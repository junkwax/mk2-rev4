-- kahn_ladder_test.lua
--
-- Shao Kahn (P2, AI) vs ONE named opponent (P1, AI) at @diff 9, on Kahn's
-- Arena, and reports who took the match.
--
-- The pass bar is deliberately the hard one the brief asked for: Kahn has to
-- take BOTH rounds.  Winning 2-1 is logged as FAIL_DROPPED_ROUND, not a pass.
--
-- Both fighters are drones on purpose.  That is the only opponent available
-- to an unattended run, and the MK2 drone has had a dozen tuning passes on
-- it, so at diff 9 it blocks, punishes whiffs, anti-airs, throws and zones -
-- a far better stand-in for a competent human than a dummy that stands still.
-- It is also symmetric: @diff is global, so the opponent gets the same 9.
--
-- How P1 is made a drone: MKGUYS.ASM's setup_players picks drone_1_proc over
-- joy_1_proc purely on @p1_state != ps_active, and it runs AFTER round_init
-- has already bumped @round_num.  So the select screen is driven normally
-- (which needs p1_state = ps_active), and the moment round_num goes nonzero
-- the state is dropped to 0 - that lands inside round_init -> setup_players,
-- before the process is created, and it stays 0 for rounds 2 and 3 as well.
--
-- Env:
--   KAHN_LADDER_CHAR  = ft_* index for P1 (0..11)
--   KAHN_LADDER_NAME  = label for the log
--   KAHN_LADDER_DIFF  = @diff to force (default 9)
--   KAHN_LADDER_LOG   = log path
--   KAHN_LADDER_ROOT  = repo root (for mk2.map)
--   KAHN_LADDER_SEED  = optional @rand seed, to re-roll the RNG stream

local frame = 0
local ROOT = os.getenv("KAHN_LADDER_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("KAHN_LADDER_LOG") or (ROOT .. "/tools/kahn_ladder_test.log")
local OPP_CHAR = tonumber(os.getenv("KAHN_LADDER_CHAR") or "1") or 1
local OPP_NAME = os.getenv("KAHN_LADDER_NAME") or ("char" .. tostring(OPP_CHAR))
local FORCE_DIFF = tonumber(os.getenv("KAHN_LADDER_DIFF") or "9") or 9
local SEED = tonumber(os.getenv("KAHN_LADDER_SEED") or "") or nil
local P1_HUMAN = os.getenv("KAHN_LADDER_P1_HUMAN") == "1"
-- Keeps P1's bar topped up so the round runs to the clock instead of ending
-- in a few seconds.  Used to tell "wedges because both sides are drones"
-- apart from "wedges after N seconds of Kahn throwing objects around".
local P1_TANK = os.getenv("KAHN_LADDER_P1_TANK") == "1"

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- mk2.map holds TMS34010 BIT addresses and this driver's Lua memory space
-- takes them as-is (same convention every other drone harness here uses).
local MAP_PATH = ROOT .. "/src/mk2.map"
local symbols = {}
do
    local fh = io.open(MAP_PATH, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        print("[ladder] FATAL could not read " .. MAP_PATH)
    end
end

local missing = {}
local function sym(name)
    local v = symbols[name]
    if not v then missing[#missing + 1] = name end
    return v or 0
end

local A = {
    gstate    = sym("gstate"),
    diff      = sym("diff"),
    rand      = sym("rand"),
    curback   = sym("curback"),
    map_position = sym("map_position"),
    battle_num   = sym("battle_num"),
    round_num = sym("round_num"),
    winner_status = sym("winner_status"),
    p1_state  = sym("p1_state"),
    p2_state  = sym("p2_state"),
    p1_char   = sym("p1_char"),
    p2_char   = sym("p2_char"),
    p1_bar    = sym("p1_bar"),
    p2_bar    = sym("p2_bar"),
    p1_matchw = sym("p1_matchw"),
    p2_matchw = sym("p2_matchw"),
    p1_obj    = sym("p1_obj"),
    p2_obj    = sym("p2_obj"),
    -- these two were MISSING from this table while the stall dump read them,
    -- so r32(nil) came back 0x3f3f3f3f and looked exactly like process-pool
    -- corruption. sym() is never called for a key that is not here, so the
    -- missing-symbol check could not catch it either.
    p1_proc   = sym("p1_proc"),
    p2_proc   = sym("p2_proc"),
    clk_tens  = sym("clk_tens"),
    clk_ones  = sym("clk_ones"),
    debug4    = sym("debug4"),
    tick      = sym("tick"),
}

local O = { oxval = 0x080, oxpos = 0x090 }
local P = { wake = 0x0e0, action = 0x1f0 }
local stall, last_sig = 0, ""

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KAHN = 13
local KAHN_ARENA = 8
local PS_ACTIVE, PS_INACTIVE = 1, 0

local CHAR_NAMES = {
    [0] = "kunglao", [1] = "liukang", [2] = "cage", [3] = "baraka",
    [4] = "kitana", [5] = "mileena", [6] = "shang", [7] = "raiden",
    [8] = "subzero", [9] = "reptile", [10] = "scorpion", [11] = "jax",
}

local cpu, space, fields = nil, nil, {}
local charsel_frame, fighting_frame, p1_confirm_start = 0, 0, 0
local last_gstate, last_round, last_p1w, last_p2w = -1, -1, 0, 0
local verdict_done = false
local round_start_frame = 0
local round_log = {}
local drone_forced = false
local opp_damage, last_kahn_hp = 0, 161

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function r32(a) return space:read_u32(a) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

--
-- WEDGE PROBE.  kunglao HANGs against Kahn on ~3 of 4 attempts, and a live
-- spar caught the shape: P1's p_action sticks at act_flykick (0200h) while
-- Kahn keeps animating normally, so it is P1's process that stops advancing,
-- not the machine.
--
-- do_flip_kick sets act_flykick then jsrp air_strike, and BOTH of that
-- routine's exits set act_fk_sd - so an action still reading act_flykick
-- means the loop inside air_strike never left.  It has exactly three ways
-- out, and this dumps the state each one tests so the stuck one names
-- itself:
--
--   as2: strike_check hits                    -> as6
--   as2: p_store1 (strike frames) hits 0      -> as7
--   as3: oyvel >= 0 AND oypos >= p_ganiy      -> lands, as8
--
-- If oyvel is negative forever he is rising forever (gravity gone); if it
-- is 0 with oypos above p_ganiy he is parked in mid-air. Either way the
-- numbers say which.
--
local OB = { ograv = 0x020, oxvel = 0x040, oyvel = 0x060, oxpos = 0x090, oypos = 0x0b0 }
local PR = { action = 0x1f0, ganiy = 0x200, store1 = 0x230 }
local function s32(v) if v >= 0x80000000 then v = v - 0x100000000 end return v end
local wedge_act, wedge_since, wedge_shots = -1, 0, 0
local function wedge_probe()
    local p1p, p1o = r32(A.p1_proc), r32(A.p1_obj)
    if p1p == 0 or p1o == 0 then return end
    local act = r16(p1p + PR.action)
    if act ~= wedge_act then wedge_act, wedge_since, wedge_shots = act, frame, 0; return end
    if frame - wedge_since < 120 then return end          -- 2s of no change
    if wedge_shots >= 4 then return end
    wedge_shots = wedge_shots + 1
    local oyv  = s32(r32(p1o + OB.oyvel))
    local grav = s32(r32(p1o + OB.ograv))
    local ypos = r16(p1o + OB.oypos)
    local gan  = r16(p1p + PR.ganiy)
    print(string.format(
        "[ladder] WEDGE p1_action=%04x stuck %d frames | oyvel=%d ograv=%d oypos=%d ganiy=%d strike_frames_left=%d | kahn_action=%04x",
        act, frame - wedge_since, oyv, grav, ypos, gan,
        r32(p1p + PR.store1) & 0xffff, r16(r32(A.p2_proc) + PR.action)))
    if oyv < 0 and grav == 0 then
        print("[ladder] WEDGE cause: rising with NO gravity - as3 'jrn as2' loops forever")
    elseif oyv == 0 and ypos < gan then
        print("[ladder] WEDGE cause: parked in mid-air (no vel, above ground line) - never lands")
    elseif ypos < gan then
        print("[ladder] WEDGE cause: still above his ground line and not descending")
    end
end

local function gap()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return -1 end
    local d = r16(p1o + O.oxpos) - r16(p2o + O.oxpos)
    if d < 0 then d = -d end
    return d
end

local function state_line()
    return string.format("p1hp=%d p2hp=%d p1w=%d p2w=%d round=%d clk=%d%d gap=%d",
        r16(A.p1_bar), r16(A.p2_bar), r16(A.p1_matchw), r16(A.p2_matchw),
        r16(A.round_num), r16(A.clk_tens), r16(A.clk_ones), gap())
end

local function finish(verdict, detail)
    if verdict_done then return end
    verdict_done = true
    print(string.format("[ladder] ROUNDS %s", table.concat(round_log, " ")))
    print(string.format("[ladder] RESULT opponent=%s char=%d verdict=%s p1w=%d p2w=%d oppdmg=%d %s",
        OPP_NAME, OPP_CHAR, verdict, r16(A.p1_matchw), r16(A.p2_matchw), opp_damage, detail or ""))
    print("[ladder] finished")
    manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["1 Player Start"] = true, ["UI Select"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        print(string.format("[ladder] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

-- Boot script: coin, then 1P start, then hammer UI Select through the
-- character screen.  The characters themselves are written directly, so the
-- only job of the button presses is to move the screen along.
local function pressed(name)
    if charsel_frame > 0 and (name == "UI Select" or name == "Coin 1" or name == "1 Player Start") then
        if p1_confirm_start == 0 then return false end
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    return false
end

local function force_matchup()
    w16(A.p1_state, PS_ACTIVE)      -- select needs a human in slot 1
    w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, OPP_CHAR)
    w16(A.p2_char, FT_KAHN)
    w16(A.curback, KAHN_ARENA)
    w16(A.map_position, 14)
    w16(A.battle_num, 15)
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[ladder] opponent=%s char=%d (%s) diff=%d",
            OPP_NAME, OPP_CHAR, CHAR_NAMES[OPP_CHAR] or "?", FORCE_DIFF))
        print("[ladder] log_path=" .. LOG_PATH)
        if #missing > 0 then
            print("[ladder] FATAL missing map symbols: " .. table.concat(missing, ","))
            manager.machine:exit()
            return
        end
    end

    if not space or verdict_done then return end

    wedge_probe()

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[ladder] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            round_start_frame = frame
            print(string.format("[ladder] fight_start %s p1obj=%08x p2obj=%08x p1proc=%08x p2proc=%08x",
                state_line(), r32(A.p1_obj), r32(A.p2_obj), r32(A.p1_proc), r32(A.p2_proc)))
        end
        last_gstate = gs
    end

    -- Hold the difficulty at the top for BOTH fighters, every frame: the
    -- ladder position would otherwise walk it, and a test that drifts off
    -- max difficulty half way through is not testing max difficulty.
    w16(A.diff, FORCE_DIFF)

    if charsel_frame > 0 and fighting_frame == 0 then
        force_matchup()
        if p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[ladder] confirming select frame=%d", frame))
        end
    end

    -- Making P1 a drone WITHOUT destabilising the rest of the game.
    --
    -- setup_players (MKGUYS.ASM) is the only place that cares: it picks
    -- drone_1_proc over joy_1_proc on p1_state != ps_active, and it runs
    -- between round_init (which has already bumped round_num) and
    -- set_game_state(gs_round_intro).  So the state is dropped to 0 only
    -- inside that window and put straight back to ps_active once the fight
    -- is live.
    --
    -- Holding it at 0 for the whole fight - which is what this did first -
    -- wedges or resets the board: plenty of round-end and match-end code
    -- (check_enter_initials, who_is_alone, the buy-in path) asks "is anybody
    -- playing", and answering no for both slots walks it into states it was
    -- never built to be in.  That showed up as gstate turning to garbage and
    -- every RAM read coming back 0xffff, on the BASELINE build as well as a
    -- patched one, which is how it was identified as a rig fault.
    local rn = r16(A.round_num)
    local in_fight = (gs == GS_FIGHTING)
    if P1_HUMAN then
        -- diagnostic mode: leave P1 as an input-less human process, to tell a
        -- fault in the drone-in-slot-1 setup apart from a fault in the rest
        -- of the rig.  Proves nothing about difficulty - P1 does not fight.
    elseif rn >= 1 and not in_fight then
        w16(A.p1_state, PS_INACTIVE)      -- setup_players window: be a drone
        w16(A.p2_state, PS_INACTIVE)
    elseif in_fight and not drone_forced then
        drone_forced = true
        w16(A.p1_state, PS_ACTIVE)        -- process already made - look human
        if SEED then w32(A.rand, SEED) end
        print(string.format("[ladder] p1_drone_armed round=%d frame=%d seed=%s",
            rn, frame, tostring(SEED)))
    end

    if rn ~= last_round then
        if rn > 0 and rn <= 3 then
            print(string.format("[ladder] round %d start frame=%d %s", rn, frame, state_line()))
            round_start_frame = frame
            drone_forced = false          -- re-arm for the next setup_players
        end
        last_round = rn
    end

    -- Sanity gate.  A wedged or reset board reads back nonsense, and nonsense
    -- must never be allowed to look like a verdict - the first version of
    -- this script reported "FAIL_DROPPED_ROUND, Kahn won 2-64764".
    if fighting_frame > 0 then
        local rnv, p1wv, p2wv = r16(A.round_num), r16(A.p1_matchw), r16(A.p2_matchw)
        if rnv > 3 or p1wv > 3 or p2wv > 3 or r16(A.p1_bar) > 161 or r16(A.p2_bar) > 161 then
            finish("CRASH", string.format("corrupt state frame=%d round=%d p1w=%d p2w=%d gs=%d",
                frame, rnv, p1wv, p2wv, gs))
            return
        end
    end

    -- Round results come off the match win counters, which round_init resets
    -- per MATCH and end_of_match_chores clears - so a change here is exactly
    -- "somebody just took a round".
    local p1w, p2w = r16(A.p1_matchw), r16(A.p2_matchw)
    if p1w ~= last_p1w or p2w ~= last_p2w then
        if p1w > last_p1w then
            round_log[#round_log + 1] = string.format("R%d:OPP", #round_log + 1)
            print(string.format("[ladder] ROUND LOST by Kahn frame=%d ticks=%d %s",
                frame, frame - round_start_frame, state_line()))
        elseif p2w > last_p2w then
            round_log[#round_log + 1] = string.format("R%d:KAHN", #round_log + 1)
            print(string.format("[ladder] ROUND WON by Kahn frame=%d ticks=%d %s",
                frame, frame - round_start_frame, state_line()))
        end
        last_p1w, last_p2w = p1w, p2w

        if p2w >= 2 then
            if p1w == 0 then
                finish("PASS", "Kahn took both rounds")
            else
                finish("FAIL_DROPPED_ROUND", string.format("Kahn won 2-%d", p1w))
            end
            return
        end
        if p1w >= 2 then
            finish("FAIL_LOST_MATCH", string.format("opponent won %d-%d", p1w, p2w))
            return
        end
    end

    if fighting_frame > 0 then
        if P1_TANK and gs == GS_FIGHTING then w16(A.p1_bar, 161) end

        -- Proof the opponent drone is actually alive and fighting.  A rig
        -- where P1 silently ended up an input-less human process would post
        -- a clean 12/12 and mean nothing at all, so the damage it deals to
        -- Kahn is tracked and printed with the verdict.
        local kahn_hp = r16(A.p2_bar)
        if kahn_hp < last_kahn_hp then opp_damage = opp_damage + (last_kahn_hp - kahn_hp) end
        last_kahn_hp = kahn_hp

        if (frame - fighting_frame) % 600 == 0 then
            print(string.format("[ladder] tick rel=%d %s oppdmg=%d",
                frame - fighting_frame, state_line(), opp_damage))
        end

        -- Stall detector.  A drone-vs-drone fight can wedge on a path that
        -- waits for a human button tap that is never coming; when it does,
        -- print who was doing what so the wait can be found in the source
        -- instead of guessed at.  @tick still advancing means the scheduler
        -- is alive and one process is stuck; @tick frozen means the whole
        -- main loop is gone (an ermac).
        local sig = string.format("%d:%d:%d:%d", r16(A.p1_bar), r16(A.p2_bar),
            r16(A.clk_tens), r16(A.clk_ones))
        if sig == last_sig then
            stall = stall + 1
            if stall == 900 then
                local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
                print(string.format("[ladder] STALL frame=%d tick=%d gs=%d %s",
                    frame, r16(A.tick), gs, state_line()))
                print(string.format("[ladder] STALL p1proc=%08x act=%04x wake=%04x  p2proc=%08x act=%04x wake=%04x",
                    p1p, p1p ~= 0 and r16(p1p + P.action) or 0, p1p ~= 0 and r16(p1p + P.wake) or 0,
                    p2p, p2p ~= 0 and r16(p2p + P.action) or 0, p2p ~= 0 and r16(p2p + P.wake) or 0))
                print(string.format("[ladder] STALL winner_status=%d round=%d debug4=%04x",
                    r16(A.winner_status), r16(A.round_num), r16(A.debug4)))
            end
            if stall > 2400 then
                finish("HANG", string.format("no state change for %d frames", stall))
                return
            end
        else
            stall = 0
            last_sig = sig
        end
        -- Kahn stopped being Kahn: the match ended and the game moved on
        -- without either counter reaching 2.  Report it rather than sit here.
        if r16(A.p2_char) ~= FT_KAHN and frame - fighting_frame > 120 then
            finish("NO_VERDICT", string.format("left the Kahn fight at frame=%d", frame))
            return
        end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end
end)

emu.register_stop(function()
    if not verdict_done then
        print(string.format("[ladder] RESULT opponent=%s char=%d verdict=NO_VERDICT (backstop) frame=%d",
            OPP_NAME, OPP_CHAR, frame))
    end
    if logfh then logfh:close() end
end)
