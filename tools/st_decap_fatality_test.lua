-- st_decap_fatality_test.lua
--
-- End-to-end MAME harness for Shang Tsung's Old Shang decapitation
-- (ST1DEATHBLO12-15 windup + STLAUGHFAT1-13 laugh, victim torso rip at the
-- first STLAUGHFAT13, Shang holds STLAUGHFAT13 as his victory pose).
--
-- Modeled on raiden_bolt_decap_test.lua: it only shortcuts selection and the
-- victim's Finish Him reaction so the game reaches a genuine in-fight Finish
-- Him state, then performs the retail Back,Back,Forward,Up + LP input.
-- Retail gameplay keeps the D,D,F+HK Soul Drain input on this button.
--
-- Capture policy: one screenshot every 5 frames from fatality start through
-- rel=CAPTURE_UNTIL, plus every labeled milestone, plus the final victory
-- pose. A CSV row maps each capture to its attacker/victim frame labels.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("ST_DECAP_LOG")
    or (ROOT .. "/tools/st_decap_fatality_test.log")
local FRAME_LOG_PATH = os.getenv("ST_DECAP_FRAME_LOG")
    or (ROOT .. "/tools/st_decap_fatality_frames.csv")
local CAPTURE_UNTIL = getenv_int("ST_DECAP_CAPTURE_UNTIL", 300)
local PASS_REL = getenv_int("ST_DECAP_PASS_REL", 460)
local STAGE_ID = getenv_int("ST_DECAP_STAGE", 5) -- Armory; no stage fatality route.
-- ST_DECAP_MODE=inexp tests the INNER EXPLOSION instead (st_hk_open, MOVES.ASM):
-- hold HK for ST_INEXP_HOLD ticks from outside kick range, let go, and PASS
-- if it fires (ST_INEXP_EXPECT=1, default) or stays quiet (ST_INEXP_EXPECT=0).
local MODE = os.getenv("ST_DECAP_MODE") or "decap"
local INEXP_HOLD = getenv_int("ST_INEXP_HOLD", 180)
local INEXP_EXPECT = getenv_int("ST_INEXP_EXPECT", 1)
local SWEEP_X = getenv_int("ST_DECAP_SWEEP_X", MODE == "inexp" and 110 or 72) -- 0x60 (96px) gate; the two Back taps walk him ~12px further out, so 90 ended past it

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(FRAME_LOG_PATH, "w")
if csvfh then
    csvfh:write("capture_index,emu_frame,fatality_rel,f_death,shang_frames,rip_frames,head_process,p1_x,p1_y,p2_x,p2_y\n")
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
    print("[st-decap] " .. msg)
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
    p1_bar        = sym("p1_bar", 0x0112a910),
    p2_bar        = sym("p2_bar", 0x0112b4e0),
    p1_matchw     = sym("p1_matchw", 0x0112a930),
    p2_matchw     = sym("p2_matchw", 0x0112b500),
    round_num     = sym("round_num", 0x0112c120),
    curback       = sym("curback", 0x0112c0f0),
    winner_status = sym("winner_status", 0x0112c130),
    f_death       = sym("f_death", 0x0112bfe0),
    pf_ram        = sym("pf_ram", 0x0112c0b0),
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
local FT_ST, FT_JAX = 6, 11
local ACT_STUNNED = 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local PID_HEAD = 0x0202
local EXPECTED_FDEATH = 10

local cpu, space = nil, nil
local snd_tap = nil
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
local fdeath_seen = false
local wind_seen, laugh_seen, decap_seen = {}, {}, {}
local fat13_rel = nil
local decap_rel = nil
local knees_rel = nil
local head_rel = nil
local announce_forced = false
local victory_hold_seen = false
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
        ["P1 Low Punch"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Up"] = true, ["P1 High Kick"] = true,
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
load_sag_labels(ROOT .. "/src/STDECAP.TBL", "^(ST1DEATHBLO%d+)")
load_sag_labels(ROOT .. "/src/STDECAP.TBL", "^(STLAUGHFAT%d+)")
load_sag_labels(ROOT .. "/src/STDECAP.TBL", "^(VICTORY%d+)")
-- The STDCP windup wrappers queue the STDEATHBLO11B/C legs first, and the
-- player object's osag exposes only the first-queued piece - so the legs
-- are the observable proxy for the whole windup lane (the ST1DEATHBLO bob
-- art is validated visually via the screenshots).
load_sag_labels(ROOT .. "/src/MKST.TBL", "^(STDEATHBLO11[BC])")
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXDECAPHEAD%d+)")
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXDECAPTORSO%d+)")
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXDECAPLEG%d+)")

local function add_marker(set, label)
    if label then set[label] = true end
end

local function marker_set()
    local shang, decap = {}, {}
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag1 = r32(obj + O.osag) & 0x00ffffff
            local img = r32(obj + O.oimg)
            local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
            local label = sag_labels[sag1] or sag_labels[sag2]
            if label then
                if label:match("^ST1DEATHBLO") or label:match("^STDEATHBLO11")
                    or label:match("^STLAUGHFAT") or label:match("^VICTORY") then
                    add_marker(shang, label)
                end
                if label:match("^JXDECAP") then
                    add_marker(decap, label)
                end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return shang, decap
end

local function sorted_labels(set)
    local items = {}
    for label, _ in pairs(set) do items[#items + 1] = label end
    table.sort(items)
    return #items > 0 and table.concat(items, "+") or "-"
end

local function find_head()
    local proc = r32(A.active)
    local guard = 0
    while proc ~= 0 and guard < 256 do
        if r16(proc + P.id) == PID_HEAD then return proc end
        proc = r32(proc + P.next)
        guard = guard + 1
    end
    return 0
end

local function force_select()
    w16(A.p1_char, FT_ST)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=ShangTsung(%d) P2=Jax(%d) stage=%d", FT_ST, FT_JAX, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    return p1char == FT_ST and p2char == FT_JAX, p1char, p2char
end

local function pxy()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1obj ~= 0 then p1x, p1y = r16(p1obj + O.oxpos), r16(p1obj + O.oypos) end
    if p2obj ~= 0 then p2x, p2y = r16(p2obj + O.oxpos), r16(p2obj + O.oypos) end
    return p1x, p1y, p2x, p2y
end

-- The HK hook is distance-gated (fatality_xfer_close, 0x60 = 96px); snap P1
-- to a deterministic sweep distance left of the victim before the press.
local function snap_sweep_range()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return end
    local p2x = r16(p2obj + O.oxpos)
    local x = p2x - SWEEP_X
    w16(p1obj + O.oxpos, x)
    w32(p1obj + O.oxval, (x << 16) & 0xffffffff)
    log("snap_sweep_range p1_x=%d p2_x=%d dist=%d", x, p2x, SWEEP_X)
end

local function force_finish_him()
    if fight_count ~= 1 or fatality_frame ~= 0 or r16(A.f_death) ~= 0 then return end
    local fighters_ok, p1ochar, p2ochar = loaded_fighters_match()
    if not fighters_ok then
        if not fighter_verify_logged then
            fighter_verify_logged = true
            log("waiting_for_visible_fighters p1_objchar=%d p2_objchar=%d want=%d/%d", p1ochar, p2ochar, FT_ST, FT_JAX)
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

-- The retail fatality input: Back, Back, Forward, Up + LP.  P1 is snapped
-- to the left of the victim (facing right), so Back = Left, Forward =
-- Right.  Discrete presses with release gaps so the joystick queue records
-- each switch transition; the whole run fits the 0x40(+6)-tick window.
local COMBO_SCRIPT = {
    { 0,   8, "P1 Left" },
    { 12, 20, "P1 Left" },
    { 24, 32, "P1 Right" },
    { 36, 44, "P1 Up" },
    { 37, 47, "P1 Low Punch" },   -- one tick after Up: any later and Shang is already airborne
}
if MODE == "inexp" then COMBO_SCRIPT = { { 0, INEXP_HOLD, "P1 High Kick" } } end
local COMBO_LEN = MODE == "inexp" and INEXP_HOLD + 2 or 60

local function input_phase()
    if input_start_frame == 0 then return nil end
    local rel = frame - input_start_frame
    if rel >= 0 and rel < COMBO_LEN then return "combo" end
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

local function write_frame_log(rel, shang, decap, head_proc)
    if not csvfh then return end
    local p1x, p1y, p2x, p2y = pxy()
    csvfh:write(string.format("%d,%d,%d,%d,%s,%s,%d,%d,%d,%d,%d\n",
        capture_index, frame, rel, r16(A.f_death), sorted_labels(shang),
        sorted_labels(decap), head_proc ~= 0 and 1 or 0, p1x, p1y, p2x, p2y))
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
    local wind = sorted_labels(wind_seen)
    local laugh = sorted_labels(laugh_seen)
    local decap = sorted_labels(decap_seen)
    if ok then
        log("PASS reason=%s fdeath_seen=%s fat13_rel=%s decap_rel=%s knees_rel=%s head_rel=%s victory_hold=%s wind=%s laugh=%s decap=%s",
            reason, tostring(fdeath_seen), tostring(fat13_rel), tostring(decap_rel),
            tostring(knees_rel), tostring(head_rel), tostring(victory_hold_seen), wind, laugh, decap)
    else
        log("ERROR reason=%s fdeath_seen=%s fat13_rel=%s decap_rel=%s knees_rel=%s head_rel=%s victory_hold=%s wind=%s laugh=%s decap=%s",
            reason, tostring(fdeath_seen), tostring(fat13_rel), tostring(decap_rel),
            tostring(knees_rel), tostring(head_rel), tostring(victory_hold_seen), wind, laugh, decap)
    end
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        -- Sound-board port (@sound, SYSEQU.ASM): send_code_a3 writes the
        -- high byte then the low byte.  Log every code once the fatality is
        -- under way so the laugh (02e9h..) and the morph layered under it
        -- (01ddh.. - +1/+2 = channel 2/3) can be read off the log.
        local snd_hi = nil
        snd_tap = space:install_write_tap(0x1d01030, 0x1d0103f, "st_decap_snd", function(offset, data, mask)
            local b = data & 0xff
            if snd_hi == nil then snd_hi = b return end
            local code = (snd_hi << 8) | b
            snd_hi = nil
            if fatality_frame > 0 then log("sndcode frame=%d rel=%d code=%04x", frame, frame - fatality_frame, code) end
        end)
        if not cache_fields() then
            finish(false, "required_input_missing")
            return
        end
        log("loaded: P1 ShangTsung vs P2 Jax; test Finish Him input HK; capture_until=%d", CAPTURE_UNTIL)
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
            and r16(A.p1_char) == FT_ST and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
    end

    force_finish_him()
    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        dizzy_ready_frame = frame
        input_start_frame = frame + 30
        snap_sweep_range()
        log("victim_dizzy_ready frame=%d; combo input begins at frame=%d", frame, input_start_frame)
        queue_snap("victim_dizzy_ready")
    end

    local phase = input_phase()
    if phase and not did_input_log then
        did_input_log = true
        log("combo_input_started frame=%d phase=%s", frame, phase)
        queue_snap("input_hk")
    end

    local fdeath = r16(A.f_death)
    if MODE == "inexp" and input_start_frame > 0 then
        local since_release = frame - input_start_frame - INEXP_HOLD
        if fdeath ~= 0 and fdeath ~= 0xffff then
            log("inexp_fired hold=%d since_release=%d f_death=%d", INEXP_HOLD, since_release, fdeath)
            queue_snap("inexp_fired")
            finish(INEXP_EXPECT == 1, "inexp_fired_hold_" .. INEXP_HOLD)
            return
        elseif since_release > 150 then
            log("inexp_quiet hold=%d ws=%d p2_bar=%d", INEXP_HOLD, r16(A.winner_status), r16(A.p2_bar))
            finish(INEXP_EXPECT == 0, "inexp_not_fired_hold_" .. INEXP_HOLD)
            return
        end
    end
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
        local shang, decap = marker_set()
        for label, _ in pairs(shang) do
            if label:match("^ST1DEATHBLO") or label:match("^STDEATHBLO11") then
                wind_seen[label] = true
            end
            if label:match("^STLAUGHFAT") then laugh_seen[label] = true end
        end
        for label, _ in pairs(decap) do decap_seen[label] = true end

        if shang["STLAUGHFAT13"] and not fat13_rel then
            fat13_rel = rel
            log("fat13_seen frame=%d rel=%d", frame, rel)
            queue_snap("fat13_contact")
        end
        -- The victim's osag exposes the leg piece of each JXDECAP wrapper
        -- (the torso piece is not the last-queued blit), so the leg labels
        -- are the observable 1:1 proxy for the decap body frames.
        if decap["JXDECAPLEG1"] and not decap_rel then
            decap_rel = rel
            log("decap_begin_seen frame=%d rel=%d", frame, rel)
            queue_snap("decap_begin")
        end
        if decap["JXDECAPLEG3"] and not knees_rel then
            knees_rel = rel
            log("decap_knees_seen frame=%d rel=%d", frame, rel)
            queue_snap("decap_knees")
        end

        -- The stock decapitation must spawn the detached-head process.
        local head_proc = find_head()
        if head_proc ~= 0 and not head_rel then
            head_rel = rel
            log("head_process_seen frame=%d rel=%d", frame, rel)
            queue_snap("head_spawned")
        end

        -- This harness forced Finish Him mid-round, so the game's play loop
        -- never reaches the winner declaration that follows a real fatality
        -- (MAIN's play4).  The controller now gates its recovery + victory
        -- frames on that declaration; mimic it once the fatality completes.
        if not announce_forced and (fdeath == 0 or fdeath == 0xffff) then
            announce_forced = true
            w16(A.winner_status, 1)
            log("victory_announce_forced frame=%d rel=%d", frame, rel)
            queue_snap("victory_announce")
        end

        -- Victory pose: after the fatality completes Shang plays the
        -- VICTORY1-3 sequence and holds VICTORY3 on screen.
        if (fdeath == 0 or fdeath == 0xffff) and rel > 250 and shang["VICTORY3"] then
            if not victory_hold_seen then
                victory_hold_seen = true
                log("victory_hold_seen frame=%d rel=%d", frame, rel)
                queue_snap("victory_hold_v3")
            end
        end

        local capture = (rel <= CAPTURE_UNTIL and rel % 5 == 0)
            or rel == 320 or rel == 360 or rel == 400 or rel == PASS_REL
        if capture then
            write_frame_log(rel, shang, decap, head_proc)
            queue_snap(string.format("fatality_rel_%03d_shang_%s_decap_%s", rel,
                sorted_labels(shang), sorted_labels(decap)))
        end

        if rel > 250 and (fdeath == 0 or fdeath == 0xffff) then completed = true end
        if rel >= PASS_REL then
            if did_error then
                finish(false, "runtime_error")
            elseif not fdeath_seen then
                finish(false, "f_death_10_not_seen")
            elseif not wind_seen["STDEATHBLO11B"] then
                finish(false, "windup_legs_not_seen")
            elseif not (laugh_seen["STLAUGHFAT1"] and laugh_seen["STLAUGHFAT9"]
                and laugh_seen["STLAUGHFAT12"]) then
                finish(false, "laugh_lane_incomplete")
            elseif not fat13_rel then
                finish(false, "fat13_not_seen")
            elseif not decap_rel then
                finish(false, "decap_begin_not_seen")
            elseif not knees_rel then
                finish(false, "decap_knees_not_seen")
            elseif not head_rel then
                finish(false, "detached_head_not_seen")
            elseif decap_rel + 5 < fat13_rel then
                finish(false, "decap_started_before_fat13")
            elseif not victory_hold_seen then
                finish(false, "victory_v3_hold_not_seen")
            elseif not completed then
                finish(false, "fatality_not_completed")
            else
                finish(true, "test_hk_windup_laugh_fat13_decap_victory123")
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

    if input_start_frame > 0 and frame - input_start_frame < 80 then
        local p1x, p1y = pxy()
        local p1p = r32(A.p1_proc)
        local held = {}
        for name, _ in pairs(fields) do if pressed(name) then held[#held + 1] = name end end
        log("combo rel=%d p1x=%d p1y=%d act=%04x held=%s", frame - input_start_frame, p1x, p1y,
            p1p ~= 0 and r16(p1p + P.action) or 0, table.concat(held, "+"))
    end
    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif MODE ~= "inexp" and input_start_frame > 0 and fatality_frame == 0 and frame - input_start_frame > 300 then
        finish(false, "fatality_never_started_after_real_input")
    elseif fight_count == 1 and fighting_frame > 0 and not fighter_verified and frame - fighting_frame > 360 then
        finish(false, "visible_fighters_not_st_jax")
    elseif frame > 14000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function()
    flush_snaps()
end)
