-- Runtime proof for YOTEIGAI TOR's rain (peak_rain, BGND.ASM).
--
-- A screenshot of rain is almost worthless: 24 thin streaks on a dark sky
-- read as noise whether they are moving, frozen, or all sitting in one
-- place.  Everything below is measured off the live objects on
-- peak_rain_lst over a whole round instead.
--
--   built      24 objects on the list, all m_noscroll, all on ONE colour
--              map (getfpal refcounts by palette id, so a second map means
--              a record lost its PON> binding).
--   falling    every slot's oypos must actually change, and downward.  A
--              frozen drop is what a missed prn_place write looks like.
--   drifting   each drop drifts the way its OWN streak leans.  The art
--              leans 5px left over 16 rows; a mirrored (m_fliph) drop leans
--              right.  The wind changes sides every few seconds, so both
--              must be seen in a round, and a drop drifting AGAINST its own
--              slant (x going up while unflipped, or down while flipped) is
--              a picture of motion pointing somewhere it is not going.
--   recycling  slots must come back to the top.  Without this the storm
--              runs for half a second and the screen is empty for the rest
--              of the round.
--   breaking   DROPHIT1 (12 wide) and DROPHIT2 (16 wide) must both appear.
--              Only the two near tiers splash, so this also proves the
--              tier is being read back out of RAIN_ST correctly.
--   on the deck the splashes must land in the deck's own band, derived from
--              peak_deck_y and worldtly the same way peak_rain derives it -
--              NOT against a fixed screen row, which is exactly the bug
--              that check would be there to catch.
--   pool       objs_free must not collapse.  24 objects is a permanent tax
--              on a 358-block pool that this stage already taxes twice
--              over with 39 railing strips, and object_setup calls ermac 5
--              (a hang) when getobj comes back empty.
--
-- Boot schedule, addressing and the warning-screen dismissal are lifted
-- from tools/peak_stage_test.lua.  All offsets are TMS34010 BIT units.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("RAIN_LOG") or (ROOT .. "/tools/peak_rain_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[rain] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "map_position", "battle_num", "worldtly", "ground_y",
                     "peak_rain_lst", "peak_rain_ram", "ofree", "peak_overload",
                     "qdma_drops", "p1_bar", "p2_bar", "round_num",
                     "battle_num", "p1_wiar", "p2_wiar", "weather_rand" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local ONEXT, OXPOS, OYPOS = 0x00, 0x090, 0x0b0
local OSIZEX, OSIZEY, OPAL, OIMG = 0x120, 0x130, 0x140, 0x1a0
-- SYSEQU.ASM: an image record is isizex/isizey/ianioffx/ianioffy/isag/...
local IANIOFFY = 0x30
local OFLAGS2, M_NOSCROLL = 0x160, 0x0001
local OFLAGS, M_FLIPH = 0x0f0, 0x0010
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_SUBZERO, FT_KANG = 8, 1
local PEAK = 0x18

-- BGND.ASM.  peak_deck_y is the deck's TOP row in world y; rain_deck puts the
-- four tiers 2..30 rows into it.  The deck art itself runs 41 rows deep.
local PEAK_DECK_Y = 247
local RAIN_N = 24
local DROP_W, HIT1_W, HIT2_W = 6, 12, 16
-- peak_rain positions by CONTACT POINT and prn_place subtracts the record's
-- own anipoint to get oypos, so reading the contact point back means adding it
-- again - and it has to come from the RECORD, not from a table here.  The
-- anipoints are not uniform (DROP2 is 17 where the other three are 16, and the
-- two splashes are 11 and 13), so every frame swap moves oypos by the
-- DIFFERENCE on top of that tick's fall.  Inferring it from the sprite width
-- cannot tell DROP2 from DROP1 at all, and reading oypos raw makes a landing
-- frame look like a 21px fall - which is what a stacked-process check reports
-- as a stacked process.

-- peak_weather_roll (BGND.ASM) in Lua.  Deliberately a SECOND implementation
-- rather than a read of some stored flag: the ASM keeps no "is it raining"
-- variable, and the whole netplay claim is that the answer is a pure function
-- of five words of agreed match state.  If these two ever disagree the probe
-- fails, which is the point.
local function weather_roll(battle, p1c, p2c, w1, w2)
    local M = 0xffffffff
    local a = battle & 0xffff
    a = ((a << 5) & M) ~ (p1c & 0xffff)
    a = ((a << 5) & M) ~ (p2c & 0xffff)
    a = ((a << 3) & M) ~ (w1  & 0xffff)
    a = ((a << 3) & M) ~ (w2  & 0xffff)
    a = (a + 0x9E3779B9) & M
    a = a ~ ((a << 13) & M)
    a = a ~ (a >> 17)
    a = a ~ ((a << 5) & M)
    return (a & 0xff) < 86, a & M          -- PEAK_RAIN_ODDS
end

-- RAIN_FORCE=dry exercises the other branch: a dry match must take NO objects
-- and must not wedge.  Default picks a P2 character that makes it rain, so the
-- storm machinery is actually driven.
local WANT_RAIN = (os.getenv("RAIN_FORCE") or "wet") ~= "dry"

local READY_PATH = os.getenv("RAIN_READY") or (ROOT .. "/tools/peak_rain_ready.flag")
local ready_written = false

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local R = {}

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function world(a) return s16(r32(a) >> 16) end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- field report ----")
    for _, k in ipairs({ "curback", "rain_objs", "rain_noscroll", "rain_maps",
                         "moved_slots", "fell_slots", "drift_left", "drift_right", "drift_wrong",
                         "recycles", "hit1_seen", "hit2_seen",
                         "deck_offset_min", "deck_offset_max",
                         "y_min", "y_max", "x_min", "x_max",
                         "objs_free_min", "peak_overload", "qdma_drops",
                         "predicted", "want", "roll_key", "weather_seeded",
                         "max_fall_step", "round2_objs", "round2_free",
                         "round2_max_fall", "rounds_seen", "frames_watched" }) do
        log("  %-20s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
                   ["1 Player Start"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local function objs_free()
    if not A.ofree then return -1 end
    local o, n = r32(A.ofree), 0
    while o ~= 0 and n < 400 do o = r32(o); n = n + 1 end
    return n
end

-- Walk peak_rain_lst.  Keyed by object ADDRESS, not by list position: the
-- list is sorted by ozval and every drop carries the same one, so a slot's
-- position in it is not stable and per-position tracking would report motion
-- that is really just re-ordering.
local function walk_rain()
    local obj, out, guard = r32(A.peak_rain_lst), {}, 0
    while obj ~= 0 and guard < 200 do
        local img = r32(obj + OIMG)
        local aniy = (img ~= 0) and s16(r16(img + IANIOFFY)) or 0
        out[obj] = { x = s16(r16(obj + OXPOS)), y = s16(r16(obj + OYPOS)),
                     w = r16(obj + OSIZEX),     h = r16(obj + OSIZEY),
                     f2 = r16(obj + OFLAGS2),   pal = r16(obj + OPAL),
                     flip = (r16(obj + OFLAGS) & M_FLIPH) ~= 0,
                     -- the contact point: what peak_rain actually advances
                     cy = s16(r16(obj + OYPOS)) + aniy }
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return out, guard
end

local prev = nil
local moved, fell, dleft, dright, dwrong, recycles = {}, {}, 0, 0, 0, 0
local maps, hit1, hit2 = {}, 0, 0
local free_min, watched = 9999, 0
-- play_1_round calls do_a11_background, so peak_calla - and its two `create`s
-- - run once per ROUND, not once per stage.  A second peak_rain driving the
-- same peak_rain_ram would advance every drop twice per tick, so the largest
-- single-frame fall is the detector: tier 0 falls 16, and nothing legitimate
-- can exceed that.  A recycle looks like a huge NEGATIVE step, so only
-- downward moves count.
local max_fall, rounds_seen, round2_at = 0, 1, 0
-- getfpal hands out a CRAM slot, and the palettes are reallocated between
-- rounds, so round 2 legitimately lands on a different map id than round 1.
-- The invariant is per-round: all 24 drops on ONE map at any given moment.
local maps_worst = 0

emu.register_frame_done(function()
    if finished then return end
    frame = frame + 1

    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- YOTEIGAI TOR rain (curback %02xh) ----", PEAK)
    end

    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO)
        -- battle_num and both streaks are pinned below, so the only free input
        -- to the roll is P2's character.  Walk it until the weather matches
        -- what this run is here to test.
        local pick = FT_KANG
        for c = 0, 12 do
            local wet = weather_roll(1, FT_SUBZERO, c, 0, 0)
            if wet == WANT_RAIN then pick = c; break end
        end
        w16(A.p2_char, pick)
        if A.p1_wiar then w16(A.p1_wiar, 0) end
        if A.p2_wiar then w16(A.p2_wiar, 0) end
        w16(A.curback, PEAK)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space then return end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        R.curback = r16(A.curback)
        -- Predict from the LIVE values, not from what was written at select:
        -- whatever the game did to them in between is what the roll saw.
        local wet, key = weather_roll(r16(A.battle_num), r16(A.p1_char),
                                      r16(A.p2_char), r16(A.p1_wiar), r16(A.p2_wiar))
        R.predicted = wet and "rain" or "dry"
        R.roll_key = string.format("%08x", key)
        R.want = WANT_RAIN and "rain" or "dry"
        if A.weather_rand then R.weather_seeded = string.format("%08x", r32(A.weather_rand)) end
        log("fight start f=%d curback=%d worldtly=%d  battle=%d p1c=%d p2c=%d "
            .. "wiar=%d/%d -> %s (wanted %s)",
            frame, R.curback, world(A.worldtly), r16(A.battle_num), r16(A.p1_char),
            r16(A.p2_char), r16(A.p1_wiar), r16(A.p2_wiar), R.predicted, R.want)
        -- peak_overload is a session high-water mark and it is WRITE-ONLY in
        -- game code, so zeroing it here is free and it is the only way to
        -- attribute the number.  Left alone it reports the worst tick since
        -- power-on - character select and the round-start pan both spike it,
        -- and a rain figure read against that is meaningless.
        if A.peak_overload then w16(A.peak_overload, 0) end
        if A.qdma_drops then w16(A.qdma_drops, 0) end
        if R.curback ~= PEAK then finish(false, "curback is not Yoteigai Tor") end
    end
    if fighting_frame == 0 then
        if frame > 4000 then finish(false, "never reached a fight") end
        return
    end

    local since = frame - fighting_frame
    -- Skip the round-start pan: the camera owns worldtly for the first second
    -- and the deck band is not where it settles.
    if since < 80 then return end

    -- Between rounds the list is torn down and the object pool is rebuilt, so
    -- an address seen in round 1 can come back as a different drop in round 2.
    -- Comparing across that boundary invents a fall step of a hundred pixels
    -- and would fail the stacking check on nothing at all.
    if gs ~= GS_FIGHTING then prev = nil; return end

    watched = watched + 1
    local cur = walk_rain()
    -- prev is cleared on every non-fighting frame, so a nil one here means
    -- this is the first sample of a fresh round.  The colour-map set has to be
    -- reset HERE and not at the round-2 transition below, which runs after the
    -- sampling loop and therefore lets round 2's first map join round 1's set
    -- - reporting two maps on a build where each round correctly used one.
    if prev == nil then maps = {} end
    local n = 0
    for obj, o in pairs(cur) do
        n = n + 1
        maps[o.pal] = true
        if o.w == HIT1_W then hit1 = hit1 + 1 end
        if o.w == HIT2_W then hit2 = hit2 + 1 end
        if (o.f2 & M_NOSCROLL) == 0 then R.rain_noscroll = "MISSING" end
        R.y_min = math.min(R.y_min or o.y, o.y)
        R.y_max = math.max(R.y_max or o.y, o.y)
        R.x_min = math.min(R.x_min or o.x, o.x)
        R.x_max = math.max(R.x_max or o.x, o.x)

        -- A splash is the only thing that says where the drop broke.
        --
        -- These objects are m_noscroll, so oypos IS the screen row - do NOT
        -- subtract worldtly from it, which is a double subtraction and reads
        -- as the splashes sitting 30px above the deck.  What has to be
        -- measured is how far into the deck the CONTACT POINT lands, which is
        -- oypos + the record's own aniy against the deck's screen line - and
        -- worldtly has to be sampled NOW, because the whole point of deriving
        -- that line per tick is that it moves when the camera pans.
        if o.w == HIT1_W or o.w == HIT2_W then
            local into = o.cy - (PEAK_DECK_Y - world(A.worldtly))
            R.deck_offset_min = math.min(R.deck_offset_min or into, into)
            R.deck_offset_max = math.max(R.deck_offset_max or into, into)
        end

        local p = prev and prev[obj]
        if p then
            if o.y ~= p.y then moved[obj] = true end
            if o.y > p.y then fell[obj] = true end
            -- A jump of more than a screen upward is a recycle, not a fall.
            local recycled = p.y - o.y > 120
            if recycled then recycles = recycles + 1 end
            -- Drift is judged only on a drop that is still the same drop
            -- (a respawn re-rolls x and takes the current wind) and still a
            -- FALLING streak: on the drop->splash swap oxpos jumps by the
            -- difference of the two records' anipoints, and for a mirrored
            -- drop that jump is to the LEFT without anything having drifted.
            local streak = o.w ~= HIT1_W and o.w ~= HIT2_W and o.w == p.w
            -- A drop recycled off the SIDE edge is often still near the top,
            -- so its y barely jumps; its x does.  Drift is at most 5 px a
            -- tick, so anything past 20 is a respawn, not a drift.
            local respawned = recycled or math.abs(o.x - p.x) > 20
            if not respawned and streak and o.flip == p.flip then
                if not o.flip and o.x < p.x then dleft = dleft + 1 end
                if o.flip and o.x > p.x then dright = dright + 1 end
                if (not o.flip and o.x > p.x) or (o.flip and o.x < p.x) then
                    dwrong = dwrong + 1
                end
            end
            local step = o.cy - p.cy
            if step > 0 and step > max_fall then max_fall = step end
        end
    end
    R.rain_objs = n
    do
        local m = 0
        for _ in pairs(maps) do m = m + 1 end
        if m > maps_worst then maps_worst = m end
    end
    prev = cur

    local free = objs_free()
    if free >= 0 and free < free_min then free_min = free end

    -- Drop P2 to end round 1.  play_1_round runs peak_calla again on the way
    -- into round 2 and the object pool is rebuilt underneath it, so this is
    -- the only window in which a stacked process or a leaked object shows up.
    if since == 500 and rounds_seen == 1 and A.p2_bar then
        w16(A.p2_bar, 0)
        log("round 1 ended deliberately at since=%d", since)
    end
    if rounds_seen == 1 and A.round_num and r16(A.round_num) >= 2 and gs == GS_FIGHTING then
        rounds_seen, round2_at = 2, frame
        max_fall = 0                       -- measure round 2 on its own
        prev = nil                         -- and never against round 1's pool
        log("round 2 f=%d free=%d", frame, objs_free())
    end
    if rounds_seen == 2 and round2_at > 0 and frame - round2_at == 120 then
        R.round2_objs = 0
        for _ in pairs(walk_rain()) do R.round2_objs = R.round2_objs + 1 end
        R.round2_free = objs_free()
        snap("round 2")
    end

    if since == 200 then snap("rain 200") end
    if since == 600 then snap("rain 600") end
    if since == 1000 then snap("rain 1000") end

    if since >= 1400 then
        local mv, fl = 0, 0
        for _ in pairs(moved) do mv = mv + 1 end
        for _ in pairs(fell) do fl = fl + 1 end
        local nmaps = maps_worst
        R.moved_slots, R.fell_slots = mv, fl
        R.drift_left, R.drift_right, R.drift_wrong = dleft, dright, dwrong
        R.recycles = recycles
        R.hit1_seen, R.hit2_seen = hit1, hit2
        R.rain_maps = nmaps
        R.objs_free_min = free_min
        R.frames_watched = watched
        R.rain_noscroll = R.rain_noscroll or "all set"
        R.max_fall_step = max_fall
        R.round2_max_fall = (rounds_seen == 2) and max_fall or nil
        R.rounds_seen = rounds_seen
        if A.peak_overload then R.peak_overload = r16(A.peak_overload) end
        if A.qdma_drops then R.qdma_drops = r16(A.qdma_drops) end
        local bad = {}

        -- The two implementations of peak_weather_roll have to agree, and the
        -- DRY branch is where that can be checked exactly: peak_rain dies
        -- immediately after the roll, so @weather_rand is still the raw key it
        -- was seeded with.  In a wet match the drop respawns have churned it
        -- long before this probe can look.
        if R.predicted ~= R.want then
            bad[#bad+1] = "could not steer the roll to " .. R.want
        end
        if R.predicted == "dry" then
            if R.weather_seeded ~= R.roll_key then
                bad[#bad+1] = string.format("ASM seeded %s, this file's hash says %s "
                    .. "- the two peak_weather_roll implementations disagree",
                    tostring(R.weather_seeded), R.roll_key)
            end
            if R.rain_objs ~= 0 then
                bad[#bad+1] = string.format("dry match still took %d objects", R.rain_objs)
            end
            if rounds_seen < 2 then
                bad[#bad+1] = "dry match never reached round 2"
            end
            finish(#bad == 0, #bad == 0 and "dry match: no storm, no objects, round 2 fine"
                                        or table.concat(bad, ", "))
            return
        end

        if R.rain_objs ~= RAIN_N then
            bad[#bad+1] = string.format("%d objects on the list, expected %d", R.rain_objs, RAIN_N)
        end
        if R.rain_noscroll ~= "all set" then bad[#bad+1] = "a drop is not m_noscroll" end
        if nmaps ~= 1 then
            bad[#bad+1] = string.format("%d colour maps in use, expected 1 (a record "
                .. "lost its PON> binding)", nmaps)
        end
        if mv < RAIN_N then bad[#bad+1] = string.format("only %d of %d slots ever moved", mv, RAIN_N) end
        if fl < RAIN_N then bad[#bad+1] = string.format("only %d of %d slots ever fell", fl, RAIN_N) end
        if dleft == 0 then bad[#bad+1] = "nothing drifted left" end
        if dright == 0 then bad[#bad+1] = "nothing drifted right - the wind never turned" end
        if dwrong > 0 then
            bad[#bad+1] = string.format("%d drop-steps drifted AGAINST their own slant", dwrong)
        end
        if recycles == 0 then bad[#bad+1] = "nothing recycled - the storm runs once and stops" end
        if hit1 == 0 then bad[#bad+1] = "DROPHIT1 never appeared - nothing broke on the deck" end
        if hit2 == 0 then bad[#bad+1] = "DROPHIT2 never appeared - the splash never reached frame 2" end
        -- rain_deck puts the two splashing tiers 20 and 30 rows into the deck,
        -- and the landing test is `y >= line`, so a drop overshoots by up to
        -- its own fall step (16) before it breaks.  Anything outside 15..50 is
        -- the splash detaching from the deck, which is what happens the moment
        -- the line stops being derived from worldtly.
        if not R.deck_offset_min then
            bad[#bad+1] = "no splash ever measured against the deck"
        elseif R.deck_offset_min < 15 or R.deck_offset_max > 50 then
            bad[#bad+1] = string.format("splashes land %d..%d rows into the deck, "
                .. "expected 15..50", R.deck_offset_min, R.deck_offset_max)
        end
        -- 16 is tier 0's fall speed, measured on the CONTACT POINT so a frame
        -- swap's anipoint change is not counted as motion.  Anything above it
        -- means peak_rain_ram is being advanced more than once a tick, i.e. a
        -- second peak_rain is alive - which also means it is writing through
        -- object pointers the pool rebuild has since handed to something else.
        if max_fall > 16 then
            bad[#bad+1] = string.format("largest fall step is %d, over tier 0's 16 - "
                .. "a second peak_rain is running", max_fall)
        end
        if rounds_seen < 2 then
            bad[#bad+1] = "never reached round 2 - the per-round rebuild is unproven"
        elseif R.round2_objs ~= RAIN_N then
            bad[#bad+1] = string.format("round 2 has %d drops, expected %d",
                tostring(R.round2_objs), RAIN_N)
        end
        if free_min < 32 then
            bad[#bad+1] = string.format("object pool down to %d free - ermac 5 territory", free_min)
        end
        finish(#bad == 0, #bad == 0 and "all checks green" or table.concat(bad, ", "))
    end

    if frame > 20000 then finish(false, "backstop") end
end)
