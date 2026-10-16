-- st_soul_suck_test.lua
--
-- End-to-end MAME harness for Shang Tsung's soul suck fatality (do_drain,
-- MKDEATH.ASM) after the MK1SOUL corpse drop was added.
--
-- What it proves, in order:
--   1. Up,Down,Up + LK during Finish Him at close range starts the fatality.
--   2. Shang plays the DB1 drain body: STDEATHBLO1..7 (beats 1 and 2).
--   3. The victim withers through his own *SOULSUCK* poses and ends on the
--      CORPSE1A husk.
--   4. Shang reaches ST1DEATHBLO8 - the release - and on that beat the NEW
--      MKSOUL1 art starts: CORPSEDROP1 through CORPSEDROP8.
--   5. The corpse drop does not start before the release (ordering check -
--      this is the specific thing the frames were added for).
--   6. No lockup, and the fatality completes.
--
-- Structure mirrors st_decap_fatality_test.lua: it only shortcuts selection
-- and the victim's Finish Him reaction, then performs the real input.
--
-- Capture policy: one screenshot every 5 frames from fatality start through
-- rel=CAPTURE_UNTIL, plus every labeled milestone. A CSV row maps each
-- capture to the attacker's and victim's frame labels.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("ST_SOUL_LOG")
    or (ROOT .. "/tools/st_soul_suck_test.log")
local FRAME_LOG_PATH = os.getenv("ST_SOUL_FRAME_LOG")
    or (ROOT .. "/tools/st_soul_suck_frames.csv")
local CAPTURE_UNTIL = getenv_int("ST_SOUL_CAPTURE_UNTIL", 400)
local PASS_REL = getenv_int("ST_SOUL_PASS_REL", 520)
local STAGE_ID = getenv_int("ST_SOUL_STAGE", 5) -- Armory; no stage fatality route.
-- do_drain is reached through fatality_xfer_close with a1=0x52 (82px).
local SWEEP_X = getenv_int("ST_SOUL_SWEEP_X", 70)
local P2_CHAR = getenv_int("ST_SOUL_P2_CHAR", 11)
-- Rows 12..16 of drain_table / alternate_suck_pals did not exist until
-- 2026-08-03; do_drain indexes both by the VICTIM's ochar via
-- get_his_char_long, so Smoke(14)/Noob(15)/Jade(16) used to read past the end.
-- Those three cannot be driven through the select screen from here - forcing
-- p2_char to a hidden fighter without the unlock intercept walks the SELECT
-- code into illegal_opcode in gstate 4, long before any fight - so instead
-- select an ordinary fighter and restamp the victim OBJECT's ochar once the
-- round is live. That is the same trick do_kintaro_fatal uses on itself, and
-- it exercises exactly the indexing the padding fixes.
local FORCE_OCHAR = getenv_int("ST_SOUL_FORCE_OCHAR", -1)

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(FRAME_LOG_PATH, "w")
if csvfh then
    csvfh:write("capture_index,emu_frame,fatality_rel,f_death,shang_frames,victim_frames,p1_x,p1_y,p2_x,p2_y\n")
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
    print("[st-soul] " .. msg)
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

local last_vpal = nil
local PALRAM = sym('palram', 0)
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
    p1_jcq        = sym("p1_jcq", 0x0112abe0),
    objlst        = sym("objlst", 0x01127570),
    objlst2       = sym("objlst2", 0x01127590),
    objlst3       = sym("objlst3", 0x011275b0),
    dizzy_dude    = sym("dizzy_dude", 0xffa27af0),
    dizzy         = sym("dizzy", 0xffa27e40),
    system_lockup = sym("system_lockup", 0xffa74d60),
    tvbp          = sym("TVBP", 0xffa74f70),
}

local O = {
    next = 0x000, oxvel = 0x040, oyvel = 0x060, oxval = 0x080,
    oxpos = 0x090, oyval = 0x0a0, oypos = 0x0b0, osag = 0x100,
    oimg = 0x1a0, ochar = 0x1f0,
}
local P = {
    next = 0x000, id = 0x020, pa8 = 0x0c0, wake = 0x0e0,
    action = 0x1f0, flags = 0x210,
}

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_ST = 6
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
-- do_drain calls init_death_blow with a1 = 1.
local EXPECTED_FDEATH = 1

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
local force_ochar_logged = false
local dizzy_ready_frame = 0
local input_start_frame = 0
local did_input_log = false
local fatality_frame = 0
local fdeath_seen = false
local shang_seen, victim_seen = {}, {}
local husk_rel = nil
local release_rel = nil
local drop_start_rel = nil
local drop_end_rel = nil
local blo11_rel = nil
local victory_rel = nil
local last_p1_wake = -1
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
        ["P1 Low Kick"] = true,
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
    pending_snaps[#pending_snaps + 1] = {
        index = capture_index, frame = frame, label = label,
    }
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

-- Associate every visible object with its authored frame label.  The test
-- reads source TBLs only as labels; it never patches runtime art.
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
-- Shang's DB1 body lane.  The STDEATHBLO wrappers are multipart and a player
-- object's osag exposes only the FIRST-queued piece, so the *A strips are the
-- observable proxy for each beat (and 6A/7A/8A really are the first entries).
load_sag_labels(ROOT .. "/src/MKST.TBL", "^(STDEATHBLO%d+[A-D])")
-- The victim: the CORPSE1A husk, then the new corpse drop.  Both are single
-- piece lists, so their labels appear directly.
load_sag_labels(ROOT .. "/src/MKFX.TBL", "^(CORPSE1A)")
-- The drop is loaded as A/B strips (MKSOUL1.LOD), and a player object's
-- osag exposes only the FIRST-queued piece - so CORPSEDROPnA is the
-- observable proxy for frame n, the same way STDEATHBLO8A stands in for
-- Shang's four-piece BLO8.
load_sag_labels(ROOT .. "/src/MKSOUL1.TBL", "^(CORPSEDROP%d+[AB])")

local function add_marker(set, label)
    if label then set[label] = true end
end

local function marker_set()
    local shang, victim = {}, {}
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag1 = r32(obj + O.osag) & 0x00ffffff
            local img = r32(obj + O.oimg)
            local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
            local label = sag_labels[sag1] or sag_labels[sag2]
            if label then
                if label:match("^STDEATHBLO") then add_marker(shang, label) end
                if label == "CORPSE1A" or label:match("^CORPSEDROP") then
                    add_marker(victim, label)
                end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return shang, victim
end

local function sorted_labels(set)
    local items = {}
    for label, _ in pairs(set) do items[#items + 1] = label end
    table.sort(items)
    return #items > 0 and table.concat(items, "+") or "-"
end

local function force_select()
    w16(A.p1_char, FT_ST)
    w16(A.p2_char, P2_CHAR)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=ShangTsung(%d) P2=char(%d) stage=%d", FT_ST, P2_CHAR, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    -- Once the victim's ochar has been restamped it no longer equals the
    -- selected p2_char; accept the forced value so the flow keeps going.
    local p2ok = (p2char == P2_CHAR) or (FORCE_OCHAR >= 0 and p2char == FORCE_OCHAR)
    return p1char == FT_ST and p2ok, p1char, p2char
end

local function pxy()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1obj ~= 0 then p1x, p1y = r16(p1obj + O.oxpos), r16(p1obj + O.oypos) end
    if p2obj ~= 0 then p2x, p2y = r16(p2obj + O.oxpos), r16(p2obj + O.oypos) end
    return p1x, p1y, p2x, p2y
end

-- fatality_xfer_close gates on 0x52 (82px); snap P1 inside it deterministically.
local function snap_close_range()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local p2x = r16(p2obj + O.oxpos)
    local x = p2x - SWEEP_X
    w16(p1obj + O.oxpos, x)
    w32(p1obj + O.oxval, (x << 16) & 0xffffffff)
    log("snap_close_range p1_x=%d p2_x=%d dist=%d", x, p2x, SWEEP_X)
end

-- The retail input: Up, Down, Up + LK.  Vertical only, so it needs no
-- facing mirror.  Discrete presses with release gaps so the joystick queue
-- records each switch transition.
--
-- The LK press is deliberately LATE.  The first Up makes Shang jump (p1_y
-- 112 -> 17 -> 112 over ~46 frames), and a low kick pressed while he is
-- airborne dispatches the air-kick path instead of st_lo_kick, so the combo
-- is never even looked at.  He lands around rel=46; the last stick entry is
-- stamped around tick 244 and scom_st_soul_drain's window is 0x38+6 = 62
-- ticks, so the press has to land in roughly rel 48..88.  This is also how a
-- player performs it: jump, ride the stick, kick on the way down.
local COMBO_SCRIPT = {
    { 0,   8, "P1 Up" },
    { 12, 20, "P1 Down" },
    { 24, 32, "P1 Up" },
    { 52, 62, "P1 Low Kick" },
}

local function input_phase()
    if input_start_frame == 0 then return nil end
    local rel = frame - input_start_frame
    if rel >= 0 and rel < 75 then return "combo" end
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
        for _, step in ipairs(COMBO_SCRIPT) do
            if name == step[3] and rel >= step[1] and rel < step[2] then return true end
        end
    end
    return false
end

local function force_finish_him()
    if fight_count ~= 1 or fatality_frame ~= 0 or r16(A.f_death) ~= 0 then return end
    local fighters_ok, p1ochar, p2ochar = loaded_fighters_match()
    if not fighters_ok then
        if not fighter_verify_logged then
            fighter_verify_logged = true
            log("waiting_for_visible_fighters p1_objchar=%d p2_objchar=%d want=%d/%d", p1ochar, p2ochar, FT_ST, P2_CHAR)
        end
        return
    end
    if not fighter_verified then
        fighter_verified = true
        log("visible_fighters_verified p1_objchar=%d p2_objchar=%d", p1ochar, p2ochar)
        queue_snap("visible_fighters_verified")
    end
    if FORCE_OCHAR >= 0 then
        local p2obj = r32(A.p2_obj)
        if p2obj ~= 0 and r16(p2obj + O.ochar) ~= FORCE_OCHAR then
            w16(p2obj + O.ochar, FORCE_OCHAR)
            if not force_ochar_logged then
                force_ochar_logged = true
                log("victim_ochar_forced %d -> %d", p2ochar, FORCE_OCHAR)
                queue_snap("victim_ochar_forced")
            end
        end
    end
    local rel = frame - fighting_frame
    if rel < 90 or rel > 720 then return end
    w16(A.winner_status, 3); w16(A.f_death, 0)
    local p1proc = r32(A.p1_proc)
    if p1proc ~= 0 then
        w16(p1proc + P.flags, r16(p1proc + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2proc = r32(A.p2_proc)
    -- Re-force every 30 frames until he is really stunned: a Kitana caught
    -- mid-move ignored the single write, and the game then dizzied SHANG.
    if p2proc ~= 0 and r16(p2proc + P.action) ~= ACT_STUNNED
            and (not victim_dizzy_forced or (frame - victim_dizzy_forced) >= 30) then
        w32(p2proc + P.wake, A.dizzy_dude)
        victim_dizzy_forced = frame
        local p1p = r32(A.p1_proc)
        log("reforce frame=%d p2act=0x%04x p2wake=0x%08x p1act=0x%04x p1wake=0x%08x", frame, r16(p2proc + P.action), r32(p2proc + P.wake), r16(p1p + P.action), r32(p1p + P.wake))
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
    local act = r16(proc + P.action)
    if wake >= A.dizzy and wake < (A.dizzy + 0x120) and act == ACT_STUNNED then return true end
    -- A female ninja's dizzy loop wakes outside dizzy..+0x120 (her own
    -- fan/sway handling), which left a Kitana run waiting forever.  Being
    -- stunned for two seconds after the force is just as good a signal.
    if finish_forced_frame > 0 and frame - finish_forced_frame > 60 and act == ACT_STUNNED then
        local p1proc = r32(A.p1_proc)
        if p1proc ~= 0 and r16(p1proc + P.action) ~= ACT_STUNNED then
            log("victim_ready fallback wake=0x%08x act=0x%04x", wake, act)
            return true
        end
    end
    return false
end

-- Diagnostic: the joystick change queue combo_look_lr walks backwards, plus
-- P1's action/height.  Up in the combo makes Shang jump, so this is the first
-- thing to check when the input does not take.
local function dump_state(tag)
    local ptr = r32(A.p1_jcq)
    local pieces = { string.format("next=%s", hx(ptr)) }
    for i = 1, 6 do
        ptr = ptr - 32
        if ptr <= A.p1_jcq then ptr = A.p1_jcq + 20 * 32 end
        local raw = r32(ptr)
        pieces[#pieces + 1] = string.format("%d:%04x@%04x", i, (raw >> 16) & 0xffff, raw & 0xffff)
    end
    local p1obj, p1proc = r32(A.p1_obj), r32(A.p1_proc)
    local p1y = p1obj ~= 0 and r16(p1obj + O.oypos) or -1
    local act = p1proc ~= 0 and r16(p1proc + P.action) or -1
    log("%s p1_y=%d p1_action=0x%04x queue %s", tag, p1y, act, table.concat(pieces, " "))
end

local function write_frame_log(rel, shang, victim)
    if not csvfh then return end
    local p1x, p1y, p2x, p2y = pxy()
    csvfh:write(string.format("%d,%d,%d,%d,%s,%s,%d,%d,%d,%d\n",
        capture_index, frame, rel, r16(A.f_death), sorted_labels(shang),
        sorted_labels(victim), p1x, p1y, p2x, p2y))
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

local function finish(ok, reason)
    if finished then return end
    finished = true
    queue_snap(ok and "pass_final" or ("error_" .. reason))
    flush_snaps()
    if csvfh then csvfh:close(); csvfh = nil end
    local shang = sorted_labels(shang_seen)
    local victim = sorted_labels(victim_seen)
    log("%s reason=%s fdeath_seen=%s husk_rel=%s release_rel=%s drop_start_rel=%s drop_end_rel=%s blo11_rel=%s victory_rel=%s shang=%s victim=%s",
        ok and "PASS" or "ERROR", reason, tostring(fdeath_seen), tostring(husk_rel),
        tostring(release_rel), tostring(drop_start_rel), tostring(drop_end_rel),
        tostring(blo11_rel), tostring(victory_rel), shang, victim)
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
        log("loaded: P1 ShangTsung vs P2 char=%d; input Up,Down,Up+LK; capture_until=%d",
            P2_CHAR, CAPTURE_UNTIL)
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

    if fighting_frame == 0 then
        force_select()
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        force_select()
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_ST and r16(A.p2_char) == P2_CHAR then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
    end

    force_finish_him()
    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        dizzy_ready_frame = frame
        input_start_frame = frame + 30
        snap_close_range()
        log("victim_dizzy_ready frame=%d; combo input begins at frame=%d", frame, input_start_frame)
        queue_snap("victim_dizzy_ready")
    end

    local phase = input_phase()
    if phase and not did_input_log then
        did_input_log = true
        log("combo_input_started frame=%d phase=%s", frame, phase)
        dump_state("input_begin")
        queue_snap("input_udu_lk")
    end
    if input_start_frame > 0 and fatality_frame == 0 then
        local irel = frame - input_start_frame
        if irel == 12 or irel == 24 or irel == 36 or irel == 52 or irel == 62 then
            dump_state(string.format("input_rel_%02d", irel))
        end
    end

    local fdeath = r16(A.f_death)
    if fdeath == EXPECTED_FDEATH and fatality_frame == 0 then
        fatality_frame = frame
        fdeath_seen = true
        log("fatality_started frame=%d f_death=%d", frame, fdeath)
        queue_snap("fatality_start")
    elseif input_start_frame > 0 and fdeath ~= 0 and fdeath ~= EXPECTED_FDEATH
        and fdeath ~= 0xffff and fatality_frame == 0 then
        did_error = true
        finish(false, "unexpected_f_death_" .. tostring(fdeath))
        return
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local shang, victim = marker_set()
        for label, _ in pairs(shang) do shang_seen[label] = true end
        for label, _ in pairs(victim) do victim_seen[label] = true end

        if victim["CORPSE1A"] and not husk_rel then
            husk_rel = rel
            log("husk_seen frame=%d rel=%d", frame, rel)
            queue_snap("husk_corpse1a")
        end
        -- ST1DEATHBLO8 is the release beat and the whole point of the change:
        -- the drop is supposed to start here, not before it.
        if shang["STDEATHBLO8A"] and not release_rel then
            release_rel = rel
            log("release_seen (ST1DEATHBLO8) frame=%d rel=%d", frame, rel)
            queue_snap("release_blo8")
        end
        if not drop_start_rel then
            for n = 1, 8 do
                if victim["CORPSEDROP" .. n .. "A"] then
                    drop_start_rel = rel
                    log("corpse_drop_started frame=%d rel=%d first=CORPSEDROP%dA", frame, rel, n)
                    queue_snap("corpse_drop_start")
                    break
                end
            end
        end
        if victim["CORPSEDROP8A"] and not drop_end_rel then
            drop_end_rel = rel
            log("corpse_drop_landed frame=%d rel=%d", frame, rel)
            queue_snap("corpse_drop_landed")
        end
        -- The lane ends on ST1DEATHBLO11 held 9.  STVIC1 queues
        -- STDEATHBLO11B first, so that piece is the observable proxy.
        if shang["STDEATHBLO11B"] and not blo11_rel then
            blo11_rel = rel
            log("blo11_hold_seen frame=%d rel=%d", frame, rel)
            queue_snap("blo11_hold")
        end
        -- osag cannot tell the BLO11 hold from the victory cycle (every
        -- STVIC wrapper queues STDEATHBLO11B first), so track Shang's
        -- process wake pointer instead: it leaves do_drain the moment
        -- victory_animation takes over.  Resolve with sym_resolve.py.
        local p1proc = r32(A.p1_proc)
        if p1proc ~= 0 then
            local wake = r32(p1proc + P.wake)
            if wake ~= last_p1_wake then
                last_p1_wake = wake
                log("p1_wake rel=%3d wake=%s", rel, hx(wake))
            end
        end
        -- Soft signal only: STVIC2-5 also queue STDEATHBLO11B/C first, so
        -- whether their 12A-15D pieces surface as their own objects depends
        -- on how the multipart walker linked them. Logged, not gated.
        if not victory_rel then
            for _, n in ipairs({ 12, 13, 14, 15 }) do
                for _, suffix in ipairs({ "A", "B", "C", "D" }) do
                    if shang["STDEATHBLO" .. n .. suffix] then
                        victory_rel = rel
                        log("victory_anim_seen frame=%d rel=%d label=STDEATHBLO%d%s",
                            frame, rel, n, suffix)
                        queue_snap("victory_anim")
                        break
                    end
                end
                if victory_rel then break end
            end
        end

        -- Victim palette trace: log every change of the map his object draws
        -- in and the ROM palette that map holds (palram[map].palid).
        do
            local vo = r32(A.p2_obj)
            if vo ~= 0 then
                local opal = r16(vo + 0x140)
                local map = (opal >> 8) & 0xff
                local pid = r32(PALRAM + map * 0x40)
                local key = string.format('%04x/%08x', opal, pid)
                if key ~= last_vpal then
                    log('VPAL rel=%d opal=0x%04x map=%d palid=0x%08x', rel, opal, map, pid)
                    last_vpal = key
                end
            end
        end
        local capture = (rel <= CAPTURE_UNTIL and rel % 5 == 0) or rel == PASS_REL
        if capture then
            write_frame_log(rel, shang, victim)
            queue_snap(string.format("fatality_rel_%03d_shang_%s_victim_%s", rel,
                sorted_labels(shang), sorted_labels(victim)))
        end

        if rel > 250 and (fdeath == 0 or fdeath == 0xffff) then completed = true end
        if rel >= PASS_REL then
            if did_error then
                finish(false, "runtime_error")
            elseif not fdeath_seen then
                finish(false, "f_death_not_seen")
            elseif not (shang_seen["STDEATHBLO1A"] and shang_seen["STDEATHBLO7A"]) then
                finish(false, "drain_body_lane_incomplete")
            elseif not husk_rel then
                finish(false, "corpse1a_husk_not_seen")
            elseif not release_rel then
                finish(false, "release_blo8_not_seen")
            elseif not drop_start_rel then
                finish(false, "corpse_drop_never_started")
            elseif not drop_end_rel then
                finish(false, "corpse_drop_never_landed")
            elseif drop_start_rel + 5 < release_rel then
                finish(false, "corpse_drop_started_before_blo8")
            elseif drop_end_rel < drop_start_rel then
                finish(false, "corpse_drop_out_of_order")
            elseif not blo11_rel then
                finish(false, "blo11_hold_not_seen")
            elseif blo11_rel < release_rel then
                finish(false, "blo11_before_release")
            elseif not completed then
                finish(false, "fatality_not_completed")
            else
                finish(true, "udu_lk_drain_husk_blo8_release_corpsedrop1_8")
            end
            return
        end
    end

    if check_lockup() then finish(false, "mkbug_lockup"); return end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        local _, p1ochar, p2ochar = loaded_fighters_match()
        log("status frame=%d gs=%d fight=%d p1=%d/%d p2=%d/%d ws=%d fdeath=%d input=%s", frame,
            gs, fight_count, r16(A.p1_char), p1ochar, r16(A.p2_char), p2ochar,
            r16(A.winner_status), r16(A.f_death), input_phase() or "-")
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif input_start_frame > 0 and fatality_frame == 0 and frame - input_start_frame > 300 then
        finish(false, "fatality_never_started_after_real_input")
    elseif fight_count == 1 and fighting_frame > 0 and not fighter_verified and frame - fighting_frame > 360 then
        finish(false, "visible_fighters_not_as_selected")
    elseif frame > 14000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function()
    flush_snaps()
end)
