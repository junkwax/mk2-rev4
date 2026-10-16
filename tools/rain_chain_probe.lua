-- rain_chain_probe.lua
--
-- Does Trilogy's guard actually stop RAIN being looped with his super
-- roundhouse, and does it ever get in the way of an honest one?
--
-- The guard is `rain_rh_due` (MOVES.ASM), Trilogy's MKSTAT.C:1206 line for
-- line: the super is refused only when BOTH the roundhouse is inside
-- `rain_rh_cool` (80 ticks) of his last super AND the other man's `p_hitby`
-- is still `act_rhouse`.  So a SECOND roundhouse thrown quickly at a man who
-- was last hit by one comes out as the stock MK2 kick instead.
--
-- Each trial: land one super, wait `delay` ticks, snap back into range and
-- keep swinging until one LANDS.  What separates the two is DAMAGE - the
-- super is stk_rain_roundh at 14, the stock kick is 00dh at 30 - and the
-- hits are 70+ ticks apart, far outside any string, so dmgscale never
-- muddies it.  The WRAP is only recorded, never judged: rain_rh_scan
-- teleports the victim when he passes a screen EDGE, so whether a super
-- wraps depends on where on screen he was standing, and a run judged on
-- the wrap called three of six trials wrong while damage called six of
-- six right.
--
-- The sweep also answers the question that decides whether the guard
-- matters at all: how long after the first super can the man be hit again?
-- If that is always past 80 ticks, the guard never fires in real play.
--
-- 2-player game: P1 = Rain (base Scorpion at the select screen, p1_char
-- overwritten at GS_POST), P2 = Jax, idle.
--
--   RC_DELAYS  ticks between the two kicks (default 20,40,60,75,100,130)
--   RC_GAP     px between them for each attempt (default 80)
--   RC_LOG     log path       RC_MAP  a map to read instead of src/mk2.map

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("RC_LOG") or (ROOT .. "/tools/rain_chain_probe.log")
local GAP  = tonumber(os.getenv("RC_GAP") or "80") or 80

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rc] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("RC_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local A, missing = {}, false
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj",
                     "p1_proc", "p2_proc", "l_roundh" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end

local O_OXPOS, O_OXVAL = 0x090, 0x080
local P_ACTION = 0x1f0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_RAIN, FT_JAX, MAX_HP = 10, 19, 11, 0xa1
local ACT_RHOUSE = 0x105
local WRAP_PX = 150          -- a one-tick x jump this big is rain_rh_scan
-- What the two kicks are worth, FRESH and SCALED.  A second hit that lands
-- while the first is still the same string is cut to 3/4 by dmgscale
-- (JOY.ASM), so each kick has two legal numbers and 23 is not a third kind
-- of kick - it is the stock 30 scaled.  Super scaled is 11, the same 11 the
-- knee link contributes to its 27.
local DMG = { [30] = "stock", [23] = "stock", [14] = "SUPER", [11] = "SUPER" }
local SCALED = { [23] = true, [11] = true }

local DELAYS = {}
for s in (os.getenv("RC_DELAYS") or "20,40,60,75,100,130"):gmatch("[^,]+") do
    DELAYS[#DELAYS+1] = tonumber(s)
end

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local trial, phase, t0 = 0, "idle", 0
local results, cur = {}, nil
local TRIAL_EVERY = 300

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Left"]=1, ["P1 Right"]=1,
                   ["P1 High Kick"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

local function vx() local o = r32(A.p2_obj); return o ~= 0 and s16(r16(o + O_OXPOS)) or 0 end

-- park P1 on whichever side of Jax keeps him on screen, GAP px away
local function park()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local x2 = s16(r16(p2o + O_OXPOS))
    place(p1o, x2 - GAP)
end

local function finish()
    done = true
    log("---- results (guard: super refused inside 80 ticks IF he was last hit by a roundhouse) ----")
    local bad, judged, blind = 0, 0, 0
    for _, x in ipairs(results) do
        if x.hit2 then
            -- judge on the gap the GUARD saw, not the delay we asked for:
            -- the second kick lands some ticks after we start swinging
            local want = x.gap_ticks > 80 and "SUPER" or "stock"
            local got = DMG[x.dmg2] or ("?" .. x.dmg2)
            local ok = (got == want)
            judged = judged + 1
            if not ok then bad = bad + 1 end
            log("  asked +%3d, landed +%3d after the 1st: %-6s (want %-5s) %s  dmg1=%d dmg2=%d%s wrap=%s",
                x.d, x.gap_ticks, got, want, ok and "OK" or "MISMATCH", x.dmg1 or 0, x.dmg2 or 0,
                SCALED[x.dmg2] and " (dmgscale 3/4)" or "", tostring(x.wrap2 == true))
        else
            blind = blind + 1
            log("  asked +%3d: NO SECOND HIT - he was never hittable again, so this "
                .. "trial tests NOTHING", x.d)
        end
    end
    if judged == 0 then
        log("NO VERDICT: not one second roundhouse landed, so the guard was never "
            .. "exercised.  A man cannot be looped with this move at all.")
    else
        log("%s guard behaves as Trilogy's (judged=%d mismatches=%d, %d trial(s) "
            .. "proved nothing)", bad == 0 and "PASS" or "FAIL", judged, bad, blind)
    end
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
        w16(A.p1_bar, MAX_HP)                    -- Rain never dies
        for n in pairs(fields) do hold(n, false) end
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o == 0 or p2o == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        -- wrap detection runs for the whole trial: rain_rh_scan teleports
        -- him during the FLIGHT, long after the swing phase has moved on
        if cur and phase ~= "idle" and phase ~= "cool" then
            local x = vx()
            if cur.lastx and math.abs(x - cur.lastx) > WRAP_PX then
                if cur.hit2 then cur.wrap2 = true else cur.wrap1 = true end
            end
            cur.lastx = x
        end

        if phase == "idle" and r >= 120 and (r - 120) % TRIAL_EVERY == 0 and trial < #DELAYS then
            trial = trial + 1
            w16(A.p2_bar, MAX_HP)
            cur = { d = DELAYS[trial], lastx = vx(), dmg1 = 0, dmg2 = 0 }
            phase, t0 = "park1", frame
            log("trial %d: second roundhouse %d ticks after the first", trial, cur.d)

        elseif phase == "park1" then
            park()
            if frame - t0 > 6 then
                cur.bar0 = r16(A.p2_bar)
                cur.lastx = vx()
                phase, t0 = "kick1", frame
            end

        elseif phase == "kick1" then
            local d = frame - t0
            if d < 12 then hold("P1 Left", true) end
            if d >= 3 and d < 7 then hold("P1 High Kick", true) end
            local b = r16(A.p2_bar)
            if b < cur.bar0 and not cur.hit1 then
                cur.hit1 = true; cur.hit1_at = frame
                cur.dmg1 = cur.bar0 - b
                log("  1st connected at +%d for %d (wrap=%s)", d, cur.dmg1, tostring(cur.wrap1 == true))
            end
            if cur.hit1 and frame - cur.hit1_at >= cur.d then
                cur.bar1 = r16(A.p2_bar)
                phase, t0 = "hunt", frame
            elseif (not cur.hit1) and d > 90 then
                log("  trial %d: the FIRST roundhouse never landed", trial)
                results[#results+1] = cur
                phase, t0 = "cool", frame
            end

        elseif phase == "hunt" then
            -- The delay is up.  Keep swinging until one LANDS - a kick that
            -- whiffs because he is still airborne or getting up proves
            -- nothing about the guard.  Re-park every tick, because the
            -- first super wrapped him across the screen.
            local d = frame - t0
            park()
            local c = d % 14                     -- a fresh Back+HK every 14
            if c < 12 then hold("P1 Left", true) end
            if c >= 1 and c < 5 then hold("P1 High Kick", true) end
            local b = r16(A.p2_bar)
            if b < cur.bar1 and not cur.hit2 then
                cur.hit2 = true
                cur.hit2_at = frame
                cur.dmg2 = cur.bar1 - b
                cur.gap_ticks = frame - cur.hit1_at   -- what the GUARD sees
                cur.wrapwatch = frame                  -- watch the wrap from here
            end
            if cur.hit2 and frame - cur.hit2_at > 40 then
                log("  2nd landed %d ticks after the 1st: dmg=%d wrap=%s",
                    cur.gap_ticks, cur.dmg2, tostring(cur.wrap2 == true))
                results[#results+1] = cur
                phase, t0 = "cool", frame
            elseif (not cur.hit2) and d > 150 then
                cur.unhittable = true
                log("  he was never hittable again within %d ticks of the 1st (his act=%04x)",
                    d + cur.d, action("p2_proc"))
                results[#results+1] = cur
                phase, t0 = "cool", frame
            end

        elseif phase == "cool" then
            w16(A.p2_bar, MAX_HP)
            if frame - t0 > 80 then phase = "idle" end
        end

        if trial >= #DELAYS and phase == "idle" then finish(); return end
        if r > 4000 then log("ran out of time"); finish(); return end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 14000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
