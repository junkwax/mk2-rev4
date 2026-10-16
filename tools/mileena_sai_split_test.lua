-- mileena_sai_split_test.lua
--
-- Mileena's sai fatality (do_psycho_stab, MKDEATH.ASM; the victim's side is
-- r_stabbed_by_fn2, MKCANNED.ASM).  With saisplit (MAINEQU.ASM) the sais cut
-- him in half at the belt: the legs stay where he stood and buckle to their
-- knees, wobble, and the torso drops off the back of them and lands BEHIND
-- the kneeling legs, drawn behind them.
--
-- P1 = Mileena on the left, P2 = the victim, 2-player game.  FINISH HIM is
-- forced by emptying P2's bar with P1 on match point; the rig then snaps the
-- two inside fatality_xfer_close's 04ch and plays F,B,F + LP (scom_fn2_db,
-- MOVES.ASM fn2_lo_punch).  P1 faces right, so Forward is Right.
--
-- What it proves without pictures (the snapshots are for looking):
--   f_death == 2          the fatality started (init_death_blow a1 = 2)
--   a LEGS object         a non-player object with the victim's ochar and oid
--                         appears once f_death drops to 0ffffh
--   legs z > torso z      the torso (the victim's own object) sorts BEHIND
--   torso lands behind    its final x is on the far side of the legs from
--                         Mileena
--
--   MSS_VICTIM      subzero | kitana | kang | cage | kunglao | jax | baraka |
--                   shang | raiden | scorpion | reptile | mileena (default subzero)
--   MSS_SNAP_EVERY  snapshot every N frames after the split (default 6; 0 = milestones)
--   MSS_LOG         log path

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("MSS_VICTIM") or "subzero"):lower()
local SNAP_EVERY = tonumber(os.getenv("MSS_SNAP_EVERY") or "6") or 6
-- MSS_STAB_SNAP=N: also snapshot every N frames DURING the stabbing, for
-- looking at the blood stream rather than the split.
local STAB_SNAP = tonumber(os.getenv("MSS_STAB_SNAP") or "0") or 0
local LOG    = os.getenv("MSS_LOG") or (ROOT .. "/tools/mileena_sai_split_" .. VICTIM .. ".log")
local READY  = os.getenv("MSS_READY")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[mss/" .. VICTIM .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    raw(line); logfh:write(line, "\n"); logfh:flush()
end

-- ------------------------------------------------------------------ symbols
local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "p1_obj", "p2_obj", "f_death", "ground_y", "objlst",
               "blood_count" }
-- The select-screen START-tap morphs (morph_table, MKSEL.ASM): a Start tap
-- while hovering Sub-Zero/Mileena/Scorpion turns that square into
-- Rain/Jade/Ermac.  This rig taps Start to make P2 join, so it would silently
-- test a DIFFERENT fighter - it read as "P2 is not the requested victim" the
-- day Rain landed.  Cleared every frame of the select.
local CHEATS = { "f_rain_cheat1", "f_rain_cheat2", "f_ermac_cheat1",
                 "f_ermac_cheat2", "f_jade_cheat1", "f_jade_cheat2" }
local A = {}
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end

-- DISPEQU.ASM object offsets, in bits - MAME's program space is bit-addressed.
local O_OXPOS, O_OXVAL, O_OYPOS = 0x090, 0x080, 0x0b0
local O_OZVAL, O_OFLAGS, O_OSIZE = 0x0c0, 0x0f0, 0x120
local O_OCHAR, O_OID = nil, nil
do
    -- ochar / oid move with DISPEQU; read them from the source rather than guess.
    local fh = io.open(ROOT .. "/src/DISPEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(%w+)%s+%.set%s+(%x+)h")
            if n == "ochar" then O_OCHAR = tonumber(v, 16) end
            if n == "oid" then O_OID = tonumber(v, 16) end
        end
        fh:close()
    end
    if not O_OCHAR or not O_OID then log("FATAL: ochar/oid not found in DISPEQU.ASM") end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_FN2 = 5
local VICTIMS = {
    kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
    shang = 6, raiden = 7, subzero = 8, reptile = 9, scorpion = 10, jax = 11,
}
local WANT_P2 = VICTIMS[VICTIM]
if not WANT_P2 then log("FATAL: unknown MSS_VICTIM '%s'", VICTIM); WANT_P2 = 8 end

local FATAL_DIST = 0x40		-- inside fatality_xfer_close's 04ch
-- F, B, F then LP.  combo_look_lr wants the three inside scom_fn2_db's 024h.
local SEQ = { { "P1 Right", 0, 4 }, { "P1 Left", 8, 12 }, { "P1 Right", 16, 20 },
              { "P1 Low Punch", 26, 32 } }

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, combo_at, done = 0, 0, 0, false
local phase, snaps, ready_written = "boot", 0, false
local fatal_at, split_at = 0, 0
local legs_seen, legs_obj = false, 0
local final = {}
local tries = 0
local blood_peak_stab, blood_peak_cut = 0, 0
local flip_seen = false

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1,
                   ["P1 Right"]=1, ["P1 Left"]=1, ["P2 Low Punch"]=1 }
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
    local x1, x2 = r16(p1o + O_OXPOS), r16(p2o + O_OXPOS)
    local mid = (x1 + x2) // 2
    place(p1o, mid - dist // 2)
    place(p2o, mid + dist - dist // 2)
end

local function snap()
    snaps = snaps + 1
    manager.machine.video:snapshot()
end

-- The legs: a live object that is neither player and carries the victim's
-- ochar AND oid (r_sai_split copies both off him, as r_second_swipe does).
local function find_legs()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p2o == 0 then return 0 end
    local ch, id = r16(p2o + O_OCHAR), r16(p2o + O_OID)
    local o, n = r32(A.objlst), 0
    while o ~= 0 and n < 250 do
        if o ~= p1o and o ~= p2o and r16(o + O_OCHAR) == ch and r16(o + O_OID) == id then
            return o
        end
        o = r32(o); n = n + 1
    end
    return 0
end

-- Blood flips, for the drip's mirror.  get_jt_blood copies the VICTIM's flip
-- onto every droplet; swb_drip then XORs it so the art faces along the throw.
-- So a healthy stream shows BOTH flips live at once - all-same means the XOR
-- was lost (or ran before set_proj_vel and reversed the throw instead).
local function blood_flips()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p2o == 0 then return 0, 0, 0 end
    local vflip = r16(p2o + O_OFLAGS) & 0x0010
    local same, opp, o, n = 0, 0, r32(A.objlst), 0
    while o ~= 0 and n < 250 do
        if o ~= p1o and o ~= p2o then
            local w = r16(o + O_OSIZE)
            if w > 0 and w <= 40 then	-- a droplet, not the legs/torso
                if (r16(o + O_OFLAGS) & 0x0010) == vflip then same = same + 1
                else opp = opp + 1 end
            end
        end
        o = r32(o); n = n + 1
    end
    return same, opp, vflip
end

local function describe(tag, o)
    if o == 0 then return tag .. "=none" end
    return string.format("%s x=%d y=%d z=%x fl=%04x size=%dx%d", tag,
        s16(r16(o + O_OXPOS)), s16(r16(o + O_OYPOS)), r32(o + O_OZVAL),
        r16(o + O_OFLAGS), r16(o + O_OSIZE), r16(o + O_OSIZE + 0x10))
end

local function verdict()
    local ok, why = true, {}
    log("p1_char=%d (want %d)  p2_char=%d (want %d)",
        r16(A.p1_char), FT_FN2, r16(A.p2_char), WANT_P2)
    if r16(A.p1_char) ~= FT_FN2 then ok = false; why[#why+1] = "P1 is not Mileena" end
    if r16(A.p2_char) ~= WANT_P2 then ok = false; why[#why+1] = "P2 is not the requested victim" end
    if finish_at == 0 then ok = false; why[#why+1] = "no FINISH HIM window" end
    if fatal_at == 0 then ok = false; why[#why+1] = "the fatality never started" end
    if split_at == 0 then ok = false; why[#why+1] = "the stabbing never finished" end
    if not legs_seen then
        ok = false; why[#why+1] = "no separate legs object"
    elseif final.legs_z and final.torso_z then
        log("FINAL legs x=%d z=%x | torso x=%d z=%x | mileena x=%d",
            final.legs_x, final.legs_z, final.torso_x, final.torso_z, final.mil_x)
        if final.torso_z >= final.legs_z then
            ok = false; why[#why+1] = "torso does not sort behind the legs"
        end
        local away = (final.legs_x - final.mil_x) >= 0 and 1 or -1
        if (final.torso_x - final.legs_x) * away <= 0 then
            ok = false; why[#why+1] = "torso did not land on the far side of the legs"
        end
    end
    if not flip_seen then
        ok = false; why[#why+1] = "no mirrored droplets - swb_drip's flip is gone"
    end
    log("BLOOD peak live droplets: %d while stabbing, %d at the cut (MAX_BLOOD 64)",
        blood_peak_stab, blood_peak_cut)
    log("%d snapshot(s) written", snaps)
    log("%s sai split on %s%s", ok and "PASS" or "FAIL", VICTIM,
        ok and "" or ("  -- " .. table.concat(why, "; ")))
end

local function finish()
    done = true; verdict(); manager.machine:exit()
end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
    end
    frame = frame + 1
    if READY and not ready_written and frame >= 120 then
        local f = io.open(READY, "w"); if f then f:write("ok"); f:close() end
        ready_written = true
    end
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
            w16(A.p1_char, FT_FN2)
            w16(A.p2_char, WANT_P2)
            for _, n in ipairs(CHEATS) do
                if symbols[n] then w16(symbols[n], 0) end
            end
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel == 60 and phase == "boot" then phase = "post" end
        if phase == "post" and rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and phase == "post" then
            confirm = frame
            log("select done at frame %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            for n in pairs(fields) do hold(n, false) end
        end

    else
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
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
                ko_at = frame
                hold("P1 High Punch", false)
                log("KO at frame %d", frame)
            end
        end

        if ko_at > 0 and finish_at == 0 and r16(A.winner_status) == 3 then
            finish_at = frame
            log("FINISH HIM at frame %d", frame)
        end

        if finish_at > 0 and fatal_at == 0 then
            snap_to(FATAL_DIST)
            if combo_at == 0 and frame - finish_at >= 20 then
                combo_at = frame; tries = tries + 1
                log("F,B,F + LP (try %d)", tries)
            end
            if combo_at > 0 then
                local c = frame - combo_at
                local want = {}
                for _, step in ipairs(SEQ) do
                    if c >= step[2] and c < step[3] then want[step[1]] = true end
                end
                for _, n in ipairs({ "P1 Right", "P1 Left", "P1 Low Punch" }) do
                    hold(n, want[n] == true)
                end
                if c > 50 and tries < 3 then combo_at = 0 end	-- try again
            end
            if r16(A.f_death) ~= 0 and r16(A.f_death) ~= 0xffff then
                fatal_at = frame
                for n in pairs(fields) do hold(n, false) end
                log("fatality started (f_death=%04x)", r16(A.f_death))
                snap()
            end
        end

        if fatal_at > 0 and split_at == 0 then
            local rel = frame - fatal_at
            blood_peak_stab = math.max(blood_peak_stab, r16(A.blood_count))
            if rel == 40 or rel == 90 then
                local same, opp, vf = blood_flips()
                log("  +%3d BLOODFLIP victim=%04x  droplets: %d with his flip, %d mirrored",
                    rel, vf, same, opp)
                if opp > 0 then flip_seen = true end
            end
            if STAB_SNAP > 0 then
                if rel % STAB_SNAP == 0 then snap() end
            elseif rel % 20 == 0 then snap() end
            if rel % 10 == 0 then log("  +%3d %s", rel, describe("victim", r32(A.p2_obj))) end
            if r16(A.f_death) == 0xffff then
                split_at = frame
                log("stabbing over at +%d: %s | %s", rel, describe("victim", r32(A.p2_obj)),
                    describe("mileena", r32(A.p1_obj)))
                snap()
            elseif rel > 900 then
                log("the stabbing never finished"); finish()
            end
        end

        if split_at > 0 then
            local rel = frame - split_at
            local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
            if rel <= 40 then blood_peak_cut = math.max(blood_peak_cut, r16(A.blood_count)) end
            local lg = find_legs()
            if lg ~= 0 then
                if not legs_seen then log("legs object appears at +%d", rel) end
                legs_seen = true; legs_obj = lg
            end
            if rel % 6 == 0 and rel <= 200 then
                log("  +%3d %s | %s", rel, describe("torso", p2o), describe("legs", legs_obj))
            end
            if (SNAP_EVERY > 0 and rel <= 200 and rel % SNAP_EVERY == 0) or
               (SNAP_EVERY == 0 and (rel == 10 or rel == 30 or rel == 60 or rel == 100 or rel == 160)) then
                snap()
            end
            if rel == 170 then
                if legs_obj ~= 0 then
                    final.legs_x = s16(r16(legs_obj + O_OXPOS)); final.legs_z = r32(legs_obj + O_OZVAL)
                end
                final.torso_x = s16(r16(p2o + O_OXPOS)); final.torso_z = r32(p2o + O_OZVAL)
                final.mil_x = s16(r16(p1o + O_OXPOS))
            end
            if rel > 180 then finish() end
        end

        if finish_at > 0 and fatal_at == 0 and frame - finish_at > 600 then
            snap(); log("fatality never started"); finish()
        end
        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then
            log("never landed a KO"); finish()
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end

    if frame > 14000 and not done then
        log("timeout phase=%s psel=%d confirm=%d fight=%d ko=%d finish=%d",
            phase, psel, confirm, fight_at, ko_at, finish_at)
        finish()
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
