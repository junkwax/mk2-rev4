-- sweep_addon_suddeath.lua - a match's FIRST tie is a DRAW; the next one is
-- SUDDEN DEATH, and in it the first hit wins (suddeath / sudden_draws,
-- MAINEQU.ASM).
--
-- Round 1: both fighters stand still and the rig empties both bars on the
-- same frame - the same equal-bars state a double KO or a level timeout
-- leaves.  @tie_count goes to 1, which is inside sudden_draws, so f_sudden
-- must stay 0 and the banner must read DRAW (snapshotted).  The SUDDEN DEATH
-- line must NOT be sent here - that is the control for the whole change - and
-- the DRAW line (triple_sndtab2 $67 -> 021eh) MUST be, which is the positive
-- half.  With -Listen both are then scored against the recorded mix BY LABEL,
-- because the two latch lines log in the same format.
--
-- Round 2: an ORDINARY round - the intro reads ROUND 2, f_sudden is 0 and the
-- bars charge to full, not to sudden_strength.  The rig then forces the same
-- tie again.  @tie_count 2 is past the allowance, so this one raises f_sudden
-- and the banner reads SUDDEN DEATH with the announcer's line.
--
-- Round 3 (sudden death): the intro is snapshotted (SUDDEN DEATH in place of
-- ROUND 3) and the bars open on sudden_strength.  P1 throws a high kick every
-- PERIOD frames at DIST px.  P2 holds block first: every blocked kick (P2's
-- p_hit rising while he guards) must leave his bar exactly full - no chip.
-- After BLOCKS_WANTED blocks P2 drops the guard, and the next bar movement
-- must be full -> 0 in one step.
--
-- Round 4: an ordinary round again - f_sudden must be 0, the intro reads
-- ROUND 4.
--
-- Env: SD_LOG.  Driven by run_suddeath_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("SD_LOG") or (ROOT .. "/tools/suddeath.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[sd] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local need = { "gstate", "round_num", "f_sudden", "tie_count", "p1_bar", "p2_bar",
               "p1_obj", "p2_obj", "p2_proc", "p1_matchw", "p2_matchw" }
for _, n in ipairs(need) do
    if not sym[n] then
        log("%s is not in mk2.map%s", n, n == "f_sudden" and " - suddeath is compiled OUT" or "")
        log("VERDICT: NOT BUILT")
        return
    end
end

local ACT_BLOCKHI = 0x0700
local P_ACTION, P_HIT = 0x1f0, 0x370
local OXPOS, OXVAL = 0x090, 0x080
local FULL = 0xA1
-- sudden_strength (MAINEQU.ASM): a sudden-death round charges to 10%
local SUDDEN_HP = FULL // 10
local PERIOD, DIST = 26, 70
local BLOCKS_WANTED = 3

for _, n in ipairs({
    "P1 Left", "P1 Right", "P1 Up", "P1 Down",
    "P1 High Punch", "P1 Low Punch", "P1 High Kick", "P1 Low Kick", "P1 Block",
    "P2 Left", "P2 Right", "P2 Up", "P2 Down",
    "P2 High Punch", "P2 Low Punch", "P2 High Kick", "P2 Low Kick", "P2 Block",
}) do ADDON_OWNS[n] = true end

-- SD_NO_SHOTS=1: no snapshots.  The PNG flood starves the HOST sound device
-- (the wav tap is immune, but a listener is not), so the -Listen run turns it
-- off.  SD_SND=1 taps the hardware sound latch (SYSEQU.ASM `sound`), which is
-- what proves a track was actually SENT rather than refused by triple_sound.
local NO_SHOTS = os.getenv("SD_NO_SHOTS") == "1"
local SND_TAP  = os.getenv("SD_SND") ~= nil and os.getenv("SD_SND") ~= ""
local SND_ALL  = os.getenv("SD_SND") == "all"   -- log every code, not just ours
local SND_PORT, TAP_LO, TAP_HI = 0x01d01030, 0x01d00000, 0x01d01fff
-- triple_sndtab2 $64 -> track 02fdh (MKSOUND.ASM): the SUDDEN DEATH line.
local SD_TRACK_LO, SD_TRACK_HI = 0x02fd, 0x02ff
-- triple_sndtab2 $67 -> track 021eh (MKSOUND.ASM:756, sound/stlaugh_patch.txt
-- note (52)): the DRAW line.  It is the POSITIVE half of the same rule - it
-- must be sent at the FIRST tie, and must NOT be sent at the second, which is
-- sudden death.  Counted rather than just timestamped, so "sent again at the
-- second tie" can be told from "the round-1 send is still on the clock".
local DRAW_TRACK_LO, DRAW_TRACK_HI = 0x021e, 0x0220
-- SD_MODE=stall: skip the block/one-hit half of round 3 and instead STAND
-- STILL for the whole 99-second clock.  Both bars end the round untouched at
-- sudden_strength, which is what "both players at full strength" means in a
-- sudden-death round - weed_out_cheaters (MAIN.ASM) must call that GAME OVER.
-- It read full_strength*2 outright before, so the one round in the game that
-- exists to stop stalling was the one round stalling worked in.
local STALL = os.getenv("SD_MODE") == "stall"
local GS_GAMEOVER = 0x0b
local snd_pending, sd_track_at, tie_ms, snd_tap = nil, nil, nil, nil
local draw_track_at, draw_n, draw_n_tie2 = nil, 0, 0

local space, fields, frame = nil, {}, 0
local phase = "r1"
local phase_at = 0
local fails = {}
local function fail(f, ...) local m = string.format(f, ...); fails[#fails+1] = m; log("FAIL: " .. m) end

local function r16(a) return space:read_u16(a) & 0xffff end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on) local f = fields[n]; if f then f:set_value(on and 1 or 0) end end
local function now_ms()
    local ok, t = pcall(function() return manager.machine.time:as_double() end)
    if ok and t then return t * 1000.0 end
    return 0
end
local function shot(tag)
    if NO_SHOTS then return end
    pcall(function() manager.machine.screens[":screen"]:snapshot() end)
    log("  snapshot: %s (frame %d)", tag, frame)
end

-- The latch takes a track code as two 16-bit writes, each byte OR'd with
-- 0ff00h (see tools/kahn_fatality_audio_probe.lua).
local function on_sound_write(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_pending = nil; return data end
    -- ROLLING pair, not a strict two-write pairing.  One odd write anywhere
    -- earlier puts a strict pairing permanently out of phase, and the code
    -- being looked for then straddles the boundary: 02fd showed up as the
    -- tail of one "code" and the head of the next, and read as never sent.
    local byte = w & 0xff
    local prev = snd_pending
    snd_pending = byte
    if prev == nil then return data end
    local code = (prev << 8) | byte
    if code >= SD_TRACK_LO and code <= SD_TRACK_HI then
        if not sd_track_at then sd_track_at = now_ms() end
        log("  sound latch: track %04x (SUDDEN DEATH) at %.1fms%s", code, now_ms(),
            tie_ms and string.format(", %.0fms after the banner", now_ms() - tie_ms) or "")
    elseif code >= DRAW_TRACK_LO and code <= DRAW_TRACK_HI then
        draw_n = draw_n + 1
        if not draw_track_at then draw_track_at = now_ms() end
        log("  sound latch: track %04x (DRAW) at %.1fms%s", code, now_ms(),
            tie_ms and string.format(", %.0fms after the banner", now_ms() - tie_ms) or "")
    elseif SND_ALL then
        -- every other code, so "nothing was sent" can be told apart from
        -- "the tap is not seeing this one"
        log("  latch %04x at %.1fms%s", code, now_ms(),
            tie_ms and string.format(" (%+.0fms vs banner)", now_ms() - tie_ms) or "")
    end
    return data
end
local function finish()
    if SND_TAP then
        log("sound: SUDDEN DEATH track %s", sd_track_at
            and string.format("sent at %.1fms (wav offset)", sd_track_at) or "NEVER SENT")
        log("sound: DRAW track %s", draw_track_at
            and string.format("sent at %.1fms (wav offset), %d send(s)",
                              draw_track_at, draw_n) or "NEVER SENT")
    end
    if #fails == 0 then log("VERDICT: PASS") else log("VERDICT: FAIL (%d)", #fails) end
    if fh then fh:flush() end
    manager.machine:exit()
end

-- the sudden-death round's state
local fight_at, blocks, last_phit, last_p2, released, lethal_seen = 0, 0, 0, SUDDEN_HP, false, false

-- Force the equal-bars state a double KO leaves.  Used twice: the DRAW tie
-- and the SUDDEN DEATH one.
local function force_tie(what)
    space:write_u16(sym.p1_bar, 0)
    space:write_u16(sym.p2_bar, 0)
    log("%s: both bars emptied on frame %d (a forced tie)", what, frame)
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== sudden death ===")
        if SND_TAP then
            -- KEEP THE HANDLE.  A tap whose object is not referenced is
            -- collected and never fires again - which looks exactly like a
            -- silent game, and cost a run that reported "track NEVER SENT"
            -- while the recording was full of music.
            local ok, err = pcall(function()
                snd_tap = space:install_write_tap(TAP_LO, TAP_HI, "sndtap", on_sound_write) end)
            log("  sound-latch tap: %s", (ok and snd_tap) and "installed"
                or ("FAILED " .. tostring(err)))
            if not (ok and snd_tap) then fail("could not install the sound tap") end
        end
    end
    local gs, rn = r16(sym.gstate), r16(sym.round_num)
    local fs, tc = r16(sym.f_sudden), r16(sym.tie_count)

    if phase == "r1" then
        if gs == 2 and rn == 1 then
            if phase_at == 0 then phase_at = frame end
            if fs ~= 0 then fail("f_sudden already set in round 1 (%d)", fs) end
            if tc ~= 0 then fail("tie_count is %d at the start of a match, want 0", tc) end
            if frame - phase_at == 60 then
                force_tie("round 1")
                phase, phase_at = "tie1", frame
            end
        end

    elseif phase == "tie1" then
        if gs == 5 then
            if phase_at >= 0 then
                phase_at = -frame                    -- bonus-count start
                log("tie 1 -> bonus count: f_sudden=%d tie_count=%d  matchw %d-%d", fs, tc,
                    r16(sym.p1_matchw), r16(sym.p2_matchw))
                if tc ~= 1 then fail("tie_count=%d after the first tie, want 1", tc) end
                if fs ~= 0 then
                    fail("f_sudden=%d after the FIRST tie - it should still be a DRAW", fs) end
                if r16(sym.p1_matchw) ~= 0 or r16(sym.p2_matchw) ~= 0 then
                    fail("a tie awarded a round") end
            end
            local d = frame + phase_at
            if d == 8 or d == 10 or d == 12 or d == 14 then shot("DRAW banner +" .. d) end
        elseif gs == 7 and rn == 2 then
            if SND_TAP and sd_track_at then
                fail("the SUDDEN DEATH line was sent at the first tie, which is a DRAW") end
            if SND_TAP and not draw_track_at then
                fail("no DRAW track (%04x-%04x) was sent at the first tie",
                     DRAW_TRACK_LO, DRAW_TRACK_HI) end
            phase, phase_at = "r2intro", frame
            log("round 2 intro: f_sudden=%d tie_count=%d", fs, tc)
            if fs ~= 0 then fail("round 2 is sudden death (f_sudden=%d) - it follows a DRAW", fs) end
        end

    elseif phase == "r2intro" then
        local d = frame - phase_at
        if d == 6 or d == 8 or d == 10 or d == 12 then shot("round 2 intro +" .. d) end
        if gs == 2 and rn == 2 then
            log("round 2 fight: bars %d / %d (want %d each - an ordinary round)",
                r16(sym.p1_bar), r16(sym.p2_bar), FULL)
            if r16(sym.p1_bar) ~= FULL or r16(sym.p2_bar) ~= FULL then
                fail("the round after a DRAW opened on %d/%d, want %d - it charged like sudden death",
                     r16(sym.p1_bar), r16(sym.p2_bar), FULL) end
            phase, phase_at = "r2", frame
        end

    elseif phase == "r2" then
        if frame - phase_at == 60 then
            force_tie("round 2")
            phase, phase_at = "tie2", frame
        end

    elseif phase == "tie2" then
        if gs == 5 then
            if phase_at >= 0 then
                phase_at = -frame
                tie_ms = now_ms()
                log("tie 2 -> bonus count: f_sudden=%d tie_count=%d  matchw %d-%d  (t=%.1fms)",
                    fs, tc, r16(sym.p1_matchw), r16(sym.p2_matchw), tie_ms)
                draw_n_tie2 = draw_n     -- anything after this is a SECOND-tie send
                if tc ~= 2 then fail("tie_count=%d after the second tie, want 2", tc) end
                if fs ~= 1 then fail("f_sudden=%d after the SECOND tie, want 1", fs) end
                if r16(sym.p1_matchw) ~= 0 or r16(sym.p2_matchw) ~= 0 then
                    fail("a tie awarded a round") end
            end
            local d = frame + phase_at
            if d == 8 or d == 10 or d == 12 or d == 14 then shot("SUDDEN DEATH banner +" .. d) end
        elseif gs == 7 and rn == 3 then
            if SND_TAP and not sd_track_at then
                fail("no SUDDEN DEATH track (%04x-%04x) was sent at the second tie",
                     SD_TRACK_LO, SD_TRACK_HI)
            end
            if SND_TAP and draw_n > draw_n_tie2 then
                fail("the DRAW line was sent at the second tie, which is SUDDEN DEATH")
            end
            phase, phase_at = "r3intro", frame
            log("round 3 intro: f_sudden=%d", fs)
            if fs ~= 1 then fail("round 3 is not sudden death (f_sudden=%d)", fs) end
        end

    elseif phase == "r3intro" then
        local d = frame - phase_at
        if d == 6 or d == 8 or d == 10 or d == 12 then shot("round 3 intro +" .. d) end
        if SND_TAP and sd_track_at and (now_ms() - sd_track_at) > 6000 then
            fail("the line played again at the round intro, which should be silent")
            sd_track_at = now_ms()
        end
        if gs == 2 and rn == 3 then
            phase, fight_at = STALL and "r3stall" or "r3", frame
            last_p2 = r16(sym.p2_bar)
            log("round 3 fight%s: bars %d / %d (want %d each)",
                STALL and " (STALL - nobody presses anything)" or "",
                r16(sym.p1_bar), last_p2, SUDDEN_HP)
            if last_p2 ~= SUDDEN_HP or r16(sym.p1_bar) ~= SUDDEN_HP then
                fail("sudden death opened on %d/%d, want %d - the 10%% charge",
                     r16(sym.p1_bar), last_p2, SUDDEN_HP) end
        end

    elseif phase == "r3stall" then
        -- Nobody presses anything and nobody is pinned.  The clock is the
        -- whole test: ~99 seconds at 54.7Hz, then the round ends with both
        -- bars still on sudden_strength.
        local t = frame - fight_at
        if t % 600 == 0 then
            log("  stalling t=%d: bars %d / %d, clock %d%d", t,
                r16(sym.p1_bar), r16(sym.p2_bar),
                sym.clk_tens and r16(sym.clk_tens) or 0,
                sym.clk_ones and r16(sym.clk_ones) or 0)
        end
        if r16(sym.p1_bar) ~= SUDDEN_HP or r16(sym.p2_bar) ~= SUDDEN_HP then
            fail("a bar moved during the stall (%d / %d) - somebody attacked, so this trial proves nothing",
                 r16(sym.p1_bar), r16(sym.p2_bar))
            finish(); return
        end
        if gs == GS_GAMEOVER then
            log("stall -> GAME OVER at t=%d (gstate %02xh), round_num still %d", t, gs, rn)
            shot("stalled sudden death -> game over")
            finish(); return
        end
        if rn >= 4 or (gs == 7 and rn ~= 3) then
            fail("a stalled SUDDEN DEATH round started round %d instead of GAME OVER - "
                 .. "weed_out_cheaters compared against full_strength*2, not this round's charge", rn)
            finish(); return
        end
        if t > 8000 then
            fail("no round end in %d frames of stalling (clock never ran out?)", t)
            finish(); return
        end

    elseif phase == "r3" then
        local t = frame - fight_at
        local o1, o2 = space:read_u32(sym.p1_obj), space:read_u32(sym.p2_obj)
        local r2 = space:read_u32(sym.p2_proc)
        if o1 == 0 or o2 == 0 or r2 == 0 then return end
        local p2 = r16(sym.p2_bar)
        local a2 = r16(r2 + P_ACTION)
        local phit = r16(r2 + P_HIT) & 0xff

        if not lethal_seen then
            -- pin the gap (oxval; a write to oxpos is overwritten before the draw)
            local x1 = s16(r16(o1 + OXPOS))
            local x2 = s16(r16(o2 + OXPOS))
            local tx = (x1 < x2) and (x1 + DIST) or (x1 - DIST)
            space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
        end

        press("P2 Block", not released)
        press("P1 High Kick", t > 40 and (t % PERIOD) < 3 and not lethal_seen)

        if not released and phit > last_phit and a2 == ACT_BLOCKHI then
            blocks = blocks + 1
            log("  blocked kick %d at t=%d: p2_bar=%d", blocks, t, p2)
        end
        last_phit = phit

        if p2 ~= last_p2 then
            if not released then
                fail("P2's bar moved %d -> %d while he was blocking (chip in sudden death)", last_p2, p2)
            elseif not lethal_seen then
                lethal_seen = true
                log("first clean hit at t=%d: p2_bar %d -> %d", t, last_p2, p2)
                if p2 ~= 0 then fail("first hit took %d, not the whole bar", last_p2 - p2) end
                shot("the one hit")
            end
            last_p2 = p2
        end
        if not released and blocks >= BLOCKS_WANTED then
            released = true
            log("  guard dropped at t=%d after %d blocks, p2_bar still %d", t, blocks, p2)
            -- a blocked kick's own block_shake can still be running; let the
            -- next hit be a clean one
        end
        if r16(sym.p1_bar) ~= SUDDEN_HP then
            fail("P1's bar moved (%d) - P2 never attacks", r16(sym.p1_bar)) end
        if t > 1500 and not lethal_seen then
            fail("no decisive hit in 1500 frames (blocks=%d, released=%s)", blocks, tostring(released))
            finish(); return
        end
        if gs == 5 then
            phase, phase_at = "r3bonus", frame
            log("round 3 over: f_sudden=%d tie_count=%d  matchw %d-%d",
                fs, tc, r16(sym.p1_matchw), r16(sym.p2_matchw))
            if fs ~= 0 then fail("f_sudden still %d after a decided round", fs) end
            if tc ~= 2 then fail("tie_count moved to %d on a decided round, want 2", tc) end
            if r16(sym.p1_matchw) ~= 1 then fail("P1 was not given the round") end
            if blocks < BLOCKS_WANTED then fail("only %d blocks seen", blocks) end
        end

    elseif phase == "r3bonus" then
        local d = frame - phase_at
        if d == 60 then shot("round 3 winner banner") end
        if gs == 7 and rn == 4 then
            phase, phase_at = "r4intro", frame
            log("round 4 intro: f_sudden=%d", fs)
            if fs ~= 0 then fail("round 4 is still sudden death") end
        end

    elseif phase == "r4intro" then
        local d = frame - phase_at
        if d == 10 then shot("round 4 intro") end
        if d >= 12 then finish() end
    end

    if frame > 26000 then fail("timed out in phase %s", phase); finish() end
end)
