-- dyn_map_probe.lua
--
-- Dump the generated one-player ladder, so the matchup ordering can be checked
-- against the chart instead of taken on trust.
--
-- Forces a character at select, lets the ladder screen build the tower, then
-- reads dyn_map out of RAM and prints it with each opponent's matchup score
-- against the chosen fighter.
--
-- WHAT A CORRECT BUILD LOOKS LIKE, and it is NOT a sorted list. The chart
-- buys a fighter a TIER; the order inside a tier is drawn fresh every game.
-- So the test is two-sided and both sides matter:
--
--   RAMPS  - the back half is harder for you than the front half, and there
--            are few real inversions. Equal scores are not inversions, so a
--            wide flat band (Cage has seven fighters that all score 10) costs
--            nothing here.
--   VARIES - two towers built for the SAME fighter must not come out the
--            same. That is the whole point of the rework and it is the one
--            thing the old sorted build could never do; a run that only
--            checks the ramp would have passed the version this replaced.
--
-- Env: DYNMAP_LOG, DYNMAP_CHAR (ochar), DYNMAP_DIFF, DYNMAP_WATCH

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG = os.getenv("DYNMAP_LOG") or (ROOT .. "/tools/dyn_map_probe.log")
-- "Frames are demonstrably running" flag for tools/mame_dismiss_warning.ps1.
-- It MUST NOT be the log above: Lua opens that with io.open at script load,
-- which happens before a single frame runs, so a dismisser watching the log
-- quits instantly and MAME parks on the red warning screen forever at ~0 CPU.
-- The symptom is a run that logs its header and nothing else -- which is
-- exactly what it looks like when the ROM itself has hung, and that ambiguity
-- is why this file exists.
local READYF = os.getenv("DYNMAP_READY") or (LOG .. ".ready")
os.remove(READYF)
local WANT_CHAR = tonumber(os.getenv("DYNMAP_CHAR") or "5")   -- default Mileena
local WANT_DIFF = tonumber(os.getenv("DYNMAP_DIFF") or "9")

local fh = io.open(LOG, "w")
local function log(f, ...)
    local l = "[dynmap] " .. string.format(f, ...)
    print(l); if fh then fh:write(l, "\n"); fh:flush() end
end

local sym = {}
do
    local m = io.open(ROOT .. "/src/MK2.MAP", "r")
    if m then
        for line in m:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
        end
        m:close()
    end
end
local function S(n) return sym[n] or 0 end

local NAMES = {[0]="kung lao","liu kang","cage","baraka","kitana","mileena","shang",
               "raiden","sub-zero","reptile","scorpion","jax","goro","kahn","smoke","noob","jade"}
local function nm(v)
    if v == 0xffff or v == -1 then return "END" end
    return NAMES[v] or ("?" .. tostring(v))
end

local A = {
    gstate = S("gstate"), p1_char = S("p1_char"), p2_char = S("p2_char"),
    p1_state = S("p1_state"), p2_state = S("p2_state"),
    diff = S("diff"), map_start = S("map_start"), dyn_map = S("dyn_map"),
    matchup_odds = S("matchup_odds"),
    -- the sort's own working arrays: printing the score the ASM actually
    -- stored, next to the score the chart says it should be, is the only way
    -- to tell "the sort is broken" from "the scores never arrived"
    dyn_score = S("dyn_score"), dyn_char = S("dyn_char"),
    -- the band each candidate landed in. Printing it turns "these two
    -- opponents swapped" from a worry into a reading: inside a band it is
    -- the shuffle doing its job, across one it is a soft seam.
    dyn_tier = S("dyn_tier"),
    -- build_dynamic_map's breadcrumb (dynmap_debug .set 1 in MKSEL.ASM).
    -- 1 = entered, 3 = scan done, 4 = sort done, 5 = banded+shuffled,
    -- 6 = built, 7 = declined. Reading 0 means it was never called at all,
    -- which is a completely different bug from declining.
    debug1 = S("debug1"),
    -- @rand AT BUILD TIME. Two identical towers have two completely different
    -- causes and only this tells them apart: MAIN.ASM reseeds @rand at every
    -- ROUND start from battle_num ^ p1_wiar ^ p2_wiar ^ a constant, all of
    -- which are fixed under a scripted rig, so a harness can replay the same
    -- stream forever. Same tower AND same @rand = the seed. Same tower with a
    -- DIFFERENT @rand = the shuffle really is not running.
    rand = S("rand"),
}

local GS_PSEL = 4
local frame, space, cpu, done = 0, nil, nil, false
local fields, charsel, confirm = {}, 0, 0
local last_ms = -1
-- persistence watch: how long to keep checking the built ladder is untouched
-- Keep this BELOW the length of an attract-mode demo game (~2800 frames) or
-- the watch never completes: a new game re-arms it before the window closes
-- and the run ends with no verdict at all.
-- MEASURED, not guessed: in attract mode a tower only LIVES about 575 frames.
-- The demo game starts, the ladder screen builds, the demo ends and the next
-- game start stamps a ROM table back into map_start. A watch longer than that
-- is re-armed before it can ever complete and the run ends with no verdict at
-- all -- which the wrapper then reports as if the script had never loaded.
local WATCH = tonumber(os.getenv("DYNMAP_WATCH") or "400")
-- How many separate towers to see before delivering a verdict. Two is the
-- minimum that can say anything about variance at all.
--
-- This is a COUNT, not a longer WATCH, and that distinction is forced: the
-- watch has to stay shorter than an attract demo game (~2800 frames) or a new
-- game re-arms it before it ever completes and the run ends with no verdict.
-- So the way to see a second tower is to finish the first watch, re-arm on
-- purpose, and let the next demo game build one.
local MIN_BUILDS = tonumber(os.getenv("DYNMAP_BUILDS") or "2")
local snapshot, snap_frame = nil, 0
local verdict_ok, verdict_why = false, "no verdict"
-- Every tower this run has built, as a printable key, so a second build for
-- the same fighter can be compared against the first. Attract mode restarts a
-- demo game every ~2800 frames and each one builds its own tower, which is
-- what makes the variance check free -- see the re-arm path below.
-- char -> { seen = {tower string -> true}, n = how many built for that char }
local towers_by_char, builds, repeats, varied = {}, 0, 0, false
-- Has map_start been seen on a ROM table since the last tower we counted?
--
-- WITHOUT THIS THE PROBE COUNTS EVERY TOWER TWICE. The re-arm that goes
-- looking for a second build clears `snapshot` while map_start is still
-- pointing at dyn_map, so the report block fires again on the SAME unchanged
-- tower and duly announces it as "identical to an earlier one". The signature
-- is unmistakable once you know it: the towers come out in exact pairs,
-- 1=2, 3=4, 5=6, with a different @rand logged for each half of every pair.
-- A build that had genuinely stopped shuffling would make them ALL identical,
-- not pairwise, so read the shape before believing the count.
local fresh_game = true
-- Wedge watch: when did gstate last change, and was it long enough ago to be a
-- hang rather than a slow screen? Attract never sits in one state for
-- thousands of frames on its own.
local last_gs, last_gs_frame, wedge_at, wedge_pc = -1, 0, 0, 0

local function pc_now()
    local ok, v = pcall(function() return cpu.state["PC"].value end)
    return (ok and v) or 0
end

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function odds(row, col)
    if A.matchup_odds == 0 then return nil end
    return r16(A.matchup_odds + ((row * 12 + col) * 16))
end

local function finish(ok, why)
    if done then return end
    done = true
    log("%s %s", ok and "PASS" or "FAIL", why)
    if fh then fh:close(); fh = nil end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
        for _, p in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("dyn_map=0x%x map_start=0x%x matchup_odds=0x%x",
            A.dyn_map, A.map_start, A.matchup_odds)
        if A.dyn_map == 0 then log("FATAL: dyn_map not in MK2.MAP - build did not include it") end
    end
    for n, f in pairs(fields) do
        local on = false
        if charsel == 0 then
            if n == "Coin 1" then on = frame >= 200 and frame < 1000 and (frame % 80) < 20 end
            if n == "1 Player Start" then on = frame >= 1000 and frame < 1080 end
        elseif confirm > 0 and n == "P1 High Punch" then
            on = frame >= confirm and frame < confirm + 45
        end
        f:set_value(on and 1 or 0)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if frame == 120 then
        local rf = io.open(READYF, "w")
        if rf then rf:write("frames running"); rf:close() end
    end
    -- HEARTBEAT. Without one, a run that never reaches character select logs
    -- its header and nothing else, which is indistinguishable from the script
    -- having failed to load at all -- and that ambiguity has cost whole runs.
    -- Say where the machine actually is every few hundred frames.
    if frame % 600 == 0 then
        -- The PC comes along because a wedge at 100%% emulated speed is
        -- indistinguishable from "nothing is happening" from out here: the
        -- heartbeat keeps ticking either way. Feed the value to
        -- `python sym_resolve.py <pc>` and it names the routine.
        local pc = pc_now()
        log("frame %d gstate=%d charsel=%d confirm=%d map_start=0x%x p1_char=%d p1/p2_state=%d/%d stage=%d pc=%x",
            frame, gs, charsel, confirm, r32(A.map_start), r16(A.p1_char),
            r16(A.p1_state), r16(A.p2_state),
            A.debug1 ~= 0 and r16(A.debug1) or -1, pc)
    end
    if gs ~= last_gs then
        last_gs, last_gs_frame, wedge_at = gs, frame, 0
    elseif wedge_at == 0 and frame - last_gs_frame > 3000 then
        wedge_at, wedge_pc = last_gs_frame, pc_now()
        log("WEDGE: gstate has been %d since frame %d (pc=%x)", gs, wedge_at, wedge_pc)
    end

    if gs == GS_PSEL and charsel == 0 then charsel = frame end
    if charsel > 0 and confirm == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 0)
        w16(A.p1_char, WANT_CHAR)
        w16(A.diff, WANT_DIFF)
        if frame - charsel > 90 then confirm = frame end
    elseif gs == GS_PSEL then
        -- KEEP FORCING ON EVERY LATER SELECT TOO. Only the first game here is
        -- the one we drove; every attract demo after it picks its own fighter,
        -- and the variance check needs the SAME fighter twice to have anything
        -- to compare. Left alone, a run collects towers for five different
        -- characters and can say nothing about whether any of them varies.
        w16(A.p1_char, WANT_CHAR)
        w16(A.diff, WANT_DIFF)
    end

    -- WATCH map_start over time instead of sampling it once. init_map_start
    -- runs twice: at game start (before a character exists, so it picks a ROM
    -- table) and again on the ladder screen, which is the one that matters.
    -- A single early sample sees only the first and reports the feature dead.
    if confirm > 0 then
        local ms = r32(A.map_start)
        if ms ~= last_ms then
            log("map_start -> 0x%x %s (frame=%d, gstate=%d)", ms,
                (ms == A.dyn_map) and "= dyn_map" or "= ROM table", frame, gs)
            last_ms = ms
            if ms ~= A.dyn_map then fresh_game = true end
        end
    end
    -- `not snapshot` matters: the verdict is no longer delivered here (the
    -- persistence watch below owns it), so without it this whole block re-runs
    -- and re-prints the ladder every single frame.
    if confirm > 0 and frame > confirm + 240 and not snapshot and not done and fresh_game then
        local ms = r32(A.map_start)
        if ms ~= 0 and A.dyn_map ~= 0 and (ms == A.dyn_map) then
            fresh_game = false          -- do not count this tower a second time
            log("map_start points at dyn_map -- the tower was GENERATED")
            -- SCORE AGAINST THE FIGHTER THE ROM USED, not the one we asked
            -- for. Only the first game here is the forced one; every attract
            -- demo after it picks its own character and builds its own tower,
            -- and those are most of the towers this run sees. Reading them
            -- against WANT_CHAR prints a column of matchups that has nothing
            -- to do with the numbers in dyn_score, which reads as the sort
            -- being broken when it is the report that is wrong.
            --
            -- Mirror build_dynamic_map's own choice exactly (MKSEL.ASM): p1
            -- if p1_state is set, else p2 if p2_state is, else p1 anyway.
            local you = r16(A.p1_char)
            if r16(A.p1_state) == 0 and r16(A.p2_state) ~= 0 then you = r16(A.p2_char) end
            if you ~= WANT_CHAR then
                log("(this tower is an attract demo's, built for %s -- not the forced %s)",
                    nm(you), nm(WANT_CHAR))
            end
            log("you = %s (ochar %d), diff = %d, rand=0x%08x",
                nm(you), you, r16(A.diff), A.rand ~= 0 and r32(A.rand) or 0)
            if A.dyn_score ~= 0 then
                local s, c = {}, {}
                for i = 0, 11 do
                    s[#s + 1] = tostring(r16(A.dyn_score + i * 16))
                    c[#c + 1] = tostring(r16(A.dyn_char + i * 16))
                end
                log("  dyn_score(sorted) = [%s]", table.concat(s, " "))
                log("  dyn_char (sorted) = [%s]", table.concat(c, " "))
            end
            -- SCORE THE TREND, NOT STRICT ORDER. The tower is shuffled
            -- inside each band on purpose, so demanding a non-decreasing
            -- sequence fails a ladder that is working exactly as designed.
            -- What the feature promises is that the back half is harder for
            -- you than the front half; the inversion count is reported
            -- alongside so a shuffle that HAS escaped its band still shows.
            local scores = {}
            for i = 0, 15 do
                local v = r16(A.dyn_map + i * 16)
                if v == 0xffff then log("  %2d. END", i + 1); break end
                local sc = (v <= 11 and you <= 11) and odds(v, you) or nil
                if sc then
                    log("  %2d. %-10s matchup %.1f vs you", i + 1, nm(v), sc / 2)
                    if i < 11 then scores[#scores + 1] = sc end
                else
                    log("  %2d. %-10s (tail)", i + 1, nm(v))
                end
            end
            local n = #scores
            if n < 6 then finish(false, "only " .. n .. " scored entries - not a ladder") return end

            -- The bands, straight out of the ASM's own scratch array. A band
            -- printed here as 7 wide is not a bug: that is seven fighters the
            -- chart says are equally rough for this player, and their order
            -- is supposed to be a draw.
            if A.dyn_tier ~= 0 then
                local tiers, sizes, order = {}, {}, {}
                for i = 0, n - 1 do
                    local t = r16(A.dyn_tier + i * 16)
                    tiers[#tiers + 1] = t
                    if sizes[t] == nil then sizes[t] = 0; order[#order + 1] = t end
                    sizes[t] = sizes[t] + 1
                end
                local parts = {}
                for _, t in ipairs(order) do parts[#parts + 1] = string.format("t%d x%d", t, sizes[t]) end
                log("  bands = %s   (%s)", table.concat(parts, ", "), table.concat(tiers, " "))
            end
            local half, front, back = n // 2, 0, 0
            for i = 1, half do front = front + scores[i] end
            for i = n - half + 1, n do back = back + scores[i] end
            front, back = front / half, back / half
            local inv = 0
            for i = 1, n do for j = i + 1, n do if scores[j] < scores[i] then inv = inv + 1 end end end
            local maxinv = n * (n - 1) / 2
            log("  front-half mean %.1f vs back-half mean %.1f, inversions %d/%d",
                front / 2, back / 2, inv, maxinv)
            -- A random order averages half the possible inversions; a clean
            -- ramp has none. Anything under a third is a real ramp with noise.
            -- PERSISTENCE. The one real risk of moving the ladder out of ROM
            -- and into .bss is that something clobbers it later: the ROM
            -- tables could not be overwritten, dyn_map can. Snapshot it here
            -- and re-check further down; who_is_next and adv3 read this array
            -- for the whole climb, so a single stray write ends the tower.
            snapshot = {}
            for i = 0, 15 do snapshot[i] = r16(A.dyn_map + i * 16) end
            snap_frame = frame
            log("  snapshotted dyn_map; watching it for %d more frames", WATCH)

            -- DOES IT VARY?  Key this tower and compare it against every
            -- tower this run has already built for the same fighter. The old
            -- sorted build produced one fixed climb per character and would
            -- have sailed through the ramp test above, so the ramp alone is
            -- not evidence that this rework did anything at all.
            local key = {}
            for i = 0, 15 do key[#key + 1] = r16(A.dyn_map + i * 16) end
            key = table.concat(key, ",")
            builds = builds + 1
            -- KEYED PER FIGHTER. Two towers built for two different characters
            -- differ for a reason that has nothing to do with the shuffle, so
            -- counting those as variance would pass a build with no shuffle in
            -- it at all. Only a repeat of the SAME fighter is evidence.
            local hist = towers_by_char[you]
            if not hist then hist = { seen = {}, n = 0 }; towers_by_char[you] = hist end
            hist.n = hist.n + 1
            if hist.n > 1 then
                repeats = repeats + 1
                if hist.seen[key] then
                    log("  tower %d for %s is IDENTICAL to an earlier one (compare the rand= above:" ..
                        " same state means the rig replayed one RNG stream, not a dead shuffle)",
                        hist.n, nm(you))
                else
                    varied = true
                    log("  tower %d for %s differs from every earlier one - the draw is live",
                        hist.n, nm(you))
                end
            end
            hist.seen[key] = true

            local ok = (back > front) and (inv <= maxinv / 3)
            verdict_ok = ok
            verdict_why = ok and string.format(
                "ladder ramps: easy half %.1f -> hard half %.1f, %d inversions",
                front / 2, back / 2, inv)
                or string.format(
                "ladder does NOT ramp (front %.1f, back %.1f, %d/%d inversions) - has the shuffle escaped its band?",
                front / 2, back / 2, inv, maxinv)
        elseif frame > confirm + 7000 and builds == 0 then
            -- ONLY WHEN NOTHING HAS EVER BEEN BUILT. After the first tower
            -- this branch is reachable again -- the persistence watch re-arms
            -- on every new game and map_start legitimately sits on a ROM table
            -- between the game start and the ladder screen -- and firing here
            -- then overwrites a run that had already PASSED with a flat
            -- "declined". That is not a near miss: it inverts the result.
            --
            -- Report the inputs the ASM gate actually sees. Guessing which
            -- condition failed cost a build cycle already.
            log("map_start=0x%x is a ROM table, not dyn_map", ms)
            log("  p1_state=%d p2_state=%d p1_char=%d(%s) p2_char=%d(%s) diff=%d",
                r16(A.p1_state), r16(A.p2_state),
                r16(A.p1_char), nm(r16(A.p1_char)),
                r16(A.p2_char), nm(r16(A.p2_char)), r16(A.diff))
            finish(false, "fell back to a ROM map - dynamic build declined")
        end
    end
    -- Watch the snapshot until the window closes, then deliver the verdict.
    if snapshot and not done then
        -- A NEW GAME legitimately gets a new tower: zero_map_ram stamps a ROM
        -- table into map_start at every game start, and the ladder screen then
        -- builds a fresh one. In attract mode that happens every few thousand
        -- frames, so without this the watch reports a rebuild that is entirely
        -- correct. Re-snapshot instead, and only judge changes that happen
        -- while map_start has stayed pointed at dyn_map.
        if r32(A.map_start) ~= A.dyn_map then
            log("new game started (map_start left dyn_map) - re-arming the watch")
            snapshot, snap_frame = nil, 0
            return
        end
        for i = 0, 15 do
            local now = r16(A.dyn_map + i * 16)
            if now ~= snapshot[i] then
                -- Distinguish the two ways this can change, because they are
                -- completely different bugs. A REBUILD means the mountain was
                -- drawn from one tower and the fights come from another (the
                -- photos-do-not-match report). A stray write means .bss is
                -- being trampled. Either way the ladder is wrong, but the fix
                -- is not the same, so say which.
                log("dyn_map CHANGED at frame %d: slot %d was %d, now %d",
                    frame, i + 1, snapshot[i], now)
                finish(false, "the tower changed after it was drawn -- rebuilt mid-game, or clobbered")
                return
            end
        end
        if frame - snap_frame >= WATCH then
            log("dyn_map intact after %d frames (a fight has started and run in that window)", WATCH)
            if repeats < MIN_BUILDS - 1 then
                -- This tower is proven good. Drop the watch and wait for the
                -- next attract game to build another one for the same fighter
                -- to compare it with.
                log("%d tower(s), %d repeat(s) so far - re-arming for another build",
                    builds, repeats)
                snapshot, snap_frame = nil, 0
                return
            end
            -- The variance half of the verdict. With only one build there is
            -- nothing to compare, so say UNPROVEN rather than passing it --
            -- silently counting an untested promise as kept is how the old
            -- version stayed dead for weeks while its probe read green.
            local vtxt
            if repeats == 0 then
                vtxt = string.format(
                    "; variance UNPROVEN (%d towers but no fighter built twice - raise -Backstop)", builds)
            elseif varied then
                vtxt = string.format("; %d towers, %d repeats, and they differ", builds, repeats)
            else
                vtxt = string.format(
                    "; %d towers, %d repeats, ALL IDENTICAL - the in-tier shuffle is not running",
                    builds, repeats)
                verdict_ok = false
            end
            finish(verdict_ok, verdict_why .. "; ladder survived " .. WATCH ..
                   " frames intact" .. vtxt)
        end
    end

    -- SAY WHY IT TIMED OUT. A bare "timeout" is the least useful verdict this
    -- rig can produce: it covers "the tower code is wrong", "attract wedged",
    -- and "not enough frames" equally well, and they are three different days
    -- of work. Name what the machine was actually doing.
    if frame > 20000 then
        if wedge_at > 0 then
            finish(false, string.format(
                "attract WEDGED at frame %d - gstate stuck at %d for %d frames, " ..
                "p1_state=%d p2_state=%d, pc=%x - READ THE NUMBERS: plausible small " ..
                "values mean a stuck process, garbage means RAM was scribbled, and " ..
                "0/0 means a drone-vs-drone demo, which wedges on baseline too",
                wedge_at, r16(A.gstate), frame - wedge_at,
                r16(A.p1_state), r16(A.p2_state), wedge_pc))
        else
            finish(false, string.format("timeout with %d tower(s) built", builds))
        end
    end
end)
emu.register_stop(function() if fh then fh:close(); fh = nil end end)
