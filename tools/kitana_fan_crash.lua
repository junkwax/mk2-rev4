--[[
    kitana_fan_crash.lua  —  Reproduce + forensically capture the
    "two Kitanas throw boomerang fans" freeze crash.

    Usage:
        mame.exe mk2 -lua tools/kitana_fan_crash.lua
        (best with a TEST build: both fighters Kitana, P2 human — see below)

    The crash:
        When two Kitana fans are in flight and boomeranging ("move the
        fan blades to attack" = the HP-held return + joystick re-aim),
        the game freezes. The actual hang lands in `illegal_opcode`
        (PC self-loops at ~0xFFA549D0 with a0=0x16) — i.e. the TMS34010
        PC was corrupted and trapped on a bad instruction. a0 is just the
        trap code, so the real culprit is on the STACK (the return chain).

    What this script does:
        1. Automates the scenario: injects Forward,Forward + HP+LP to BOTH
           players to throw fans, holds HP on both so the fans boomerang,
           and oscillates Up/Down so the fans aim vertically AND both
           Kitanas jump (air mode) -- the fan must connect against an
           airborne opponent (the full crashing condition).
        2. Watches PC every frame. If PC enters the lockup/illegal_opcode
           region (or PC is stuck for ~1.5s), it dumps ONE forensic
           report: CPU regs, a stack walk (with a ready-to-paste
           sym_resolve command), gstate, and a scan of the active process
           list highlighting both fan projectile procs and validating
           their p_store2/p_store4/p_store5 / pa8 boomerang pointers.

    Hotkeys (while MAME window focused):
        F1   = toggle FULL auto (throw + hold HP + up/down steer/jump)
        F2   = throw one fan from each player (single shot)
        F3   = dump forensic crash report on demand (even if not crashed)
        F4   = toggle "hold HP on both" (forces boomerang return)
        F5   = toggle up/down steer (fan vertical aim + jump into air mode)
        PgUp = quick one-line state dump
        F9   = reset the crash latch (allow another auto-dump)

    Build-specific addresses:
        The _B table below holds TMS34010 BIT addresses from THIS build's
        mk2.map. RAM layout shifts every rebuild. After a rebuild refresh
        with:
            python sym_resolve.py --dump | grep -iE "active|free|gstate|p1_bar|p2_bar"
        and paste the new bit values into _B. (Byte addr = bit // 8; this
        script does the //8 for you.)
--]]

-- ============================================================
-- CONFIG
-- ============================================================
local CFG = {
    log_file    = "kitana_fan_crash_log.txt",

    -- Crash detection. system_lockup/illegal_opcode/errort live in a high-ROM
    -- error band that shifts each build; this broad range covers it. The
    -- freeze itself (PC stuck, below) is the address-shift-proof trigger.
    crash_lo    = 0xFFA53000,
    crash_hi    = 0xFFA56000,
    -- secondary watchdog: PC identical for this many frames => dump.
    -- The fan crash self-loops in the handler with RAM intact, so a quick
    -- trigger still captures the fan procs.
    stuck_frames = 45,

    -- Stack walk depth (longs read from SP upward)
    stack_longs = 28,

    -- Input injection: fan throw = Forward,Forward + HP + LP (both punches).
    -- Holding HP afterwards makes the fan boomerang back ("move the blades").
    -- MK2 button name varies by MAME version; check the port dump in the
    -- log on first run and adjust these substrings if injection misfires.
    btn_hp_match = "High Punch",  -- HP (also held => fan boomerangs)
    btn_lp_match = "Low Punch",   -- LP (pressed with HP to throw)

    -- frames to hold each motion step / button
    step_hold   = 8,

    -- Auto-start: once a round has been live this many frames, automatically
    -- enable full auto (throw + hold-HP + up/down steer) with no keypress.
    -- Set to 0 to disable and drive manually with the hotkeys.
    -- (0 = manual play: harness only WATCHES for the crash, never injects.)
    autostart_frames = 0,

    -- Vertical motion (the air-mode crash condition):
    --   P1 oscillates Up/Down to aim its fan up/down (fanp4 hat-aim); this
    --   also makes P1 hop. steer_period = frames per Up or Down half-cycle.
    --   P2 continuously JUMPS so there is an airborne Kitana the fans must
    --   connect against. jump_up = frames holding Up, jump_gap = frames down.
    steer_period = 14,
    jump_up      = 6,
    jump_gap     = 16,
}

-- ============================================================
-- ADDRESS TABLE  (TMS34010 BIT addresses from current mk2.map)
-- ============================================================
local _B = {
    active = 0x010dc6d0,   -- head of active process list (long -> first proc)
    free   = 0x010dc6f0,   -- head of free process list
    objlst = 0x01127060,   -- head of object list
    gstate = 0x01129dc0,   -- game state word
    p1_bar = 0x01129ee0,   -- P1 health
    p2_bar = 0x0112aab0,   -- P2 health
    p1_state = 0x01129de0, -- P1 player state (ps_active=1 => controllable)
    p2_state = 0x0112a9b0, -- P2 player state
}

-- Process struct field BIT offsets (from MAINEQU.ASM, pdata=0x100)
local PF = {
    link      = 0x000,  -- next-proc pointer (proc list link)
    procid    = 0x020,  -- 16-bit process id
    pa8       = 0x0c0,  -- 32-bit -> this proc's object (a8)
    p_otherguy= 0x140,
    p_otherproc=0x170,
    p_slave   = 0x190,
    p_action  = 0x1f0,  -- 16-bit current action
    -- NOTE: store fields are pdata-relative in MAINEQU (pdata=0x100), so the
    -- absolute proc offset is 0x100 + the listed value.
    p_store1  = 0x230,  -- pdata+0x130
    p_store2  = 0x250,  -- pdata+0x150  boomerang: thrower proc
    p_store3  = 0x270,  -- pdata+0x170
    p_store4  = 0x290,  -- pdata+0x190  boomerang: thrower procid stamp
    p_store5  = 0x2b0,  -- pdata+0x1b0  boomerang: victim procid stamp
}

-- Object struct field BIT offsets (DISPEQU.ASM)
local OF = {
    oxpos = 0x090, oypos = 0x0b0, oxvel = 0x040, oyvel = 0x060,
    oflags = 0x0f0, oimg = 0x1a0,
}

-- Game constants
local GS_FIGHT  = 0x0002
local PID_P1    = 0x0001
local PID_P2    = 0x0002
local PID_PROJ1 = 0x0700   -- P1 projectile (P1 Kitana fan)
local PID_PROJ2 = 0x0800   -- P2 projectile (P2 Kitana fan)

-- IMPORTANT: MAME 0.287's TMS34010 Lua program space is addressed by the
-- RAW bit address (verified: read_u32(0xFF800000) == flat ROM word 0). Do NOT
-- divide by 8 here (the old mk2_test.lua / CLAUDE.md note are wrong for this
-- MAME version). All _B / PF / OF values are TMS bit addresses used as-is.
local function b2byte(bit) return bit end

-- ============================================================
-- MEMORY + CPU
-- ============================================================
local space, cpu

local function mem_init()
    cpu = manager.machine.devices[":maincpu"]
    if not cpu then print("[fan] ERROR: no :maincpu"); return false end
    space = cpu.spaces["program"]
    if not space then print("[fan] ERROR: no program space"); return false end
    return true
end

local function rw(bit)  return space:read_u16(b2byte(bit)) end
local function rl(bit)  return space:read_u32(b2byte(bit)) end
local function ww(bit,v) space:write_u16(b2byte(bit), v & 0xffff) end

-- read a field (bit offset) inside a proc/obj whose BASE is a bit address
local function fld_w(base_bit, off) return rw(base_bit + off) end
local function fld_l(base_bit, off) return rl(base_bit + off) end

-- CPU register value by name (bit address for PC/SP on TMS34010)
local function reg(name)
    local ok, v = pcall(function() return cpu.state[name].value end)
    if ok then return v end
    return nil
end

-- ============================================================
-- LOG
-- ============================================================
local logf
local function log(msg)
    local s = string.format("[%s] %s\n", os.date("%H:%M:%S"), msg)
    io.write(s); io.flush()
    if logf then logf:write(s); logf:flush() end
end

-- ============================================================
-- PROCESS LIST WALK
-- ============================================================
-- Returns array of proc base bit-addresses, walking `active`.
local function walk_active()
    local procs = {}
    local p = rl(_B.active)
    local guard = 0
    while p ~= 0 and guard < 400 do
        procs[#procs+1] = p
        p = fld_l(p, PF.link)
        guard = guard + 1
    end
    return procs, guard
end

local function count_list(head_bit)
    local n, p, guard = 0, rl(head_bit), 0
    while p ~= 0 and guard < 1000 do
        n = n + 1
        p = fld_l(p, PF.link)
        guard = guard + 1
    end
    return n
end

-- is a proc base still present in the active list? (validity check)
local function proc_is_active(target)
    if target == 0 then return false end
    local p, guard = rl(_B.active), 0
    while p ~= 0 and guard < 400 do
        if p == target then return true end
        p = fld_l(p, PF.link)
        guard = guard + 1
    end
    return false
end

-- ============================================================
-- FORENSIC CRASH DUMP
-- ============================================================
local function dump_regs()
    log("--- CPU registers ---")
    local pc, sp, st = reg("PC"), reg("SP"), reg("ST")
    log(string.format("  PC=%08X  SP=%08X  ST=%08X",
        pc or 0, sp or 0, st or 0))
    for bank = 0, 1 do
        local pfx = (bank == 0) and "A" or "B"
        local parts = {}
        for i = 0, 14 do
            local v = reg(pfx .. i)
            if v then parts[#parts+1] = string.format("%s%d=%08X", pfx, i, v) end
        end
        -- print 5 per line
        for i = 1, #parts, 5 do
            log("  " .. table.concat(parts, "  ", i, math.min(i+4, #parts)))
        end
    end
end

local function dump_stack()
    local sp = reg("SP")
    if not sp then log("  (no SP)"); return end
    log(string.format("--- Stack walk from SP=%08X ---", sp))
    local code_vals = {}
    for i = 0, CFG.stack_longs - 1 do
        local at  = sp + i * 32           -- 32 bits per long
        local v   = rl(at)
        local tag = ""
        if v >= 0xFF800000 and v <= 0xFFFFFFFF then
            tag = "  <- code/return?"
            code_vals[#code_vals+1] = string.format("%08x", v)
        end
        log(string.format("  [SP+%04X] %08X%s", i*32, v, tag))
    end
    if #code_vals > 0 then
        log("  Resolve the return chain with:")
        log("    python sym_resolve.py " .. table.concat(code_vals, " "))
    end
end

local function describe_proc(base, idx)
    local pid    = fld_w(base, PF.procid)
    local act    = fld_w(base, PF.p_action)
    local pa8    = fld_l(base, PF.pa8)
    local slave  = fld_l(base, PF.p_slave)
    local tag    = ""
    if pid == PID_P1 then tag = " [P1 fighter]"
    elseif pid == PID_P2 then tag = " [P2 fighter]"
    elseif pid == PID_PROJ1 then tag = " [P1 PROJ/fan]"
    elseif pid == PID_PROJ2 then tag = " [P2 PROJ/fan]" end
    log(string.format("  #%-2d proc=%08X pid=%04X act=%04X pa8=%08X slave=%08X%s",
        idx, base, pid, act, pa8, slave, tag))

    -- For fan/projectile procs, validate boomerang pointers
    if pid == PID_PROJ1 or pid == PID_PROJ2 then
        local s2 = fld_l(base, PF.p_store2)   -- thrower proc
        local s4 = fld_w(base, PF.p_store4)   -- thrower procid stamp
        local s5 = fld_w(base, PF.p_store5)   -- victim procid stamp
        local oproc = fld_l(base, PF.p_otherproc)
        local s2_ok = proc_is_active(s2)
        local s2_pid = (s2 ~= 0) and fld_w(s2, PF.procid) or 0
        local oproc_ok = proc_is_active(oproc)
        local oproc_pid = (oproc ~= 0) and fld_w(oproc, PF.procid) or 0
        log(string.format("       boomerang: p_store2=%08X(alive=%s pid=%04X want=%04X %s)",
            s2, tostring(s2_ok), s2_pid, s4,
            (s2_ok and s2_pid == s4) and "MATCH" or "*** STALE/MISMATCH ***"))
        log(string.format("                  p_otherproc=%08X(alive=%s pid=%04X want=%04X %s)",
            oproc, tostring(oproc_ok), oproc_pid, s5,
            (oproc_ok and oproc_pid == s5) and "MATCH" or "*** STALE/MISMATCH ***"))
        -- if pa8 (fan object) is bogus the renderer/strike code can wander
        if pa8 ~= 0 then
            local img = fld_l(pa8, OF.oimg)
            log(string.format("                  fan obj oimg=%08X xpos=%d ypos=%d",
                img, fld_w(pa8, OF.oxpos), fld_w(pa8, OF.oypos)))
        end
    end
end

local dump_count = 0
local function forensic_dump(reason)
    dump_count = dump_count + 1
    log("")
    log("================ FORENSIC DUMP #" .. dump_count .. " ================")
    log("reason: " .. reason)
    log(string.format("gstate=%04X  P1hp=%d  P2hp=%d",
        rw(_B.gstate), rw(_B.p1_bar), rw(_B.p2_bar)))
    dump_regs()

    local procs, walked = walk_active()
    local nactive = #procs
    local nfree   = count_list(_B.free)
    log(string.format("--- Process pool: active=%d free=%d (walk guard=%d) ---",
        nactive, nfree, walked))
    if walked >= 400 then
        log("  *** active list walk hit guard limit — list may be CORRUPTED (loop) ***")
    end

    -- fighters + projectiles first, summarize the rest
    local nfan = 0
    for i, base in ipairs(procs) do
        local pid = fld_w(base, PF.procid)
        if pid == PID_P1 or pid == PID_P2 or pid == PID_PROJ1 or pid == PID_PROJ2 then
            describe_proc(base, i)
            if pid == PID_PROJ1 or pid == PID_PROJ2 then nfan = nfan + 1 end
        end
    end
    log(string.format("  (%d fan/projectile procs in flight)", nfan))

    dump_stack()
    log("================ END DUMP #" .. dump_count .. " ================")
    log("")
end

-- ============================================================
-- CRASH WATCHER
-- ============================================================
local crash_latched = false
local last_pc       = nil
local pc_same_count = 0
local fight_seen    = false   -- only treat freezes as crashes once a round was live

local function crash_watch()
    local pc = reg("PC")
    if not pc then return end

    -- Require that a real fight was running first, so we ignore the
    -- boot/self-test loop (which also sits at a steady PC in high ROM).
    if rw(_B.gstate) == GS_FIGHT then fight_seen = true end

    -- 1) PC landed in the lockup / illegal_opcode region (addresses shift
    --    per build; broad high-ROM error band).
    local in_region = (pc >= CFG.crash_lo and pc <= CFG.crash_hi)

    -- 2) PC frozen on the same instruction for a while
    if pc == last_pc then
        pc_same_count = pc_same_count + 1
    else
        pc_same_count = 0
        last_pc = pc
    end
    local stuck = pc_same_count >= CFG.stuck_frames

    if fight_seen and (in_region or stuck) and not crash_latched then
        crash_latched = true
        local why = in_region
            and string.format("PC=%08X inside lockup/error region", pc)
            or  string.format("PC=%08X stuck for %d frames", pc, pc_same_count)
        log("!!! CRASH/HANG DETECTED: " .. why)
        forensic_dump(why)
    end
end

-- ============================================================
-- INPUT INJECTION
-- ============================================================
-- discover P1/P2 direction + button fields by name
local IN = { p1 = {}, p2 = {} }

local function grab_field(side, key, port, name)
    IN[side][key] = port.fields[name]
end

-- MAME ioports table moved between versions: manager.machine.ioport.ports
-- (0.227+) vs manager.machine.ioports (older). Support both.
local function get_ioports()
    local m = manager.machine
    if m.ioport and m.ioport.ports then return m.ioport.ports end
    if m.ioports then return m.ioports end
    return {}
end

local function enum_ports()
    log("--- Input ports (configure CFG.btn_*_match from this) ---")
    for tag, port in pairs(get_ioports()) do
        local names = {}
        for name, _ in pairs(port.fields) do names[#names+1] = name end
        if #names > 0 then
            table.sort(names)
            log(string.format("  [%s]: %s", tag, table.concat(names, " | ")))
            for _, name in ipairs(names) do
                local f = port.fields[name]
                if name:find("^P1") then
                    if name:find("Left")  then IN.p1.left  = f end
                    if name:find("Right") then IN.p1.right = f end
                    if name:find("Up")    then IN.p1.up    = f end
                    if name:find("Down")  then IN.p1.down  = f end
                    if name:find(CFG.btn_hp_match) then IN.p1.hp = f end
                    if name:find(CFG.btn_lp_match) then IN.p1.lp = f end
                elseif name:find("^P2") then
                    if name:find("Left")  then IN.p2.left  = f end
                    if name:find("Right") then IN.p2.right = f end
                    if name:find("Up")    then IN.p2.up    = f end
                    if name:find("Down")  then IN.p2.down  = f end
                    if name:find(CFG.btn_hp_match) then IN.p2.hp = f end
                    if name:find(CFG.btn_lp_match) then IN.p2.lp = f end
                end
            end
        end
    end
    log("---")
    local function rep(side)
        local s = IN[side]
        log(string.format("  %s: left=%s right=%s up=%s down=%s hp=%s lp=%s", side,
            tostring(s.left ~= nil), tostring(s.right ~= nil),
            tostring(s.up ~= nil),   tostring(s.down ~= nil),
            tostring(s.hp ~= nil),   tostring(s.lp ~= nil)))
    end
    rep("p1"); rep("p2")
end

local function set_field(f, v) if f then pcall(function() f:set_value(v) end) end end

-- A throw "program": list of {hold_frames, p1_dir_field, p2_dir_field, press_punch}
-- press_punch = press HP+LP together (the fan-throw trigger).
-- P1 faces right (Forward=Right), P2 faces left (Forward=Left) at round start.
local function build_throw_seq()
    local h = CFG.step_hold
    return {
        { h, IN.p1.right, IN.p2.left, false },  -- Forward
        { 4, nil,         nil,        false },  -- gap
        { h, IN.p1.right, IN.p2.left, true  },  -- Forward + HP+LP (throw)
        { 4, nil,         nil,        false },
    }
end

local seq, seq_step, seq_ticks = nil, 1, 0
local function seq_start()
    seq = build_throw_seq(); seq_step = 1; seq_ticks = 0
    log("throw sequence started (both players)")
end

local hold_hp = false   -- F4 / part of auto: keep HP held so fans boomerang
local auto    = false   -- F1: continuously re-throw
local steer   = false   -- part of auto: P1 up/down fan-aim + P2 jumping
local steer_ctr = 0     -- oscillator counter

-- Vertical motion:
--   P1 alternates Up / Down  -> aims its fan up & down (and hops).
--   P2 jumps on a cycle      -> stays mostly airborne (the air-mode target).
local function steer_tick()
    if not steer then return end
    steer_ctr = steer_ctr + 1

    -- P1: up/down oscillation (fan vertical aim)
    local phase = (steer_ctr // CFG.steer_period) % 2   -- 0 = up, 1 = down
    if phase == 0 then
        set_field(IN.p1.down, 0); set_field(IN.p1.up, 1)
    else
        set_field(IN.p1.up, 0);   set_field(IN.p1.down, 1)
    end

    -- P2: jump cycle (Up for jump_up frames, neutral for jump_gap frames)
    local jp = steer_ctr % (CFG.jump_up + CFG.jump_gap)
    if jp < CFG.jump_up then
        set_field(IN.p2.down, 0); set_field(IN.p2.up, 1)
    else
        set_field(IN.p2.up, 0)
    end
end

local function clear_inputs()
    for _, s in pairs({IN.p1, IN.p2}) do
        set_field(s.left, 0); set_field(s.right, 0)
        set_field(s.up, 0);   set_field(s.down, 0)
        set_field(s.lp, 0)
        if not hold_hp then set_field(s.hp, 0) end
    end
end

local function seq_tick()
    -- HP hold is independent of the motion sequence
    if hold_hp then set_field(IN.p1.hp, 1); set_field(IN.p2.hp, 1) end

    if not seq then
        if auto and rw(_B.gstate) == GS_FIGHT then seq_start() end
        return
    end
    local step = seq[seq_step]
    if not step then
        clear_inputs()
        seq = nil
        if auto then seq_start() end   -- loop
        return
    end
    if seq_ticks == 0 then
        -- (re)assert this step's inputs
        set_field(IN.p1.left, 0); set_field(IN.p1.right, 0); set_field(IN.p1.lp, 0)
        set_field(IN.p2.left, 0); set_field(IN.p2.right, 0); set_field(IN.p2.lp, 0)
        set_field(step[2], 1)
        set_field(step[3], 1)
        if step[4] then  -- Forward + HP + LP throws the fan
            set_field(IN.p1.hp, 1); set_field(IN.p1.lp, 1)
            set_field(IN.p2.hp, 1); set_field(IN.p2.lp, 1)
        end
    end
    seq_ticks = seq_ticks + 1
    if seq_ticks >= step[1] then seq_step = seq_step + 1; seq_ticks = 0 end
end

-- run after seq_tick so Up/Down overrides any direction clears that frame
local function inputs_tick()
    seq_tick()
    steer_tick()
end

-- ============================================================
-- QUICK STATE LINE
-- ============================================================
local function quick_dump()
    local procs = walk_active()
    local nfan = 0
    for _, base in ipairs(procs) do
        local pid = fld_w(base, PF.procid)
        if pid == PID_PROJ1 or pid == PID_PROJ2 then nfan = nfan + 1 end
    end
    log(string.format("gs=%04X P1hp=%d P2hp=%d active=%d free=%d fans=%d PC=%08X",
        rw(_B.gstate), rw(_B.p1_bar), rw(_B.p2_bar),
        #procs, count_list(_B.free), nfan, reg("PC") or 0))
end

-- ============================================================
-- HOTKEYS
-- ============================================================
-- NOTE: keys chosen to NOT collide with MAME's UI defaults (F2=service,
-- F3=reset, F5=debugger, F7=state, etc.). Ins/Home/End/PgUp/PgDn/Del are free.
local input_sys, debounce = nil, {}
local function set_full_auto(on)
    auto = on; hold_hp = on; steer = on
    log("FULL AUTO (throw + HP-hold + up/down steer): " .. (on and "ON" or "OFF"))
    if not on then seq = nil; clear_inputs() end
end
local HOTKEYS = {
    { "KEYCODE_INSERT", function() set_full_auto(not auto) end },
    { "KEYCODE_DEL",    function() seq_start() end },
    { "KEYCODE_HOME",   function() hold_hp = not hold_hp
                       log("hold-HP (boomerang): " .. (hold_hp and "ON" or "OFF")) end },
    { "KEYCODE_END",    function() steer = not steer
                       if not steer then clear_inputs() end
                       log("up/down steer (aim+jump): " .. (steer and "ON" or "OFF")) end },
    { "KEYCODE_PGDN",   function() forensic_dump("manual PgDn") end },
    { "KEYCODE_PAUSE",  function() crash_latched = false; pc_same_count = 0
                       log("crash latch reset") end },
    { "KEYCODE_PGUP",   quick_dump },
}

local function hotkeys()
    for _, hk in ipairs(HOTKEYS) do
        local code = input_sys:code_from_token(hk[1])
        local down = input_sys:code_pressed(code)
        if down and not debounce[hk[1]] then hk[2]() end
        debounce[hk[1]] = down
    end
end

-- ============================================================
-- FRAME LOOP
-- ============================================================
-- lazy one-time init (register_start is deprecated and may not fire)
local inited = false
local function ensure_init()
    if inited then return true end
    if not mem_init() then return false end
    input_sys = manager.machine.input
    enum_ports()
    inited = true
    -- address-convention probe: program ROM at 0xFF800000 (bit) is always
    -- non-zero. Read it both ways to confirm which addressing the Lua space
    -- uses, so we trust gstate/proc reads.
    local ok1, rom_div8 = pcall(function() return space:read_u32((0xFF800000)//8) end)
    local ok2, rom_bit  = pcall(function() return space:read_u32(0xFF800000) end)
    local okp, powerup  = pcall(function() return space:read_u32((0xFF80EA20)//8) end)
    log(string.format("PROBE rom@(bit/8)=%s  rom@(bit)=%s  powerup@(bit/8)=%s",
        ok1 and string.format("%08X", rom_div8) or "ERR",
        ok2 and string.format("%08X", rom_bit) or "ERR",
        okp and string.format("%08X", powerup) or "ERR"))
    log("Ready | Ins=full auto  Del=throw once  Home=hold-HP  End=steer  PgDn=dump  PgUp=state  Pause=reset latch")
    if CFG.autostart_frames > 0 then
        log(string.format("auto-start armed: full auto after %d live frames", CFG.autostart_frames))
    end
    return true
end

local fight_frames    = 0
local autostarted     = false
local function autostart_tick()
    if CFG.autostart_frames <= 0 or autostarted then return end
    if rw(_B.gstate) == GS_FIGHT then
        fight_frames = fight_frames + 1
        if fight_frames >= CFG.autostart_frames then
            autostarted = true
            log("AUTO-START: round live -> enabling full auto")
            set_full_auto(true)
        end
    else
        fight_frames = 0
    end
end

-- Heartbeat: log live state when it changes (or every ~2s) so we can see
-- whether the round is controllable and whether fans are being thrown,
-- without relying on any keypress.
local hb_sig, hb_ctr, hb_lines = nil, 0, 0
local function heartbeat()
    if hb_lines > 600 then return end
    hb_ctr = hb_ctr + 1
    local procs = walk_active()
    local nfan = 0
    for _, b in ipairs(procs) do
        local pid = fld_w(b, PF.procid)
        if pid == PID_PROJ1 or pid == PID_PROJ2 then nfan = nfan + 1 end
    end
    local gs  = rw(_B.gstate)
    local p1s = rw(_B.p1_state)
    local p2s = rw(_B.p2_state)
    local sig = string.format("%x|%x|%x|%d", gs, p1s, p2s, nfan)
    if sig ~= hb_sig or hb_ctr % 120 == 0 then
        hb_sig = sig
        hb_lines = hb_lines + 1
        log(string.format("hb gs=%04X p1st=%04X p2st=%04X P1hp=%d P2hp=%d fans=%d active=%d PC=%08X",
            gs, p1s, p2s, rw(_B.p1_bar), rw(_B.p2_bar), nfan, #procs, reg("PC") or 0))
    end
end

-- Corruption detector: watch every in-flight fan proc's p_store2 (thrower
-- back-pointer). A valid proc lives in the RAM pool (~0x01080000..0x010FFFFF).
-- The instant a fan's p_store2 goes out of that range we log it with the PC,
-- A13 and the fan proc, pinpointing when/where the corruption happens --
-- before the eventual lockup.
local function proc_ptr_sane(p)
    return p ~= 0 and p >= 0x01080000 and p < 0x01100000 and (p % 16 == 0)
end
local corrupt_latched = {}   -- per fan-proc addr, log once
local function corruption_watch()
    if not fight_seen then return end
    local procs = walk_active()
    for _, base in ipairs(procs) do
        local pid = fld_w(base, PF.procid)
        if pid == PID_PROJ1 or pid == PID_PROJ2 then
            local s2 = fld_l(base, PF.p_store2)
            if not proc_ptr_sane(s2) and not corrupt_latched[base] then
                corrupt_latched[base] = true
                log(string.format(
                    "*** P_STORE2 CORRUPT *** fan=%08X pid=%04X p_store2=%08X PC=%08X A13=%08X act=%04X pa8=%08X",
                    base, pid, s2, reg("PC") or 0, reg("A13") or 0,
                    fld_w(base, PF.p_action), fld_l(base, PF.pa8)))
            end
        end
    end
end

-- Saved-PC watch: the dispatcher (prclsp) resumes a process via the value at
-- proc+0x40 (saved A7 = resume PC). A valid resume PC is in ROM (0xFF8xxxxx).
-- The crash is caused by a proc whose saved A7 became a RAM address (it gets
-- JUMP'd into and executes data). Scan every proc each frame and report the
-- instant one's saved A7 turns into a RAM (non-code) value -- that names the
-- victim process (procid/action) before it is ever dispatched.
local SAVED_A7 = 0x40
local function code_ptr(p) return p >= 0xFF800000 end
local savedpc_latched = {}
local function savedpc_watch()
    if not fight_seen then return end
    local procs = walk_active()
    for _, base in ipairs(procs) do
        local a7 = fld_l(base, SAVED_A7)
        -- invalid resume PC = points into RAM (0x01000000..0x01200000)
        if a7 >= 0x01000000 and a7 < 0x01200000 and not savedpc_latched[base] then
            savedpc_latched[base] = true
            local pid = fld_w(base, PF.procid)
            log(string.format(
                "*** BAD RESUME-PC *** proc=%08X pid=%04X act=%04X savedA7=%08X link=%08X pa8=%08X PC=%08X",
                base, pid, fld_w(base, PF.p_action), a7,
                fld_l(base, 0x00), fld_l(base, PF.pa8), reg("PC") or 0))
            -- dump the proc's saved-register area (0x40..0x100) and id fields
            local parts = {}
            for off = 0x40, 0x100, 0x20 do
                parts[#parts+1] = string.format("+%02X=%08X", off, fld_l(base, off))
            end
            log("      savearea " .. table.concat(parts, " "))
        end
    end
end

local function on_frame()
    if not ensure_init() then return end
    hotkeys()
    crash_watch()
    corruption_watch()
    savedpc_watch()
    heartbeat()
    autostart_tick()
    inputs_tick()
end

-- ============================================================
-- STARTUP
-- ============================================================
logf = io.open(CFG.log_file, "a")
log("=== kitana_fan_crash.lua start ===")

-- ensure_init() also runs lazily from on_frame in case this never fires
pcall(function() emu.register_start(function() ensure_init() end) end)

emu.register_frame_done(on_frame)
