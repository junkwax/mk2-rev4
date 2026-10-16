--- raiden_victory_lanetrim.lua - which lane draws the armpit specks?
---
--- During Raiden's held victory pose (RNVICTORY7) ~15 px are drawn beside his
--- right armpit that do NOT exist in the authored art: the four RNVICTORY7A-D
--- chunks reassemble the composite record pixel-for-pixel, and the lane RAM at
--- runtime matches the source table exactly.  The specks land on the LAST THREE
--- ROWS of chunk C (local x 1..9, y 55..57), which is what a decode over-run at
--- the end of a chunk's packed data looks like.
---
--- This patches the frame record's HEIGHT in the program ROM image mid-pose and
--- snapshots before/after.  If trimming chunk C's height kills the specks, the
--- over-run is chunk C's; the same is then tried on chunk D as a control.
---
--- Record offsets (byte offsets into the :maincpu ROM image, found by matching
--- the 14-byte record from src/MKRD.TBL against rom/mk2_flat.bin):
---     RNVICTORY7A 0x87258   RNVICTORY7B 0x87266
---     RNVICTORY7C 0x87274   RNVICTORY7D 0x87282
--- layout: .word w,h,anix,aniy / .long sag / .word ctrl  -> h is at record+2.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = os.getenv("RDLT_LOG") or (ROOT .. "/tools/raiden_victory_lanetrim.log")

local REC_C, REC_D = 0x87274, 0x87282
local H_OFF = 2

local logfh = io.open(LOG_PATH, "w")
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
    print("[rdlt] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), winner_status = sym("winner_status"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"), curback = sym("curback"),
}
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_RAIDEN, FT_JAX = 7, 11

local cpu, space, rgn, fields = nil, nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm_start = 0, 0, 0
local killed_frame, win_frame = 0, 0
local finished, snap_index = false, 0

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function find_region()
    for _, tag in ipairs({ ":maincpu", "maincpu" }) do
        local ok, r = pcall(function() return manager.machine.memory.regions[tag] end)
        if ok and r then log("region %s size=%d", tag, r.size); return r end
    end
    return nil
end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                     ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %s MISSING", name); return false end
    end
    return true
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s", snap_index, frame, label, tostring(ok))
    snap_index = snap_index + 1
end

local function set_height(rec, h)
    local before = rgn:read_u16(rec + H_OFF)
    rgn:write_u16(rec + H_OFF, h)
    log("rec 0x%x height %d -> %d (readback %d)", rec, before, h, rgn:read_u16(rec + H_OFF))
end

-- live multipart lane RAM: lane n at oimg + n*0x70; sag(32) sizex(16) sizey(16)
-- ctrl(16) dx(16) dy(16)
local LANE = 0x70
local function lane_addr(n) 
    local obj = space:read_u32(sym("p1_obj"))
    if obj == 0 then return 0 end
    local img = space:read_u32(obj + 0x1a0)
    if img == 0 then return 0 end
    return img + n * LANE
end
local function lane_poke(n, off, v, what)
    local a = lane_addr(n)
    if a == 0 then log("lane%d: no object", n); return end
    local before = space:read_u16(a + off)
    space:write_u16(a + off, v & 0xffff)
    log("lane%d %s %d -> %d (readback %d)", n, what, before, v, space:read_u16(a + off))
end
local saved_sag = {}
local function sag_zero(n)
    local a = lane_addr(n)
    if a == 0 then log("lane%d: no object", n); return end
    saved_sag[n] = { space:read_u16(a), space:read_u16(a + 0x10) }
    space:write_u16(a, 0); space:write_u16(a + 0x10, 0)
    log("lane%d sag zeroed (was 0x%04x%04x, now 0x%04x%04x)", n,
        saved_sag[n][2], saved_sag[n][1], space:read_u16(a + 0x10), space:read_u16(a))
end

local function lane_report()
    for n = 0, 3 do
        local a = lane_addr(n)
        if a ~= 0 then
            log("  lane%d sag=0x%08x size=%dx%d d=(%d,%d)", n, space:read_u32(a),
                space:read_u16(a + 0x20), space:read_u16(a + 0x30),
                space:read_u16(a + 0x50), space:read_u16(a + 0x60))
        end
    end
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("%s reason=%s", ok and "DONE" or "FAIL", reason)
    if logfh then logfh:flush() end
    manager.machine:exit()
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
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        rgn = find_region()
        if not rgn then finish(false, "no_maincpu_region"); return end
        if not cache_fields() then finish(false, "input_missing"); return end
        log("lane-trim probe")
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX); w16(A.curback, 5)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_RAIDEN and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    end

    if fighting_frame > 0 and killed_frame == 0 and frame > fighting_frame + 150 then
        w16(A.p2_bar, 0); killed_frame = frame
    end
    if killed_frame > 0 and win_frame == 0 then
        local ws = r16(A.winner_status)
        if ws == 1 or ws == 2 then win_frame = frame; log("winner_declared frame=%d", frame) end
    end

    if win_frame > 0 then
        local rel = frame - win_frame
        if rel == 120 then lane_report(); snap("verify_120")
        elseif rel == 150 then snap("verify_150")
        elseif rel == 200 then snap("verify_200"); finish(true, "verify_complete"); return
        end
    end

    if frame > 6000 and win_frame == 0 then finish(false, "never_reached_victory"); return end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
