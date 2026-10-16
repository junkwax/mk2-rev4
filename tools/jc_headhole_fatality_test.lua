-- jc_headhole_fatality_test.lua
--
-- Dedicated MAME Lua harness for Johnny Cage's restored DBLO2/headhole fatality.
-- It lets MK2 initialize normally, shortcuts character select into Cage on either
-- player side versus a configured victim on a non-Dead-Pool stage, immediately awards round 1,
-- then uses the real round-2 fight state for Finish Him. The test ROM's
-- jc_headhole_hp_test hook routes Cage HP through fatality_xfer_close into
-- do_jc_headhole, snapshots are captured, and the test exits PASS/ERROR.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local LOG_PATH = os.getenv("JC_HEADHOLE_FATALITY_LOG") or (ROOT .. "/tools/jc_headhole_fatality_test.log")
local logfh = io.open(LOG_PATH, "w")

local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    print("[jcheadhole] " .. msg)
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value & 0xffffffff)
end

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
        log("ERROR could not open mk2.map")
    end
end

local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s, using fallback %s", name, hx(fallback or 0))
    return fallback or 0
end

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local READOUT_ENABLED = (_G.JC_HEADHOLE_READOUT == true) or (os.getenv("JC_HEADHOLE_READOUT") == "1")
local READOUT_STEP = tonumber(_G.JC_HEADHOLE_READOUT_STEP) or getenv_int("JC_HEADHOLE_READOUT_STEP", 1)
if READOUT_STEP < 1 then READOUT_STEP = 1 end
local FORCE_NOFLIP = (_G.JC_HEADHOLE_FORCE_NOFLIP == true)
    or (os.getenv("JC_HEADHOLE_FORCE_NOFLIP") == "1")
-- Diagnostic switch: keep Cage, the victim body, HEADHOLE, and KHEART active
-- while asking every optional blood worker to exit at its normal gate.  This is
-- deliberately runtime-only so an art/lane isolation run never changes ROM code.
local FORCE_NO_BLOOD = (_G.JC_HEADHOLE_FORCE_NO_BLOOD == true)
    or (os.getenv("JC_HEADHOLE_FORCE_NO_BLOOD") == "1")
local READOUT_DIR = (os.getenv("JC_HEADHOLE_READOUT_DIR") or (ROOT .. "/tmp/jc_headhole_readout")):gsub("\\", "/")
local READOUT_CSV_PATH = os.getenv("JC_HEADHOLE_READOUT_CSV") or (READOUT_DIR .. "/jc_headhole_anim_readout.csv")
local READOUT_TXT_PATH = os.getenv("JC_HEADHOLE_READOUT_TXT") or (READOUT_DIR .. "/jc_headhole_anim_readout.txt")
local KHEART_PLACEMENT_ENABLED = (_G.JC_KHEART_PLACEMENT == true)
    or (os.getenv("JC_KHEART_PLACEMENT") == "1")
local KHEART_PLACEMENT_CSV_PATH = os.getenv("JC_KHEART_PLACEMENT_CSV")
    or (READOUT_DIR .. "/jc_kheart_placement.csv")
local KHEART_PLACEMENT_TXT_PATH = os.getenv("JC_KHEART_PLACEMENT_TXT")
    or (READOUT_DIR .. "/jc_kheart_placement.txt")
local KHEART_PLACEMENT_STATE_DIR = (os.getenv("JC_KHEART_PLACEMENT_STATE_DIR")
    or (READOUT_DIR .. "/states")):gsub("\\", "/")
local KHEART_PLACEMENT_MAX_REL = getenv_int("JC_KHEART_PLACEMENT_MAX_REL", 250)
local KHEART_PLACEMENT_AUTOTEST = os.getenv("JC_KHEART_PLACEMENT_AUTOTEST") == "1"
local TARGETED_SNAPSHOTS_ONLY = os.getenv("JC_HEADHOLE_TARGETED_SNAPSHOTS_ONLY") == "1"
local HUD_ENABLED = os.getenv("JC_HEADHOLE_HUD") ~= "0"
local ATTACKER_SIDE = tonumber(_G.JC_HEADHOLE_ATTACKER_SIDE)
    or getenv_int("JC_HEADHOLE_ATTACKER_SIDE", 1)
if ATTACKER_SIDE ~= 2 then ATTACKER_SIDE = 1 end
local VICTIM_SIDE = ATTACKER_SIDE == 1 and 2 or 1
local PASS_REL = tonumber(_G.JC_HEADHOLE_PASS_REL)
    or getenv_int("JC_HEADHOLE_PASS_REL", 760)
local SNAPSHOT_RELS = {}
local SNAPSHOT_RELS_RAW = os.getenv("JC_HEADHOLE_SNAPSHOT_RELS") or ""
for token in SNAPSHOT_RELS_RAW:gmatch("[^,%s]+") do
    local rel = tonumber(token)
    if rel then SNAPSHOT_RELS[rel] = true end
end
local targeted_snap_seen = {}

local function set_count(set)
    local n = 0
    for _, _ in pairs(set) do n = n + 1 end
    return n
end

local function load_tbl_sags(path, want_label)
    local out = {}
    local fh = io.open(path, "r")
    if not fh then
        log("WARN could not open SAG marker table %s", path)
        return out
    end

    local current = nil
    for line in fh:lines() do
        local label = line:match("^([%w_]+):")
        if label then
            current = want_label(label) and label or nil
        elseif current then
            local raw = line:match("%.long%s+([%x]+)H")
            if raw then
                local sag = tonumber(raw, 16)
                if sag then out[sag & 0x00ffffff] = current end
                current = nil
            end
        end
    end
    fh:close()
    return out
end

local deathblo10_sags = load_tbl_sags(ROOT .. "/src/JCHRIP.TBL", function(label)
    return label == "JC2DEATHBLO10A" or label == "JC2DEATHBLO10B"
end)

local jc_victory_sags = load_tbl_sags(ROOT .. "/src/MKJC.TBL", function(label)
    return label:match("^JCVICTORY%d") ~= nil
end)

local headhole_sags = {}
for _, tbl in ipairs({
    "HHHEADHO.TBL", "JCHEADHO.TBL", "KTHEADHO.TBL", "LKHEADHO.TBL",
    "NJHEADHO.TBL", "RNHEADHO.TBL", "STHEADHO.TBL", "UGHEADHO.TBL",
}) do
    local labels = load_tbl_sags(ROOT .. "/src/" .. tbl, function(label)
        return label:match("DEADHEAD") ~= nil or label:match("HEADHOLE") ~= nil
    end)
    for sag, label in pairs(labels) do
        headhole_sags[sag] = label
    end
end

local readout_sag_labels = {}
local function merge_sag_labels(path, want_label)
    local labels = load_tbl_sags(path, want_label)
    for sag, label in pairs(labels) do
        readout_sag_labels[sag] = label
    end
end

if READOUT_ENABLED then
    merge_sag_labels(ROOT .. "/src/JCHRIP.TBL", function(label)
        return label:match("^JC2DEATHBLO") ~= nil
    end)
    merge_sag_labels(ROOT .. "/src/MKJC.TBL", function(label)
        return label:match("^JCHIPUNCH[23]") ~= nil
    end)
    merge_sag_labels(ROOT .. "/src/JCMK1BLD.TBL", function(label)
        return label:match("^KHEART") ~= nil
    end)
    merge_sag_labels(ROOT .. "/src/JCBLOOD.TBL", function(label)
        return label:match("^JCSTAB") ~= nil or label:match("^JCSPLAT") ~= nil
    end)
    merge_sag_labels(ROOT .. "/src/JCSPILL.TBL", function(label)
        return label:match("^SPILL") ~= nil
    end)
    merge_sag_labels(ROOT .. "/src/KGBLOOD.TBL", function(label)
        return label:match("^SMGUSH") ~= nil
    end)
    merge_sag_labels(ROOT .. "/src/MKBLOOD.TBL", function(label)
        return label:match("^SPURT") ~= nil
            or label:match("^SPRAY") ~= nil
            or label:match("^SPLASH") ~= nil
            or label:match("^STAB%d+$") ~= nil
            or label:match("^SPLAT%d+$") ~= nil
            or label:match("^SPILL%d+$") ~= nil
    end)
    for sag, label in pairs(headhole_sags) do
        readout_sag_labels[sag] = label
    end
    local baraka_decap = load_tbl_sags(ROOT .. "/src/MKSA2.TBL", function(label)
        return label:match("^UGDECAPLEG[1-7]A$") ~= nil
    end)
    for sag, label in pairs(baraka_decap) do
        readout_sag_labels[sag] = label:gsub("^UGDECAPLEG([1-7])A$", "UGDECAP%1")
    end
end

-- Native CAGE10.IMG DBLO2 sequence (letter O; often written DBL02).
-- The entries are authored steps, not a preview-export expansion.  Keep the
-- labels unique here and resolve holds from their source tick counts.
DBLO2_STEPS = {
    { label = "JC2DEATHBLO1",  ticks = 6 },
    { label = "JC2DEATHBLO2",  ticks = 1 },
    { label = "JC2DEATHBLO3",  ticks = 1 },
    { label = "JCHIPUNCH3",    ticks = 10 },
    { label = "JCHIPUNCH2",    ticks = 1 },
    { label = "JC2DEATHBLO4",  ticks = 1 },
    { label = "JC2DEATHBLO5",  ticks = 1 },
    { label = "JC2DEATHBLO6",  ticks = 1 },
    { label = "JC2DEATHBLO7",  ticks = 10 },
    { label = "JC2DEATHBLO8",  ticks = 1 },
    { label = "JC2DEATHBLO9",  ticks = 1 },
    { label = "JC2DEATHBLO10", ticks = 10 },
}

function dblo2_at_rel(rel)
    if rel < 0 then return nil end
    local start = 0
    for step, entry in ipairs(DBLO2_STEPS) do
        if rel < start + entry.ticks then
            return entry.label, step, rel - start, entry.ticks
        end
        start = start + entry.ticks
    end
    return nil
end

local A = {
    active        = sym("active", 0x010dc6d0),
    gstate        = sym("gstate", 0x01129d90),
    p1_state      = sym("p1_state", 0x0112a7f0),
    p2_state      = sym("p2_state", 0x0112b3c0),
    p1_char       = sym("p1_char", 0x0112a880),
    p2_char       = sym("p2_char", 0x0112b450),
    p1_obj        = sym("p1_obj", 0x0112a820),
    p2_obj        = sym("p2_obj", 0x0112b3f0),
    p1_proc       = sym("p1_proc", 0x0112a860),
    p2_proc       = sym("p2_proc", 0x0112b430),
    p1_bar        = sym("p1_bar", 0x0112a8f0),
    p2_bar        = sym("p2_bar", 0x0112b4c0),
    p1_bar_view   = sym("p1_bar_view", 0x011285f0),
    p2_bar_view   = sym("p2_bar_view", 0x01128530),
    curback       = sym("curback", 0x0112c0d0),
    map_position  = sym("map_position", 0x0112c140),
    battle_num    = sym("battle_num", 0x0112c150),
    round_num     = sym("round_num", 0x0112c0f0),
    p1_matchw     = sym("p1_matchw", 0x0112a8c0),
    p2_matchw     = sym("p2_matchw", 0x0112b490),
    p1_bcq        = sym("p1_bcq", 0x0112a940),
    p1_jcq        = sym("p1_jcq", 0x0112abe0),
    p2_bcq        = sym("p2_bcq", 0x0112b500),
    p2_jcq        = sym("p2_jcq", 0x0112b7b0),
    tick          = sym("tick", 0x01127070),
    pageaddr      = sym("pageaddr", 0x01127140),
    noflip        = sym("noflip", 0x01127190),
    displayon     = sym("displayon", 0x011271a0),
    worldtlx      = sym("worldtlx", 0x01127430),
    worldtly      = sym("worldtly", 0x01127210),
    winner_status = sym("winner_status", 0x0112c110),
    f_death       = sym("f_death", 0x0112bfc0),
    f_no_blood    = sym("f_no_blood", 0x0112c1d0),
    f_no_violence = sym("f_no_violence", 0x0112c1e0),
    pf_ram        = sym("pf_ram", 0x0112c0b0),
    palram        = sym("palram", 0x01125720),
    objlst        = sym("objlst", 0x01127570),
    objlst2       = sym("objlst2", 0x01127590),
    objlst3       = sym("objlst3", 0x011275b0),
    do_jc_headhole = sym("do_jc_headhole", 0xff9ed2d0),
    dizzy_dude    = sym("dizzy_dude", 0xffa27af0),
    dizzy         = sym("dizzy", 0xffa27e40),
    CAGE_P        = sym("CAGE_P", 0xffbadf70),
    debug1        = sym("debug1", 0x0112c260),
    debug2        = sym("debug2", 0x0112c270),
    debug3        = sym("debug3", 0x0112c290),
    debug4        = sym("debug4", 0x0112c2b0),
}

local function player_slot(side)
    if side == 2 then
        return {
            side = 2,
            name = "P2",
            char = A.p2_char,
            state = A.p2_state,
            obj = A.p2_obj,
            proc = A.p2_proc,
            bar = A.p2_bar,
            bar_view = A.p2_bar_view,
            bcq = A.p2_bcq,
            jcq = A.p2_jcq,
            high_punch = "P2 High Punch",
            left = "P2 Left",
            right = "P2 Right",
        }
    end
    return {
        side = 1,
        name = "P1",
        char = A.p1_char,
        state = A.p1_state,
        obj = A.p1_obj,
        proc = A.p1_proc,
        bar = A.p1_bar,
        bar_view = A.p1_bar_view,
        bcq = A.p1_bcq,
        jcq = A.p1_jcq,
        high_punch = "P1 High Punch",
        left = "P1 Left",
        right = "P1 Right",
    }
end

local ATTACKER = player_slot(ATTACKER_SIDE)
local VICTIM = player_slot(VICTIM_SIDE)

local O = {
    next    = 0x000,
    ograv   = 0x020,
    oxvel   = 0x040,
    oyvel   = 0x060,
    oxval   = 0x080,
    oxpos   = 0x090,
    oyval   = 0x0a0,
    oypos   = 0x0b0,
    ozval   = 0x0c0,
    oflags  = 0x0f0,
    oflags2 = 0x160,
    osag    = 0x100,
    osize   = 0x120,
    opal    = 0x140,
    oimg    = 0x1a0,
    oshape  = 0x1d0,
    ochar   = 0x1f0,
}

local P = {
    next   = 0x000,
    id     = 0x020,
    time   = 0x030,
    psptr  = 0x040,
    pa10   = 0x080,
    pa9    = 0x0a0,
    wake   = 0x0e0,
    pa8    = 0x0c0,
    otherguy = 0x140,
    otherproc = 0x170,
    anitab = 0x1b0,
    anirate = 0x1d0,
    anicount = 0x1e0,
    action = 0x1f0,
    ganiy  = 0x200,
    flags  = 0x210,
    store4 = 0x290,
}

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local PS_ACTIVE   = 1
local FT_CAGE     = 2
local FT_BARAKA   = 3
local FT_VICTIM   = tonumber(_G.JC_HEADHOLE_VICTIM)
    or getenv_int("JC_HEADHOLE_VICTIM", FT_BARAKA)
local FIGHTER_NAMES = {
    [0] = "Kung Lao",
    [1] = "Liu Kang",
    [2] = "Johnny Cage",
    [3] = "Baraka",
    [4] = "Kitana",
    [5] = "Mileena",
    [6] = "Shang Tsung",
    [7] = "Raiden",
    [8] = "Sub-Zero",
    [9] = "Reptile",
    [10] = "Scorpion",
    [11] = "Jax",
}
local VICTIM_NAME = FIGHTER_NAMES[FT_VICTIM] or ("fighter " .. tostring(FT_VICTIM))
local KOMBAT_TOMB = 1
local STAGE_ID    = getenv_int("JC_HEADHOLE_STAGE", KOMBAT_TOMB)
local STAGE_NAMES = {
    [0] = "Dead Pool",
    [1] = "Kombat Tomb",
    [2] = "Wasteland",
    [3] = "Tower",
    [4] = "Living Forest",
    [5] = "Armory",
    [6] = "Pit II",
    [7] = "Portal",
    [8] = "Kahn's Arena",
    [9] = "Goro's Lair",
}
local STAGE_NAME  = os.getenv("JC_HEADHOLE_STAGE_NAME") or STAGE_NAMES[STAGE_ID] or ("stage " .. tostring(STAGE_ID))
local MAX_HP      = 0x00a1
local PID_FX      = 0x0100
local PID_HEAD    = 0x0202
local COLRAM      = 0x01800000
local PAL_STRIDE  = 0x00001000
local ACT_STANCE  = 0x0303
local ACT_STUNNED = 0x0400
local PM_REACTING = 0x0004
local PM_SITDUCK  = 0x0008
local PM_SPECIAL  = 0x0010
-- The program layout moves as code changes.  Resolve the real MKBUG recovery
-- range from the current linker map instead of retaining an obsolete fixed one.
local MKBUG_START = sym("system_lockup", 0xffa74d60)
local MKBUG_END   = sym("TVBP", 0xffa74f70) - 1
local PROGRAM_ROM_BASE = 0xff800000
local HP_TRIGGER_START = getenv_int("JC_HEADHOLE_HP_START", 120)
local HP_TRIGGER_LEN   = getenv_int("JC_HEADHOLE_HP_LEN", 40)
local MP_SAG  = 0x000
local MP_SIZE = 0x020
local MP_CTRL = 0x040
local MP_ANIX = 0x050
local MP_ANIY = 0x060
local MP_LEN  = 0x070

local fields = {}
local cpu = nil
local space = nil
local rom_region = nil
local rom_region_tag = nil
local charsel_frame = 0
local vs_frame = 0
local fighting_frame = 0
local fight_count = 0
local fatality_frame = 0
local finish_forced_frame = 0
local round1_forced_frame = 0
local p1_confirm_start = 0
local last_gstate = -1
local did_direct_select = false
local did_stage_context = false
local did_force_round1 = false
local did_input_snap = false
local did_fatality_snap = false
local did_mid_snap = false
local did_final_anim_snap = false
local did_complete = false
local did_deathblo10 = false
local did_victory_started = false
local fdeath_clear_frame = 0
local did_error = false
local finished = false
local dizzy_ready_frame = 0
local did_dizzy_snap = false
local last_attacker_live = nil
local readout_csv = nil
local readout_txt = nil
local readout_seen = {}
local readout_objdump_seen = {}
local overlay_warned = false
local snapshot_index = 0
local pending_snapshots = {}
local effect_label_summary = nil
local placement_ready = false
local placement_started = false
local placement_start_requested = not KHEART_PLACEMENT_ENABLED
local placement_paused = false
local placement_scene = -1
local placement_max_scene = KHEART_PLACEMENT_MAX_REL // 5
local placement_advancing = false
local placement_advance_remaining = 0
local placement_previewing = false
local placement_preview_needed = false
local placement_showing = false
local placement_pending_load = nil
local placement_load_needs_unpause = false
local placement_load_issued = false
local placement_capture_pending = -1
local placement_load_warmup_frames = 0
local placement_reuse_pause_pending = false
local placement_step_requested = false
local placement_frozen_process_times = {}
local placement_buffers = {}
local placement_state_generation = {}
local placement_baselines = {}
local placement_records = {}
local placement_key_cache = {}
local placement_key_prev = {}
local placement_keyboard_armed = false
local placement_arm_at_ticks = 0
local placement_autotest_stage = 0
local placement_autotest_next_ticks = 0
local placement_autotest_target_scene = -1
local placement_autotest_preview_snapped = false
local placement_textures = {}

local function r16(addr)
    if not space or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(addr) end)
    return ok and v or 0
end

local function r32(addr)
    if not space or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u32(addr) end)
    return ok and v or 0
end

local function w16(addr, value)
    if not space or addr == 0 then return end
    pcall(function() space:write_u16(addr, value & 0xffff) end)
end

local function w32(addr, value)
    if not space or addr == 0 then return end
    pcall(function() space:write_u32(addr, value & 0xffffffff) end)
end

local function maincpu_region()
    if rom_region then return rom_region end
    local candidates = { ":maincpu", "maincpu" }
    for _, tag in ipairs(candidates) do
        local ok, region = pcall(function() return manager.machine.memory.regions[tag] end)
        if ok and region then
            rom_region = region
            rom_region_tag = tag
            log("maincpu_region tag=%s size=0x%x", tag, region.size or 0)
            return region
        end
    end
    return nil
end

local function rom_offset_for_bit_addr(bit_addr)
    return (bit_addr - PROGRAM_ROM_BASE) // 8
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, value = pcall(function() return item.value end)
    if okv then return value end
    okv, value = pcall(function() return item() end)
    if okv then return value end
    return nil
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(0) end)
    if ok and s then return s end
    return nil
end

function load_kheart_textures()
    local root = os.getenv("MK2_ROOT") or "."
    root = root:gsub("\\", "/")
    local labels = {
        "KHEART1", "KHEART2", "KHEART3A", "KHEART3B", "KHEART3C",
        "KHEART4", "KHEART5A", "KHEART5B", "KHEART5C",
        "KHEART6A", "KHEART6B", "KHEART6C", "KHEART6D",
    }
    for _, label in ipairs(labels) do
        local path = string.format("%s/tools/jc_kheart_frames/%s.png", root, label)
        local file = io.open(path, "rb")
        if file then
            local data = file:read("*a")
            file:close()
            local ok, bitmap = pcall(function() return emu.bitmap_argb32.load(data) end)
            if ok and bitmap then
                local tex_ok, texture = pcall(function()
                    return manager.machine.render:texture_alloc(bitmap)
                end)
                if tex_ok and texture then
                    placement_textures[label] = {
                        bitmap = bitmap,
                        texture = texture,
                        width = bitmap.width,
                        height = bitmap.height,
                    }
                end
            end
        end
    end
    log("placement textures loaded=%d", set_count(placement_textures))
end

function free_kheart_textures()
    for _, item in pairs(placement_textures) do
        pcall(function() item.texture:free() end)
    end
    placement_textures = {}
end

function draw_kheart_preview()
    if not placement_paused or placement_scene < 0 then return end
    local rec = placement_records[placement_scene]
    if not rec or not rec.present then return end
    local item = placement_textures[rec.kheart_label]
    local screen = main_screen()
    if not item or not screen then return end
    local container = screen.container
    if not container then return end

    local world_left = r16(A.worldtlx + 16)
    if world_left == 0xffff then world_left = 0 end
    local x0 = (rec.final_x - world_left) / 400.0
    local y0 = rec.final_y / 254.0
    local x1 = x0 + (item.width / 400.0)
    local y1 = y0 + (item.height / 254.0)

    container:draw_box(0.0, 0.0, 1.0, 1.0, 0x00000000, 0x68000000)
    container:draw_quad(item.texture, x0, y0, x1, y1, 0xffffffff)
    container:draw_box(x0, y0, x1, y1, 0xffffff00, 0x00000000)
end

local function snap(label)
    local effects = effect_label_summary and effect_label_summary() or "effects=pending"
    -- register_frame runs before MAME has presented the newly rendered page.
    -- MK2 alternates its two screen pages, so taking the bitmap here captures
    -- the cleared back page every other tick and falsely looks like a blink.
    -- Defer to register_frame_done, after the display page is complete.
    table.insert(pending_snapshots, {
        file_index = snapshot_index,
        frame = frame,
        label = label,
        effects = effects,
    })
    log("SNAPQUEUED file=%04d.png frame=%d label=%s %s", snapshot_index, frame, label, effects)
    snapshot_index = snapshot_index + 1
end

local function flush_snapshots()
    if #pending_snapshots == 0 then return end
    local video = manager.machine.video
    if not video then
        for _, req in ipairs(pending_snapshots) do
            log("SNAP frame=%d label=%s no_video", req.frame, req.label)
        end
        pending_snapshots = {}
        return
    end
    for _, req in ipairs(pending_snapshots) do
        log("SNAPMAP file=%04d.png label=%s %s", req.file_index, req.label, req.effects)
        local ok, err = pcall(function() video:snapshot() end)
        log("SNAP frame=%d label=%s ok=%s %s", req.frame, req.label, tostring(ok), ok and "" or tostring(err))
    end
    pending_snapshots = {}
end

local function auto_snap(label)
    if not TARGETED_SNAPSHOTS_ONLY then
        snap(label)
    end
end

local function draw_line(y, text)
    if not HUD_ENABLED then return end
    local s = main_screen()
    if not s then return end
    local ok = pcall(function()
        s:draw_text(4, y, text, 0xffffffff, 0x80000000)
    end)
    if not ok and not overlay_warned then
        overlay_warned = true
        log("screen draw_text unavailable; HUD disabled")
    end
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Up"] = true,
        ["P1 Down"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
        ["P2 High Punch"] = true,
        ["P2 Left"] = true,
        ["P2 Right"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

local function count_list(head_addr)
    local p = r32(head_addr)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = r32(p + O.next)
    end
    return count
end

local function count_process_id(pid)
    local p = r32(A.active)
    local count = 0
    local guard = 0
    while p ~= 0 and guard < 256 do
        if r16(p + P.id) == pid then count = count + 1 end
        p = r32(p + P.next)
        guard = guard + 1
    end
    return count
end

local function active_contains(ptr)
    if ptr == 0 then return false end
    local p = r32(A.active)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if p == ptr then return true end
        p = r32(p + P.next)
        guard = guard + 1
    end
    return false
end

local function proc_brief(ptr)
    if ptr == 0 then return "proc=0" end
    return string.format(
        "proc=%s id=0x%04x next=%s time=%d wake=%s psptr=%s pa9=%s act=0x%04x flags=0x%04x",
        hx(ptr), r16(ptr + P.id), hx(r32(ptr + P.next)), r16(ptr + P.time),
        hx(r32(ptr + P.wake)), hx(r32(ptr + P.psptr)), hx(r32(ptr + P.pa9)),
        r16(ptr + P.action), r16(ptr + P.flags))
end

local function dump_active(label, limit)
    local p = r32(A.active)
    local i = 0
    log("active %s head=%s", label, hx(p))
    while p ~= 0 and i < (limit or 16) do
        log("active %s #%02d %s", label, i, proc_brief(p))
        p = r32(p + P.next)
        i = i + 1
    end
end

local function dump_queue(addr, label)
    local nextp = r32(addr)
    log("%s queue=%s next=%s", label, hx(addr), hx(nextp))
    local p = nextp
    for i = 1, 6 do
        p = p - 32
        if p <= addr then p = addr + 32 * 20 end
        local v = r32(p)
        local sw = (v >> 16) & 0xffff
        local t = v & 0xffff
        log("%s q-%d ptr=%s raw=%s sw=%d tick=%d age=%d",
            label, i, hx(p), hx(v), sw, t, (r16(A.tick) - t) & 0xffff)
    end
end

local function force_stage_context()
    w16(A.curback, STAGE_ID)
    if not did_stage_context then
        did_stage_context = true
        log("stage_context frame=%d stage=%s(%d) round=%d matchw=%d/%d map_position=%d battle=%d",
            frame, STAGE_NAME, STAGE_ID, r16(A.round_num), r16(A.p1_matchw), r16(A.p2_matchw),
            r16(A.map_position), r16(A.battle_num))
    end
end

local function force_match_select()
    w16(ATTACKER.char, FT_CAGE)
    w16(VICTIM.char, FT_VICTIM)
    force_stage_context()
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select frame=%d attacker=%s Cage victim=%s %s(%d) p1=%d p2=%d p1_state=%d p2_state=%d curback=%d",
            frame, ATTACKER.name, VICTIM.name, VICTIM_NAME, FT_VICTIM,
            r16(A.p1_char), r16(A.p2_char), r16(A.p1_state), r16(A.p2_state), r16(A.curback))
    end
end

local function position_for_fatality()
    local p1obj = r32(A.p1_obj)
    local p2obj = r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local world_left = r16(A.worldtlx + 16)
    if world_left == 0xffff then world_left = 0 end
    local p1x = world_left + 136
    local p2x = p1x + 0x38
    local p1y = r16(p1obj + O.oypos)
    local p2y = r16(p2obj + O.oypos)
    local p1proc = r32(A.p1_proc)
    local p2proc = r32(A.p2_proc)
    if p1y == 0 and p1proc ~= 0 then p1y = r16(p1proc + P.ganiy) end
    if p2y == 0 and p2proc ~= 0 then p2y = r16(p2proc + P.ganiy) end
    w16(p1obj + O.oxpos, p1x)
    w32(p1obj + O.oxval, p1x << 16)
    w32(p1obj + O.oxvel, 0)
    w32(p1obj + O.oyvel, 0)
    w16(p2obj + O.oxpos, p2x)
    w32(p2obj + O.oxval, p2x << 16)
    w32(p2obj + O.oxvel, 0)
    w32(p2obj + O.oyvel, 0)
    if p1y ~= 0 then
        w16(p1obj + O.oypos, p1y)
        w32(p1obj + O.oyval, p1y << 16)
        if p1proc ~= 0 then w16(p1proc + P.ganiy, p1y) end
    end
    if p2y ~= 0 then
        w16(p2obj + O.oypos, p2y)
        w32(p2obj + O.oyval, p2y << 16)
        if p2proc ~= 0 then w16(p2proc + P.ganiy, p2y) end
    end
end

local function normalize_player_links()
    local p1obj = r32(A.p1_obj)
    local p2obj = r32(A.p2_obj)
    local p1proc = r32(A.p1_proc)
    local p2proc = r32(A.p2_proc)
    if p1proc ~= 0 and p2proc ~= 0 and p1obj ~= 0 and p2obj ~= 0 then
        w32(p1proc + P.otherguy, p2obj)
        w32(p1proc + P.otherproc, p2proc)
        w32(p1proc + P.store4, p1proc)
        w32(p2proc + P.otherguy, p1obj)
        w32(p2proc + P.otherproc, p1proc)
        w32(p2proc + P.store4, p2proc)
    end
end

local function clear_blocking_flags(proc)
    if proc == 0 then return end
    local flags = r16(proc + P.flags)
    flags = flags & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL)
    w16(proc + P.flags, flags)
end

local pstate_summary

local function force_round1_win()
    if fight_count ~= 1 or fighting_frame == 0 or did_force_round1 then return end
    local rel = frame - fighting_frame
    if rel < 120 then return end

    did_force_round1 = true
    round1_forced_frame = frame
    position_for_fatality()
    normalize_player_links()
    w16(VICTIM.bar, 0)
    w16(VICTIM.bar_view, 0)
    w16(A.winner_status, 3)
    log("round1_forced frame=%d rel=%d %s", frame, rel, pstate_summary())
    auto_snap("round1_forced")
end

local function force_finish_him()
    if fight_count ~= 2 or fighting_frame == 0 or r16(A.f_death) == 2 then return end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 620 then return end

    w16(A.winner_status, 3)
    w16(A.f_death, 0)
    -- Suppress blood only after the fatality state starts; setting this
    -- during Finish Him prevents the fatality trigger itself.
    w16(A.f_no_blood, 0)
    w16(A.f_no_violence, 0)
    w16(ATTACKER.bar, MAX_HP)
    w16(ATTACKER.bar_view, MAX_HP)
    w16(VICTIM.bar, 0)
    w16(VICTIM.bar_view, 0)

    local victim_proc = r32(VICTIM.proc)
    normalize_player_links()
    local attacker_proc = r32(ATTACKER.proc)
    if attacker_proc ~= 0 then
        clear_blocking_flags(attacker_proc)
        w16(attacker_proc + P.action, ACT_STANCE)
    end
    position_for_fatality()

    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        log("finish_him_forced frame=%d rel=%d attacker=%s victim=%s victim_wake=%s dizzy_dude=%s dizzy=%s",
            frame, rel, ATTACKER.name, VICTIM.name,
            hx(victim_proc ~= 0 and r32(victim_proc + P.wake) or 0), hx(A.dizzy_dude), hx(A.dizzy))
        auto_snap("finish_him_forced")
    end
end

local function victim_ready_for_fatality()
    local victim_proc = r32(VICTIM.proc)
    if victim_proc == 0 then return false end
    local wake = r32(victim_proc + P.wake)
    local in_dizzy_loop = wake >= A.dizzy and wake < (A.dizzy + 0x120)
    return in_dizzy_loop and r16(victim_proc + P.action) == ACT_STUNNED
end

-- The retail input for the headhole fatality is Forward, Back, Back + HP
-- (scom_jc_headhole, MOVES.ASM:9442; 038h = 56 ticks for the whole switch
-- combo).  The old HP-only path in this rig went through jc_headhole_hp_test,
-- which is `.set 0` in MAINEQU.ASM and marked retired - so on any shipped ROM
-- the rig could never trigger the fatality, no matter how long it waited.
--
-- position_for_fatality() puts the attacker 0x38 apart from the victim, inside
-- the 060h punch range the dispatch gates on, so only the input needed fixing.
-- One table, not seven locals: the main chunk is near Lua's 200-local ceiling.
JC_RI = {                                                 -- global on purpose
    on = os.getenv("JC_HEADHOLE_RETAIL_INPUT") ~= "0",
    tap = getenv_int("JC_HEADHOLE_TAP_FRAMES", 5),        -- frames held per tap
    retry = getenv_int("JC_HEADHOLE_SEQ_RETRY", 70),      -- frames before retrying
    start = 0,
    attempts = 0,
}

-- Chronological (oldest first), the reverse of how the combo table reads.
-- Odd slots are the releases between taps.
function JC_RI.token(rel)
    local slot = rel // JC_RI.tap
    if slot == 0 then return "fwd" end
    if slot == 2 or slot == 4 then return "back" end
    if slot == 6 then return "hp" end
    return nil
end

-- Facing is not read back: position_for_fatality() always puts P1 on the left,
-- so the attacker's Forward is toward the other player.
function JC_RI.dir(which)
    local toward_right = (ATTACKER.side == 1)
    if which == "fwd" then
        return toward_right and ATTACKER.right or ATTACKER.left
    end
    return toward_right and ATTACKER.left or ATTACKER.right
end

local function fatality_input_active(name)
    if finish_forced_frame == 0 then return false end
    if not victim_ready_for_fatality() then return false end
    if dizzy_ready_frame == 0 then dizzy_ready_frame = frame end
    if KHEART_PLACEMENT_ENABLED then
        return placement_start_requested and fatality_frame == 0 and name == ATTACKER.high_punch
    end

    if JC_RI.on then
        if fatality_frame ~= 0 then return false end
        if JC_RI.start == 0 then
            JC_RI.start = frame + HP_TRIGGER_START
            JC_RI.attempts = 1
            log("retail combo armed: Forward,Back,Back + HP  start=%d attacker=%s",
                JC_RI.start, ATTACKER.name)
        end
        local rel = frame - JC_RI.start
        if rel < 0 then return false end
        if rel >= JC_RI.tap * 7 + JC_RI.retry then    -- it did not take; go again
            JC_RI.attempts = JC_RI.attempts + 1
            JC_RI.start = frame
            log("retail combo retry #%d at frame=%d", JC_RI.attempts, frame)
            return false
        end
        local token = JC_RI.token(rel)
        if token == nil then return false end
        if token == "hp" then return name == ATTACKER.high_punch end
        return name == JC_RI.dir(token)
    end

    local rel = frame - dizzy_ready_frame
    if rel >= HP_TRIGGER_START and rel < HP_TRIGGER_START + HP_TRIGGER_LEN then
        return name == ATTACKER.high_punch
    end
    return false
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if fatality_input_active(name) then
        if not did_input_snap then
            did_input_snap = true
            log("hp_trigger_input frame=%d finish_rel=%d", frame, frame - finish_forced_frame)
            auto_snap("hp_trigger_input")
        end
        return true
    end

    return false
end

function pstate_summary()
    local p1obj = r32(A.p1_obj)
    local p2obj = r32(A.p2_obj)
    local p1proc = r32(A.p1_proc)
    local p2proc = r32(A.p2_proc)
    local p1live = active_contains(p1proc) and 1 or 0
    local p2live = active_contains(p2proc) and 1 or 0
    local p1act = p1proc ~= 0 and r16(p1proc + P.action) or 0xffff
    local p1flags = p1proc ~= 0 and r16(p1proc + P.flags) or 0xffff
    local p1pa9 = p1proc ~= 0 and r32(p1proc + P.pa9) or 0
    local p1time = p1proc ~= 0 and r16(p1proc + P.time) or 0xffff
    local p1wake = p1proc ~= 0 and r32(p1proc + P.wake) or 0
    local p1psptr = p1proc ~= 0 and r32(p1proc + P.psptr) or 0
    local p1store4 = p1proc ~= 0 and r32(p1proc + P.store4) or 0
    local p2time = p2proc ~= 0 and r16(p2proc + P.time) or 0xffff
    local p2wake = p2proc ~= 0 and r32(p2proc + P.wake) or 0
    local p2psptr = p2proc ~= 0 and r32(p2proc + P.psptr) or 0
    local p2ganiy = p2proc ~= 0 and r16(p2proc + P.ganiy) or 0xffff
    local p2act = p2proc ~= 0 and r16(p2proc + P.action) or 0xffff
    local p2pa9 = p2proc ~= 0 and r32(p2proc + P.pa9) or 0
    local p2flags = p2proc ~= 0 and r16(p2proc + P.flags) or 0xffff
    local p1x, p1y, p1sag, p1char = 0, 0, 0, 0xffff
    local p2x, p2y, p2sag, p2char, p2yvel = 0, 0, 0, 0xffff, 0
    if p1obj ~= 0 then
        p1x = r16(p1obj + O.oxpos)
        p1y = r16(p1obj + O.oypos)
        p1char = r16(p1obj + O.ochar)
        local img = r32(p1obj + O.oimg)
        if img ~= 0 then p1sag = r32(img) end
    end
    if p2obj ~= 0 then
        p2x = r16(p2obj + O.oxpos)
        p2y = r16(p2obj + O.oypos)
        p2char = r16(p2obj + O.ochar)
        p2yvel = r32(p2obj + O.oyvel)
        local img = r32(p2obj + O.oimg)
        if img ~= 0 then p2sag = r32(img) end
    end
    return string.format(
        "gs=%d stage=%d round=%d mw=%d/%d ws=%d fdeath=0x%04x noblood=%d noviol=%d p1=%d/%d p2=%d/%d p1live=%d p2live=%d p1time=%d p2time=%d p1wake=%s p1psptr=%s p2wake=%s p2psptr=%s act=0x%04x pflags=0x%04x p2act=0x%04x p2flags=0x%04x pa9=%s p2pa9=%s p1store4=%s p1xy=%d,%d p2xy=%d,%d p2ganiy=%d p2yvel=%s p1sag=%s p2sag=%s obj=%d/%d/%d fx=%d pc=%s pf=%s",
        r16(A.gstate), r16(A.curback), r16(A.round_num), r16(A.p1_matchw), r16(A.p2_matchw),
        r16(A.winner_status), r16(A.f_death), r16(A.f_no_blood), r16(A.f_no_violence),
        r16(A.p1_char), p1char, r16(A.p2_char), p2char,
        p1live, p2live, p1time, p2time, hx(p1wake), hx(p1psptr), hx(p2wake), hx(p2psptr),
        p1act, p1flags, p2act, p2flags, hx(p1pa9), hx(p2pa9), hx(p1store4),
        p1x, p1y, p2x, p2y, p2ganiy, hx(p2yvel), hx(p1sag), hx(p2sag),
        count_list(A.objlst), count_list(A.objlst2), count_list(A.objlst3),
        count_process_id(PID_FX),
        hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")), hx(r32(A.pf_ram)))
end

local function log_process_liveness(label)
    local attacker_proc = r32(ATTACKER.proc)
    local victim_proc = r32(VICTIM.proc)
    local attacker_live = active_contains(attacker_proc)
    local victim_live = active_contains(victim_proc)
    log("live %s attacker(%s)=%s live=%s victim(%s)=%s live=%s fx=%d",
        label, ATTACKER.name, proc_brief(attacker_proc), tostring(attacker_live),
        VICTIM.name, proc_brief(victim_proc), tostring(victim_live),
        count_process_id(PID_FX))
    if last_attacker_live == nil or last_attacker_live ~= attacker_live then
        last_attacker_live = attacker_live
        dump_active(label .. "_attacker_live_change", 18)
    end
end

local function log_attack_frame_probe(label)
    local proc = r32(ATTACKER.proc)
    local obj = r32(ATTACKER.obj)
    local psptr = proc ~= 0 and r32(proc + P.psptr) or 0
    local pa8 = proc ~= 0 and r32(proc + P.pa8) or 0
    local pa9 = proc ~= 0 and r32(proc + P.pa9) or 0
    local shape = obj ~= 0 and r32(obj + O.oshape) or 0
    local img = obj ~= 0 and r32(obj + O.oimg) or 0
    local pa8_shape = pa8 ~= 0 and r32(pa8 + O.oshape) or 0
    local pa8_img = pa8 ~= 0 and r32(pa8 + O.oimg) or 0
    local pa8_sag = pa8_img ~= 0 and r32(pa8_img + MP_SAG) or 0
    local first_hdr = shape ~= 0 and r32(shape) or 0
    local first_sag = img ~= 0 and r32(img + MP_SAG) or 0
    local stack0 = psptr ~= 0 and r32(psptr) or 0
    local stack1 = psptr ~= 0 and r32(psptr + 0x20) or 0
    local stack2 = psptr ~= 0 and r32(psptr + 0x40) or 0
    local stack3 = psptr ~= 0 and r32(psptr + 0x60) or 0
    local entry = pa9 ~= 0 and r32(pa9) or 0
    local prev_entry = pa9 ~= 0 and r32(pa9 - 0x20) or 0
    log("probe %s %s obj=%s shape=%s first_hdr=%s first_sag=%s osag=%s pa8=%s pa8_shape=%s pa8_sag=%s pa9_entry=%s pa9_prev=%s dbg=%d,%s,%s,%s stack=%s,%s,%s,%s",
        label, proc_brief(proc), hx(obj), hx(shape), hx(first_hdr), hx(first_sag),
        obj ~= 0 and hx(r32(obj + O.osag)) or hx(0),
        hx(pa8), hx(pa8_shape), hx(pa8_sag),
        hx(entry), hx(prev_entry),
        r16(A.debug1), hx(r32(A.debug2)), hx(r32(A.debug3)), hx(r32(A.debug4)),
        hx(stack0), hx(stack1), hx(stack2), hx(stack3))
end

local function attacker_current_sag()
    local obj = r32(ATTACKER.obj)
    if obj == 0 then return 0 end
    local img = r32(obj + O.oimg)
    if img == 0 then return 0 end
    return r32(img + MP_SAG) & 0x00ffffff
end

local function obj_sag(obj)
    if obj == 0 then return 0 end
    local osag = r32(obj + O.osag) & 0x00ffffff
    if headhole_sags[osag] then return osag end
    local img = r32(obj + O.oimg)
    if img == 0 then return 0 end
    return r32(img + MP_SAG) & 0x00ffffff
end

local function palette_brief(obj)
    if obj == 0 then return "pal_live=-" end
    local slot = r16(obj + O.opal) & 0xff
    local base = COLRAM + slot * PAL_STRIDE
    local nonzero = 0
    local sum = 0
    local xors = 0
    local first_colors = {}
    for i = 0, 63 do
        local value = r16(base + i * 0x10)
        if value ~= 0 then nonzero = nonzero + 1 end
        sum = (sum + value) & 0xffffffff
        xors = (xors ~ value) & 0xffff
        if i < 16 then first_colors[#first_colors + 1] = string.format("%04x", value) end
    end
    local alloc = A.palram + slot * 0x40
    return string.format("pal_live=slot%d nz%d sum%s xor0x%04x id%s cnt%d p0=%s",
        slot, nonzero, hx(sum), xors, hx(r32(alloc)), r16(alloc + 0x20),
        table.concat(first_colors, ":"))
end

-- ---------------------------------------------------------------------
-- Amulet fade watch.  death_blow_fader (MKDEATH) fades every palette in
-- palram EXCEPT those named in death_fade_excludes (MKGUYS), matching on
-- the palette's ID - the ROM address getfpal was called with.  The win
-- amulets under the life bars are drawn from AMULET_P, claimed by
-- get_amulet_pal, and AMULET_P was not on that list, so they dimmed
-- through every fatality while the life bar beside them stayed lit.
--
-- This rig is the right place to see it: round 1 is played for real, so
-- p1_matchw is genuinely 1 and update_knotches has genuinely stamped an
-- amulet, and round 2 ends in a real fatality.
--
-- "Unchanged" on its own proves nothing - if the fade never ran, nothing
-- would change either.  So every allocated slot is sampled, and a pass
-- needs BOTH halves: the amulet slot identical, and some other slot
-- visibly darker.  The control is the evidence the fade happened at all.
--
-- One table, not a dozen upvalues: the main chunk is near Lua's 200-local
-- ceiling and adding loose locals here overflows it.
local AM = {
    pal = sym("SCORE2_P", 0),
    base = nil, slot = -1, moved_at = 0, others = 0, verdict = "not-run",
}

function AM.cram_sum(slot)
    local base = COLRAM + slot * PAL_STRIDE
    local sum = 0
    for i = 0, 63 do sum = (sum + r16(base + i * 0x10)) & 0xffffffff end
    return sum
end

function AM.begin()
    AM.base, AM.slot = {}, -1
    for slot = 0, 79 do
        local alloc = A.palram + slot * 0x40
        if r16(alloc + 0x20) ~= 0 then          -- palcnt: slot is in use
            local id = r32(alloc)
            AM.base[slot] = { id = id, sum = AM.cram_sum(slot) }
            if id == AM.pal then AM.slot = slot end
        end
    end
    log("amulet watch armed SCORE2_P=%s slot=%d allocated=%d",
        hx(AM.pal), AM.slot, set_count(AM.base))
    if AM.slot < 0 then
        AM.verdict = string.format(
            "SKIP no amulet on screen (p1_matchw=%d p2_matchw=%d)",
            r16(A.p1_matchw), r16(A.p2_matchw))
    end
end

function AM.step()
    if AM.base == nil then return end
    for slot, e in pairs(AM.base) do
        -- only compare a slot still holding the palette it held at arm time
        if r32(A.palram + slot * 0x40) == e.id then
            local now = AM.cram_sum(slot)
            if now ~= e.sum then
                if slot == AM.slot then
                    if AM.moved_at == 0 then
                        AM.moved_at = frame
                        log("amulet DIMMED frame=%d slot=%d sum %s -> %s",
                            frame, slot, hx(e.sum), hx(now))
                    end
                elseif not e.counted then
                    e.counted = true
                    AM.others = AM.others + 1
                end
            end
        end
    end
end

function AM.report()
    if AM.base ~= nil and AM.slot >= 0 then
        if AM.others == 0 then
            AM.verdict = "NO-VERDICT fade never ran (no slot changed) - " ..
                "the amulet holding still proves nothing here"
        elseif AM.moved_at > 0 then
            AM.verdict = string.format(
                "FAIL amulet dimmed at frame %d (%d other slots faded)",
                AM.moved_at, AM.others)
        else
            AM.verdict = string.format(
                "PASS amulet slot %d held its colours while %d other slots faded",
                AM.slot, AM.others)
        end
    end
    log("amulet VERDICT %s", AM.verdict)
end


local function obj_brief(obj)
    if obj == 0 then return "obj=0" end
    local img = r32(obj + O.oimg)
    local shape = r32(obj + O.oshape)
    local sag_img = img ~= 0 and (r32(img + MP_SAG) & 0x00ffffff) or 0
    local sag_obj = r32(obj + O.osag) & 0x00ffffff
    local label = readout_sag_labels[sag_img] or readout_sag_labels[sag_obj] or headhole_sags[sag_img] or headhole_sags[sag_obj] or ""
    return string.format(
        "obj=%s next=%s label=%s sag_img=%s sag_obj=%s img=%s shape=%s xy=%d,%d val=%s,%s z=%s pal=0x%04x flags=0x%04x flags2=0x%04x char=%d %s",
        hx(obj), hx(r32(obj + O.next)), label ~= "" and label or "-",
        hx(sag_img), hx(sag_obj), hx(img), hx(shape), r16(obj + O.oxpos), r16(obj + O.oypos),
        hx(r32(obj + O.oxval)), hx(r32(obj + O.oyval)), hx(r32(obj + O.ozval)),
        r16(obj + O.opal), r16(obj + O.oflags), r16(obj + O.oflags2), r16(obj + O.ochar),
        palette_brief(obj))
end

local function dump_object_list(head, label, rel)
    local p = r32(head)
    local guard = 0
    log("objdump rel=%d list=%s head=%s first=%s", rel, label, hx(head), hx(p))
    while p ~= 0 and guard < 32 do
        log("objdump rel=%d list=%s #%02d %s", rel, label, guard, obj_brief(p))
        p = r32(p + O.next)
        guard = guard + 1
    end
end

local function dump_effect_processes(rel)
    local p = r32(A.active)
    local guard = 0
    while p ~= 0 and guard < 256 do
        local pid = r16(p + P.id)
        if pid == PID_FX or pid == PID_HEAD then
            local pa8 = r32(p + P.pa8)
            local pa9 = r32(p + P.pa9)
            local pa10 = r32(p + P.pa10)
            log("effectproc rel=%d pid=0x%04x %s pa8=%s %s pa9=%s pa9val=%s pa10=%s %s",
                rel, pid, proc_brief(p), hx(pa8), obj_brief(pa8), hx(pa9), hx(r32(pa9)),
                hx(pa10), obj_brief(pa10))
        end
        p = r32(p + P.next)
        guard = guard + 1
    end
end

local function maybe_dump_headhole_objects(rel)
    if not READOUT_ENABLED then return end
    if not SNAPSHOT_RELS[rel] and not ({ [35] = true, [40] = true, [45] = true, [90] = true, [95] = true, [110] = true })[rel] then return end
    if readout_objdump_seen[rel] then return end
    readout_objdump_seen[rel] = true
    dump_object_list(A.objlst, "objlst", rel)
    dump_object_list(A.objlst2, "objlst2", rel)
    dump_object_list(A.objlst3, "objlst3", rel)
    dump_effect_processes(rel)
end

local function find_headhole_obj()
    local lists = { A.objlst, A.objlst2, A.objlst3 }
    for _, head in ipairs(lists) do
        local p = r32(head)
        local guard = 0
        while p ~= 0 and guard < 256 do
            local sag = obj_sag(p)
            if headhole_sags[sag] then
                return p, sag, headhole_sags[sag]
            end
            p = r32(p + O.next)
            guard = guard + 1
        end
    end
    return 0, 0, ""
end

effect_label_summary = function()
    local kheart = "-"
    local spill = "-"
    local head = "-"
    local blood = {}
    local lists = { A.objlst, A.objlst2, A.objlst3 }
    for _, list in ipairs(lists) do
        local p = r32(list)
        local guard = 0
        while p ~= 0 and guard < 256 do
            local sag_obj = r32(p + O.osag) & 0x00ffffff
            local img = r32(p + O.oimg)
            local sag_img = img ~= 0 and (r32(img + MP_SAG) & 0x00ffffff) or 0
            local label = readout_sag_labels[sag_obj] or readout_sag_labels[sag_img]
                or headhole_sags[sag_obj] or headhole_sags[sag_img] or ""
            if label:match("^KHEART") then
                kheart = label
            elseif label:match("^SPILL") then
                spill = label
            elseif label:match("HEADHOLE") or label:match("DEADHEAD") then
                head = label
            elseif label:match("^JCSTAB") or label:match("^JCSPLAT")
                or label:match("^STAB%d+$") or label:match("^SPLAT%d+$") then
                blood[#blood + 1] = label
            end
            p = r32(p + O.next)
            guard = guard + 1
        end
    end
    return string.format("K=%s S=%s B=%s H=%s",
        kheart, spill, #blood > 0 and table.concat(blood, "/") or "-", head)
end

function find_kheart_obj()
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag_obj = r32(obj + O.osag) & 0x00ffffff
            local img = r32(obj + O.oimg)
            local sag_img = img ~= 0 and (r32(img + MP_SAG) & 0x00ffffff) or 0
            local label = readout_sag_labels[sag_obj] or readout_sag_labels[sag_img] or ""
            if label:match("^KHEART") then
                return obj, label, sag_obj ~= 0 and sag_obj or sag_img
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return 0, "", 0
end

function placement_freeze_processes()
    if #placement_frozen_process_times > 0 then return end
    placement_frozen_process_times = {}
    local proc = r32(A.active)
    local guard = 0
    while proc ~= 0 and guard < 256 do
        local pid = r16(proc + P.id)
        if pid == 1 or pid == 2 or pid == PID_FX or pid == PID_HEAD then
            placement_frozen_process_times[#placement_frozen_process_times + 1] = {
                proc = proc,
                time = r16(proc + P.time),
            }
            w16(proc + P.time, 0x7fff)
        end
        proc = r32(proc + P.next)
        guard = guard + 1
    end
end

function placement_restore_processes()
    for _, saved in ipairs(placement_frozen_process_times) do
        w16(saved.proc + P.time, saved.time)
    end
    placement_frozen_process_times = {}
end

function placement_hold_processes()
    for _, saved in ipairs(placement_frozen_process_times) do
        w16(saved.proc + P.time, 0x7fff)
    end
end

function placement_expected(scene)
    if scene < 0 then return "PRE-FATALITY" end
    -- The placement editor remains a coarse five-tick companion-art sampler.
    -- It is not an authored attacker-frame editor.
    local label = dblo2_at_rel(scene * 5)
    return label or "VICTORY/HOLD"
end

function placement_write_files()
    if not KHEART_PLACEMENT_ENABLED then return end
    local csv = io.open(KHEART_PLACEMENT_CSV_PATH, "w")
    if csv then
        csv:write("scene_frame,fatality_rel,scene_label,kheart_label,present,base_world_x,base_world_y,final_world_x,final_world_y,delta_x,delta_y,last_reason\n")
        for scene = 0, placement_max_scene do
            local rec = placement_records[scene]
            if rec then
                csv:write(string.format("%d,%d,%s,%s,%d,%d,%d,%d,%d,%d,%d,%s\n",
                    scene, scene * 5, rec.scene_label, rec.kheart_label,
                    rec.present and 1 or 0, rec.base_x, rec.base_y, rec.final_x,
                    rec.final_y, rec.final_x - rec.base_x, rec.final_y - rec.base_y,
                    rec.reason or "capture"))
            end
        end
        csv:close()
    end

    local txt = io.open(KHEART_PLACEMENT_TXT_PATH, "w")
    if txt then
        txt:write("Johnny Cage KHEART interactive placement\n")
        txt:write("One row per complete authored scene frame. Coordinates are KHEART object world positions.\n")
        txt:write("Controls: arrows move KHEART; Space or S commits/advances; A commits/goes back; Esc exits.\n\n")
        for scene = 0, placement_max_scene do
            local rec = placement_records[scene]
            if rec then
                txt:write(string.format(
                    "scene=%02d rel=%03d scene_label=%-14s kheart=%-10s present=%d base=(%d,%d) final=(%d,%d) delta=(%d,%d) reason=%s\n",
                    scene, scene * 5, rec.scene_label, rec.kheart_label ~= "" and rec.kheart_label or "-",
                    rec.present and 1 or 0, rec.base_x, rec.base_y, rec.final_x,
                    rec.final_y, rec.final_x - rec.base_x, rec.final_y - rec.base_y,
                    rec.reason or "capture"))
            end
        end
        txt:close()
    end
end

function placement_init_record(scene, reason)
    if scene < 0 then return end
    local obj, label = find_kheart_obj()
    local present = obj ~= 0
    local x = present and r16(obj + O.oxpos) or 0
    local y = present and r16(obj + O.oypos) or 0
    if not placement_baselines[scene] then
        placement_baselines[scene] = { x = x, y = y, label = label, present = present }
    end
    local base = placement_baselines[scene]
    if not placement_records[scene] then
        placement_records[scene] = {
            scene_label = placement_expected(scene),
            kheart_label = label,
            present = present,
            base_x = base.x,
            base_y = base.y,
            final_x = x,
            final_y = y,
            reason = reason or "capture",
        }
    end
    placement_write_files()
end

function placement_apply_record()
    local rec = placement_records[placement_scene]
    if not rec or not rec.present then return false end
    local obj, label = find_kheart_obj()
    if obj == 0 then return false end
    rec.kheart_label = label
    w16(obj + O.oxpos, rec.final_x)
    w32(obj + O.oxval, rec.final_x << 16)
    w16(obj + O.oypos, rec.final_y)
    w32(obj + O.oyval, rec.final_y << 16)
    return true
end

function placement_restore_base()
    local rec = placement_records[placement_scene]
    if not rec or not rec.present then return end
    local obj = find_kheart_obj()
    if obj == 0 then return end
    w16(obj + O.oxpos, rec.base_x)
    w32(obj + O.oxval, rec.base_x << 16)
    w16(obj + O.oypos, rec.base_y)
    w32(obj + O.oyval, rec.base_y << 16)
end

function placement_render_preview()
    placement_apply_record()
end

function placement_commit(reason)
    if placement_scene < 0 then return end
    placement_init_record(placement_scene, reason)
    local rec = placement_records[placement_scene]
    rec.reason = reason or "commit"
    placement_write_files()
    log("placement commit scene=%d rel=%d kheart=%s final=%d,%d delta=%d,%d reason=%s",
        placement_scene, placement_scene * 5,
        rec.kheart_label ~= "" and rec.kheart_label or "-", rec.final_x, rec.final_y,
        rec.final_x - rec.base_x, rec.final_y - rec.base_y, rec.reason)
end

function placement_capture_scene(scene)
    if placement_buffers[scene] then
        placement_scene = scene
        placement_advancing = false
        placement_advance_remaining = 0
        placement_paused = true
        placement_keyboard_armed = false
        placement_arm_at_ticks = emu.osd_ticks() + (emu.osd_ticks_per_second() // 2)
        placement_init_record(scene, "recapture")
        placement_apply_record()
        emu.pause()
        log("placement scene=%d rel=%d reused_state=%s label=%s",
            scene, scene * 5, placement_buffers[scene], placement_expected(scene))
        return true
    end
    local generation = (placement_state_generation[scene] or 0) + 1
    placement_state_generation[scene] = generation
    local state_path = string.format("%s/scene_%02d_%02d.sta",
        KHEART_PLACEMENT_STATE_DIR, scene, generation)
    placement_buffers[scene] = state_path
    placement_scene = scene
    placement_advancing = false
    placement_advance_remaining = 0
    placement_paused = true
    placement_keyboard_armed = false
    placement_arm_at_ticks = emu.osd_ticks() + (emu.osd_ticks_per_second() // 2)
    placement_init_record(scene, "capture")
    placement_apply_record()
    local ok, err = pcall(function() manager.machine:save(state_path) end)
    if not ok then
        log("ERROR placement state_save scene=%d path=%s error=%s", scene, state_path, tostring(err))
        return false
    end
    placement_preview_needed = false
    emu.pause()
    log("placement scene=%d rel=%d state=%s label=%s",
        scene, scene * 5, state_path, placement_expected(scene))
    return true
end

function placement_schedule_load(scene, purpose)
    if placement_pending_load or not placement_buffers[scene] then return false end
    placement_pending_load = { scene = scene, purpose = purpose }
    placement_previewing = purpose == "show"
    placement_paused = true
    placement_load_issued = false
    placement_load_needs_unpause = false
    log("placement queued scene=%d rel=%d purpose=%s", scene, scene * 5, purpose)
    return true
end

function placement_issue_pending_load()
    if not KHEART_PLACEMENT_ENABLED or not placement_pending_load
        or placement_load_issued then
        return false
    end
    local pending = placement_pending_load
    local state_path = placement_buffers[pending.scene]
    local ok, err = pcall(function() manager.machine:load(state_path) end)
    placement_load_issued = ok
    if not placement_load_issued then
        log("ERROR placement issue_load scene=%d purpose=%s path=%s error=%s",
            pending.scene, pending.purpose, state_path, tostring(err))
        placement_pending_load = nil
        placement_previewing = false
        placement_paused = true
        emu.pause()
        return false
    end
    log("placement issued scene=%d rel=%d purpose=%s",
        pending.scene, pending.scene * 5, pending.purpose)
    emu.step()
    return true
end

function placement_request_preview()
    if placement_scene < 0 or placement_pending_load or placement_advancing then return end
    placement_preview_needed = false
    placement_schedule_load(placement_scene, "show")
end

function placement_load_scene(scene)
    if scene < 0 or scene > placement_max_scene or not placement_buffers[scene] then return end
    placement_commit("navigate")
    placement_keyboard_armed = false
    placement_schedule_load(scene, "show")
end

function placement_forward()
    if placement_ready then
        placement_ready = false
        placement_start_requested = true
        placement_started = true
        placement_paused = false
        placement_keyboard_armed = false
        log("placement start requested at pre-fatality pause")
        emu.unpause()
        return
    end
    if placement_scene < 0 or placement_advancing or placement_previewing or placement_pending_load then return end
    placement_commit("advance")
    local next_scene = placement_scene + 1
    if next_scene > placement_max_scene then
        log("placement final scene held scene=%d rel=%d", placement_scene, placement_scene * 5)
        return
    end
    placement_restore_base()
    if placement_buffers[next_scene] then
        placement_schedule_load(next_scene, "show")
        return
    end
    placement_advancing = true
    placement_advance_remaining = 5
    placement_step_requested = true
    placement_paused = true
    placement_keyboard_armed = false
end

function placement_back()
    if placement_ready or placement_scene <= 0 or placement_advancing or placement_previewing then return end
    placement_load_scene(placement_scene - 1)
end

function placement_key_down(token)
    local code = placement_key_cache[token]
    if not code then
        local ok, value = pcall(function() return manager.machine.input:code_from_token(token) end)
        if not ok or not value then return false end
        code = value
        placement_key_cache[token] = code
    end
    local ok, value = pcall(function() return manager.machine.input:code_pressed(code) end)
    return ok and value or false
end

function placement_key_pressed(token)
    local down = placement_key_down(token)
    local previous = placement_key_prev[token] or false
    placement_key_prev[token] = down
    return down and not previous
end

PLACEMENT_KEYS = {
    "KEYCODE_LEFT", "KEYCODE_RIGHT", "KEYCODE_UP", "KEYCODE_DOWN",
    "KEYCODE_A", "KEYCODE_S", "KEYCODE_SPACE",
}

function placement_any_key_down()
    for _, token in ipairs(PLACEMENT_KEYS) do
        if placement_key_down(token) then return true end
    end
    return false
end

function placement_move(dx, dy)
    if placement_scene < 0 then return end
    placement_init_record(placement_scene, "move")
    local rec = placement_records[placement_scene]
    if not rec or not rec.present then return end
    rec.final_x = rec.final_x + dx
    rec.final_y = rec.final_y + dy
    rec.reason = "move"
    placement_apply_record()
    placement_write_files()
    placement_preview_needed = false
end

function placement_autotest_tick()
    local now = emu.osd_ticks()
    if now < placement_autotest_next_ticks then return end
    placement_autotest_next_ticks = now + emu.osd_ticks_per_second()
    if placement_ready then
        placement_forward()
        return
    end
    if placement_scene < 0 then return end
    if placement_autotest_stage == 0 then
        local rec = placement_records[placement_scene]
        if not rec or not rec.present then
            if placement_scene < placement_max_scene then
                placement_forward()
            else
                log("ERROR placement_autotest KHEART missing through scene=%d", placement_scene)
                manager.machine:exit()
            end
            return
        end
        placement_autotest_target_scene = placement_scene
        snap("placement_autotest_before_move")
        placement_move(-30, 2)
        placement_commit("autotest_move")
        placement_autotest_stage = 1
        return
    end
    if placement_autotest_stage == 1 then
        if not placement_autotest_preview_snapped then
            placement_autotest_preview_snapped = true
            snap("placement_autotest_after_move")
            return
        end
        placement_load_scene(placement_autotest_target_scene - 1)
        placement_autotest_stage = 2
        return
    end
    if placement_autotest_stage == 2 and placement_scene == placement_autotest_target_scene - 1 then
        placement_load_scene(placement_autotest_target_scene)
        placement_autotest_stage = 3
        return
    end
    if placement_autotest_stage == 3 and placement_scene == placement_autotest_target_scene then
        local rec = placement_records[placement_autotest_target_scene]
        if rec and rec.present and rec.final_x - rec.base_x == -30 and rec.final_y - rec.base_y == 2 then
            log("PLACEMENT_AUTOTEST_PASS scene=%d kheart=%s final=%d,%d delta=-30,2",
                placement_autotest_target_scene, rec.kheart_label, rec.final_x, rec.final_y)
        else
            log("ERROR placement_autotest record_not_preserved")
        end
        placement_commit("autotest_exit")
        manager.machine:exit()
    end
end

function placement_poll_keys()
    if not KHEART_PLACEMENT_ENABLED then return end
    if placement_pending_load and not placement_load_issued then
        placement_issue_pending_load()
        return
    end
    if placement_advancing and placement_step_requested then
        placement_step_requested = false
        emu.step()
        return
    end
    if not placement_paused then return end
    if placement_previewing or placement_advancing or placement_pending_load or placement_showing then return end
    if placement_preview_needed then
        placement_request_preview()
        return
    end
    if KHEART_PLACEMENT_AUTOTEST then
        placement_autotest_tick()
        return
    end
    if not placement_keyboard_armed then
        if emu.osd_ticks() < placement_arm_at_ticks then return end
        if placement_any_key_down() then return end
        placement_keyboard_armed = true
        for _, token in ipairs(PLACEMENT_KEYS) do placement_key_prev[token] = false end
        log("placement keyboard armed scene=%d", placement_scene)
    end

    if placement_key_pressed("KEYCODE_A") then
        placement_back()
        return
    end
    if placement_key_pressed("KEYCODE_S") or placement_key_pressed("KEYCODE_SPACE") then
        placement_forward()
        return
    end

    local dx, dy = 0, 0
    if placement_key_down("KEYCODE_LEFT") then dx = dx - 1 end
    if placement_key_down("KEYCODE_RIGHT") then dx = dx + 1 end
    if placement_key_down("KEYCODE_UP") then dy = dy - 1 end
    if placement_key_down("KEYCODE_DOWN") then dy = dy + 1 end
    if dx ~= 0 or dy ~= 0 then placement_move(dx, dy) end
end

function placement_enter_ready()
    if not KHEART_PLACEMENT_ENABLED or placement_ready or placement_started then return end
    placement_ready = true
    placement_paused = true
    placement_keyboard_armed = false
    placement_arm_at_ticks = KHEART_PLACEMENT_AUTOTEST and 0
        or (emu.osd_ticks() + (emu.osd_ticks_per_second() * 8))
    emu.pause()
    log("placement paused before fatality; Space starts scene 0")
end

function placement_after_frame_done()
    if not KHEART_PLACEMENT_ENABLED then return end
    if placement_load_issued and placement_pending_load then
        local pending = placement_pending_load
        placement_pending_load = nil
        placement_load_needs_unpause = false
        placement_load_issued = false
        placement_scene = pending.scene
        if pending.purpose == "show" then
            placement_apply_record()
            placement_keyboard_armed = false
            placement_arm_at_ticks = emu.osd_ticks() + (emu.osd_ticks_per_second() // 4)
            placement_showing = false
            placement_previewing = false
            placement_paused = true
            log("placement loaded scene=%d rel=%d for display", placement_scene, placement_scene * 5)
            emu.pause()
        elseif pending.purpose == "advance" then
            placement_previewing = false
            placement_advancing = true
            placement_advance_remaining = 4
            placement_step_requested = true
            placement_paused = true
            log("placement loaded scene=%d rel=%d for advance", placement_scene, placement_scene * 5)
        end
        return
    end
    if placement_advancing then
        placement_advance_remaining = placement_advance_remaining - 1
        if placement_advance_remaining <= 0 then
            placement_advancing = false
            placement_step_requested = false
            placement_capture_scene(placement_scene + 1)
        else
            placement_step_requested = true
        end
    end
end

local function draw_placement_hud()
    draw_kheart_preview()
    if placement_ready then
        draw_line(4, "KHEART PLACEMENT - PAUSED BEFORE FATALITY (NOT CRASHED)")
        draw_line(14, "SPACE start fatality at scene frame 00")
        draw_line(24, "Then: ARROWS move KHEART  A back  S/SPACE forward")
        draw_line(34, "Every scene position is recorded automatically; Esc exits")
        return
    end
    if placement_scene < 0 then
        draw_line(4, "KHEART PLACEMENT - booting to R2 Finish Him")
        return
    end
    local rec = placement_records[placement_scene]
    draw_line(4, string.format("PAUSED - NOT CRASHED | KHEART SCENE %02d/%02d rel%03d %s",
        placement_scene, placement_max_scene, placement_scene * 5, placement_expected(placement_scene)))
    if rec and rec.present then
        draw_line(14, string.format("%s base(%d,%d) final(%d,%d) delta(%d,%d)",
            rec.kheart_label, rec.base_x, rec.base_y, rec.final_x, rec.final_y,
            rec.final_x - rec.base_x, rec.final_y - rec.base_y))
    else
        draw_line(14, "KHEART not present on this composite scene frame")
    end
    draw_line(24, "ARROWS move  A previous  S or SPACE commit/next  Esc finish")
    draw_line(34, "Output: jc_kheart_placement.csv + .txt")
    draw_line(44, "FX " .. effect_label_summary())
end

local function open_readout()
    if not READOUT_ENABLED or readout_csv then return end
    readout_csv = io.open(READOUT_CSV_PATH, "w")
    readout_txt = io.open(READOUT_TXT_PATH, "w")
    if not readout_csv then
        log("WARN readout csv could not open: %s", READOUT_CSV_PATH)
        return
    end
    readout_csv:write("run_frame,fatality_rel,dblo2_source_tick,expected_label,actual_cage_label,cage_sag_hex,victim_label,victim_sag_hex,head_label,head_sag_hex,cage_world_x,cage_world_y,victim_world_x,victim_world_y,head_world_x,head_world_y,cage_screen_x,cage_screen_y,victim_screen_x,victim_screen_y,head_screen_x,head_screen_y,dx,dy,head_dx,head_dy,victim_action_hex,victim_flags_hex,victim_wake_hex,fx_count\n")
    readout_csv:flush()
    if readout_txt then
        readout_txt:write("Johnny Cage headhole fatality animator readout\n")
        readout_txt:write(string.format("One row every %d runtime tick(s); expected labels use native CAGE10 DBLO2 source timing.\n\n", READOUT_STEP))
        readout_txt:flush()
    end
    log("readout enabled csv=%s txt=%s sag_labels=%d", READOUT_CSV_PATH, READOUT_TXT_PATH, set_count(readout_sag_labels))
end

local function close_readout()
    if readout_csv then
        readout_csv:flush()
        readout_csv:close()
        readout_csv = nil
    end
    if readout_txt then
        readout_txt:flush()
        readout_txt:close()
        readout_txt = nil
    end
end

local function write_readout_tick(rel)
    if not READOUT_ENABLED or not readout_csv then return end
    if rel < 0 or (rel % READOUT_STEP) ~= 0 then return end
    local tick = rel
    local expected = dblo2_at_rel(tick)
    if not expected then return end
    local seen_key = rel
    if readout_seen[seen_key] then return end
    readout_seen[seen_key] = true

    local attacker_obj = r32(ATTACKER.obj)
    local victim_obj = r32(VICTIM.obj)
    local victim_proc = r32(VICTIM.proc)
    local world_left = r16(A.worldtlx + 16)
    if world_left == 0xffff then world_left = 0 end

    local attacker_x, attacker_y, victim_x, victim_y = 0, 0, 0, 0
    if attacker_obj ~= 0 then
        attacker_x = r16(attacker_obj + O.oxpos)
        attacker_y = r16(attacker_obj + O.oypos)
    end
    if victim_obj ~= 0 then
        victim_x = r16(victim_obj + O.oxpos)
        victim_y = r16(victim_obj + O.oypos)
    end

    local attacker_sag = obj_sag(attacker_obj)
    local victim_sag = obj_sag(victim_obj)
    local head_obj, head_sag, head_label = find_headhole_obj()
    local head_x, head_y = 0, 0
    if head_obj ~= 0 then
        head_x = r16(head_obj + O.oxpos)
        head_y = r16(head_obj + O.oypos)
    end
    local victim_action = victim_proc ~= 0 and r16(victim_proc + P.action) or 0
    local victim_flags = victim_proc ~= 0 and r16(victim_proc + P.flags) or 0
    local victim_wake = victim_proc ~= 0 and r32(victim_proc + P.wake) or 0
    local actual = readout_sag_labels[attacker_sag] or ""
    local victim_label = readout_sag_labels[victim_sag] or ""
    local dx = victim_x - attacker_x
    local dy = victim_y - attacker_y
    local head_dx = head_x - victim_x
    local head_dy = head_y - victim_y
    local fx_count = count_process_id(PID_FX)

    readout_csv:write(string.format(
        "%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,0x%04x,0x%04x,%s,%d\n",
        frame, rel, tick, expected, actual, hx(attacker_sag), victim_label, hx(victim_sag), head_label, hx(head_sag),
        attacker_x, attacker_y, victim_x, victim_y, head_x, head_y,
        attacker_x - world_left, attacker_y, victim_x - world_left, victim_y,
        head_x - world_left, head_y, dx, dy, head_dx, head_dy,
        victim_action, victim_flags, hx(victim_wake), fx_count))
    readout_csv:flush()

    if readout_txt then
        readout_txt:write(string.format(
            "tick=%02d rel=%03d expected=%-14s actual=%-16s cage[%s]=(%d,%d) victim[%s]=%s(%d,%d) head=%s(%d,%d d=%d,%d) dx=%d dy=%d cage_sag=%s victim_sag=%s head_sag=%s victim_act=0x%04x victim_flags=0x%04x\n",
            tick, rel, expected, actual ~= "" and actual or "-",
            ATTACKER.name, attacker_x, attacker_y, VICTIM.name, victim_label ~= "" and victim_label or "-",
            victim_x, victim_y, head_label ~= "" and head_label or "-", head_x, head_y,
            head_dx, head_dy, dx, dy, hx(attacker_sag), hx(victim_sag), hx(head_sag), victim_action, victim_flags))
        readout_txt:flush()
    end
end

local function draw_hud()
    if not HUD_ENABLED then return end
    if KHEART_PLACEMENT_ENABLED then
        draw_placement_hud()
        return
    end
    draw_line(4, "JC HH  P pause  Shift+P step  F12 snap  Esc quit")
    draw_line(14, "Replay: Shift+F7+slot save, F7+slot load")

    if fatality_frame <= 0 then
        draw_line(24, string.format("Booting to R2 Finish Him  stage=%s", STAGE_NAME))
        draw_line(34, "DBLO2 source ticks: 6,1,1,10,1,1,1,1,10,1,1,10")
        return
    end

    local rel = frame - fatality_frame
    local tick = rel >= 0 and rel or -1
    local expected, step, tick_in_step, step_ticks = dblo2_at_rel(tick)
    expected = expected or "-"
    local attacker_obj = r32(ATTACKER.obj)
    local victim_obj = r32(VICTIM.obj)
    local head_obj, head_sag, head_label = find_headhole_obj()
    local attacker_x, attacker_y, victim_x, victim_y = 0, 0, 0, 0
    local head_x, head_y = 0, 0
    if attacker_obj ~= 0 then
        attacker_x = r16(attacker_obj + O.oxpos)
        attacker_y = r16(attacker_obj + O.oypos)
    end
    if victim_obj ~= 0 then
        victim_x = r16(victim_obj + O.oxpos)
        victim_y = r16(victim_obj + O.oypos)
    end
    if head_obj ~= 0 then
        head_x = r16(head_obj + O.oxpos)
        head_y = r16(head_obj + O.oypos)
    end
    draw_line(24, string.format("DBLO2 %s t%02d s%02d %d/%d %-12s C:%06x L:%06x",
        ATTACKER.name,
        tick, step or 0, tick_in_step or 0, step_ticks or 0, expected,
        obj_sag(attacker_obj), obj_sag(victim_obj)))
    draw_line(34, string.format("pos C(%d,%d) V(%d,%d) H(%d,%d) %s",
        attacker_x, attacker_y, victim_x, victim_y, head_x, head_y, head_label ~= "" and head_label or "-"))
    draw_line(44, "FX " .. effect_label_summary())
    draw_line(54, string.format("dx=%d dy=%d head-body=%d,%d H:%06x",
        victim_x - attacker_x, victim_y - attacker_y, head_x - victim_x, head_y - victim_y, head_sag))
end

local function log_multipart(label)
    local obj = r32(ATTACKER.obj)
    if obj == 0 then
        log("mp %s no_attacker_obj", label)
        return
    end

    local img = r32(obj + O.oimg)
    local shape = r32(obj + O.oshape)
    local first_header = shape ~= 0 and r32(shape) or 0
    local first_icmap = first_header ~= 0 and r32(first_header + 0x70) or 0
    log("mp %s obj=%s img=%s shape=%s first_hdr=%s hdr_icmap=%s cage_p=%s opal=0x%04x flags=0x%04x flags2=0x%04x osag=%s osize=%s",
        label, hx(obj), hx(img), hx(shape), hx(first_header), hx(first_icmap), hx(A.CAGE_P),
        r16(obj + O.opal), r16(obj + O.oflags), r16(obj + O.oflags2),
        hx(r32(obj + O.osag)), hx(r32(obj + O.osize)))

    if img == 0 then return end
    for i = 0, 3 do
        local node = img + (i * MP_LEN)
        local sag = r32(node + MP_SAG)
        if sag == 0 then
            log("mp %s node%d end", label, i)
            break
        end
        log("mp %s node%d sag=%s size=%s ctrl=0x%04x anix=%d aniy=%d",
            label, i, hx(sag), hx(r32(node + MP_SIZE)),
            r16(node + MP_CTRL), r16(node + MP_ANIX), r16(node + MP_ANIY))
    end
end

local function log_shape(label, ptr)
    if ptr == 0 then
        log("ani %s shape=%s zero", label, hx(ptr))
        return
    end

    local parts = {}
    for i = 0, 4 do
        parts[#parts + 1] = hx(r32(ptr + (i * 0x20)))
    end
    log("ani %s shape=%s entries=%s", label, hx(ptr), table.concat(parts, ","))

    local hdr = r32(ptr)
    if hdr ~= 0 then
        log("ani %s first_hdr=%s size=%s anix=%d aniy=%d sag=%s ctrl=0x%04x icmap=%s",
            label, hx(hdr), hx(r32(hdr + 0x00)), r16(hdr + 0x20), r16(hdr + 0x30),
            hx(r32(hdr + 0x40)), r16(hdr + 0x60), hx(r32(hdr + 0x70)))
    end
end

local function log_anim_window(label)
    local proc = r32(ATTACKER.proc)
    if proc == 0 then
        log("ani %s no_attacker_proc", label)
        return
    end

    local pa9 = r32(proc + P.pa9)
    log("ani %s proc=%s pa9=%s ptime=%d panitab=%s rate=%d count=%d",
        label, hx(proc), hx(pa9), r16(proc + P.time), hx(r32(proc + P.anitab)),
        r16(proc + P.anirate), r16(proc + P.anicount))

    for i = -8, 10 do
        local addr = pa9 + (i * 0x20)
        local val = r32(addr)
        log("ani %s entry[%+d] @%s = %s", label, i, hx(addr), hx(val))
        if i >= -1 and i <= 3 and val ~= 0 and val > 0xff800000 then
            log_shape(label .. string.format("[%+d]", i), val)
        end
    end
end

local function log_state(force)
    if not space then return end
    if not force and frame % 30 ~= 0 then return end
    log("state frame=%d %s", frame, pstate_summary())
end

local function check_lockup()
    if did_error or not space then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = r32(A.pf_ram)
    if pc and pc >= MKBUG_START and pc <= MKBUG_END then
        did_error = true
        log("ERROR system_lockup pc=%s pf=%s %s", hx(pc), hx(pf), pstate_summary())
        auto_snap("system_lockup")
        manager.machine:exit()
        return true
    end
    -- pf_ram is printf scratch RAM, not a lockup flag.  Preserve it in the
    -- state log above, but do not turn a valid signed scratch value into a
    -- false runtime failure.
    return false
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    AM.report()
    log_state(true)
    auto_snap(ok and "pass_final" or ("error_" .. reason))
    if ok then
        log("PASS reason=%s fatality_frame=%d complete=%s deathblo10=%s victory=%s",
            reason, fatality_frame, tostring(did_complete),
            tostring(did_deathblo10), tostring(did_victory_started))
    else
        log("ERROR reason=%s fatality_frame=%d complete=%s deathblo10=%s victory=%s",
            reason, fatality_frame, tostring(did_complete),
            tostring(did_deathblo10), tostring(did_victory_started))
    end
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1

    -- KHEART witness: the heart is its own object, so the readout CSV (which
    -- follows Cage, the victim and the head) never sees it.  Log every change
    -- of the drawn KHEART record, with the SAG and control word the DMA was
    -- handed - that is what proves the 4 bpp repack draws in a running game.
    if READOUT_ENABLED and frame > 1 then
        local kobj, klabel, ksag = find_kheart_obj()
        if klabel ~= JC_RI.last_kheart then
            JC_RI.last_kheart = klabel
            if klabel ~= "" then
                -- Sprite header layout is the LOD's IHDR, in BIT offsets:
                -- SIZX:W 0x00, SIZY:W 0x10, ANIX:W 0x20, ANIY:W 0x30,
                -- SAG:L 0x40, CTRL:W 0x60, PAL:L 0x70.  (The MP_* constants
                -- above describe a different record and read the SAG's low
                -- word if used here.)
                local hdr = kobj ~= 0 and r32(kobj + O.oimg) or 0
                local hsag = hdr ~= 0 and (r32(hdr + 0x040) & 0x00ffffff) or 0
                local ctrl = hdr ~= 0 and r16(hdr + 0x060) or 0
                local wl = r16(A.worldtlx + 16)
                if wl == 0xffff then wl = 0 end
                log("KHEART frame=%d rel=%d label=%-10s sag=0x%06x hdr_sag=0x%06x ctrl=0x%04x bpp=%d screen=%d,%d",
                    frame, fatality_frame ~= 0 and (frame - fatality_frame) or -1,
                    klabel, ksag, hsag, ctrl, (ctrl >> 12) & 0xf,
                    r16(kobj + O.oxpos) - wl, r16(kobj + O.oypos))
            end
        end
    end

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        maincpu_region()
        open_readout()
        if KHEART_PLACEMENT_ENABLED then load_kheart_textures() end
        log("markers loaded deathblo10_sags=%d jc_victory_sags=%d", set_count(deathblo10_sags), set_count(jc_victory_sags))
        log("loaded: direct-select %s Cage vs %s %s(%d) on %s(%d), force round 1 then round 2 HP-trigger fatality; HUD=%s",
            ATTACKER.name, VICTIM.name, VICTIM_NAME, FT_VICTIM, STAGE_NAME, STAGE_ID, tostring(HUD_ENABLED))
    end

    if space and placement_capture_pending >= 0 then
        local capture_scene = placement_capture_pending
        placement_capture_pending = -1
        placement_capture_scene(capture_scene)
        return
    end

    if space and placement_issue_pending_load() then return end

    if space then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
                fight_count = fight_count + 1
                fighting_frame = frame
                log("fight_start frame=%d fight=%d %s", frame, fight_count, pstate_summary())
                auto_snap("fight_" .. tostring(fight_count) .. "_start")
            end
            last_gstate = gs
        end

        if (gs == GS_POST or gs == GS_FIGHTING) and fight_count == 0 then
            force_stage_context()
        end

        if charsel_frame > 0 and fighting_frame == 0 then
            force_match_select()
            if p1_confirm_start == 0 and frame > charsel_frame + 90
                and r16(ATTACKER.char) == FT_CAGE and r16(VICTIM.char) == FT_VICTIM then
                p1_confirm_start = frame + 25
                log("confirm_start frame=%d", p1_confirm_start)
            end
        end

        force_round1_win()
        force_finish_him()
        if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready_for_fatality() then
            dizzy_ready_frame = frame
            log("victim_dizzy_ready frame=%d finish_rel=%d %s", frame, frame - finish_forced_frame, pstate_summary())
            if not did_dizzy_snap then
                did_dizzy_snap = true
                auto_snap("victim_dizzy_ready")
            end
            placement_enter_ready()
        end
        if not (KHEART_PLACEMENT_ENABLED and placement_paused) then log_state(false) end

        local fdeath = r16(A.f_death)
        if fatality_frame > 0 then AM.step() end
        if fdeath == 2 and fatality_frame == 0 then
            fatality_frame = frame
            if FORCE_NO_BLOOD then
                w16(A.f_no_blood, 1)
                log("diagnostic blood suppression enabled after fatality start")
            end
            did_fatality_snap = true
            log("fatality_started frame=%d %s", frame, pstate_summary())
            AM.begin()
            log_process_liveness("fatality_start")
            log_anim_window("fatality_start")
            log_multipart("fatality_start")
            auto_snap("fatality_start")
            if KHEART_PLACEMENT_ENABLED then placement_capture_scene(0) end
        end

        if fatality_frame > 0 then
            if FORCE_NOFLIP then
                -- Diagnostic: present and render page 0 only.  This tests
                -- whether a stale page-1 buffer is the source of blink.
                w16(A.noflip, 1)
            end
            local rel = KHEART_PLACEMENT_ENABLED and math.max(0, placement_scene * 5)
                or (frame - fatality_frame)
            if rel >= 200 and rel <= 205 then
                log("display rel=%d noflip=0x%04x pageaddr=%s displayon=0x%04x",
                    rel, r16(A.noflip), hx(r32(A.pageaddr)), r16(A.displayon))
            end
            local attacker_sag = attacker_current_sag()
            if SNAPSHOT_RELS[rel] and not targeted_snap_seen[rel] then
                targeted_snap_seen[rel] = true
                snap(string.format("fatality_rel_%03d", rel))
            end
            maybe_dump_headhole_objects(rel)
            write_readout_tick(rel)
            -- Native CAGE10 DBLO2 is a direct [frame, tick] list.  It has no
            -- inline ANI_SOUND / DFYEAH command; that cue belonged only to a
            -- retired preview-derived table and must not be a pass condition.
            if not did_deathblo10 and deathblo10_sags[attacker_sag] then
                did_deathblo10 = true
                log("deathblo10_seen frame=%d rel=%d side=%s sag=%s label=%s", frame, rel,
                    ATTACKER.name, hx(attacker_sag), deathblo10_sags[attacker_sag])
                auto_snap("deathblo10_seen")
            end
            if not KHEART_PLACEMENT_ENABLED and
                ((rel >= 20 and rel <= 35) or (rel >= 80 and rel <= 105)) then
                log_attack_frame_probe(string.format("fatality_rel_%03d", rel))
            end
            if not KHEART_PLACEMENT_ENABLED and rel <= 120 and (rel % 5) == 0 then
                log_process_liveness(string.format("fatality_rel_%03d", rel))
            end
            if rel >= 70 and not did_mid_snap then
                did_mid_snap = true
                log("fatality_mid frame=%d rel=%d %s", frame, rel, pstate_summary())
                log_process_liveness("fatality_mid")
                log_anim_window("fatality_mid")
                log_multipart("fatality_mid")
                auto_snap("fatality_mid")
            end
            if rel >= 190 and not did_final_anim_snap then
                did_final_anim_snap = true
                log("fatality_final_anim frame=%d rel=%d %s", frame, rel, pstate_summary())
                log_process_liveness("fatality_final_anim")
                log_anim_window("fatality_final_anim")
                log_multipart("fatality_final_anim")
                auto_snap("fatality_final_anim")
            end
            if fdeath == 0xffff or (fdeath == 0 and rel > 120) then
                did_complete = true
                if fdeath_clear_frame == 0 then
                    fdeath_clear_frame = frame
                    log("fdeath_cleared frame=%d rel=%d fdeath=0x%04x", frame, rel, fdeath)
                end
            end
            if did_complete and not did_victory_started and jc_victory_sags[attacker_sag] then
                did_victory_started = true
                log("jc_victory_seen frame=%d rel=%d side=%s sag=%s label=%s", frame, rel,
                    ATTACKER.name, hx(attacker_sag), jc_victory_sags[attacker_sag])
                log_process_liveness("jc_victory_seen")
                log_anim_window("jc_victory_seen")
                log_multipart("jc_victory_seen")
                dump_object_list(A.objlst, "victory_objlst", rel)
                dump_effect_processes(rel)
                auto_snap("jc_victory_seen")
            end
            if rel >= PASS_REL then
                dump_object_list(A.objlst, "pass_objlst", rel)
                dump_effect_processes(rel)
                if did_fatality_snap and did_mid_snap and did_final_anim_snap and did_complete and did_deathblo10 and did_victory_started and not did_error then
                    finish(true, "deathblo_then_jc_victory_no_crash")
                elseif not did_deathblo10 then
                    finish(false, "deathblo10_not_seen")
                elseif not did_complete then
                    finish(false, "fatality_never_completed")
                elseif not did_victory_started then
                    finish(false, "jc_victory_not_seen")
                else
                    finish(false, "missing_snap_or_error")
                end
                return
            end
        end

        if check_lockup() then return end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if KHEART_PLACEMENT_ENABLED then return end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif fight_count < 2 and fighting_frame > 0 and frame - fighting_frame > 3200 then
        finish(false, "round2_never_reached")
    elseif fight_count >= 2 and fighting_frame > 0 and fatality_frame == 0 and frame - fighting_frame > 1500 then
        dump_queue(ATTACKER.jcq, "no_fatality_attacker_jcq")
        dump_queue(ATTACKER.bcq, "no_fatality_attacker_bcq")
        if finish_forced_frame > 0 and dizzy_ready_frame == 0 then
            finish(false, "victim_never_reached_real_dizzy")
        else
            finish(false, "fatality_never_started")
        end
    elseif frame > 14000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function()
    placement_after_frame_done()
    draw_hud()
    flush_snapshots()
end)

if KHEART_PLACEMENT_ENABLED then
    emu.register_periodic(function()
        placement_poll_keys()
    end)
end

emu.register_stop(function()
    if KHEART_PLACEMENT_ENABLED then
        placement_commit("exit")
        placement_write_files()
        free_kheart_textures()
    end
    log("stopped frame=%d finished=%s error=%s fatality_frame=%d complete=%s deathblo10=%s victory=%s",
        frame, tostring(finished), tostring(did_error), fatality_frame, tostring(did_complete),
        tostring(did_deathblo10), tostring(did_victory_started))
    if logfh then
        logfh:flush()
        logfh:close()
    end
    close_readout()
end)
