-- uppercut_freeze_camera.lua
--
-- "Uppercut an air-frozen victim and the camera misbehaves."
--
-- camera_scroll_probe.lua already cleared the y-scroll controller itself: a
-- fighter parked anywhere in or above the barrier band settles worldtly on a
-- stable value, no hunting, at every height tested.  So the fault is not the
-- scroll limit arithmetic.  Something ELSE must be writing worldtly.
--
-- Only three things ever move worldtly:
--     * MKDISP display loop   worldtly += scrolly     (the actual scroll)
--     * BGND scrl8            snap to ceiling_y       (the clamp)
--     * MKFX es_sub           the screen shake, +/- N px every 3 ticks
--
-- So account for every frame: predicted delta is last frame's scrolly.  Any
-- delta that is NOT that is an outside writer, and it gets named and measured.
-- That turns "the camera misbehaves" into a ledger.
--
-- Trials:
--   grounded   uppercut a standing victim.  Control: the same uppercut and the
--              same shake, with nobody near the scroll barrier.
--   airfrozen  victim jumps, gets air-frozen, then eats the uppercut while
--              hanging up there -- the reported case.
--
-- Env: UCFC_LOG
-- Usage: tools/run_uppercut_freeze_camera.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("UCFC_LOG") or (ROOT .. "/tools/uppercut_freeze_camera.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[ucfc] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state",
                     "p2_state", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view",
                     "winner_status", "battle_num", "map_position",
                     "worldtly", "scrolly", "ceiling_y", "ground_y",
                     "f_freeze_timer" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s - results are worthless", n) end
end

local OXVAL, OYPOS = 0x080, 0x0b0
local P_ACTION = 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_THROW_ICE, ACT_FROZEN = 0x0010, 0x0401

local TRIALS = { "grounded", "airfrozen" }
local TRIAL_FRAMES = 420
local WATCH = 170                   -- frames of ledger after the uppercut lands

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial, trial_start = 1, 0
local ceiling_y, floor_y = 0, 0
local fields, results, done = {}, {}, false

-- per-trial state
local st = nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end
local function pact(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + P_ACTION) end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function getx(p) local o = r32(p); if o == 0 then return nil end return (r32(o + OXVAL) >> 16) & 0xffff end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end
local function wtly() return s32(r32(A.worldtly)) end          -- 16.16
local function px(v) return v / 65536.0 end

local function new_state()
    return { phase = "setup", jumped = 0, iced = 0, froze = 0, uppercut = 0,
             hit = 0, prev_w = nil, prev_sc = 0, ledger = {}, outside = {},
             wmin = 1e9, wmax = -1e9, froze_y = nil, watching = 0 }
end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P1 Low Punch"] = true, ["P1 Right"] = true, ["P1 Down"] = true,
                   ["P2 Up"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input field %s", n) end end
end

-- Inputs are driven off measured game state, not a fixed script: the victim
-- has to actually be airborne before the ice goes out, and actually frozen
-- before the uppercut does.
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 1000 and (frame % 80) < 20
        end
        if name == "1 Player Start"  then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 then
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
            if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
        end
        return false
    end
    if not st then return false end
    local r = frame - trial_start

    if TRIALS[trial] == "airfrozen" then
        -- jump
        if name == "P2 Up" and st.jumped == 0 then return r >= 30 and r < 38 end
        -- D,F+LP once he is off the ground
        if st.jumped > 0 and st.froze == 0 then
            local j = frame - st.jumped
            if name == "P1 Down"      then return j >= 0 and j < 8 end
            if name == "P1 Right"     then return j >= 8 and j < 16 end
            if name == "P1 Low Punch" then return j >= 14 and j < 20 end
        end
        -- uppercut, but only once he is actually frozen
        if st.froze > 0 then
            local u = frame - st.froze
            if name == "P1 Down"       then return u >= 6 and u < 26 end
            if name == "P1 High Punch" then return u >= 12 and u < 18 end
        end
        return false
    else
        if name == "P1 Down"       then return r >= 40 and r < 60 end
        if name == "P1 High Punch" then return r >= 46 and r < 52 end
        return false
    end
end

local function summarize(mode, s)
    local n_out, worst, shakes = 0, 0, 0
    for _, o in ipairs(s.outside) do
        n_out = n_out + 1
        if math.abs(o.d) > math.abs(worst) then worst = o.d end
    end
    -- direction reversals in the scroll velocity
    local flips, prev = 0, 0
    for _, e in ipairs(s.ledger) do
        local dir = (e.sc > 0 and 1) or (e.sc < 0 and -1) or 0
        if dir ~= 0 and prev ~= 0 and dir ~= prev then flips = flips + 1 end
        if dir ~= 0 then prev = dir end
    end
    results[mode] = {
        froze = s.froze > 0, froze_y = s.froze_y, hit = s.hit > 0,
        span = (s.wmax > -1e9) and (px(s.wmax) - px(s.wmin)) or 0,
        wmin = s.wmin, wmax = s.wmax,
        outside = n_out, worst = worst, flips = flips,
        frames = #s.ledger,
    }
end

local function finish()
    if done then return end
    done = true
    log("")
    log("ceiling_y=%d  rest barrier=%d  barrier at full scroll-up=%d  scroll-up limit worldtly=%d",
        ceiling_y, ceiling_y + 40, ceiling_y + 24, ceiling_y - 0x10)
    log("")
    for _, k in ipairs(TRIALS) do
        local r = results[k]
        if not r then
            log("RESULT %-10s NO DATA", k)
        else
            log("RESULT %-10s froze=%-3s hit=%-3s camera span=%.1fpx over %d frames, "
                .. "%d scroll-direction flips, %d outside writes (worst %.1fpx)",
                k, r.froze and "yes" or "no", r.hit and "yes" or "no",
                r.span, r.frames, r.flips, r.outside, px(r.worst))
        end
    end
    log("")
    local g, a = results["grounded"], results["airfrozen"]
    if not a or not a.froze then
        log("FAIL rig: the airfrozen trial never froze the victim in the air - "
            .. "nothing below is the reported case")
    elseif not a.hit then
        log("FAIL rig: the frozen victim was never uppercut")
    else
        log("Compare: grounded %d outside writes / %d flips  vs  airfrozen %d / %d",
            g and g.outside or -1, g and g.flips or -1, a.outside, a.flips)
    end
    logfh:close(); manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- uppercut vs an air-frozen victim: who moves the camera? ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_REPTILE); w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING then w16(A.p2_state, 1) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; trial_start = frame; st = new_state()
        ceiling_y = s16(r16(A.ceiling_y))
        floor_y = gety(A.p2_obj) or 0
        log("fight start frame=%d ceiling_y=%d victim standing oypos=%d worldtly=%.1f",
            frame, ceiling_y, floor_y, px(wtly()))
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local mode = TRIALS[trial]
    local r = frame - trial_start
    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    local y2 = gety(A.p2_obj)

    -- keep them in uppercut range; stop steering once the sequence is live so
    -- the reaction physics are the game's own
    if st.uppercut == 0 then
        local x2 = getx(A.p2_obj)
        if x2 then setx(A.p1_obj, x2 - 0x2a) end
    end

    if st.jumped == 0 and y2 and y2 < floor_y - 25 then
        st.jumped = frame
        log("%s: victim airborne at r=%d (oypos %d, %d px up)", mode, r, y2, floor_y - y2)
    end
    if st.iced == 0 and a1 == ACT_THROW_ICE then
        st.iced = frame
        log("%s: ice thrown at r=%d", mode, r)
    end
    if st.froze == 0 and a2 == ACT_FROZEN then
        st.froze = frame; st.froze_y = y2
        log("%s: FROZEN at r=%d, oypos %d (%d px up, barrier %d)",
            mode, r, y2 or -1, floor_y - (y2 or 0), (wtly() >> 16) + 40)
    end
    if st.uppercut == 0 and a1 ~= 0 and st.froze > 0 and (frame - st.froze) >= 12 then
        st.uppercut = frame
    end
    if mode == "grounded" and st.uppercut == 0 and r >= 46 then st.uppercut = frame end

    -- ---------------------------------------------------------------- ledger
    -- MKDISP does worldtly += scrolly once per frame.  Anything else that
    -- changes worldtly is an outside writer: name it and size it.
    local w = wtly()
    local sc = s32(r32(A.scrolly))
    if st.prev_w then
        local delta = w - st.prev_w
        local unexplained = delta - st.prev_sc
        if st.watching > 0 then
            if w < st.wmin then st.wmin = w end
            if w > st.wmax then st.wmax = w end
            st.ledger[#st.ledger + 1] = { w = w, sc = sc }
            if math.abs(unexplained) > 0x2000 then    -- > 1/8 px, i.e. not rounding
                st.outside[#st.outside + 1] = { f = frame, d = unexplained }
                log("  %s r=%-3d OUTSIDE WRITE %+.1fpx -> worldtly %.1f "
                    .. "(scrolly %+.2f, victim oypos %s, barrier %.0f)",
                    mode, r, px(unexplained), px(w), px(sc),
                    tostring(y2), px(w) + 40)
            end
        end
    end
    st.prev_w, st.prev_sc = w, sc

    if st.uppercut > 0 and st.watching == 0 then
        st.watching = 1
        log("%s: uppercut window opens at r=%d (worldtly %.1f)", mode, r, px(w))
    end
    if st.watching > 0 then
        st.watching = st.watching + 1
        if st.hit == 0 and y2 and st.froze_y and y2 < st.froze_y - 4 then
            st.hit = frame
            log("%s: victim launched (oypos %d -> %d)", mode, st.froze_y, y2)
        end
        if mode == "grounded" and st.hit == 0 and y2 and y2 < floor_y - 20 then
            st.hit = frame
            log("%s: victim launched off the ground (oypos %d)", mode, y2)
        end
        if st.watching % 10 == 0 then
            log("  %s r=%-3d worldtly=%7.1f scrolly=%+6.2f victim oypos=%s p1act=%04x p2act=%04x",
                mode, r, px(w), px(sc), tostring(y2), a1, a2)
        end
    end

    if r > TRIAL_FRAMES or (st.watching > WATCH) then
        summarize(mode, st)
        log("---- %s done: froze=%s hit=%s outside writes=%d ----",
            mode, st.froze > 0 and "yes" or "no", st.hit > 0 and "yes" or "no",
            #st.outside)
        trial = trial + 1
        if trial > #TRIALS then finish(); return end
        trial_start = frame; st = new_state()
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
