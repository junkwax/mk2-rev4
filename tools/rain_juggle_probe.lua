-- rain_juggle_probe.lua
--
-- Can anything be landed on a man juggled by RAIN's LIGHTNING BOLT, and for
-- how long?  The bolt (B,B+HP; r_rain_bolt, MKREACT.ASM) throws him straight
-- up on `flight` (ANIM_ORB_BANGED) and lands him on his back; the question is
-- which ticks of that are hittable, and how far off the ground he is then.
--
-- 2-player game: P1 = Rain (base Scorpion at the select screen, p1_char
-- overwritten at GS_POST), P2 = Jax, idle.  The rig casts the bolt, then
-- throws a ROUNDHOUSE (Back+HK) every RJ_EVERY ticks, snapping Rain to
-- RJ_GAP px away first so range is never the reason a swing missed.  For
-- each attempt it records the victim's height and state and whether his bar
-- moved inside the next RJ_JUDGE ticks.
--
-- It also prints a per-tick trace of the whole juggle: y, his p_action,
-- his p_hit (the string counter dmgscale reads) and both bars.
--
--   RJ_WALK    1 = do NOT teleport Rain in.  He is left at the range he
--              cast from and must WALK to RJ_GAP before he swings - the
--              real question, because the bolt drops the man where he
--              STOOD and a stock roundhouse only reaches ~96 px.
--   RJ_GAP     px between them for each attempt (default 70)
--   RJ_EVERY   ticks between attempts (default 16)
--   RJ_JUDGE   ticks allowed for damage to show (default 14)
--   RJ_LOG     log path       RJ_MAP  a map to read instead of src/mk2.map

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("RJ_LOG") or (ROOT .. "/tools/rain_juggle_probe.log")
local GAP   = tonumber(os.getenv("RJ_GAP") or "70") or 70
local EVERY = tonumber(os.getenv("RJ_EVERY") or "16") or 16
local JUDGE = tonumber(os.getenv("RJ_JUDGE") or "14") or 14
local WALK  = os.getenv("RJ_WALK") == "1"
local CASTGAP = tonumber(os.getenv("RJ_CASTGAP") or "110") or 110

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rj] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("RJ_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local A, missing = {}, false
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj",
                     "p1_proc", "p2_proc", "ground_y", "l_rainbolt" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end

local O_OXPOS, O_OXVAL, O_OYPOS = 0x090, 0x080, 0x0b0
local P_ACTION, P_HIT = 0x1f0, nil
do  -- p_hit is a byte field in the process; read its offset from MAINEQU
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    for line in fh:lines() do
        local v = line:match("^p_hit%s+%.set%s+pdata%+(%x+)h")
        if v then P_HIT = 0x1f0 end     -- only used for a rough trace; see below
    end
    fh:close()
end

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_RAIN, FT_JAX, MAX_HP = 10, 19, 11, 0xa1

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
-- one CAST per trial, then exactly one roundhouse `delay` ticks after the
-- lift.  Spaced past rain_bolt_cool (112) so no cast is refused.
local DELAYS = {}
for s in (os.getenv("RJ_DELAYS") or "4,10,16,22,28"):gmatch("[^,]+") do DELAYS[#DELAYS+1] = tonumber(s) end
local TRIAL_EVERY = 240
local trial, phase, t0 = 0, "idle", 0
local cast_at, lift_at, swing_at, bar_before = 0, 0, 0, 0
local seen_swing, y_at_active, results = false, nil, {}
local walk_ticks = nil

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Left"]=1, ["P1 Right"]=1,
                   ["P1 High Punch"]=1, ["P1 High Kick"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

local function action(sym)
    local p = r32(A[sym]); if p == 0 then return 0 end
    return r16(p + P_ACTION)
end

local function finish()
    done = true
    log("---- attempts ----")
    for _, a in ipairs(attempts) do
        log("  +%3d  y=%4d (%3d off the floor)  his act=%04x  -> %s", a.rel, a.y, a.up,
            a.act, a.hit and ("HIT for " .. a.dmg) or "whiff")
    end
    local hits = 0
    for _, a in ipairs(attempts) do if a.hit then hits = hits + 1 end end
    log("%d of %d roundhouses connected during the juggle", hits, #attempts)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        if missing then finish(); return end
    end
    frame = frame + 1
    local gs = r16(A.gstate)

    if psel == 0 and gs == GS_PSEL then
        psel = frame
        log("select screen at frame %d", frame)
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)
    elseif confirm == 0 then
        local rel = frame - psel
        if gs == GS_PSEL then
            w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and rel > 60 then
            confirm = frame
            for n in pairs(fields) do hold(n, false) end
        end
    else
        if gs == GS_POST then w16(A.p1_char, FT_RAIN); w16(A.p2_char, FT_JAX) end
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= FT_RAIN then log("P1 is not Rain"); finish(); return end
        end
        if fight_at == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        local r = frame - fight_at
        w16(A.p1_bar, MAX_HP)
        for n in pairs(fields) do hold(n, false) end
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o == 0 or p2o == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end
        local y = s16(r16(p2o + O_OYPOS))
        local hisact = action("p2_proc")
        local myact = action("p1_proc")

        -- a trial every TRIAL_EVERY ticks
        if phase == "idle" and r >= 120 and (r - 120) % TRIAL_EVERY == 0 and trial < #DELAYS then
            trial = trial + 1
            phase, t0 = "park", frame
            walk_ticks = nil
            w16(A.p2_bar, MAX_HP)
            log("trial %d: roundhouse %d ticks after the lift", trial, DELAYS[trial])
        end

        if phase == "park" then
            place(p1o, r16(p2o + O_OXPOS) - CASTGAP)  -- cast range
            if frame - t0 > 8 then phase, t0 = "cast", frame end

        elseif phase == "cast" then
            local d = frame - t0
            if d < 4 or (d >= 8 and d < 12) then hold("P1 Left", true) end
            if d >= 13 and d < 17 then hold("P1 High Punch", true) end
            if d > 20 then phase, t0, lift_at = "wait", frame, 0 end

        elseif phase == "wait" then                  -- until the bolt lifts him
            if y < 60 then
                lift_at = frame
                phase, t0 = "delay", frame
                log("  lifted at +%d after the cast (y=%d)", frame - t0, y)
            elseif frame - t0 > 140 then
                log("  trial %d: the bolt never landed", trial)
                results[#results+1] = { d = DELAYS[trial], swung = false, dmg = 0, y = 0 }
                phase = "cool"; t0 = frame
            end

        elseif phase == "delay" then
            local away = r16(p2o + O_OXPOS) - r16(p1o + O_OXPOS)
            if WALK then
                -- no teleport: walk in from the range he cast at, the way a
                -- player has to.  Swing as soon as he is inside GAP.
                if away > GAP then
                    hold("P1 Right", true)
                    if frame - t0 > 90 then
                        log("  trial %d: still %d px away after 90 ticks - never got in range",
                            trial, away)
                        results[#results+1] = { d = DELAYS[trial], swung = false, dmg = 0, y = y,
                                                walk = frame - t0, away = away }
                        phase, t0 = "cool", frame
                    end
                else
                    log("  walked in to %d px in %d ticks", away, frame - t0)
                    walk_ticks = frame - t0
                    bar_before = r16(A.p2_bar)
                    seen_swing, y_at_active = false, nil
                    phase, t0 = "swing", frame
                end
            elseif frame - t0 >= DELAYS[trial] then
                place(p1o, r16(p2o + O_OXPOS) - GAP)  -- in range, so reach is not the answer
                bar_before = r16(A.p2_bar)
                seen_swing, y_at_active = false, nil
                phase, t0 = "swing", frame
            end

        elseif phase == "swing" then
            local d = frame - t0
            if d < 10 then hold("P1 Left", true) end
            if d >= 2 and d < 6 then hold("P1 High Kick", true) end
            if myact == 0x105 then
                if not seen_swing then seen_swing = true end
                if not y_at_active then y_at_active = y end
            end
            if d % 3 == 0 and d <= 30 then
                log("    +%2d y=%4d his=%04x mine=%04x bar=%d", d, y, hisact, myact, r16(A.p2_bar))
            end
            if d >= 34 then
                local dmg = bar_before - r16(A.p2_bar)
                results[#results+1] = { d = DELAYS[trial], swung = seen_swing, dmg = dmg,
                                        y = y_at_active or y, walk = walk_ticks }
                log("  trial %d: swung=%s dmg=%d (victim y at the swing = %s)", trial,
                    tostring(seen_swing), dmg, tostring(y_at_active))
                phase, t0 = "cool", frame
            end

        elseif phase == "cool" then
            w16(A.p2_bar, MAX_HP)
            if frame - t0 > 60 then phase = "idle" end
        end

        if trial >= #DELAYS and phase == "idle" then
            log("---- results (victim standing y = 77, floor = 216) ----")
            local hits = 0
            for _, x in ipairs(results) do
                log("  %2d ticks after the lift: swung=%s  y=%4d  dmg=%d%s", x.d,
                    tostring(x.swung), x.y, x.dmg,
                    x.walk and string.format("  (walked in in %d ticks)", x.walk)
                        or (x.away and string.format("  (stuck %d px away)", x.away) or ""))
                if x.dmg > 0 then hits = hits + 1 end
            end
            log("%d of %d timed roundhouses connected in the air", hits, #results)
            finish(); return
        end

        if r > 4000 then log("ran out of time"); finish(); return end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 12000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
