-- hud_pixblt_testmode.lua
--
-- Same exact-glyph verification as hud_pixblt_test.lua, but for the
-- test_mode=1 ROM, which boots straight into a fight.  That matters right now
-- because the current tree wedges at gs_post_psel on the way out of character
-- select - reproducibly, and with the HUD text pass compiled out - so the
-- normal harness cannot reach a fight at all.  Booting past the broken screen
-- keeps this feature testable while that is someone else's problem.
--
-- Verdict logic is identical: read the glyph bitmaps out of the running ROM,
-- compute where every set bit must land, and require the frame buffer to hold
-- the requested palette index at every one of them.

local LOGP = os.getenv("HUD_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/hud_pixblt_testmode.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[hud] " .. string.format(fmt, ...)
    print(line)
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
    gstate = sym("gstate"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), f_freeze_timer = sym("f_freeze_timer"),
    f_doscore = sym("f_doscore"), pageaddr = sym("pageaddr"),
    hud_ran = sym("hud_ran"), hud_drew = sym("hud_drew"),
    hud_count = sym("hud_count"), hud_list = sym("hud_list"),
    geo_ran = sym("geo_ran"), geo_drew = sym("geo_drew"),
    sysfont = sym("sysfont"),
}

local GS_FIGHTING = 2
local RECS = {
    { name = "P1", x = 32,  y = 46, ink = 0x0e },   -- bpal_white
    { name = "P2", x = 344, y = 46, ink = 0x0d },   -- bpal_red
}
local ADVANCE = 1

local frame, space = 0, nil
local fighting_frame, done = 0, false
local PAGE0, PAGE1

-- MAME's TMS34010 program space is bit-addressed and read_u16 aligns DOWN to
-- a 16-bit boundary, so every byte-granular read has to go through this or
-- odd addresses silently return their neighbour.
local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end

local glyph_cache = {}
local function glyph(ch)
    if glyph_cache[ch] then return glyph_cache[ch] end
    local ent  = r32(A.sysfont + (ch - 32) * 32)
    local dydx = r32(ent)
    local pix  = r32(ent + 32)
    local w, h = dydx & 0xffff, (dydx >> 16) & 0xffff
    local sptch = math.floor((w + 7) / 8) * 8
    local rows = {}
    for r = 0, h - 1 do rows[r] = rd8(pix + r * sptch) end
    local g = { w = w, h = h, rows = rows }
    glyph_cache[ch] = g
    return g
end

local function check(page, x0, y0, text, ink)
    local hit, tot, misses = 0, 0, {}
    local x = x0
    for i = 1, #text do
        local g = glyph(text:byte(i))
        for r = 0, g.h - 1 do
            for b = 0, g.w - 1 do
                if (g.rows[r] >> b) & 1 == 1 then
                    tot = tot + 1
                    local v = pxv(page, x + b, y0 + r)
                    if v == ink then hit = hit + 1
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

local phases = {
    { p1 = 161, p2 = 7,   frames = 200 },
    { p1 = 88,  p2 = 100, frames = 200 },
    { p1 = 5,   p2 = 161, frames = 200 },
}
local phase_idx, phase_start, results = 1, 0, {}

local function finish()
    if done then return end
    done = true
    local ran, drew = r16(A.hud_ran), r16(A.hud_drew)
    log("sentinels: hud_ran=%d hud_drew=%d (geo_ran=%d geo_drew=%d)",
        ran, drew, r16(A.geo_ran), r16(A.geo_drew))

    local fails = {}
    if ran == 0 then fails[#fails+1] = "hud_pass never ran - dsa9 hook not firing" end
    if drew == 0 then fails[#fails+1] = "hud_pass ran but never completed a draw loop" end

    local texts = {}
    for _, r in ipairs(results) do
        log("%-2s %-4s at (%3d,%3d): %d/%d set pixels are ink %02x  %s",
            r.name, r.text, r.x, r.y, r.hit, r.tot, r.ink,
            (#r.misses > 0) and ("first misses: " .. table.concat(r.misses, " ")) or "")
        if r.tot == 0 then
            fails[#fails+1] = string.format("%s %q: nothing expected", r.name, r.text)
        elseif r.hit < r.tot then
            fails[#fails+1] = string.format("%s %q: %d of %d glyph pixels missing",
                                            r.name, r.text, r.tot - r.hit, r.tot)
        end
        texts[#texts+1] = r.name .. r.text
    end
    local seen, n = {}, 0
    for _, t in ipairs(texts) do seen[t] = true end
    for _ in pairs(seen) do n = n + 1 end
    if #texts > 0 and n < #texts then
        fails[#fails+1] = "the same string every phase - the value is not live"
    end

    if #fails == 0 and #results > 0 then
        log("PASS: PIXBLT B,XY renders sysfont glyphs exactly, in two colours, tracking live values")
    else
        log("FAIL: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        log("---- PIXBLT B,XY HUD text test (test_mode ROM) ----")
    end
    if not space then return end

    if r16(A.gstate) == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase_start = frame
        local pa = r32(A.pageaddr)
        local x, y = pa & 0xffff, (pa >> 16) & 0xffff
        PAGE0 = (y * 512 + x) * 8
        PAGE1 = (((y + 256) % 512) * 512 + x) * 8
        log("fight at frame %d pageaddr=%08x f_doscore=%d", frame, pa, r16(A.f_doscore))
    end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); finish() end
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
        local s = manager.machine.screens[":screen"]
        if s then pcall(function() s:snapshot() end) end
    end
    if rel >= ph.frames then
        local vals = { ph.p1, ph.p2 }
        for i, rec in ipairs(RECS) do
            local text = tostring(vals[i])
            local h0, t0, m0 = check(PAGE0, rec.x, rec.y, text, rec.ink)
            local h1, t1, m1 = check(PAGE1, rec.x, rec.y, text, rec.ink)
            local hit, tot, misses = h0, t0, m0
            if h1 > h0 then hit, tot, misses = h1, t1, m1 end
            results[#results+1] = { name = rec.name, text = text, x = rec.x, y = rec.y,
                                    ink = rec.ink, hit = hit, tot = tot, misses = misses }
        end
        log("phase %d done: p1=%d p2=%d hud_ran=%d hud_drew=%d",
            phase_idx, ph.p1, ph.p2, r16(A.hud_ran), r16(A.hud_drew))
        phase_idx = phase_idx + 1
        phase_start = frame
        if phase_idx > #phases then finish() end
    end
    if frame > 30000 then log("ERROR timeout"); finish() end
end)
