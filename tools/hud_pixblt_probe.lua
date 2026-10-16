-- hud_pixblt_probe.lua
--
-- Ground truth for the PIXBLT B,XY text pass: dump the raw frame-buffer BYTES
-- around where hud_test puts its two strings, on both pages, and mark the two
-- ink indices.  The colour-count test can be fooled - the life bar and the
-- name plate are drawn from boonpal too, so they contain the same indices -
-- and a PNG only shows what CRAM made of a byte.  This shows the bytes.

local LOGP = os.getenv("HUD_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/hud_pixblt_probe.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print("[probe] " .. line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"), f_doscore = sym("f_doscore"),
    pageaddr = sym("pageaddr"),
    hud_ran = sym("hud_ran"), hud_drew = sym("hud_drew"),
    hud_count = sym("hud_count"), hud_list = sym("hud_list"),
    sysfont = sym("sysfont"),
}

local GS_PSEL, GS_FIGHTING = 4, 2
local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function px(page, x, y)
    local w = space:read_u16(page + ((y * 512 + x) * 8))
    return w & 0xff
end

-- Both page bases as flat bit addresses; pageaddr is packed y:x and carries
-- xpadding, and the two pages differ only in y (0 and 256).
local function pages()
    local pa = r32(A.pageaddr)
    local x = pa & 0xffff
    local y = (pa >> 16) & 0xffff
    return (y * 512 + x) * 8, (((y + 256) % 512) * 512 + x) * 8
end

local function dump(tag, page, x0, y0, w, h, marks)
    log("%s  page_base=%08x  x=%d..%d y=%d..%d", tag, page, x0, x0+w-1, y0, y0+h-1)
    for y = y0, y0 + h - 1 do
        local row = {}
        for x = x0, x0 + w - 1 do
            local v = px(page, x, y)
            local ch = marks[v]
            if ch then row[#row+1] = ch
            elseif v == 0 then row[#row+1] = "."
            else row[#row+1] = "-" end
        end
        log("  %3d |%s|", y, table.concat(row))
    end
end

-- Read one glyph out of sysfont so the expected shape is derived from the ROM
-- the game is actually running, not from a copy of DIAGFONT.ASM.
local function glyph(ch)
    local ent = space:read_u32(A.sysfont + (ch - 32) * 32)
    local dydx = space:read_u32(ent)
    local pix  = space:read_u32(ent + 32)
    local w = dydx & 0xffff
    local h = (dydx >> 16) & 0xffff
    local sptch = math.floor((w + 7) / 8) * 8
    local rows = {}
    for r = 0, h - 1 do
        rows[r] = space:read_u16(pix + r * sptch) & 0xff
    end
    return { w = w, h = h, rows = rows, addr = ent, pix = pix }
end

local function finish()
    if done then return end
    done = true
    manager.machine:exit()
end

local fields = {}
local function cache_fields()
    local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- PIXBLT B,XY frame-buffer probe ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 1); w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, 161); w16(A.p1_bar_view, 161)
    w16(A.p2_bar, 7);   w16(A.p2_bar_view, 7)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    if frame - fighting_frame == 200 then
        log("hud_ran=%d hud_drew=%d hud_count=%d f_doscore=%d",
            r16(A.hud_ran), r16(A.hud_drew), r16(A.hud_count), r16(A.f_doscore))
        log("sysfont=%08x", A.sysfont)
        for _, c in ipairs({ 49, 54, 55 }) do   -- '1' '6' '7'
            local g = glyph(c)
            local bits = {}
            for r = 0, g.h - 1 do bits[#bits+1] = string.format("%02x", g.rows[r]) end
            log("  glyph '%s' w=%d h=%d hdr=%08x pix=%08x rows=%s",
                string.char(c), g.w, g.h, g.addr, g.pix, table.concat(bits, " "))
        end

        -- what hud_test actually queued (hud_pass zeroes the count, but the
        -- records themselves stay put)
        for i = 0, 1 do
            local rec = A.hud_list + i * 256
            local xy  = space:read_u32(rec)
            local col = space:read_u32(rec + 32)
            local txt = {}
            for c = 0, 7 do
                local b = space:read_u16(rec + 64 + c * 8) & 0xff
                if b == 0 then break end
                txt[#txt+1] = string.char(b)
            end
            log("  record %d: xy=%08x (x=%d y=%d) col=%08x text=%q",
                i, xy, xy & 0xffff, (xy >> 16) & 0xffff, col, table.concat(txt))
        end

        local pg0, pg1 = pages()
        local marks = { [0x0e] = "W", [0x0c] = "Y" }
        dump("P1 band, plot page", pg0, 26, 20, 40, 22, marks)
        dump("P1 band, other page", pg1, 26, 20, 40, 22, marks)
        dump("P2 band, plot page", pg0, 338, 20, 40, 22, marks)
        finish()
    end
    if frame > 20000 then finish() end
end)
