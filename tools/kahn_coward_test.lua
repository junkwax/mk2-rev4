-- kahn_coward_test.lua - SHAO KAHN SAYS "RUN, COWARD" POINTING, AND NEVER INTO
-- A LIVE FIREBALL (kahn_coward_talk / kahn_coward_note, MKBOSS.ASM).
--
-- 1P game, P1 Liu Kang (human, driven) vs a CPU Shao Kahn on his real brain -
-- no puppet hook, because the line is checked at the brain top
-- (kstalk_clean) and in the chase loop (kahn_stalk_a11), and a puppet reaches
-- neither.  Both bars are pinned every frame and the clock is frozen
-- (f_freeze_timer), so nobody wins and the round never ends under the rig.
--
-- Three things are measured per trial:
--   STAMP  Kahn's own decision: update_tsl writing his word of l_kahn_coward.
--          The authority on "he chose to say it".
--   SOUND  the track on the latch: triple_sndtab2 $63 -> $0402, $0403 or $0404 -
--          triple_sound2 ROTATES through the triple, so a rig watching $0402
--          alone misses two sends in three.  Pairs are taken STRICTLY and
--          resynced per frame; ROLLING pairing matched any $xx04 track followed
--          by a $02xx one and put a false hit into the control.
--   HOLD   one raise of the hand held through the line: BGTALK5 unbroken for
--          at least kct_speech - 15 - 3 ticks, and never left and returned to
--          (kahn_dummy_talk's part-2 WAG would do that).
--   POSE   the SAGs Kahn's multipart RAM hands the DMA: any piece in BGTALK1-5
--          (A/B) is the point lane, anitab1[018h] (a_sk_talkup).  Read out of
--          src/MKSK.TBL each run, never typed in.
-- A sound-only build stamps and sends but never draws BGTALK - the bug this
-- rig was written for.
--
-- Modes (CW_MODE):
--   flee    Kahn ahead by 41 (under kahn_dummy_talk's 040h lead, so his OTHER
--           taunt - the same pose - cannot fire and be mistaken for this one).
--           P1 walks away from 192px.  PASS: stamp, sound within 2 ticks of
--           it, pose 0-6 ticks after it and held >= 20.
--   zone    same lead; P1 stands still, then throws ONE high fireball
--           (F,F+HP).  The cooldown is pinned "just said" until he is still,
--           so the setup's slide cannot fire the FLEE half - only the
--           remembered throw (kct_pend) can.  PASS: as flee, plus kct_pend
--           armed while the fireball was live and no stamp, no send and no
--           pose START while any P1 projectile process was alive.  A throw
--           Kahn answered some other way (block, jump, clap) never arms the
--           note: that trial is NOT EXERCISED and another is run.
--   behind  CONTROL: Kahn BEHIND by 41, P1 flees exactly as in `flee`.  PASS:
--           no stamp, no send, no pose - and P1 really walking away.  This is
--           what caught kahn_dummy_talk's UNSIGNED lead test.
--
-- Every trial places the pair at x 424 / 616 (centring them on their own
-- midpoint walked later trials into the left wall at 106, where Back has
-- oxvel but goes nowhere) and seeds l_kahn_coward = 0 ("never") and
-- kct_pend = 0.  Both are .globl in MKBOSS.ASM for this rig.
--
--   CW_LOG, CW_MAP (the map that belongs to the zip), CW_MODE, CW_TRIALS

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("CW_LOG") or (ROOT .. "/tools/kahn_coward_test.log")
local MODE = (os.getenv("CW_MODE") or "flee"):lower()
local TRIALS = tonumber(os.getenv("CW_TRIALS") or "3") or 3
local TRACE = os.getenv("CW_TRACE") == "1"

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[cow] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local missing = false
local symbols = {}
do
    local mp = os.getenv("CW_MAP") or (ROOT .. "/src/mk2.map")
    local fh = assert(io.open(mp, "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
    log("map: %s", mp)
end

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_state", "p2_state", "p1_char", "p2_char",
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view",
                     "p1_obj", "p2_obj", "p1_proc", "p2_proc", "map_position", "battle_num",
                     "f_freeze_timer", "active", "l_kahn_coward", "kct_pend", "tick" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end

-- the talk lane's SAGs, out of the TBL
local TALK = {}
do
    local fh = io.open(ROOT .. "/src/MKSK.TBL", "r")
    if not fh then log("FATAL: no src/MKSK.TBL"); missing = true
    else
        local want = nil
        for line in fh:lines() do
            local lab = line:match("^(BGTALK%d[AB]):")
            if lab then want = lab
            elseif want then
                local h = line:match("%.long%s+(%x+)[Hh]")
                if h then TALK[tonumber(h, 16)] = want; want = nil end
            end
        end
        fh:close()
    end
    local n = 0; for _ in pairs(TALK) do n = n + 1 end
    log("talk lane SAGs from MKSK.TBL: %d", n)
    if n ~= 10 then log("FATAL: expected 10 BGTALK1-5 A/B records, found %d", n); missing = true end
end

-- DISPEQU / MKSTRUCT bit offsets
local OXVAL, OXPOS, OXVEL, OIMG = 0x080, 0x090, 0x040, 0x1a0
local MP_STRIDE = 112
local PLINK, PROCID = 0x000, 0x020
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_KAHN, KAHN_ARENA = 1, 13, 8
local MAX_HP = 0xa1
local LEAD = 41                       -- < 040h, so kahn_dummy_talk stays out
local TRACK = 0x0402               -- the triple: $0402, $0403, $0404 (triple_sound2 rotates)
local SND_LO, SND_HI, SND_PORT = 0x01d00000, 0x01d01fff, 0x01d01030
local TRIAL_LEN = 420
-- kct_speech (83) - the 15-tick raise: the hand must be held on BGTALK5 that
-- long without a break; a little slack for the frame the hold starts on
local HOLD_MIN = 83 - 15 - 3

local space, tap
local fields, held = {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function s32(v) v = v & 0xffffffff; return v >= 0x80000000 and v - 0x100000000 or v end
local function hold(n, on) held[n] = on and true or false end

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["1 Player Start"]=1, ["UI Select"]=1, ["P1 High Punch"]=1,
                   ["P1 Left"]=1, ["P1 Right"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do
        if not fields[n] then
            log("input %s: %s", n == "UI Select" and "absent (optional)" or "MISSING", n)
            if n ~= "UI Select" then missing = true end
        end
    end
end

-- piece SAGs Kahn is drawing; returns the talk record name if any piece is one
local function kahn_talk()
    local o = r32(A.p2_obj); if o == 0 then return nil end
    local mp = r32(o + OIMG); if mp == 0 then return nil end
    for i = 0, 12 do
        local s = r32(mp + i * MP_STRIDE)
        if s == 0 then return nil end
        if TALK[s] then return TALK[s] end
    end
    return nil
end

local function p1_proj_live()
    local p, g = r32(A.active + PLINK), 0
    while p ~= 0 and g < 512 do
        if (r16(p + PROCID) & 0xff00) == 0x0700 then return true end
        p = r32(p + PLINK); g = g + 1
    end
    return false
end

-- ------------------------------------------------------------------ sound
local frame = 0
-- A track goes out as two byte writes in one tick, high byte first (a track
-- number's high byte is <= 07).  Pair them STRICTLY, resyncing every frame:
-- the first cut paired ROLLING and matched any $xx04 track followed by a
-- $02xx one, which put a false $0402 into the behind control.  The decision
-- itself is judged off Kahn's own l_kahn_coward stamp; the latch is the proof
-- the line was SENT.
local snd_hi, snd_hi_frame = nil, -1
local snd_events = {}          -- frames $0402 was sent
local snd_ring = {}            -- every decoded track, {frame, code}, last 64
local function snd_around(f, w)
    local out = {}
    for _, e in ipairs(snd_ring) do
        if math.abs(e[1] - f) <= w then out[#out + 1] = string.format("%+d:$%04x", e[1] - f, e[2]) end
    end
    return table.concat(out, " ")
end
local function on_snd(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    local b = w & 0xff
    if snd_hi ~= nil and snd_hi_frame == frame then
        local code = (snd_hi << 8) | b
        snd_ring[#snd_ring + 1] = { frame, code }
        if #snd_ring > 64 then table.remove(snd_ring, 1) end
        if code >= TRACK and code <= TRACK + 2 then snd_events[#snd_events + 1] = frame end
        snd_hi = nil
        return data
    end
    if b <= 0x07 then snd_hi, snd_hi_frame = b, frame else snd_hi = nil end
    return data
end

-- ------------------------------------------------------------------ flow
local psel, confirm_at, fight_at, done = 0, 0, 0, false
local trial, t0, cur = 0, 0, nil
local results = {}
local last_end = 0
local rig_lkc = 0

local function finish()
    if done then return end
    done = true
    log("---- results CW_MODE=%s ----", MODE)
    local fails = 0
    for i, r in ipairs(results) do
        local ok, why
        if MODE == "behind" then
            ok = (r.stamp == nil) and (r.snd == nil) and (r.pose_at == nil) and (r.away_ticks >= 60)
            why = string.format("stamp=%s snd=%s pose=%s away_ticks=%d",
                tostring(r.stamp), tostring(r.snd), tostring(r.pose_at), r.away_ticks)
        else
            ok = r.stamp ~= nil and r.snd ~= nil and r.pose_at ~= nil
                 and math.abs(r.snd - r.stamp) <= 2
                 and r.pose_at >= r.stamp and r.pose_at - r.stamp <= 6
                 and (r.hold5 or 0) >= HOLD_MIN and (r.waves or 0) == 0
            why = string.format("stamp=%s snd=%s pose=%s(%s) len=%d hold5=%d waves=%d gap=%s",
                tostring(r.stamp), tostring(r.snd), tostring(r.pose_at), tostring(r.pose_rec),
                r.pose_len, r.hold5 or 0, r.waves or 0, tostring(r.gap_stamp))
            if MODE == "flee" then
                ok = ok and r.away_ticks >= 20
                why = why .. " away_ticks=" .. r.away_ticks
            else
                ok = ok and r.threw and r.pend_seen and not r.stamp_during_proj
                        and not r.snd_during_proj and not r.pose_start_during_proj
                why = why .. string.format(" threw=%s pend_armed=%s proj_gone=%s stamp_during_proj=%s snd_during_proj=%s pose_start_during_proj=%s",
                    tostring(r.threw), tostring(r.pend_seen), tostring(r.proj_gone),
                    tostring(r.stamp_during_proj), tostring(r.snd_during_proj),
                    tostring(r.pose_start_during_proj))
            end
        end
        ok = ok and true or false
        if not ok then fails = fails + 1 end
        log("trial %d %s  %s", i, ok and "PASS" or "FAIL", why)
    end
    if #results < TRIALS then
        log("only %d of %d trials ran (%d not exercised) - NO VERDICT", #results, TRIALS, skipped)
        fails = fails + 1
    end
    log(fails == 0 and "PASS" or ("FAIL - " .. fails .. " trial(s)"))
    logfh:close()
    manager.machine:exit()
end

local function start_trial()
    -- Always the same spot.  Placing round their own midpoint walked later
    -- trials into the stage's left wall (x 106), where a man holding Back has
    -- oxvel but goes nowhere and Kahn never has to chase him.
    local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
    local m = 520
    w32(o1 + OXVAL, (m - 0x60) << 16)
    w32(o2 + OXVAL, (m + 0x60) << 16)
    -- cooldown clear ("never"); zone mode re-pins it every tick until the throw
    w16(A.l_kahn_coward, 0); w16(A.l_kahn_coward + 16, 0)
    rig_lkc = 0
    w16(A.kct_pend, 0)
    trial = trial + 1
    t0 = frame
    cur = { pose_len = 0, away_ticks = 0 }
    log("trial %d start frame=%d p1x=%d kahnx=%d", trial, frame, m - 0x60, m + 0x60)
end

local skipped = 0
local function end_trial(why)
    cur.why = why
    log("trial %d end (%s) snd=%s pose=%s len=%d", trial, why, tostring(cur.snd), tostring(cur.pose_at), cur.pose_len)
    if cur.stamp_frame then
        log("trial %d tracks around the decision: %s", trial, snd_around(cur.stamp_frame, 10))
    end
    -- zone: Kahn does not always answer a fireball through
    -- kahn_counter_projectile (he can block, jump or clap it through other
    -- branches).  A throw that never armed the note did not exercise the path
    -- under test - not a failure, and not a pass either: run another.
    if MODE == "zone" and not cur.pend_seen and cur.stamp == nil then
        skipped = skipped + 1
        log("trial %d not exercised (no note armed) - %d skipped", trial, skipped)
    else
        results[#results + 1] = cur
    end
    cur = nil
    last_end = frame
    if #results >= TRIALS or skipped >= 3 * TRIALS then finish() end
end

local function tick()
    if done then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        local ok, err = pcall(function() tap = space:install_write_tap(SND_LO, SND_HI, "cow_snd", on_snd) end)
        log("mode=%s trials=%d sound tap %s", MODE, TRIALS, ok and "installed" or ("FAILED " .. tostring(err)))
        if missing or not ok then finish(); return end
    end
    if frame > 24000 then log("backstop: out of frames"); finish(); return end

    local gs = r16(A.gstate)
    if frame % 600 == 0 then log("hb frame=%d gs=%02x psel=%d fight=%d trial=%d", frame, gs, psel, fight_at, trial) end
    if psel == 0 and gs == GS_PSEL then psel = frame; log("select at %d", frame) end

    if fight_at == 0 then
        if psel == 0 then
            hold("UI Select", frame >= 5 and frame < 35)
            hold("Coin 1", frame >= 700 and frame < 980 and (frame % 80) < 20)
            hold("1 Player Start", frame >= 1000 and frame < 1080)
        else
            hold("Coin 1", false); hold("1 Player Start", false); hold("UI Select", false)
            w16(A.p1_state, 1); w16(A.p2_state, 0)
            w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_KAHN)
            w16(A.curback, KAHN_ARENA); w16(A.map_position, 14); w16(A.battle_num, 15)
            if confirm_at == 0 and gs == GS_PSEL and frame - psel > 90 then confirm_at = frame end
            hold("P1 High Punch", confirm_at > 0 and frame - confirm_at < 45)
            if gs == GS_FIGHTING then fight_at = frame; hold("P1 High Punch", false); log("fight live at %d", frame) end
        end
        for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
        return
    end

    -- fight: bars and clock pinned every frame
    w16(A.f_freeze_timer, 1)
    local kb, pb = MAX_HP, MAX_HP - LEAD
    if MODE == "behind" then kb, pb = MAX_HP - LEAD, MAX_HP end
    w16(A.p1_bar, pb); w16(A.p1_bar_view, pb)
    w16(A.p2_bar, kb); w16(A.p2_bar_view, kb)
    for n in pairs(held) do held[n] = false end

    local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
    if gs ~= GS_FIGHTING or o1 == 0 or o2 == 0 then
        for n, f in pairs(fields) do f:set_value(0) end
        return
    end

    if cur == nil and frame - fight_at > 90 and #results < TRIALS
       and frame - last_end > 60 then
        start_trial()
    end

    if cur then
        local rel = frame - t0
        local x1, x2 = s16(r16(o1 + OXPOS)), s16(r16(o2 + OXPOS))
        local left = x1 < x2
        local away, toward = left and "P1 Left" or "P1 Right", left and "P1 Right" or "P1 Left"
        local proj = p1_proj_live()

        if MODE == "zone" then
            local p1p = r32(A.p1_proc)
            local p1a = p1p ~= 0 and r16(p1p + 0x1f0) or 0xffff
            if cur.go == nil then
                -- Pin the cooldown "just said" until P1 stands still, so the
                -- FLEE half cannot fire off the setup's own slide: only the
                -- remembered throw may be what makes him say it.
                local t = r16(A.tick); if t == 0 then t = 1 end
                w16(A.l_kahn_coward, t); w16(A.l_kahn_coward + 16, t); rig_lkc = t
                if rel >= 40 and p1a == 0 and s32(r32(o1 + OXVEL)) == 0 then
                    cur.go = rel
                    w16(A.l_kahn_coward, 0); w16(A.l_kahn_coward + 16, 0); rig_lkc = 0
                    log("trial %d throw starts at rel %d", trial, rel)
                end
            else
                local g = rel - cur.go
                hold(toward, (g >= 0 and g < 4) or (g >= 8 and g < 12))
                hold("P1 High Punch", g >= 12 and g < 17)
            end
            if proj then cur.threw = true end
            if cur.threw and not proj then cur.proj_gone = cur.proj_gone or rel end
            if proj and r16(A.kct_pend) ~= 0 and not cur.pend_seen then
                cur.pend_seen = true
                log("trial %d kct_pend armed at rel %d (fireball live)", trial, rel)
            end
        elseif rel >= 40 then
            hold(away, true)
            local v = s32(r32(o1 + OXVEL))
            if (left and v < 0) or ((not left) and v > 0) then cur.away_ticks = cur.away_ticks + 1 end
        end

        if rel % 30 == 0 or (TRACE and cur.go and rel >= cur.go and cur.stamp == nil) or (TRACE and cur.stamp and rel <= cur.stamp + 3) then
            local p2p = r32(A.p2_proc)
            log("  t%d rel=%d x1=%d x2=%d gap=%d v1=%.2f v2=%.2f kact=%04x p1act=%04x ochar2=%d bars %d/%d tick=%d lkc=%d pend=%d proj=%s",
                trial, rel, x1, x2, math.abs(x2 - x1), s32(r32(o1 + OXVEL)) / 65536, s32(r32(o2 + OXVEL)) / 65536,
                p2p ~= 0 and r16(p2p + 0x1f0) or 0xffff, r32(A.p1_proc) ~= 0 and r16(r32(A.p1_proc) + 0x1f0) or 0xffff,
                r16(o2 + 0x1f0), r16(A.p1_bar), r16(A.p2_bar), r16(A.tick), r16(A.l_kahn_coward + 16), r16(A.kct_pend), tostring(proj))
        end

        -- Kahn's own decision: update_tsl writing his (p2) word
        local lk = r16(A.l_kahn_coward + 16)
        if lk ~= 0 and lk ~= rig_lkc and cur.stamp == nil then
            cur.stamp = rel; cur.gap_stamp = math.abs(x2 - x1); cur.stamp_frame = frame
            if proj then cur.stamp_during_proj = true end
            log("trial %d STAMP (decided) at rel %d gap=%d proj_live=%s", trial, rel, cur.gap_stamp, tostring(proj))
        end

        -- sound events since this trial began
        for _, f in ipairs(snd_events) do
            if f >= t0 and cur.snd == nil then
                cur.snd = f - t0
                cur.gap_snd = math.abs(x2 - x1)
                if proj then cur.snd_during_proj = true end
                log("trial %d $0402 at rel %d gap=%d proj_live=%s", trial, cur.snd, cur.gap_snd, tostring(proj))
            end
        end

        local rec = kahn_talk()
        if rec then
            if cur.pose_at == nil then
                cur.pose_at = rel; cur.pose_rec = rec
                log("trial %d talk pose %s at rel %d", trial, rec, rel)
            end
            cur.pose_len = cur.pose_len + 1
            -- ONE raise held for the line: count the longest unbroken run
            -- on the raised frame, and any drop back below it followed by a
            -- rise again (a wag) - the unpoint only ever goes down.
            if rec == "BGTALK5A" then
                cur.run5 = (cur.run5 or 0) + 1
                if cur.run5 > (cur.hold5 or 0) then cur.hold5 = cur.run5 end
                if cur.left5 then cur.waves = (cur.waves or 0) + 1; cur.left5 = false end
            else
                if (cur.run5 or 0) > 0 then cur.left5 = true end
                cur.run5 = 0
            end
            if proj and cur.pose_len == 1 then cur.pose_start_during_proj = true end
        end

        local settled = cur.pose_at and not rec and cur.pose_len > 0
        if settled and (cur.stamp ~= nil) then end_trial("pose ended")
        elseif rel >= TRIAL_LEN then end_trial("timeout") end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
end

emu.register_frame_done(tick)
emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
log("kahn coward rig armed")
