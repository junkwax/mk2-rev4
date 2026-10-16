-- drone_antiair_test.lua
--
-- Does the CPU punish a jump-in, and does it ever swing at nothing?
--
-- Jumping in is the most common thing a player does, and the drone's whole
-- answer was a guard (stalk_airborn_med/far) or a high kick that trades
-- (rt_airborn_close).  The uppercut -- which in MK2 IS the anti-air -- was
-- in neither list.  drone_antiair_try adds it, gated on him being visibly
-- airborne, visibly coming towards me, and actually inside strike table
-- 008h before it swings.
--
-- WHAT IS MEASURED, per scripted jump-in:
--   MET      an uppercut (act_uppercut) came out while the player was
--            airborne or within a few frames of landing
--   WHIFF    an uppercut came out with the player NOT in range -- the
--            failure that matters most.  A whiffed uppercut is the most
--            punishable thing in the game, so an anti-air that swings at
--            nothing is strictly worse than no anti-air at all.
--   damage   the player's bar actually dropping, which is the honest
--            signal that the uppercut connected rather than merely fired
--
-- HONESTY CONTROL: -Diff 0.  rpt_antiair is 0 there, so the easy CPU must
-- score ZERO anti-airs.  A non-zero count at diff 0 means the gate is not
-- reading difficulty at all.
--
-- The player jumps straight at the drone on a fixed cadence and does
-- nothing else, so every uppercut observed is a response to the jump.
--
-- RNG: @rand is reseeded from constants at round start, so a scripted rig
-- replays one stream and a single roll would decide every trial.  Stirred
-- every frame -- see doc/AI_DRONE.md, "the RNG stream will lie to you".
--
-- Env: ANTIAIR_LOG, ANTIAIR_DIFF, ANTIAIR_CHAR
-- Usage: tools\run_drone_antiair_test.ps1

local LOGP = os.getenv("ANTIAIR_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_antiair_test.log"
local DIFF = tonumber(os.getenv("ANTIAIR_DIFF") or "9")
local CHAR = (os.getenv("ANTIAIR_CHAR") or "raiden"):lower()
local SEED = tonumber(os.getenv("ANTIAIR_SEED") or "0")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[antiair] " .. string.format(fmt, ...)
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
}

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local PDATA        = 0x100
local PROC_ACTION  = PDATA + 0x0f0
-- p_juggle_step = pdata+2b0h (same derivation as drone_juggle_test.lua).
-- Non-zero = drone_juggle_try took the reaction and a combo script is running.
local PROC_JUGGLE  = PDATA + 0x2b0
local PROC_GANIY   = PDATA + 0x100
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

-- Action ids are .set equates, so they are NOT in MK2.MAP -- they have to be
-- read out of MAINEQU.ASM. Do NOT hardcode them: the first version of this
-- harness guessed act_uppercut = 0x0103 (it is 0x0107) and act_upcut_sd =
-- 0x0606 (it is 0x0603), and therefore scored a working anti-air as 0/39
-- while looking completely plausible. A wrong constant here is indis-
-- tinguishable from a broken feature.
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
local function act(n)
    local v = acts[n]
    if not v then log("FATAL: %s not found in MAINEQU.ASM", n) end
    return v or -1
end
local ACT_UPPERCUT, ACT_UPCUT_SD = act("act_uppercut"), act("act_upcut_sd")
local ACT_RHOUSE, ACT_HIKICK = act("act_rhouse"), act("act_hikick")

-- kunglao is 0, and 0 is truthy in Lua, so the `or 7` default below still
-- works for it.  reptile/kunglao added so every ochar_antiair row that is
-- not the default can actually be put under the rig.
local CHARS = { raiden = 7, scorpion = 10, kitana = 4, jax = 11, subzero = 8,
                reptile = 9, kunglao = 0 }
-- AN UNKNOWN NAME MUST NOT QUIETLY BECOME RAIDEN.
--
-- `CHARS[CHAR] or 7` used to swallow any typo, and worse: calling the wrapper
-- through `powershell -File ... -Char scorpion,raiden` passes ONE argument
-- rather than an array, so CHAR became the literal "scorpion,raiden", missed
-- the table, and the run silently tested raiden while its RESULT line read
-- `char=scorpion,raiden`.  It PASSED, and proved nothing about scorpion.
-- (Use the PowerShell tool, or one -Char per invocation, for multiples.)
local SUBJECT = CHARS[CHAR]
if not SUBJECT then
    log("FATAL: unknown ANTIAIR_CHAR '%s' -- known: raiden scorpion kitana jax "
        .. "subzero reptile kunglao.  NOT defaulting; this run proves nothing.", CHAR)
    SUBJECT = 7
    CHAR = CHAR .. "(UNKNOWN->raiden)"
end
local FT_KANG = 1

-- WHICH ACTION IS THIS CHARACTER'S ANTI-AIR.
--
-- The rig used to watch act_uppercut and nothing else, which was correct
-- while every character's anti-air WAS the uppercut.  ochar_antiair
-- (MKDRONE.ASM) ended that: Sub-Zero, Reptile and Scorpion answer with a
-- roundhouse and Kung Lao with a standing high kick.  Watching the uppercut
-- on one of those scores a perfectly good anti-air as zero -- a false
-- regression, and the kind that reads as "the feature is broken".
--
-- This table is kept in step with ochar_antiair BY HAND, and nothing here
-- checks that.  A row that disagrees with the ROM shows up as a met rate of
-- roughly zero with 0 whiffs -- which looks exactly like a broken anti-air.
-- If a character suddenly scores 0/N, read ochar_antiair before believing it.
local AA_BY_CHAR = {
    [8]  = ACT_RHOUSE,      -- sub-zero
    [9]  = ACT_RHOUSE,      -- reptile
    [10] = ACT_RHOUSE,      -- scorpion
    [0]  = ACT_HIKICK,      -- kung lao
}
local AA_ACT  = AA_BY_CHAR[SUBJECT] or ACT_UPPERCUT
local AA_NAME = (AA_ACT == ACT_RHOUSE and "roundhouse")
             or (AA_ACT == ACT_HIKICK and "high kick") or "uppercut"

-- "In range" for scoring: the uppercut box (008h) is ~0x60 wide, so anything
-- inside this when it fires had a real chance to connect.  Deliberately
-- generous - we are trying to catch the drone swinging at a man on the far
-- side of the screen, not to referee pixel-perfect spacing.
local IN_RANGE   = 0x70
local AIR_MIN    = 0x10
local JUMP_PERIOD = 170
local RUN_FRAMES = 7000

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start = 0
local fields = {}
local done = false

local jumps, met, whiffs, damaged = 0, 0, 0, 0
local others = 0   -- swings of the same move that were NOT jump-in answers
local was_air, was_uc = false, false
local jump_open, uc_this_jump = false, false
local p1_forward = "R"
local hp_at_uc = nil
local hp_window = nil  -- frame by which a connection must show up
local pending_uc = nil

-- LATENCY: how long after the player leaves the ground the drone's swing
-- actually comes out, in ticks.  This is the number a player feels as
-- "cheating" -- a human cannot press inside their own reaction time, so a
-- drone that answers in 3 or 4 ticks reads as a switch-read no matter how
-- honest the information it used.  Reported as a distribution, not a mean:
-- the machine signature is LOW SPREAD (always the same tick), and a mean
-- alone hides that completely.
local jump_open_frame = nil
local latencies = {}

-- COMBO LAUNCHES ON A PLAIN JUMP-IN.  drone_juggle_try is the anti-air high
-- punch, and until it was hooked into angle_towards_me its only call sites
-- were flip_towards_land_close and c_kano_sd -- neither of which is a jump-in.
-- This counts the thing that hook was added for, so "it fires" is measured
-- rather than assumed.
local combos, was_jug = 0, false
local combo_lat = {}

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
local function height(procptr, objptr)
    local q, o = r32(procptr), r32(objptr)
    if q == 0 or o == 0 then return 0 end
    local h = s16(r16(q + PROC_GANIY)) - s16(r16(o + OYPOS))
    if h < 0 then h = 0 end
    return h
end

local function finish()
    if done then return end
    done = true
    local rate = (jumps > 0) and (met * 100 // jumps) or 0
    log("RESULT char=%s diff=%d  jumps=%d  met=%d (%d%%)  whiffs=%d  connected=%d  other=%d",
        CHAR, DIFF, jumps, met, rate, whiffs, damaged, others)

    -- THE HUMANNESS NUMBER.  min/max/spread, not a mean: a drone that always
    -- answers on tick 7 and a drone that answers anywhere in 5..20 can share
    -- a mean and feel completely different across the cabinet.  Spread near
    -- zero IS the machine signature.
    log("COMBOS launched off a jump-in: %d", combos)
    if #combo_lat > 0 then
        table.sort(combo_lat)
        log("COMBOS  latencies: %s", table.concat(combo_lat, " "))
    end
    if #latencies > 0 then
        local lo, hi, sum = 999, -1, 0
        for _, v in ipairs(latencies) do
            if v < lo then lo = v end
            if v > hi then hi = v end
            sum = sum + v
        end
        table.sort(latencies)
        local list = table.concat(latencies, " ")
        log("LATENCY ticks from jump-start to swing: min=%d max=%d spread=%d mean=%d",
            lo, hi, hi - lo, sum // #latencies)
        log("LATENCY  ms: min=%d max=%d   (18.28ms per tick; human visual reaction ~200ms = 11 ticks)",
            math.floor(lo * 18.28), math.floor(hi * 18.28))
        log("LATENCY  all: %s", list)
    end
    local fails = {}
    if jumps < 5 then
        fails[#fails+1] = string.format("only %d jump-ins scripted - the rig never got going, so this proves nothing", jumps)
    elseif DIFF == 0 then
        if met > 0 then
            fails[#fails+1] = string.format("diff 0 anti-aired %d time(s) - rpt_antiair[0] is 0, so the gate is not reading difficulty", met)
        end
    else
        -- A rate floor, not "at least one". The first build of this scored
        -- 1/36 and PASSED a met>0 test, which is exactly the sort of green
        -- tick that hides a feature that is not really running. rpt_antiair
        -- rolls 60% at diff 9; the floor is set well under that because a
        -- roll that wins can still legitimately find no range before the
        -- patience runs out.
        --
        -- 20 -> 12 when is_he_uppercuttable got its descent gate.  THE OLD
        -- FLOOR WAS CALIBRATED AGAINST A BUILD THAT WAS CHEATING: 6 of
        -- Raiden's 14 baseline swings came out while the player was still
        -- RISING (1-2 ticks after leaving the floor), and they counted.  With
        -- those gone the honest rate over four runs is 16/27/22/17, mean 21 --
        -- so a floor of 20 sits ON the mean and fails half of all runs by
        -- construction.  A floor has to sit below the mean or it is measuring
        -- stream luck.  12 is under the observed minimum with room to spare
        -- and still four times the 2.7% "barely running" case above.
        local FLOOR = 12
        if rate < FLOOR then
            fails[#fails+1] = string.format(
                "only %d%% of jump-ins met (floor %d%%) - the reaction is barely reaching the roll",
                rate, FLOOR)
        end
    end
    if whiffs > 0 then
        fails[#fails+1] = string.format("%d %s(s) thrown with nobody in range", whiffs, AA_NAME)
    end
    if #fails == 0 then
        if DIFF == 0 then
            log("PASS antiair: diff 0 ate all %d jump-ins, as the easy CPU should", jumps)
        else
            log("PASS antiair: %d/%d jump-ins met (%d%%), %d connected, 0 swings at nothing",
                met, jumps, rate, damaged)
        end
    else
        log("FAIL antiair: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Up"]=true, ["P1 Right"]=true, ["P1 Left"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

-- Hold up+towards for a few frames: a diagonal jump straight at the drone.
local function jump_phase()
    local t = (frame - fighting_frame) % JUMP_PERIOD
    if t < 10 then return "jump" end
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
    local ph = jump_phase()
    if name == "P1 Up" then return ph == "jump" end
    if name == (p1_forward == "L" and "P1 Left" or "P1 Right") then return ph == "jump" end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- antiair: P1=LiuKang jumps in every %d frames, P2=%s(drone) diff=%d ----",
            JUMP_PERIOD, CHAR, DIFF)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, SUBJECT)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        run_start = frame
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= DIFF then w16(A.diff, DIFF) end
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    -- SEED shifts the whole stream.  This rig is otherwise deterministic --
    -- same build, same result, every run -- so a single rate cannot tell a
    -- real regression from one unlucky stream.  doc/AI_DRONE.md's rule is
    -- "shift the stream and re-run before believing it"; this is the knob
    -- that makes that possible.  Default 0 reproduces the historical runs.
    if A.rand ~= 0 then
        w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345 + SEED) & 0xffffffff)
    end

    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then p1_forward = (x1 < x2) and "R" or "L" end
    local gap = (x1 and x2) and math.abs(x2 - x1) or 999
    local h1 = height(A.p1_proc, A.p1_obj)
    local act2 = proc_act(A.p2_proc)
    local hp1 = r16(A.p1_bar)

    -- Keep the pair honestly spaced: nudge the DRONE is wrong (it overrides
    -- its walk), so nudge the idle-between-jumps player back out instead.
    if gap < 0x50 and jump_phase() == "idle" and (frame % 10) == 0 then
        local o = r32(A.p1_obj)
        if o ~= 0 and x1 and x2 then
            local nx = x1 + ((x1 < x2) and -5 or 5)
            if nx > 40 and nx < 360 then
                space:write_u32(o + OXVAL, (nx & 0xffff) << 16)
                w16(o + OXPOS, nx & 0xffff)
            end
        end
    end

    -- ---- count jump-ins ----
    local air = h1 >= AIR_MIN
    if air and not was_air then
        jumps = jumps + 1
        jump_open, uc_this_jump = true, false
        jump_open_frame = frame
    end
    if was_air and not air then
        -- landed: the jump is over 20 frames later (landing recovery still
        -- counts as "met" -- punishing the landing is the same read)
        pending_uc = frame + 20
    end
    was_air = air

    -- ---- the anti-air (whatever ochar_antiair gave this character) ----
    local uc = (act2 == AA_ACT)
    if uc and not was_uc then
        local inrange = (gap <= IN_RANGE)
        local live = jump_open or (pending_uc and frame <= pending_uc)
        -- ONLY SWINGS DURING A JUMP-IN COUNT AS ANTI-AIR ATTEMPTS.
        --
        -- This branch used to score a whiff without consulting `live`, which
        -- was harmless while the watched action was the uppercut: the drone
        -- barely throws one outside drone_antiair_try, so any uppercut was
        -- its anti-air.  The roundhouse and the high kick are NOT like that -
        -- they are general-purpose moves thrown from reaction handlers and
        -- close-range mixups all match long.  Counting those as failed
        -- anti-airs blamed drone_antiair_try for swings it never authored
        -- (measured: a roundhouse at gap=116 h1=87, which is outside BOTH of
        -- is_he_rhouseable's gates and so cannot have come from it).
        if not live then
            others = others + 1
            log("other %s (not a jump-in): gap=%d h1=%d frame=%d",
                AA_NAME, gap, h1, frame - run_start)
        elseif not inrange then
            whiffs = whiffs + 1
            log("WHIFF %s with gap=%d (h1=%d) frame=%d", AA_NAME, gap, h1, frame - run_start)
        elseif not uc_this_jump then
            met = met + 1
            uc_this_jump = true
            hp_at_uc = hp1
            hp_window = frame + 12
            local lat = jump_open_frame and (frame - jump_open_frame) or -1
            if lat >= 0 then latencies[#latencies+1] = lat end
            log("MET  #%-2d jump-in met by %s: gap=%d h1=%d lat=%d frame=%d",
                met, AA_NAME, gap, h1, lat, frame - run_start)
        end
    end
    was_uc = uc

    -- ---- combo launcher (the anti-air HP) during a jump-in ----
    local jq = r32(A.p2_proc)
    local jstep = (jq ~= 0) and r16(jq + PROC_JUGGLE) or 0
    local jug = (jstep ~= 0)
    if jug and not was_jug then
        local live = jump_open or (pending_uc and frame <= pending_uc)
        if live then
            combos = combos + 1
            local lat = jump_open_frame and (frame - jump_open_frame) or -1
            if lat >= 0 then combo_lat[#combo_lat+1] = lat end
            log("COMBO #%-2d jump-in met by the aaHP launcher: step=%d gap=%d h1=%d lat=%d frame=%d",
                combos, jstep, gap, h1, lat, frame - run_start)
        end
    end
    was_jug = jug

    -- did the uppercut we just counted actually take health off him ?
    if hp_at_uc and hp1 < hp_at_uc then
        damaged = damaged + 1
        log("  .. connected for %d", hp_at_uc - hp1)
        hp_at_uc, hp_window = nil, nil
    end
    -- CLOSE THE WINDOW ON A SHORT CLOCK, NOT ON THE ACTION.
    --
    -- 12 frames, and the width matters in BOTH directions.  Tied to the
    -- action it could shut in one frame (see below) and under-counted; at 40
    -- frames it caught damage from entirely unrelated attacks and counted
    -- 9/9, including a "connection" of 40 on a move whose damage_hit is 30.
    -- ALWAYS read the `connected for N` amounts: stk_njroundh is 30 on hit
    -- and 8 on BLOCK, so N is what tells you which of those you measured.
    --
    -- This used to be `act2 ~= AA_ACT and act2 ~= AA_SD`, which worked only
    -- for the uppercut: act_upcut_sd is a real, distinct recovery state, so
    -- the window stayed open across the whole swing.  A kick has no such
    -- state -- AA_SD collapses to AA_ACT -- so the window shut the instant
    -- the action left act_rhouse, and do_roundhouse does `sleep 10` then
    -- retract_strike AFTER a hit.  Connections were being dropped at ranges
    -- that had demonstrably connected in earlier runs, which reads as the
    -- anti-air whiffing when it did not.
    if hp_at_uc and hp_window and frame > hp_window then
        hp_at_uc, hp_window = nil, nil
    end

    if jump_open and not air and (not pending_uc or frame > pending_uc) then jump_open = false end

    -- give his bar back between jumps so the round never ends
    if not air and not hp_at_uc then w16(A.p1_bar, MAX_HP) end
    w16(A.p1_bar_view, MAX_HP)

    if (frame % 900) == 0 then
        log("  .. rel=%d gap=%d h1=%d p2_act=0x%04x jumps=%d met=%d whiff=%d",
            frame - run_start, gap, h1, act2, jumps, met, whiffs)
    end

    if frame - run_start > RUN_FRAMES then finish(); return end
    if frame > 40000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
