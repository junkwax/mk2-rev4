-- sweep_addon_monk.lua - do the Portal's shadow priests drift DOWNWARD?
--
-- Beta report: "the shadow priests just keep moving down on the original
-- portal stage".  monk_proc (BGND.ASM) floats them by ramping oyvel between
-- -8000h and +8000h in 400h steps, which integrates to zero over a full
-- cycle - so in theory they bob and stay put.  This measures whether they
-- actually do.
--
-- Walks baklst4 (the list port_calla puts both monks and both little monks
-- on) and records every object's y over the whole fight.  What matters is not
-- the wobble, it is the TREND: first-seen y against last-seen y, and the
-- running min/max.  A bob shows as a band that stays put; a drift shows as a
-- band that walks.
--
-- Passive: reads only.
--
-- Output: tools/monk_<tag>.txt   (MONK_TAG, default "run")

local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG  = os.getenv("MONK_TAG") or "run"
local OUT  = ROOT .. "/tools/monk_" .. TAG .. ".txt"

local O = { oyvel = 0x060, oxpos = 0x090, oyval = 0x0a0, oypos = 0x0b0,
            osizex = 0x120, osizey = 0x130, osag = 0x100 }

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if not fh then print("[monk] no mk2.map"); return end
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            sym[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local gstate, baklst4 = sym.gstate, sym.baklst4
local worldtly = sym.worldtly
if not (gstate and baklst4) then print("[monk] symbols missing"); return end

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[monk] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end; return v end
local function s32(v) v = v & 0xffffffff
    if v >= 0x80000000 then return v - 0x100000000 end; return v end

local space, frame = nil, 0
local wtrack = {}
-- keyed by object address: objects are stable for the life of the round, and
-- if one is recycled the size/sag change shows up in the dump.
local track = {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if space:read_u16(gstate) ~= 2 then return end
    if frame % 4 ~= 0 then return end

    -- The monks' WORLD y can be perfectly still while they still walk down the
    -- screen, because every plane's y comes off the one global worldtly.  Log
    -- it alongside, or a stable object table proves nothing about what the
    -- player saw.
    if worldtly then
        local wy = s32(space:read_u32(worldtly)) >> 16
        local wi = frame // 512
        local wb = wtrack[wi]
        if not wb then wb = { lo = wy, hi = wy }; wtrack[wi] = wb end
        if wy < wb.lo then wb.lo = wy end
        if wy > wb.hi then wb.hi = wy end
    end

    local o = space:read_u32(baklst4)
    local guard = 0
    while o ~= 0 and guard < 64 do
        guard = guard + 1
        local y   = s16(space:read_u16(o + O.oypos))
        local yv  = s32(space:read_u32(o + O.oyvel))
        local t = track[o]
        if not t then
            t = { first = y, min = y, max = y, n = 0, sx = s16(space:read_u16(o + O.osizex)),
                  sy = s16(space:read_u16(o + O.osizey)), moving = 0, win = {} }
            track[o] = t
        end
        t.last = y; t.n = t.n + 1
        if y < t.min then t.min = y end
        if y > t.max then t.max = y end
        if yv ~= 0 then t.moving = t.moving + 1 end
        -- Per-window band.  A bob is a band that stays put; a drift is a band
        -- that walks.  One monk_proc cycle is 128 ticks, so a 512-frame window
        -- is four full cycles - big enough that the phase you sampled cannot
        -- fake a trend, small enough to see one.
        local wi = frame // 512
        local wb = t.win[wi]
        if not wb then wb = { lo = y, hi = y }; t.win[wi] = wb end
        if y < wb.lo then wb.lo = y end
        if y > wb.hi then wb.hi = y end
        o = space:read_u32(o)
    end
end)

emu.register_stop(function()
    local rows = {}
    for addr, t in pairs(track) do
        if t.n > 30 then rows[#rows+1] = { addr = addr, t = t } end
    end
    table.sort(rows, function(a, b) return a.addr < b.addr end)
    log("=== monk === baklst4 objects seen for >30 samples")
    log("%-10s %5s %5s %6s %6s %6s %7s %6s %s", "obj", "sizex", "sizey",
        "first", "last", "drift", "min..max", "n", "ticks_with_yvel")
    for _, r in ipairs(rows) do
        local t = r.t
        log("%08x %5d %5d %6d %6d %6d %3d..%-3d %6d %d",
            r.addr, t.sx, t.sy, t.first, t.last, t.last - t.first,
            t.min, t.max, t.n, t.moving)
        local ks = {}
        for k in pairs(t.win) do ks[#ks+1] = k end
        table.sort(ks)
        local parts = {}
        for _, k in ipairs(ks) do
            parts[#parts+1] = string.format("%d..%d", t.win[k].lo, t.win[k].hi)
        end
        if #parts > 1 then log("           bands: %s", table.concat(parts, "  ")) end
    end
    if worldtly then
        local ks = {}
        for k in pairs(wtrack) do ks[#ks+1] = k end
        table.sort(ks)
        local parts = {}
        for _, k in ipairs(ks) do
            parts[#parts+1] = string.format("%d..%d", wtrack[k].lo, wtrack[k].hi)
        end
        log("worldtly bands: %s", table.concat(parts, "  "))
    end
    log("run_end")
end)
