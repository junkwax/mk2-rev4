-- rain_zap_aim_probe.lua
--
-- The two things added to RAIN's water move:
--
--   rzap_aim   (MKZAP.ASM) - the thrower's up/down steers the cloud in
--              flight, the forceball's own nudge and ceiling
--   rzap_slosh (MKZAP.ASM) - the cloud WOBBLES, an `oscale` law of its own:
--              one big displacement when it is flung, then a damped
--              oscillation that settles to a small residual ripple
--
-- Both are measured off the cloud OBJECT, not off the victim: the thrower's
-- process carries it in `p_slave` (get_proj_obj_m parks it there), so the
-- probe reads that pointer once the cast is away and then samples the
-- object's own `oyvel`, `oypos` and `oscale` every tick.
--
-- Trials, each one cast from the same spot at the same range:
--
--   flat   no stick during the flight   -> oyvel stays 0, it flies level
--   up     Up held                      -> oyvel goes NEGATIVE, it climbs,
--                                          and |oyvel| stops at the ceiling
--   down   Down held                    -> oyvel goes POSITIVE, it dives
--
-- The ceiling is the point of the test as much as the steer is: an uncapped
-- nudge stacks for the whole flight, which is what made the forceball
-- unaimable before orb_aim_ymax existed.  RZ_YMAX is read from MAINEQU so
-- the probe cannot drift from the source.
--
-- The slosh is judged on the SEQUENCE of oscale values, not on "it changed":
-- the first pose must be the flat-and-wide fling (ystep > xstep), the
-- oscillation must cross 1:1 both ways, and the late ripple must be SMALLER
-- than the opening displacement - that decay is the whole difference from
-- Reptile's endless throb.
--
--   RZA_LOG  log path       RZA_MAP  a map to read instead of src/mk2.map

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("RZA_LOG") or (ROOT .. "/tools/rain_zap_aim_probe.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rza] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

-- the ceiling, read from the source so this cannot drift
local YMAX
do
    local fh = assert(io.open(ROOT .. "/src/MAINEQU.ASM", "r"))
    for line in fh:lines() do
        local v = line:match("^rzap_aim_ymax%s+%.set%s+0?(%x+)h")
        if v then YMAX = tonumber(v, 16) end
    end
    fh:close()
end
if not YMAX then log("FATAL: rzap_aim_ymax not found in MAINEQU.ASM"); YMAX = 0x30000 end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("RZA_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local A, missing = {}, false
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj",
                     "p1_proc", "p2_proc", "objlst", "objlst2", "objlst3" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end

local O_OXPOS, O_OXVAL, O_OYPOS = 0x090, 0x080, 0x0b0
local O_OYVEL, O_OSCALE, O_OXVEL, O_OPAL = 0x060, 0x180, 0x040, 0x140
-- colour RAM: slot s, entry i is at 0x01800000 + s*0x1000 + i*16
local CRAM = 0x01800000
-- the cycled window, read from MAINEQU so the probe cannot drift from it
local CYC_START, CYC_COUNT = 5, 16
do
    local fh = assert(io.open(ROOT .. "/src/MAINEQU.ASM", "r"))
    for line in fh:lines() do
        local a = line:match("^rzap_cyc_start%s+%.set%s+(%d+)")
        local b = line:match("^rzap_cyc_count%s+%.set%s+(%d+)")
        if a then CYC_START = tonumber(a) end
        if b then CYC_COUNT = tonumber(b) end
    end
    fh:close()
end
local P_ACTION, P_SLAVE = 0x1f0, 0x090 + 0x100   -- pdata+090h, and pdata is 100h
-- (p_action = pdata+0f0h = 1f0h is the check that pdata really is 100h)
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_RAIN, FT_JAX, MAX_HP = 10, 19, 11, 0xa1

-- stick = what P1 holds during the flight; dy = which way it must go
local TRIALS = {
    { label = "flat", stick = nil,         want = "level" },
    { label = "up",   stick = "P1 Up",     want = "climb" },
    { label = "down", stick = "P1 Down",   want = "dive"  },
}

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local trial, phase, t0, cur = 0, "idle", 0, nil
local results = {}
local TRIAL_EVERY = 260

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Left"]=1, ["P1 Right"]=1,
                   ["P1 Up"]=1, ["P1 Down"]=1, ["P1 High Punch"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x); w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

-- The cloud, found by WALKING THE OBJECT LISTS.
--
-- p_slave looked like the handle - get_proj_obj_m parks the projectile
-- there - but it is the THROWER's slot and `back_to_normal` calls
-- delete_slave, so it is back to 0 long before the cloud lands.  Reading it
-- gave 0 on every sample while the move was plainly working (Rain was in
-- act_rain_hold 030ch).
--
-- The discriminator is motion: during the flight the only object that is
-- neither fighter and is travelling at the cloud's own speed IS the cloud.
-- rain_zap_vel is 0a0000h = 10 px/tick; nothing else on screen moves like
-- that while one is in the air.
local O_OLINK = 0x000
local CLOUD_MIN_VEL = 0x80000          -- 8 px/tick

local function cloud()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    for _, listsym in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if listsym and listsym ~= 0 then
            local obj, guard, seen = r32(listsym), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then break end
                seen[obj] = true
                if obj ~= p1o and obj ~= p2o then
                    local xv = s32(r32(obj + O_OXVEL))
                    if xv < 0 then xv = -xv end
                    if xv >= CLOUD_MIN_VEL then return obj end
                end
                obj = r32(obj + O_OLINK)
                guard = guard + 1
            end
        end
    end
    return 0
end

local function finish()
    done = true
    log("---- results (ceiling rzap_aim_ymax = 0x%x = %d px/tick) ----", YMAX, YMAX >> 16)
    local fails = 0
    for _, x in ipairs(results) do
        local ok, why
        if not x.saw then
            ok, why = false, "NEVER FOUND THE CLOUD - this trial measured nothing"
        elseif x.want == "level" then
            ok = (x.ymin == 0 and x.ymax == 0)
            why = string.format("oyvel stayed %d..%d (want 0..0), dy=%d", x.ymin, x.ymax, x.dy)
        elseif x.want == "climb" then
            ok = (x.ymin < 0) and (x.dy < -8) and (x.ymin >= -YMAX)
            why = string.format("oyvel fell to %d (%.2f px/tick), climbed %d px, capped at -%d %s",
                x.ymin, x.ymin / 65536, -x.dy, YMAX >> 16,
                x.ymin >= -YMAX and "(within)" or "(OVER THE CAP)")
        else
            ok = (x.ymax > 0) and (x.dy > 8) and (x.ymax <= YMAX)
            why = string.format("oyvel rose to %d (%.2f px/tick), dived %d px, capped at %d %s",
                x.ymax, x.ymax / 65536, x.dy, YMAX >> 16,
                x.ymax <= YMAX and "(within)" or "(OVER THE CAP)")
        end
        if not ok then fails = fails + 1 end
        log("  %-5s %s  %s", x.label, why, ok and "OK" or "FAIL")
    end
    -- the slosh, from the poses seen on the level trial
    local flat = results[1]
    if flat and flat.poses and #flat.poses == 1 and flat.poses[1] == 0x01000100 then
        log("  shape RIGID: oscale stayed %08x all flight (rzapslosh is off) OK",
            flat.poses[1])
    elseif flat and flat.poses and #flat.poses >= 4 then
        -- The FIRST sample is the tick the cloud gets its velocity, which
        -- is before rzap_slosh's first step has run, so it is still 1:1.
        -- The fling must show up in the first few poses, not literally first.
        local fy, fx = 0, 0
        local opened_wide = false
        for i = 1, math.min(3, #flat.poses) do
            local y, x = flat.poses[i] >> 16, flat.poses[i] & 0xffff
            if y > x then opened_wide = true; fy, fx = y, x; break end
        end
        if fy == 0 then fy, fx = flat.poses[1] >> 16, flat.poses[1] & 0xffff end
        -- biggest deviation early vs late
        local function dev(v) local y, x = v >> 16, v & 0xffff
            local a, b = math.abs(y - 0x100), math.abs(x - 0x100); return a > b and a or b end
        local early, late = 0, 0
        for i, v in ipairs(flat.poses) do
            local d = dev(v)
            if i <= 6 then if d > early then early = d end
            elseif d > late then late = d end
        end
        local crossed_both = false
        do
            local hi, lo = false, false
            for _, v in ipairs(flat.poses) do
                if (v >> 16) > 0x100 then hi = true end
                if (v >> 16) < 0x100 then lo = true end
            end
            crossed_both = hi and lo
        end
        local ok = opened_wide and crossed_both and (late < early)
        if not ok then fails = fails + 1 end
        log("  slosh %d distinct poses; opens %s (ystep %04x vs xstep %04x), crosses 1:1 both ways=%s, "
            .. "deviation early %d -> late %d %s",
            #flat.poses, opened_wide and "FLAT+WIDE" or "NOT flat+wide", fy, fx,
            tostring(crossed_both), early, late, ok and "OK" or "FAIL")
    else
        fails = fails + 1
        log("  slosh: NO VERDICT - too few poses sampled (%d)",
            flat and flat.poses and #flat.poses or 0)
    end
    local f2 = results[1]
    if f2 and f2.pals and #f2.pals >= 1 then
        local first = f2.pals[1]
        local sorted_first = {}
        for _, v in ipairs(first) do sorted_first[#sorted_first+1] = v end
        table.sort(sorted_first)
        local all_rotations = true
        for _, l in ipairs(f2.pals) do
            local s = {}
            for _, v in ipairs(l) do s[#s+1] = v end
            table.sort(s)
            for i = 1, #s do
                if s[i] ~= sorted_first[i] then all_rotations = false end
            end
        end
        local ok = (#f2.pals >= 3) and all_rotations
        if not ok then fails = fails + 1 end
        log("  cycle slot %d, window %d..%d: %d distinct arrangements, every one a "
            .. "rotation of the same colours=%s %s", f2.pal_slot or -1, CYC_START,
            CYC_START + CYC_COUNT - 1, #f2.pals, tostring(all_rotations),
            ok and "OK" or "FAIL")
    else
        fails = fails + 1
        log("  cycle: NO VERDICT - never read the cloud's palette")
    end
    log("%s water cloud steers, flows, and holds its shape (failures=%d)",
        fails == 0 and "PASS" or "FAIL", fails)
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
            log("fight live at %d: p1_char=%d", frame, r16(A.p1_char))
            if r16(A.p1_char) ~= FT_RAIN then log("P1 is not Rain"); finish(); return end
        end
        if fight_at == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        local r = frame - fight_at
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        for n in pairs(fields) do hold(n, false) end
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o == 0 or p2o == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        if phase == "idle" and r >= 120 and (r - 120) % TRIAL_EVERY == 0 and trial < #TRIALS then
            trial = trial + 1
            local T = TRIALS[trial]
            cur = { label = T.label, stick = T.stick, want = T.want,
                    ymin = 0, ymax = 0, poses = {}, seen = {}, saw = false }
            phase, t0 = "park", frame
            log("trial %d (%s): %s", trial, T.label, T.stick or "no stick")

        elseif phase == "park" then
            -- far apart, so the cloud has a long flight to be steered over
            place(p1o, s16(r16(p2o + O_OXPOS)) - 160)
            if frame - t0 > 6 then phase, t0 = "cast", frame end

        elseif phase == "cast" then
            -- Down, RELEASE, Forward, then High Punch - rain_zap_test.lua's
            -- own timing.  The first version of this held Down and Forward
            -- together and the move never came out; the release matters.
            local d = frame - t0
            if d >= 0 and d < 4 then hold("P1 Down", true) end
            if d >= 6 and d < 10 then hold("P1 Right", true) end
            if d >= 11 and d < 16 then hold("P1 High Punch", true) end
            -- go straight to sampling on the punch.  Waiting for the input
            -- window to finish missed the whole flight: the cloud is 10
            -- px/tick, so from 160 px it had already CAUGHT him (p1act
            -- 030c = act_rain_hold) and p_slave was back to 0 before the
            -- first sample.
            if d >= 16 then phase, t0 = "fly", frame end

        elseif phase == "fly" then
            local d = frame - t0
            if cur.stick then hold(cur.stick, true) end
            -- Keep the victim out of its way EVERY tick, not only once the
            -- cloud has been found: doing it conditionally let him be caught
            -- in the ticks before the walker first saw it, and a caught
            -- cloud is consumed - which read as "never found the cloud".
            place(p2o, s16(r16(p1o + O_OXPOS)) - 300)
            local c = cloud()
            if d % 4 == 0 and d <= 48 then
                local pp = r32(A.p1_proc)
                log("    +%2d p1act=%04x p_slave=%08x", d,
                    pp ~= 0 and r16(pp + P_ACTION) or 0xffff, c)
            end
            if c ~= 0 then
                local yv = s32(r32(c + O_OYVEL))
                local yp = s16(r16(c + O_OYPOS))
                local sc = r32(c + O_OSCALE)
                if not cur.saw then
                    cur.saw = true; cur.y0 = yp
                    log("  cloud at +%d: y=%d oscale=%08x", d, yp, sc)
                end
                if yv < cur.ymin then cur.ymin = yv end
                if yv > cur.ymax then cur.ymax = yv end
                cur.ylast = yp
                if not cur.seen[sc] then
                    cur.seen[sc] = true
                    cur.poses[#cur.poses+1] = sc
                end
                local opal = r16(c + O_OPAL)
                local slot = (opal >> 8) & 0xff
                if slot ~= 0 then
                    local key, list = "", {}
                    for i = 0, CYC_COUNT - 1 do
                        local v = r16(CRAM + slot * 0x1000 + (CYC_START + i) * 16)
                        list[#list+1] = v
                        key = key .. string.format("%04x", v)
                    end
                    cur.pal_slot = slot
                    if not cur.palseen then cur.palseen = {}; cur.pals = {} end
                    if not cur.palseen[key] then
                        cur.palseen[key] = true
                        cur.pals[#cur.pals+1] = list
                    end
                end
            end
            if d >= 55 then
                cur.dy = (cur.ylast or cur.y0 or 0) - (cur.y0 or 0)
                log("  %s: oyvel %d..%d, y %d -> %d (%+d), %d distinct oscale poses",
                    cur.label, cur.ymin, cur.ymax, cur.y0 or 0, cur.ylast or 0, cur.dy or 0,
                    #cur.poses)
                results[#results+1] = cur
                phase, t0 = "cool", frame
            end

        elseif phase == "cool" then
            if frame - t0 > 60 then phase = "idle" end
        end

        if trial >= #TRIALS and phase == "idle" then finish(); return end
        if r > 3000 then log("ran out of time"); finish(); return end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 14000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
