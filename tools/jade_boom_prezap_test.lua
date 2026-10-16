-- jade_boom_prezap_test.lua
--
-- Runtime proof for WHERE JADE'S BOOMERANG LEAVES HER HAND, and therefore how
-- close a man can stand and still be hit by it.
--
-- The move had a point-blank hole: a man closer than ~105px could not be hit at
-- all, and the blade was drawn crossing him. The cause was geometry, not
-- collision code. `UBREL4` had been re-anchored here to (-85,-27) as part of a
-- travel path that walked the blade out of her grip through the whole release,
-- so it could not live in the flight loop, and the flight then needed a 112px
-- anchor step to pick that art up - which opened the first strike box at +105
-- with nothing ever testing the span between.
--
-- It is now the arcade's own arrangement (2026-09-27, the user's call - the
-- boomerang should behave as it does in the arcade):
--
--   UBREL4 carries Midway's (25,5), which KITANA7.IMG's BOOMERANG5 and the
--     arcade program ROM agree on, and sits in the FLIGHT loop where UMK3
--     keeps it - a 7-frame revolution, 14 ticks at anirate 2
--   the displacement is `boomerang_adjust`: +72,+32 on the anchor at the
--     release calla (MKANI.C -> jade_boom_release, MKZAP.ASM)
--   so the anchor is on the art, the first strike box opens at +56, and the
--     remaining dead zone is the arcade's own
--
-- UBREL1-3 keep their own anipoints: those ARE fitted to MK2 Jade's arm rather
-- than MK3 Kitana's, and they are within 8px of Midway's anyway.
--
-- WHAT THIS ASSERTS
--
--   1. The release displacement is the arcade's +72,+32. This is the whole
--      change in one number, and it is read off the objects rather than
--      inferred from whether something got hit.
--   2. The flight loop is SEVEN distinct frames. Six means UBREL4 fell out of
--      the lane again and the anchor step is back.
--   3. A man at 72, 104, 130 and 190 px is hit, once each, by the FLYING
--      blade. 72 is the one that matters: under the old geometry it was a
--      clean miss.
--   4. A man at 24 px is NOT hit. That is the arcade's own hole, and it is
--      also the check that the prezap is really compiled out (`jboomclose 0`)
--      - with it on, 24 connects. Flip the equate and this trial is the
--      control for that feature.
--   5. The blade always flies, hit or miss - nothing consumes it at her hand.
--
--   48 px is MEASURED, not asserted. It sits on the boundary (his squeezed
--   column is a quarter of his width, so whether it reaches +65 on the first
--   flight tick is a pixel question), and a rig that asserted it would be
--   claiming precision it does not have. The log prints the whole sweep, which
--   is what tells you where the boundary actually is.
--
-- Damage: a clean hit is >= 15, not == 20. Jade is a hidden fighter and takes
-- the 3/4 secret-fighter scaling, so both numbers are legal and a rig that
-- insisted on 20 would fail on a correct ROM. 3 means he BLOCKED, which is a
-- rig problem (P2 must be pressing nothing), not a pass.
--
-- P2 is HUMAN (2-player start) so he stands still and no drone decision can
-- walk him out of the distance being measured. Jade is not selectable, so P1
-- hovers Kitana through GS_PSEL and p1_char is overwritten during GS_POST -
-- the same trick as jade_boom_arcs_test.lua.
--
-- JADE_PREZAP_TRACE=1 logs every tick of every throw.
--
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_PREZAP_LOG") or (ROOT .. "/tools/jade_boom_prezap_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[prezap] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local TRACE = (os.getenv("JADE_PREZAP_TRACE") or "") ~= ""

-- The arcade's own release displacement (MKANI.C boomerang_adjust:
-- adjust_xy_a5(p_slave, SCX(048h), SCY(020h)) - the UMK3 PS1 source writes
-- arcade values and scales them at compile time, so these literals are the
-- arcade numbers).
local WANT_DX, WANT_DY = 72, 32
local FLIGHT_FRAMES = 7          -- UBREL4 + UBSPIN1-6, the arcade's loop

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                if symbols[name] == nil then symbols[name] = tonumber(addr, 16) end
            end
        end
        fh:close()
    end
end
local function sym(n, d)
    local v = symbols[n]
    if v == nil then log("WARN symbol %s not in mk2.map", n) end
    return v or d
end

local A = {
    gstate  = sym("gstate"),
    p1_obj  = sym("p1_obj"),
    p1_proc = sym("p1_proc"),
    p1_char = sym("p1_char"),
    p1_bar  = sym("p1_bar"),
    p2_obj  = sym("p2_obj"),
    p2_char = sym("p2_char"),
    p2_bar  = sym("p2_bar"),
    objlst  = sym("objlst"),
}

-- object block (bit offsets, DISPEQU.ASM)
local O = { link=0x000, xvel=0x040, yvel=0x060, xval=0x080, xpos=0x090,
            yval=0x0a0, ypos=0x0b0, zval=0x0c0, flags=0x0f0,
            flags2=0x160, img=0x1a0 }
local MP_SAG = 0

local P_ACTION = 0x1f0           -- pdata+0f0h
local ACT_JADE_BOOM = 0x112
local FULL_STRENGTH = 0xa1       -- full_strength, MAINEQU.ASM
local GS_PSEL, GS_FIGHTING, GS_POST = 4, 2, 0x0d
local FT_KITANA, FT_REPTILE, FT_JADE = 4, 9, 16

-- Blade frame SAGs are READ OUT OF src/JADERANG.TBL on every run, never typed
-- here: every SAG in the sidecar shifts whenever data/JADERANG.LOD's pack
-- changes, and a stale window then matches NOTHING, so the rig reports "the
-- blade never appeared" against a perfectly good ROM. That is what the three
-- older boomerang rigs were doing. Only the UB* records count: Jade's own
-- throw poses (JDTHROWBLADE*) live in the same sidecar and are pieces of her
-- multipart object, which is in objlst too.
local SAG_LO, SAG_HI, SAG_NAME = nil, nil, {}
do
    local label
    local fh = io.open(ROOT .. "/src/JADERANG.TBL", "r")
    if fh then
        for line in fh:lines() do
            local l = line:match("^(UB[%w_]*):")
            if l then label = l end
            local sag = line:match("^%s*%.long%s+0(%x+)[Hh]")
            if label and sag then
                local v = tonumber(sag, 16)
                SAG_NAME[v] = label
                if not SAG_LO or v < SAG_LO then SAG_LO = v end
                if not SAG_HI or v > SAG_HI then SAG_HI = v end
                label = nil
            end
        end
        fh:close()
    end
    assert(SAG_LO, "could not read blade SAGs from src/JADERANG.TBL")
    SAG_LO, SAG_HI = SAG_LO - 0x1000, SAG_HI + 0x10000
    log("blade SAG window %08x..%08x (read from JADERANG.TBL)", SAG_LO, SAG_HI)
end

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local last_gs, last_pc, same_pc = -1, nil, 0
local errors, notes = {}, {}
local pin_x = nil

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end
local function s16(v) v = v & 0xffff; return (v >= 0x8000) and (v - 0x10000) or v end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local function fail(msg) errors[#errors+1] = msg; log("FAIL %s", msg) end

-- Trials --------------------------------------------------------------------
-- want: "hit" must connect, "miss" must not, nil is measured and reported.
local TRIALS = {
    { dist=24,  want="miss" },
    { dist=48,  want=nil    },
    { dist=72,  want="hit"  },
    { dist=104, want="hit"  },
    { dist=130, want="hit"  },
    { dist=190, want="hit"  },
}
local FIRST_AT, STRIDE, WINDOW = 150, 190, 110
local SEQ = { {"P1 Left",0,5}, {"P1 Right",7,12}, {"P1 Low Punch",14,20} }

local cur, pending, armed = 0, 1, nil
local samples = {}

local function throw_at(i) return FIRST_AT + (i - 1) * STRIDE end

local function dist_for(rel)
    local d = TRIALS[1].dist
    for i = 1, #TRIALS do
        if rel >= throw_at(i) - 60 then d = TRIALS[i].dist end
    end
    return d
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 200 and frame < 3000 and (frame % 80) < 20 end
    if name == "Coin 2" then return frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40 end
    if name == "2 Players Start" then return frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70 end
    if fighting_frame == 0 then
        if (name == "P1 Low Punch" or name == "P2 Low Punch") and confirm_frame > 0 then
            return frame >= confirm_frame and frame < confirm_frame + 120 and (frame % 20) < 8
        end
        return false
    end
    local rel = frame - fighting_frame
    for i = 1, #TRIALS do
        local d = rel - throw_at(i)
        for _, s in ipairs(SEQ) do
            if name == s[1] and d >= s[2] and d < s[3] then return true end
        end
    end
    return false
end

-- The BLADE: the one MULTIPART object carrying a blade SAG.
--
-- The trail puffs carry blade SAGs too, so they have to be excluded by KIND,
-- not by position. "Furthest downrange" does not do it: a multipart object's
-- oxpos is its ANCHOR while a single-part object's oxpos is its drawn
-- TOP-LEFT, so those two numbers are not on the same reference and a puff
-- dropped on the blade routinely reads as being in front of it. Selecting on
-- position counted all six UBTRAIL frames as flight frames (13 instead of 7)
-- and would have taken the blade's position off a puff.
--
-- Scan the WHOLE list: the trail keeps spawning and each puff goes in at the
-- head, so a short cap walks past the blade and reports it deleted.
local function blade_front()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p, n = r32(A.objlst), 0
    while p ~= 0 and n < 250 do
        if p ~= p1o and p ~= p2o and (r16(p + O.flags2) & 2) ~= 0 then
            local img = r32(p + O.img)
            if img ~= 0 then
                local sag = r32(img + MP_SAG)
                if sag >= SAG_LO and sag < SAG_HI then
                    return s16(r16(p + O.xpos)), s16(r16(p + O.ypos)), sag
                end
            end
        end
        p = r32(p + O.link); n = n + 1
    end
    return nil, nil, nil
end

local function assess(i)
    local t, s = TRIALS[i], samples[i]
    local label = string.format("d=%d", t.dist)
    if not s then fail(label .. ": the throw never fired"); return end

    local drop = s.bar_start - s.bar_min
    local reach = (s.max_blade_x or -9999) - s.jade_x
    local nframes = 0
    for _ in pairs(s.frames or {}) do nframes = nframes + 1 end

    if drop == 0 then
        log("%s: NO HIT (p2_bar held at %d; release +%s,+%s; %d flight frames;"
            .. " blade reached +%d)", label, s.bar_start,
            tostring(s.rel_dx), tostring(s.rel_dy), nframes, reach)
    else
        log("%s: -%d at throw tick %d, blade at +%d, by=%s (release +%s,+%s;"
            .. " %d flight frames; blade reached +%d)",
            label, drop, s.hit_tick or -1, (s.hit_blade_x or 0) - s.jade_x,
            s.by or "?", tostring(s.rel_dx), tostring(s.rel_dy), nframes, reach)
    end

    -- 1. THE RELEASE DISPLACEMENT - the arcade's boomerang_adjust, the whole
    --    change in one number, read off the objects.
    if s.rel_dx == nil then
        fail(string.format("%s: never saw the blade leave her hand", label))
    else
        if math.abs(s.rel_dx - WANT_DX) > 2 then
            fail(string.format("%s: the blade leaves her hand at +%d, want +%d"
                               .. " (the arcade's boomerang_adjust) - a 112 here"
                               .. " means the old anchor step is back",
                               label, s.rel_dx, WANT_DX))
        end
        if s.rel_dy and math.abs(s.rel_dy - WANT_DY) > 2 then
            fail(string.format("%s: release drops it %d px, want %d",
                               label, s.rel_dy, WANT_DY))
        end
    end

    -- 2. SEVEN frames in the loop: UBREL4 back in the lane where UMK3 has it.
    if nframes ~= FLIGHT_FRAMES then
        local names = {}
        for sg in pairs(s.frames or {}) do names[#names+1] = SAG_NAME[sg] or string.format("%08x", sg) end
        table.sort(names)
        fail(string.format("%s: %d distinct flight frames (%s), want %d"
                           .. " - UBREL4 belongs in the loop", label, nframes,
                           table.concat(names, ","), FLIGHT_FRAMES))
    end

    -- 5. the blade always flies
    if reach < 150 then
        fail(string.format("%s: the blade only got %d px out", label, reach))
    end

    if drop >= 28 then
        fail(string.format("%s: -%d is TWO hits on one throw", label, drop))
        return
    end
    if drop > 0 and drop < 15 then
        fail(string.format("%s: only -%d, which is chip - P2 was guarding, so"
                           .. " this trial proves nothing", label, drop))
        return
    end

    -- 3/4. did it connect, and was it allowed to?
    if t.want == "hit" then
        if drop == 0 then
            fail(string.format("%s: nothing registered - the flying blade should"
                               .. " reach him from +%d", label, WANT_DX))
        else
            notes[#notes+1] = string.format("%s: -%d by the %s box", label, drop, s.by or "?")
        end
    elseif t.want == "miss" then
        if drop > 0 then
            fail(string.format("%s: took -%d at point-blank range - the arcade"
                               .. " does not connect here, so either the prezap"
                               .. " is compiled IN (jboomclose) or the release"
                               .. " moved", label, drop))
        else
            notes[#notes+1] = string.format("%s: no hit, which is the arcade's own"
                                            .. " hole and proves the prezap is out", label)
        end
    else
        notes[#notes+1] = string.format("%s: %s (boundary trial - measured, not"
                                        .. " asserted)", label,
                                        (drop > 0) and string.format("-%d", drop) or "no hit")
    end
end

local function finish()
    if finished then return end
    finished = true
    for i = 1, #TRIALS do
        if samples[i] == nil then fail(string.format("d=%d: throw never fired", TRIALS[i].dist)) end
    end
    for _, n in ipairs(notes) do log("note %s", n) end
    if #errors == 0 then log("PASS reason=arcade_release_geometry")
    else log("ERROR reason=%s (%d failures)", errors[1], #errors) end
    logfh:close()
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local wanted = {
            ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
            ["2 Players Start"]=true, ["P1 Right"]=true, ["P1 Left"]=true,
            ["P1 Low Punch"]=true, ["P2 Low Punch"]=true,
        }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if wanted[f.name] then fields[f.name] = f end end
        end
        local missing = {}
        for _, n in ipairs({"P1 Left","P1 Right","P1 Low Punch","P2 Low Punch",
                            "2 Players Start","Coin 1","Coin 2"}) do
            if not fields[n] then missing[#missing+1] = n end
        end
        log("harness loaded  objlst=%s%s",
            A.objlst and string.format("%08x", A.objlst) or "MISSING",
            #missing > 0 and ("  MISSING INPUTS: " .. table.concat(missing, ",")) or "")
        if #missing > 0 then fail("input fields missing: " .. table.concat(missing, ",")) end
    end
    if not space or finished then
        for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs ~= last_gs then
        log("gstate %d -> %d at frame %d%s", last_gs, gs, frame,
            fighting_frame > 0 and string.format(" (fight+%d)", frame - fighting_frame) or "")
        -- Leaving the fight mid-run is a RESET, and a reset is how a blown
        -- system stack shows up here: no lockup, no Lua error, just gstate 2
        -- going back to 0 a tick or two after the release. Say so, or the run
        -- reads as "the throws stopped firing".
        if last_gs == GS_FIGHTING and gs ~= GS_FIGHTING and pending <= #TRIALS
           and fighting_frame > 0 then
            fail(string.format("the game LEFT the fight at fight+%d (gstate %d ->"
                               .. " %d) with %d trial(s) to go - that is a crash"
                               .. " or a round end, not a missed throw",
                               frame - fighting_frame, last_gs, gs,
                               #TRIALS - pending + 1))
            finish(); return
        end
        last_gs = gs
    end
    do
        local ok, pc = pcall(function() return cpu.state["PC"].value end)
        if ok then
            if pc == last_pc then
                same_pc = same_pc + 1
                if same_pc == 45 then
                    log("LOCKUP: PC pinned at %08x for 45 frames (gstate=%d)", pc, gs)
                    fail(string.format("CPU locked at %08x", pc)); finish(); return
                end
            else last_pc, same_pc = pc, 0 end
        end
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame; log("select reached frame=%d", frame) end
        w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_REPTILE)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_JADE); w16(A.p2_char, FT_REPTILE)
    elseif gs == GS_FIGHTING then
        if fighting_frame == 0 then
            fighting_frame = frame
            log("fight started (p1=%d p2=%d)", r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= FT_JADE then
                fail(string.format("P1 is char %d, not Jade (%d) - the select cheat did"
                                   .. " not stick", r16(A.p1_char), FT_JADE))
                finish(); return
            end
        end
        local rel = frame - fighting_frame
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)

        -- PARK THE PAIR, EVERY TICK. repell rewrites velocity from its own
        -- request every tick, so a distance written once is gone by the next
        -- one - and at these separations repell is exactly what would move
        -- them. Jade is pinned too, not just P2: parking only the victim lets a
        -- trial inherit the previous one's drift (the double-knee rig's own
        -- trap). p1_bar is held full so nothing ends the round; p2_bar is left
        -- alone here because it IS the measurement.
        if p1o ~= 0 and p2o ~= 0 then
            if pin_x == nil then pin_x = s16(r16(p1o + O.xpos)) end
            local d = dist_for(rel)
            w32(p1o + O.xval, (pin_x << 16) & 0xffffffff)
            w32(p1o + O.xvel, 0)
            w32(p2o + O.xval, ((pin_x + d) << 16) & 0xffffffff)
            w32(p2o + O.xvel, 0)
        end
        if A.p1_bar then w16(A.p1_bar, FULL_STRENGTH) end

        local proc = r32(A.p1_proc)
        local act = proc ~= 0 and r16(proc + P_ACTION) or 0

        if pending <= #TRIALS and cur == 0 and rel == throw_at(pending) - 20 then
            if A.p2_bar then w16(A.p2_bar, FULL_STRENGTH) end
        end

        if cur == 0 and pending <= #TRIALS and act == ACT_JADE_BOOM
           and rel >= throw_at(pending) then
            cur, armed = pending, rel
            local bar = A.p2_bar and r16(A.p2_bar) or 0
            samples[cur] = { bar_start = bar, bar_min = bar,
                             jade_x = s16(r16(p1o + O.xpos)),
                             jade_y = s16(r16(p1o + O.ypos)),
                             frames = {} }
            log("d=%d: throw armed at rel=%d (jade x=%d, P2 x=%d, p2_bar=%d)",
                TRIALS[cur].dist, rel, samples[cur].jade_x,
                p2o ~= 0 and s16(r16(p2o + O.xpos)) or -1, bar)
        end

        if cur > 0 then
            local s, tick = samples[cur], rel - armed
            local bx, by, bsag = blade_front()
            if bx then
                if s.max_blade_x == nil or bx > s.max_blade_x then s.max_blade_x = bx end
                -- THE RELEASE. The blade rides her throw poses as a slave at
                -- her own anchor (match_ani_points copies her oxval on every
                -- ani_slani), so its offset is ~0 for the whole wind-up and
                -- then steps to the release displacement in one tick. The
                -- first offset clear of her body is that step, measured rather
                -- than assumed.
                if s.rel_dx == nil and (bx - s.jade_x) > 20 then
                    s.rel_dx, s.rel_dy = bx - s.jade_x, by - s.jade_y
                    s.handoff_x = bx
                end
                -- Distinct frames, but only once it is FLYING: the wind-up
                -- frames are in her hand and are not part of the loop.
                if s.rel_dx ~= nil and bsag then s.frames[bsag] = true end
            end
            local bar = A.p2_bar and r16(A.p2_bar) or 0
            if bar < s.bar_min then
                if s.hit_tick == nil then
                    s.hit_tick, s.hit_blade_x = tick, bx or s.jade_x
                    -- Has the blade travelled yet? The prezap (when compiled
                    -- in) can only land on the handoff frame; the flying blade
                    -- cannot strike until it has moved.
                    if s.handoff_x and s.hit_blade_x > s.handoff_x then
                        s.by = "flight"
                    else
                        s.by = "prezap"
                    end
                end
                s.bar_min = bar
            end
            if TRACE then
                log("  d=%d t=%02d blade=%s frame=%s bar=%d", TRIALS[cur].dist, tick,
                    bx and tostring(bx - s.jade_x) or "-",
                    bsag and (SAG_NAME[bsag] or "?") or "-", bar)
            end
            if tick == 4 then snap(string.format("d%d", TRIALS[cur].dist)) end
            if tick >= WINDOW then
                assess(cur); pending = cur + 1; cur = 0
            end
        end

        if rel > throw_at(#TRIALS) + WINDOW + 60 then finish() end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
end)
