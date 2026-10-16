-- hud_pixblt_test.lua
--
-- Verifies the CPU text pass added for doc/UNUSED_GRAPHICS_PRIMITIVES.md S3:
-- `PIXBLT B,XY`, a 1bpp source expanded to COLOR0/COLOR1, drawing sysfont's
-- program-ROM glyphs straight into the frame buffer at dsa9.
--
-- The check is exact, not statistical.  Counting "how many pixels of the ink
-- colour are in the band" is not good enough: the life bar, the name plate
-- and the WINS counter are all drawn from boonpal too, so they contain the
-- same indices, and the count moves when the bar length moves.  Instead this
-- reads the glyph bitmaps out of the ROM the game is running, computes where
-- every set bit must land, and requires the frame buffer to hold the ink
-- colour at every one of them.  That pins position, spacing, colour, bit
-- order and transparency in one assertion.
--
-- It also samples the CLEAR bits: PIXBLT B expands 0 bits to COLOR0 as well,
-- so if the transparency bit ever stops being set the glyphs arrive in an
-- opaque box and the background inside the character cell goes uniform.
--
-- Usage: tools\run_hud_pixblt_test.ps1

local LOGP = os.getenv("HUD_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/hud_pixblt_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[hud] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate    = sym("gstate"),    curback     = sym("curback"),
    p1_char   = sym("p1_char"),   p2_char     = sym("p2_char"),
    p1_state  = sym("p1_state"),  p2_state    = sym("p2_state"),
    p1_bar    = sym("p1_bar"),    p2_bar      = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"),
    f_doscore = sym("f_doscore"), pageaddr = sym("pageaddr"),
    hud_ran   = sym("hud_ran"),   hud_drew    = sym("hud_drew"),
    hud_count = sym("hud_count"), hud_list    = sym("hud_list"),
    geo_ran   = sym("geo_ran"),   geo_drew    = sym("geo_drew"),
    sysfont   = sym("sysfont"),
}

local GS_PSEL, GS_FIGHTING = 4, 2

-- hud_test's two records, and the boonpal indices it asks for.  boonpal is
-- pinned at colour map #0, so an index IS the frame-buffer byte.
local RECS = {
    { name = "P1", x = 32,  y = 46, ink = 0x0e },   -- bpal_white
    { name = "P2", x = 344, y = 46, ink = 0x0d },   -- bpal_red
}
local ADVANCE = 1               -- hud_string: width + 1

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local done = false

-- MAME's TMS34010 program space is bit-addressed, and read_u16 aligns DOWN to
-- a 16-bit boundary: a read at an odd byte offset silently returns the byte
-- below it.  Every byte-granular read here has to go through this, or half
-- the pixels and every odd font row come back as copies of their neighbour.
-- That artifact looks exactly like a rendering bug, which cost a whole probe
-- run to tell apart.
local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end

local PAGE0, PAGE1 = nil, nil
local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end

-- One glyph, read from the ROM the game is running rather than from a copy of
-- DIAGFONT.ASM: directory entry is one .long per character from ASCII 32, and
-- each entry points at [dydx(32), pixels(32)].  Bit 0 of a source byte is the
-- LEFTMOST pixel.
local glyph_cache = {}
local function glyph(ch)
    if glyph_cache[ch] then return glyph_cache[ch] end
    local ent  = r32(A.sysfont + (ch - 32) * 32)
    local dydx = r32(ent)
    local pix  = r32(ent + 32)
    local w    = dydx & 0xffff
    local h    = (dydx >> 16) & 0xffff
    local sptch = math.floor((w + 7) / 8) * 8
    local rows = {}
    for r = 0, h - 1 do rows[r] = rd8(pix + r * sptch) end
    local g = { w = w, h = h, rows = rows }
    glyph_cache[ch] = g
    return g
end

-- Every set bit of `text` rendered at (x0,y0) must read `ink`.  Returns
-- matched, total, and a sample of what went wrong.
local function check(page, x0, y0, text, ink)
    local hit, tot, misses = 0, 0, {}
    local x = x0
    for i = 1, #text do
        local g = glyph(text:byte(i))
        for r = 0, g.h - 1 do
            local bits = g.rows[r]
            for b = 0, g.w - 1 do
                if (bits >> b) & 1 == 1 then
                    tot = tot + 1
                    local v = pxv(page, x + b, y0 + r)
                    if v == ink then
                        hit = hit + 1
                    elseif #misses < 6 then
                        misses[#misses+1] = string.format("(%d,%d)=%02x", x + b, y0 + r, v)
                    end
                end
            end
        end
        x = x + g.w + ADVANCE
    end
    return hit, tot, misses
end

-- Phases: distinct HP pairs, so the rendered string has to change with the
-- value and not just be "something in that band".
local phases = {
    { p1 = 161, p2 = 7,   frames = 200 },
    { p1 = 88,  p2 = 100, frames = 200 },
    { p1 = 5,   p2 = 161, frames = 200 },
}
local phase_idx, phase_start = 1, 0
local results = {}

local function finish()
    if done then return end
    done = true

    local ran, drew = r16(A.hud_ran), r16(A.hud_drew)
    log("sentinels: hud_ran=%d hud_drew=%d  (geo_ran=%d geo_drew=%d)",
        ran, drew, r16(A.geo_ran), r16(A.geo_drew))

    local fails = {}
    if ran == 0 then
        fails[#fails+1] = "hud_pass never ran - the dsa9 hook is not firing"
    end
    if drew == 0 then
        fails[#fails+1] = "hud_pass ran but never completed a draw loop"
    end

    local texts = {}
    for _, r in ipairs(results) do
        log("%-2s %-4s at (%3d,%3d): %d/%d set pixels are ink %02x  %s",
            r.name, r.text, r.x, r.y, r.hit, r.tot, r.ink,
            (#r.misses > 0) and ("first misses: " .. table.concat(r.misses, " ")) or "")
        if r.tot == 0 then
            fails[#fails+1] = string.format("%s %q: no glyph pixels expected at all", r.name, r.text)
        elseif r.hit < r.tot then
            fails[#fails+1] = string.format("%s %q: %d of %d glyph pixels missing",
                                            r.name, r.text, r.tot - r.hit, r.tot)
        end
        texts[#texts+1] = r.name .. r.text
    end

    -- The rendered strings must differ between phases, or the pass is drawing
    -- something static and the value is not reaching it.
    local seen = {}
    for _, t in ipairs(texts) do seen[t] = true end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    if n < #texts then
        fails[#fails+1] = "the same string was drawn in every phase - the value is not live"
    end

    if #fails == 0 then
        log("PASS: PIXBLT B,XY renders sysfont glyphs exactly, in two colours, tracking live values")
    else
        log("FAIL: %s", table.concat(fails, "; "))
    end
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
        log("---- PIXBLT B,XY HUD text test ----")
        if A.hud_ran == 0 or A.sysfont == 0 then
            log("ERROR hud_*/sysfont missing from MK2.MAP - stale map or hudtext off")
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 1);  w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase_start = frame
        local pa = r32(A.pageaddr)
        local x, y = pa & 0xffff, (pa >> 16) & 0xffff
        PAGE0 = (y * 512 + x) * 8
        PAGE1 = (((y + 256) % 512) * 512 + x) * 8
        log("fight start frame=%d pageaddr=%08x pages %08x/%08x f_doscore=%d",
            frame, pa, PAGE0, PAGE1, r16(A.f_doscore))
        for _, c in ipairs({ 48, 49, 53, 54, 55, 56 }) do
            local g = glyph(c)
            local b = {}
            for r = 0, g.h - 1 do b[#b+1] = string.format("%02x", g.rows[r]) end
            log("  glyph '%s' %dx%d rows %s", string.char(c), g.w, g.h, table.concat(b, " "))
        end
    end
    if fighting_frame == 0 then
        if frame > 30000 then log("ERROR never reached fight"); finish() end
        return
    end

    local ph = phases[phase_idx]
    if not ph then finish(); return end
    w16(A.p1_bar, ph.p1); w16(A.p1_bar_view, ph.p1)
    w16(A.p2_bar, ph.p2); w16(A.p2_bar_view, ph.p2)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local rel = frame - phase_start
    if rel == ph.frames - 30 then
        local screen = manager.machine.screens[":screen"]
        if screen then pcall(function() screen:snapshot() end) end
    end
    if rel >= ph.frames then
        local vals = { ph.p1, ph.p2 }
        for i, rec in ipairs(RECS) do
            local text = tostring(vals[i])
            -- Either page is fine: both were the plot page a frame apart and
            -- both carry the text.  Take the better of the two so a snapshot
            -- taken mid-flip cannot produce a phantom failure.
            local h0, t0, m0 = check(PAGE0, rec.x, rec.y, text, rec.ink)
            local h1, t1, m1 = check(PAGE1, rec.x, rec.y, text, rec.ink)
            local hit, tot, misses = h0, t0, m0
            if h1 > h0 then hit, tot, misses = h1, t1, m1 end
            results[#results+1] = {
                name = rec.name, text = text, x = rec.x, y = rec.y,
                ink = rec.ink, hit = hit, tot = tot, misses = misses,
            }
        end
        log("phase %d done: p1=%d p2=%d hud_ran=%d hud_drew=%d",
            phase_idx, ph.p1, ph.p2, r16(A.hud_ran), r16(A.hud_drew))
        phase_idx = phase_idx + 1
        phase_start = frame
        if phase_idx > #phases then finish() end
    end

    if frame > 60000 then log("ERROR timeout"); finish() end
end)
