-- flatband_demo.lua
--
-- The two worked EXAMPLES of the VRAM block fill (doc/UNUSED_GRAPHICS_
-- PRIMITIVES.md S2, doc/GRAPHICS_CAPABILITIES.md "a flat colour band"),
-- driven in a real fight and checked against what the band list says they
-- should be.  Which one runs comes from FXDEMO_STAGE:
--
--   peak       peak_flash    - Yoteigai Tor.  The big bolt whites out the
--                              play area for two ticks and leaves the HUD.
--
-- There was a `deadpool` mode here for dp_acid_glow, the other worked example
-- of the band list.  That effect was removed on 2026-08-27 and so was the
-- mode; what it taught is kept in doc/UNUSED_GRAPHICS_PRIMITIVES.md S2.
--
-- HOW IT IS CHECKED, and why not by counting pixels of a colour.  boonpal is
-- colour map 0 and the life bar, the name plates and the WINS counter all
-- draw out of it, so "N pixels are index 8" passes on coincidence - see
-- doc/GRAPHICS_CAPABILITIES.md.  What a block fill and nothing else can do is
-- make a row UNIFORM across the whole 400px width, and make consecutive rows
-- alternate between exactly two values.  Both of those are asserted here, on
-- every sampled row, together with a control row just above the band that
-- must NOT be uniform - otherwise a blank page reads as a pass.
--
-- Env: MK2_ROOT, FXDEMO_LOG, FXDEMO_READY, FXDEMO_STAGE

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("FXDEMO_LOG") or (ROOT .. "/tools/flatband_demo.log")
local STAGE = (os.getenv("FXDEMO_STAGE") or "peak"):lower()
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[fx] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view", "winner_status",
                     "battle_num", "map_position", "pageaddr", "worldtly",
                     "f_freeze_timer", "f_nosound", "baklst2", "rand",
                     "flash_ticks", "flash_col", "flash_ran", "flash_did",
                     "flash_bands", "flash_list" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_SUBZERO = 1, 8
local DEADPOOL, PEAK = 0x00, 0x18

-- boonpal, after MAINEQU's bpal_* names
local WHITE, BLUE = 0x0e, 0x0b

local PLAY_TOP = 46                       -- FLASH_TOP
local HUD_TOP, HUD_BOT = 8, 44

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local PAGE0, PAGE1
local snap_index = 0
local fails, notes = {}, {}

local READY_PATH = os.getenv("FXDEMO_READY") or (ROOT .. "/tools/flatband_demo_ready.flag")
local ready_written = false

local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end

-- one row: its value if every sampled pixel across the width agrees, else nil
local function row_uniform(page, y, step)
    local v = pxv(page, 4, y)
    for x = 4, 396, (step or 4) do
        if pxv(page, x, y) ~= v then return nil, x end
    end
    return v
end

-- rows y0..y1 on whichever page currently holds a fill: even rows all one
-- value, odd rows all another.  Returns even, odd (or nil plus a reason).
local function band_pair(page, y0, y1)
    local ev, od
    for y = y0, y1 do
        local v = row_uniform(page, y)
        if not v then return nil, string.format("row %d is not uniform", y) end
        if y % 2 == 0 then
            if ev and v ~= ev then return nil, string.format("even rows disagree at %d", y) end
            ev = v
        else
            if od and v ~= od then return nil, string.format("odd rows disagree at %d", y) end
            od = v
        end
    end
    return ev, od
end

local function both_pages(fn)
    for _, p in ipairs({ PAGE0, PAGE1 }) do
        local a, b = fn(p)
        if a then return a, b, p end
    end
    return nil
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap_now(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP %04d %s (ok=%s)", snap_index, label, tostring(ok))
    snap_index = snap_index + 1
end

-- A snapshot is of what the SCREEN is showing, and that is not what the page
-- we just read holds: the fill goes to the plot page and only reaches the
-- beam on the flip.  Snapping on the frame a band is detected catches the
-- frame BEFORE it - which for a two-tick flash means a picture of the stage
-- with no flash in it at all.  So snaps are queued a frame or two out.
local snap_queue = {}
local function snap(label, delay)
    local at = frame + (delay or 1)
    snap_queue[at] = snap_queue[at] or {}
    table.insert(snap_queue[at], label)
end
local function snap_pump()
    local due = snap_queue[frame]
    if not due then return end
    snap_queue[frame] = nil
    for _, l in ipairs(due) do snap_now(l) end
end

local function fail(f) fails[#fails + 1] = f; log("FAIL %s", f) end

local function finish()
    if finished then return end
    finished = true
    log("sentinels: flash_ran=%d flash_did=%d", r16(A.flash_ran), r16(A.flash_did))
    for _, n in ipairs(notes) do log("%s", n) end
    if r16(A.flash_ran) == 0 then fail("flash_pass never ran - the dsa9 hook is dead") end
    if #fails == 0 then log("PASS") else log("FAILED: %s", table.concat(fails, "; ")) end
    manager.machine:exit()
end

-- -------------------------------------------------------------------- peak
--
-- The storm picks its slot with randu and only slot 5 - the big bolt that
-- reaches down the sky - lights the stage.  That is one bolt in six, and one
-- bolt every 3-6 seconds, so the wait is long.  It is also DETERMINISTIC: the
-- rng reseeds identically every round, so a scripted run replays one roll of
-- the dice for ever and a run that draws no 5 in its first dozen bolts will
-- never draw one however long it is left.  So the seed gets stirred here,
-- which is the same thing a coin drop does.
local strikes, hud_base, last_did = 0, nil, 0
local bolts, bolt_up, flipped = 0, false, 0
local pal0_bolts = 0
local stir = 0x13579bdf

local function grab(page, y0, y1)
    local t = {}
    for y = y0, y1, 2 do for x = 8, 392, 8 do t[#t + 1] = pxv(page, x, y) end end
    return t
end
local function diff(a, b)
    if not a or not b or #a ~= #b then return -1 end
    local n = 0
    for i = 1, #a do if a[i] ~= b[i] then n = n + 1 end end
    return n / #a
end

-- how many objects are hanging off the lightning plane right now
local function plane_count(head)
    local n, o, guard = 0, r32(head), 0
    while o ~= 0 and guard < 64 do
        n = n + 1; o = r32(o); guard = guard + 1
    end
    return n
end

local function peak_tick(rel)
    if rel == 60 then hud_base = grab(PAGE0, HUD_TOP, HUD_BOT); last_did = r16(A.flash_did) end
    if rel < 60 then return end

    -- stir the seed so the storm does not replay one roll (see above)
    if rel % 137 == 0 and A.rand then
        stir = (stir * 1103515245 + 12345) & 0xffffffff
        space:write_u32(A.rand, stir)
    end

    -- count bolts, so "no flash" can be told apart from "no storm", and read
    -- the flip bit off each one: peak_bang gives half of them m_flipv, which
    -- is UNUSED_HARDWARE_EFFECTS #1 - a bit retail sets exactly zero times.
    local up = A.baklst2 and plane_count(A.baklst2) > 0 or false
    if up and not bolt_up then
        bolts = bolts + 1
        local o = r32(A.baklst2)
        if o ~= 0 then
            local fl = r16(o + 0x0f0)          -- oflags
            local bx, by = s16(r16(o + 0x090)), s16(r16(o + 0x0b0))
            local bw, bh = s16(r16(o + 0x120)), s16(r16(o + 0x130))
            local tag = (fl & 0x20) ~= 0 and "FLIPPED" or "authored"
            if (fl & 0x20) ~= 0 then flipped = flipped + 1 end
            local pal = r16(o + 0x140)        -- opal: 0 IS colour map 0
            if bolts <= 8 then
                log("rel=%4d bolt %d %s oflags=%04x opal=%04x at (%d,%d) %dx%d",
                    rel, bolts, tag, fl, pal, bx, by, bw, bh)
            end
            if pal == 0 then pal0_bolts = pal0_bolts + 1 end
            -- the lane is 6 ticks a frame, so photograph it well inside the
            -- first frame and again on the third
            if bolts <= 6 then
                snap("bolt " .. bolts .. " " .. tag, 4)
                snap("bolt " .. bolts .. " " .. tag .. " late", 14)
            end
        end
    end
    bolt_up = up

    local did = r16(A.flash_did)
    if did ~= last_did then
        last_did = did
        -- a band was filled on the frame that just went out
        local ev, od, page = both_pages(function(p) return band_pair(p, PLAY_TOP, PLAY_TOP + 40) end)
        if ev then
            strikes = strikes + 1
            local kind = (ev == WHITE and od == WHITE) and "blast"
                or ((ev == WHITE and od == BLUE) and "dither" or "UNEXPECTED")
            log("rel=%d strike frame %d: play band %02x/%02x (%s)", rel, strikes, ev, od, kind)
            if kind == "UNEXPECTED" then
                fail(string.format("play band came out %02x/%02x, not white/white or white/blue", ev, od))
            end
            -- the HUD must be untouched by it
            local hud_now = grab(page, HUD_TOP, HUD_BOT)
            local d = diff(hud_base, hud_now)
            if d > 0.05 then
                fail(string.format("the flash changed %.0f%% of the HUD band", d * 100))
            elseif strikes == 1 then
                notes[#notes + 1] = string.format("HUD band %.1f%% changed under the flash - spared", d * 100)
            end
            -- and the band has to reach the bottom of the screen
            local bev = band_pair(page, 240, 252)
            if bev ~= ev then
                fail("the band does not reach the bottom of the play area")
            end
            if strikes <= 4 then
                snap("peak lightning " .. kind, 1)
                snap("peak lightning " .. kind .. " +1", 2)
            end
        else
            log("rel=%d flash_did moved but no uniform play band found", rel)
        end
    end

    if rel > 60 * 90 then          -- ~90 seconds of storm
        notes[#notes + 1] = string.format("bolts: %d, of which lit the stage: %d", bolts, strikes)
        notes[#notes + 1] = string.format("bolts drawn with m_flipv: %d of %d", flipped, bolts)
        notes[#notes + 1] = string.format("bolts that got colour map 0 (no palette): %d of %d",
            pal0_bolts, bolts)
        if bolts >= 8 and (flipped == 0 or flipped == bolts) then
            fail("m_flipv is not being rolled per bolt")
        end
        if strikes == 0 then
            fail(bolts == 0 and "no storm at all - peak_thunder is not running"
                 or "bolts fell but none of them lit the stage")
        end
        finish()
    end
end

-- ------------------------------------------------------------------- drive
emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                       ["2 Players Start"] = true, ["P1 High Punch"] = true,
                       ["P2 High Punch"] = true, ["UI Select"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("---- flat colour band demo: %s ----", STAGE)
    end
    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = space and r16(A.gstate) or 0
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, STAGE == "peak" and PEAK or DEADPOOL)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space or finished then return end
    snap_pump()

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        local pa = r32(A.pageaddr)
        local x, y = pa & 0xffff, (pa >> 16) & 0xffff
        PAGE0 = (y * 512 + x) * 8
        PAGE1 = (((y + 256) % 512) * 512 + x) * 8
        log("fight at frame %d, curback=%02xh worldtly=%d pages %08x/%08x",
            frame, r16(A.curback), s16(r32(A.worldtly) >> 16), PAGE0, PAGE1)
    end
    if fighting_frame == 0 then
        if frame > 9000 then fail("never reached a fight"); finish() end
        return
    end

    -- an endless round: nobody dies, the clock never runs out
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status then w16(A.winner_status, 0) end
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end

    local rel = frame - fighting_frame
    peak_tick(rel)
end)
