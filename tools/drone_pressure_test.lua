-- drone_pressure_test.lua
--
-- Can the drone be beaten by mashing ONE move?
--
-- That is the honest test of "is the CPU easy". A player who finds a poke the
-- CPU has no answer to will repeat it until the round ends, and every MK2
-- drone in the wild loses to exactly that. The opponent model (drone_learn /
-- drone_predict, doc/AI_DRONE.md) exists to make repetition stop working, so
-- this measures whether it does.
--
-- The player throws the SAME attack on a fixed cadence for the whole fight.
-- The run is split into thirds and damage is reported per third:
--
--   adapting   damage taken in the last third < the first third
--   flat       the drone eats it at the same rate forever
--
-- Both bars are topped back up whenever they drop, so the round never ends
-- and the sample keeps running; damage is ACCUMULATED as it happens rather
-- than read off the bar at the end.
--
-- Also reported, because "took less damage" has several possible causes and
-- they are not equally good:
--   blocks     drone entered act_blockhi/act_blocklo
--   dealt      damage the drone did back (it may be winning the exchange
--              rather than merely surviving it)
--
-- NOT a pass/fail on damage: a drone that eats a well-spaced poke is not
-- necessarily broken, and one number cannot say. It fails only if the rig
-- itself did not work (too few attacks landed to measure anything).
--
-- Action ids come from MAINEQU.ASM -- never hardcode them, see the anti-air
-- harness comment for what that costs.
--
-- TWO STYLES, and only one of them is worth much:
--
--   mash    the player throws the poke and never blocks.  Measured first and
--           it answered nothing: 104 attacks, drone took 30 and dealt 4546.
--           A player with no defence loses to ANY opponent, so a good score
--           here is not evidence of a good drone.  Kept only as a sanity
--           check that the rig can fight at all.
--
--   turtle  the player holds BLOCK and pokes out of it occasionally.
--           Measured: drone dealt 1050 (6.5 bars) and took 0, so passive
--           turtling does NOT beat it.  Kept as a regression check.
--
--   duckupper  the player CROUCHES permanently and uppercuts whenever the
--           drone walks into range.  This is the reported exploit -- "I can
--           literally just duck and uppercut the whole way through the
--           game" -- and it is a completely different thing from turtling:
--           it is an active punish, not passive defence.  The drone cannot
--           REACT to it (the uppercut is live ~2 ticks after the button and
--           drone_react_delay floors at 3), so the only honest answer is
--           spacing: every character's sweep out-ranges every character's
--           uppercut by 6-31 px.  `taken` is the number that matters here.
--
-- Env: PRESSURE_LOG, PRESSURE_DIFF, PRESSURE_CHAR, PRESSURE_MOVE, PRESSURE_STYLE
-- Usage: tools\run_drone_pressure_test.ps1

local LOGP = os.getenv("PRESSURE_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_pressure_test.log"
local DIFF = tonumber(os.getenv("PRESSURE_DIFF") or "9")
local CHAR = (os.getenv("PRESSURE_CHAR") or "raiden"):lower()
local MOVE = (os.getenv("PRESSURE_MOVE") or "hp"):lower()
local STYLE = (os.getenv("PRESSURE_STYLE") or "turtle"):lower()
-- backjump: the player repeatedly jumps BACKWARD. Reported symptom is that
-- the drone mirrors it and ends up airborne too -- and an airborne fighter
-- cannot block, so any air projectile that follows is unblockable. The
-- precondition is simply "both off the ground at once", which is what this
-- counts; it needs no projectile to measure.

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[pressure] " .. string.format(fmt, ...)
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
local ACT_BLOCKHI, ACT_BLOCKLO = act("act_blockhi"), act("act_blocklo")

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
local PDATA = 0x100
local PROC_ACTION = PDATA + 0x0f0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

local CHARS = { raiden = 7, scorpion = 10, kitana = 4, jax = 11, subzero = 8, liukang = 1,
                hathead = 0, cage = 2, baraka = 3, mileena = 5, shang = 6, reptile = 9,
                smoke = 14, noob = 15, jade = 16 }
local SUBJECT = CHARS[CHAR] or 7
local FT_KANG = 1
-- The HUMAN's character. Was hardcoded to Liu Kang, which makes this rig
-- useless for "does <character>'s <move> actually connect" - the question that
-- brought Jade's high kick here.
--
-- HIDDEN FIGHTERS DO NOT WORK AS P1 HERE. Jade (16), Smoke (14) and Noob (15)
-- are unlocked by a select-screen ritual, and simply writing p1_char never
-- confirms: measured, PRESSURE_P1=jade reaches the select screen and then
-- never reaches a fight at all, while the same fighter as the DRONE
-- (PRESSURE_CHAR=jade) fights perfectly well. That is this rig, not the game.
-- To measure a hidden fighter as the human, use the test_mode build instead
-- (test_p1_char in MKAMODE.ASM), which boots straight into a fight and skips
-- the select screen entirely.
local P1CHAR = CHARS[(os.getenv("PRESSURE_P1") or "liukang"):lower()] or FT_KANG
local P2_HUMAN = (os.getenv("PRESSURE_P2_HUMAN") or "0") ~= "0"

local BUTTON = ({ hp = "P1 High Punch", lp = "P1 Low Punch",
                  hk = "P1 High Kick",  lk = "P1 Low Kick" })[MOVE] or "P1 High Punch"

local ATTACK_PERIOD = 45      -- mash: one poke roughly every 0.75s
local TURTLE_PERIOD = 100     -- turtle: drop the guard to poke this often
local TURTLE_POKE   = 8       -- ...for this many frames
local CLOSE_GAP     = 0x48    -- walk in to about jab range
local RUN_FRAMES    = 9000

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start = 0
local fields = {}
local done = false

local taken, dealt = 0, 0            -- accumulated damage, both directions
local third_taken = {0, 0, 0}
local third_dealt = {0, 0, 0}
local blocks = 0
local was_block = false
local prev_p2, prev_p1 = MAX_HP, MAX_HP
local hit_sizes = {}   -- bar drop -> how many times it happened
local attacks = 0
local p1_forward = "R"
local p1_air_frames, both_air_frames, both_air_events = 0, 0, 0
local was_both_air = false

-- "fight" style: a scripted opponent that actually PLAYS, instead of doing
-- one thing forever. Every other style here measures the drone against a
-- punchbag, which flatters it -- an idle opponent never blocks, never spaces,
-- never punishes, so "the drone dealt 2320" says less than it appears to.
--
-- It is held to the same honesty rule as the drone: it reads the drone's
-- VISIBLE action category and positions, never internal state.
local f_block, f_fwd, f_back, f_up, f_down = false, false, false, false, false
local f_btn = nil       -- which attack button to hold this frame

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

-- height off the floor, same basis as distance_off_ground: p_ganiy is where
-- the anchor sits when standing, and oypos shrinks going up.
local PROC_GANIY = PDATA + 0x100
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
    log("RESULT char=%s move=%s diff=%d  attacks=%d  taken=%d dealt=%d blocks=%d",
        CHAR, MOVE, DIFF, attacks, taken, dealt, blocks)
    do
        local ks = {}
        for k in pairs(hit_sizes) do ks[#ks+1] = k end
        table.sort(ks)
        local parts = {}
        for _, k in ipairs(ks) do parts[#parts+1] = string.format("%dx%d", k, hit_sizes[k]) end
        log("  hit sizes taken: [%s]", table.concat(parts, " "))
    end
    log("  taken by third : %d / %d / %d", third_taken[1], third_taken[2], third_taken[3])
    log("  dealt by third : %d / %d / %d", third_dealt[1], third_dealt[2], third_dealt[3])
    local fails = {}
    if attacks < 20 then
        fails[#fails+1] = string.format(
            "only %d attacks scripted - the rig never got into range, so this measures nothing", attacks)
    end
    if taken == 0 and dealt == 0 then
        fails[#fails+1] = "neither fighter took a point of damage - the rig is not fighting"
    end
    if #fails > 0 then
        log("INVALID pressure: %s", table.concat(fails, "; "))
    elseif STYLE == "fight" then
        log("MEASURED pressure[%s/fight/diff%d]: a scripted opponent that blocks, spaces, pokes and anti-airs",
            CHAR, DIFF)
        log("  drone took %d (%d.%02d bars), dealt %d (%d.%02d bars)",
            taken, taken*100//MAX_HP//100, (taken*100//MAX_HP)%100,
            dealt, dealt*100//MAX_HP//100, (dealt*100//MAX_HP)%100)
        log("  taken by third: %d / %d / %d   dealt by third: %d / %d / %d",
            third_taken[1], third_taken[2], third_taken[3],
            third_dealt[1], third_dealt[2], third_dealt[3])
        log("  drone blocked %d time(s); both-airborne windows: %d", blocks, both_air_events)
        -- A scripted opponent that cannot hurt the drone is a punchbag, and a
        -- good score against a punchbag is not evidence of anything. Half a
        -- life bar over the whole run is the floor for calling this a fight.
        if taken < MAX_HP // 2 then
            log("  INVALID: the opponent only did %d damage in %d frames - too weak to measure against",
                taken, RUN_FRAMES)
        elseif dealt > taken * 2 then
            log("  VERDICT: drone comfortably ahead against a real opponent")
        elseif dealt > taken then
            log("  VERDICT: drone ahead but it is a fight")
        else
            log("  VERDICT: the scripted opponent is BEATING the drone (%d vs %d)", taken, dealt)
        end
    elseif STYLE == "backjump" then
        local pct = (p1_air_frames > 0) and (both_air_frames * 100 // p1_air_frames) or 0
        log("MEASURED pressure[%s/backjump/diff%d]: %d back-jumps", CHAR, DIFF, attacks)
        log("  player airborne %d frames; drone ALSO airborne %d of them (%d%%), in %d separate events",
            p1_air_frames, both_air_frames, pct, both_air_events)
        log("  drone took %d, dealt %d", taken, dealt)
        if both_air_events == 0 then
            log("  VERDICT: the drone never left the ground with him - no unblockable window")
        else
            log("  VERDICT: %d window(s) where an air projectile would be UNBLOCKABLE", both_air_events)
        end
    elseif STYLE == "duckupper" then
        -- `taken` is the exploit's score: damage the crouching player got for
        -- doing nothing but waiting. `dealt` says whether the drone found any
        -- answer at all.
        local tb = taken * 100 // MAX_HP
        local db = dealt * 100 // MAX_HP
        log("MEASURED pressure[%s/duckupper/diff%d]: %d uppercuts thrown", CHAR, DIFF, attacks)
        log("  drone TOOK  %d (%d.%02d life bars)  by third: %d / %d / %d",
            taken, tb // 100, tb % 100, third_taken[1], third_taken[2], third_taken[3])
        log("  drone DEALT %d (%d.%02d life bars)  by third: %d / %d / %d",
            dealt, db // 100, db % 100, third_dealt[1], third_dealt[2], third_dealt[3])
        if taken > dealt then
            log("  VERDICT: EXPLOIT CONFIRMED - crouching and waiting beats the drone (%d vs %d)",
                taken, dealt)
        elseif taken * 2 > dealt then
            log("  VERDICT: still very strong for the player - %d vs %d", taken, dealt)
        else
            log("  VERDICT: the drone is winning through it - %d taken vs %d dealt", taken, dealt)
        end
    elseif STYLE == "turtle" then
        -- Against a blocker the question is only: can the drone open him up?
        -- Reported as damage per 1000 frames so different run lengths compare.
        local rate = dealt * 1000 // RUN_FRAMES
        local bars = dealt * 100 // MAX_HP
        log("MEASURED pressure[%s/turtle/diff%d]: drone dealt %d (%d.%02d life bars) = %d per 1000 frames",
            CHAR, DIFF, dealt, bars // 100, bars % 100, rate)
        log("  opening rate by third: %d / %d / %d",
            third_dealt[1], third_dealt[2], third_dealt[3])
        if dealt == 0 then
            log("  VERDICT: the drone CANNOT open a guard at all - turtling beats it outright")
        elseif bars < 100 then
            log("  VERDICT: under one life bar in %d frames - turtling is still very strong",
                RUN_FRAMES)
        else
            log("  VERDICT: the drone opens the guard and keeps scoring")
        end
        log("  (drone took %d back from the pokes)", taken)
    else
        local first, last = third_taken[1], third_taken[3]
        local verdict
        if first == 0 then
            verdict = "took nothing in the first third - already immune to this poke"
        elseif last < first * 0.75 then
            verdict = string.format("ADAPTING - last third %d vs first %d (%d%% less)",
                last, first, 100 - (last * 100 // math.max(first, 1)))
        elseif last > first * 1.25 then
            verdict = string.format("DEGRADING - last third %d vs first %d", last, first)
        else
            verdict = string.format("FLAT - last third %d vs first %d (repetition keeps working)",
                last, first)
        end
        log("MEASURED pressure[%s/%s/diff%d]: %s", CHAR, MOVE, DIFF, verdict)
        log("  exchange: drone took %d, dealt %d (%s)", taken, dealt,
            dealt > taken and "drone is winning the exchange" or "player is winning the exchange")
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Low Punch"]=true, ["P1 High Kick"]=true, ["P1 Low Kick"]=true,
                   ["P1 Right"]=true, ["P1 Left"]=true, ["P1 Block"]=true,
                   ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local walk_in = false
local upper_now = false
local UPPER_RANGE = 0x5a       -- swing when he is inside uppercut reach (~90)
local upper_cool  = 0          -- frame the next uppercut is allowed
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
    if STYLE == "fight" then
        if name == "P1 Block" then return f_block end
        if name == "P1 Up"    then return f_up end
        if name == "P1 Down"  then return f_down end
        if name == (p1_forward == "L" and "P1 Left" or "P1 Right") then return f_fwd end
        if name == (p1_forward == "L" and "P1 Right" or "P1 Left") then return f_back end
        return name == f_btn
    end
    if STYLE == "backjump" then
        -- jump away, land, repeat
        local t2 = (frame - fighting_frame) % 90
        local jumping = t2 < 8
        if name == "P1 Up" then return jumping end
        if name == (p1_forward == "L" and "P1 Right" or "P1 Left") then return jumping end
        return false
    end
    if STYLE == "duckupper" then
        -- Crouch forever; uppercut (Down+HP) whenever he walks into range.
        -- Deliberately never walks forward: the whole exploit is that the
        -- CPU comes to you.
        if name == "P1 Down" then return true end
        if name == "P1 High Punch" then return upper_now end
        return false
    end
    if STYLE == "turtle" then
        -- Hold block; drop it briefly to poke. Deliberately does NOT walk in:
        -- a turtle waits for you to come to him, and letting the rig march
        -- forward would hand the drone free openings it did not earn.
        local t = (frame - fighting_frame) % TURTLE_PERIOD
        local poking = t < TURTLE_POKE
        if name == "P1 Block" then return not poking end
        if name == BUTTON then return poking end
        return false
    end
    -- mash: walk toward him when out of range, otherwise poke on the cadence
    if walk_in then
        return name == (p1_forward == "L" and "P1 Left" or "P1 Right")
    end
    if name == BUTTON then
        local t = (frame - fighting_frame) % ATTACK_PERIOD
        return t < 4
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- pressure: P1 mashes %s every %d frames vs %s drone, diff=%d ----",
            MOVE:upper(), ATTACK_PERIOD, CHAR, DIFF)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        -- P2_HUMAN makes P2 a passive HUMAN instead of the drone: MKGUYS.ASM
        -- picks joy_2_proc over drone_2_proc purely on ps_active, so this is
        -- the game's own switch. Nothing drives P2's stick, so it stands there
        -- and eats every hit -- which is what you want when measuring DAMAGE
        -- rather than AI, because a drone blocks and the sample vanishes.
        w16(A.p2_state, P2_HUMAN and PS_ACTIVE or PS_INACTIVE)
        w16(A.p1_char, P1CHAR)
        w16(A.p2_char, SUBJECT)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        run_start = frame
        prev_p1, prev_p2 = r16(A.p1_bar), r16(A.p2_bar)
        log("fight start frame=%d", frame)
        -- The damage gate in JOY.ASM (xlate_secret) asks "is this side
        -- ps_active", which is the same question MKGUYS.ASM asks to spawn
        -- joy_2_proc instead of drone_2_proc. That is only sound if the flag
        -- STAYS set for a human once the fight is running, so print it.
        log("  p1_state=%d p2_state=%d  (ps_active=%d -> human)",
            r16(A.p1_state), r16(A.p2_state), PS_ACTIVE)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= DIFF then w16(A.diff, DIFF) end
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    if A.rand ~= 0 then
        w32(A.rand, (r32(A.rand) * 1103515245 + frame * 12345) & 0xffffffff)
    end

    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then p1_forward = (x1 < x2) and "R" or "L" end
    local gap = (x1 and x2) and math.abs(x2 - x1) or 999
    walk_in = gap > CLOSE_GAP

    -- duckupper: swing when he walks into uppercut range, then respect the
    -- move's own recovery before swinging again (a human cannot mash it).
    if STYLE == "duckupper" then
        if gap <= UPPER_RANGE and frame >= upper_cool then
            upper_now = true
            upper_cool = frame + 40
            attacks = attacks + 1
        elseif frame >= upper_cool - 34 then
            upper_now = false          -- 6-frame press, then release
        end
    end

    local rel = frame - run_start
    local idx = math.min(3, rel * 3 // RUN_FRAMES + 1)

    -- ---- accumulate damage BEFORE topping the bars back up ----
    local p1, p2 = r16(A.p1_bar), r16(A.p2_bar)
    if p2 < prev_p2 then
        local d = prev_p2 - p2
        taken = taken + d; third_taken[idx] = third_taken[idx] + d
        -- PER-HIT sizes, not just the total. Totals cannot answer "does this
        -- character take scaled damage", because the drone blocks and moves,
        -- so two characters land different numbers of hits. One hit's bar drop
        -- is the number that compares cleanly across characters.
        hit_sizes[d] = (hit_sizes[d] or 0) + 1
    end
    if p1 < prev_p1 then
        local d = prev_p1 - p1
        dealt = dealt + d; third_dealt[idx] = third_dealt[idx] + d
    end
    -- top both back up so the round never ends
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    prev_p1, prev_p2 = MAX_HP, MAX_HP

    -- ---- scripted fighter ----
    if STYLE == "fight" then
        f_block, f_fwd, f_back, f_up, f_down, f_btn = false,false,false,false,false,nil
        local a2  = proc_act(A.p2_proc)
        local cat = (a2 ~= 0xffff) and (a2 >> 8) or 0
        local h2  = height(A.p2_proc, A.p2_obj)
        local ph  = (frame - fighting_frame) % 240

        if (cat == 1 or cat == 2) and gap < 0x90 then
            -- he committed to something: block it, and duck-block lows
            f_block = true
            f_down  = (a2 == 0x0106 or a2 == 0x0104)   -- sweep / lo kick
        elseif h2 >= 0x18 and gap < 0x70 then
            f_down, f_btn = true, "P1 High Punch"      -- anti-air uppercut
        elseif gap > 0x90 then
            if ph < 120 then f_fwd = true              -- close the distance
            else f_up, f_back = true, true end         -- ...or jump away
        elseif ph < 30 then
            f_btn = "P1 High Punch"                    -- jab
        elseif ph < 46 then
            f_btn = "P1 Low Punch"                     -- ...into a second hit
        elseif ph < 70 then
            f_down, f_btn = true, "P1 Low Kick"        -- sweep
        elseif ph < 86 then
            f_down, f_btn = true, "P1 High Punch"      -- uppercut
        elseif ph < 110 then
            f_up, f_fwd = true, true                   -- jump in
        elseif ph < 140 then
            f_btn = "P1 High Kick"                     -- roundhouse
        elseif ph < 160 then
            f_back = true                              -- reset spacing
        elseif ph < 190 then
            f_fwd, f_btn = true, "P1 High Punch"       -- walk in swinging
        else
            f_block = true                             -- and take a breath
        end
        if ((frame - fighting_frame) % 40) == 0 then attacks = attacks + 1 end
    end

    -- ---- airborne bookkeeping (backjump + fight) ----
    if STYLE == "backjump" or STYLE == "fight" then
        local h1 = height(A.p1_proc, A.p1_obj)
        local h2 = height(A.p2_proc, A.p2_obj)
        local a1air, a2air = h1 >= 0x10, h2 >= 0x10
        if a1air then p1_air_frames = p1_air_frames + 1 end
        local both = a1air and a2air
        if both then both_air_frames = both_air_frames + 1 end
        if both and not was_both_air then
            both_air_events = both_air_events + 1
            log("BOTH-AIR #%-2d  p1_h=%d p2_h=%d frame=%d", both_air_events, h1, h2, rel)
        end
        was_both_air = both
        if STYLE == "backjump" and ((frame - fighting_frame) % 90) == 0 then
            attacks = attacks + 1
        end
    end

    -- ---- count attacks actually thrown and blocks put up ----
    if STYLE ~= "duckupper" then    -- duckupper counts its own swings above
        local period = (STYLE == "turtle") and TURTLE_PERIOD or ATTACK_PERIOD
        if (STYLE == "turtle" or not walk_in) and ((frame - fighting_frame) % period) == 0 then
            attacks = attacks + 1
        end
    end
    local a2 = proc_act(A.p2_proc)
    local blocking = (a2 == ACT_BLOCKHI or a2 == ACT_BLOCKLO)
    if blocking and not was_block then blocks = blocks + 1 end
    was_block = blocking

    if (rel % 1500) == 0 and rel > 0 then
        log("  .. rel=%d gap=%d attacks=%d taken=%d dealt=%d blocks=%d",
            rel, gap, attacks, taken, dealt, blocks)
    end

    if rel > RUN_FRAMES then finish(); return end
    if frame > 45000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
