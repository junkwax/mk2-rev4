-- sz_headrip_test.lua
--
-- End-to-end MAME harness for Sub-Zero's MK1 head-rip fatality
-- (do_sz_headrip in MKDEATH.ASM, lanes in MKNJ.ASM).
--
-- What the sequence is supposed to do:
--   NJSCORPSWIPE9/NJHIPUNCH2   windup
--   NJHIPUNCH3                 the grab, held 10 authored ticks
--   NJUPPERCUT4                THE RIP - victim -> sz_headrip_fall, and both
--                              props (SPINERIP1 + LKSPINEHEAD1) appear
--   NJELBO1/NJSUBVIC2          pulled clear and raised, props step with him
--   NJSUBVIC3                  held forever, props on frame 4, as the pose
--
-- The three things this run is actually here to prove:
--   1. all four SPINERIP and all four LKSPINEHEAD frames render;
--   2. NO detached head - the victim takes tongued_fall, not decap_fall, so
--      no pid_head process may ever exist (Sub-Zero is holding the head);
--   3. both props sit in front of both players, and the head in front of
--      the spine, in BOTH facings.
--
-- Modeled on scorpion_scortch_mk1_test.lua.  Same caveat applies: scripted
-- button presses do not reach the in-fight move dispatch in this MAME build,
-- so the fatality is entered by pointing P1's process wake at do_sz_headrip.
-- That exercises the controller, not the MOVES.ASM gate.
--
-- Env:
--   SZHR_SIDE=left|right    which side Sub-Zero stands on (default left)
--   SZHR_FATAL_X=<px>       forced separation before the trigger (default 112
--                           = sz_headrip_reach, so the snap is a no-op)
--   SZHR_STAGE=<id>         stage index (default 5)

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("SZHR_LOG") or (ROOT .. "/tools/sz_headrip_test.log")
local CSV_PATH = os.getenv("SZHR_FRAME_LOG") or (ROOT .. "/tools/sz_headrip_frames.csv")
local CAPTURE_UNTIL = getenv_int("SZHR_CAPTURE_UNTIL", 160)
local PASS_REL = getenv_int("SZHR_PASS_REL", 300)
local STAGE_ID = getenv_int("SZHR_STAGE", 5)
local FATAL_X = getenv_int("SZHR_FATAL_X", 112)   -- sz_headrip_reach = 070h
local SIDE = (os.getenv("SZHR_SIDE") or "left"):lower()
local VICTIM = getenv_int("SZHR_VICTIM", 11)   -- ochar; 11 = Jax

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(CSV_PATH, "w")
if csvfh then
    csvfh:write("capture_index,emu_frame,rel,f_death,attacker,spine,head," ..
                "spine_z,head_z,p1_z,p2_z,p1_x,p2_x,spine_c,head_c,victim_c\n")
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
    print("[szhr] " .. msg)
end

local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

-- Resolve symbols from the freshly built linker map.  Never hardcode: BSS
-- shifts on every build.
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
        log("WARN no linker map found")
    end
end

local missing_symbols = {}
local function sym(name, fallback)
    local value = symbols[name]
    if value ~= nil then return value end
    missing_symbols[#missing_symbols + 1] = name
    log("WARN missing symbol %s; fallback=%s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    active        = sym("active"),
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),
    p2_state      = sym("p2_state"),
    p1_char       = sym("p1_char"),
    p2_char       = sym("p2_char"),
    p1_obj        = sym("p1_obj"),
    p2_obj        = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),
    p2_proc       = sym("p2_proc"),
    curback       = sym("curback"),
    winner_status = sym("winner_status"),
    f_death       = sym("f_death"),
    pf_ram        = sym("pf_ram"),
    objlst        = sym("objlst"),
    objlst2       = sym("objlst2"),
    objlst3       = sym("objlst3"),
    do_sz_headrip = sym("do_sz_headrip"),
    dizzy_dude    = sym("dizzy_dude"),
    dizzy         = sym("dizzy"),
    r_super_freeze = sym("r_super_freeze"),
    super_frozen  = sym("super_frozen"),
    sz_headrip_reaches = sym("sz_headrip_reaches"),
    system_lockup = sym("system_lockup"),
    tvbp          = sym("TVBP"),
}

local O = {
    next = 0x000, oslink = 0x020, oxval = 0x080, oxpos = 0x090,
    oyval = 0x0a0, oypos = 0x0b0, ozval = 0x0c0, oflags = 0x0f0,
    osag = 0x100, oimg = 0x1a0, oshape = 0x1d0, ochar = 0x1f0,
}
local M_FLIPH = 0x010

-- pdata = 0x100 (MAINEQU.ASM), so p_store1 = 0x230.
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210 }
local PID_HEAD = 0x0202          -- decapped head worker; must NEVER appear

-- Rendered centre of a drawn object.  ganiof puts the sprite at
-- (anchor - anioff), and ani2 stores the offset it actually applied in the
-- per-piece RAM record: sag(32) size(32) ctrl(16) dx(16) dy(16), so width is
-- at bit +32 and the applied offset at bit +80.  A multiparter's own osizex
-- reads back 0 - this is the only way to get its real span.
local function draw_span(obj, space_r16, space_r32)
    local img = space_r32(obj + O.oimg)
    if img == 0 then return nil end
    local dx = space_r16(img + 80)
    if dx >= 0x8000 then dx = dx - 0x10000 end
    local w = space_r16(img + 32)
    if w == 0 then return nil end
    local anchor = space_r16(obj + O.oxpos)
    return anchor - dx + (w - 1) // 2, w, dx, anchor
end

-- Same record, both axes: w at +32, h at +48, dx at +80, dy at +96.
-- Returns the DRAWN box plus the object's own anchor.
local function draw_box(obj, space_r16, space_r32)
    local img = space_r32(obj + O.oimg)
    if img == 0 then return nil end
    local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
    local w, h = space_r16(img + 32), space_r16(img + 48)
    if w == 0 then return nil end
    local dx, dy = s16(space_r16(img + 80)), s16(space_r16(img + 96))
    local ax, ay = space_r16(obj + O.oxpos), space_r16(obj + O.oypos)
    return { x0 = ax - dx, x1 = ax - dx + w - 1, y0 = ay - dy, y1 = ay - dy + h - 1,
             w = w, h = h, ax = ax, ay = ay }
end

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_SUBZERO = 8
-- Which head record each victim ochar must produce (MKNJ.ASM
-- sz_head_ani_table).  Heads are shared by body type; the palette is what
-- separates e.g. Sub-Zero from Scorpion, and a palette is not observable
-- from the display list, so this checks the SPRITE only.
local HEAD_FOR_OCHAR = {
    [0]='TMSPINE1',  [1]='LKSPINE1', [2]='JCSPINE1', [3]='UGSPINE1',
    [4]='KTSPINE1',  [5]='KTSPINE1', [6]='STSPINE1', [7]='RADSPINE1',
    [8]='NJSPINE1',  [9]='NJSPINE1', [10]='NJSPINE1', [11]='JXSPINE1',
    [12]='LKSPINEHEAD1', [13]='LKSPINEHEAD1',
    [14]='NJSPINE1', [15]='NJSPINE1', [16]='KTSPINE1',
}
local WANT_HEAD = HEAD_FOR_OCHAR[VICTIM] or 'LKSPINEHEAD1'
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

local cpu, space = nil, nil
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local fight_count, last_gstate = 0, -1
local p1_confirm_start = 0
local did_direct_select = false
local finish_forced_frame, dizzy_ready_frame = 0, 0
local CROSS = (os.getenv("SZHR_CROSS") or "0") ~= "0"
-- NEGATIVE CONTROL: mirror the HEAD prop on its own, after it is built, so it
-- no longer carries Sub-Zero's facing.  Its anipoint is ~90px off its anchor,
-- so flipping it about that anchor throws the head ~190px across the screen -
-- which is what a mirror fault looks like, and ALIGN must catch it.  A run with
-- this set MUST report ALIGN BAD; if it passes, the check is measuring nothing.
local NEG = (os.getenv("SZHR_NEG") or "0") ~= "0"
local neg_done = false
local OTHER_SIDE = (SIDE == "right") and "left" or "right"
local cross_before, cross_after = nil, nil   -- (side, flip) before / after the cross
-- FREEZE: super-freeze the dizzy victim first (r_super_freeze in his own
-- process, the routine the arctic blast hands him), and only then rip.  With
-- -CrossUp that is "freeze him, flip over him, rip" - he cannot turn while he
-- is ice, so he is taken over with his back to Sub-Zero.
local FREEZE = (os.getenv("SZHR_FREEZE") or "0") ~= "0"
local freeze_frame = 0
-- THE VICTIM AT THE GRAB: which frame he is drawn on, which way he faces and
-- where he stands, sampled on the last frame before the rip.
--   pose   = the STUNNED frame data/SUBSPINE.WAX authors this body on
--            (tools/szhr_pose_expect.lua, written by subspine_wax_import.py)
--   facing = opposite to Sub-Zero's, and on the side Sub-Zero is facing
local ANITAB1 = { [0]="hat_anitab1", "lk_anitab1", "jc_anitab1", "sa_anitab1",
                  "fn1_anitab1", "fn2_anitab1", "st_anitab1", "rd_anitab1",
                  "sz_anitab1", "rp_anitab1", "sc_anitab1", "jx_anitab1" }
local pose_expect = nil
do
    local f = loadfile(ROOT .. "/tools/szhr_pose_expect.lua")
    if f then pose_expect = f() end
end
local grab_sample = nil
local victim_y0, victim_yk = nil, nil     -- his anchor y: dizzy, and on his knees
local trigger_frame, fatality_frame = 0, 0
local forced_via_wake, fdeath_seen = false, false
local fighter_verified, fighter_verify_logged = false, false
local victim_dizzy_forced = false
local attacker_seen, spine_seen, head_seen = {}, {}, {}
local spine_rel, head_rel, attacker_rel = {}, {}, {}
local zorder_ok, zorder_bad = 0, 0
local head_over_spine_ok, head_over_spine_bad = 0, 0
local pid_head_sightings = 0
local head_positions = {}
local head_pos_count = 0
local victim_last = nil
local shake_trace = {}

-- WHERE THE PROPS MUST BE, generated from the art by
-- tools/szhr_align_expect.py.  Facing space: x measured from Sub-Zero's own
-- anchor and negated when he faces left, so the SAME numbers must come back
-- whichever way he is turned - which is the whole of "the mirror is toward
-- him".  A mirror fault is twice the offset (~30px at the hold, ~190 at the
-- rip), nowhere near ALIGN_TOL_X, which only covers ganiof's flipped
-- sizex/sizex-1 off-by-one plus integer truncation.
local ALIGN_TOL_X, ALIGN_TOL_Y = 2, 1
local align_expect = nil
do
    local f = loadfile(ROOT .. "/tools/szhr_align_expect.lua")
    if f then align_expect = f() end
end
local align_worst = {}        -- beat -> worst deviation seen
local align_samples = 0
local fist_verdict = {}       -- beat -> "ok" / why not
local rip_delta = nil
local announce_forced, completed, did_error, finished = false, false, false, false
local pending_snaps, capture_index, last_status_frame = {}, 0, 0

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end
local function w32(addr, value) space:write_u32(addr, value & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local missing = {}
    for name, _ in pairs(wanted) do
        if fields[name] then log("input %-18s ok", name)
        else log("input %-18s MISSING", name); missing[#missing + 1] = name end
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

-- Map every visible object back to its authored frame label via the source
-- TBL SAGs.  The test never patches runtime art.
local sag_labels = {}
local function load_sag_labels(path, pattern)
    local fh = io.open(path, "r")
    if not fh then log("WARN cannot open %s for SAG labels", path); return end
    local current = nil
    local n = 0
    for line in fh:lines() do
        local label = line:match("^([%w_]+):")
        if label then
            current = label:match(pattern)
        elseif current then
            local raw = line:match("%.long%s+([%x]+)H")
            if raw then
                sag_labels[tonumber(raw, 16) & 0x00ffffff] = current
                current = nil
                n = n + 1
            end
        end
    end
    fh:close()
    log("sag labels %-24s pattern=%s -> %d", path:match("[^/]+$"), pattern, n)
end
load_sag_labels(ROOT .. "/src/SZSPINE.TBL", "^(SPINERIP%d+)$")
load_sag_labels(ROOT .. "/src/SZSPINE.TBL", "^(LKSPINEHEAD1)$")
load_sag_labels(ROOT .. "/src/SZSPINE.TBL", "^(%u+SPINE1)$")

local HEAD_LABELS = {
    LKSPINEHEAD1=true, TMSPINE1=true, LKSPINE1=true, UGSPINE1=true,
    JXSPINE1=true, KTSPINE1=true, STSPINE1=true, NJSPINE1=true,
    JCSPINE1=true, RADSPINE1=true,
}

-- Every head record now has its OWN pixel payload, so a plain SAG lookup
-- identifies them - unlike the retired LKSPINEHEAD1-4, which were one deduped
-- payload under four labels and needed anipoint matching.  The travel is no
-- longer in the anipoint either: each head is a single record and frames 2-4
-- move the OBJECT via ani_adjustxy, so this run watches oxpos change instead
-- of watching the frame label change.
log("victim ochar=%d, expecting head record %s", VICTIM, WANT_HEAD)

-- Sub-Zero's own frames are multipart; osag exposes only the FIRST queued
-- piece, so key the attacker beats on the leading piece of each wrapper.
load_sag_labels(ROOT .. "/src/MKNJ.TBL", "^(NJSCORPSWIPE9A)$")
load_sag_labels(ROOT .. "/src/MKNJ.TBL", "^(NJHIPUNCH3A)$")
load_sag_labels(ROOT .. "/src/MKNJ.TBL", "^(NJUPPERCUT4A)$")
load_sag_labels(ROOT .. "/src/MKNJ.TBL", "^(NJELBO1A)$")
load_sag_labels(ROOT .. "/src/MKNJ.TBL", "^(NJSUBVIC2A)$")
load_sag_labels(ROOT .. "/src/MKNJ.TBL", "^(NJSUBVIC3A)$")

local function marker_set()
    local att, spine, head = {}, {}, {}
    local spine_z, head_z, spine_c, head_c = nil, nil, nil, nil
    local spine_box, head_box, spine_lbl, head_lbl = nil, nil, nil, nil
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
                if label:match("^SPINERIP%d") then
                    spine[label] = true
                    if spine_z == nil or z > spine_z then spine_z = z end
                    spine_c = draw_span(obj, r16, r32)
                    spine_box, spine_lbl = draw_box(obj, r16, r32), label
                elseif HEAD_LABELS[label] then
                    head[label] = true
                    if head_z == nil or z > head_z then head_z = z end
                    head_c = draw_span(obj, r16, r32)
                    head_box, head_lbl = draw_box(obj, r16, r32), label
                else
                    att[label] = true
                end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return att, spine, head, spine_z, head_z, spine_c, head_c,
           spine_box, head_box, spine_lbl, head_lbl
end

-- decap_fall spawns a pid_head worker; tongued_fall does not.  Sub-Zero is
-- holding the head, so a second one flying across the screen is the exact
-- failure this fatality was designed to avoid.  Walk the active list.
local function count_pid_head()
    if A.active == 0 then return 0 end
    local proc = r32(A.active)
    local n, guard = 0, 0
    while proc ~= 0 and guard < 512 do
        if r16(proc + P.id) == PID_HEAD then n = n + 1 end
        proc = r32(proc + P.next)
        guard = guard + 1
    end
    return n
end

local function sorted_labels(set)
    local items = {}
    for label, _ in pairs(set) do items[#items + 1] = label end
    table.sort(items)
    return #items > 0 and table.concat(items, "+") or "-"
end

local function force_select()
    w16(A.p1_char, FT_SUBZERO)
    w16(A.p2_char, VICTIM)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=SubZero(%d) P2=ochar%d stage=%d", FT_SUBZERO, VICTIM, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    return p1char == FT_SUBZERO and p2char == VICTIM, p1char, p2char
end

local function pxy()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1x = p1obj ~= 0 and r16(p1obj + O.oxpos) or 0
    local p2x = p2obj ~= 0 and r16(p2obj + O.oxpos) or 0
    return p1x, p2x
end

-- CROSS-UP: stand him on the WRONG side first and let the game turn him, then
-- put him across the victim shortly before the press.  That is what jumping
-- over leaves behind - he arrives at the fatality having had to change facing
-- during Finish Him - and it is the case the props' mirroring has to survive,
-- because match_ani_points copies whatever facing he has AT THE RIP.
local cross_logged = {}

local function snap_fatal_range(force_side)
    local side = force_side or SIDE
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local p2x = r16(p2obj + O.oxpos)
    local x = (side == "right") and (p2x + FATAL_X) or (p2x - FATAL_X)
    w16(p1obj + O.oxpos, x)
    w32(p1obj + O.oxval, (x << 16) & 0xffffffff)
    if not cross_logged[side] then
        cross_logged[side] = true
        log("snap_fatal_range side=%s p1_x=%d p2_x=%d dist=%d flip=%s",
            side, x, p2x, FATAL_X,
            tostring((r16(p1obj + O.oflags) & M_FLIPH) ~= 0))
    end
end

-- Which side he is standing on right now, and which way he is facing.
local function cross_state()
    local p1obj = r32(A.p1_obj)
    if p1obj == 0 then return nil end
    local p1x, p2x = pxy()
    return (p1x > p2x) and "right" or "left",
           (r16(p1obj + O.oflags) & M_FLIPH) ~= 0
end

local function force_finish_him()
    if fight_count ~= 1 or fatality_frame ~= 0 or r16(A.f_death) ~= 0 then return end
    local fighters_ok, p1ochar, p2ochar = loaded_fighters_match()
    if not fighters_ok then
        if not fighter_verify_logged then
            fighter_verify_logged = true
            log("waiting_for_visible_fighters p1=%d p2=%d want=%d/%d",
                p1ochar, p2ochar, FT_SUBZERO, VICTIM)
        end
        return
    end
    if not fighter_verified then
        fighter_verified = true
        log("visible_fighters_verified p1=%d p2=%d", p1ochar, p2ochar)
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
        -- Snap Sub-Zero BEFORE handing the victim to dizzy_dude: its first act
        -- is face_opponent, and that is the only thing that turns the victim
        -- around.  Snapping after leaves -Side right testing nothing.
        snap_fatal_range(CROSS and OTHER_SIDE or nil)
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

local function victim_frozen()
    local proc = r32(A.p2_proc)
    return proc ~= 0 and r32(proc + P.wake) == A.super_frozen
end

-- The victim as he stood on the last frame before the rip, judged.
local function grab_report()
    local g = grab_sample
    if g == nil then return false, "never sampled" end
    local txt, ok = {}, true
    -- facing: he looks at Sub-Zero, and stands where Sub-Zero is looking
    local faces = g.vflip ~= g.sflip
    local infront = (g.sflip and g.vx < g.sx) or ((not g.sflip) and g.vx > g.sx)
    if not (faces and infront) then ok = false end
    txt[#txt + 1] = string.format("facing=%s(sz flip=%s x=%d, victim flip=%s x=%d)",
        (faces and infront) and "ok" or "BAD", tostring(g.sflip), g.sx,
        tostring(g.vflip), g.vx)
    -- separation: his row of sz_headrip_reaches, +-2 for the shake
    local want = r16(A.sz_headrip_reaches + VICTIM * 16)
    local got = math.abs(g.vx - g.sx)
    local sep_ok = math.abs(got - want) <= 2
    if not sep_ok then ok = false end
    txt[#txt + 1] = string.format("reach=%s(%d want %d)", sep_ok and "ok" or "BAD", got, want)
    -- pose: the authored STUNNED frame, out of his own dizzy lane (anitab1 028h)
    local n = pose_expect and pose_expect[VICTIM]
    local tab = ANITAB1[VICTIM] and symbols[ANITAB1[VICTIM]]
    if n == nil or tab == nil then
        txt[#txt + 1] = "pose=unchecked(no authored frame for this ochar)"
    else
        local lane = r32(tab + 0x28 * 32)
        local want_shape = r32(lane + (n - 1) * 32)
        local seen = "?"
        for i = 0, 6 do
            if r32(lane + i * 32) == g.shape then seen = "STUNNED" .. (i + 1) end
        end
        local pose_ok = g.shape == want_shape
        if not pose_ok then ok = false end
        txt[#txt + 1] = string.format("pose=%s(drawn %s want STUNNED%d)",
            pose_ok and "ok" or "BAD", seen, n)
    end
    -- floor: on his knees he must be back on the line he stood on while dizzy.
    -- During the grab he rides Sub-Zero's anchor y, which is reported only.
    local floor_ok = victim_y0 ~= nil and victim_yk == victim_y0
    if not floor_ok then ok = false end
    txt[#txt + 1] = string.format("floor=%s(dizzy y=%s grab y=%s knees y=%s)",
        floor_ok and "ok" or "BAD", tostring(victim_y0), tostring(g.vy), tostring(victim_yk))
    return ok, table.concat(txt, " ")
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    if trigger_frame > 0 and fatality_frame == 0 then
        if name == "P1 High Punch" then
            local rel = frame - trigger_frame
            return rel >= 0 and rel < 10
        end
    end
    return false
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
    if not space or A.system_lockup == 0 or A.tvbp == 0 then return false end
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

-- Reduce the per-frame victim trace to the shake's four numbers.  A square
-- wave of amplitude SHAKE_PX in BOTH axes, SHAKE_RATE frames a half, repeated
-- SHAKE_N times - szhr_victim_shake's equates (MKDEATH.ASM), which are UMK3's
-- shake2(obj,2,2,8,3).  Judged on the DRAWN object, so a shake the display
-- never applied cannot pass.
local SHAKE_PX, SHAKE_RATE, SHAKE_N = 2, 3, 8

local function shake_report()
    if #shake_trace == 0 then return "none", false end
    -- the baseline is the value he sits at before the first nudge
    local base_x, base_y = shake_trace[1].x, shake_trace[1].y
    local amp_x, amp_y, cycles, bad_pair, runs = 0, 0, 0, 0, {}
    local prev, run = nil, 0
    for _, s in ipairs(shake_trace) do
        local dx, dy = s.x - base_x, s.y - base_y
        if math.abs(dx) > amp_x then amp_x = math.abs(dx) end
        if math.abs(dy) > amp_y then amp_y = math.abs(dy) end
        -- UMK3 moves x and y by the SAME amount on the same tick; a port that
        -- kept MK2's x-only shake_him_up would fail here and nowhere else.
        if dx ~= dy then bad_pair = bad_pair + 1 end
        local up = (dx ~= 0)
        if prev == nil then prev, run = up, 1
        elseif up == prev then run = run + 1
        else
            runs[#runs + 1] = run
            if prev then cycles = cycles + 1 end
            prev, run = up, 1
        end
    end
    runs[#runs + 1] = run
    if prev then cycles = cycles + 1 end
    -- hold length: the modal run, ignoring the first (pre-shake) and last
    -- (cut off by the rip) which are not full halves
    local hold = "?"
    if #runs > 2 then
        local counts = {}
        for i = 2, #runs - 1 do counts[runs[i]] = (counts[runs[i]] or 0) + 1 end
        local best = -1
        for len, n in pairs(counts) do if n > best then best, hold = n, len end end
    end
    local ok = amp_x == SHAKE_PX and amp_y == SHAKE_PX and bad_pair == 0
               and hold == SHAKE_RATE and cycles == SHAKE_N
    return string.format("amp=%d/%d hold=%s cycles=%d unpaired=%d samples=%d",
                         amp_x, amp_y, tostring(hold), cycles, bad_pair, #shake_trace), ok
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    queue_snap(ok and "pass_final" or ("error_" .. reason))
    flush_snaps()
    if csvfh then csvfh:close(); csvfh = nil end
    local _, spine_missing = all_seen(spine_seen, "SPINERIP", 4)
    local head_ok = head_seen[WANT_HEAD] == true
    -- The shake is part of the fatality now, so a missing or wrong one is a
    -- FAILURE, not a note underneath a PASS.
    -- ALIGNMENT: the props measured from Sub-Zero's anchor in facing space,
    -- against what the art says.  Same numbers on both sides or it is not
    -- mirroring toward him.
    local align_ok, align_txt = true, {}
    if align_expect == nil then
        align_ok, align_txt = false, { "expectation file missing" }
    elseif align_samples == 0 then
        align_ok, align_txt = false, { "never sampled" }
    else
        for beat = 4, 7 do
            local w = align_worst[beat]
            if w == nil then
                align_ok = false
                align_txt[#align_txt + 1] = string.format("b%d=UNSEEN", beat)
            else
                local bad = math.abs(w.dx) > ALIGN_TOL_X or math.abs(w.dy) > ALIGN_TOL_Y
                if bad then align_ok = false end
                align_txt[#align_txt + 1] = string.format(
                    "b%d=%s(dx=%+d dy=%+d obs=%d/%d want=%d/%d flip=%s)",
                    beat, bad and "BAD" or "ok", w.dx, w.dy,
                    w.obs_cx, w.obs_top, w.want_cx, w.want_top, tostring(w.flip))
            end
        end
    end
    log("ALIGN %s samples=%d %s", align_ok and "OK" or "BAD", align_samples,
        table.concat(align_txt, " "))


    -- A cross-up run that never actually crossed proves nothing - say so
    -- rather than passing it.
    if CROSS then
        local b, a = cross_before, cross_after
        if b == nil or a == nil then
            ok, reason = false, reason .. "+cross_not_measured"
            log("CROSS BAD never measured (before=%s after=%s)",
                tostring(b ~= nil), tostring(a ~= nil))
        else
            local crossed = b[1] ~= a[1]
            local turned = b[2] ~= a[2]
            log("CROSS %s side %s->%s flip %s->%s",
                (crossed and turned) and "OK" or "BAD",
                b[1], a[1], tostring(b[2]), tostring(a[2]))
            if ok and not (crossed and turned) then
                ok, reason = false, reason .. "+did_not_cross"
            end
        end
    end

    local fist_ok, fist_txt = true, {}
    for beat = 6, 7 do
        local v = fist_verdict[beat]
        if v ~= "ok" then fist_ok = false end
        fist_txt[#fist_txt + 1] = string.format("b%d=%s", beat, v or "UNSEEN")
    end
    log("FIST %s %s", fist_ok and "OK" or "BAD", table.concat(fist_txt, " "))

    local grab_ok, grab_txt = grab_report()
    log("GRAB %s %s", grab_ok and "OK" or "BAD", grab_txt)
    if ok and not grab_ok and not NEG then ok, reason = false, reason .. "+grab_bad" end

    if NEG then
        -- Inverted: the control is only useful if it FAILS, and BOTH checks are
        -- expected to - the head is mirrored off his facing, so it is neither
        -- where the art says nor under his hand.
        log("NEGATIVE expected ALIGN/FIST BAD, got ALIGN %s FIST %s",
            align_ok and "OK" or "BAD", fist_ok and "OK" or "BAD")
        if align_ok or fist_ok then
            ok, reason = false, "negative_did_not_fail"
        else
            ok, reason = true, "negative_control_failed_as_required"
        end
    else
        if ok and not align_ok then ok, reason = false, reason .. "+align_bad" end
        if ok and not fist_ok then ok, reason = false, reason .. "+fist_bad" end
    end

    local shake_txt, shake_ok = shake_report()
    log("SHAKE %s %s (want amp=%d/%d hold=%d cycles=%d)",
        shake_ok and "OK" or "BAD", shake_txt, SHAKE_PX, SHAKE_PX, SHAKE_RATE, SHAKE_N)
    if ok and not shake_ok then ok, reason = false, reason .. "+shake_bad" end
    log("%s reason=%s fdeath=%s attacker=%s spine=%s head=%s " ..
        "spine_missing=%s want_head=%s(%s) head_steps=%d pid_head=%d " ..
        "zorder_ok=%d zorder_bad=%d head_over_spine=%d/%d rip_delta=%s",
        ok and "PASS" or "ERROR", reason, tostring(fdeath_seen),
        sorted_labels(attacker_seen), sorted_labels(spine_seen), sorted_labels(head_seen),
        spine_missing ~= "" and spine_missing or "-",
        WANT_HEAD, tostring(head_ok), head_pos_count,
        pid_head_sightings, zorder_ok, zorder_bad,
        head_over_spine_ok, head_over_spine_bad, tostring(rip_delta))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "required_input_missing"); return end
        if #missing_symbols > 0 then
            log("ERROR unresolved symbols: %s", table.concat(missing_symbols, ","))
            finish(false, "unresolved_symbols")
            return
        end
        log("loaded: P1 Sub-Zero vs P2 Jax; side=%s fatal_x=%d stage=%d", SIDE, FATAL_X, STAGE_ID)
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
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_SUBZERO and r16(A.p2_char) == VICTIM then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
    end

    force_finish_him()
    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        dizzy_ready_frame = frame
        snap_fatal_range(CROSS and OTHER_SIDE or nil)
        if CROSS then cross_before = { cross_state() } end
        victim_y0 = r16(r32(A.p2_obj) + O.oypos)
        if FREEZE then
            -- hand him the freeze in his own process, as superice_hit does
            freeze_frame = frame
            w32(r32(A.p2_proc) + P.wake, A.r_super_freeze)
            log("victim_dizzy_ready frame=%d; super freeze forced", frame)
        else
            trigger_frame = frame + 30
            log("victim_dizzy_ready frame=%d; HP press at frame=%d", frame, trigger_frame)
        end
        queue_snap("victim_dizzy_ready")
    end
    if FREEZE and freeze_frame > 0 and trigger_frame == 0 then
        if victim_frozen() then
            trigger_frame = frame + 30
            if CROSS then cross_before = { cross_state() } end
            log("victim_frozen frame=%d (%d after the freeze); press at frame=%d",
                frame, frame - freeze_frame, trigger_frame)
            queue_snap("victim_frozen")
        elseif frame > freeze_frame + 400 then
            log("ERROR victim never reached super_frozen")
            finish(false, "never_froze"); return
        end
    end

    -- Hold the separation through the trigger window; the gate is read at the
    -- press, not at Finish Him.
    if trigger_frame > 0 and fatality_frame == 0 and frame < trigger_frame + 40 then
        -- In cross mode hold him on the WRONG side until 15 frames before the
        -- press, then put him across.  The game turns him on its own; nothing
        -- here touches his facing, which is the point.
        local wrong = CROSS and frame < (trigger_frame - 15)
        if (frame - trigger_frame) % 8 == 0 or (CROSS and frame == trigger_frame - 15) then
            snap_fatal_range(wrong and OTHER_SIDE or nil)
        end
        if CROSS and cross_after == nil and frame == trigger_frame - 1 then
            cross_after = { cross_state() }
        end
    end

    -- Fallback: point P1's wake straight at do_sz_headrip if the scripted HP
    -- never reaches the move dispatch (it does not, in this MAME build).
    if trigger_frame > 0 and fatality_frame == 0 and not forced_via_wake
        and frame >= trigger_frame + 75 then
        forced_via_wake = true
        local p1proc = r32(A.p1_proc)
        if p1proc ~= 0 and A.do_sz_headrip ~= 0 then
            w32(p1proc + P.wake, A.do_sz_headrip)
            log("forced_fatality_via_wake frame=%d p1proc=%s", frame, hx(p1proc))
            queue_snap("forced_fatality_via_wake")
        else
            log("WARN cannot force via wake p1proc=%s do_sz_headrip=%s",
                hx(p1proc), hx(A.do_sz_headrip))
        end
    end

    local fdeath = r16(A.f_death)
    if fdeath ~= 0 and fdeath ~= 0xffff and fatality_frame == 0 then
        fatality_frame = frame
        fdeath_seen = true
        log("fatality_started frame=%d f_death=%d (want 11)", frame, fdeath)
        queue_snap("fatality_start")
    end

    -- The head must never be spawned as a separate flying object.
    local heads = count_pid_head()
    if heads > 0 then
        pid_head_sightings = pid_head_sightings + 1
        if pid_head_sightings == 1 then
            log("ERROR pid_head process exists frame=%d count=%d - victim took " ..
                "decap_fall, not tongued_fall", frame, heads)
            queue_snap("pid_head_seen")
        end
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local att, spine, head, spine_z, head_z, spine_c, head_c,
              spine_box, head_box, spine_lbl, head_lbl = marker_set()
        local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
        local p1z = p1obj ~= 0 and r32(p1obj + O.ozval) or nil
        local p2z = p2obj ~= 0 and r32(p2obj + O.ozval) or nil

        -- Freeze the victim's own drawn centre at the last frame before the
        -- rip so the head's start position can be measured against where his
        -- head actually was.  That number is what sz_headrip_reach tunes.
        if spine_c == nil and p2obj ~= 0 then
            local c, w, dx = draw_span(p2obj, r16, r32)
            if c then victim_last = { c = c, w = w, dx = dx } end
        end

        -- THE UMK3 SHAKE, sampled every frame while Sub-Zero has hold of him.
        -- szhr_victim_shake (MKDEATH.ASM) is UMK3's shake2(obj,2,2,8,3): the
        -- victim's oxpos AND oypos step 2px together, hold 3 frames, come back,
        -- hold 3, eight times.  Sampled off the object rather than the process
        -- so it measures what was DRAWN.  Only before the rip - once he is
        -- handed sz_headrip_fall he is falling and moves for other reasons.
        if p2obj ~= 0 and rel >= 180 and victim_yk == nil then
            victim_yk = r16(p2obj + O.oypos)
        end
        if spine_c == nil and p1obj ~= 0 and p2obj ~= 0 and rel >= 8 then
            grab_sample = {
                vy = r16(p2obj + O.oypos),
                sx = r16(p1obj + O.oxpos), vx = r16(p2obj + O.oxpos),
                sflip = (r16(p1obj + O.oflags) & M_FLIPH) ~= 0,
                vflip = (r16(p2obj + O.oflags) & M_FLIPH) ~= 0,
                shape = r32(p2obj + O.oshape) }
        end
        if spine_c == nil and p2obj ~= 0 then
            shake_trace[#shake_trace + 1] = {
                rel = rel, x = r16(p2obj + O.oxpos), y = r16(p2obj + O.oypos) }
        end

        -- IS THE MIRROR TOWARD HIM, AND IS THE HAND OVER THE HEAD?
        -- Both props hang off Sub-Zero's anchor and mirror with HIS facing, so
        -- measure them from his anchor, in facing space, against the numbers
        -- the art says (tools/szhr_align_expect.py).  SPINERIP1-4 name the
        -- beat, so this needs no clock.
        if NEG and not neg_done and head_box then
            for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
                local obj, guard = r32(list), 0
                while obj ~= 0 and guard < 256 do
                    local img = r32(obj + O.oimg)
                    local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
                    local lbl = sag_labels[r32(obj + O.osag) & 0x00ffffff] or sag_labels[sag2]
                    if lbl and HEAD_LABELS[lbl] then
                        w16(obj + O.oflags, r16(obj + O.oflags) ~ M_FLIPH)
                        neg_done = true
                        log("NEGATIVE head prop mirrored off Sub-Zero's facing")
                    end
                    obj = r32(obj + O.next); guard = guard + 1
                end
            end
        end

        if align_expect and p1obj ~= 0 and spine_lbl and head_lbl and head_box then
            local n = tonumber(spine_lbl:match("^SPINERIP(%d)$"))
            local beat = n and (n + 3) or nil          -- SPINERIP1 == beat 4
            local hx = align_expect.head[head_lbl]
            if beat and hx and hx[beat] then
                local flip = (r16(p1obj + O.oflags) & M_FLIPH) ~= 0
                local sign = flip and -1 or 1
                local sz_x, sz_y = r16(p1obj + O.oxpos), r16(p1obj + O.oypos)
                local want = hx[beat]
                local wcx = flip and want.cx_flip or want.cx
                local hc = head_box.x0 + (head_box.w - 1) // 2   -- draw_span's centre
                local obs_cx = sign * (hc - sz_x)
                local obs_top = head_box.y0 - sz_y
                local dx, dy = obs_cx - wcx, obs_top - want.top
                local w = align_worst[beat]
                if w == nil or math.abs(dx) > math.abs(w.dx) or math.abs(dy) > math.abs(w.dy) then
                    align_worst[beat] = { dx = dx, dy = dy, flip = flip,
                                          obs_cx = obs_cx, obs_top = obs_top,
                                          want_cx = wcx, want_top = want.top,
                                          rec = head_lbl }
                end
                align_samples = align_samples + 1

                -- The hand over the head, in facing space.  Only the beats
                -- where he is HOLDING it: at the rip the head is still out at
                -- the victim, which is the point of sz_headrip_reach.
                if beat >= 6 then
                    local f = align_expect.fist[beat]
                    local hx0 = obs_cx - (head_box.w - 1) // 2
                    local hx1 = hx0 + head_box.w - 1
                    local why = nil
                    if hx1 < f.x0 or hx0 > f.x1 then
                        why = string.format("no x overlap head[%d,%d] fist[%d,%d]",
                                            hx0, hx1, f.x0, f.x1)
                    elseif obs_top > f.y1 + ALIGN_TOL_Y then
                        why = string.format("head top %d is BELOW the fist (%d)", obs_top, f.y1)
                    elseif obs_top < f.y0 - 12 then
                        why = string.format("head top %d floats above the fist (%d)", obs_top, f.y0)
                    end
                    if why then fist_verdict[beat] = why
                    elseif fist_verdict[beat] == nil then fist_verdict[beat] = "ok" end
                end
            end
        end
        if rip_delta == nil and head_c and victim_last then
            rip_delta = head_c - victim_last.c
            log("RIPDELTA rel=%d head_c=%d victim_c=%d delta=%d side=%s",
                rel, head_c, victim_last.c, rip_delta, SIDE)
        end

        for label, _ in pairs(att) do
            if not attacker_seen[label] then
                attacker_seen[label] = true
                attacker_rel[label] = rel
                log("attacker_frame %s rel=%d", label, rel)
            end
        end
        for label, _ in pairs(spine) do
            if not spine_seen[label] then
                spine_seen[label] = true
                spine_rel[label] = rel
                log("spine_frame %s rel=%d z=%s", label, rel, spine_z and hx(spine_z) or "-")
                queue_snap(string.format("spine_%s_rel_%03d", label, rel))
            end
        end
        for label, _ in pairs(head) do
            if not head_seen[label] then
                head_seen[label] = true
                head_rel[label] = rel
                log("head_record %s rel=%d z=%s", label, rel, head_z and hx(head_z) or "-")
                queue_snap(string.format("head_%s_rel_%03d", label, rel))
            end
        end
        -- The head no longer changes FRAME - every beat draws the same record
        -- and ani_adjustxy moves the object instead.  So the thing to prove is
        -- that its drawn position actually stepped four times.  If
        -- ani_adjustxy's oxpos write were being overwritten from oxval, this
        -- would stick at one value and the head would sit on the victim all
        -- the way through.
        if head_c and not head_positions[head_c] then
            head_positions[head_c] = rel
            head_pos_count = head_pos_count + 1
            log("head_position #%d x=%d rel=%d", head_pos_count, head_c, rel)
        end

        -- Both props in front of BOTH players; head in front of the spine.
        if spine_z and p1z and p2z then
            if spine_z > p1z and spine_z > p2z then zorder_ok = zorder_ok + 1
            else
                zorder_bad = zorder_bad + 1
                if zorder_bad == 1 then
                    log("WARN prop not in front rel=%d spine_z=%s p1_z=%s p2_z=%s",
                        rel, hx(spine_z), hx(p1z), hx(p2z))
                    queue_snap("zorder_bad")
                end
            end
        end
        if spine_z and head_z then
            if head_z > spine_z then head_over_spine_ok = head_over_spine_ok + 1
            else head_over_spine_bad = head_over_spine_bad + 1 end
        end

        if not announce_forced and (fdeath == 0 or fdeath == 0xffff) then
            announce_forced = true
            w16(A.winner_status, 1)
            log("victory_announce_forced frame=%d rel=%d", frame, rel)
        end

        if csvfh and ((rel <= CAPTURE_UNTIL and rel % 5 == 0) or rel == PASS_REL) then
            local p1x, p2x = pxy()
            csvfh:write(string.format("%d,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%d,%d,%s,%s,%s\n",
                capture_index, frame, rel, fdeath, sorted_labels(att),
                sorted_labels(spine), sorted_labels(head),
                spine_z and hx(spine_z) or "-", head_z and hx(head_z) or "-",
                p1z and hx(p1z) or "-", p2z and hx(p2z) or "-", p1x, p2x,
                tostring(spine_c), tostring(head_c),
                tostring(victim_last and victim_last.c)))
            csvfh:flush()
            if rel % 10 == 0 then
                queue_snap(string.format("rel_%03d_spine_%s_head_%s", rel,
                    sorted_labels(spine), sorted_labels(head)))
            end
        end

        if rel > 200 and (fdeath == 0 or fdeath == 0xffff) then completed = true end

        if rel >= PASS_REL then
            local spine_ok, spine_missing = all_seen(spine_seen, "SPINERIP", 4)
            local head_ok = head_seen[WANT_HEAD] == true
            local wrong = {}
            for label, _ in pairs(head_seen) do
                if label ~= WANT_HEAD then wrong[#wrong + 1] = label end
            end
            if did_error then finish(false, "runtime_error")
            elseif not fdeath_seen then finish(false, "f_death_not_seen")
            elseif pid_head_sightings > 0 then finish(false, "detached_head_spawned")
            elseif not spine_ok then finish(false, "missing_spine_" .. spine_missing)
            elseif not head_ok then finish(false, "wrong_head_want_" .. WANT_HEAD)
            elseif #wrong > 0 then
                finish(false, "extra_head_" .. table.concat(wrong, ","))
            elseif head_pos_count < 4 then
                finish(false, "head_did_not_travel_" .. head_pos_count .. "_of_4")
            elseif not attacker_seen["NJUPPERCUT4A"] then finish(false, "no_rip_frame")
            elseif not attacker_seen["NJSUBVIC3A"] then finish(false, "no_hold_pose")
            elseif spine_rel["SPINERIP1"] == nil or attacker_rel["NJUPPERCUT4A"] == nil then
                finish(false, "rip_beat_not_timed")
            elseif math.abs(spine_rel["SPINERIP1"] - attacker_rel["NJUPPERCUT4A"]) > 6 then
                finish(false, "props_not_synced_to_rip")
            elseif zorder_ok == 0 then finish(false, "props_never_in_front")
            elseif zorder_bad > 0 then finish(false, "props_behind_players_" .. zorder_bad)
            elseif head_over_spine_bad > 0 then
                finish(false, "head_behind_spine_" .. head_over_spine_bad)
            elseif not completed then finish(false, "fatality_not_completed")
            else finish(true, "spine1_4_head1_4_synced_headless_zorder")
            end
            return
        end
    end

    if check_lockup() then finish(false, "mkbug_lockup"); return end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        local _, p1ochar, p2ochar = loaded_fighters_match()
        log("status frame=%d gs=%d fight=%d p1=%d/%d p2=%d/%d ws=%d fdeath=%d",
            frame, gs, fight_count, r16(A.p1_char), p1ochar,
            r16(A.p2_char), p2ochar, r16(A.winner_status), r16(A.f_death))
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif trigger_frame > 0 and fatality_frame == 0 and frame - trigger_frame > 300 then
        finish(false, "fatality_never_started")
    elseif fight_count == 1 and fighting_frame > 0 and not fighter_verified
        and frame - fighting_frame > 360 then
        finish(false, "visible_fighters_not_matched")
    elseif frame > 14000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function() flush_snaps() end)
