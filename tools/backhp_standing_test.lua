-- backhp_standing_test.lua
--
-- The back+HP specials must only come out STANDING. Holding down-back and
-- pressing HP means the player wants an uppercut, and before this fix the
-- away-test fired the special instead:
--   * the four we added (Kung Lao / Liu Kang / Cage / Jax) short-circuit on
--     is_stick_away at the TOP of their char_hi_punch handler, before the
--     button table is consulted at all;
--   * Baraka's swipe and Kitana's fan swipe go through joy_power_punch,
--     which joy_stance_loop can still reach while holding down-back because
--     it tests left/right BEFORE down and drops into the walk loop.
--
-- Two phases, both with P1 holding AWAY:
--   STAND  - away only. The special MUST still come out (this is not a
--            "delete the move" fix).
--   CROUCH - away + down. The special must NOT come out, and act_uppercut
--            MUST.
--
-- Both fighters are set to human so no AI interferes.
--
-- Env: BHP_CHAR (ft index for P1), BHP_ACT (expected back+HP act), BHP_LABEL
-- Usage: tools\run_backhp_standing_test.ps1

local CHAR  = tonumber(os.getenv("BHP_CHAR") or "1")
local BHP   = tonumber(os.getenv("BHP_ACT") or "0x010c")
-- Raiden's back+HP is a zap (do_short_lightning -> do_zap), so its action is
-- somewhere in the 001h-016h projectile block rather than one fixed id.
local BHP_HI = tonumber(os.getenv("BHP_ACT_HI") or "0") 
if BHP_HI == 0 then BHP_HI = BHP end
local LABEL = os.getenv("BHP_LABEL") or "liukang"
local LOGP  = os.getenv("BHP_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/backhp_standing_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[bhp] " .. string.format(fmt, ...)
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
    p1_proc = sym("p1_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PS_ACTIVE = 1
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local ACT_UPPERCUT = 0x0107

local PHASE_FRAMES = 1800
local TAP_PERIOD, TAP_ON = 45, 7

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase_idx, phase_start = 1, 0
local phases = { "stand", "crouch" }
local hits = { stand = {bhp=0, up=0}, crouch = {bhp=0, up=0} }
local last_act = -1
local fields = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function finish()
    if done then return end
    done = true
    log("RESULT %s stand: bhp=%d upcut=%d | crouch: bhp=%d upcut=%d",
        LABEL, hits.stand.bhp, hits.stand.up, hits.crouch.bhp, hits.crouch.up)
    local fails = {}
    if hits.stand.bhp == 0 then
        fails[#fails+1] = "standing back+HP never came out - the move is broken, not gated"
    end
    if hits.crouch.bhp > 0 then
        fails[#fails+1] = string.format("back+HP fired %d time(s) while crouching", hits.crouch.bhp)
    end
    if hits.crouch.up == 0 then
        fails[#fails+1] = "down-back+HP never produced an uppercut"
    end
    if #fails == 0 then
        log("PASS %s: back+HP is standing-only, down-back+HP uppercuts", LABEL)
    else
        log("FAIL %s: %s", LABEL, table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["2 Players Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Left"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

-- P1 is pinned to the LEFT of P2, so AWAY = Left.
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    local rel = frame - phase_start
    if name == "P1 Left" then return true end
    if name == "P1 Down" then return phases[phase_idx] == "crouch" end
    if name == "P1 High Punch" then
        -- Let the new stick position take effect before the first tap. Without
        -- this the crouch phase taps HP on its very first frame, while the
        -- fighter is still standing, and scores a legitimate standing back+HP
        -- as a crouch violation.
        if rel < 30 then return false end
        return (rel % TAP_PERIOD) < TAP_ON
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- %s: P1 char=%d, back+HP act=0x%04x..0x%04x ----", LABEL, CHAR, BHP, BHP_HI)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        -- both human: no AI to interfere with the input test
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_ACTIVE)
        w16(A.p1_char, CHAR)
        w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase_start = frame
        log("fight start frame=%d phase=%s", frame, phases[1])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    -- hold the geometry: P1 left, P2 right, in range of the special
    local x1 = objx(A.p1_obj)
    if x1 then pin(A.p2_obj, x1 + 0x50) end

    local p = r32(A.p1_proc)
    local act = (p ~= 0) and r16(p + PROC_ACTION) or 0xffff
    if act ~= last_act then
        local ph = phases[phase_idx]
        -- Settle window: a move started by the PREVIOUS phase's last tap only
        -- sets its action a few frames later, i.e. after the phase counter has
        -- already flipped. Counting it against the new phase blamed the crouch
        -- phase for the stand phase's final back+HP in 5 of 6 characters. Same
        -- window in which taps are suppressed, so nothing real is hidden --
        -- and carry-overs are logged rather than silently dropped.
        local settling = (frame - phase_start) < 30
        local is_bhp = (act >= BHP and act <= BHP_HI)
        if settling then
            if is_bhp or act == ACT_UPPERCUT then
                log("%s %s: (settle) carry-over act=0x%04x ignored", LABEL, ph, act)
            end
        elseif is_bhp then
            hits[ph].bhp = hits[ph].bhp + 1
            log("%s %s: back+HP act=0x%04x (#%d)", LABEL, ph, act, hits[ph].bhp)
        elseif act == ACT_UPPERCUT then
            hits[ph].up = hits[ph].up + 1
            log("%s %s: UPPERCUT (#%d)", LABEL, ph, hits[ph].up)
        end
        last_act = act
    end

    if frame - phase_start > PHASE_FRAMES then
        phase_idx = phase_idx + 1
        if phase_idx > #phases then finish(); return end
        phase_start = frame
        log("---- phase -> %s ----", phases[phase_idx])
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
