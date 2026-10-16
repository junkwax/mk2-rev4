-- hitbox_color_probe.lua - what byte does the overlay actually leave in VRAM,
-- and what does CRAM turn that byte into?
--
-- MAINEQU's bpal_* names describe the boonpal SOURCE table.  The overlay came
-- out one uniform yellow-orange instead of the six named colours, so this
-- reads the two links in the chain separately:
--    1. the frame-buffer byte on a pixel the overlay definitely wrote
--    2. the full 256-entry CRAM, so that byte can be looked up
--
-- Runs with cb_anchor ONLY (f_colbox = 8): the anchor cross is a known,
-- isolated 11x11 mark centred exactly on the fighter's oxpos/oypos, so there
-- is no ambiguity about which pixels are ours.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = ROOT .. "/tools/hitbox_color_probe.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[colour] " .. line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n) return symbols[n] or 0 end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), worldtly = sym("worldtly"),
    pageaddr = sym("pageaddr"), f_colbox = sym("f_colbox"),
    geo_drew = sym("geo_drew"), ground_y = sym("ground_y"),
}
local CRAM = 0x01800000
local O = { oxpos = 0x090, oypos = 0x0b0 }

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields = {}
local done = false

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1200 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 300 and frame < 1200 and (frame % 60) >= 30 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    return false
end

-- TMS34010 memory space is BIT addressed in MAME, so a pixel at (x,y) on the
-- page whose origin is (px,py) sits at ((py+y)*512 + (px+x)) * 8 bits.
local function pixel_addr(px, py, x, y)
    return ((py + y) * 512 + (px + x)) * 8
end

local function read_byte(addr)
    -- read_u8 on a bit-addressed space still wants the bit address
    local ok, v = pcall(function() return space:read_u8(addr) end)
    if ok then return v end
    return space:read_u16(addr) & 0xff
end

emu.register_frame(function()
    frame = frame + 1
    if done then return end
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
        log("pageaddr sym=%s f_colbox sym=%s", string.format("0x%x", A.pageaddr),
            string.format("0x%x", A.f_colbox))
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = space:read_u16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        space:write_u16(A.p1_state, 1); space:write_u16(A.p2_state, 1)
        space:write_u16(A.p1_char, 1);  space:write_u16(A.p2_char, 1)
        space:write_u16(A.curback, 5)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then fighting_frame = frame end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); manager.machine:exit() end
        return
    end

    -- anchors only, so the cross is unmistakable
    if space:read_u16(A.f_colbox) ~= 8 then space:write_u16(A.f_colbox, 8) end

    if frame - fighting_frame == 240 then
        local page = space:read_u32(A.pageaddr)
        local px, py = page & 0xffff, (page >> 16) & 0xffff
        local p1o = space:read_u32(A.p1_obj)
        local wx = space:read_u32(A.worldtlx) >> 16
        local wy = space:read_u32(A.worldtly) >> 16
        local ax = s16(space:read_u16(p1o + O.oxpos)) - wx
        local ay = s16(space:read_u16(p1o + O.oypos)) - wy
        log("page=(%d,%d) worldtl=(%d,%d) p1 anchor screen=(%d,%d) geo_drew=%d",
            px, py, wx, wy, ax, ay, space:read_u16(A.geo_drew))

        -- the horizontal stroke of the cross runs ax-5 .. ax+5 at row ay
        log("frame-buffer bytes across the anchor cross (row %d):", ay)
        local line = {}
        for dx = -8, 8 do
            local b = read_byte(pixel_addr(px, py, ax + dx, ay))
            line[#line+1] = string.format("%+3d:%02x", dx, b)
        end
        log("  %s", table.concat(line, " "))

        log("frame-buffer bytes down the cross (col %d):", ax)
        line = {}
        for dy = -8, 8 do
            local b = read_byte(pixel_addr(px, py, ax, ay + dy))
            line[#line+1] = string.format("%+3d:%02x", dy, b)
        end
        log("  %s", table.concat(line, " "))

        log("CRAM, all 256 entries (xRRRRRGGGGGBBBBB):")
        for i = 0, 255 do
            local v = space:read_u16(CRAM + i * 16)
            if v ~= 0 then
                local r, g, b = (v >> 10) & 0x1f, (v >> 5) & 0x1f, v & 0x1f
                log("  %3d (%02xh) = %04x -> %3d,%3d,%3d", i, i, v, r*8, g*8, b*8)
            end
        end
        done = true
        manager.machine:exit()
    end
    if frame > 20000 then manager.machine:exit() end
end)
