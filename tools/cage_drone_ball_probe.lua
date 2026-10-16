-- cage_drone_ball_probe.lua
--
-- Cage's HIGH force ball is retired for the player (jchip_fight, MOVES.ASM).
-- The drone reached it separately, through cage_zap_hi_jsrp (MKDRONE.ASM),
-- which three anti-air tables jump to: angle_towards_reactions,
-- close_out_of_air and med_out_of_air.  That wrapper now throws the LOW ball
-- instead, so the move must be unreachable in a real fight from either side.
--
-- P1 = Liu Kang, human, jumps straight in on a cadence and does nothing else
-- (a jump-in is what puts the drone into those anti-air tables at all).
-- P2 = Johnny Cage, drone, diff 9.
--
-- PASS  = act_jcsnot_hi never appears on the drone, and act_jcsnot_lo does
--         (proving the anti-air still fires - a silent drone would "pass"
--         a hi==0 test while telling us nothing).
--
-- RNG is stirred every frame: @rand is reseeded from constants at round
-- start, so an unstirred scripted rig replays one stream and a single roll
-- decides the whole run.  See doc/AI_DRONE.md.
--
-- Env: CDB_LOG, CDB_DIFF, CDB_SEED
-- Usage: tools\run_cage_drone_ball_probe.ps1

local LOGP = os.getenv("CDB_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/cage_drone_ball_probe.log"
local DIFF = tonumber(os.getenv("CDB_DIFF") or "9")
local SEED = tonumber(os.getenv("CDB_SEED") or "0")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[cdb] " .. string.format(fmt, ...)
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
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"), rand = sym("rand"),
}

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local PDATA       = 0x100
local PROC_ACTION = PDATA + 0x0f0
local PROC_GANIY  = PDATA + 0x100
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

-- Action ids are .set equates, so they are not in MK2.MAP - read them out of
-- MAINEQU.ASM rather than hardcoding.  A wrong constant here is indis-
-- tinguishable from "the move never fired".
local acts = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+([0-9a-fA-F]+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end
local function act(n)
    local v = acts[n]
    if not v then log("FATAL: %s not found in MAINEQU.ASM", n) end
    return v or -1
end
local ACT_SNOT_HI, ACT_SNOT_LO = act("act_jcsnot_hi"), act("act_jcsnot_lo")

local FT_KANG, FT_CAGE = 1, 2
local AIR_MIN     = 0x10
local JUMP_PERIOD = 170
local RUN_FRAMES  = 9000

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start = 0
local fields = {}
local done = false

local jumps, hi_balls, lo_balls = 0, 0, 0
local was_air, last_act2 = false, -1
local p1_forward = "R"

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function proc_act(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
end
local function height(procptr, objptr)
    local q, o = r32(procptr), r32(objptr)
    if q == 0 or o == 0 then return 0 end
    local h = s16(r16(q + PROC_GANIY)) - s16(r16(o + OYPOS))
    if h < 0 then h = 0 end
    return h
end

local function finish()
    if done then return end
    done = true
    log("RESULT diff=%d jumps=%d high_balls=%d low_balls=%d", DIFF, jumps, hi_balls, lo_balls)
    local fails = {}
    if jumps < 5 then
        fails[#fails+1] = string.format(
            "only %d jump-ins - the rig never got going, so this proves nothing", jumps)
    end
    if hi_balls > 0 then
        fails[#fails+1] = string.format(
            "the drone threw the retired HIGH ball %d time(s)", hi_balls)
    end
    if lo_balls == 0 then
        fails[#fails+1] =
            "the drone never threw a ball at all - hi=0 here proves nothing about the wrapper"
    end
    if #fails == 0 then
        log("PASS cage_drone_ball: %d balls thrown, all of them the low one", lo_balls)
    else
        log("FAIL cage_drone_ball: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Up"]=true, ["P1 Right"]=true, ["P1 Left"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local function jump_phase()
    local t = (frame - fighting_frame) % JUMP_PERIOD
    if t < 10 then return "jump" end
    return "idle"
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    local ph = jump_phase()
    if name == "P1 Up" then return ph == "jump" end
    if name == (p1_forward == "L" and "P1 Left" or "P1 Right") then return ph == "jump" end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- cage drone ball: P1=LiuKang jumps in every %d frames, P2=Cage(drone) diff=%d ----",
            JUMP_PERIOD, DIFF)
        log("     watching act_jcsnot_hi=0x%04x (must never appear) / act_jcsnot_lo=0x%04x",
            ACT_SNOT_HI, ACT_SNOT_LO)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)      -- P2 is the drone
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_CAGE)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        run_start = frame
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= DIFF then w16(A.diff, DIFF) end
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    if A.rand ~= 0 then
        w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345 + SEED) & 0xffffffff)
    end

    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then p1_forward = (x1 < x2) and "R" or "L" end
    local gap = (x1 and x2) and math.abs(x2 - x1) or 999
    local h1 = height(A.p1_proc, A.p1_obj)
    local act2 = proc_act(A.p2_proc)

    -- keep them honestly spaced: nudge the idle player, never the drone
    if gap < 0x50 and jump_phase() == "idle" and (frame % 10) == 0 then
        local o = r32(A.p1_obj)
        if o ~= 0 and x1 and x2 then
            local nx = x1 + ((x1 < x2) and -5 or 5)
            if nx > 40 and nx < 360 then
                space:write_u32(o + OXVAL, (nx & 0xffff) << 16)
                w16(o + OXPOS, nx & 0xffff)
            end
        end
    end

    local air = h1 >= AIR_MIN
    if air and not was_air then jumps = jumps + 1 end
    was_air = air

    if act2 ~= last_act2 then
        if act2 == ACT_SNOT_HI then
            hi_balls = hi_balls + 1
            log("HIGH ball from the drone (#%d) gap=%d h1=%d frame=%d",
                hi_balls, gap, h1, frame - run_start)
        elseif act2 == ACT_SNOT_LO then
            lo_balls = lo_balls + 1
            log("low ball (#%d) gap=%d h1=%d frame=%d", lo_balls, gap, h1, frame - run_start)
        end
        last_act2 = act2
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)

    if (frame % 1200) == 0 then
        log("  .. rel=%d gap=%d h1=%d p2_act=0x%04x jumps=%d hi=%d lo=%d",
            frame - run_start, gap, h1, act2, jumps, hi_balls, lo_balls)
    end

    if frame - run_start > RUN_FRAMES then finish(); return end
    if frame > 40000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
