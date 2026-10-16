-- drone_divepunish_test.lua
--
-- "On a blocked Kung Lao dive kick the computer often whiffs the punishment
--  with a missed roundhouse kick."  Reported from real play.
--
-- THE WINDOW BEING MEASURED.  do_reptile_superk (MKPROP.ASM) is Kung Lao's
-- dive kick.  When it is BLOCKED, super_rep_blocked stamps act_hh_sd (061ah)
-- and flies him UP and slightly back, rolled in a ball, for about 37 ticks
-- before he lands.  So the whole punish window is spent with him AIRBORNE and
-- close -- and the drone has three separate ways to swing at an airborne man:
--
--   drone_antiair_try -> aa_roundhouse   gated: dog<=044h AND gap<=028h
--   rh_ooa (med_out_of_air)              gated on closest point only
--   rt_airborn_close (stalk, random 1/3) NO GATES AT ALL
--
-- The third is retail's and it swings blind.  A roundhouse is fixed at head
-- height and does not travel up, so a man 60-90px off the floor is over it --
-- and a whiffed roundhouse is a free punish handed straight back.
--
-- WHAT IS COUNTED, per dive kick the drone BLOCKS:
--   swings   every attack the drone starts while Kung Lao is in act_hh_sd
--   HIT      p1_bar actually dropped within 14 frames of the swing
--   WHIFF    it did not -- the failure the report is about
-- broken out by move, because which move whiffs is the whole question.
--
-- Env: DIVEP_LOG, DIVEP_CHAR (the DRONE), DIVEP_DIFF, DIVEP_SEED
-- Usage: tools\run_drone_divepunish_test.ps1

local LOGP = os.getenv("DIVEP_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_divepunish_test.log"
local DIFF = tonumber(os.getenv("DIVEP_DIFF") or "9")
local CHAR = (os.getenv("DIVEP_CHAR") or "scorpion"):lower()
local SEED = tonumber(os.getenv("DIVEP_SEED") or "0")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[divep] " .. string.format(fmt, ...)
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
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"), rand = sym("rand"),
    ground_y = sym("ground_y"),
}

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
-- oyvel: signed 16.16, NEGATIVE = rising (q_he_heading_down tests jrp on it).
-- Height alone did not separate the sweeps that land from the ones that miss
-- - the misses clustered LOWER than the hits - so direction gets logged too.
local OYVEL = 0x060   -- DISPEQU.ASM: oyvel .set 060h (0x0a0 is oyval, the POSITION)
local PDATA        = 0x100
local PROC_ACTION  = PDATA + 0x0f0
local PROC_GANIY   = PDATA + 0x100
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

-- Action ids are .set equates and are NOT in MK2.MAP -- read them out of
-- MAINEQU.ASM.  A hardcoded guess here is indistinguishable from a broken
-- feature; drone_antiair_test.lua carries the scar tissue for that.
local acts = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+([0-9a-fA-F]+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end
local missing = {}
local function act(n)
    local v = acts[n]
    if not v then missing[#missing+1] = n end
    return v or -1
end
local ACT_FLY    = act("act_reptile_fly")
local ACT_HH_SD  = act("act_hh_sd")
local ACT_REACT  = act("act_reacting")
-- IDLE IS act_stance (0303h), NOT ZERO.  The state machine was gated on
-- "action == 0" for one build and produced a run with ZERO dives: the action
-- a standing fighter carries is act_stance, and 0 only turns up in
-- transients.  It is gated on dog and act_reacting instead.
local ACT_SLAM   = act("act_bodyslam")
local ATTACK_NAME = {
    [act("act_hipunch")]  = "hi punch",
    [act("act_lopunch")]  = "lo punch",
    [act("act_hikick")]   = "hi kick",
    [act("act_medkick")]  = "med kick",
    [act("act_rhouse")]   = "ROUNDHOUSE",
    [act("act_sweep")]    = "sweep",
    [act("act_uppercut")] = "uppercut",
}

local CHARS = { kunglao = 0, liukang = 1, cage = 2, baraka = 3, kitana = 4,
                mileena = 5, shang = 6, raiden = 7, subzero = 8, reptile = 9,
                scorpion = 10, jax = 11 }
local SUBJECT = CHARS[CHAR]
if not SUBJECT then
    log("FATAL unknown DIVEP_CHAR '%s' -- NOT defaulting; this run proves nothing.", CHAR)
    SUBJECT, CHAR = 10, CHAR .. "(UNKNOWN)"
end
local FT_HATHEAD = 0

local DIVE_MIN_DFG = 0xa4        -- do_reptile_superk needs dfg >= 0a0h
local JUMP_GAP     = 0x84        -- walk out to about here, then jump
local RUN_FRAMES   = 14000

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start, done = 0, false
local fields = {}

local dives, blocked, hit_clean = 0, 0, 0
local swings, hits, whiffs = 0, 0, 0
-- STALL WATCHDOG.  Two ways a run stops producing dives: MAME faults in
-- dma_draw (seen once, an ACCESS VIOLATION inside midtunit_video_device),
-- and the drone throws Kung Lao and the pair sits in act_bodyslam with the
-- bars pinned.  Either way the counts already collected are the sample, so
-- close the run and print them instead of burning the backstop.
local last_progress = 0
local last_ws = 0
local by_move = {}      -- name -> {swings, hits, whiffs}
-- THE WIDER SAMPLE.  The act_hh_sd window is the report, but it is only about
-- three windows per run: the drone blocks maybe three dives in eight and the
-- run ends on a stall.  stalk_airborn_close does not care WHY he is airborne,
-- so every swing the drone starts at a man off the floor measures the same
-- gate on a much bigger sample.  air_* counts those; by_air breaks them out.
local air_swings, air_hits, air_whiffs = 0, 0, 0
local by_air = {}
local air_pending = nil
local p1_forward = "R"

-- input state machine
local st, st_frame = "approach", 0
local hold = {}
local window_open, window_until = false, 0
local last_p2_act, last_p1_act = -1, -1
local TRACE = (os.getenv("DIVEP_TRACE") or "0") ~= "0"
local tr1, tr2 = -1, -1
local pending = nil      -- the swing whose outcome we are still waiting on
local seq = {}           -- the drone's action sequence inside one window

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function proc_act(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
end
-- dog: p_ganiy - oypos, the number get_his_dog / aa_kick_height compare
local function dog(procptr, objptr)
    local q, o = r32(procptr), r32(objptr)
    if q == 0 or o == 0 then return 0 end
    return s16(r16(q + PROC_GANIY)) - s16(r16(o + OYPOS))
end
-- dfg: ground_y - oypos, the number do_reptile_superk gates the dive on
local function dfg(objptr)
    local o = r32(objptr); if o == 0 then return 0 end
    return s16(r16(A.ground_y)) - s16(r16(o + OYPOS))
end

local function bump(tab, name, field)
    local e = tab[name]
    if not e then e = {swings = 0, hits = 0, whiffs = 0}; tab[name] = e end
    e[field] = e[field] + 1
end

local function settle()
    if not pending then return end
    whiffs = whiffs + 1
    bump(by_move, pending.name, "whiffs")
    log("  WHIFF %s at gap=%d dog1=%d  (rel=%d)",
        pending.name, pending.gap, pending.h1, pending.frame - run_start)
    pending = nil
end

local function finish()
    if done then return end
    done = true
    if #missing > 0 then
        log("FATAL these act_ equates were not found in MAINEQU.ASM: %s",
            table.concat(missing, " "))
    end
    settle()
    log("RESULT drone=%s diff=%d seed=%d  dives=%d blocked=%d unblocked=%d",
        CHAR, DIFF, SEED, dives, blocked, hit_clean)
    log("RESULT punish swings in the act_hh_sd window: %d  hit=%d  WHIFF=%d",
        swings, hits, whiffs)
    for name, e in pairs(by_move) do
        log("   %-12s swings=%d hit=%d whiff=%d", name, e.swings, e.hits, e.whiffs)
    end
    log("RESULT every swing at an AIRBORNE opponent: %d  hit=%d  WHIFF=%d",
        air_swings, air_hits, air_whiffs)
    for name, e in pairs(by_air) do
        log("   air %-12s swings=%d hit=%d whiff=%d", name, e.swings, e.hits, e.whiffs)
    end
    local rh = by_move["ROUNDHOUSE"]
    if blocked < 3 then
        log("NO-VERDICT only %d blocked dives -- the rig never got going", blocked)
    elseif rh and rh.whiffs > 0 then
        log("REPRO %d roundhouse(s) thrown into the blocked-dive window missed (%d hit)",
            rh.whiffs, rh.hits)
    elseif whiffs > 0 then
        log("PARTIAL no roundhouse whiff, but %d other swing(s) missed", whiffs)
    else
        log("CLEAN %d blocked dives, %d swings, none whiffed", blocked, swings)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["P1 High Punch"] = true, ["P1 High Kick"] = true,
                   ["P1 Up"] = true, ["P1 Down"] = true,
                   ["P1 Right"] = true, ["P1 Left"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local function fwd() return (p1_forward == "L") and "P1 Left" or "P1 Right" end
local function back() return (p1_forward == "L") and "P1 Right" or "P1 Left" end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- divepunish: P1=KungLao dive kicks, P2=%s(drone) diff=%d seed=%d ----",
            CHAR, DIFF, SEED)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame == 0 then
        for n, f in pairs(fields) do
            local v = 0
            if n == "Coin 1" and frame >= 200 and frame < 1000 and (frame % 80) < 20 then v = 1 end
            if n == "1 Player Start" and frame >= 1000 and frame < 1080 then v = 1 end
            f:set_value(v)
        end
        if frame > 6000 then log("ERROR never reached select"); finish() end
        return
    end

    if fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_HATHEAD)
        w16(A.p2_char, SUBJECT)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        for n, f in pairs(fields) do
            local v = 0
            if n == "P1 High Punch" and p1_confirm > 0
               and frame >= p1_confirm and frame < p1_confirm + 45 then v = 1 end
            f:set_value(v)
        end
        if gs == GS_FIGHTING then
            fighting_frame = frame; run_start = frame
            log("fight start frame=%d", frame)
        end
        if frame > 9000 then log("ERROR never reached fight"); finish() end
        return
    end

    -- keep the round alive
    if gs ~= GS_FIGHTING then
        log("ROUND-END gstate=%d at rel=%d -- closing the run with what it has",
            gs, frame - run_start)
        finish(); return
    end
    if A.diff ~= DIFF then w16(A.diff, DIFF) end
    -- READ IT BEFORE STOMPING IT.  The stomp is unconditional, so logging
    -- winner_status after the write only ever prints 0 -- which hid the round
    -- ending under the rig's own hand for several runs.
    local ws_seen = r16(A.winner_status)
    if ws_seen ~= 0 and ws_seen ~= last_ws then
        log("WINNER-STATUS %d at rel=%d hp1=%d -- the round tried to end",
            ws_seen, frame - run_start, r16(A.p1_bar))
    end
    last_ws = ws_seen
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    w16(A.winner_status, 0)
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    -- SHIFT THE STREAM ONCE, DO NOT STIR IT EVERY FRAME.
    --
    -- drone_antiair_test.lua re-stirs @rand on every frame and gets away with
    -- it; this rig did not.  Walking the RNG through nine thousand arbitrary
    -- phases lands on the ones documented in
    -- doc/AI_DRONE.md / project_attract_rng_phase_crash: one seed took MAME
    -- down with an ACCESS VIOLATION inside midtunit_video_device::dma_draw,
    -- and several wedged the fight outright - both fighters parked in
    -- act_stance with full bars, winner_status 0, gstate still FIGHTING and
    -- the positions frozen while MAME kept emulating.  That reads exactly
    -- like a drone that has stopped reacting, which is the failure this rig
    -- is supposed to be measuring, so it has to go.
    --
    -- One stir at the top of the fight gives the per-seed stream shift the
    -- doc asks for ("shift the stream and re-run before believing it") and
    -- nothing else.  @rand is reseeded per ROUND, and the rig keeps one round
    -- alive, so once is enough.
    if A.rand ~= 0 and SEED ~= 0 and frame == fighting_frame + 1 then
        w32(A.rand, (r32(A.rand) * 1103515245 + SEED * 12345) & 0xffffffff)
    end

    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then p1_forward = (x1 < x2) and "R" or "L" end
    local gap = (x1 and x2) and math.abs(x2 - x1) or 999
    local d1  = dog(A.p1_proc, A.p1_obj)
    local g1  = dfg(A.p1_obj)
    local a1  = proc_act(A.p1_proc)
    local a2  = proc_act(A.p2_proc)
    local hp1 = r16(A.p1_bar)

    -- DIVEP_TRACE=1 logs every action change on both sides.  Seed 0 takes
    -- MAME down with an ACCESS VIOLATION inside
    -- midtunit_video_device::dma_draw at a repeatable point, which is a
    -- sprite source address out of the gfx region, not a rig fault -- and the
    -- log is flushed per line, so the last trace lines before the fault name
    -- the state that produced it.
    if TRACE and (a1 ~= tr1 or a2 ~= tr2) then
        log("T rel=%-5d p1=%04x p2=%04x gap=%-4d dog1=%-4d dfg=%d",
            frame - run_start, a1, a2, gap, d1, g1)
        tr1, tr2 = a1, a2
    end

    -- NUDGED, NOT SNAPPED.  A blocked dive ends with the pair on top of each
    -- other, which is throw range, and a drone that lands a body slam holds
    -- him for a long time with the bars pinned.  So the idle player gets
    -- walked back out a few pixels at a time, the way drone_antiair_test.lua
    -- does it.
    --
    -- DO NOT SNAP HIM THE WHOLE WAY IN ONE FRAME.  That was tried, to get
    -- more dives per run: teleport him to a fixed launch distance while
    -- grounded and idle, then jump.  It WEDGES THE GAME - within about 700
    -- ticks both fighters sit in act_stance with the positions frozen while
    -- MAME keeps emulating, every seed, and the log reads exactly like a
    -- drone that has stopped reacting. A 200px instantaneous move is not
    -- something any code path in the game produces; a 6px one is a walk.
    -- ...AND NOT WHILE THE DRONE IS HOLDING HIM.  `dog <= 4` does not cover
    -- it: a man being THROWN reads dog -1, so the nudge was shoving the
    -- victim sideways in the middle of the drone's body slam and wedging the
    -- pair for the rest of the run (p2 parked in act_bodyslam, p1 in action
    -- 0, 700+ ticks).  Gating on p1 being in stance/walk instead was too
    -- tight and cost most of the dives - the useful nudges happen while he is
    -- landing and getting up.  One test, on the drone's hold.
    if gap < 0x64 and d1 <= 4 and not window_open and (frame % 5) == 0
       and (st == "approach" or st == "recover") and a2 ~= ACT_SLAM then
        local o = r32(A.p1_obj)
        if o ~= 0 and x1 and x2 then
            local nx = x1 + ((x1 < x2) and -6 or 6)
            -- NO ABSOLUTE SCREEN CLAMP.  oxpos is a WORLD x on a scrolling
            -- stage: measured values here run 620-870, so the "40..360"
            -- screen-coordinate clamp this was copied with rejected every
            -- single nudge and the pair stayed welded together. Bound the
            -- step by the GAP instead, which is what it is actually for.
            local ngap = math.abs(x2 - nx)
            if ngap > 0 and ngap < 0x100 then
                w32(o + OXVAL, (nx & 0xffff) << 16)
                w16(o + OXPOS, nx & 0xffff)
            end
        end
    end

    -- ---- drive the dive: approach, jump, Down, HK ----
    hold = {}
    -- He owns his own joystick when he is on the floor and not in hit stun.
    local p1_idle = (d1 <= 4) and (a1 ~= ACT_REACT)
    -- A MAN WHO IS BUSY CANNOT BE DRIVEN.  Every state below assumes P1 owns
    -- his own joystick; while he is in act_reacting he does not, so Up is
    -- swallowed, "rise" times out, and the cycle spins without producing a
    -- dive until the stall watchdog closes the run.  Send him back to the top
    -- the moment that happens, and only snap-and-jump from a neutral action.
    if a1 == ACT_REACT and st ~= "recover" and not window_open then
        st, st_frame = "recover", frame
    end
    if st == "approach" then
        if not p1_idle then
            -- wait it out
        elseif gap > JUMP_GAP then
            hold[fwd()] = true
        elseif gap < 0x54 then
            hold[back()] = true
        else
            st, st_frame = "jump", frame
        end
    elseif st == "jump" then
        hold["P1 Up"] = true; hold[fwd()] = true
        if frame - st_frame > 5 then st, st_frame = "rise", frame end
    elseif st == "rise" then
        -- AIMED, not just high enough: the dive travels a long way, and one
        -- thrown from 227px away lands nowhere near him and is never blocked.
        if g1 >= DIVE_MIN_DFG and gap <= 0x80 then st, st_frame = "down", frame
        elseif frame - st_frame > 45 then st, st_frame = "recover", frame end
    elseif st == "down" then
        hold["P1 Down"] = true
        if frame - st_frame > 2 then st, st_frame = "gap", frame end
    elseif st == "gap" then
        if frame - st_frame > 1 then st, st_frame = "hk", frame end
    elseif st == "hk" then
        hold["P1 High Kick"] = true
        if frame - st_frame > 3 then st, st_frame = "recover", frame end
    elseif st == "recover" then
        if p1_idle and not window_open and frame - st_frame > 18 then
            st, st_frame = "approach", frame
        elseif frame - st_frame > 240 then
            st, st_frame = "approach", frame
        end
    end
    for n, f in pairs(fields) do f:set_value(hold[n] and 1 or 0) end

    -- ---- every swing at an airborne man, whatever put him up there ----
    if air_pending then
        if hp1 < air_pending.hp then
            air_hits = air_hits + 1
            bump(by_air, air_pending.name, "hits")
            log("  AIR HIT   %s dog1=%d gap=%d vy=%.2f", air_pending.name, air_pending.h1, air_pending.gap, air_pending.vy)
            air_pending = nil
        elseif frame - air_pending.frame > 14 then
            air_whiffs = air_whiffs + 1
            bump(by_air, air_pending.name, "whiffs")
            log("  AIR WHIFF %s dog1=%d gap=%d vy=%.2f", air_pending.name, air_pending.h1, air_pending.gap, air_pending.vy)
            air_pending = nil
        end
    end
    if a2 ~= last_p2_act and ATTACK_NAME[a2] and d1 > 0x10 then
        if air_pending then
            air_whiffs = air_whiffs + 1
            bump(by_air, air_pending.name, "whiffs")
            log("  AIR WHIFF %s dog1=%d gap=%d vy=%.2f", air_pending.name, air_pending.h1, air_pending.gap, air_pending.vy)
            air_pending = nil
        end
        air_swings = air_swings + 1
        bump(by_air, ATTACK_NAME[a2], "swings")
        -- height and gap at the swing's FIRST tick: that is what a gate in
        -- the ROM would have to decide on, so it is what a threshold has
        -- to be read from
        local o1 = r32(A.p1_obj)
        local vy = 0
        if o1 ~= 0 then
            vy = r32(o1 + OYVEL)
            if vy >= 0x80000000 then vy = vy - 0x100000000 end
        end
        air_pending = {name = ATTACK_NAME[a2], frame = frame, hp = hp1,
                       h1 = d1, gap = gap, vy = vy / 65536}
    end

    -- ---- did the dive come out, and was it blocked ? ----
    if a1 == ACT_FLY and last_p1_act ~= ACT_FLY then
        dives = dives + 1
        last_progress = frame
        log("dive #%-2d gap=%d dfg=%d rel=%d", dives, gap, g1, frame - run_start)
    end
    if a1 == ACT_HH_SD and last_p1_act ~= ACT_HH_SD then
        blocked = blocked + 1
        window_open, window_until = true, frame + 90
        seq = {}
        log("BLOCKED #%-2d (dive %d) gap=%d dog1=%d rel=%d",
            blocked, dives, gap, d1, frame - run_start)
    end
    if last_p1_act == ACT_FLY and a1 ~= ACT_FLY and a1 ~= ACT_HH_SD then
        hit_clean = hit_clean + 1
    end
    last_p1_act = a1

    if window_open then
        if a2 ~= last_p2_act then
            seq[#seq + 1] = string.format("%04x", a2)
            local name = ATTACK_NAME[a2]
            if name then
                settle()
                swings = swings + 1
                bump(by_move, name, "swings")
                pending = {name = name, frame = frame, hp = hp1, gap = gap, h1 = d1}
                log("  swing %s at gap=%d dog1=%d rel=%d",
                    name, gap, d1, frame - run_start)
            end
        end
        if frame > window_until then
            window_open = false
            log("  .. drone actions in window: %s", table.concat(seq, " "))
        end
    end
    last_p2_act = a2

    if pending then
        if hp1 < pending.hp then
            hits = hits + 1
            bump(by_move, pending.name, "hits")
            log("  HIT   %s for %d at gap=%d dog1=%d",
                pending.name, pending.hp - hp1, pending.gap, pending.h1)
            pending = nil
        elseif frame - pending.frame > 14 then
            settle()
        end
    end

    -- GIVE THE BAR BACK WHENEVER NOTHING IS BEING MEASURED.  Grounded is the
    -- normal case; the `hp1 < 0x40` arm is the emergency one.  Four connected
    -- 40-damage punishes in a row killed him, the round then half-ended
    -- (winner_status is stomped to 0 every frame) and both fighters stood in
    -- act_stance forever -- a wedge that reads exactly like the drone having
    -- stopped reacting.  Refilling on EVERY frame instead is not the fix: it
    -- wedged the game outright inside 50 ticks.
    -- ...AND NOT WHILE HE IS BEING SLAMMED.  Every run was ending on the same
    -- stall: p2 in act_bodyslam for 700+ ticks with nothing else happening.
    -- The drone's slam does not finish while the victim's bar keeps being
    -- handed back, so let those hits land; the round is kept alive by the
    -- refill that resumes the moment he is dropped.
    if not pending and not air_pending and a2 ~= ACT_SLAM
       and (d1 <= 0x46 or hp1 < 0x40) then
        w16(A.p1_bar, MAX_HP)
    end
    w16(A.p1_bar_view, MAX_HP)

    if (frame % 300) == 0 then
        local okp, pcv = pcall(function()
            return manager.machine.devices[":maincpu"].state["PC"].value
        end)
        log("  .. rel=%d st=%s gap=%d dfg=%d dog1=%d p1=%04x p2=%04x hp1=%d hp2=%d "
            .. "ws=%d gs=%d x1=%s x2=%s pc=%s dives=%d blk=%d sw=%d wh=%d",
            frame - run_start, st, gap, g1, d1, a1, a2, hp1, r16(A.p2_bar),
            ws_seen, gs, tostring(x1), tostring(x2),
            okp and string.format("%08x", pcv) or "?",
            dives, blocked, swings, whiffs)
    end

    if frame - run_start > RUN_FRAMES then finish(); return end
    if last_progress > 0 and frame - last_progress > 700 then
        -- WHERE IS THE CPU?  A stall with both fighters frozen in place and
        -- the joystick ignored is a HUNG GAME, not a rig that ran out of
        -- things to do - and the two read identically from action ids alone.
        -- The PC, sampled over a few frames, says which: one address (or a
        -- tight cluster) is a spin; addresses all over the program is a
        -- running game.  Resolve with: python sym_resolve.py <pc>
        local pcs = {}
        local ok, st_pc = pcall(function()
            return manager.machine.devices[":maincpu"].state["PC"].value
        end)
        log("STALL no dive for %d frames (st=%s gap=%d p1=%04x p2=%04x pc=%s) -- closing "
            .. "the run with what it has", frame - last_progress, st, gap, a1, a2,
            ok and string.format("%08x", st_pc) or "unreadable")
        -- CRASH or WEDGE?  The two stalls look identical from action ids.  A PC
        -- inside illegal_opcode .. errort (MKBUG.ASM: the TRAP 30 handler and
        -- its `recovery: jauc $`) is a CPU that jumped into garbage; anywhere
        -- else the game is still running and the rig is what stopped.
        local lo, hi = sym("illegal_opcode"), sym("errort")
        local verdict = "WEDGE"
        if ok and st_pc and lo ~= 0 and hi ~= 0 and st_pc >= lo and st_pc < hi + 0x40 then
            verdict = "CRASH"
        end
        log("STALL-VERDICT %s (pc=%s, trap handler %08x..%08x)", verdict,
            ok and string.format("%08x", st_pc) or "?", lo, hi)
        -- WHO JUMPED INTO GARBAGE?  illegal_opcode (MKBUG.ASM) audits and then
        -- parks at `recovery: jauc $` - it saves nothing.  But the TMS34010
        -- trap itself pushed ST and the faulting PC onto the SYSTEM stack, and
        -- aud1 returned, so they are still sitting at SP.  Dump a few longs
        -- there; the one that resolves into real code is the culprit.
        -- (space:read takes the raw bit-address map form, same as sym().)
        -- The register's name in MAME's tms340x0 state table is not certain
        -- ("SP" vs "A15" - the 34010 stack pointer IS A15), and a wrong name
        -- would silently skip the dump, so try both and say which answered.
        local spname, oks, spv = nil, false, nil
        for _, nm in ipairs({"SP", "A15", "R15"}) do
            local okn, v = pcall(function()
                return manager.machine.devices[":maincpu"].state[nm].value
            end)
            if okn and v then spname, oks, spv = nm, true, v; break end
        end
        if oks and spv then
            local words = {}
            for k = 0, 5 do
                local okw, w = pcall(function() return space:read_u32(spv + k * 0x20) end)
                words[#words + 1] = okw and string.format("%08x", w) or "????????"
            end
            log("STALL-STACK %s=%08x longs: %s  (resolve each with sym_resolve.py)",
                spname, spv, table.concat(words, " "))
        else
            local names = {}
            pcall(function()
                for k in pairs(manager.machine.devices[":maincpu"].state) do names[#names + 1] = k end
            end)
            log("STALL-STACK stack pointer unreadable; cpu state names: %s", table.concat(names, " "))
        end
        -- THE REGISTERS NAME THE CULPRIT.  doc/DRONE_BEWARE_REENTRY.md: at the
        -- last TRAP 30 freeze, A7 held the instruction AFTER the retp that
        -- jumped into RAM, and A1/A3 identified the routine around it.  Dump
        -- them all; anything that resolves into MKDRONE/MOVES code is a lead.
        -- (Its own do..end, AFTER the stack if/else - wedged between the two
        -- it made MAME refuse the whole script: "'end' expected near 'else'",
        -- which then read exactly like MAME parked on the warning box.)
        do
            local cpu = manager.machine.devices[":maincpu"]
            local regs = {}
            for _, nm in ipairs({"PC","ST","A0","A1","A2","A3","A4","A5","A6","A7",
                                 "A8","A9","A10","A11","A12","A13","A14"}) do
                local okr, v = pcall(function() return cpu.state[nm].value end)
                regs[#regs + 1] = nm .. "=" .. (okr and v and string.format("%08x", v) or "?")
            end
            -- which process is A13?  compare against the fighters' own
            -- process pointers (the p?_proc SLOTS hold pointers; read them)
            local p1p = r32(A.p1_proc)
            local p2p = r32(A.p2_proc)
            log("STALL-REGS %s  p1_proc->%08x p2_proc->%08x", table.concat(regs, " "), p1p, p2p)
        end
        finish(); return
    end
    if frame > 45000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
