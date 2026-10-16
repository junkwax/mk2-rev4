-- raiden_bolt_decap_test.lua
--
-- End-to-end MAME harness for Raiden's separate bolt torso rip.
-- It only shortcuts selection and the victim's Finish Him reaction so the game reaches a genuine
-- in-fight Finish Him state.  This test build deliberately uses the scoped
-- Raiden plain-HP hook; retail gameplay continues to use U,U,Forward+HP.
--
-- Default capture policy: one screenshot and one CSV row for every fatality
-- frame from rel=0 through rel=90 (the complete bolt-to-rip impact window),
-- plus key late frames through victory.  The log maps each capture index to
-- its exact emulation frame and fatality-relative frame.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("RAIDEN_BOLT_DECAP_LOG")
    or (ROOT .. "/tools/raiden_bolt_decap_test.log")
local FRAME_LOG_PATH = os.getenv("RAIDEN_BOLT_DECAP_FRAME_LOG")
    or (ROOT .. "/tools/raiden_bolt_decap_frames.csv")
local CAPTURE_UNTIL = getenv_int("RAIDEN_BOLT_DECAP_CAPTURE_UNTIL", 90)
local PASS_REL = getenv_int("RAIDEN_BOLT_DECAP_PASS_REL", 320)
local STAGE_ID = getenv_int("RAIDEN_BOLT_DECAP_STAGE", 5) -- Armory; no stage fatality route.

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(FRAME_LOG_PATH, "w")
if csvfh then
    csvfh:write("capture_index,emu_frame,fatality_rel,f_death,body_frames,bolt_frames,shock_frames,rip_frames,head_process,p1_x,p1_y,p2_x,p2_y,p2_dx,p2_dy,p2_alt_pal\n")
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
    print("[rd-bolt-decap] " .. msg)
end

local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

local function i32(v)
    v = v & 0xffffffff
    return v >= 0x80000000 and (v - 0x100000000) or v
end

-- Resolve symbols from the freshly built linker map.  The fallbacks are only
-- for an early diagnostic if a map is absent; normal runs use the current map.
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
    p1_matchw     = sym("p1_matchw", 0x0112a8c0),
    p2_matchw     = sym("p2_matchw", 0x0112b490),
    round_num     = sym("round_num", 0x0112c0f0),
    p1_jcq        = sym("p1_jcq", 0x0112abe0),
    curback       = sym("curback", 0x0112c0d0),
    worldtlx      = sym("worldtlx", 0x01127430),
    winner_status = sym("winner_status", 0x0112c110),
    f_death       = sym("f_death", 0x0112bfc0),
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
    next = 0x000, id = 0x020, pa10 = 0x080, pa9 = 0x0a0,
    pa8 = 0x0c0, wake = 0x0e0, otherguy = 0x140,
    otherproc = 0x170, action = 0x1f0, ganiy = 0x200,
    flags = 0x210, store4 = 0x290,
}

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local PS_ACTIVE = 1
local FT_RAIDEN, FT_JAX = 7, 11
local MAX_HP = 0x00a1
local ACT_STANCE, ACT_STUNNED = 0x0303, 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL, PM_ALT_PAL = 0x0004, 0x0008, 0x0010, 0x0020
local PID_HEAD = 0x0202
local EXPECTED_FDEATH = 4

local cpu, space = nil, nil
local fields = {}
local charsel_frame, vs_frame, fighting_frame = 0, 0, 0
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
local bolt12_rel = nil
local rip_rel = nil
local rip_visible_rel = nil
local unexpected_head_rel = nil
local completed = false
local did_error = false
local finished = false
local body_seen, bolt_seen, shock_seen, rip_seen = {}, {}, {}, {}
local shock_pose_seen = false
local shock_bob_seen = false
local shock_return_seen = false
local shock_frozen_seen = false
local shock_normal_seen = false
local shock_x_error = false
local shock_anchor_x = nil
local shock_anchor_y = nil
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
        ["P1 Up"] = true, ["P1 Right"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
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

-- Associate every visible multipart piece with its authored body or bolt step.
-- The test reads source TBLs only as labels; it never patches runtime art.
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
load_sag_labels(ROOT .. "/src/MKRD2.TBL", "^(RN2DETHBLO%d+)")
load_sag_labels(ROOT .. "/src/MKBOLTS.TBL", "^(RN2DETHBOLT%d+)")
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXRIPTORSO%d+)")
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXDECAPLEG1)")
load_sag_labels(ROOT .. "/src/MKJX.TBL", "^(JXSTUMBLE6[AB])")

local function add_marker(set, label)
    if label then set[label] = true end
end

local function marker_set()
    local body, bolt, shock, rip = {}, {}, {}, {}
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local obj = r32(list)
        local guard = 0
        while obj ~= 0 and guard < 256 do
            local sag1 = r32(obj + O.osag) & 0x00ffffff
            local img = r32(obj + O.oimg)
            local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
            local label = sag_labels[sag1] or sag_labels[sag2]
            if label then
                if label:match("^RN2DETHBLO") then add_marker(body, label) end
                if label:match("^RN2DETHBOLT") then add_marker(bolt, label) end
                if label:match("^JXSTUMBLE6") then add_marker(shock, label) end
                if label:match("^JXRIPTORSO") or label == "JXDECAPLEG1" then add_marker(rip, label) end
            end
            obj = r32(obj + O.next)
            guard = guard + 1
        end
    end
    return body, bolt, shock, rip
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
        if r16(proc + P.id) == PID_HEAD then
            local obj = r32(proc + P.pa8)
            local yvel = obj ~= 0 and i32(r32(obj + O.oyvel)) or 0
            return proc, obj, yvel
        end
        proc = r32(proc + P.next)
        guard = guard + 1
    end
    return 0, 0, 0
end

local function force_select()
    w16(A.p1_char, FT_RAIDEN)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=Raiden(%d) P2=Jax(%d) stage=%d", FT_RAIDEN, FT_JAX, STAGE_ID)
    end
end

local function loaded_fighters_match()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false, 0xffff, 0xffff end
    local p1char, p2char = r16(p1obj + O.ochar), r16(p2obj + O.ochar)
    return p1char == FT_RAIDEN and p2char == FT_JAX, p1char, p2char
end

local function force_finish_him()
    -- This test ROM reloads a stock match after a forced round end, so retain
    -- the original Raiden/Jax fight and establish Finish Him inside fight 1.
    -- Once the real HP press has transferred into the fatality, do not write
    -- f_death back to zero during the Lua callback before its start monitor
    -- has recorded the new value.
    if fight_count ~= 1 or fatality_frame ~= 0 or r16(A.f_death) ~= 0 then return end
    local fighters_ok, p1ochar, p2ochar = loaded_fighters_match()
    if not fighters_ok then
        if not fighter_verify_logged then
            fighter_verify_logged = true
            log("waiting_for_visible_fighters p1_objchar=%d p2_objchar=%d want=%d/%d", p1ochar, p2ochar, FT_RAIDEN, FT_JAX)
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
    -- Do not alter either health bar.  In this engine a zero bar invokes the
    -- normal round-end path; winner_status plus the victim's dizzy handoff is
    -- the controlled Finish Him context required by fatality_xfer_close.
    local p1proc = r32(A.p1_proc)
    if p1proc ~= 0 then
        w16(p1proc + P.flags, r16(p1proc + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2proc = r32(A.p2_proc)
    if p2proc ~= 0 and not victim_dizzy_forced then
        -- Enter the stock Finish Him victim routine once, then leave its wake
        -- address alone so it can advance into the normal dizzy loop.
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

local function input_phase()
    if input_start_frame == 0 then return nil end
    local rel = frame - input_start_frame
    -- The test-only assembly hook accepts one ordinary High Punch.  It still
    -- traverses fatality_xfer_close and the full controller/reaction path.
    if rel >= 0 and rel < 12 then return "hp_test" end
    return nil
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then return frame >= 220 and frame < 6000 and (frame % 80) < 20 end
        if name == "2 Players Start" then return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55 end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then return frame >= p1_confirm_start and frame < p1_confirm_start + 40 end
        if name == "P2 High Punch" and p1_confirm_start > 0 then return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120 end
    end
    local phase = input_phase()
    if phase == "hp_test" then return name == "P1 High Punch" end
    return false
end

local function dump_queue()
    local ptr = r32(A.p1_jcq)
    local pieces = { string.format("next=%s", hx(ptr)) }
    for i = 1, 6 do
        ptr = ptr - 32
        if ptr <= A.p1_jcq then ptr = A.p1_jcq + 20 * 32 end
        local raw = r32(ptr)
        pieces[#pieces + 1] = string.format("%d:%04x@%04x", i, (raw >> 16) & 0xffff, raw & 0xffff)
    end
    log("queue_after_input %s", table.concat(pieces, " "))
end

local function pxy()
    local p1obj, p2obj = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1obj ~= 0 then p1x, p1y = r16(p1obj + O.oxpos), r16(p1obj + O.oypos) end
    if p2obj ~= 0 then p2x, p2y = r16(p2obj + O.oxpos), r16(p2obj + O.oypos) end
    return p1x, p1y, p2x, p2y
end

local function write_frame_log(rel, body, bolt, shock, rip, head_proc)
    if not csvfh then return end
    local p1x, p1y, p2x, p2y = pxy()
    local p2proc = r32(A.p2_proc)
    local p2alt = p2proc ~= 0 and ((r16(p2proc + P.flags) & PM_ALT_PAL) ~= 0) and 1 or 0
    local p2dx = shock_anchor_x ~= nil and (p2x - shock_anchor_x) or 0
    local p2dy = shock_anchor_y ~= nil and (p2y - shock_anchor_y) or 0
    csvfh:write(string.format("%d,%d,%d,%d,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d\n",
        capture_index, frame, rel, r16(A.f_death), sorted_labels(body), sorted_labels(bolt),
        sorted_labels(shock), sorted_labels(rip), head_proc ~= 0 and 1 or 0,
        p1x, p1y, p2x, p2y, p2dx, p2dy, p2alt))
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
    -- pf_ram legitimately becomes 0xffffffff during ordinary engine work;
    -- only the mapped MKBUG recovery PC interval is a lockup signal here.
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
    if ok then
        log("PASS reason=%s fdeath_seen=%s bolt12_rel=%s rip_rel=%s rip_visible_rel=%s unexpected_head_rel=%s",
            reason, tostring(fdeath_seen), tostring(bolt12_rel), tostring(rip_rel),
            tostring(rip_visible_rel), tostring(unexpected_head_rel))
    else
        log("ERROR reason=%s fdeath_seen=%s bolt12_rel=%s rip_rel=%s rip_visible_rel=%s unexpected_head_rel=%s",
            reason, tostring(fdeath_seen), tostring(bolt12_rel), tostring(rip_rel),
            tostring(rip_visible_rel), tostring(unexpected_head_rel))
    end
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
        log("loaded: P1 Raiden vs P2 Jax; test Finish Him input HP; capture_until=%d", CAPTURE_UNTIL)
    end

    if not space then return end
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1
            fighting_frame = frame
            log("fight_start frame=%d fight=%d", frame, fight_count)
            queue_snap("fight_" .. tostring(fight_count) .. "_start")
        end
        last_gstate = gs
    end

    -- The test-ROM boot path may bypass GS_PSEL entirely.  Seed the character
    -- slots and stage for every pre-fight frame, not only while that screen is
    -- observable, so the first loaded fight is always Raiden versus Jax.
    if fighting_frame == 0 then
        force_select()
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        force_select()
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_RAIDEN and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
    end

    force_finish_him()
    if finish_forced_frame > 0 and dizzy_ready_frame == 0 and victim_ready() then
        dizzy_ready_frame = frame
        input_start_frame = frame + 30
        log("victim_dizzy_ready frame=%d; test HP begins at frame=%d", frame, input_start_frame)
        queue_snap("victim_dizzy_ready")
    end

    local phase = input_phase()
    if phase and not did_input_log then
        did_input_log = true
        log("test_hp_started frame=%d phase=%s", frame, phase)
        queue_snap("input_hp")
    end
    if input_start_frame > 0 and frame == input_start_frame + 42 then
        dump_queue()
        queue_snap("input_complete")
    end

    local fdeath = r16(A.f_death)
    if fdeath == EXPECTED_FDEATH and fatality_frame == 0 then
        fatality_frame = frame
        fdeath_seen = true
        log("fatality_started frame=%d f_death=%d", frame, fdeath)
        queue_snap("fatality_start")
    elseif input_start_frame > 0 and fdeath ~= 0 and fdeath ~= EXPECTED_FDEATH and fatality_frame == 0 then
        did_error = true
        finish(false, "unexpected_f_death_" .. tostring(fdeath))
        return
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local body, bolt, shock, rip = marker_set()
        for label, _ in pairs(body) do body_seen[label] = true end
        for label, _ in pairs(bolt) do bolt_seen[label] = true end
        for label, _ in pairs(shock) do shock_seen[label] = true end
        for label, _ in pairs(rip) do rip_seen[label] = true end

        if next(bolt) ~= nil then
            local _, _, p2x, p2y = pxy()
            if shock_anchor_x == nil then
                shock_anchor_x, shock_anchor_y = p2x, p2y
                log("shock_anchor frame=%d rel=%d x=%d y=%d", frame, rel, p2x, p2y)
            end
            local p2dx, p2dy = p2x - shock_anchor_x, p2y - shock_anchor_y
            if p2dx ~= 0 then shock_x_error = true end
            if p2dy ~= 0 and not shock_bob_seen then
                shock_bob_seen = true
                log("shock_bob_seen frame=%d rel=%d dy=%d", frame, rel, p2dy)
                queue_snap("shock_bob_seen")
            end
            if shock_bob_seen and p2dy == 0 and not shock_return_seen then
                shock_return_seen = true
                log("shock_return_seen frame=%d rel=%d", frame, rel)
                queue_snap("shock_return_seen")
            end
            if next(shock) ~= nil then shock_pose_seen = true end
            local p2proc = r32(A.p2_proc)
            local p2alt = p2proc ~= 0 and ((r16(p2proc + P.flags) & PM_ALT_PAL) ~= 0)
            if p2alt and not shock_frozen_seen then
                shock_frozen_seen = true
                log("shock_frozen_seen frame=%d rel=%d", frame, rel)
                queue_snap("shock_frozen_seen")
            elseif shock_frozen_seen and not p2alt and not shock_normal_seen then
                shock_normal_seen = true
                log("shock_normal_seen frame=%d rel=%d", frame, rel)
                queue_snap("shock_normal_seen")
            end
        end
        if bolt["RN2DETHBOLT12"] and not bolt12_rel then
            bolt12_rel = rel
            log("bolt12_seen frame=%d rel=%d", frame, rel)
            queue_snap("bolt12_seen")
        end

        if rip["JXRIPTORSO1"] and not rip_rel then
            rip_rel = rel
            log("rip_begin_seen frame=%d rel=%d", frame, rel)
            queue_snap("rip_begin")
        end
        if rip["JXRIPTORSO3"] and not rip_visible_rel then
            rip_visible_rel = rel
            log("rip_visible_seen frame=%d rel=%d", frame, rel)
            queue_snap("rip_visible")
        end

        -- A torso rip must never invoke the old high-decap lane.
        local head_proc = find_head()
        if head_proc ~= 0 and not unexpected_head_rel then
            unexpected_head_rel = rel
            log("ERROR unexpected_head_spawned frame=%d rel=%d", frame, rel)
            queue_snap("unexpected_head_spawned")
        end

        local capture = rel <= CAPTURE_UNTIL
            or rel == 100 or rel == 120 or rel == 145 or rel == 160
            or rel == 235 or rel == 250 or rel == PASS_REL
        if capture then
            write_frame_log(rel, body, bolt, shock, rip, head_proc)
            queue_snap(string.format("fatality_rel_%03d_body_%s_bolt_%s_shock_%s_rip_%s", rel,
                sorted_labels(body), sorted_labels(bolt), sorted_labels(shock), sorted_labels(rip)))
        end

        if rel > 230 and (fdeath == 0 or fdeath == 0xffff) then completed = true end
        if rel >= PASS_REL then
            if did_error then
                finish(false, "runtime_error")
            elseif not fdeath_seen then
                finish(false, "f_death_4_not_seen")
            elseif not body_seen["RN2DETHBLO1"] or not body_seen["RN2DETHBLO2"] or not body_seen["RN2DETHBLO3"] then
                finish(false, "native_body_lane_incomplete")
            elseif not bolt12_rel then
                finish(false, "bolt12_not_seen")
            elseif not shock_pose_seen then
                finish(false, "victim_shock_pose_not_seen")
            elseif not shock_bob_seen or not shock_return_seen then
                finish(false, "victim_shock_bob_not_complete")
            elseif not shock_frozen_seen or not shock_normal_seen then
                finish(false, "victim_shock_palette_pulse_not_complete")
            elseif shock_x_error then
                finish(false, "victim_shock_moved_horizontally")
            elseif not rip_seen["JXRIPTORSO1"] or not rip_rel then
                finish(false, "rip_begin_not_seen")
            elseif not rip_seen["JXRIPTORSO3"] or not rip_visible_rel then
                finish(false, "rip_visible_not_seen")
            elseif not rip_seen["JXDECAPLEG1"] then
                finish(false, "rip_legs_not_seen")
            elseif rip_rel < bolt12_rel then
                finish(false, "rip_started_before_bolt12")
            elseif unexpected_head_rel then
                finish(false, "unexpected_decap_head")
            elseif not completed then
                finish(false, "fatality_not_completed")
            else
                finish(true, "test_hp_bolt12_then_reptile_torso_rip")
            end
            return
        end
    end

    if check_lockup() then finish(false, "mkbug_lockup"); return end

    if frame - last_status_frame >= 120 then
        last_status_frame = frame
        local _, p1ochar, p2ochar = loaded_fighters_match()
        log("status frame=%d gs=%d fight=%d p1=%d/%d p2=%d/%d round=%d match=%d/%d ws=%d fdeath=%d input=%s", frame,
            gs, fight_count, r16(A.p1_char), p1ochar, r16(A.p2_char), p2ochar,
            r16(A.round_num), r16(A.p1_matchw), r16(A.p2_matchw), r16(A.winner_status), r16(A.f_death), input_phase() or "-")
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 8000 then
        finish(false, "never_reached_fight")
    elseif fight_count < 1 and fighting_frame > 0 and frame - fighting_frame > 3200 then
        finish(false, "fight_never_reached")
    elseif input_start_frame > 0 and fatality_frame == 0 and frame - input_start_frame > 300 then
        dump_queue()
        finish(false, "fatality_never_started_after_real_input")
    elseif fight_count == 1 and fighting_frame > 0 and not fighter_verified and frame - fighting_frame > 360 then
        finish(false, "visible_fighters_not_raiden_jax")
    elseif frame > 14000 then
        finish(false, "global_timeout")
    end
end)

emu.register_frame_done(function()
    flush_snaps()
end)
