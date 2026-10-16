-- vsplit_test.lua
--
-- Verifies doc/UNUSED_GRAPHICS_PRIMITIVES.md §4: a mid-frame palette split
-- driven by polling vcount, with no raster interrupt.
--
-- The claim is specifically that ONE colour RAM entry shows TWO colours in a
-- single frame, split at a chosen scanline.  That cannot be checked from the
-- frame buffer - the frame buffer holds palette INDICES, and the index is the
-- same above and below the line.  The split only exists at display time.  So
-- the check has to come from the rendered screenshot, and it has to be
-- anchored to pixels whose index is known.
--
-- Which is why this leans on §2: arm the block fill to paint the whole play
-- area with one index, then split that index.  Every pixel in the band is
-- provably the same entry, so if the top of the band renders one colour and
-- the bottom another, the split is real and nothing else can explain it.
--
--   PASS  = band is uniform above the line, uniform below it, and the two
--           differ, while the frame buffer holds the SAME index throughout
--   FAIL  = one colour everywhere (no split), or the index is not uniform
--           (the band was not actually painted by the fill)

local LOGP = os.getenv("VSPLIT_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/vsplit_test.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[vsplit] " .. string.format(fmt, ...)
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
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), f_freeze_timer = sym("f_freeze_timer"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    pageaddr = sym("pageaddr"),
    flash_ticks = sym("flash_ticks"), flash_col = sym("flash_col"),
    vsplit_line = sym("vsplit_line"), vsplit_cram = sym("vsplit_cram"),
    vsplit_top = sym("vsplit_top"), vsplit_bot = sym("vsplit_bot"),
    vsplit_ran = sym("vsplit_ran"), vsplit_hit = sym("vsplit_hit"),
    vsplit_vmin = sym("vsplit_vmin"), vsplit_vmax = sym("vsplit_vmax"),
}

local CRAM       = 0x01800000
local INK        = 0x0e             -- bpal_white, colour map 0 (pinned)
local CRAM_ENTRY = CRAM + INK * 16
local SPLIT_LINE = 150
local TOP_COL    = 0x739c           -- boonpal's own white
local BOT_COL    = 0x7c00           -- pure red - no green or blue at all,
                                    --   so "did it change" cannot be subtle
local BAND_TOP, BAND_BOT = 46, 253

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields, done = {}, false

local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end

local PAGE0, PAGE1
local function idx_uniform(y0, y1)
    -- fraction of the band that holds INK, best of the two pages
    local best = -1
    for _, page in ipairs({ PAGE0, PAGE1 }) do
        local hit, tot = 0, 0
        for y = y0, y1, 4 do
            for x = 16, 384, 16 do
                tot = tot + 1
                if rd8(page + ((y * 512 + x) * 8)) == INK then hit = hit + 1 end
            end
        end
        if hit / tot > best then best = hit / tot end
    end
    return best
end

local SWEEP = { 80, 150, 220 }
local observed = {}

-- Rendered pixels, not the frame buffer.  The split exists only at display
-- time, so this has to look at what MAME actually drew.
local function screen_rgb(pix, w, x, y)
    local off = ((y * w) + x) * 4 + 1
    local v = string.unpack("<I4", pix, off)
    return string.format("%02x%02x%02x", (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
end

-- Returns the colour well above the line, well below it, and the row where it
-- actually changes (nil if it never does).
local function sample_screen(L)
    local scr = manager.machine.screens[":screen"]
    if not scr then return "noscreen", "noscreen", nil end
    local ok, pix, w, h = pcall(function() return scr:pixels() end)
    if not ok or type(pix) ~= "string" then
        -- older API returns a table/other; report rather than guess
        return "nopixels", "nopixels", nil
    end
    w = w or scr.width; h = h or scr.height
    local x = math.floor(w / 2)
    local above = screen_rgb(pix, w, x, math.max(BAND_TOP + 4, L - 30))
    local below = screen_rgb(pix, w, x, math.min(BAND_BOT - 4, L + 30))
    local boundary = nil
    local prev = screen_rgb(pix, w, x, BAND_TOP + 4)
    for y = BAND_TOP + 5, BAND_BOT - 4 do
        local c = screen_rgb(pix, w, x, y)
        if c ~= prev then boundary = y; break end
    end
    return above, below, boundary
end

local results = {}
local function finish()
    if done then return end
    done = true
    log("sentinels: vsplit_ran=%d vsplit_hit=%d  vcount seen during the idle wait: %d..%d",
        r16(A.vsplit_ran), r16(A.vsplit_hit), r16(A.vsplit_vmin), r16(A.vsplit_vmax))
    local fails = {}
    if r16(A.vsplit_ran) == 0 then
        fails[#fails+1] = "vsplit_poll never ran - the prcdsp hook is not firing"
    elseif r16(A.vsplit_hit) == 0 then
        fails[#fails+1] = "vsplit_poll ran but never crossed the line - " ..
                          "the idle wait never spins below it"
    end
    for _, r in ipairs(results) do
        log("%s", r.text)
        if r.fail then fails[#fails+1] = r.fail end
    end
    -- Did the boundary track the requested line?
    local tracked, uniform = 0, 0
    for _, o in ipairs(observed) do
        if o.above == o.below then
            uniform = uniform + 1
        elseif o.boundary and math.abs(o.boundary - o.line) <= 6 then
            tracked = tracked + 1
        end
    end
    if uniform == #observed and #observed > 0 then
        fails[#fails+1] = string.format(
            "the screen is ONE colour at every split line (%d/%d) - the palette is " ..
            "being resolved once per frame, so the last write wins everywhere and " ..
            "the split is not observable here", uniform, #observed)
    elseif tracked < #observed then
        fails[#fails+1] = string.format(
            "the boundary tracked the requested line in only %d of %d cases",
            tracked, #observed)
    end

    if #fails == 0 then
        log("PASS: one palette entry, two colours, boundary follows the requested line")
    else
        log("FAIL: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
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
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
        log("---- vcount raster split test ----")
        if A.vsplit_line == 0 then
            log("ERROR vsplit_* missing from MK2.MAP - stale map or vsplit off")
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 1);  w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then
        fighting_frame = frame
        local pa = r32(A.pageaddr)
        local x, y = pa & 0xffff, (pa >> 16) & 0xffff
        PAGE0 = (y * 512 + x) * 8
        PAGE1 = (((y + 256) % 512) * 512 + x) * 8
        log("fight at frame %d", frame)
    end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, 161); w16(A.p1_bar_view, 161)
    w16(A.p2_bar, 161); w16(A.p2_bar_view, 161)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local rel = frame - fighting_frame

    -- arm the split, then hold the whole play area at one index with the §2
    -- fill so every sampled pixel is provably that entry
    if rel == 120 then
        w32(A.vsplit_cram, CRAM_ENTRY)
        w16(A.vsplit_top, TOP_COL)
        w16(A.vsplit_bot, BOT_COL)
        w16(A.vsplit_vmin, 0xffff)          -- seed so the min can come down
        w16(A.vsplit_vmax, 0)
        w16(A.vsplit_line, SPLIT_LINE)      -- last: this is the arm
        log("armed: cram=%08x line=%d top=%04x bot=%04x",
            CRAM_ENTRY, SPLIT_LINE, TOP_COL, BOT_COL)
    end
    if rel >= 125 and rel <= 230 then
        w16(A.flash_col, INK)
        w16(A.flash_ticks, 2)               -- keep the band painted
    end

    if rel == 140 then
        local f = idx_uniform(BAND_TOP, BAND_BOT)
        results[#results+1] = { text = string.format(
            "frame buffer: %.1f%% of the band holds index %02x", f * 100, INK) }
        if f < 0.95 then
            results[#results].fail = string.format(
                "band is only %.1f%% index %02x - the fill did not cover it, so a " ..
                "colour difference would prove nothing", f * 100, INK)
        end
    end

    -- Sweep the split line.  One line proves nothing on its own: if the whole
    -- screen comes out the bottom colour, that is equally consistent with
    -- "the split works and fired at line 0" and with "the palette is resolved
    -- once per frame, so the last write wins everywhere".  Moving the line and
    -- watching where the boundary goes separates them.
    for i, L in ipairs(SWEEP) do
        local at = 150 + (i - 1) * 20
        if rel == at then
            w16(A.vsplit_line, L)
            log("sweep: split line -> %d", L)
        end
        if rel == at + 8 then
            local above, below, boundary = sample_screen(L)
            results[#results+1] = { text = string.format(
                "line %3d: above=%s below=%s boundary=%s",
                L, above, below, boundary or "none") }
            observed[#observed+1] = { line = L, above = above, below = below,
                                      boundary = boundary }
            local s = manager.machine.screens[":screen"]
            if s then pcall(function() s:snapshot() end) end
        end
    end

    if rel == 150 + #SWEEP * 20 + 12 then
        w16(A.vsplit_line, 0)               -- disarm first
        log("disarmed")
        finish()
    end
    if frame > 30000 then log("ERROR timeout"); finish() end
end)
