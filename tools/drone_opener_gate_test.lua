-- drone_opener_gate_test.lua
--
-- Verifies the round-opener reach gate (opener_in_range, MKDRONE.ASM).
--
-- setup_players always starts the fighters 0c0h = 192px apart, and every
-- *_start opener is a short-range move, so firing one at the top of the
-- round could only ever whiff.  Two phases per run:
--
--   OPENER - watch the drone for OBSERVE frames from fight start without
--            touching positions.  The special must NEVER appear (the reach
--            test is deterministic at 192px, so this is not a coin flip).
--   CLOSE  - pin both fighters ~50px apart and keep watching.  The special
--            SHOULD appear, proving the move is still in the drone's kit
--            via the cmf_close hook rather than merely deleted.
--
-- Env: GATE_CHAR (ft index for P2/drone), GATE_ACT (act_* value to watch),
--      GATE_LABEL, GATE_LOG
--
-- Usage: tools\run_drone_opener_gate_test.ps1

local CHAR  = tonumber(os.getenv("GATE_CHAR") or "11")
local ACT   = tonumber(os.getenv("GATE_ACT") or "0x0110")
local LABEL = os.getenv("GATE_LABEL") or "jax"
local LOGP  = os.getenv("GATE_LOG") or "C:/Users/you/Workplace/mk2-main/tools/drone_opener_gate_test.log"

local OPENER_FRAMES = 400     -- generous: many drone decision cycles
local CLOSE_FRAMES  = 3600

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[gate] " .. string.format(fmt, ...)
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
    p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PS_ACTIVE, PS_INACTIVE = 1, 0   -- ps_active=1 (MAINEQU); 2 is ps_buyin and stalls select
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

local frame, space = 0, nil
local last_gstate = -1      -- must be a number: string.format("%d", nil) kills the frame callback
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase, phase_start = "opener", 0
local opener_hits, close_hits = 0, 0
local was_in_move = false
local fields = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function drone_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + PROC_ACTION)
end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function finish()
    if done then return end
    done = true
    log("%s RESULT opener_fires=%d close_fires=%d", LABEL, opener_hits, close_hits)
    if opener_hits == 0 and close_hits > 0 then
        log("PASS %s: gated out of the round opener, still used in close", LABEL)
    elseif opener_hits > 0 then
        log("FAIL %s: special still fired as a round opener (%d times)", LABEL, opener_hits)
    else
        log("FAIL %s: never fired in close either - move may be unreachable", LABEL)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true, ["UI Select"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        return false
    end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- %s: drone char=%d watching act=0x%04x ----", LABEL, CHAR, ACT)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("%s frame=%d gstate %d -> %d", LABEL, frame, last_gstate, gs)
        last_gstate = gs
    end
    if gs == GS_PSEL and charsel_frame == 0 then
        charsel_frame = frame
        log("%s char select at frame=%d", LABEL, frame)
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)      -- P2 = AI drone
        w16(A.p1_char, 1)                 -- P1 = Liu Kang (idle human)
        w16(A.p2_char, CHAR)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase, phase_start = "opener", frame
        local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
        log("%s fight_start frame=%d p2_char=%d start_gap=%d diff=%d",
            LABEL, frame, r16(A.p2_char), math.abs((x2 or 0) - (x1 or 0)), r16(A.diff))
    end

    if fighting_frame == 0 then
        if frame > 6000 then log("%s ERROR never reached fight", LABEL); finish() end
        return
    end

    -- ask_mr_diff scales the roll by @diff (8% at 0, 45% at 9).  Pin it high
    -- so a quiet window is evidence of unreachability, not just bad luck.
    if A.diff ~= 0 then w16(A.diff, 9) end
    -- keep both alive so rounds never end and the drone keeps deciding
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    local act = drone_action()
    local firing = (act == ACT)
    local edge = firing and not was_in_move
    was_in_move = firing

    if phase == "opener" then
        if edge then
            local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
            local gap = math.abs((x2 or 0) - (x1 or 0))
            -- Judge by DISTANCE, not elapsed frames.  The complaint is "it is
            -- the CPU's first move at the top of the round", i.e. fired from
            -- the 192px start separation.  Once the drone has walked in, a
            -- fire is ordinary cmf_close usage and must not count against
            -- the gate - Cage was failed on exactly that, at gap=79.
            if gap >= 150 then
                opener_hits = opener_hits + 1
                log("%s OPENER FIRE at rel=%d gap=%d  <-- VIOLATION", LABEL,
                    frame - phase_start, gap)
            else
                log("%s in-range fire at rel=%d gap=%d (not an opener)", LABEL,
                    frame - phase_start, gap)
                close_hits = close_hits + 1
            end
        end
        if frame - phase_start > OPENER_FRAMES then
            phase, phase_start = "close", frame
            log("%s opener window clean (%d frames), now testing close range",
                LABEL, OPENER_FRAMES)
        end
    elseif phase == "close" then
        -- Nudge the drone back only when it wanders out of close range.
        -- Hard-pinning every frame overrides its own walk and it stops
        -- entering cmf_close at all, which reads as a false "unreachable".
        local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
        if x1 and x2 and math.abs(x2 - x1) > 70 then pin(A.p2_obj, x1 + 50) end
        if edge then
            close_hits = close_hits + 1
            if close_hits <= 3 then
                log("%s CLOSE FIRE #%d at rel=%d", LABEL, close_hits, frame - phase_start)
            end
        end
        if close_hits >= 3 or frame - phase_start > CLOSE_FRAMES then finish(); return end
    end

    if frame > 20000 then log("%s ERROR global timeout", LABEL); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
