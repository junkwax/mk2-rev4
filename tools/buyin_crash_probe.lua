-- crash_probe.lua
--
-- Reproduces the portal CRASH_lockup and dumps WHO jumped to garbage.
--
-- The stability sweep only reports that the PC ended up inside the game's
-- lockup/error handlers (system_lockup..tvbp). That says a trap fired; it
-- does not say what faulted. The TMS34010 pushes the faulting PC when it
-- traps, so the answer is sitting on the stack at the moment we notice.
--
-- Dumps, on the first frame the PC lands in the handler:
--   * every CPU register (A0-A14, SP, PC, ST)
--   * the top of the SYSTEM stack (SP) -- where the trap return address is
--   * the top of the PROCESS stack (A12) -- the drone's own call chain
--   * both fighters' p_action and ochar, so we know who was doing what
--
-- Feed the hex words to:  python sym_resolve.py --stack <w0> <w1> ...
--
-- Env: CRASH_LOG
-- Usage: tools\run_crash_probe.ps1

local LOGP = os.getenv("CRASH_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/crash_probe.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[crash] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    map_position = sym("map_position"), battle_num = sym("battle_num"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"),
    system_lockup = sym("system_lockup"), tvbp = sym("TVBP"),
    illegal_opcode = sym("illegal_opcode"),
}

local PDATA = 0x100
local PROC_ACTION = PDATA + 0x0f0
local OBJ_OCHAR = 0x1a0          -- ochar within the object
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local P1_CHAR, P2_CHAR, STAGE = 1, 11, 0    -- kang vs jax, dead pool

local frame, space, cpu = 0, nil, nil
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields, done, did_select = {}, false, false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end

local function reg(n)
    local ok, item = pcall(function() return cpu.state[n] end)
    if ok and item then return item.value end
    return nil
end

local function proc_act(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
end

local function dump_crash(pc)
    log("================ CRASH at frame %d ================", frame)
    log("PC = 0x%08x   (system_lockup=0x%08x illegal_opcode=0x%08x tvbp=0x%08x)",
        pc, A.system_lockup, A.illegal_opcode, A.tvbp)

    -- registers
    local names = {"A0","A1","A2","A3","A4","A5","A6","A7","A8","A9",
                   "A10","A11","A12","A13","A14","SP","ST","PC"}
    local line = ""
    for _, n in ipairs(names) do
        local v = reg(n)
        if v then line = line .. string.format("%s=%08x ", n, v & 0xffffffff) end
    end
    log("REGS %s", line)

    -- The trap pushed the faulting PC on the SYSTEM stack. Walk it.
    local sp = reg("SP")
    if sp then
        local words = {}
        for i = 0, 11 do
            local ok, v = pcall(function() return r32(sp + i * 32) end)
            words[#words+1] = string.format("%08x", ok and (v & 0xffffffff) or 0)
        end
        log("SYSTEM STACK (SP=0x%08x, 12 longs, oldest last):", sp)
        log("  %s", table.concat(words, " "))
        log("  -> python sym_resolve.py --stack %s", table.concat(words, " "))
    end

    -- The drone's own call chain lives on the process stack (A12).
    local a12 = reg("A12")
    if a12 then
        local words = {}
        for i = 0, 11 do
            local ok, v = pcall(function() return r32(a12 + i * 32) end)
            words[#words+1] = string.format("%08x", ok and (v & 0xffffffff) or 0)
        end
        log("PROCESS STACK (A12=0x%08x, 12 longs):", a12)
        log("  %s", table.concat(words, " "))
        log("  -> python sym_resolve.py --stack %s", table.concat(words, " "))
    end

    -- who was doing what
    local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
    log("P1 act=0x%04x ochar=%d   P2 act=0x%04x ochar=%d   stage=%d",
        proc_act(A.p1_proc), o1 ~= 0 and r16(o1 + OBJ_OCHAR) or -1,
        proc_act(A.p2_proc), o2 ~= 0 and r16(o2 + OBJ_OCHAR) or -1,
        r16(A.curback))
    log("a13 (current proc) = 0x%08x", reg("A13") or 0)
    log("===================================================")
end

local function finish(why)
    if done then return end
    done = true
    log("DONE: %s", why)
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Left"]=true, ["P1 Right"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local walk_dir = 1
local function pressed(name)
    if fighting_frame > 0 then
        -- The sweep drives P1 into BOTH corners; without this the crash does
        -- not reproduce, so the corner is part of the trigger.
        if name == "P1 Left"  then return walk_dir < 0 end
        if name == "P1 Right" then return walk_dir > 0 end
        return false
    end
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cpu = manager.machine.devices[":maincpu"]
        cache_fields()
        log("---- buyin probe: 1P arcade, P1 drained to force the continue screen ----")
        if A.system_lockup == 0 or A.tvbp == 0 then
            log("WARNING: system_lockup/tvbp not in MK2.MAP - detection disabled")
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, P1_CHAR)
        w16(A.p2_char, P2_CHAR)
        w16(A.curback, STAGE)
        if A.map_position ~= 0 then w16(A.map_position, STAGE) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if not did_select then did_select = true; log("forced kang vs jax on stage %d", STAGE) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then finish("never reached fight") end
        return
    end

    -- OPPOSITE of the sweep: we WANT the match to end. Drain P1 so he loses
    -- both rounds and the game reaches the continue/buy-in screen, which is
    -- the restored code path that crashed in arcade mode.
    -- Natural loss: touch nothing, let the drone win two rounds, and watch
    -- the state machine walk into gs_buyin (3) on its own.
    local gs_now = r16(A.gstate)
    if gs_now ~= last_gstate then
        log("  gstate 0x%04x -> 0x%04x at rel=%d  p1_hp=%d p2_hp=%d",
            last_gstate, gs_now, frame - fighting_frame, r16(A.p1_bar), r16(A.p2_bar))
        last_gstate = gs_now
        if gs_now == 3 then log("  *** REACHED gs_buyin (continue screen) ***") end
    end

    local wrel = frame - fighting_frame
    if wrel < 225 then walk_dir = 1 else walk_dir = -1 end

    local pc = reg("PC")
    if pc and A.system_lockup ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
        dump_crash(pc)
        finish("crash captured")
        return
    end

    if (frame % 300) == 0 then
        log("  .. frame=%d rel=%d pc=0x%08x p2_act=0x%04x",
            frame, frame - fighting_frame, pc or 0, proc_act(A.p2_proc))
    end

    if frame - fighting_frame > 9000 then finish("no crash in 9000 frames") end
    if frame > 20000 then finish("global timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
