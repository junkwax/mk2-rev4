-- rain_zap_combo_test.lua
--
-- "RAIN'S PROJECTILE MOVE DOESN'T HOLD A COMBO WHEN THE OPPONENT IS STILL IN
-- THE AIR" (reported 2026-10-01).  The cloud DOES catch an airborne man and
-- DOES hold him - what broke was the KOMBO KOUNTER's clock underneath him.
--
-- cmb_tick (MKDISP.ASM) is hudcmb_hold = 40h = 64 ticks and only a HIT
-- re-arms it; r_rain_zap holds the victim for 6 half-shakes at 3 ticks plus 2
-- at 7 = 64 ticks, so the window closed with the man still hanging in the
-- cloud and the next hit opened a fresh string.  cmb_holding already exists to
-- pause the clock for exactly this - the freeze, the spear, the puddle, Jax's
-- elbow - and act_rain_storm was simply not in cmb_holds.
--
-- THE MEASUREMENT IS cmb_tick ITSELF: it must not move while the victim is in
-- act_rain_storm, and it must move again once he is out.
--
--   aircombo  two Low Kicks (a real 2-hit string, so the readout exists), the
--             victim pinned off the floor, then D,F+HP - the cloud catches him
--             in the air as hit 3.  Must: cmb_hits >= 3, cmb_tick frozen for
--             the whole hold, and cmb_tick running again after the release.
--   pinnedair THE CONTROL, and the one that makes the pause specific: the same
--             two kicks and the same pinned airborne victim, NO cloud.  He
--             hangs there in plain act_reacting and the clock must run all the
--             way to 0.  Without this, "frozen" could just mean the clock
--             never runs for a man off the ground.
--
-- THREE RIG TRAPS THIS HIT FIRST, all of which read as "the combo broke":
--   * at the cloud's own throwing range a Low Kick does not reach, so the
--     cloud was the OPENING hit of its string.  The pair is parked at kick
--     range for the kicks and P1 teleported out before the cast.
--   * below hudcmb_min (2 hits) cmb_fly is never created, and cmb_fly is what
--     DECREMENTS cmb_tick - so a 1-hit string leaves the clock sitting at 64
--     forever and a probe reads that as a perfect pause.
--   * p_hit returns to 0 the moment the victim recovers (back_to_normal), and
--     hud_combo_hit calls p_hit == 0 a NEW string whatever the clock says.  So
--     the setup hits only chain while he is still in a reaction, which is what
--     pinning him off the floor is for: reaction_exit sends an airborne man to
--     fall_on_my_back, and he cannot land to end the string.
--
--   RZC_LOG    log file path
--   RZC_MAP    the mk2.map belonging to -rompath's zip
--   RZC_STAGE  force a curback

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("RZC_LOG") or (ROOT .. "/tools/rain_zap_combo_test.log")
local STAGE = tonumber(os.getenv("RZC_STAGE") or "")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[rzcombo] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(os.getenv("RZC_MAP") or (ROOT .. "/src/mk2.map"), "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end

local A = {}
local missing = false
for _, n in ipairs({ "gstate", "diff", "p1_proc", "p2_proc", "p1_char", "p2_char",
                     "p1_bar", "p2_bar", "p1_obj", "p2_obj", "worldtlx", "curback",
                     "winner_status", "cmb_hits", "cmb_tick", "cmb_dmg", "f_kmbcnt",
                     "f_freeze_timer" }) do
    A[n] = symbols[n]
    -- A missing symbol is a NAMED REFUSAL, never a default: every number here is
    -- read at a bit address out of this build's own map, and a nil read as 0
    -- would be reported as a verdict.
    if not A[n] then log("FATAL: symbol '%s' not in mk2.map", n); missing = true end
end

local P_ACTION, P_GANIY, P_HIT = 0x1f0, 0x200, 0x370
local OXPOS, OYPOS, OYVEL = 0x90, 0xb0, 0x60
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_JAX, FT_RAIN, MAX_HP = 10, 11, 19, 0xa1
local ACT_RAIN_STORM = 0x50e
local KICK_GAP, CLOUD_GAP = 58, 150
local LIFT = 24                 -- px off his own floor: airborne by the game's
                                -- own is_he_airborn, and still inside the
                                -- cloud's band (stk_rain_zap is 18 px tall)

-- P1 is the ATTACKER, and hud_combo_hit indexes the cmb_ arrays by the
-- attacker: its a6 is 0 when the VICTIM is p1, and a1 = a6^1.  The victim here
-- is P2, so the attacker's slot is offset 0.
local SLOT = 0

-- d = ticks into the trial.  A Low Kick ties P1 up for ~44 ticks (the kick,
-- then act_ret_kick 060c), so every follow-up is scheduled past that - pressed
-- inside the recovery it is simply dropped and the trial measures nothing.
--
-- THE CLOUD IS HIT 2, off ONE setup kick, and that is deliberate rather than
-- convenient: cmb_fly is not created below hudcmb_min (2 hits) and cmb_fly is
-- what DECREMENTS cmb_tick, so a 1-hit string leaves the clock parked at 64.
-- Three hits would need the cloud inside 64 ticks of the second one, which a
-- 44-tick kick recovery plus a ~33-tick cast does not fit - and a clock that
-- expired before the cloud landed would make it open its own string again.
local K1 = 0
local TELE, MO_D, MO_F, MO_HP = 46, 50, 56, 61
local CTRL_K2 = 50              -- the control needs a real 2-hit string of its
                                -- own, or its clock never runs either

local TESTS = {
    { at = 150, label = "aircombo",  win = 300, cloud = true },
    { at = 520, label = "pinnedair", win = 200, cloud = false },
}
local PARK, RUN_END = 40, 790

local frame, space, finished = 0, nil, false
local fields, st, results = {}, {}, {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local failures = 0
local last_act, last_act2

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function obj_x(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function obj_y(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function set_x(p, x) local o = r32(p); if o ~= 0 then w16(o + OXPOS, x) end end
local function wtlx() return s16(r16(A.worldtlx + 16)) end
local function act_of(pp) local p = r32(pp); if p == 0 then return 0xffff end return r16(p + P_ACTION) end
local function ganiy() local p = r32(A.p2_proc); if p == 0 then return nil end return s16(r16(p + P_GANIY)) end
local function p2_hit() local p = r32(A.p2_proc); if p == 0 then return -1 end return r16(p + P_HIT) & 0xff end
local function cmb(base) return r16(base + SLOT) end

-- Park P1 `gap` px from P2, on whichever side has room.
local function park(gap)
    local p2 = obj_x(A.p2_obj)
    if not p2 then return end
    local left = p2 - gap
    set_x(A.p1_obj, (left > wtlx() + 40) and left or (p2 + gap))
end

local function lift()
    local o, g = r32(A.p2_obj), ganiy()
    if o ~= 0 and g then w16(o + OYPOS, g - LIFT); w32(o + OYVEL, 0) end
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- results ----")
    for _, t in ipairs(TESTS) do log("%-9s %s", t.label, results[t.label] or "NOT REACHED") end
    log("%s reason=%s failures=%d", ok and "PASS" or "FAIL", reason, failures)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["1 Player Start"] = true,
                     ["P1 Right"] = true, ["P1 Left"] = true, ["P1 Down"] = true,
                     ["P1 High Punch"] = true, ["P1 Low Kick"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do if not fields[name] then log("input %-16s MISSING", name) end end
end

local function pressed(name)
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end
    local r = frame - fighting_frame
    for _, t in ipairs(TESTS) do
        local d, s = r - t.at, st[t.label]
        if s and s.facing ~= nil and d >= 0 and d <= t.win then
            local fwd = s.facing and "P1 Right" or "P1 Left"
            if name == "P1 Low Kick" then
                if d >= K1 and d < K1 + 5 then return true end
                if (not t.cloud) and d >= CTRL_K2 and d < CTRL_K2 + 5 then return true end
            end
            if t.cloud then
                if name == "P1 Down" and d >= MO_D and d < MO_D + 4 then return true end
                if name == fwd and d >= MO_F and d < MO_F + 4 then return true end
                if name == "P1 High Punch" and d >= MO_HP and d < MO_HP + 5 then return true end
            end
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("harness loaded")
        if missing then finish(false, "missing_symbols"); return end
    end
    if not space or finished then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_RAIN); w16(A.p2_char, FT_JAX)
        if STAGE then w16(A.curback, STAGE) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d stage=%d kounter=%d",
            r16(A.p1_char), r16(A.p2_char), r16(A.curback), r16(A.f_kmbcnt))
        if r16(A.p1_char) ~= FT_RAIN then finish(false, "p1_char_overwrite_failed"); return end
        -- The KOMBO KOUNTER is the thing under test: an operator switch that
        -- happens to be off reads exactly like "the combo broke".
        if r16(A.f_kmbcnt) == 0 then finish(false, "kombo_kounter_off"); return end
    end

    if fighting_frame == 0 then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    local r = frame - fighting_frame
    if A.diff then w16(A.diff, 0) end
    -- Two trials of 260 frames against a 99-second round is not margin to rely
    -- on: stop the clock the way training mode does.
    w16(A.f_freeze_timer, 1)
    w16(A.p1_bar, MAX_HP)

    local act, act2 = act_of(A.p1_proc), act_of(A.p2_proc)
    if act ~= last_act or act2 ~= last_act2 then
        log("  r=%4d p1act %04x p2act %04x  tick=%d hits=%d dmg=%d p_hit=%d",
            r, act, act2, cmb(A.cmb_tick), cmb(A.cmb_hits), cmb(A.cmb_dmg), p2_hit())
        last_act, last_act2 = act, act2
    end

    local measuring = false
    for _, t in ipairs(TESTS) do
        local d = r - t.at
        if d >= -PARK and d < 0 then
            measuring = true
            park(KICK_GAP)
            w16(A.p2_bar, MAX_HP)
        elseif d == 0 then
            measuring = true
            local p1, p2 = obj_x(A.p1_obj), obj_x(A.p2_obj)
            st[t.label] = { facing = (p1 <= p2), hits_max = 0, held = 0,
                            tick_drop_in_hold = 0, tick_fell_after = false,
                            tick_min = 0x7fff, tick_max = 0 }
            log("%-9s start: p1=%d p2=%d (%s)", t.label, p1, p2,
                (p1 <= p2) and "facing right" or "facing left")
        elseif d > 0 and d <= t.win then
            measuring = true
            local s = st[t.label]
            w16(A.p2_bar, MAX_HP)       -- nobody dies mid-measurement

            -- PIN HIM OFF THE FLOOR.  oyvel 0 with oypos above his ganiy is
            -- airborne by is_he_airborn's own test, which keeps him inside a
            -- reaction (reaction_exit sends an airborne man to fall_on_my_back)
            -- so p_hit survives between the setup kicks - and LIFT keeps him
            -- inside stk_rain_zap's 18 px band.  It stops the instant he is
            -- act_rain_storm: after that r_rain_zap owns his position and
            -- writing it would be driving what is being measured.
            if act2 ~= ACT_RAIN_STORM and s.held == 0 then lift() end

            -- P1 stays at kick range for the two setup hits, then backs off to
            -- throwing range.  At the cloud's own range a Low Kick does not
            -- reach, and the cloud then opens its own string.
            if t.cloud and d >= TELE and d < TELE + 2 then park(CLOUD_GAP) end

            local tk, hits = cmb(A.cmb_tick), cmb(A.cmb_hits)
            if hits > s.hits_max then s.hits_max = hits end
            if tk < s.tick_min then s.tick_min = tk end
            if tk > s.tick_max then s.tick_max = tk end

            if act2 == ACT_RAIN_STORM then
                s.held = s.held + 1
                if not s.tick_at_hold then
                    s.tick_at_hold = tk
                    s.hits_at_hold = hits
                    log("  %s: held at +%d  y=%s ganiy=%s  tick=%d hits=%d p_hit=%d",
                        t.label, d, tostring(obj_y(A.p2_obj)), tostring(ganiy()), tk, hits, p2_hit())
                end
                -- THE MEASUREMENT: the clock must not move while he is held.
                if s.last_in_hold and tk < s.last_in_hold then
                    s.tick_drop_in_hold = s.tick_drop_in_hold + (s.last_in_hold - tk)
                end
                s.last_in_hold = tk
                if s.held % 8 == 1 then
                    log("    %s held +%3d  tick=%d hits=%d dmg=%d p_hit=%d y=%s",
                        t.label, s.held, tk, hits, cmb(A.cmb_dmg), p2_hit(), tostring(obj_y(A.p2_obj)))
                end
            elseif s.tick_at_hold then
                -- ...and it must move again once he is out, or "frozen" proves
                -- nothing: this is the other half of the control.
                if not s.out_at then
                    s.out_at = d
                    s.tick_after = tk
                    log("  %s: released after %d ticks  tick=%d hits=%d", t.label, s.held, tk, hits)
                end
                if s.tick_after and tk < s.tick_after then s.tick_fell_after = true end
            end

            if not t.cloud and s.hits_max >= 2 then
                if d % 16 == 0 then
                    log("    %s +%3d  tick=%d hits=%d p2act=%04x p_hit=%d y=%s",
                        t.label, d, tk, hits, act2, p2_hit(), tostring(obj_y(A.p2_obj)))
                end
            end

            if d == t.win then
                local ok, line
                if t.cloud then
                    local enough = (s.hits_at_hold or 0) >= 2
                    ok = enough and s.held > 40 and s.tick_drop_in_hold == 0 and s.tick_fell_after
                    line = string.format(
                        "%s hits_at_catch=%s max=%d  held=%d ticks  clock_lost_in_hold=%d (want 0)  ran_after=%s",
                        ok and "OK  " or "FAIL", tostring(s.hits_at_hold), s.hits_max, s.held,
                        s.tick_drop_in_hold, tostring(s.tick_fell_after))
                    if s.held == 0 then line = line .. "  [NO VERDICT: never held]" end
                    if not enough and s.held > 0 then
                        line = line .. "  [NO VERDICT: the cloud opened its own string]"
                    end
                else
                    -- A pinned AIRBORNE victim in plain act_reacting must NOT
                    -- pause the clock: that is what makes the pause specific to
                    -- the cloud rather than to being off the ground.
                    ok = s.hits_max >= 2 and s.tick_min == 0
                    line = string.format("%s hits=%d  clock ran %d -> %d (want 0: a pinned airborne victim does NOT pause it)",
                        ok and "OK  " or "FAIL", s.hits_max, s.tick_max, s.tick_min)
                    if s.hits_max < 2 then line = line .. "  [NO VERDICT: never a 2-hit string]" end
                end
                results[t.label] = line
                if not ok then failures = failures + 1 end
                log("%-9s %s", t.label, line)
            end
        end
    end
    if not measuring and r < 700 then w16(A.p2_bar, MAX_HP) end
    if r > RUN_END then
        -- An empty run is a FAILURE, not a pass by omission.
        local reached = 0
        for _, t in ipairs(TESTS) do if results[t.label] then reached = reached + 1 end end
        if reached < #TESTS then finish(false, "trials_not_reached"); return end
        finish(failures == 0, failures == 0 and "clock_pauses_while_held" or "mismatch")
        return
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 5000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
