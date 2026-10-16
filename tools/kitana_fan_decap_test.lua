-- kitana_fan_decap_test.lua
--
-- KITANA'S FAN DECAPITATION, the two-slice version (fandecap2, MAINEQU.ASM;
-- do_fan_decap, MKDEATH.ASM).  FANSWIPESQ - the sequence Midway authored into
-- data/KAT9.IMG - swings the fan OUT and BACK:
--
--     KTFANSWIPE1 2 3 4 5 6[15] 5 4 3 2 1
--
-- Retail's lane stops at the top of the swing, so the blade crosses him once.
-- Here the first pass CUTS him (r_first_swipe: blood, a grunt, a stumble) and
-- the SECOND pass, on the way back, takes the head.
--
-- P1 = Kitana on the left, P2 = the victim, 2-player game.  FINISH HIM is
-- forced by emptying P2's bar with P1 on match point; the rig then snaps the
-- two inside fn1_hi_kick's 048h and plays Block, Block, Block + High Kick
-- (bcom_fn1_db2, MOVES.ASM).  Not facing-dependent.
--
-- WHAT IT PROVES, and why it is measured this way:
--
--   * Kitana's DRAWN FRAME is read every tick, off her object's osize, and
--     matched against the KTFANSWIPEnA records in src/MKFN.TBL - so the rig
--     reads the same geometry the build ships and cannot pass against a
--     stale constant.  Every (w,h) in that set is unique, which is what
--     makes the frame identifiable at all.
--   * The RETURN half is the whole point, so it is asserted as an ordered
--     run: the outward 1..6, the top held, then 5,4,3,2,1.  A retail lane
--     stops after 6 and fails here with "the fan never came back".
--   * The head (oid_head) must appear AFTER the return starts.  That is the
--     two-slice claim: if the head came off on the way out, this ROM is
--     retail's timing wearing the new animation.
--   * The victim must already be reacting BEFORE the head appears - his
--     drawn frame has to change at least once between the fatality starting
--     and the decapitation.  Without that, the first pass did nothing and
--     the "first slice" is a comment rather than a beat.
--
--   KFD_VICTIM      subzero | kitana | kang | cage | kunglao | jax | baraka |
--                   shang | raiden | scorpion | reptile | mileena (default subzero)
--   KFD_SNAP_EVERY  snapshot every N frames of the fatality (default 6; 0 = off)
--   KFD_LOG         log path

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("KFD_VICTIM") or "subzero"):lower()
local SNAP_EVERY = tonumber(os.getenv("KFD_SNAP_EVERY") or "6") or 6
local LOG    = os.getenv("KFD_LOG") or (ROOT .. "/tools/kitana_fan_decap_" .. VICTIM .. ".log")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[kfd/" .. VICTIM .. "] " ..
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
               "winner_status", "p1_obj", "p2_obj", "f_death", "objlst", "blood_count",
               "active" }
-- The select-screen START-tap morphs (morph_table, MKSEL.ASM) turn
-- Sub-Zero/Mileena/Scorpion into Rain/Jade/Ermac, and this rig taps Start to
-- make P2 join - so the cheats are cleared every frame of the select or the
-- run silently tests a different fighter.
local CHEATS = { "f_rain_cheat1", "f_rain_cheat2", "f_ermac_cheat1",
                 "f_ermac_cheat2", "f_jade_cheat1", "f_jade_cheat2" }
local A = {}
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end

-- DISPEQU.ASM object offsets, in bits - MAME's program space is bit-addressed.
local O_OXPOS, O_OXVAL, O_OYPOS = 0x090, 0x080, 0x0b0
local O_OSAG, O_OSIZEX, O_OSIZEY = 0x100, 0x120, 0x130
local O_OPAL, O_OIMG, O_OSHAPE = 0x140, 0x1a0, 0x1d0
-- A FIGHTER IS A MULTIPART OBJECT and its own oxxx size fields are 0: the
-- pieces live in the process's shape RAM at *obj(oimg), as 112-bit nodes
-- (mp_sag/mp_sizex/mp_sizey/mp_control/mp_anix/mp_aniy, DISPEQU.ASM), and
-- they are NOT on objlst.  Reading osize off the player object is what the
-- first cut of this rig did and it reported 0x0 every tick.
local MP_SAG, MP_SIZEX, MP_SIZEY = 0x00, 0x20, 0x30
-- process block: plink at 0, procid at 20h, pa8 at 0c0h (MAINEQU.ASM)
local P_PROCID, P_A8 = 0x20, 0xc0
local PID_HEAD = 0x0202		-- pid_head, MAINEQU.ASM
local O_OCHAR, O_OID
do
    -- ochar / oid move with DISPEQU; read them rather than guess.
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

-- Kitana's swing frames, BY SIZE, read out of the shipped table.  A piece
-- record is `NAME:` then `.word w,h,ax,ay`, and the object carries the FIRST
-- piece of each frame (KTFANSWIPEnA), so that is what identifies the frame.
local FRAME_OF = {}
do
    local fh = assert(io.open(ROOT .. "/src/MKFN.TBL", "r"))
    local pending
    for line in fh:lines() do
        local n = line:match("^KTFANSWIPE(%d)A:")
        if n then
            pending = tonumber(n)
        elseif pending then
            local w, h = line:match("^%s+%.word%s+(%-?%d+),(%-?%d+),")
            if w then
                FRAME_OF[tonumber(w) .. "x" .. tonumber(h)] = pending
                pending = nil
            end
        end
    end
    fh:close()
end
do
    local n = 0
    local seen = {}
    for k, v in pairs(FRAME_OF) do
        n = n + 1
        if seen[v] then log("FATAL: KTFANSWIPE%dA size %s is not unique", v, k) end
        seen[v] = k
    end
    if n ~= 6 then log("FATAL: found %d KTFANSWIPEnA records in MKFN.TBL, want 6", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_FN1 = 4
local VICTIMS = {
    kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
    shang = 6, raiden = 7, subzero = 8, reptile = 9, scorpion = 10, jax = 11,
}
local WANT_P2 = VICTIMS[VICTIM]
if not WANT_P2 then log("FATAL: unknown KFD_VICTIM '%s'", VICTIM); WANT_P2 = 8 end

local FATAL_DIST = 0x40		-- inside fn1_hi_kick's 048h
-- Block, Block, Block then High Kick, all inside bcom_fn1_db2's 030h window.
local SEQ = { { "P1 Block", 0, 4 }, { "P1 Block", 8, 12 }, { "P1 Block", 16, 20 },
              { "P1 High Kick", 26, 32 } }

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
local phase, snaps = "boot", 0
local fatal_at, tries = 0, 0
local lane = {}			-- [{frame index, swing frame}] in order seen
local last_frame_n = nil
local vic_sizes, vic_changes = nil, 0
local head_at, head_lane_at = 0, nil
local blood_peak = 0
local top_hold = 0
local vic_pal0, vic_pal_at = nil, 0

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1, ["P1 Block"]=1,
                   ["P1 High Kick"]=1, ["P2 Low Punch"]=1 }
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

-- The first piece of the frame a multipart object is currently drawing.
local function piece_a(obj)
    if obj == 0 then return nil end
    -- a SINGLE-part object carries its own size and its oimg is an image
    -- record, not a shape-RAM node: reading mp fields off it is nonsense.
    if r16(obj + O_OSIZEX) ~= 0 then return nil end
    local mp = r32(obj + O_OIMG)
    if mp == 0 then return nil end
    return r16(mp + MP_SIZEX) .. "x" .. r16(mp + MP_SIZEY), r32(mp + MP_SAG)
end

local function swing_frame()
    local key = piece_a(r32(A.p1_obj))
    return key and FRAME_OF[key] or nil
end

-- The detached head, found by its PROCESS: decap_fall does
-- `create pid_head,decapped_head`, so the active list carries a process whose
-- procid is pid_head and pa8 is the head object.
--
-- MATCHING ON THE OBJECT DOES NOT WORK.  decapped_head copies the victim's
-- OCHAR onto its object and never writes an oid (getobj zeroes a fresh block),
-- so ochar looks like the handle - and it is, for eleven of the twelve
-- victims.  KUNG LAO IS OCHAR 0, which every object that never set one also
-- reads as, so the ochar walk matched a stray object on the fatality's very
-- first tick and reported the head off before the swing had started.  The
-- sai-split legs ARE found by oid, because r_sai_split copies that too; the
-- two detectors are not interchangeable.
local function find_head()
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 200 do
        if r16(p + P_PROCID) == PID_HEAD then return r32(p + P_A8) end
        p = r32(p); n = n + 1
    end
    return 0
end

local function describe(tag, o)
    if o == 0 then return tag .. "=none" end
    local key, sag = piece_a(o)
    return string.format("%s x=%d y=%d piece=%s sag=%08x pal=%04x", tag,
        s16(r16(o + O_OXPOS)), s16(r16(o + O_OYPOS)),
        key or (r16(o + O_OSIZEX) .. "x" .. r16(o + O_OSIZEY)),
        sag or r32(o + O_OSAG), r16(o + O_OPAL))
end

-- The run of swing frames, collapsed to the order they were first drawn in.
local function lane_order()
    local out = {}
    for _, e in ipairs(lane) do
        if out[#out] ~= e[2] then out[#out + 1] = e[2] end
    end
    return out
end

local function verdict()
    local ok, why = true, {}
    local order = lane_order()
    log("p1_char=%d (want %d)  p2_char=%d (want %d)",
        r16(A.p1_char), FT_FN1, r16(A.p2_char), WANT_P2)
    if r16(A.p1_char) ~= FT_FN1 then ok = false; why[#why+1] = "P1 is not Kitana" end
    if r16(A.p2_char) ~= WANT_P2 then ok = false; why[#why+1] = "P2 is not the requested victim" end
    if finish_at == 0 then ok = false; why[#why+1] = "no FINISH HIM window" end
    if fatal_at == 0 then ok = false; why[#why+1] = "the fatality never started" end

    log("LANE %s", table.concat(order, ","))
    log("TOP  KTFANSWIPE6 drawn for %d ticks (authored 15 preview ticks x4 = 60)", top_hold)

    -- the out-and-back, as an ordered run
    local want = { 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1 }
    local i = 1
    for _, f in ipairs(order) do
        if i <= #want and f == want[i] then i = i + 1 end
    end
    local out_done, back_done = math.min(i - 1, 6), math.max(i - 1 - 6, 0)
    if out_done < 6 then
        ok = false
        why[#why+1] = string.format("the swing out stopped at KTFANSWIPE%d", out_done)
    elseif back_done < 5 then
        ok = false
        why[#why+1] = string.format("the fan never came back (%d of 5 return frames)", back_done)
    end

    -- which pass took the head
    local return_at = nil		-- ticks since the fatality started
    for _, e in ipairs(lane) do
        if e[3] then return_at = return_at or e[1] end
    end
    local head_rel = head_at > 0 and (head_at - fatal_at) or nil
    if head_at == 0 then
        ok = false; why[#why+1] = "the head never came off"
    else
        log("HEAD off at fatality tick +%d, on KTFANSWIPE%s (return began +%s)",
            head_rel, tostring(head_lane_at), tostring(return_at))
        if not return_at then
            ok = false; why[#why+1] = "the return half never played"
        elseif head_rel < return_at then
            ok = false
            why[#why+1] = "the head came off on the way OUT - this is retail's single slice"
        end
    end

    -- the first slice has to have done something before the second one
    log("VICTIM drew %d different frames before the head came off; repalette at +%s",
        vic_changes, vic_pal_at > 0 and (vic_pal_at - fatal_at) or "never")
    if vic_changes < 1 then
        ok = false; why[#why+1] = "the victim never reacted to the first slice"
    end

    log("BLOOD peak live droplets: %d (MAX_BLOOD 64)", blood_peak)
    log("%d snapshot(s) written", snaps)
    log("%s two-slice fan decap on %s%s", ok and "PASS" or "FAIL", VICTIM,
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
            w16(A.p1_char, FT_FN1)
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
                log("Block,Block,Block + High Kick (try %d)", tries)
            end
            if combo_at > 0 then
                local c = frame - combo_at
                local want = {}
                for _, step in ipairs(SEQ) do
                    if c >= step[2] and c < step[3] then want[step[1]] = true end
                end
                for _, n in ipairs({ "P1 Block", "P1 High Kick" }) do
                    hold(n, want[n] == true)
                end
                if c > 50 and tries < 4 then combo_at = 0 end	-- try again
            end
            if r16(A.f_death) ~= 0 and r16(A.f_death) ~= 0xffff then
                fatal_at = frame
                for n in pairs(fields) do hold(n, false) end
                log("fatality started at frame %d (f_death=%04x)", frame, r16(A.f_death))
                vic_sizes = {}
                local k = piece_a(r32(A.p2_obj))
                if k then vic_sizes[k] = true end
                vic_pal0 = r16(r32(A.p2_obj) + O_OPAL)
                snap()
            end
        end

        if fatal_at > 0 then
            local rel = frame - fatal_at
            blood_peak = math.max(blood_peak, r16(A.blood_count))

            local sf = swing_frame()
            if sf then
                if sf == 6 then top_hold = top_hold + 1 end
                if sf ~= last_frame_n then
                    -- a RETURN frame is one drawn after the top of the swing
                    local past_top = false
                    for _, e in ipairs(lane) do if e[2] == 6 then past_top = true end end
                    lane[#lane + 1] = { rel, sf, past_top and sf ~= 6 }
                    log("  +%3d KTFANSWIPE%d%s", rel, sf, (past_top and sf ~= 6) and "  (coming back)" or "")
                    last_frame_n = sf
                end
            end

            if head_at == 0 then
                local p2o = r32(A.p2_obj)
                if p2o ~= 0 and vic_sizes then
                    local k = piece_a(p2o)
                    if k and not vic_sizes[k] then vic_sizes[k] = true; vic_changes = vic_changes + 1 end
                    -- decap_fall -> tongued_fall calls change_to_bloody_pal;
                    -- r_first_swipe does not, so the palette moving IS the
                    -- decapitation and not the first slice's stumble.
                    if vic_pal_at == 0 and r16(p2o + O_OPAL) ~= vic_pal0 then
                        vic_pal_at = frame
                        log("  +%3d victim repalette (bloody) - the killing slice", rel)
                    end
                end
                local h = find_head()
                if h ~= 0 then
                    head_at = frame
                    head_lane_at = last_frame_n
                    log("  +%3d HEAD OFF: %s", rel, describe("head", h))
                    snap()
                end
            end

            if SNAP_EVERY > 0 and rel % SNAP_EVERY == 0 and rel <= 200 then snap() end
            if rel == 210 then
                log("  +%3d %s | %s", rel, describe("kitana", r32(A.p1_obj)),
                    describe("victim", r32(A.p2_obj)))
                finish()
            end
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
