--- raiden_victory_ctrlsweep.lua - exact extra-pixel measurement + DMA ctrl sweep
---
--- The specks on Raiden's held victory pose sit on the EDGE ROWS of the four
--- RNVICTORY7 chunks (first row of B, last row of A, last row of C), so they
--- are a per-chunk decode edge effect, not one bad chunk.  The chunks are drawn
--- with zero compression on (ctrl bit 7) plus leading/trailing zero multipliers
--- (bits 8-9 / 10-11).  If the multipliers in the table do not match what LOAD2
--- actually packed, the run-length decode lands junk at the row extremes.
---
--- Phase 1: snapshot the pose with all lanes, then with the lane walk cut at
---          lane 0 (nothing drawn).  Diffing those two offline gives the EXACT
---          set of pixels the object draws - no background coincidences.
--- Phase 2: sweep the leading/trailing zero multiplier bits in every lane's
---          live ctrl word and snapshot each, to see if any setting draws the
---          authored art with no junk.
---
--- lane RAM: sag(32) sizex(16) sizey(16) ctrl(16) dx(16) dy(16), stride 0x70.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = os.getenv("RDCS_LOG") or (ROOT .. "/tools/raiden_victory_ctrlsweep.log")

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
    print("[rdcs] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
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
    p1_obj = sym("p1_obj"), p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    curback = sym("curback"),
}
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_RAIDEN, FT_JAX = 7, 11

local space, fields = nil, {}
local last_gstate = -1
local charsel_frame, fight_start, p1_confirm_start = 0, 0, 0
local killed_frame, win_frame = 0, 0
local finished, snap_index = false, 0
local saved_sag, saved_ctrl = nil, {}

local LANE = 0x70
local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function lane_addr(n)
    local obj = space:read_u32(A.p1_obj)
    if obj == 0 then return 0 end
    local img = space:read_u32(obj + 0x1a0)
    if img == 0 then return 0 end
    return img + n * LANE
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
    log("SNAP idx=%04d label=%s ok=%s", snap_index, label, tostring(ok))
    snap_index = snap_index + 1
end

-- ctrl variants: keep bpp (bits 12-14) and compression (bit 7); sweep the
-- leading (bits 8-9) and trailing (bits 10-11) zero multipliers.
local CTRL_VARIANTS = { 0x0400, 0x0000, 0x0100, 0x0200, 0x0300, 0x0500, 0x0600,
                        0x0700, 0x0800, 0x0900, 0x0a00, 0x0b00, 0x0c00, 0x0d00,
                        0x0e00, 0x0f00 }
local variant_i = 0

local function set_all_ctrl(mult_bits)
    for n = 0, 3 do
        local a = lane_addr(n)
        if a ~= 0 then
            if not saved_ctrl[n] then saved_ctrl[n] = r16(a + 0x40) end
            local base = saved_ctrl[n] & ~0x0f00
            w16(a + 0x40, base | mult_bits)
        end
    end
    log("ctrl multipliers -> 0x%04x (lane0 ctrl now 0x%04x)", mult_bits, r16(lane_addr(0) + 0x40))
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
    if charsel_frame > 0 and fight_start == 0 and p1_confirm_start > 0 then
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
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("ctrl sweep probe")
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fight_start == 0 then fight_start = frame end
        last_gstate = gs
    end

    if fight_start == 0 then
        w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX); w16(A.curback, 5)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_RAIDEN and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    end

    if fight_start > 0 and killed_frame == 0 and frame > fight_start + 150 then
        w16(A.p2_bar, 0); killed_frame = frame
    end
    if killed_frame > 0 and win_frame == 0 then
        local ws = r16(A.winner_status)
        if ws == 1 or ws == 2 then win_frame = frame end
    end

    if win_frame > 0 then
        local rel = frame - win_frame
        if rel == 110 then snap("00_all_lanes")
        elseif rel == 112 then
            local a = lane_addr(0)
            saved_sag = { r16(a), r16(a + 0x10) }
            w16(a, 0); w16(a + 0x10, 0)
        elseif rel == 116 then snap("01_no_lanes")
        elseif rel == 118 then
            local a = lane_addr(0)
            w16(a, saved_sag[1]); w16(a + 0x10, saved_sag[2])
        elseif rel >= 124 and (rel - 124) % 6 == 0 then
            local step = (rel - 124) // 6
            if step % 2 == 0 then
                variant_i = variant_i + 1
                if variant_i > #CTRL_VARIANTS then
                    local a = lane_addr(1)
                    if saved_ctrl[1] then w16(a + 0x40, saved_ctrl[1]) end
                    finish(true, "b_sweep_complete")
                    return
                end
                -- chunk B (lane 1) ONLY
                local a = lane_addr(1)
                if not saved_ctrl[1] then saved_ctrl[1] = r16(a + 0x40) end
                local base = saved_ctrl[1] & ~0x0f00
                w16(a + 0x40, base | CTRL_VARIANTS[variant_i])
                log("lane1 ctrl 0x%04x -> 0x%04x", saved_ctrl[1], r16(a + 0x40))
            else
                snap(string.format("B_%02d_%04x", variant_i, CTRL_VARIANTS[variant_i]))
            end
        end
    end

    if frame > 6000 and win_frame == 0 then finish(false, "never_reached_victory"); return end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
