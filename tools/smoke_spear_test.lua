-- smoke_spear_test.lua
--
-- SMOKE THROWS THE SPEAR ON HIS OWN ROPE (smrope, MAINEQU.ASM).
--
-- He has always thrown it - zap_offsets row 14 (MKDRONE.ASM) is 00ch, the
-- same do_throw_spear Scorpion uses - but sm_anitab2 was a bare alias label
-- stacked on sc_anitab2, so row 1 resolved to SCORPION's rope: BIGRP1/BIGRP2
-- in flight, SPEARHIT once it stuck.  He now walks a_sm_rope_ani instead:
-- COMEHERE1/COMEHERE2 in flight, COMEHERE3 stuck (data/SMROPE.LOD).
--
-- WHAT THIS MEASURES IS THE SAG THE DMA WAS HANDED, not a palette and not a
-- screenshot.  The rope is a one-piece multipart object, so obj(oimg) is its
-- multipart RAM and mp_sag is the record actually being drawn.  Expectations
-- come from tools/smoke_spear_expect.lua, which the PowerShell runner
-- REGENERATES from src/SMROPE.TBL and src/MKNJ.TBL on every run - a rebuild
-- moves every SAG in the pack, so a hard-coded number here would pass against
-- the wrong art.
--
-- THE SECOND HALF IS THE CLIP, and it is why this rig exists at all rather
-- than a look at a screenshot.  lineup_rope_with_him (MKZAP.ASM) clips the
-- taut rope to the gap between the two fighters by writing (width - distance)
-- into `ofset`, and that width was a hard-coded 304 - SPEARHIT's.  COMEHERE3
-- is 317 wide.  The check is therefore an IDENTITY on the live object:
--
--     ofset + |x distance|  ==  mp_sizex
--
-- which is true for both ropes only if the code reads the width off the frame
-- it is drawing.  With the old constant it holds for Scorpion and is 13 out
-- for Smoke, so -Who scorpion is a real control, not a formality.
--
-- The thrower is the DRONE, because that is Smoke's only path: he is CPU-only
-- (toasty_check, MKTOAST.ASM) and char_lo_punch row 14 is `sucide`, so a human
-- Smoke cannot throw it at all.  Reaching him follows tools/kham_moves_test.lua
-- - pick a real fighter at select and overwrite the char id at GS_POST, since
-- forcing a hidden id at GS_PSEL never confirms.
--
-- KNOWN LIMITATION, 2026-09-27: THIS RIG CANNOT MAKE A DRONE ACT.  It reaches
-- the fight correctly - select, confirm, the forced char ids, the bars and the
-- clock all hold, and P1 walks - but the CPU fighter sits in act_stance
-- (0x0303) for every frame of the run and never decides anything.  That is NOT
-- about Smoke: with MK2_SPEAR_FT=1 (Liu Kang, an ordinary fighter) the drone is
-- inert in exactly the same way, 1,602 frames of 0x0303 and byte-identical
-- positions.  Ruled out along the way: the RNG stir (MK2_SPEAR_STIR=0 is the
-- same), the p_state writes (MK2_SPEAR_STATES=0 is the same), and
-- f_freeze_timer (it only skips the clock decrement, MAIN.ASM:832).
--
-- So a run that ends "HARNESS: drone never acted" is reporting the rig, not the
-- art, and the FAIL should be read that way.  What the rig HAS measured, on a
-- real spear: the clip identity below held 25 frames out of 25 with zero
-- breaks for Scorpion, which is the check on the shared lineup_rope_with_him
-- change.  The Smoke half is still statically proved only - see
-- doc/SMOKE_SPEAR.md.
--
--   MK2_SPEAR_WHO     smoke (default) | scorpion   - who is on the rope
--   MK2_SPEAR_LOG     log file path
--   MK2_SPEAR_END     frames of fighting to watch (default 5400)
--   MK2_SPEAR_FT      override P2's ft_ id (diagnosing the inert drone)
--   MK2_SPEAR_STIR    0 = do not stir @rand
--   MK2_SPEAR_STATES  0 = do not write p1_state/p2_state

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local WHO = (os.getenv("MK2_SPEAR_WHO") or "smoke"):lower()
local LOG = os.getenv("MK2_SPEAR_LOG") or (ROOT .. "/tools/smoke_spear_" .. WHO .. ".log")
local RUN_END = tonumber(os.getenv("MK2_SPEAR_END") or "5400")
local SEED    = tonumber(os.getenv("MK2_SPEAR_SEED") or "0")
local STIR    = (os.getenv("MK2_SPEAR_STIR") or "1") ~= "0"
local STATES  = (os.getenv("MK2_SPEAR_STATES") or "1") ~= "0"

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[spear] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

-- ---- expectations, regenerated per run by the runner ---------------------
local EXPECT = dofile(ROOT .. "/tools/smoke_spear_expect.lua")
EXPECT.byname = {}
for n, s in pairs(EXPECT.all) do EXPECT.byname[s] = n end
local WANT = EXPECT[WHO]
if not WANT then
    log("FATAL: no expectation for MK2_SPEAR_WHO=%q", WHO)
end

-- ---- symbols -------------------------------------------------------------
local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), diff = sym("diff"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar  = sym("p1_bar"),  p2_bar  = sym("p2_bar"),
    p1_obj  = sym("p1_obj"),  p2_obj  = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    objlst  = sym("objlst"),  objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    rand    = sym("rand"),  f_freeze_timer = sym("f_freeze_timer"),
    winner_status = sym("winner_status"), round_num = sym("round_num"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
}
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k) end end

-- DISPEQU.ASM object block / MKSTRUCT.ASM process block, in BIT offsets
local OLINK, OXPOS, OFSET, OIMG, OCHAR = 0, 0x90, 0xe0, 0x1a0, 0x1f0
local MP_SAG, MP_SIZEX   = 0, 32
local P_SLAVE, P_ACTION  = 0x190, 0x1f0

-- MAINEQU.ASM.  Logged, not asserted: they say whether the drone ever got as
-- far as throwing, which is the difference between "the art is wrong" and
-- "the rig never produced a spear".
local ACT_SPEAR, ACT_PROJ_SD, ACT_ROPE_PULL = 0x011, 0x604, 0x405

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local PS_ACTIVE, PS_INACTIVE = 1, 0
local FT_JAX, MAX_HP = 11, 0xa1
-- MK2_SPEAR_FT overrides who P2 is, for isolating a frozen drone from a
-- broken one: point it at an ordinary fighter and the question becomes
-- "does the drone work in this harness at all".
local THROWER = tonumber(os.getenv("MK2_SPEAR_FT") or "") or (WANT and WANT.ft) or FT_JAX

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end

local function obj_x(p) local o = r32(p); if o == 0 then return -1 end; return r16(o + OXPOS) end
local function obj_ochar(p) local o = r32(p); if o == 0 then return -1 end; return r16(o + OCHAR) end

-- ---- findings ------------------------------------------------------------
local seen        = {}     -- sag -> count
local unknown     = {}     -- sag -> count, anything not in the rope set
local clip_ok, clip_bad = 0, 0
local clip_worst  = nil
local flight_hits, taut_hits = 0, 0
local throws, pulls = 0, 0
local foreign_hits = 0     -- the OTHER fighter's rope records
local last_sag, last_act = nil, nil
local acts = {}   -- every p_action the drone was ever in

local function name_of(sag) return EXPECT.byname[sag] end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- records the DMA was handed ----")
    local names = {}
    for sag, n in pairs(seen) do names[#names+1] = { sag = sag, n = n } end
    table.sort(names, function(a, b) return a.sag < b.sag end)
    for _, e in ipairs(names) do
        local nm = name_of(e.sag) or "?"
        local mine = WANT and (WANT.flight[e.sag] or WANT.taut == e.sag)
        log("  %-12s sag=%08x  %4d frames   %s", nm, e.sag, e.n, mine and "HIS OWN" or "*** NOT HIS ***")
    end
    for sag, n in pairs(unknown) do log("  (non-rope slave sag=%08x %d frames)", sag, n) end
    log("---- clip identity  ofset + dist == mp_sizex ----")
    log("  held %d frames, broke %d frames%s", clip_ok, clip_bad,
        clip_worst and string.format("  worst off-by %d", clip_worst) or "")
    log("---- every p_action the drone was in ----")
    local al = {}
    for a, n in pairs(acts) do al[#al+1] = { a = a, n = n } end
    table.sort(al, function(x, y) return x.n > y.n end)
    for i = 1, math.min(#al, 12) do log("  0x%04x  %6d frames", al[i].a, al[i].n) end
    log("drone: act_spear entered %d times, act_rope_pull %d times", throws, pulls)
    log("flight frames=%d  taut frames=%d  foreign=%d", flight_hits, taut_hits, foreign_hits)
    log("%s who=%s reason=%s", ok and "PASS" or "FAIL", WHO, reason)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 High Punch"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do if not fields[name] then log("input %-16s MISSING", name) end end
end

-- P1 WALKS BACK AND FORTH FOR THE WHOLE RUN.  Against a completely passive
-- player the drone simply stands in act_stance - 3,000 frames of 0x0303 with
-- the gap frozen at exactly 192 - and never reaches the decision that picks
-- its special at all.  Walking sweeps the range through every band, which is
-- what tools/battle_stability_sweep.lua does for the same reason.
local walk_dir = 1

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if fighting_frame > 0 then
        if name == "P1 Left"  then return walk_dir < 0 end
        if name == "P1 Right" then return walk_dir > 0 end
        return false
    end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    return false
end

-- FIND THE ROPE BY ITS ART, not by its owner.  p_slave looks like the handle
-- - get_proj_obj_m does set it - but it is not dependable here for the same
-- reason the Rain cloud probe walks the lists instead: it is re-pointed and
-- cleared by delete_slave, and a stale one reads as a live object full of
-- rubbish.  Walking objlst/2/3 for an object whose multipart RAM carries one
-- of the six known rope SAGs asks the question directly, and it cannot match
-- anything else, because those SAGs are the rope records.
local function find_rope()
    for _, head in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local o = r32(head)
        local guard = 0
        while o ~= 0 and guard < 200 do
            local mp = r32(o + OIMG)
            if mp ~= 0 then
                local sag = r32(mp + MP_SAG)
                if EXPECT.byname[sag] then return o, mp, sag end
            end
            o = r32(o + OLINK)
            guard = guard + 1
        end
    end
    return 0, 0, 0
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("watching %s - flight %s, taut %s", WHO,
            WANT and WANT.flight_names or "?", WANT and WANT.taut_name or "?")
    end
    if not space or finished then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    -- NOTHING BEFORE THE GAME HAS BEEN PAID FOR.  Attract mode runs BOTH the
    -- select screen and a demo fight, at the same gstates a real game uses,
    -- so every latch below would fire during the attract loop: charsel and
    -- confirm on the demo select, then fighting_frame on the demo fight -
    -- after which pressed() stops driving the coin and the start button and
    -- the rig never starts a game at all.  It watched attract mode for the
    -- whole run, called the drone inert, and scored the DEMO's Scorpion
    -- spear against whoever it was meant to be testing.  The coin goes in
    -- at frames 700-980 and Start at 1000-1080, so nothing latches until
    -- after that.
    local gs = r16(A.gstate)
    if frame < 1100 then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame; log("select reached at frame %d", frame) end
        w16(A.p1_char, FT_JAX)
        w16(A.p2_char, THROWER)
        if STATES then w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_INACTIVE) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d", frame)
        end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_JAX)
        w16(A.p2_char, THROWER)      -- a hidden id only takes here
    -- ONLY AFTER WE HAVE ACTUALLY STARTED A GAME.  The ATTRACT DEMO also
    -- runs at gstate == GS_FIGHTING, so latching on the first one catches
    -- the boot demo - and because pressed() stops driving the coin and the
    -- start button once it has latched, the rig then never starts a game at
    -- all.  It sat watching attract mode for the whole run, reported the
    -- drone as inert in act_stance, and scored the demo's own Scorpion
    -- spear against whoever it was supposed to be testing.
    elseif gs == GS_FIGHTING and fighting_frame == 0 and confirm_frame > 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d (want p2=%d)", r16(A.p1_char), r16(A.p2_char), THROWER)
        if r16(A.p2_char) ~= THROWER then
            finish(false, "p2_char_overwrite_failed"); return
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 9) end            -- throw often
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        -- A FULL BAR IS NOT ENOUGH.  The round CLOCK still runs out, the round
        -- ends tied and the ladder moves on, so freeze the clock - with
        -- f_freeze_timer, the game's own training-mode flag ("non-zero = skip
        -- clock dec", RAM.ASM).
        --
        -- NOT @timer.  That is the PROCESS SCHEDULER's timer (MPROC.ASM: dirq
        -- bumps it, prcdsp reads it), and writing a round-clock value into it
        -- every frame wedges the dispatcher: the drone then stands in
        -- act_stance at a 61px gap for 3,000 frames and never decides
        -- anything, which reads exactly like "the CPU never throws the spear".
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        w16(A.p1_char, FT_JAX); w16(A.p2_char, THROWER)

        -- STIR THE RNG EVERY FRAME.  @rand is reseeded from constants at round
        -- start, so a scripted rig replays ONE stream and a single roll decides
        -- whether the drone ever picks its special.  Without this the drone
        -- threw no spear at all in 4,000 frames - not because the move was
        -- broken, but because the same roll came up every time.  Same
        -- treatment as tools/cage_drone_ball_probe.lua; see doc/AI_DRONE.md.
        if STIR and A.rand and A.rand ~= 0 then
            w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345 + SEED) & 0xffffffff)
        end

        -- what the drone is up to, so a run with no rope says WHY
        local dproc = r32(A.p2_proc)
        local dact = dproc ~= 0 and r16(dproc + P_ACTION) or -1
        acts[dact] = (acts[dact] or 0) + 1
        if dact ~= last_act then
            if dact == ACT_SPEAR then throws = throws + 1
            elseif dact == ACT_ROPE_PULL then pulls = pulls + 1 end
            last_act = dact
        end

        if r % 600 == 0 then
            local hproc = r32(A.p1_proc)
            local hact = hproc ~= 0 and r16(hproc + P_ACTION) or -1
            log("  r=%5d  gap=%4d  p1x=%4d p2x=%4d  p1act=0x%04x drone act=0x%04x  walk=%d  p1=%d/%d p2=%d/%d  ws=%d rnd=%d  throws=%d",
                r, math.abs(obj_x(A.p1_obj) - obj_x(A.p2_obj)),
                obj_x(A.p1_obj), obj_x(A.p2_obj), hact, dact, walk_dir,
                r16(A.p1_char), obj_ochar(A.p1_obj), r16(A.p2_char), obj_ochar(A.p2_obj),
                A.winner_status and r16(A.winner_status) or -1,
                A.round_num and r16(A.round_num) or -1, throws)
        end

        if r % 150 == 0 then walk_dir = -walk_dir end

        local rope, mp, sag = find_rope()
        if rope ~= 0 then
            local w   = r16(mp + MP_SIZEX)
            local ofs = r16(rope + OFSET)
            local nm  = name_of(sag)
            seen[sag] = (seen[sag] or 0) + 1
            if sag ~= last_sag then
                log("  r=%5d  %-12s sag=%08x w=%3d ofset=%4d ropex=%4d  p1x=%4d p2x=%4d  ropechar=%d p1ochar=%d p2ochar=%d",
                    r, nm, sag, w, ofs, r16(rope + OXPOS), obj_x(A.p1_obj), obj_x(A.p2_obj),
                    r16(rope + OCHAR), obj_ochar(A.p1_obj), obj_ochar(A.p2_obj))
                last_sag = sag
            end
            if WANT then
                if WANT.flight[sag] then flight_hits = flight_hits + 1
                elseif sag == WANT.taut then
                    taut_hits = taut_hits + 1
                    -- the clip identity, only while the rope is taut: ofset is
                    -- rewritten every tick by lineup_rope_with_him
                    local p1x, p2x = obj_x(A.p1_obj), obj_x(A.p2_obj)
                    if p1x >= 0 and p2x >= 0 and ofs > 0 then
                        local dist = math.abs(p1x - p2x)
                        local off  = math.abs((ofs + dist) - w)
                        -- get_x_dist measures between the fighters' anchors and
                        -- the rope is then nudged by spear_adjustments, so allow
                        -- a few px of slop.  A wrong WIDTH is a fixed 13px
                        -- error, far outside it.
                        if off <= 6 then clip_ok = clip_ok + 1
                        else
                            clip_bad = clip_bad + 1
                            if not clip_worst or off > clip_worst then clip_worst = off end
                            if clip_bad <= 8 then
                                log("  r=%5d  CLIP off by %d: ofset=%d + dist=%d != w=%d",
                                    r, off, ofs, dist, w)
                            end
                        end
                    end
                else
                    foreign_hits = foreign_hits + 1
                end
            end
        else
            last_sag = nil
        end

        if r > RUN_END then
            local ok = flight_hits > 0 and taut_hits > 0 and foreign_hits == 0
                       and clip_bad == 0 and clip_ok > 0
            -- TELL A HARNESS FAILURE FROM A PRODUCT FAILURE.  If the drone
            -- never left act_stance it never decided anything, so this run
            -- says nothing about the art: it is the rig that did not work.
            -- Measured: an ordinary fighter's drone (MK2_SPEAR_FT=1, Liu
            -- Kang) is inert here in exactly the same way, 1602 frames of
            -- 0x0303, so whatever this is it is not about Smoke.
            local only_stance = true
            for a in pairs(acts) do if a ~= 0x0303 then only_stance = false end end
            local why = "ok"
            if flight_hits == 0 then
                if throws == 0 and only_stance then
                    why = "HARNESS: drone never acted (not a finding about the art)"
                else
                    why = (throws == 0) and "drone_never_threw_a_spear" or "never_saw_the_rope_fly"
                end
            elseif taut_hits == 0 then why = "spear_never_connected"
            elseif foreign_hits > 0 then why = "drew_the_other_fighters_rope"
            elseif clip_ok == 0 then why = "no_clip_samples"
            elseif clip_bad > 0 then why = "clip_width_wrong" end
            finish(ok, why)
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 20000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
