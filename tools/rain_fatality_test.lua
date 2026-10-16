-- rain_fatality_test.lua
--
-- RAIN's LIGHTNING FATALITY (do_rain_fatal, MKRAINF.ASM): Down, Down, Back,
-- Forward + HK in FINISH HIM.  The storm gathers, bolts rain down around the
-- man and into him, and the last one splits him in two along
-- data/RAINSPLIT.WAX - his own legs and torso art, whoever he is.
--
-- P1 = Rain, reached the way every hidden-fighter rig does: pick his base
-- character (Scorpion) at the select screen and overwrite p1_char at GS_POST.
-- P2 = the victim.  FINISH HIM is forced by emptying his bar with P1 on match
-- point; the rig then snaps the pair inside rnf_maxdist and plays the input.
--
-- What it proves without pictures (the snapshots are for looking):
--   f_death == 2         the fatality started
--   rnf_zap > 0          bolts landed on him: he was jolting
--   rnf_split == 1       the last bolt landed and he came apart
--   a LEGS object        a non-player object carrying his ochar and oid
--   the halves move      legs and torso end up at different x
--   geo_drew rising      the lightning really was CPU-drawn every tick
--   budgets              geo_dropped / palq_drops / dmaq_late / peak_overload
--
--   RNF_VICTIM      subzero | kitana | kang | cage | kunglao | jax | baraka |
--                   shang | raiden | scorpion | reptile | mileena (default jax)
--   RNF_SNAP_EVERY  snapshot every N frames through the fatality (default 4)
--   RNF_LOG         log path

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("RNF_VICTIM") or "jax"):lower()
local SNAP_EVERY = tonumber(os.getenv("RNF_SNAP_EVERY") or "4") or 4
local LOG    = os.getenv("RNF_LOG") or (ROOT .. "/tools/rain_fatality_" .. VICTIM .. ".log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rnf/" .. VICTIM .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open((os.getenv("RNF_MAP") or (ROOT .. "/src/mk2.map")), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "p1_obj", "p2_obj", "f_death", "objlst", "blood_count",
               "rnf_zap", "rnf_split", "rnf_cx", "geo_drew", "geo_dropped",
               "palq_drops", "dmaq_late", "dmaq_lost", "peak_overload", "flash_did",
               "rnf_struck", "rnf_main_n", "rnf_up_state", "geo_full", "overload", "geo_count",
               "curback" }
-- rnf_bolts exists only in the SPRITE version (rnf_geo 0, MKRAINF's
-- rnf_salvo): Trilogy's 14 painted bolts, no CPU-drawn leader
local SPRITES = symbols["rnf_bolts"] ~= nil
local bolts_peak, done_at = 0, 0
-- THE JOLT MUST WAIT FOR A BOLT.  rnf_victim used to start him frying off a
-- CHANGE in the strike COUNT, and nothing cleared that count on the way into
-- the fatality - so the second Rain fatality of a session opened with the
-- previous one's 14 still there and he fried through the arms going up, with
-- nothing in the sky.  The rig now SEEDS that leftover (RNF_SEED_BOLTS, on by
-- default) and watches his oxpos: the buzz is 1 px each side of where he
-- stood every tick, so an alternating x while rnf_struck is still 0 is him
-- electrocuting before a bolt hit.
local SEED_BOLTS  = (os.getenv("RNF_SEED_BOLTS") or "1") ~= "0"
-- RNF_STAGE forces the stage (curback): 0 dead pool, 4 LIVING FOREST, ...  The
-- forest is the one that shows a background palette arriving mid-storm - it
-- scrolls seven parallax planes of trees and every bolt's shake streams new
-- blocks in.
local STAGE       = tonumber(os.getenv("RNF_STAGE") or "")
local seeded      = false
local prejolt     = 0        -- alternations seen before the first strike
local pre_x, pre_dx = nil, nil
local A, missing = {}, false
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n); missing = true end
end

local O_OXPOS, O_OXVAL, O_OYPOS, O_OZVAL = 0x090, 0x080, 0x0b0, 0x0c0
local O_OFLAGS, O_OSHAPE = 0x0f0, 0x1d0
local addr2sym = {}
local O_OCHAR, O_OID
do
    local fh = io.open(ROOT .. "/src/DISPEQU.ASM", "r")
    for line in fh:lines() do
        local n, v = line:match("^(%w+)%s+%.set%s+(%x+)h")
        if n == "ochar" then O_OCHAR = tonumber(v, 16) end
        if n == "oid" then O_OID = tonumber(v, 16) end
    end
    fh:close()
end

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_RAIN = 10, 19
local VICTIMS = { kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
                  shang = 6, raiden = 7, subzero = 8, reptile = 9, scorpion = 10, jax = 11 }
local WANT_P2 = VICTIMS[VICTIM] or 11
local FATAL_DIST = 0x60         -- inside rnf_maxdist (0c0h)
-- D, D, B, F then HK.  P1 is on the left, so Back is Left and Forward is Right.
local SEQ = { { "P1 Down", 0, 5 }, { "P1 Down", 9, 14 }, { "P1 Left", 18, 23 },
              { "P1 Right", 27, 32 }, { "P1 High Kick", 34, 40 } }

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, combo_at, done = 0, 0, 0, false
local fatal_at, split_at, tries, snaps = 0, 0, 0, 0
local zap_peak, legs_seen, legs_obj, blood_peak = 0, false, 0, 0
local zap_lines = 0
local ovl = {}
local base = {}
local final = {}

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1, ["P2 Low Punch"]=1,
                   ["P1 Right"]=1, ["P1 Left"]=1, ["P1 Down"]=1, ["P1 High Kick"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

local function snap_to(dist)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local mid = (r16(p1o + O_OXPOS) + r16(p2o + O_OXPOS)) // 2
    place(p1o, mid - dist // 2)
    place(p2o, mid + dist - dist // 2)
end

local function snap() snaps = snaps + 1; manager.machine.video:snapshot() end

local function find_legs()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p2o == 0 then return 0 end
    local ch, id = r16(p2o + O_OCHAR), r16(p2o + O_OID)
    local o, n = r32(A.objlst), 0
    while o ~= 0 and n < 250 do
        if o ~= p1o and o ~= p2o and r16(o + O_OCHAR) == ch and r16(o + O_OID) == id then return o end
        o = r32(o); n = n + 1
    end
    return 0
end

-- rnf_explode 1: no legs - the victim goes inviso and MK2's body pop throws
-- oid_bones chunks (r_shocker_pop / explode, MKDIE.ASM).  Counted off objlst.
local OID_BONES, M_INVISO = 0x010c, 0x0020
local bones_peak, inviso_seen = 0, false
local function count_bones()
    local o, n, c = r32(A.objlst), 0, 0
    while o ~= 0 and n < 400 do
        if r16(o + O_OID) == OID_BONES then c = c + 1 end
        o = r32(o); n = n + 1
    end
    return c
end

local function describe(tag, o)
    if o == 0 then return tag .. "=none" end
    local sh = r32(o + O_OSHAPE)
    return string.format("%s x=%d y=%d z=%x fl=%04x %s", tag, s16(r16(o + O_OXPOS)),
        s16(r16(o + O_OYPOS)), r32(o + O_OZVAL), r16(o + O_OFLAGS),
        addr2sym[sh] or string.format("%08x", sh))
end

local function verdict()
    local ok, why = true, {}
    log("p1_char=%d (want %d)  p2_char=%d (want %d)", r16(A.p1_char), FT_RAIN,
        r16(A.p2_char), WANT_P2)
    if r16(A.p1_char) ~= FT_RAIN then ok = false; why[#why+1] = "P1 is not Rain" end
    if finish_at == 0 then ok = false; why[#why+1] = "no FINISH HIM window" end
    if fatal_at == 0 then ok = false; why[#why+1] = "the fatality never started" end
    if zap_peak == 0 then ok = false; why[#why+1] = "no bolt ever landed on him" end
    log("pre-strike buzz: %d alternation(s) while rnf_struck was 0%s", prejolt,
        seeded and "  (rnf_bolts seeded to 14)" or "")
    if prejolt > 0 then
        ok = false; why[#why+1] = "he was electrocuting before a bolt landed"
    end
    if split_at == 0 then ok = false; why[#why+1] = "he never came apart" end
    local exploded = inviso_seen and bones_peak >= 10
    log("ending: %s  (legs object %s, victim inviso %s, bone chunks peak %d)",
        exploded and "EXPLODED" or (legs_seen and "SPLIT" or "neither"),
        tostring(legs_seen), tostring(inviso_seen), bones_peak)
    if not legs_seen and not exploded then ok = false; why[#why+1] = "he neither split nor exploded" end
    if legs_seen and final.legs_x and final.torso_x and final.legs_x == final.torso_x then
        ok = false; why[#why+1] = "the halves never separated"
    end
    if final.legs_x then
        log("FINAL legs x=%d y=%d | torso x=%d y=%d | rain x=%d",
            final.legs_x, final.legs_y, final.torso_x, final.torso_y, final.rain_x)
    end
    if SPRITES then
        log("sprite version: %d bolt(s) struck (want 14), fatality %s", bolts_peak,
            done_at > 0 and ("complete at +" .. done_at) or "NEVER completed")
        if bolts_peak ~= 14 then ok = false; why[#why+1] = "not all 14 sprite bolts struck" end
        if done_at == 0 then ok = false; why[#why+1] = "death_blow_complete never ran" end
    elseif base.geo_drew and r16(A.geo_drew) == base.geo_drew then
        ok = false; why[#why+1] = "geo_drew never moved - nothing was CPU-drawn"
    end
    log("jolt peak rnf_zap=%d   blood peak=%d   %d snapshot(s)", zap_peak, blood_peak, snaps)
    if base.geo_drew then
        log("budgets over the fatality: geo drawn +%d dropped +%d | palq_drops +%d | "
            .. "dma late +%d lost +%d | flash_did +%d | peak_overload %d | geo list FULL +%d",
            r16(A.geo_drew) - base.geo_drew, r16(A.geo_dropped) - base.geo_dropped,
            r16(A.palq_drops) - base.palq_drops, r16(A.dmaq_late) - base.dmaq_late,
            r16(A.dmaq_lost) - base.dmaq_lost, r16(A.flash_did) - base.flash_did,
            r16(A.peak_overload), r16(A.geo_full) - base.geo_full)
        if r16(A.geo_full) ~= base.geo_full then
            ok = false; why[#why+1] = "geo_list overflowed - the HUD's own text loses segments"
        end
    end
    log("%s rain lightning fatality on %s%s", ok and "PASS" or "FAIL", VICTIM,
        ok and "" or ("  -- " .. table.concat(why, "; ")))
end

local function finish() done = true; verdict(); manager.machine:exit() end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        if missing then finish(); return end
    end
    frame = frame + 1
    local gs = r16(A.gstate)

    if psel == 0 and gs == GS_PSEL then
        psel = frame
        log("select screen at frame %d", frame)
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)

    elseif confirm == 0 then
        local rel = frame - psel
        if gs == GS_PSEL then
            w16(A.p1_char, FT_SCORPION)         -- his base: forcing 19 here never confirms
            w16(A.p2_char, WANT_P2)
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and rel > 60 then
            confirm = frame
            log("select done at frame %d", frame)
            for n in pairs(fields) do hold(n, false) end
        end

    else
        if gs == GS_POST then                    -- where a hidden fighter takes
            w16(A.p1_char, FT_RAIN)              -- (run_hidden_cheat_test's route)
            w16(A.p2_char, WANT_P2)
        end
        if STAGE and gs == GS_POST then w16(A.curback, STAGE) end

        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d curback=%d", frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback))
            base = { geo_drew = r16(A.geo_drew), geo_dropped = r16(A.geo_dropped),
                     palq_drops = r16(A.palq_drops), dmaq_late = r16(A.dmaq_late), geo_full = r16(A.geo_full),
                     dmaq_lost = r16(A.dmaq_lost), flash_did = r16(A.flash_did) }
        end

        if fight_at > 0 and armed_at == 0 and frame - fight_at == 60 then
            armed_at = frame
            w16(A.p1_matchw, 1)
            w16(A.p2_bar, 1)
            log("armed: p1_matchw=1 p2_bar=1")
        end

        if armed_at > 0 and ko_at == 0 then
            snap_to(60)
            hold("P1 High Punch", (frame % 12) < 5)
            if r16(A.p2_bar) == 0 then
                ko_at = frame; hold("P1 High Punch", false)
                log("KO at frame %d", frame)
            end
        end

        if ko_at > 0 and finish_at == 0 and r16(A.winner_status) == 3 then
            finish_at = frame
            log("FINISH HIM at frame %d", frame)
            if SEED_BOLTS and SPRITES and not seeded then
                seeded = true
                w16(symbols["rnf_bolts"], 14)   -- what the LAST fatality left behind
                log("seeded rnf_bolts=14 (a previous fatality's leftover)")
            end
        end

        if finish_at > 0 and fatal_at == 0 then
            snap_to(FATAL_DIST)
            if combo_at == 0 and frame - finish_at >= 20 then
                combo_at = frame; tries = tries + 1
                log("D,D,B,F + HK (try %d)", tries)
            end
            if combo_at > 0 then
                local c = frame - combo_at
                local want = {}
                for _, step in ipairs(SEQ) do
                    if c >= step[2] and c < step[3] then want[step[1]] = true end
                end
                for _, n in ipairs({ "P1 Down", "P1 Left", "P1 Right", "P1 High Kick" }) do
                    hold(n, want[n] == true)
                end
                if c > 60 and tries < 4 then combo_at = 0 end
            end
            if r16(A.f_death) ~= 0 and r16(A.f_death) ~= 0xffff then
                fatal_at = frame
                for n in pairs(fields) do hold(n, false) end
                log("fatality started at %d (f_death=%04x)", frame, r16(A.f_death))
                snap()
            end
        end

        if fatal_at > 0 then
            local rel = frame - fatal_at
            local z = r16(A.rnf_zap)
            if r16(A.rnf_struck) == 0 then
                local vo = r32(A.p2_obj)
                if vo ~= 0 then
                    local x = s16(r16(vo + O_OXPOS))
                    if pre_x then
                        local dx = x - pre_x
                        if dx ~= 0 and pre_dx and dx == -pre_dx then
                            prejolt = prejolt + 1
                            if prejolt <= 4 then
                                log("  PRE-STRIKE BUZZ +%3d x=%d (struck=0)", rel, x)
                            end
                        end
                        if dx ~= 0 then pre_dx = dx end
                    end
                    pre_x = x
                end
            end
            if z ~= 0 and zap_lines < 24 then
                zap_lines = zap_lines + 1
                log("  ZAP +%3d zap=%2d %s", rel, z, describe("victim", r32(A.p2_obj)))
            end
            zap_peak = math.max(zap_peak, z)
            if SPRITES then
                local b = r16(symbols["rnf_bolts"])
                if b ~= bolts_peak then log("  bolt %d struck at +%d", b, rel) end
                bolts_peak = math.max(bolts_peak, b)
                if done_at == 0 and r16(A.f_death) == 0xffff then
                    done_at = rel
                    log("death_blow_complete at +%d", rel)
                end
            end
            blood_peak = math.max(blood_peak, r16(A.blood_count))
            if SNAP_EVERY > 0 and rel % SNAP_EVERY == 0 and rel <= 420 then snap() end
            if split_at == 0 and rel >= 60 then
                ovl[#ovl+1] = string.format("%d", r16(A.overload))
                if #ovl == 30 then log("  overload +%3d..: %s", rel - 29, table.concat(ovl, " ")); ovl = {} end
            end
            if rel % 6 == 0 and split_at == 0 then
                local ups = {}
                for i = 0, 6 do ups[#ups+1] = string.format("%d", s16(r16(A.rnf_up_state + i * 16))) end
                log("  +%3d leader joints=%2d ups=[%s] struck=%d zap=%2d split=%d", rel,
                    r16(A.rnf_main_n), table.concat(ups, ","), r16(A.rnf_struck),
                    r16(A.rnf_zap), r16(A.rnf_split))
            end
            if split_at == 0 and r16(A.rnf_split) ~= 0 then
                split_at = frame
                log("SPLIT at +%d", rel)
            end
            if split_at > 0 then
                local b = count_bones()
                if b > bones_peak then bones_peak = b end
                local vo = r32(A.p2_obj)
                if vo ~= 0 and (r16(vo + 0x160) & M_INVISO) ~= 0 then inviso_seen = true end
                local lg = find_legs()
                if lg ~= 0 then
                    if not legs_seen then log("legs object at +%d", frame - split_at) end
                    legs_seen = true; legs_obj = lg
                end
                local srel = frame - split_at
                if SNAP_EVERY > 0 and srel % 3 == 0 and srel <= 150 then snap() end
                if srel % 8 == 0 and srel <= 140 then
                    log("  split+%3d %s | %s", srel, describe("torso", r32(A.p2_obj)),
                        describe("legs", legs_obj))
                end
                if srel == 120 then
                    local p2o, p1o = r32(A.p2_obj), r32(A.p1_obj)
                    if legs_obj ~= 0 then
                        final.legs_x = s16(r16(legs_obj + O_OXPOS))
                        final.legs_y = s16(r16(legs_obj + O_OYPOS))
                    end
                    final.torso_x = s16(r16(p2o + O_OXPOS)); final.torso_y = s16(r16(p2o + O_OYPOS))
                    final.rain_x = s16(r16(p1o + O_OXPOS))
                end
                if srel > 150 and (not SPRITES or done_at > 0) then finish() end
            end
            if rel > 1200 then log("the fatality never finished"); finish() end
        end

        if finish_at > 0 and fatal_at == 0 and frame - finish_at > 700 then
            snap(); log("fatality never started"); finish()
        end
        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then
            log("never landed a KO"); finish()
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 16000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
