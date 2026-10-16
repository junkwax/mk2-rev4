-- scorpion_scortch_mk1_test.lua
--
-- End-to-end MAME harness for Scorpion's MK1 "toasty" scortch fatality
-- (db1_table[10] -> do_scortch -> scorpion_flame in MKFX.ASM).
--
-- What the rebuilt sequence is supposed to do:
--   scorpfire1-4      stock MK2 spit lead-in
--   MK1FIRE1-6        MK1 flame column, drawn OVER the victim (front_z+1)
--   MK1SKEL1          replaces the victim on MK1FIRE2, behind the flame,
--                     and holds for 10 ticks
--   MK1SKEL2-8        skeleton collapses; MK1SKEL8 is held
--
-- Modeled on st_decap_fatality_test.lua: symbols come from the freshly
-- built linker map, objects are matched back to authored frame labels via
-- the source TBL SAGs, and the run only shortcuts selection and the
-- victim's Finish Him reaction so a genuine in-fight Finish Him is reached.
--
-- Input, as shipped (MOVES.ASM sc_hi_punch, remapped 2026-07-31):
--   bare HP during Finish Him -> MK1 burn   (p_store6 = 0, this test)
--   D,D,U,U + HP              -> stock MK2 burn + TOASTY (SCORTCH_TOASTY=1)
-- The bare HP only burns from sweep distance: sc_scortch_min..max
-- (0x80..0xC0, 128..192px, MOVES.ASM) - retail's U,U + HP gate was
-- 0x90..0xB0.  P1 is snapped to 160px, inside it.  NOTE this rig force-wakes
-- do_fatality_1 (SCORTCH_FORCE_WAKE), so it does not test the gate.
-- Do NOT prepend stick motion to the MK1 script - Up,Up now
-- just makes Scorpion jump and the HP lands as an air punch.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("SCORTCH_LOG") or (ROOT .. "/tools/scorpion_scortch_mk1_test.log")
local FRAME_LOG_PATH = os.getenv("SCORTCH_FRAME_LOG")
    or (ROOT .. "/tools/scorpion_scortch_mk1_frames.csv")
local CAPTURE_UNTIL = getenv_int("SCORTCH_CAPTURE_UNTIL", 200)
local PASS_REL = getenv_int("SCORTCH_PASS_REL", 320)
local STAGE_ID = getenv_int("SCORTCH_STAGE", 5)
local FATAL_X = getenv_int("SCORTCH_FATAL_X", 160) -- inside sc_scortch_min..max
-- Which side Scorpion stands on.  "left" is the historical run (victim on the
-- right, so the victim is h-flipped); "right" mirrors it so the victim faces
-- the other way.  The MK1 flame/skeleton nudges are anchor-relative and must
-- mirror with the facing, so both sides have to be measured.
local SIDE = (os.getenv("SCORTCH_SIDE") or "left"):lower()

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(FRAME_LOG_PATH, "w")
if csvfh then
    csvfh:write("capture_index,emu_frame,fatality_rel,f_death,fire_frames,skel_frames,fire_z,skel_z,p1_x,p2_x\n")
    csvfh:flush()
end

local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[scortch] " .. msg)
end

local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

-- Resolve symbols from the freshly built linker map.
local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if not fh then
        map_path = ROOT .. "/src/MK2.MAP"
        fh = io.open(map_path, "r")
    end
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
        log("loaded symbols from %s", map_path)
    else
        log("WARN no linker map found; using address fallbacks")
    end
end

local function sym(name, fallback)
    local value = symbols[name]
    if value ~= nil then return value end
    log("WARN missing symbol %s; fallback=%s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    active        = sym("active", 0x010dc6d0),
    gstate        = sym("gstate", 0x0112a7f0),
    p1_state      = sym("p1_state", 0x0112a810),
    p2_state      = sym("p2_state", 0x0112b3e0),
    p1_char       = sym("p1_char", 0x0112a8a0),
    p2_char       = sym("p2_char", 0x0112b470),
    p1_obj        = sym("p1_obj", 0x0112a840),
    p2_obj        = sym("p2_obj", 0x0112b410),
    p1_proc       = sym("p1_proc", 0x0112a860),
    p2_proc       = sym("p2_proc", 0x0112b430),
    round_num     = sym("round_num", 0x0112c120),
    curback       = sym("curback", 0x0112c0f0),
    winner_status = sym("winner_status", 0x0112c130),
    f_death       = sym("f_death", 0x0112bfe0),
    pf_ram        = sym("pf_ram", 0x0112c0b0),
    objlst        = sym("objlst", 0x01127570),
    objlst2       = sym("objlst2", 0x01127590),
    objlst3       = sym("objlst3", 0x011275b0),
    do_fatality_1 = sym("do_fatality_1", 0),
    dizzy_dude    = sym("dizzy_dude", 0xffa27af0),
    dizzy         = sym("dizzy", 0xffa27e40),
    system_lockup = sym("system_lockup", 0xffa74d60),
    tvbp          = sym("TVBP", 0xffa74f70),
    blood_count   = sym("blood_count", 0),
}
-- getprc denies every pid_blood allocation once blood_count hits MAX_BLOOD
-- (MPROC.ASM). sucide decrements it; kilall/murder do NOT - so watch whether
-- it ever comes back down across a round.
local blood_peak, blood_last = 0, -1

-- Drawn span of the victim's own body, sampled every frame until takeover_him
-- replaces him with the skeleton. This is the reference the whole effect is
-- supposed to land on: "does the fire cover him, and do the bones come up
-- where he was standing" is victim_c vs fire_c/skel_c, nothing else.
local victim_last = nil

local O = {
    next = 0x000, oxvel = 0x040, oyvel = 0x060, oxval = 0x080,
    oxpos = 0x090, oyval = 0x0a0, oypos = 0x0b0, ozval = 0x0c0,
    oflags = 0x0f0, osag = 0x100, osizex = 0x120,
    oimg = 0x1a0, ochar = 0x1f0, oslink = 0x020,
}
local M_FLIPH = 0x010

-- Rendered span of a drawn object.  ganiof puts the sprite at
-- (anchor - anioff_x), where anioff_x is `anix` normally and `sizex-1-anix`
-- when h-flipped - so the art mirrors about the anchor when the facing
-- changes.  ani2 stores the offset it actually applied in the per-piece RAM
-- record, which is what `dx` below is.
local function draw_centre(anchor, dx, w)
    if anchor == nil or dx == nil or w == nil or w == 0 then return nil end
    return anchor - dx + (w - 1) // 2
end
-- pdata = 0x100, so p_store4 = 0x290 and p_store6 = 0x2d0 (MAINEQU.ASM).
local P = {
    next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210,
    store4 = 0x290, store6 = 0x2d0,
}

-- Scripted button presses reach the front end (coin/start land fine) but do
-- NOT reach the in-fight move dispatch in this MAME build - the reference
-- st_decap harness fails the same way, so it is not specific to this test.
-- The fatality is therefore driven the same way the harness already forces
-- the victim dizzy: by pointing a process's wake at the target routine.
-- do_fatality_1 is `movi db1_table,a0 / jauc ochar_jump`, so entering it in
-- P1's process dispatches straight to db1_table[10] = do_scortch.
local FORCE_VIA_WAKE = (os.getenv("SCORTCH_FORCE_WAKE") or "1") ~= "0"
-- 0 = plain U,U+HP path (MK1 burn); 1 = D,D,U,U+HP path (stock MK2 burn).
local FORCE_TOASTY = getenv_int("SCORTCH_TOASTY", 0)

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_SCORPION, FT_JAX = 10, 11
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

local cpu, space = nil, nil
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local fight_count = 0
local last_gstate = -1
local p1_confirm_start = 0
local did_direct_select = false
local finish_forced_frame = 0
local victim_dizzy_forced = false
local fighter_verified = false
local fighter_verify_logged = false
local dizzy_ready_frame = 0
local input_start_frame = 0
local did_input_log = false
local fatality_frame = 0
local forced_via_wake = false
local fdeath_seen = false
local spit_seen, fire_seen, skel_seen = {}, {}, {}
local fire_rel, skel_rel = {}, {}
local zorder_ok, zorder_bad = 0, 0
local announce_forced = false
local completed = false
local did_error = false
local finished = false
local pending_snaps = {}
local capture_index = 0
local last_status_frame = 0

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end
local function w32(addr, value) space:write_u32(addr, value & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true,
        ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Up"] = true, ["P1 Down"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local missing = {}
    for name, _ in pairs(wanted) do
        if fields[name] then
            log("input %-16s ok", name)
        else
            log("input %-16s MISSING", name)
            missing[#missing + 1] = name
        end
    end
    return #missing == 0
end

local function main_screen()
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then return screen end
    ok, screen = pcall(function() return manager.machine.screens:at(1) end)
    return ok and screen or nil
end

local function queue_snap(label)
    pending_snaps[#pending_snaps + 1] = { index = capture_index, frame = frame, label = label }
    log("SNAPQUEUED index=%04d frame=%d label=%s", capture_index, frame, label)
    capture_index = capture_index + 1
end

local function flush_snaps()
    if #pending_snaps == 0 then return end
    local screen = main_screen()
    for _, request in ipairs(pending_snaps) do
        local ok, err = false, "no screen"
        if screen then ok, err = pcall(function() screen:snapshot() end) end
        log("SNAP index=%04d frame=%d label=%s ok=%s%s",
            request.index, request.frame, request.label, tostring(ok),
            ok and "" or (" error=" .. tostring(err)))
    end
    pending_snaps = {}
end

-- Associate every visible object with its authored frame label.  Labels are
-- read from the source TBLs only; the test never patches runtime art.
local sag_labels = {}
local function load_sag_labels(path, pattern)
    local fh = io.open(path, "r")
    if not fh then
        log("WARN cannot open %s for SAG labels", path)
        return
    end
    local current = nil
    for line in fh:lines() do
        local label = line:match("^([%w_]+):")
        if label then
            current = label:match(pattern)
        elseif current then
            local raw = line:match("%.long%s+([%x]+)H")
            if raw then
                sag_labels[tonumber(raw, 16) & 0x00ffffff] = current
                current = nil
            end
        end
    end
    fh:close()
end
load_sag_labels(ROOT .. "/src/MK1SKULL.TBL", "^(MK1FIRE%d+)")
load_sag_labels(ROOT .. "/src/MK1SKULL.TBL", "^(MK1SKEL%d+)")
load_sag_labels(ROOT .. "/src/MKFX.TBL", "^(scorpfire%d+)")
-- The stock MK2 burn's victim frames.  Used by the SCORTCH_TOASTY=1 run to
-- confirm the D,D,U,U + HP combo still reaches flaming_skeleton instead of
-- the MK1 path.
load_sag_labels(ROOT .. "/src/MKFX.TBL", "^(fireskel%d*)")

-- Walk the display lists and return which labeled frames are on screen this
-- tick, plus the z of the flame column and of the skeleton so the "flame
-- draws over the victim" requirement can be checked directly.
local fire_all = {}
local function marker_set()
    fire_all = {}
    local spit, fire, skel = {}, {}, {}
    local fire_z, skel_z = nil, nil
    local fire_x, skel_x = nil, nil
    local fire_xval, skel_xval = nil, nil
    local fire_w, skel_w = nil, nil
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag1 = r32(obj + O.osag) & 0x00ffffff
            local img = r32(obj + O.oimg)
            local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
            local label = sag_labels[sag1] or sag_labels[sag2]
            if label then
                local z = r32(obj + O.ozval)
                if label:match("^scorpfire") or label:match("^fireskel") then
                    spit[label] = true
                elseif label:match("^MK1FIRE") then
                    fire[label] = true
                    if fire_z == nil or z > fire_z then fire_z = z end
                    fire_x = r16(obj + O.oxpos)
                    -- Every matching object, not just the last one: the column
                    -- is multipart and the parts do NOT all share one anchor.
                    fire_all[#fire_all + 1] = string.format("%s@%d(obj=%s,link=%s)",
                        label, fire_x, hx(obj), hx(r32(obj + O.oslink)))
                    -- ani2 multipart RAM: sag(32) size(32) ctrl(16) dx(16) dy(16).
                    -- Rendered left edge = oxpos + dx, so dx is the authored
                    -- anipoint offset actually being applied.
                    if img ~= 0 then
                        local dx = r16(img + 80)
                        if dx >= 0x8000 then dx = dx - 0x10000 end
                        fire_xval = dx
                        -- Width comes out of the same ani2 record as dx (the
                        -- head object's osize reads back 0 for a multiparter).
                        fire_w = r16(img + 32)
                    end
                elseif label:match("^MK1SKEL") then
                    skel[label] = true
                    if skel_z == nil or z > skel_z then skel_z = z end
                    skel_x = r16(obj + O.oxpos)
                    if img ~= 0 then
                        local dx = r16(img + 80)
                        if dx >= 0x8000 then dx = dx - 0x10000 end
                        skel_xval = dx
                        skel_w = r16(img + 32)
                    end
                end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return spit, fire, skel, fire_z, skel_z, fire_x, skel_x, fire_xval, skel_xval,
        fire_w, skel_w
end

local function sorted_labels(set)
    local items = {}
    for label, _ in pairs(set) do items[#items + 1] = label end
    table.sort(items)
    return #items > 0 and table.concat(items, "+") or "-"
end

local function force_select()
    w16(A.p1_char, FT_SCORPION)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Scorpion(%d) P2=Jax(%d) stage=%d", FT_SCORPION, FT_JAX, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    return p1char == FT_SCORPION and p2char == FT_JAX, p1char, p2char
end

local function pxy()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p2x = 0, 0
    if p1obj ~= 0 then p1x = r16(p1obj + O.oxpos) end
    if p2obj ~= 0 then p2x = r16(p2obj + O.oxpos) end
    return p1x, p2x
end

-- sc_hi_punch gates the scortch on get_x_dist in [0x90,0xB0]; snap P1 to a
-- deterministic distance left of the victim before the press.
local function snap_fatal_range()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local p2x = r16(p2obj + O.oxpos)
    local x = (SIDE == "right") and (p2x + FATAL_X) or (p2x - FATAL_X)
    w16(p1obj + O.oxpos, x)
    w32(p1obj + O.oxval, (x << 16) & 0xffffffff)
    log("snap_fatal_range side=%s p1_x=%d p2_x=%d dist=%d", SIDE, x, p2x, FATAL_X)
end

local function force_finish_him()
    if fight_count ~= 1 or fatality_frame ~= 0 or r16(A.f_death) ~= 0 then return end
    local fighters_ok, p1ochar, p2ochar = loaded_fighters_match()
    if not fighters_ok then
        if not fighter_verify_logged then
            fighter_verify_logged = true
            log("waiting_for_visible_fighters p1_objchar=%d p2_objchar=%d want=%d/%d",
                p1ochar, p2ochar, FT_SCORPION, FT_JAX)
        end
        return
    end
    if not fighter_verified then
        fighter_verified = true
        log("visible_fighters_verified p1_objchar=%d p2_objchar=%d", p1ochar, p2ochar)
        queue_snap("visible_fighters_verified")
    end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 720 then return end
    w16(A.winner_status, 3); w16(A.f_death, 0)
    local p1proc = r32(A.p1_proc)
    if p1proc ~= 0 then
        w16(p1proc + P.flags, r16(p1proc + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2proc = r32(A.p2_proc)
    if p2proc ~= 0 and not victim_dizzy_forced then
        -- Place Scorpion BEFORE handing the victim to dizzy_dude: its first
        -- act is face_opponent, and that is the only thing that turns the
        -- victim around.  Snapping afterwards leaves him facing the way he
        -- already was, which quietly defeats the whole point of -Side right.
        snap_fatal_range()
        w32(p2proc + P.wake, A.dizzy_dude)
        victim_dizzy_forced = true
    end
    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        log("finish_him_forced frame=%d rel=%d", frame, rel)
        queue_snap("finish_him_forced")
    end
end

local function victim_ready()
    local proc = r32(A.p2_proc)
    if proc == 0 then return false end
    local wake = r32(proc + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(proc + P.action) == ACT_STUNNED
end

-- MK1 path (default): a BARE High Punch during Finish Him.  MOVES.ASM
-- sc_hi_punch was remapped to fire the MK1 scortch on a plain HP with no
-- stick motion, so driving the old Up,Up first is not just unnecessary - it
-- makes Scorpion JUMP, and the HP then lands as an air punch that never
-- reaches the finish-him branch at all.  That is what forced the earlier
-- runs down the forced_fatality_via_wake fallback.
--
-- Toasty path (SCORTCH_TOASTY=1): the retail D,D,U,U + HP combo
-- (scom_sc_toasty, 0x38-tick window) still wins the race in sc_hi_punch and
-- gives the stock MK2 burn.  Discrete presses with release gaps so the
-- joystick queue records each switch transition.
local COMBO_SCRIPT_MK1 = {
    { 0, 10, "P1 High Punch" },
}

local COMBO_SCRIPT_TOASTY = {
    { 0,   6, "P1 Down" },
    { 9,  15, "P1 Down" },
    { 18, 24, "P1 Up" },
    { 27, 33, "P1 Up" },
    { 36, 46, "P1 High Punch" },
}

local function input_phase()
    if input_start_frame == 0 then return nil end
    local rel = frame - input_start_frame
    if rel >= 0 and rel < 60 then return "combo" end
    return nil
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then return frame >= 220 and frame < 6000 and (frame % 80) < 20 end
        if name == "2 Players Start" then return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55 end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then return frame >= p1_confirm_start and frame < p1_confirm_start + 40 end
        if name == "P2 High Punch" and p1_confirm_start > 0 then return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120 end
    end
    if input_phase() == "combo" then
        local rel = frame - input_start_frame
        local script = (FORCE_TOASTY ~= 0) and COMBO_SCRIPT_TOASTY or COMBO_SCRIPT_MK1
        for _, step in ipairs(script) do
            if name == step[3] and rel >= step[1] and rel < step[2] then return true end
        end
    end
    return false
end

local function write_frame_log(rel, fire, skel, fire_z, skel_z)
    if not csvfh then return end
    local p1x, p2x = pxy()
    csvfh:write(string.format("%d,%d,%d,%d,%s,%s,%s,%s,%d,%d\n",
        capture_index, frame, rel, r16(A.f_death), sorted_labels(fire),
        sorted_labels(skel), fire_z and hx(fire_z) or "-",
        skel_z and hx(skel_z) or "-", p1x, p2x))
    csvfh:flush()
end

local function cpu_pc()
    if not cpu then return nil end
    for _, name in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, item = pcall(function() return cpu.state[name] end)
        if ok and item then
            local okv, value = pcall(function() return item.value end)
            if okv then return value end
        end
    end
    return nil
end

local function check_lockup()
    if not space then return false end
    local pc = cpu_pc()
    if pc and pc >= A.system_lockup and pc < A.tvbp then
        log("ERROR lockup pc=%s pf=%s", hx(pc), hx(r32(A.pf_ram)))
        did_error = true
        return true
    end
    return false
end

local function all_seen(set, prefix, n)
    local missing = {}
    for i = 1, n do
        if not set[prefix .. i] then missing[#missing + 1] = prefix .. i end
    end
    return #missing == 0, table.concat(missing, ",")
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    queue_snap(ok and "pass_final" or ("error_" .. reason))
    flush_snaps()
    if csvfh then csvfh:close(); csvfh = nil end
    local _, fire_missing = all_seen(fire_seen, "MK1FIRE", 6)
    local _, skel_missing = all_seen(skel_seen, "MK1SKEL", 8)
    log("%s reason=%s fdeath=%s spit=%s fire=%s skel=%s fire_missing=%s skel_missing=%s "
        .. "fire2_rel=%s skel1_rel=%s zorder_ok=%d zorder_bad=%d",
        ok and "PASS" or "ERROR", reason, tostring(fdeath_seen),
        sorted_labels(spit_seen), sorted_labels(fire_seen), sorted_labels(skel_seen),
        fire_missing ~= "" and fire_missing or "-", skel_missing ~= "" and skel_missing or "-",
        tostring(fire_rel["MK1FIRE2"]), tostring(skel_rel["MK1SKEL1"]),
        zorder_ok, zorder_bad)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then
            finish(false, "required_input_missing")
            return
        end
        log("loaded: P1 Scorpion vs P2 Jax; Up,Up+HP scortch; capture_until=%d", CAPTURE_UNTIL)
    end

    if not space then return end
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d", frame, fight_count)
            queue_snap("fight_" .. tostring(fight_count) .. "_start")
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 then
        force_select()
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_SCORPION and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
    end

    force_finish_him()
    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        dizzy_ready_frame = frame
        input_start_frame = frame + 30
        snap_fatal_range()
        log("victim_dizzy_ready frame=%d; combo input begins at frame=%d", frame, input_start_frame)
        queue_snap("victim_dizzy_ready")
    end

    -- Hold the fatality distance through the input window; the gate is
    -- re-read at the HP press, not at Finish Him.
    if input_start_frame > 0 and fatality_frame == 0 and frame < input_start_frame + 40 then
        if (frame - input_start_frame) % 8 == 0 then snap_fatal_range() end
    end

    if input_phase() and not did_input_log then
        did_input_log = true
        log("combo_input_started frame=%d", frame)
        queue_snap("input_upup_hp")
    end

    -- Fallback trigger: stamp the toasty flag and redirect P1 into
    -- do_fatality_1 once the scripted input window has closed without the
    -- move dispatch picking the press up.
    if FORCE_VIA_WAKE and input_start_frame > 0 and fatality_frame == 0
        and not forced_via_wake and frame >= input_start_frame + 75 then
        forced_via_wake = true
        local p1proc = r32(A.p1_proc)
        if p1proc ~= 0 and A.do_fatality_1 ~= 0 then
            -- sc_hi_punch stamps p_store6 on *a13(p_store4); do_scortch reads
            -- *a13(p_store6).  Write both so the branch sees the flag either way.
            w16(p1proc + P.store6, FORCE_TOASTY)
            local store4 = r32(p1proc + P.store4)
            if store4 ~= 0 then w16(store4 + P.store6, FORCE_TOASTY) end
            w32(p1proc + P.wake, A.do_fatality_1)
            log("forced_fatality_via_wake frame=%d p1proc=%s store4=%s toasty=%d",
                frame, hx(p1proc), hx(store4), FORCE_TOASTY)
            queue_snap("forced_fatality_via_wake")
        else
            log("WARN cannot force via wake p1proc=%s do_fatality_1=%s",
                hx(p1proc), hx(A.do_fatality_1))
        end
    end

    local fdeath = r16(A.f_death)
    if fdeath ~= 0 and fdeath ~= 0xffff and fatality_frame == 0 then
        fatality_frame = frame
        fdeath_seen = true
        log("fatality_started frame=%d f_death=%d", frame, fdeath)
        queue_snap("fatality_start")
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local spit, fire, skel, fire_z, skel_z, fire_x, skel_x, fire_xval, skel_xval,
              fire_w, skel_w = marker_set()
        -- fire_dx / skel_dx are the anipoint offsets ani2 applied, so the
        -- rendered left edge is (x - dx).  Handy when a sprite is anchored
        -- correctly but still draws in the wrong place.  fire_c / skel_c are
        -- the resulting drawn centres: the whole point of the MK1 burn is that
        -- those two track each other, in BOTH facings.
        if fire_x or skel_x then
            local p1x, p2x = pxy()
            local p2obj = r32(A.p2_obj)
            local vflip = p2obj ~= 0 and ((r16(p2obj + O.oflags) & M_FLIPH) ~= 0)
            local fire_c = draw_centre(fire_x, fire_xval, fire_w)
            local skel_c = draw_centre(skel_x, skel_xval, skel_w)
            local delta = (fire_c and skel_c) and (fire_c - skel_c) or nil
            -- Freeze the victim's own drawn centre at the last frame before the
            -- skeleton takes over; after that his object IS the skeleton.
            if skel_x == nil and p2obj ~= 0 then
                local vimg = r32(p2obj + O.oimg)
                if vimg ~= 0 then
                    local vdx = r16(vimg + 80)
                    if vdx >= 0x8000 then vdx = vdx - 0x10000 end
                    local vw = r16(vimg + 32)
                    local vc = draw_centre(r16(p2obj + O.oxpos), vdx, vw)
                    if vc then victim_last = { c = vc, w = vw, dx = vdx } end
                end
            end
            local vc = victim_last and victim_last.c or nil
            log("POS rel=%d fire_x=%s fire_dx=%s skel_x=%s skel_dx=%s p1_x=%d p2_x=%d",
                rel, tostring(fire_x), tostring(fire_xval),
                tostring(skel_x), tostring(skel_xval), p1x, p2x)
            log("CENTRE rel=%d side=%s victim_flip=%s fire_c=%s(w=%s) skel_c=%s(w=%s) delta=%s",
                rel, SIDE, tostring(vflip), tostring(fire_c), tostring(fire_w),
                tostring(skel_c), tostring(skel_w), tostring(delta))
            log("VSBODY rel=%d victim_c=%s(w=%s) fire-victim=%s skel-victim=%s",
                rel, tostring(vc), tostring(victim_last and victim_last.w),
                (fire_c and vc) and tostring(fire_c - vc) or "nil",
                (skel_c and vc) and tostring(skel_c - vc) or "nil")
            if #fire_all > 0 then
                log("FIREPARTS rel=%d %s", rel, table.concat(fire_all, " "))
            end
        end
        for label, _ in pairs(spit) do spit_seen[label] = true end
        for label, _ in pairs(fire) do
            if not fire_seen[label] then
                fire_seen[label] = true
                fire_rel[label] = rel
                log("fire_frame_seen %s rel=%d", label, rel)
                queue_snap(string.format("fire_%s_rel_%03d", label, rel))
            end
        end
        for label, _ in pairs(skel) do
            if not skel_seen[label] then
                skel_seen[label] = true
                skel_rel[label] = rel
                log("skel_frame_seen %s rel=%d z=%s", label, rel, skel_z and hx(skel_z) or "-")
                queue_snap(string.format("skel_%s_rel_%03d", label, rel))
            end
        end

        -- The flame must be in FRONT of the skeleton whenever both are up.
        if fire_z and skel_z then
            if fire_z > skel_z then
                zorder_ok = zorder_ok + 1
            else
                zorder_bad = zorder_bad + 1
                if zorder_bad == 1 then
                    log("WARN flame not in front rel=%d fire_z=%s skel_z=%s",
                        rel, hx(fire_z), hx(skel_z))
                    queue_snap("zorder_bad")
                end
            end
        end

        if not announce_forced and (fdeath == 0 or fdeath == 0xffff) then
            announce_forced = true
            w16(A.winner_status, 1)
            log("victory_announce_forced frame=%d rel=%d", frame, rel)
        end

        local capture = (rel <= CAPTURE_UNTIL and rel % 10 == 0) or rel == PASS_REL
        if capture then
            write_frame_log(rel, fire, skel, fire_z, skel_z)
            queue_snap(string.format("rel_%03d_fire_%s_skel_%s", rel,
                sorted_labels(fire), sorted_labels(skel)))
        end

        if rel > 200 and (fdeath == 0 or fdeath == 0xffff) then completed = true end
        if rel >= PASS_REL then
            local fire_ok, fire_missing = all_seen(fire_seen, "MK1FIRE", 6)
            local skel_ok, skel_missing = all_seen(skel_seen, "MK1SKEL", 8)
            if did_error then
                finish(false, "runtime_error")
            elseif not fdeath_seen then
                finish(false, "f_death_not_seen")
            elseif not fire_ok then
                finish(false, "missing_fire_frames_" .. fire_missing)
            elseif not skel_ok then
                finish(false, "missing_skel_frames_" .. skel_missing)
            elseif not (fire_rel["MK1FIRE2"] and skel_rel["MK1SKEL1"]) then
                finish(false, "handoff_frames_not_timed")
            elseif skel_rel["MK1SKEL1"] < fire_rel["MK1FIRE2"] then
                finish(false, "skeleton_appeared_before_fire2")
            elseif zorder_ok == 0 then
                finish(false, "flame_never_observed_in_front")
            elseif zorder_bad > 0 then
                finish(false, "flame_behind_skeleton_" .. tostring(zorder_bad))
            elseif not completed then
                finish(false, "fatality_not_completed")
            else
                finish(true, "mk1_fire1_6_skel1_8_handoff_zorder")
            end
            return
        end
    end

    if check_lockup() then finish(false, "mkbug_lockup"); return end

    if A.blood_count ~= 0 then
        local bc = r16(A.blood_count)
        if bc > blood_peak then blood_peak = bc end
        if bc ~= blood_last then
            blood_last = bc
            log("BLOODCOUNT frame=%d count=%d peak=%d%s",
                frame, bc, blood_peak, bc >= 64 and "  *** AT CAP - blood denied ***" or "")
        end
    end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        local _, p1ochar, p2ochar = loaded_fighters_match()
        log("status frame=%d gs=%d fight=%d p1=%d/%d p2=%d/%d ws=%d fdeath=%d blood=%d/%d input=%s", frame,
            gs, fight_count, r16(A.p1_char), p1ochar, r16(A.p2_char), p2ochar,
            r16(A.winner_status), r16(A.f_death),
            A.blood_count ~= 0 and r16(A.blood_count) or -1, blood_peak,
            input_phase() or "-")
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif input_start_frame > 0 and fatality_frame == 0 and frame - input_start_frame > 300 then
        finish(false, "fatality_never_started_after_real_input")
    elseif fight_count == 1 and fighting_frame > 0 and not fighter_verified and frame - fighting_frame > 360 then
        finish(false, "visible_fighters_not_scorpion_jax")
    elseif frame > 14000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function()
    flush_snaps()
end)
