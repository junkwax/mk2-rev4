-- cage_brain_test.lua
--
-- JOHNNY CAGE'S BRAIN PUNCH (do_jc_headhole, MKDEATH.ASM), per victim:
--
--   LINEUP   on the frame the fatality starts the victim is parked at HIS
--            body's row of jch_place (generated from data/CAGEBRAIN.WAX):
--            victim anchor - Cage's anchor = (reach, drop), facing-proof.
--            The expectation is read out of src/MKDEATH.ASM every run.
--   CHUNKS   at the punch, BPARTS chunks (jc_brain_chunks, MKBLOOD.ASM) fly
--            out of the back of the head - AWAY from Cage only.  Counted as
--            small non-player objects with an x velocity, split by sign.
--   FALL     he jumps back to his own floor (his FINISH HIM y) in ONE frame
--            as he drops to his knees, and lies there.
--
-- P1 = Cage on the left, P2 = the victim, 2-player game; FINISH HIM is forced
-- by emptying P2's bar with P1 on match point, then F,B,B + HP inside 050h.
--
--   CB_VICTIM  kunglao | kang | cage | baraka | kitana | mileena | shang |
--              raiden | subzero | reptile | scorpion | jax
--   CB_LOG     log path
--   CB_SNAP    snapshot every N frames from the punch (default 4; 0 = few)

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("CB_VICTIM") or "kang"):lower()
local LOG    = os.getenv("CB_LOG") or (ROOT .. "/tools/cage_brain_" .. VICTIM .. ".log")
local SNAP_EVERY = tonumber(os.getenv("CB_SNAP") or "4") or 4
local HOLD = tonumber(os.getenv("CB_HOLD") or "0") or 0   -- demo: frames to linger
local SNAP_SPAN = tonumber(os.getenv("CB_SNAPSPAN") or "40") or 40  -- frames after the punch to snap

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[cb/" .. VICTIM .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("CB_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p2_bar", "p1_matchw",
                     "winner_status", "p1_obj", "p2_obj", "f_death", "objlst" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end
local CHEATS = { "f_rain_cheat1", "f_rain_cheat2", "f_ermac_cheat1",
                 "f_ermac_cheat2", "f_jade_cheat1", "f_jade_cheat2" }

-- jch_place rows, by ochar, out of the generated block
local PLACE = {}
do
    local fh = assert(io.open(ROOT .. "/src/MKDEATH.ASM", "r"))
    local inside, n = false, 0
    for line in fh:lines() do
        if line:match("^jch_place") then inside = true
        elseif inside then
            local x, y = line:match("^%s*%.word%s+(%-?%d+),(%-?%d+)")
            if not x then break end
            PLACE[n] = { reach = -tonumber(x), drop = tonumber(y) }; n = n + 1
        end
    end
    fh:close()
    if n ~= 20 then log("FATAL: jch_place has %d rows, not 20", n) end
end

-- SPLASHES: the back GUSHER and the front BIGGERBLUD, told apart by record size
-- (read out of src/MKBLOOD.TBL); SOUNDS: the latch carries the DCS TRACK -
-- 00c1 = MK1 uppercut smack #1, 024b = crowd "ooo" (MKSOUND.ASM), each +0..2
-- for the channel triple_sound lands it on
local SPLASH = {}
do
    local fh = assert(io.open(ROOT .. "/src/MKBLOOD.TBL", "r"))
    local name
    for line in fh:lines() do
        local n = line:match("^([%w_]+):")
        if n then name = n
        elseif name then
            local w, h = line:match("^%s*%.word%s+(%d+),(%d+),")
            if w then
                local fam = name:match("^GUSHER%d+$") and "spray" or name:match("^BIGGERBLUD%d+$") and "burst"
                if fam then SPLASH[w .. "x" .. h] = SPLASH[w .. "x" .. h] or fam end
                name = nil
            end
        end
    end
    fh:close()
end
for _, tbl in ipairs({ "MKFAT2.TBL", "BLDSPLSH.TBL" }) do
    local fh = io.open(ROOT .. "/src/" .. tbl, "r")
    if fh then
        local name
        for line in fh:lines() do
            local n = line:match("^([%w_]+):")
            if n then name = n
            elseif name then
                local w, h = line:match("^%s*%.word%s+(%d+),(%d+),")
                if w then
                    if name:match("^BLDSPLASH%d+$") then SPLASH[w .. "x" .. h] = "entry" end
                    name = nil
                end
            end
        end
        fh:close()
    end
end
local SND_PORT, SND_LO, SND_HI = 0x01d01030, 0x01d00000, 0x01d01fff
local snd_hi, snd_tap, sounds = nil, nil, {}
local O_OXVEL, O_OXPOS, O_OYPOS = 0x040, 0x090, 0x0b0
local O_OFLAGS, O_OSIZEX, O_OCHAR = 0x0f0, 0x120, 0x1f0

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_CAGE = 2
local VICTIMS = { kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
                  shang = 6, raiden = 7, subzero = 8, reptile = 9, scorpion = 10, jax = 11 }
local WANT_P2 = VICTIMS[VICTIM]
if not WANT_P2 then log("FATAL: unknown CB_VICTIM '%s'", VICTIM); WANT_P2 = 1 end

local FATAL_DIST = 0x40
local SEQ = { { "P1 Right", 0, 4 }, { "P1 Left", 8, 12 }, { "P1 Left", 16, 20 },
              { "P1 High Punch", 26, 32 } }

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, combo_at, fatal_at, tries = 0, 0, 0, 0, 0
local phase, done, snaps = "boot", false, 0
local lineup, stand_y, final_y = nil, nil, nil
local away_max, toward_max, first_chunk = 0, 0, 0
-- SHAKE: on the fist he jolts 2px (jch_shake_px) for 48 ticks, then is back
local shake_lo, shake_hi, line_x, final_x = nil, nil, nil, nil
local pre, ylo = nil, nil
local last_y, mid_frames, jumped = nil, 0, false   -- the jump off the fist

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1, ["P1 Right"]=1,
                   ["P1 Left"]=1, ["P2 Low Punch"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x); w32(obj + 0x80, (x << 16) & 0xffffffff)
end
local function snap_to(dist)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local x1, x2 = r16(p1o + O_OXPOS), r16(p2o + O_OXPOS)
    local mid = (x1 + x2) // 2
    place(p1o, mid - dist // 2); place(p2o, mid + dist - dist // 2)
end
local function snap() snaps = snaps + 1; manager.machine.video:snapshot() end

-- chunks: small non-player objects with an x velocity, split by which way
local function chunks()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local away_sign = (s16(r16(p2o + O_OXPOS)) >= s16(r16(p1o + O_OXPOS))) and 1 or -1
    local away, toward, o, n = 0, 0, r32(A.objlst), 0
    while o ~= 0 and n < 300 do
        if o ~= p1o and o ~= p2o and r16(o + O_OSIZEX) <= 16 then
            local vx = s32(r32(o + O_OXVEL))
            if vx ~= 0 then
                if (vx > 0 and 1 or -1) == away_sign then away = away + 1 else toward = toward + 1 end
            end
        end
        o = r32(o); n = n + 1
    end
    return away, toward
end

local function on_sound(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    local code = (snd_hi << 8) | (w & 0xff); snd_hi = nil
    if fatal_at > 0 then sounds[#sounds+1] = { code = code, rel = frame - fatal_at } end
    return data
end

local spray_seen, burst_seen, entry_seen = nil, nil, nil   -- {x} of the first one seen
local function splashes()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local o, n = r32(A.objlst), 0
    while o ~= 0 and n < 300 do
        if o ~= p1o and o ~= p2o and s32(r32(o + O_OXVEL)) == 0 then
            local fam = SPLASH[r16(o + O_OSIZEX) .. "x" .. r16(o + O_OSIZEX + 0x10)]
            if fam == "spray" and not spray_seen then spray_seen = { x = s16(r16(o + O_OXPOS)), w = r16(o + O_OSIZEX) } end
            if fam == "burst" and not burst_seen then burst_seen = { x = s16(r16(o + O_OXPOS)), w = r16(o + O_OSIZEX) } end
            if fam == "entry" and not entry_seen then entry_seen = { x = s16(r16(o + O_OXPOS)), w = r16(o + O_OSIZEX) } end
        end
        o = r32(o); n = n + 1
    end
end

local function verdict()
    local ok, why = true, {}
    if r16(A.p1_char) ~= FT_CAGE then ok = false; why[#why+1] = "P1 is not Cage" end
    if r16(A.p2_char) ~= WANT_P2 then ok = false; why[#why+1] = "P2 is not the requested victim" end
    if fatal_at == 0 then ok = false; why[#why+1] = "the fatality never started" end
    local want = PLACE[WANT_P2]
    if lineup and want then
        log("LINEUP reach=%d drop=%d  (jch_place wants %d,%d)", lineup.reach, lineup.drop,
            want.reach, want.drop)
        if lineup.reach ~= want.reach or lineup.drop ~= want.drop then
            ok = false; why[#why+1] = "victim not on his jch_place row"
        end
    elseif fatal_at > 0 then ok = false; why[#why+1] = "no lineup sample" end
    log("CHUNKS away=%d toward=%d (first at +%d)", away_max, toward_max,
        first_chunk > 0 and first_chunk - fatal_at or -1)
    if away_max == 0 then ok = false; why[#why+1] = "no chunks flew backwards" end
    if toward_max > 0 then ok = false; why[#why+1] = "chunks flew towards Cage" end
    log("FALL on the fist at y=%s, ended at y=%s (FINISH HIM y=%s); one-frame jump=%s, frames in between=%d",
        tostring(ylo), tostring(final_y), tostring(stand_y), tostring(jumped), mid_frames)
    if not stand_y or final_y ~= stand_y then ok = false; why[#why+1] = "not back on his own floor" end
    if ylo ~= stand_y and not jumped then ok = false; why[#why+1] = "never saw the jump off the fist" end
    if mid_frames > 0 then ok = false; why[#why+1] = "eased back to the floor instead of one jump" end
    log("SHAKE x swung %s..%s on the fist; lined up at %s, ended at %s",
        tostring(shake_lo), tostring(shake_hi), tostring(line_x), tostring(final_x))
    if not shake_lo or shake_hi - shake_lo ~= 2 then ok = false; why[#why+1] = "no 2px shake on the fist" end
    if final_x ~= line_x then ok = false; why[#why+1] = "the shake did not leave him where it found him" end
    if not pre or pre.moved == nil then ok = false; why[#why+1] = "no windup sample"
    elseif pre.moved then ok = false; why[#why+1] = "he moved BEFORE the punch" end
    local smack, ooo = nil, nil
    for _, e in ipairs(sounds) do
        -- triple_sound adds the CHANNEL it lands on (0-2) to the track
        if e.code >= 0x00c1 and e.code <= 0x00c3 and not smack then smack = e.rel end
        if e.code >= 0x024b and e.code <= 0x024d and not ooo then ooo = e.rel end
    end
    local list = {}
    for _, e in ipairs(sounds) do if e.rel <= 120 then list[#list+1] = string.format("%04x@%d", e.code, e.rel) end end
    log("SOUND uppercut smack 00c1-3 at %s, crowd ooo 024b-d at %s  [%s]", tostring(smack), tostring(ooo),
        table.concat(list, " "))
    if not smack then ok = false; why[#why+1] = "no uppercut smack" end
    if not ooo or not smack or ooo - smack < 10 or ooo - smack > 24 then
        ok = false; why[#why+1] = "no crowd ooo ~16 ticks after the smack" end
    -- the spray goes out the BACK (further from Cage), the burst out the FRONT
    local cx = s16(r16(r32(A.p1_obj) + O_OXPOS))
    local function mid(t) return t and (t.x + t.w // 2) end
    log("SPLASH spray mid x=%s, burst mid x=%s, bldsplash mid x=%s, cage x=%d", tostring(mid(spray_seen)),
        tostring(mid(burst_seen)), tostring(mid(entry_seen)), cx)
    if not entry_seen then ok = false; why[#why+1] = "no BLDSPLASH at the entry"
    elseif spray_seen and math.abs(mid(entry_seen) - cx) >= math.abs(mid(spray_seen) - cx) then
        ok = false; why[#why+1] = "BLDSPLASH is not in front of the back spray" end
    if not spray_seen then ok = false; why[#why+1] = "no back spray" end
    if not burst_seen then ok = false; why[#why+1] = "no front burst" end
    if spray_seen and burst_seen and math.abs(mid(spray_seen) - cx) <= math.abs(mid(burst_seen) - cx) then
        ok = false; why[#why+1] = "spray is not behind the burst" end
    log("%d snapshot(s)", snaps)
    log("%s brain punch on %s%s", ok and "PASS" or "FAIL", VICTIM,
        ok and "" or ("  -- " .. table.concat(why, "; ")))
end
local exit_at = nil
local function finish()
    done = true; verdict()
    if HOLD > 0 then exit_at = frame + HOLD else manager.machine:exit() end
end

emu.register_frame_done(function()
    if done then
        frame = frame + 1
        if exit_at and frame >= exit_at then exit_at = nil; manager.machine:exit() end
        return
    end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]; cache_inputs()
        local okt, err = pcall(function() snd_tap = space:install_write_tap(SND_LO, SND_HI, "cb_snd", on_sound) end)
        if not okt then log("sound tap FAILED: %s", tostring(err)) end
    end
    frame = frame + 1
    local gs = r16(A.gstate)

    if psel == 0 and gs == GS_PSEL then
        psel = frame; log("select screen at frame %d", frame)
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
            w16(A.p1_char, FT_CAGE); w16(A.p2_char, WANT_P2)
            for _, n in ipairs(CHEATS) do if symbols[n] then w16(symbols[n], 0) end end
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel == 60 and phase == "boot" then phase = "post" end
        if phase == "post" and rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and phase == "post" then
            confirm = frame
            log("select done: p1_char=%d p2_char=%d", r16(A.p1_char), r16(A.p2_char))
            for n in pairs(fields) do hold(n, false) end
        end
    else
        if gs == GS_FIGHTING and fight_at == 0 then fight_at = frame end
        if fight_at > 0 and armed_at == 0 and frame - fight_at == 60 then
            armed_at = frame; w16(A.p1_matchw, 1); w16(A.p2_bar, 1)
        end
        if armed_at > 0 and ko_at == 0 then
            snap_to(60); hold("P1 High Punch", (frame % 12) < 5)
            if r16(A.p2_bar) == 0 then ko_at = frame; hold("P1 High Punch", false) end
        end
        if ko_at > 0 and finish_at == 0 and r16(A.winner_status) == 3 then
            finish_at = frame; log("FINISH HIM at frame %d", frame)
        end

        if finish_at > 0 and fatal_at == 0 then
            -- only until the HP press: f_death is raised AFTER do_jc_headhole has
            -- lined him up, so snapping until it appears overwrites the lineup's x;
            -- stopping at the start of the motion instead lets the walk of F,B,B
            -- carry them out of 050h
            if combo_at == 0 or frame - combo_at < 26 then snap_to(FATAL_DIST) end
            -- standing dizzy: the floor height he must come back to
            if frame - finish_at == 15 then stand_y = s16(r16(r32(A.p2_obj) + O_OYPOS)) end
            if combo_at == 0 and frame - finish_at >= 20 then
                combo_at = frame; tries = tries + 1; log("F,B,B + HP (try %d)", tries)
            end
            if combo_at > 0 then
                local c, want = frame - combo_at, {}
                for _, st in ipairs(SEQ) do if c >= st[2] and c < st[3] then want[st[1]] = true end end
                for _, n in ipairs({ "P1 Right", "P1 Left", "P1 High Punch" }) do hold(n, want[n] == true) end
                if c > 50 and tries < 3 then combo_at = 0 end
            end
            local fd = r16(A.f_death)
            if fd ~= 0 and fd ~= 0xffff then
                fatal_at = frame
                for n in pairs(fields) do hold(n, false) end
                log("fatality started (f_death=%04x)", fd)
            end
            if frame - finish_at > 600 then log("fatality never started"); finish() end
        end

        if fatal_at > 0 then
            local rel = frame - fatal_at
            local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
            local vx, vy = s16(r16(p2o + O_OXPOS)), s16(r16(p2o + O_OYPOS))
            local cx, cy = s16(r16(p1o + O_OXPOS)), s16(r16(p1o + O_OYPOS))
            local face = (r16(p1o + O_OFLAGS) & 0x0010) ~= 0 and -1 or 1
            -- WINDUP: he is lined up ON THE PUNCH now, so through the windup he
            -- must still stand where FINISH HIM left him - same x, own floor y
            if rel == 15 then pre = { x = vx, y = vy, reach = (vx - cx) * face } end
            if rel == 35 and pre then
                pre.moved = (vx ~= pre.x) or (vy ~= pre.y) or (vy ~= stand_y)
                log("WINDUP reach=%d y=%d at +15, x=%d y=%d at +35 (FINISH HIM y=%s)",
                    pre.reach, pre.y, vx, vy, tostring(stand_y))
            end
            -- ON THE FIST: from the punch (first chunk) for the 48-tick shake;
            -- the shake only ADDS 2px, so the low end of the window is the lineup
            if first_chunk > 0 and frame - first_chunk <= 45 then
                shake_lo = math.min(shake_lo or vx, vx); shake_hi = math.max(shake_hi or vx, vx)
                ylo = math.min(ylo or vy, vy)
                line_x = shake_lo
                lineup = { reach = (shake_lo - cx) * face, drop = ylo - cy }
            end
            -- the jump off the fist: from the shake's end, y must go from the
            -- fist's height (ylo, or ylo+2 on the shake's down half) straight
            -- to his floor - any other y in between means it was eased
            if ylo and stand_y and first_chunk > 0 and frame - first_chunk > 40 and last_y then
                local onfist = (vy == ylo or vy == ylo + 2)
                if not onfist and vy ~= stand_y then mid_frames = mid_frames + 1 end
                if vy == stand_y and (last_y == ylo or last_y == ylo + 2) then jumped = true end
            end
            last_y = vy
            if rel >= 35 and rel <= 70 then splashes() end
            local a, t = chunks()
            if a + t > 0 and first_chunk == 0 then first_chunk = frame; snap() end
            away_max = math.max(away_max, a); toward_max = math.max(toward_max, t)
            if first_chunk > 0 and SNAP_EVERY > 0 and frame - first_chunk <= SNAP_SPAN and
               (frame - first_chunk) % SNAP_EVERY == 0 then snap() end
            if rel <= 50 then
                log("  +%3d cage x=%d fl=%04x  victim x=%d y=%d fl=%04x", rel,
                    s16(r16(p1o + O_OXPOS)), r16(p1o + O_OFLAGS),
                    s16(r16(p2o + O_OXPOS)), s16(r16(p2o + O_OYPOS)), r16(p2o + O_OFLAGS))
            end
            if rel % 20 == 0 then
                log("  +%3d victim y=%d chunks away=%d toward=%d", rel,
                    s16(r16(p2o + O_OYPOS)), a, t)
            end
            if rel == 330 then
                final_y = s16(r16(p2o + O_OYPOS)); final_x = vx; snap(); finish()
            end
        end
        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then log("never landed a KO"); finish() end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 14000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
