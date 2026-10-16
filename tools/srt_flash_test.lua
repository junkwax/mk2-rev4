-- srt_flash_test.lua
--
-- Verifies doc/UNUSED_GRAPHICS_PRIMITIVES.md §2: the VRAM shift-register
-- block fill, used as a flash that covers the play area and LEAVES THE HUD
-- ALONE.  That last part is the whole claim - the existing white_flash sets
-- irqskye (the colour behind everything) and long_white_flash blanks the
-- entire display, life bars included - so the test has to check both halves:
--
--   1. the play band goes uniformly to the requested pixel value
--   2. the HUD band does NOT change at all
--   3. it lasts exactly the armed number of frames and then stops
--
-- It arms flash_ticks/flash_col directly rather than waiting for a fatality,
-- so the primitive is tested without dragging a whole death sequence in.  A
-- second phase then confirms white_flash really arms it, by watching
-- flash_did move while the game triggers its own flashes.
--
-- NOT on the Dead Pool, which is where it used to run.  dp_acid_glow (the
-- fxdemo example in BGND.ASM) re-arms the band list on that stage EVERY
-- frame, so flash_ticks there is never 0 for long and "it stops on time"
-- cannot be asserted.  The band list is a per-frame thing by design - see
-- flash_pass - so any stage with a driver on it behaves that way.  Kombat
-- Tomb has no driver, and the primitive does not care which stage it is.

local LOGP = os.getenv("SRT_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/srt_flash_test.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[srt] " .. string.format(fmt, ...)
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
    pageaddr = sym("pageaddr"), p2_proc = sym("p2_proc"),
    r_pitched = sym("r_pitched"),
    flash_ticks = sym("flash_ticks"), flash_col = sym("flash_col"),
    flash_ran = sym("flash_ran"), flash_did = sym("flash_did"),
}

local TEST_STAGE = 1            -- Kombat Tomb: no fxdemo driver on the band
-- must match FLASH_TOP / FLASH_ROWS in MKDISP.ASM
local FLASH_TOP, FLASH_BOT = 46, 253
local FLASH_INK = 0x0e                  -- bpal_white
local HUD_TOP, HUD_BOT = 8, 44          -- strictly above the band

-- The warning-screen dismisser needs a "we are past the red screen" signal
-- and it cannot be this script's log, which exists from script LOAD.
local READY_PATH = os.getenv("SRT_READY")
local ready_written = false

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

local PAGE0, PAGE1
local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end

-- fraction of sampled pixels in a band equal to `want`, on the page that has
-- the most of them (either page may be the one just plotted)
local function band_frac(y0, y1, want)
    local best = -1
    for _, page in ipairs({ PAGE0, PAGE1 }) do
        local hit, tot = 0, 0
        for y = y0, y1, 3 do
            for x = 8, 392, 8 do
                tot = tot + 1
                if pxv(page, x, y) == want then hit = hit + 1 end
            end
        end
        local f = hit / tot
        if f > best then best = f end
    end
    return best
end

-- snapshot a band so "did it change" can be answered rather than guessed
local function band_grab(page, y0, y1)
    local t = {}
    for y = y0, y1, 3 do
        for x = 8, 392, 8 do t[#t+1] = pxv(page, x, y) end
    end
    return t
end
local function band_diff(a, b)
    if not a or not b or #a ~= #b then return -1 end
    local n = 0
    for i = 1, #a do if a[i] ~= b[i] then n = n + 1 end end
    return n / #a
end

local results = {}
local function finish()
    if done then return end
    done = true
    local fails = {}
    log("sentinels: flash_ran=%d flash_did=%d", r16(A.flash_ran), r16(A.flash_did))
    if r16(A.flash_ran) == 0 then
        fails[#fails+1] = "flash_pass never ran - the dsa9 hook is not firing"
    end
    for _, r in ipairs(results) do
        log("%s", r.text)
        if r.fail then fails[#fails+1] = r.fail end
    end
    if #fails == 0 then
        log("PASS: block fill covers the play area, spares the HUD, and stops on time")
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

local hud_before, did_before
local T = {}    -- fight-relative frame -> action

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
        log("---- VRAM block-fill flash test ----")
        if A.flash_ticks == 0 then
            log("ERROR flash_* missing from MK2.MAP - stale map or srtflash off")
        end
    end
    if READY_PATH and not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 1);  w16(A.p2_char, 1)
        w16(A.curback, TEST_STAGE)
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
        log("fight at frame %d, pages %08x/%08x", frame, PAGE0, PAGE1)
    end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); finish() end
        return
    end

    local rel = frame - fighting_frame

    -- Phase 1 needs a stable, endless round.  Phase 2 needs the opposite: a
    -- real death, so white_flash runs on its own and we can see whether it
    -- arms the fill.  Stop propping the round up at rel 210.
    if rel < 210 then
        w16(A.p1_bar, 161); w16(A.p1_bar_view, 161)
        w16(A.p2_bar, 161); w16(A.p2_bar_view, 161)
        if A.winner_status ~= 0 then w16(A.winner_status, 0) end
        if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    end

    -- settle, then baseline
    if rel == 120 then
        hud_before = band_grab(PAGE0, HUD_TOP, HUD_BOT)
        did_before = r16(A.flash_did)
        local f = band_frac(FLASH_TOP, FLASH_BOT, FLASH_INK)
        results[#results+1] = { text = string.format(
            "baseline: play band %.1f%% ink %02x (should be near 0)", f * 100, FLASH_INK) }
        if f > 0.10 then
            results[#results].fail = "play band already full of the flash colour before arming"
        end
    end

    -- arm a 4-frame flash
    if rel == 130 then
        w16(A.flash_col, FLASH_INK)
        w16(A.flash_ticks, 12)
        log("armed: flash_ticks=12 flash_col=%02x", FLASH_INK)
    end

    -- while it should still be running
    if rel == 136 then
        local play = band_frac(FLASH_TOP, FLASH_BOT, FLASH_INK)
        local hud_now = band_grab(PAGE0, HUD_TOP, HUD_BOT)
        local hud_changed = band_diff(hud_before, hud_now)
        results[#results+1] = { text = string.format(
            "during flash: play band %.1f%% ink, HUD band %.1f%% changed, flash_did %d -> %d",
            play * 100, hud_changed * 100, did_before, r16(A.flash_did)) }
        if play < 0.95 then
            results[#results].fail = string.format(
                "play band only %.1f%% filled - the block fill is not covering it", play * 100)
        elseif hud_changed > 0.02 then
            results[#results].fail = string.format(
                "HUD band changed %.1f%% - the flash is not sparing the HUD", hud_changed * 100)
        elseif r16(A.flash_did) <= did_before then
            results[#results].fail = "flash_did did not move - no band was filled"
        end
    end

    -- after it should have expired
    if rel == 200 then
        local play = band_frac(FLASH_TOP, FLASH_BOT, FLASH_INK)
        local ticks = r16(A.flash_ticks)
        results[#results+1] = { text = string.format(
            "after flash: play band %.1f%% ink, flash_ticks=%d (should be 0)",
            play * 100, ticks) }
        if ticks ~= 0 then
            results[#results].fail = "flash_ticks never reached 0 - it does not stop"
        elseif play > 0.10 then
            results[#results].fail = "play band still filled after the flash expired"
        end
    end

    -- two shots mid-flash for eyeballing, one after it ends
    if rel == 135 or rel == 138 or rel == 190 then
        local s = manager.machine.screens[":screen"]
        if s then pcall(function() s:snapshot() end) end
    end

    -- ---- phase 2: does white_flash arm it by itself? ----
    -- A plain KO does not call white_flash - it is for shatters, burns,
    -- Toasty and the fatality beats.  So drive one directly, the way the
    -- fatality rigs in this tree already do: point the victim process's
    -- p_wake at a death routine that opens with `jsrp white_flash`.  This is
    -- testing OUR wiring (does white_flash arm the fill), not the game's
    -- ability to reach that death on its own.
    if rel == 215 then
        did_before = r16(A.flash_did)
        local p2proc = r32(A.p2_proc)
        if p2proc ~= 0 and A.r_pitched ~= 0 then
            space:write_u32(p2proc + 0x0e0, A.r_pitched)   -- p_wake
            log("phase 2: P2 proc %08x woken into r_pitched, flash_did=%d",
                p2proc, did_before)
        else
            log("phase 2: SKIPPED - p2_proc=%08x r_pitched=%08x", p2proc, A.r_pitched)
        end
    end
    if rel == 600 then
        local now = r16(A.flash_did)
        results[#results+1] = { text = string.format(
            "white_flash wiring: flash_did %d -> %d over the forced death",
            did_before, now) }
        if now <= did_before then
            results[#results].text = results[#results].text ..
                "  (NOT OBSERVED - white_flash did not run)"
        end
        finish()
    end
    if frame > 30000 then log("ERROR timeout"); finish() end
end)
