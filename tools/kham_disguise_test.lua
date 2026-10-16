-- kham_disguise_test.lua
--
-- Runtime proof of KHAMELEON's DISGUISE CYCLE: she is picked in her own
-- lavender KHMAIN_P, and in a fight she changes into JADE's green, KITANA's
-- blue and MILEENA's magenta in turn, one every six to seven seconds.
--
-- She is a hidden fighter, so she cannot be forced into a fight - writing
-- p?_char never confirms and test_mode parks at gstate 8, the wall every
-- hidden-fighter rig hits.  So this drives the REAL unlock and only then
-- starts watching colour RAM.
--
-- SHE IS SUMMONED ON THE BATTLE PLAN SCREEN: one player, five taps of START
-- on the mountain between matches, and the NEXT OPPONENT is Khameleon
-- (kham_ladder_enable, MAINEQU.ASM).  She is CPU-only, so she is the DRONE and
-- this rig watches player 2 by default, not player 1.
--
-- It moved here on 2026-09-27.  Before that she was Mileena + Start x5 on the
-- SELECT screen, and before that Kitana + Block x5; both are compiled out.
-- Driving a stale gesture does not error - it walks into an ordinary fight
-- against the map's own opponent and the rig then fails on a palette that was
-- never wrong - so read kham_ladder_tap (MKSEL.ASM) rather than any prose.
--
-- NO POKING.  The old rig wrote p?_char to hover a square; this drives the
-- real gesture end to end, because the gesture IS the harness: a hidden
-- fighter cannot be forced into a fight, so if the summons breaks there is no
-- other way to reach her and the rig must be what notices.
--
-- WHY IT CAN TAP BLIND.  kham_ladder_tap is only ever called from
-- escape_button_update, which only runs on the battle plan screen, so a Start
-- tap anywhere else is inert.  The rig still confines its taps to
-- gs_round_intro (7) - the state the play loop is in across the whole ladder -
-- so it is tapping where the player would.
--
-- What it checks, on the colour map her object is actually WEARING:
--   * she is on her ANCHOR, KHMAIN_P, when the fight opens;
--   * the three disguises then arrive in kham_disguise_pals' order,
--     Jade -> Kitana -> Mileena, and WRAP back to Jade;
--   * every interval between changes is inside the authored window;
--   * kham_guise agrees with the colours on screen at every step.
--
-- THAT LAST ONE IS THE DRONE CONTRACT.  She is a CPU-only opponent and her
-- move choices follow the costume (kham_fight_as_guise, MAINEQU.ASM): the
-- palette cycle publishes kham_guise and kham_worn_ochar (MKDRONE.ASM) reads
-- it to pick which female ninja's tables the drone indexes.  If the word and
-- the colour ever disagree she would be fighting as one ninja while painted as
-- another, which is the whole bug this feature exists to avoid - and it would
-- be invisible in a rig that only watched colour RAM.  0 = her own KHMAIN_P,
-- 1 Jade, 2 Kitana, 3 Mileena, so it is the disguise index plus one.
--
-- THE INTERVAL IS THE POINT, not just that something changes.  The old BIV
-- cycle stepped every 4 ticks; a rig that only proves "the colours moved"
-- would pass on either, so a gap outside the window FAILS here.  The first
-- observed change is NOT timed: the process is created during pfsetup and
-- has already been counting before gstate reaches fighting, so only the gaps
-- BETWEEN changes are whole intervals.
--
-- BOTH BARS ARE PINNED (see doc/ and the other move rigs): the cycle process
-- dies with the round, and a fresh one starts the next round back at Jade, so
-- a KO mid-sequence would look like an out-of-order change.  Pinning is what
-- keeps the whole run inside one round.
--
-- Expectations come from tools/kham_disguise_expect.lua, which
-- tools/run_kham_disguise_test.ps1 REGENERATES out of data/MK2PALS.IMG on
-- every run, so this cannot pass against a stale colour.
--
-- PASS = anchor seen, 3 disguises in order, at least one wrap, every gap in
-- window.  KD_NEGATIVE=1 rotates the expected witnesses by one and must FAIL.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
-- She is the DRONE now, so player 2 by default (the human is player 1).
local P = tonumber(os.getenv("KD_PLAYER") or "2")
local LOG = os.getenv("KD_LOG") or (ROOT .. "/tools/kham_disguise_test.log")
-- Dropped the moment the SELECT SCREEN is reached, which is the first thing
-- that cannot happen while MAME is parked on its ROM-warning box.  The runner
-- points mame_dismiss_warning.ps1's -ReadyFile at this, NOT at the log above:
-- the log is opened when this script loads, i.e. before emulation has started,
-- so a poker waiting on the log would stop immediately and never poke at all.
local MARKER = os.getenv("KD_MARKER") or (ROOT .. "/tools/kham_disguise_started.tmp")
local NEG = (os.getenv("KD_NEGATIVE") or "0") ~= "0"
-- KD_NOTAPS=1: play the same 1P game and DO NOT tap. She must NOT appear.
-- This is the control that discriminates THIS change: the palette-rotation
-- negative proves the rig reads which disguise, but only this one proves the
-- five taps are what summoned her rather than the tower happening to hold
-- her, or a flag left latched from some earlier screen.
local NOTAPS = (os.getenv("KD_NOTAPS") or "0") ~= "0"

-- The authored window, MKGUYS.ASM: kham_dis_min 328 .. +kham_dis_span-1 383
-- ticks = 6.00 .. 7.00s at 54.7068 Hz.  SLACK covers the palette transfer
-- being queued for the next vblank rather than applied on the spot.
local GAP_LO = tonumber(os.getenv("KD_GAP_LO") or "328")
local GAP_HI = tonumber(os.getenv("KD_GAP_HI") or "383")
local SLACK = tonumber(os.getenv("KD_SLACK") or "3")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[kham-dis] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local EXPECT = assert(loadfile(ROOT .. "/tools/kham_disguise_expect.lua"))()
local CYCLE = {}
for i, e in ipairs(EXPECT.CYCLE) do CYCLE[i] = { name = e.name, who = e.who, witness = e.witness } end
if NEG then
    -- Rotate the witnesses by one: Jade's step now expects Kitana's colour.
    -- A rig that merely notices "the map changed" passes this; one that reads
    -- WHICH disguise arrived cannot.
    local first = CYCLE[1].witness
    for i = 1, #CYCLE - 1 do CYCLE[i].witness = CYCLE[i + 1].witness end
    CYCLE[#CYCLE].witness = first
    log("NEGATIVE: expected witnesses rotated by one - this run must FAIL")
end

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
    gstate  = sym("gstate"),
    my_char = sym("p" .. P .. "_char"),
    my_obj  = sym("p" .. P .. "_obj"),
    p1_bar  = sym("p1_bar"),
    p2_bar  = sym("p2_bar"),
    c       = sym("c_kham_ladder"),       -- battle-plan Start taps counted
    f       = sym("f_kham_next"),         -- latched by the 5th, spent pre-match
    human   = sym("p" .. (3 - P) .. "_char"),   -- the side a person is playing
    guise   = sym("kham_guise"),          -- p1:p2 pair, 16 bits per player
}
local missing = false
for k, v in pairs(A) do if not v then log("FATAL: symbol for '%s' not in mk2.map", k); missing = true end end

local FT_KHAM = 18                     -- ft_kham, the drone we must end up facing
local NTAPS = 5                        -- kham_ladder_taps
local GS_PSEL, GS_FIGHT, GS_ROUND_INTRO = 4, 2, 7
local OPAL = 0x140
local COLRAM, PALSIZE = 0x01800000, 0x1000
local FULL_BAR = 0xA1                  -- full_strength

local WITNESS = EXPECT.WITNESS_IDX
local SENTINEL_IDX, SENTINEL = EXPECT.SENTINEL_IDX, EXPECT.SENTINEL
local NAME_OF = { [EXPECT.ANCHOR.witness] = EXPECT.ANCHOR.who }
for _, e in ipairs(EXPECT.CYCLE) do NAME_OF[e.witness] = e.who end

-- The gesture is the HUMAN's, and the human is the side we are NOT watching.
local HUMAN = 3 - P
local START = "1 Player Start"          -- 1P game: always the 1P Start button
local LP  = "P" .. HUMAN .. " Low Punch"

local frame, space, fields = 0, nil, {}
local psel, p0, phase, done = 0, 0, "boot", false
local fight, map_seen = 0, nil
local anchor_seen, step, wraps = false, 0, 0
local last_word, last_change = nil, nil
local seq, gaps, bad = {}, {}, nil
local held = {}
local function hold(n, on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function cram(map, idx) return r16(COLRAM + map * PALSIZE + idx * 16) end
-- kham_guise is a p1:p2 pair, 16 bits per player, the way get_tsl indexes.
local function guise() return r16(A.guise + (P - 1) * 16) end

local function finish(ok, why)
    if done then return end
    done = true
    log("anchor=%s steps=%d wraps=%d map=%s", tostring(anchor_seen), step, wraps, tostring(map_seen))
    log("SEQUENCE %s", table.concat(seq, " -> "))
    if #gaps > 0 then
        local parts = {}
        for _, g in ipairs(gaps) do
            parts[#parts + 1] = string.format("%d(%.2fs)", g, g / 54.7068)
        end
        log("GAPS %s  window %d..%d ticks (+/-%d)", table.concat(parts, " "), GAP_LO, GAP_HI, SLACK)
    end
    if NOTAPS then
        log("%s reason=%s", ok and "PASS(control: no taps, no Khameleon)"
                               or "FAIL(control)", why)
    elseif NEG then
        log("%s reason=%s", ok and "FAIL(negative passed - the rig is not reading WHICH disguise)"
                               or "PASS(negative rejected as it must)", why)
    else
        log("%s reason=%s", ok and "PASS" or "FAIL", why)
    end
    log("finished")
    logfh:flush()
    manager.machine:exit()
end

local function cache()
    local want = { ["Coin 1"] = 1, ["1 Player Start"] = 1, ["UI Select"] = 1, [LP] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, fld in pairs(p.fields) do if want[fld.name] then fields[fld.name] = fld end end
    end
    for n in pairs(want) do log("input %-18s %s", n, fields[n] and "ok" or "MISSING") end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache()
        if missing then finish(false, "symbols missing from mk2.map"); return end
        log("driving the real summons: 1P, %s x%d on the BATTLE PLAN -> the drone\n            is Khameleon (%d); watching P%d, human is P%d", START, NTAPS, FT_KHAM, P, HUMAN)
        log("expecting anchor %s then %s", EXPECT.ANCHOR.who,
            table.concat({ CYCLE[1].who, CYCLE[2].who, CYCLE[3].who }, " -> "))
    end
    if not space or done then return end

    local gs = r16(A.gstate)

    -- ---- phase 1: coin up, pick anyone, then tap Start on the mountain ---
    if gs == GS_PSEL and psel == 0 then
        psel = frame; log("select reached frame=%d", frame)
        for _, n in ipairs({ "Coin 1", "1 Player Start", "UI Select" }) do hold(n, false) end
    end
    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("1 Player Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)
    elseif gs == GS_PSEL then
        -- Any character will do: the summons replaces the DRONE, not the human.
        hold(START, false)
        hold(LP, ((frame - psel) % 20) < 8)
        if phase == "boot" then phase = "select"; log("confirming a character with %s", LP) end
    elseif gs == GS_ROUND_INTRO then
        -- The battle plan. Five clean taps: 6 frames down, 6 up, so each press
        -- is seen going down AND coming back up - kham_ladder_tap counts the
        -- release edge, so a held button is one tap, not five.
        hold(LP, false)
        if p0 == 0 then
            p0 = frame
            phase = NOTAPS and "notaps" or "tapping"
            log("battle plan reached frame=%d - %s", frame,
                NOTAPS and "NOT tapping (control)" or ("tapping " .. START))
        end
        local p = frame - p0
        if NOTAPS then
            hold(START, false)
        elseif p // 12 < NTAPS then
            hold(START, (p % 12) < 6)
        else
            hold(START, false)
            if phase ~= "tapped" then
                phase = "tapped"
                log("taps done c_kham_ladder=%d f_kham_next=%d", r16(A.c), r16(A.f))
                if r16(A.f) == 0 and not NOTAPS then
                    finish(false, string.format(
                        "five taps on the battle plan left f_kham_next clear " ..
                        "(c_kham_ladder=%d) - the summons never latched", r16(A.c)))
                    return
                end
            end
        end
    else
        hold(START, false)
        hold(LP, false)
    end

    -- ---- phase 2: in the fight, watch her colour map ---------------------
    if gs == GS_FIGHT then
        if fight == 0 then
            fight = frame
            log("fight started frame=%d p%d_char=%d (human P%d=%d) f_kham_next=%d",
                frame, P, r16(A.my_char), HUMAN, r16(A.human), r16(A.f))
            if NOTAPS then
                -- No taps: the drone must be whoever the tower chose.
                if r16(A.my_char) == FT_KHAM then
                    finish(false, string.format(
                        "NO taps were made, yet p%d_char=%d is Khameleon - she is " ..
                        "reachable without the gesture, so the summons proves nothing",
                        P, r16(A.my_char)))
                else
                    log("control OK: no taps, drone is char %d and f_kham_next=%d",
                        r16(A.my_char), r16(A.f))
                    finish(true, "no_taps_no_khameleon")
                end
                return
            end
            if r16(A.my_char) ~= FT_KHAM then
                finish(false, string.format(
                    "p%d_char=%d, not Khameleon (%d) - the summons did not reach " ..
                    "the drone (c_kham_ladder=%d f_kham_next=%d). Five CLEAN Start " ..
                    "taps on the BATTLE PLAN is what kham_ladder_tap wants, and " ..
                    "kham_ladder_summon has to spend the flag AFTER do_ladder",
                    P, r16(A.my_char), FT_KHAM, r16(A.c), r16(A.f)))
                return
            end
        end

        -- Keep the round alive: the cycle process dies with the round, and the
        -- next round's starts over at Jade.
        w16(A.p1_bar, FULL_BAR)
        w16(A.p2_bar, FULL_BAR)

        local obj = r32(A.my_obj)
        if obj ~= 0 then
            local map = (r16(obj + OPAL) >> 8) & 0xff
            if cram(map, SENTINEL_IDX) == SENTINEL then
                if map_seen == nil then
                    map_seen = map
                    log("Khameleon on colour map %d", map)
                end
                local w = cram(map, WITNESS)
                if w ~= last_word then
                    local who = NAME_OF[w] or string.format("?%04X", w)
                    if last_word == nil then
                        -- First reading of the run: she should still be on her
                        -- anchor.  If a change already landed during the round
                        -- intro this is a disguise, which is not a failure -
                        -- it is just an anchor we were too late to see.
                        if w == EXPECT.ANCHOR.witness then
                            anchor_seen = true
                            log("opens on %s (%s) frame=%d kham_guise=%d",
                                EXPECT.ANCHOR.name, who, frame, guise())
                            if guise() ~= 0 then
                                finish(false, string.format(
                                    "she is painted in her own KHMAIN_P but kham_guise " ..
                                    "is %d - the drone would fight as somebody else",
                                    guise()))
                                return
                            end
                        else
                            log("first reading is already %s frame=%d - too late for the anchor",
                                who, frame)
                        end
                        seq[#seq + 1] = who
                    else
                        local want = CYCLE[(step % #CYCLE) + 1]
                        seq[#seq + 1] = who
                        if w ~= want.witness then
                            -- Name the colour we WANTED, not the step's label: in
                            -- KD_NEGATIVE the witnesses are rotated and the labels
                            -- are not, so want.who would print the step's own name
                            -- for another disguise's colour and read as "JADE is
                            -- not JADE".
                            local want_who = NAME_OF[want.witness]
                                or string.format("?%04X", want.witness)
                            finish(false, string.format(
                                "step %d expected %s's colour %04X but the map holds "
                                .. "%s's %04X", step + 1, want_who, want.witness, who, w))
                            return
                        end
                        step = step + 1
                        -- The colours just became disguise number `want_idx`;
                        -- kham_guise must say the same, or drone and paint part.
                        local want_idx = ((step - 1) % #CYCLE) + 1
                        local g = guise()
                        if g ~= want_idx then
                            finish(false, string.format(
                                "painted as %s (disguise %d) but kham_guise=%d - " ..
                                "the drone would fight as a different ninja from " ..
                                "the one she is drawn in",
                                who, want_idx, g))
                            return
                        end
                        if step > 1 then
                            local gap = frame - last_change
                            gaps[#gaps + 1] = gap
                            log("step %d -> %s after %d ticks (%.2fs) kham_guise=%d",
                            step, who, gap, gap / 54.7068, guise())
                            if gap < GAP_LO - SLACK or gap > GAP_HI + SLACK then
                                bad = bad or string.format(
                                    "gap %d ticks (%.2fs) is outside %d..%d",
                                    gap, gap / 54.7068, GAP_LO, GAP_HI)
                            end
                        else
                            log("step %d -> %s frame=%d (not timed - the wait began before the fight)",
                                step, who, frame)
                        end
                        if step > 1 and want == CYCLE[1] then wraps = wraps + 1 end
                        for _, scr in pairs(manager.machine.screens) do
                            pcall(function() scr:snapshot() end)
                        end
                    end
                    last_word, last_change = w, frame
                end
            end
        end

        -- Four changes gives the wrap back to Jade and three timed gaps.
        if step >= 4 then
            if bad then finish(false, bad) else finish(true, "anchor_then_3_disguises_in_order_wrapped_on_time") end
            return
        end
        if frame - fight > 2600 then
            finish(false, string.format("only %d change(s) in 2600 ticks (map=%s)",
                                        step, tostring(map_seen)))
            return
        end
    end

    for n, fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
    if frame > 12000 then finish(false, "timeout phase=" .. phase) end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
