-- drone_airzap_test.lua
--
-- Does the CPU throw a projectile FROM A JUMP, and does it convert a
-- connected flip kick into a follow-up?
--
-- Before this pass the drone had exactly one route to a projectile
-- (drone_zap_jsrp -> zap_offsets), and every entry in that table is a
-- GROUND zap.  So Jax's air lightwave, Kitana's air fan, Mileena's air sai,
-- Reptile's air spit, Sub-Zero's air ice and Liu Kang's air fireball were
-- player-only moves.  drone_air_zap_try adds the jump route, sharing
-- l_drone_zap so the total number of throws per round is unchanged.
--
-- WHAT IS MEASURED
--   AIRZAP   a projectile action (001h-016h) seen while the drone's feet
--            are off the floor.  Height, not action id, is the test: Jax's
--            air lightwave stamps the SAME act_jax_zap as his ground wave,
--            so the action alone cannot tell them apart.
--   GNDZAP   the same actions with his feet down - the stock behaviour,
--            reported so "it stopped throwing entirely" cannot be mistaken
--            for "it now throws from the air".
--   CONVERT  a flip kick that took health off the player, followed by a
--            projectile within CONVERT_WINDOW frames.  That string is what
--            drone_ajump_call always claimed to do and never did: the code
--            sat after `jsrp do_flip_kick`, which for a drone never returns
--            (do_land_animation -> drone_land -> reaction over).
--
-- HONESTY CONTROL: run with AIRZAP_CHAR set to a fighter with no air
-- projectile (raiden, scorpion).  AIRZAP must be 0 there or the height test
-- is picking up something that is not a throw.
--
-- RNG: @rand is re-seeded from constants at every round start, so a scripted
-- rig replays one stream and a single probability roll decides the whole run
-- identically.  We stir it every frame - without that, rpt_air_zap either
-- always hits or never does.
--
-- TWO MODES
--   zone     (default) an idle human; measures the jump-throw
--   convert  the human throws fireballs.  This is the ONLY way to see a CPU
--            flip kick: rt_drone_start is rolled once at round start and
--            never again, so every flip kick after that comes from the
--            projectile-avoidance reaction (standard_proj / ochar_avoid_pro).
--            An idle opponent therefore produces exactly zero of them, which
--            is why the pacing harness scores the flip kick need=0.
--
-- Env: AIRZAP_LOG, AIRZAP_CHAR, AIRZAP_DIFF, AIRZAP_MODE
-- Usage: tools\run_drone_airzap_test.ps1

local LOGP = os.getenv("AIRZAP_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_airzap_test.log"
local MODE = (os.getenv("AIRZAP_MODE") or "zone"):lower()
local CHAR = (os.getenv("AIRZAP_CHAR") or
              (MODE == "convert" and "scorpion" or "kitana")):lower()
local DIFF = tonumber(os.getenv("AIRZAP_DIFF") or "9")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[airzap] " .. string.format(fmt, ...)
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
    f_freeze_timer = sym("f_freeze_timer"), tick = sym("tick"),
    rand = sym("rand"),
    debug1 = sym("debug1"),
    debug2 = sym("debug2"), debug3 = sym("debug3"), debug4 = sym("debug4"),
}

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local PDATA        = 0x100              -- p_action is pdata+0f0h = 0x1f0
local PROC_ACTION  = PDATA + 0x0f0
local PROC_GANIY   = PDATA + 0x100      -- p_ganiy: my y when standing on the floor
local PROC_LANDNEXT= PDATA + 0x2b0      -- p_juggle_step, doubling as the
                                        -- landing-follow-up slot (dln_*)
local DLN_ZAP, DLN_PRESS, DLN_SWEEP = 0x10, 0x11, 0x12
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local ACT_FLYKICK = 0x0200

-- fanguard mode: P1 is KITANA throwing BOOMERANG fans (Forward,Forward +
-- HP+LP, HP held so fan_check_hp_held curves it back). The return leg is the
-- case bew_incoming_proj exists for: it generates no p_action change, so the
-- drone used to be blind to it. A Liu Kang fireball cannot test this - it is
-- fast enough that the throw reaction is still running when it arrives.
local FANGUARD = (MODE == "fanguard")
-- HUMAN FLOOR: a player's button handler refuses the throw inside this many
-- ticks of the last one (fn1lp3's l_throw_fan, fn2_hp_open's saicool,
-- sc_lo_punch's l_spear 066h).  The CPU must never beat it - drone_zap_legal.
-- floor_acts = the p_action values of that one projectile, ground and air:
-- the gap is measured between those only, so an unrelated special in the
-- 001h-016h range cannot fail the run.
local CHARS = {
    kitana   = { id = 4,  air = true,  name = "Kitana (air fan)",
                 floor = 0x80, floor_acts = { [0x08]=true, [0x09]=true } },
    mileena  = { id = 5,  air = true,  name = "Mileena (air sai)",
                 floor = 0x80, floor_acts = { [0x0a]=true, [0x0b]=true } },
    jax      = { id = 11, air = true,  name = "Jax (air lightwave)" },
    reptile  = { id = 9,  air = true,  name = "Reptile (air spit)" },
    subzero  = { id = 8,  air = true,  name = "Sub-Zero (air ice)" },
    liukang  = { id = 1,  air = true,  name = "Liu Kang (air fireball)" },
    raiden   = { id = 7,  air = false, name = "Raiden (CONTROL - no air zap)" },
    scorpion = { id = 10, air = false, name = "Scorpion (CONTROL - no air zap)",
                 floor = 0x66, floor_acts = { [0x11]=true } },
}
local floor_last, floor_min, floor_n = nil, nil, 0
local SUBJECT = CHARS[CHAR] or CHARS.kitana
local FT_KANG = 1

-- feet this far off the floor = genuinely airborne.  air_zap_height is 030h
-- and the throw animation runs for a few ticks after that, so anything this
-- test calls "air" is comfortably clear of a standing throw.
local AIR_MIN = 0x18
-- Liu Kang's uppercut box (stk_lkuppercut) is x_off 75 / x_size 53, so it
-- covers an x gap of roughly 22..75 and reaches 64px straight up. Anything
-- the drone does inside that gap while falling is a free uppercut for the
-- player. 80 is that reach rounded up one notch.
local UPPERCUT_GAP = 80
local CONVERT_WINDOW = 150
local RUN_FRAMES = 6000

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start = 0
local fields = {}
local done = false

local airzap, gndzap, converts, flipkicks = 0, 0, 0, 0
local was_proj, was_flip = false, false
-- GEOMETRY of each jump-throw: where he left the floor, where he let go, and
-- where he came down. An air zap that releases while he is standing on the
-- player's head is a free uppercut, not zoning, so the counters above cannot
-- score this move on their own.
local was_air = false
local takeoff_gap, takeoff_frame = nil, nil
local land_watch_gap, land_watch_rel, land_watch_jug = nil, nil, false
local geo = {}
local kick_armed_at, kick_hp = nil, nil
local max_air_height = 0
local arms = { [DLN_ZAP]=0, [DLN_PRESS]=0, [DLN_SWEEP]=0 }
-- Did the thing it threw from the air actually HIT? Release height alone
-- proves nothing: the old code released on the way UP, so the projectile
-- spawned near the apex and sailed over a standing opponent's head. Watch
-- his bar for a window after each air throw and attribute the drop.
local air_hits, air_watch, air_hp = 0, nil, nil
-- bew_incoming_proj guards a projectile ALREADY IN THE AIR. Count the drone
-- entering a block while one of his projectiles is live: before, the only
-- block came from reacting to the throw animation.
local guard_blocks, was_guard = 0, false
local fk_connected = 0   -- flip kicks that actually took health off him
local was_p1_proj = false
local last_arm = 0
local p1_zaps = 0
local p1_forward = "R"

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

-- height off the floor, the same way distance_off_ground computes it:
-- p_ganiy is where this fighter's anchor sits when he is standing on the
-- ground, and oypos shrinks as he rises.
local function height(procptr, objptr)
    local q, o = r32(procptr), r32(objptr)
    if q == 0 or o == 0 then return 0 end
    local g = s16(r16(q + PROC_GANIY))
    local y = s16(r16(o + OYPOS))
    local h = g - y
    if h < 0 then h = 0 end
    return h
end

local function finish()
    if done then return end
    done = true
    log("RESULT mode=%s char=%s diff=%d  AIRZAP=%d GNDZAP=%d FLIPKICK=%d CONVERT=%d maxair=%d",
        MODE, CHAR, DIFF, airzap, gndzap, flipkicks, converts, max_air_height)
    log("AIR PROJECTILES: %d thrown, %d CONNECTED", airzap, air_hits)
    -- Census from drone_air_zap_try (debug1): low byte = decisions that
    -- reached the range test, high byte = the ones that jump STRAIGHT UP
    -- because a forward flip has no runway (nothing is refused any more). A
    -- jump-throw is rare enough that AIRZAP=0 alone cannot tell "not rolled"
    -- from "gated off".
    if A.debug1 ~= 0 then
        local d = r16(A.debug1)
        log("AIRZAP DECISIONS: reached=%d  jump_up=%d  (taken=%d)",
            d & 0xff, (d >> 8) & 0xff, airzap)
    end
    if #geo > 0 then
        local bad, zoning = 0, 0
        for i, g in ipairs(geo) do
            local danger = (not g.jug) and
                           ((g.rel <= UPPERCUT_GAP) or (g.land <= UPPERCUT_GAP))
            if danger then bad = bad + 1 end
            if not g.jug then zoning = zoning + 1 end
            log("GEO  #%-2d takeoff=%-4d release=%-4d land=%-4d  %s", i,
                g.take, g.rel, g.land,
                g.jug and "juggle (exempt)" or
                (danger and "UPPERCUT BAIT" or "ok"))
        end
        log("GEO SUMMARY: %d/%d zoning jump-throws released or landed inside gap %d"
            .. "  (%d juggle conversion(s) exempt)",
            bad, zoning, UPPERCUT_GAP, #geo - zoning)
    end
    log("FLIP KICKS: %d thrown, %d CONNECTED", flipkicks, fk_connected)
    log("GUARD BLOCKS: %d   (p1 threw %d projectile(s))", guard_blocks, p1_zaps)
    -- breadcrumbs from bew_incoming_proj: saw a projectile / it was close /
    -- committed. Says exactly which gate the guard dies on.
    if A.debug2 ~= 0 then
        log("GUARD BREADCRUMBS: saw_proj=%d close_enough=%d committed=%d",
            r32(A.debug2), r32(A.debug3), r32(A.debug4))
    end
    if p1_zaps == 0 then
        log("INVALID: the rig never got a projectile out of p1 - measures nothing")
    end
    log("ARMS  zap=%d press=%d sweep=%d   (p1 projectile frames=%d)",
        arms[DLN_ZAP], arms[DLN_PRESS], arms[DLN_SWEEP], p1_zaps)
    local fails = {}
    if SUBJECT.floor then
        log("HUMAN FLOOR: %d throw(s), shortest gap %s ticks, a player's limit %d",
            floor_n, tostring(floor_min), SUBJECT.floor)
        if floor_min and floor_min < SUBJECT.floor then
            fails[#fails+1] = string.format(
                "threw twice %d ticks apart - a player cannot inside %d", floor_min, SUBJECT.floor)
        end
    end
    if MODE == "convert" then
        if flipkicks == 0 then
            fails[#fails+1] = "the drone never flip kicked - the rig never got it to react, so this run proves nothing"
        elseif arms[DLN_ZAP] == 0 then
            fails[#fails+1] = "flip kicks happened but dln_zap was never armed - drone_ajump_call is not arming"
        elseif converts == 0 then
            fails[#fails+1] = "armed but never converted - drone_land_next/dlf_zap did not fire"
        end
        if #fails == 0 then
            log("PASS convert: %d flip kick(s), %d armed, %d converted into a projectile",
                flipkicks, arms[DLN_ZAP], converts)
        else
            log("FAIL convert: %s", table.concat(fails, "; "))
        end
        manager.machine:exit()
        return
    end
    if SUBJECT.air then
        if airzap == 0 then
            fails[#fails+1] = "no air projectile in the whole run"
        end
        if gndzap == 0 and airzap == 0 then
            fails[#fails+1] = "no projectile of any kind - the drone never zoned, so this run proves nothing"
        end
    else
        if airzap > 0 then
            fails[#fails+1] = string.format(
                "CONTROL threw %d air projectile(s) - it has no air zap, so the height test is wrong", airzap)
        end
    end
    if #fails == 0 then
        if SUBJECT.air then
            log("PASS airzap: %s threw %d projectile(s) from a jump", SUBJECT.name, airzap)
        else
            log("PASS airzap: %s never threw from a jump, as it should not", SUBJECT.name)
        end
    else
        log("FAIL airzap: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Right"]=true, ["P1 Left"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

-- convert mode: Liu Kang high fireball is scom_lk_zaphi = Forward, Forward
-- + HP inside 024h ticks.  One throw per FB_PERIOD frames, which is slow
-- enough that the drone gets to finish reacting to each one.
local FB_PERIOD = 150
local function fireball_phase()
    local t = (frame - fighting_frame) % FB_PERIOD
    if t <  6 then return "fwd1" end
    if t < 12 then return "gap"  end
    if t < 18 then return "fwd2" end
    if t < 26 then return "punch" end
    return "idle"
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    if FANGUARD then
        -- Forward,Forward then both punches; keep HP held so it boomerangs.
        local ph = (frame - fighting_frame) % 200
        local fwd = (p1_forward == "L" and "P1 Left" or "P1 Right")
        if name == fwd then return ph < 6 or (ph >= 12 and ph < 18) end
        if name == "P1 Low Punch"  then return ph >= 24 and ph < 30 end
        if name == "P1 High Punch" then return ph >= 24 and ph < 90 end  -- HELD
        return false
    end
    if MODE ~= "convert" then return false end
    local ph = fireball_phase()
    -- "Forward" is towards the other fighter, whichever side we ended up on.
    if name == (p1_forward == "L" and "P1 Left" or "P1 Right") then
        return ph == "fwd1" or ph == "fwd2"
    end
    if name == "P1 High Punch" then return ph == "punch" end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- airzap: P1=LiuKang(idle human)  P2=%s(drone) diff=%d ----",
            SUBJECT.name, DIFF)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FANGUARD and 4 or FT_KANG)
        w16(A.p2_char, SUBJECT.id)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        run_start = frame
        log("fight start frame=%d (free-running; only health and the clock are held)", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= 0 then w16(A.diff, DIFF) end
    w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    -- Stir the RNG.  Without this the whole run is one roll (see doc/AI_DRONE.md,
    -- "the RNG stream will lie to you").
    if A.rand ~= 0 then
        w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345) & 0xffffffff)
    end

    local act = proc_act(A.p2_proc)
    local h = height(A.p2_proc, A.p2_obj)
    local hp1 = r16(A.p1_bar)
    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then p1_forward = (x1 < x2) and "R" or "L" end

    -- ---- the landing-follow-up slot itself ----
    -- Proves the arm/consume cycle directly, independent of whether the
    -- follow-up then found a legal move to make.
    local q2 = r32(A.p2_proc)
    local armv = (q2 ~= 0) and r16(q2 + PROC_LANDNEXT) or 0
    if armv ~= last_arm then
        if arms[armv] then
            arms[armv] = arms[armv] + 1
            log("ARM  0x%02x (%s) frame=%d height=%d", armv,
                armv == DLN_ZAP and "zap" or (armv == DLN_PRESS and "press" or "sweep"),
                frame - run_start, h)
        end
        last_arm = armv
    end

    -- convert mode: the flip-kick reaction needs real space (standard_proj
    -- refuses inside 0b6h).  NUDGE the idle human back rather than pinning
    -- the drone - pinning the drone overrides its walk and it never reaches
    -- the decision at all.
    if MODE == "convert" and x1 and x2 and math.abs(x2 - x1) < 0xd0 then
        local o = r32(A.p1_obj)
        if o ~= 0 and (frame % 8) == 0 then
            local nx = x1 + ((x1 < x2) and -6 or 6)
            if nx > 40 and nx < 360 then
                space:write_u32(o + OXVAL, (nx & 0xffff) << 16)
                w16(o + OXPOS, nx & 0xffff)
            end
        end
    end
    do  -- P1 projectile EVENTS (edge-counted), every mode.
        -- Counted always, because "the drone did not react" and "the rig
        -- never threw anything" look identical otherwise -- which is exactly
        -- how two earlier zeroes in this file wasted a run each.
        local a1 = proc_act(A.p1_proc)
        local inproj = (a1 >= 0x0001 and a1 <= 0x0016)
        if inproj and not was_p1_proj then
            p1_zaps = p1_zaps + 1
            log("  p1 threw a projectile (act=0x%04x) frame=%d", a1, frame - run_start)
        end
        was_p1_proj = inproj
    end

    -- ---- takeoff / landing, so a throw can be placed on the arc ----
    do
        local gap = (x1 and x2) and math.abs(x2 - x1) or -1
        local is_air = (h >= AIR_MIN)
        if is_air and not was_air then
            takeoff_gap, takeoff_frame = gap, frame
        elseif was_air and not is_air then
            if land_watch_gap then
                log("  LAND gap=%d (takeoff %d, release %d) -- %s",
                    gap, land_watch_gap, land_watch_rel,
                    land_watch_jug and "juggle conversion (exempt)" or
                    ((gap <= UPPERCUT_GAP) and "INSIDE HIS UPPERCUT" or "safe"))
                geo[#geo+1] = { take = land_watch_gap, rel = land_watch_rel,
                                land = gap, jug = land_watch_jug }
                land_watch_gap, land_watch_rel, land_watch_jug = nil, nil, false
            end
            takeoff_gap, takeoff_frame = nil, nil
        end
        was_air = is_air
    end

    -- ---- projectile events, split by whether his feet were down ----
    local is_proj = (act >= 0x0001 and act <= 0x0016)
    if is_proj and not was_proj and SUBJECT.floor and SUBJECT.floor_acts[act] then
        local t = r16(A.tick)
        floor_n = floor_n + 1
        if floor_last then
            local d = (t - floor_last) & 0xffff
            if not floor_min or d < floor_min then floor_min = d end
            log("  floor #%d act=0x%04x tick gap=%d (human floor %d)%s", floor_n, act, d,
                SUBJECT.floor, d < SUBJECT.floor and "  <-- FASTER THAN A PLAYER" or "")
        end
        floor_last = t
    end
    if is_proj and not was_proj then
        if h >= AIR_MIN then
            airzap = airzap + 1
            air_watch, air_hp = frame + 120, r16(A.p1_bar)
            if h > max_air_height then max_air_height = h end
            local gap = (x1 and x2) and math.abs(x2 - x1) or -1
            land_watch_gap = takeoff_gap or -1
            land_watch_rel = gap
            -- A throw that follows a connected flip kick is the JUGGLE
            -- conversion (drone_air_zap_juggle), which is point blank on
            -- purpose: the victim is in hitstun and has no uppercut to
            -- answer with. Scoring it as bait would condemn the one case
            -- the gap test cannot read.
            land_watch_jug = (kick_armed_at ~= nil) and
                             ((frame - kick_armed_at) <= CONVERT_WINDOW)
            log("AIR  #%-2d act=0x%04x height=%d  frame=%d  takeoff_gap=%d release_gap=%d%s",
                airzap, act, h, frame - run_start, takeoff_gap or -1, gap,
                (gap <= UPPERCUT_GAP) and "  <-- RELEASED IN UPPERCUT RANGE" or "")
        else
            gndzap = gndzap + 1
            log("gnd  #%-2d act=0x%04x height=%d  frame=%d", gndzap, act, h, frame - run_start)
        end
        -- flip kick conversion: a projectile inside the window after a kick
        -- that actually took health off him
        if kick_armed_at and (frame - kick_armed_at) <= CONVERT_WINDOW then
            converts = converts + 1
            log("CONVERT #%-2d  kick->projectile %d frames later (his bar %d -> %d)",
                converts, frame - kick_armed_at, kick_hp, hp1)
            kick_armed_at = nil
        end
    end
    was_proj = is_proj

    -- ---- flip kicks, and whether they connected ----
    local is_flip = (act == ACT_FLYKICK)
    if is_flip and not was_flip then
        flipkicks = flipkicks + 1
        kick_hp = hp1
        kick_armed_at = nil
    end
    if was_flip and not is_flip and kick_hp then
        if hp1 < kick_hp then
            kick_armed_at = frame      -- it landed: the conversion may follow
            fk_connected = fk_connected + 1
            log("  flip kick CONNECTED for %d", kick_hp - hp1)
        else
            log("  flip kick MISSED")
        end
    end
    was_flip = is_flip

    -- Did the air projectile actually land?  Release height alone proves
    -- nothing: the old code let go on the way UP, so the shot spawned near
    -- the apex and sailed over a standing opponent.  Watch his bar after each
    -- air throw and say CONNECTED or MISSED -- and report BOTH, because a
    -- silent counter that only ever prints 0 is indistinguishable from a
    -- harness that is not wired up (which is exactly what happened first).
    if air_watch then
        if hp1 < air_hp then
            air_hits = air_hits + 1
            log("  AIR PROJECTILE CONNECTED for %d", air_hp - hp1)
            air_watch, air_hp = nil, nil
        elseif frame > air_watch then
            log("  air projectile MISSED (no damage in 120 frames)")
            air_watch, air_hp = nil, nil
        end
    end

    -- Give the player his health back only once the kick has been scored, so
    -- healing him mid-string does not erase the very signal we are reading.
    if not kick_armed_at and not is_flip and not air_watch then
        w16(A.p1_bar, MAX_HP)
    end

    if (frame % 900) == 0 then
        log("  .. rel=%d gap=%d p2_act=0x%04x h=%d air=%d gnd=%d fk=%d conv=%d",
            frame - run_start, (x1 and x2) and math.abs(x2 - x1) or -1,
            act, h, airzap, gndzap, flipkicks, converts)
    end

    if frame - run_start > RUN_FRAMES then finish(); return end
    if frame > 40000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
