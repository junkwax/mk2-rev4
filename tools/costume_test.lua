-- Runtime proof for the two costume rules, read off the COLOUR RAM.
--
-- CT_MODE=nodup  TWO PLAYERS NEVER WEAR THE SAME COSTUME (costnodup,
--   costume_pal_a0, MKGUYS.ASM).  A 2-player MIRROR match: player 1 claims
--   START+LP with the real gesture, which is the very lane the mirror rule
--   hands player 2 automatically.  Since 2026-10-05 a taken or implicit
--   costume puts player 2 on his DEFAULT, or on the DEFAULT ALT (Start+HP, lane 1) when
--   player 1 wears the default.  CT_P1GEST / CT_P2GEST pick the gestures.
--
--   The assertion that makes this mean something is not "they differ" - it is
--   that player 2 lands on the SPECIFIC next lane in costume_offer order.
--   "They differ" would also pass if P2's palette were garbage.
--
-- CT_MODE=drone  THE CPU WEARS A RANDOM COSTUME IN 1P (dronecos,
--   drone_costume_pick).  One player, CPU on CT_OCHAR, and three checks:
--     1. his palette is one of HIS OWN lanes, not an arbitrary map;
--     2. it is not player 1's costume (the no-duplicate rule still applies);
--     3. it is THE SAME in round 2 as in round 1 - the pick is per OPPONENT,
--        not per round, and setup_players runs per round, so this is the
--        regression the design is most exposed to.
--   Variety across rolls is the WRAPPER's job: one run is one sample.
--
--   For a fighter with ONE distinct palette (Smoke, Khameleon, Kintaro, Kahn
--   today) the roll is inert BY DESIGN and the expectation flips to "he wears
--   the default" - a pass there proves the pick cannot wander, which for
--   Khameleon is what protects kham_disguise_pal_proc's cycle.
--
-- A sub-check that never got to run reports NO-VERDICT, never PASS.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local logfh = assert(io.open(os.getenv("CT_LOG") or (ROOT .. "/tools/costume_test.log"), "w"))
local function log(fmt, ...)
    local s = "[costume] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local MODE   = os.getenv("CT_MODE") or "nodup"
local OCHAR  = tonumber(os.getenv("CT_OCHAR") or "1")
local P1CHAR = tonumber(os.getenv("CT_P1CHAR") or "11")
local SETTLE = tonumber(os.getenv("CT_SETTLE") or "120")
-- CT_JITTER shifts the whole input schedule by a few frames.  A scripted rig
-- boots deterministically, so @rand - which seeds the drone's private xorshift -
-- holds the SAME value at setup_players on every run, and every roll comes out
-- identical.  That is a property of the harness, not of the pick.  Jittering the
-- schedule is what a real player does by not pressing start on the same frame.
local JITTER = tonumber(os.getenv("CT_JITTER") or "0")
-- nodup gestures: does each player hold his Start across Low Punch (START+LP)?
-- The expected answer (2026-10-05 rule, costume_lane_shift): a taken or
-- implicit costume puts player 2 on his DEFAULT, or on the DEFAULT ALT
-- (character_palettes_4 = Start+HP, lane 1) when player 1 wears the default.
local P1GEST = (os.getenv("CT_P1GEST") or "1") == "1"
local P2GEST = (os.getenv("CT_P2GEST") or "0") == "1"
-- CT_P1BTN: the button P1 holds Start across (LP = lane 2, HP = lane 1, ALT1)
local P1BTN  = os.getenv("CT_P1BTN") or "LP"
-- CT_P2FIRST=1: P2 confirms BEFORE P1's gesture, so his select-screen preview
-- can be watched changing when P1 takes a costume (sampled, see psel_samples)
local P2FIRST = (os.getenv("CT_P2FIRST") or "0") == "1"
local WANT1 = P1GEST and (P1BTN == "HP" and 1 or 2) or 0
local function resolve2(p1lane)          -- what P2 must end up in
    local req = P2GEST and 2 or ((p1lane == 0) and 1 or 0)
    if req ~= p1lane then return req end
    return (p1lane ~= 0) and 0 or 1      -- taken -> default, else the default alt
end
local WANT2 = resolve2(WANT1)

local EXP = dofile(ROOT .. "/tools/costume_expect.lua")
ME = EXP[OCHAR]
if not ME then log("FAIL reason=no expectation for ochar %d", OCHAR); logfh:close(); return end

local syms = {}
local mf = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
if mf then
    for line in mf:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n] = tonumber(a, 16) end
    end
    mf:close()
end
local missing = {}
local function sym(n, d)
    if not syms[n] then missing[#missing + 1] = n end
    return syms[n] or d
end

local A = {
    gstate        = sym("gstate",        0x0112a7d0),
    p1_char       = sym("p1_char",       0x0112a880),
    p2_char       = sym("p2_char",       0x0112b450),
    p1_obj        = sym("p1_obj",        0x0112a820),
    p2_obj        = sym("p2_obj",        0x0112b3f0),
    p2_bar        = sym("p2_bar",        0x0112aa70),
    round_num     = sym("round_num",     0),
    alt_pal_owner = sym("alt_pal_owner", 0x0112a8a0),
    dcos_for      = sym("dcos_for",      0),
    p1_state      = sym("p1_state",      0),
    p2_state      = sym("p2_state",      0),
    dcos_rand     = sym("dcos_rand",     0),
    palram        = sym("palram",        0),
}

local GS_PSEL, GS_POST, GS_FIGHT = 4, 0x0d, 2
local OPAL, OFLAGS2 = 0x140, 0x160
local COLRAM, PALSIZE = 0x01800000, 0x1000

local frame, space, psel, fight = 0, nil, 0, 0
local fields, finished = {}, false
local r1 = nil                       -- round 1 sample, for the round-2 compare
local verdicts = {}
psel_bad = false

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function cram(map, idx) return r16(COLRAM + map * PALSIZE + idx * 16) end

local function finish(ok, why)
    if finished then return end
    finished = true
    for _, v in ipairs(verdicts) do log("  %s", v) end
    log("%s reason=%s", ok and "PASS" or "FAIL", why)
    logfh:close(); manager.machine:exit()
end

local function cache()
    local wanted = { ["UI Select"] = 1, ["Coin 1"] = 1, ["Coin 2"] = 1,
                     ["2 Players Start"] = 1, ["2 Player Start"] = 1,
                     ["1 Player Start"] = 1, ["1 Players Start"] = 1,
                     ["P1 Low Punch"] = 1, ["P2 Low Punch"] = 1,
                     ["P1 High Punch"] = 1, ["P2 Left"] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
    local have = {}
    for n in pairs(fields) do have[#have + 1] = n end
    table.sort(have)
    log("input fields: %s", table.concat(have, ", "))
end

local function pressed(n)
    if n == "UI Select" then return frame >= 5 and frame < 35 end
    -- CREDIT ONLY PLAYER 1 IN DRONE MODE.  Coining slot 2 as well lets player 2
    -- join, @p2_state becomes ps_active, setup_players gives him joy_2_proc
    -- instead of drone_2_proc - and drone_costume_pick correctly refuses to pick
    -- for a human.  That is what made every drone roll land on the default.
    if n == "Coin 1" then
        return frame >= 700 + JITTER and frame < 980 + JITTER and frame % 80 < 20
    end
    if n == "Coin 2" then
        return MODE == "nodup" and frame >= 700 + JITTER and frame < 980 + JITTER
               and frame % 80 < 20
    end
    if psel == 0 then
        if MODE == "nodup" then
            if n == "2 Players Start" or n == "2 Player Start" then
                return frame >= 1000 and frame < 1080
            end
        else
            if n == "1 Player Start" or n == "1 Players Start" then
                return frame >= 1000 + JITTER and frame < 1080 + JITTER
            end
        end
        return false
    end
    -- P1's COSTUME GESTURE, in nodup mode ONLY.  He holds 1P Start across his
    -- Low Punch to claim START+LP - start down before the button and still down
    -- through it, or the press reads as a plain confirm.
    --
    -- It is deliberately NOT done in drone mode.  Pressing a start button again
    -- during the select screen brought PLAYER 2 into the game (@p2_state went
    -- ps_active), setup_players then handed him joy_2_proc instead of
    -- drone_2_proc, and drone_costume_pick correctly refused to pick a costume
    -- for what the game considered a human.  Every roll landed on the default
    -- and the bug looked like mine.  The CPU test does not need P1 on an
    -- alternate anyway: he sits on his default and the CPU must still differ.
    if MODE == "nodup" then
        -- P2FIRST: P1 holds Start (which joins him) while P2 confirms plain,
        -- and only then presses his button
        if P1GEST and (n == "1 Player Start" or n == "1 Players Start") then
            if P2FIRST then return frame >= psel + 80 and frame < psel + 200 end
            return frame >= psel + 80 and frame < psel + 150
        end
        if n == (P1BTN == "HP" and "P1 High Punch" or "P1 Low Punch") then
            if P2FIRST then return frame >= psel + 140 and frame < psel + 175 end
            return frame >= psel + 100 and frame < psel + 135
        end
        if P2GEST and (n == "2 Players Start" or n == "2 Player Start") then
            return frame >= psel + 150 and frame < psel + 220
        end
    end
    -- drone mode: P1 confirms his pick with a plain button, no start
    if MODE ~= "nodup" and n == "P1 Low Punch" then
        return frame >= psel + 100 and frame < psel + 135
    end
    -- nodup: P2 confirms with NO start, so he takes the mirror automatically -
    -- which is the collision this mode is about.
    -- P2FIRST is run on REPTILE (run_costume_test.ps1): the preview is built
    -- from the square P2's cursor STARTS on, which is Reptile's, so with
    -- p2_char pinned to him the select-screen preview is a real mirror.
    if MODE == "nodup" and n == "P2 Low Punch" then
        if P2FIRST then return frame >= psel + 102 and frame < psel + 120 end
        return frame >= psel + 170 and frame < psel + 205
    end
    return false
end

local function sample(objaddr)
    local obj = r32(objaddr)
    if obj == 0 then return nil end
    local opal = r16(obj + OPAL)
    local map = (opal >> 8) & 0xff
    local w = {}
    for i = 1, 64 do w[i] = cram(map, i - 1) end
    return { obj = obj, map = map, flags = r32(obj + OFLAGS2), words = w }
end

-- index 0 is the transparent entry and is not always transferred
local function same(a, b)
    local n = math.min(#a, #b)
    for i = 2, n do if a[i] ~= b[i] then return false end end
    return true
end

local function which_lane(w)
    for _, L in ipairs(ME.lanes) do
        if same(w, L.words) then return L end
    end
    return nil
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache()
        if #missing > 0 then
            log("WARN symbols not in map: %s", table.concat(missing, ", "))
        end
        log("mode=%s ochar=%d (%s) distinct=%d p1char=%d",
            MODE, OCHAR, ME.who, ME.distinct, MODE == "nodup" and OCHAR or P1CHAR)
        for _, L in ipairs(ME.lanes) do
            log("  lane %d %-12s %s", L.idx, L.press, L.sym)
        end
        if MODE == "nodup" and ME.distinct < 4 then
            finish(false, string.format(
                "ochar %d has only %d distinct palettes - this mode needs the "
                .. "START+LP and START+HK lanes to differ or it cannot discriminate",
                OCHAR, ME.distinct))
            return
        end
    end
    if space and not finished then
        local gs = r16(A.gstate)
        -- P2FIRST: FOLLOW P2's PREVIEW.  It is built from the square his cursor
        -- starts on, and that is not fixed (Reptile one run, Jax the next), so
        -- the mirror is whatever HE is: pin both chars to his preview's ochar.
        if MODE == "nodup" and P2FIRST and gs == GS_PSEL and psel > 0
           and frame - psel < 125 then
            local o = r32(A.p2_obj)
            local och = o ~= 0 and r16(o + 0x1f0) or nil
            if och and och ~= OCHAR and EXP[och] and EXP[och].distinct >= 4 then
                OCHAR, ME = och, EXP[och]
                log("following P2's preview: ochar %d (%s)", och, ME.who)
            end
        end
        -- PIN THE PAIR UNTIL THE FIGHT IS RUNNING, not just on the select
        -- screen.  setup_players - which is where drone_costume_pick reads
        -- @p2_char - runs during the ROUND INTRO (gstate 7), after the select
        -- states are gone.  Pinning only through GS_PSEL/GS_POST let the game
        -- pick its own ladder opponent in between: the rig asked for Noob,
        -- @dcos_for came back 4 (ochar 3, Baraka), and the costume was compared
        -- against the wrong fighter's lanes.
        if psel > 0 and fight == 0 and gs ~= GS_FIGHT then
            w16(A.p1_char, MODE == "nodup" and OCHAR or P1CHAR)
            w16(A.p2_char, OCHAR)
            if MODE ~= "nodup" then w16(A.p2_state, 0) end
        end
        if gs == GS_PSEL or gs == GS_POST then
            if gs == GS_PSEL and psel == 0 then
                psel = frame; log("select screen at frame %d", frame)
            end
            -- P2's PREVIEW, before P1's gesture and while he holds it: it must
            -- follow P1 (the default alt while P1 is on the default, then
            -- whatever resolve2 says once P1 has claimed)
            if MODE == "nodup" and P2FIRST and psel > 0 then
                local at = frame - psel
                if at == 130 or at == 150 then
                    local p2 = sample(A.p2_obj)
                    local want = resolve2(at == 130 and 0 or WANT1)
                    -- by IDENTITY (palram's first long = the palette's ROM
                    -- address): the select screen fades the previews, so the
                    -- colour RAM there matches no lane's words
                    local got
                    if p2 then
                        log("preview probe +%d: owner=%04X opal=%04X palram id=%08X oflags2=%08X", at, r16(A.alt_pal_owner),
                            r16(p2.obj + OPAL), r32(A.palram + p2.map * 0x40), p2.flags)
                        local id = r32(A.palram + p2.map * 0x40)
                        for _, L in ipairs(ME.lanes) do
                            if syms[L.sym] == id then got = got or L end
                        end
                    end
                    local okp = got and got.idx == want
                    verdicts[#verdicts + 1] = string.format(
                        "%s select preview +%d: P2 on %s, want lane %d (obj=%08X map=%s gs=%d)",
                        okp and "OK  " or "BAD ", at,
                        got and (got.sym .. " lane " .. got.idx) or "unknown", want,
                        r32(A.p2_obj), p2 and tostring(p2.map) or "-", gs)
                    if not okp then psel_bad = true end
                end
            end
            w16(A.p1_char, MODE == "nodup" and OCHAR or P1CHAR)
            w16(A.p2_char, OCHAR)
            -- FORCING p2_char MAKES THE GAME TREAT PLAYER 2 AS PRESENT, so in a
            -- 1P test his state has to be pinned to 0 as well or he comes up
            -- ps_active - a human with nobody on the sticks.  setup_players then
            -- hands him joy_2_proc instead of drone_2_proc and
            -- drone_costume_pick correctly refuses to dress a human, so every
            -- roll lands on the default and the ASM looks broken when it is not.
            -- MAIN.ASM says it outright: "p?_state is ps_active for humans and 0
            -- for drones during the match".  Same fix as
            -- tools/shang_soul_escape_test.lua:240.
            if MODE ~= "nodup" then w16(A.p2_state, 0) end
        elseif gs == GS_FIGHT then
            if fight == 0 then
                fight = frame
                log("fight at frame %d: seed=%04X alt_pal_owner=%04X dcos_for=%d "
                    .. "p1_state=%d p2_state=%d (ps_active=1: p1 must BE 1 and "
                    .. "p2 must NOT be, or drone_costume_pick bails)",
                    frame, r16(A.dcos_rand), r16(A.alt_pal_owner),
                    r16(A.dcos_for), r16(A.p1_state), r16(A.p2_state))
            end
            local age = frame - fight
            if age == SETTLE then
                for _, scr in pairs(manager.machine.screens) do
                    pcall(function() scr:snapshot() end)
                end
                local p1 = sample(A.p1_obj)
                local p2 = sample(A.p2_obj)
                if not p1 or not p2 then finish(false, "a player object was null"); return end
                log("P1 map=%d oflags2=%08X   P2 map=%d oflags2=%08X",
                    p1.map, p1.flags, p2.map, p2.flags)

                if MODE == "nodup" then
                    local want1 = which_lane(p1.words)
                    local want2 = which_lane(p2.words)
                    log("P1 is wearing %s; P2 is wearing %s",
                        want1 and (want1.sym .. " (lane " .. want1.idx .. ")") or "NOTHING KNOWN",
                        want2 and (want2.sym .. " (lane " .. want2.idx .. ")") or "NOTHING KNOWN")
                    local function lane_at(i)
                        for _, L in ipairs(ME.lanes) do if L.idx == i then return L end end
                    end
                    local L1, L2 = lane_at(WANT1), lane_at(WANT2)
                    if not L1 or not L2 then
                        finish(false, "no expectation for lane " .. WANT1 .. "/" .. WANT2); return
                    end
                    if not same(p1.words, L1.words) then
                        finish(false, string.format(
                            "player 1 is not on lane %d (%s) - the gesture missed, so "
                            .. "nothing about the rule was tested. He is on %s.",
                            WANT1, L1.sym, want1 and want1.sym or "an unknown palette"))
                        return
                    end
                    if same(p1.words, p2.words) then
                        finish(false, "BOTH FIGHTERS ARE WEARING " .. L1.sym
                               .. " - the no-duplicate rule did not fire")
                        return
                    end
                    verdicts[#verdicts + 1] = "player 2 is NOT in player 1's costume"
                    if not same(p2.words, L2.words) then
                        finish(false, string.format(
                            "player 2 is on %s, expected lane %d (%s) - P1 lane %d, "
                            .. "P2 %s", want2 and (want2.sym .. " lane " .. want2.idx)
                            or "an unknown palette", WANT2, L2.sym, WANT1,
                            P2GEST and "pressed START+LP" or "plain select"))
                        return
                    end
                    if psel_bad then
                        finish(false, "the select-screen preview did not follow P1"); return
                    end
                    finish(true, string.format(
                        "P1 %s (lane %d), P2 %s -> %s (lane %d) on map %d",
                        L1.sym, WANT1, P2GEST and "START+LP" or "plain",
                        L2.sym, WANT2, p2.map))
                    return
                end

                -- drone mode
                local lane = which_lane(p2.words)
                log("the CPU is wearing %s",
                    lane and (lane.sym .. " (lane " .. lane.idx .. " " .. lane.press .. ")")
                    or "a palette that is NOT one of his lanes")
                if not lane then
                    finish(false, "the CPU's palette is not any lane of his - "
                           .. "drone_costume_pick wrote a claim that resolves to nothing")
                    return
                end
                log("CHOSE lane=%d sym=%s", lane.idx, lane.sym)
                if ME.distinct == 1 then
                    if lane.idx ~= 0 then
                        finish(false, string.format(
                            "%s has ONE distinct palette, so the roll must be inert and "
                            .. "land on the default - it landed on lane %d", ME.who, lane.idx))
                        return
                    end
                    verdicts[#verdicts + 1] =
                        "one distinct palette: the roll is inert, as designed"
                end
                if same(p1.words, p2.words) then
                    finish(false, "the CPU is in player 1's costume - "
                           .. "the no-duplicate rule did not fire")
                    return
                end
                verdicts[#verdicts + 1] = "the CPU is not in player 1's costume"
                r1 = { lane = lane.idx, sym = lane.sym, words = p2.words }
                log("round 1 sampled; draining the CPU to reach round 2")
            end
            -- force round 1 to end so the per-round question can be answered
            if r1 and age > SETTLE then w16(A.p2_bar, 1) end
            if r1 and age > SETTLE + 60 then
                local p2 = sample(A.p2_obj)
                local rn = r16(A.round_num)
                if p2 and rn and rn >= 2 then
                    local lane = which_lane(p2.words)
                    log("round %d: the CPU is wearing %s", rn,
                        lane and lane.sym or "something unknown")
                    if not same(p2.words, r1.words) then
                        finish(false, string.format(
                            "the CPU CHANGED costume between rounds: %s in round 1, %s in "
                            .. "round %d. The pick is per OPPONENT; setup_players runs per "
                            .. "ROUND, so @dcos_for is not holding.",
                            r1.sym, lane and lane.sym or "something unknown", rn))
                        return
                    end
                    finish(true, string.format(
                        "the CPU wears %s (lane %d), not player 1's costume, and the same "
                        .. "in round %d", r1.sym, r1.lane, rn))
                    return
                end
            end
            if age > SETTLE + 1800 then
                if r1 then
                    log("NO-VERDICT on the round-2 check: never reached round 2")
                    finish(true, string.format(
                        "the CPU wears %s (lane %d) and not player 1's costume; the "
                        .. "between-rounds check is NO-VERDICT, not a pass", r1.sym, r1.lane))
                else
                    finish(false, "the fight never settled")
                end
                return
            end
        end
        if frame % 120 == 0 then
            log("frame=%d gstate=%d p1s=%d p2s=%d p1c=%d p2c=%d owner=%04X dcos_for=%d",
                frame, gs, r16(A.p1_state), r16(A.p2_state),
                r16(A.p1_char), r16(A.p2_char),
                r16(A.alt_pal_owner), r16(A.dcos_for))
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame > 9000 then finish(false, "timeout - never reached a fight") end
end)
