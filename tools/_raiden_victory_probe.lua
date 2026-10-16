-- raiden_victory_probe.lua
--
-- Runtime review harness for Shang Tsung's TSUNG8.IMG sequence 3 (LAFF)
-- victory animation.  It direct-selects P1 Shang, lets the game enter a real
-- fight, sets only P2's health to zero, then waits for the normal winner path.
-- It deliberately does not invoke a fatality or patch victory code.
--
-- The sixteen screenshots are emitted only for the LAFF samples, in source
-- order.  Therefore the snapshot directory's 0000.png through 0015.png map
-- directly to CSV rows 0 through 15.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local LOG_PATH = os.getenv("SHANG_LAFF_LOG")
    or (ROOT .. "/tools/raiden_victory_probe.log")
local CSV_PATH = os.getenv("SHANG_LAFF_CSV")
    or (ROOT .. "/tools/raiden_victory_probe.csv")

local logfh = io.open(LOG_PATH, "w")
local csvfh = io.open(CSV_PATH, "w")
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
    local message = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[stlaff] " .. message)
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
        log("ERROR unable to read mk2.map")
    end
end

local function sym(name, fallback)
    local value = symbols[name]
    if value ~= nil then return value end
    log("WARN missing symbol %s; using %s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    gstate        = sym("gstate", 0x0112a7d0),
    p1_char       = sym("p1_char", 0x0112a880),
    p2_char       = sym("p2_char", 0x0112b450),
    p1_obj        = sym("p1_obj", 0x0112a820),
    p1_proc       = sym("p1_proc", 0x0112a860),
    p1_bar        = sym("p1_bar", 0x0112a8f0),
    p2_bar        = sym("p2_bar", 0x0112b4c0),
    p1_bar_view   = sym("p1_bar_view", 0x011285f0),
    p2_bar_view   = sym("p2_bar_view", 0x01128530),
    winner_status = sym("winner_status", 0x0112c110),
}

local O = {
    oimg = 0x1a0,
}

local MP_SAG = 0x000
local MP_LEN = 0x070

local GS_PSEL = 4
local GS_POST = 0x0d
local GS_FIGHTING = 2
local FT_SHANG = 7  -- Raiden
local FT_JAX = 11
local MAX_HP = 0x00a1

-- Direct CAGE/WIMP order from TSUNG8.IMG sequence 3, LAFF, followed by
-- the original STVIC1 terminal pose (STDEATHBLO11 multipart art).
local EXPECTED = { 12, 13, 14, 15, 14, 13, 14, 15, 14, 15, 14, 13, 12, 13, 14, 13, 11 }
-- Victory loops conventionally present each native entry for six scheduler ticks.
local PRESENTATION_TICKS = 6

local function load_stage_markers(path)
    local markers = {}
    local count = 0
    local fh = io.open(path, "r")
    if not fh then
        log("ERROR unable to read sprite table %s", path)
        return markers, count
    end

    local stage = nil
    for line in fh:lines() do
        local label = line:match("^%s*([%w_]+):")
        if label then
            local candidate = tonumber(label:match("^STDEATHBLO(%d%d)[ABCD]$"))
            stage = candidate and candidate >= 11 and candidate <= 15 and candidate or nil
        end
        if stage then
            local hex = line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
            if hex then
                markers[tonumber(hex, 16) & 0x00ffffff] = stage
                count = count + 1
                stage = nil
            end
        end
    end
    fh:close()
    return markers, count
end

local stage_markers, stage_marker_count = load_stage_markers(ROOT .. "/src/MKST.TBL")

local frame = 0
local cpu = nil
local space = nil
local fields = {}
local charsel_frame = 0
local vs_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local force_win_frame = 0
local round_end_seen = false
local laff_start_frame = 0
local capture_index = 0
local last_gstate = -1
local last_winner_status = -1
local finished = false

local function r16(addr)
    return space and space:read_u16(addr) or 0
end

local function r32(addr)
    return space and space:read_u32(addr) or 0
end

local function w16(addr, value)
    if space then space:write_u16(addr, value & 0xffff) end
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["1 Player Start"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
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

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end

    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 45
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end
    return false
end

local function main_screen()
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then return screen end
    ok, screen = pcall(function() return manager.machine.screens:at(1) end)
    if ok and screen then return screen end
    return nil
end

local function snap(label)
    local screen = main_screen()
    if not screen then
        log("ERROR no screen for snapshot label=%s", label)
        return false
    end
    local ok, err = pcall(function() screen:snapshot() end)
    log("SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err))
    return ok
end

local function current_laff_stage()
    local obj = r32(A.p1_obj)
    if obj == 0 then return 0, "" end
    local img = r32(obj + O.oimg)
    if img == 0 then return 0, "" end

    local stage = 0
    local parts = {}
    for i = 0, 7 do
        local sag = r32(img + i * MP_LEN + MP_SAG) & 0x00ffffff
        if sag == 0 then break end
        parts[#parts + 1] = string.format("%06x", sag)
        local candidate = stage_markers[sag]
        if candidate then
            -- STVIC2..5 share STDEATHBLO11 lower-body parts with STVIC1.
            -- The higher-numbered upper-body marker identifies the active pose.
            if candidate > stage then stage = candidate end
        end
    end
    return stage, table.concat(parts, ":")
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    if csvfh then csvfh:flush(); csvfh:close(); csvfh = nil end
    if ok then
        log("PASS reason=%s samples=%d", reason, capture_index)
    else
        log("ERROR reason=%s samples=%d", reason, capture_index)
    end
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    if not space or charsel_frame == 0 then return end
    w16(A.p1_char, FT_SHANG)
    w16(A.p2_char, FT_JAX)
end

local function force_normal_round_win()
    if force_win_frame ~= 0 or fighting_frame == 0 then return end
    if frame - fighting_frame < 180 then return end
    if r16(A.p1_char) ~= FT_SHANG then
        finish(false, "p1_not_shang")
        return
    end
    -- Preserve P1, exhaust P2, and let stock combat code choose the winner.
    -- Do not write f_death, winner_status, a process wake target, or a PC.
    w16(A.p1_bar, MAX_HP)
    w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, 0)
    w16(A.p2_bar_view, 0)
    force_win_frame = frame
    log("forced ordinary P1 round win at frame=%d (P2 bar only)", frame)
end

local function capture_laff_sample(stage, nodes)
    local expected = EXPECTED[capture_index + 1]
    local rel = frame - laff_start_frame
    local label = string.format("laff_%02d_stage%02d", capture_index, expected)
    local expected_rel = capture_index * PRESENTATION_TICKS
    if rel ~= expected_rel then
        log("ERROR LAFF tick gap: sample=%d expected_rel=%d actual_rel=%d", capture_index, expected_rel, rel)
        finish(false, "laff_tick_gap")
        return
    end
    if csvfh then
        csvfh:write(string.format("%d,%d,%d,%d,%d,%s\n",
            capture_index, frame, rel, expected, stage, nodes))
        csvfh:flush()
    end
    snap(label)
    log("sample=%02d rel=%d expected=STDEATHBLO%d actual=STDEATHBLO%d nodes=%s",
        capture_index, rel, expected, stage, nodes)
    if stage ~= expected then
        finish(false, "laff_order_mismatch")
        return
    end
    capture_index = capture_index + 1
    if capture_index == #EXPECTED then
        finish(true, "all_16_native_laff_samples")
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        if csvfh then
            csvfh:write("capture_index,emu_frame,laff_rel,expected_stage,actual_stage,multipart_sags\n")
            csvfh:flush()
        end
        log("loaded: select P1 Shang, force ordinary win, capture TSUNG8 LAFF; markers=%d", stage_marker_count)
    end

    if space and not finished then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                log("fight started frame=%d P1=%d P2=%d", frame, r16(A.p1_char), r16(A.p2_char))
            end
            last_gstate = gs
        end

        if gs == GS_PSEL and charsel_frame > 0 then
            force_select()
            if p1_confirm_start == 0 and frame - charsel_frame > 90 and r16(A.p1_char) == FT_SHANG then
                p1_confirm_start = frame
                log("P1 Shang selected; confirm starts frame=%d", p1_confirm_start)
            end
        end

        force_normal_round_win()

        local winner_status = r16(A.winner_status)
        if winner_status ~= last_winner_status then
            log("frame=%d winner_status %d -> %d", frame, last_winner_status, winner_status)
            last_winner_status = winner_status
        end
        if force_win_frame ~= 0 and winner_status ~= 0 then round_end_seen = true end

        -- Raiden victory probe: once the round ends, snapshot every 8
        -- frames for ~30 samples to catch the whole victory pose + bolts.
        if round_end_seen then
            if laff_start_frame == 0 then
                laff_start_frame = frame
                log("victory window begins frame=%d", frame)
            end
            local rel = frame - laff_start_frame
            if rel % 8 == 0 and capture_index < 30 then
                snap(string.format("rdvic_%02d", capture_index))
                capture_index = capture_index + 1
                if capture_index == 30 then
                    finish(true, "raiden_victory_sampled")
                end
            end
        end

        if force_win_frame ~= 0 and frame - force_win_frame > 2200 and laff_start_frame == 0 then
            finish(false, "victory_never_started")
            return
        end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if not finished and frame > 11000 then
        finish(false, "global_timeout")
    end
end)
