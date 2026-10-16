-- tower_scale_probe.lua
-- One question, answered on the real machine before any of it is built:
--
--   can a BACKGROUND block be drawn flipped and vertically squashed using
--   nothing but m_flipv and a non-square oscale, on THIS art?
--
-- If yes, a pillar reflection costs zero video ROM - it is the pillar's own
-- SAG drawn upside down and foreshortened. If no, it needs authored art like
-- the statues did.
--
-- Two things could break it and neither is obvious from the source:
--   * the pillar tile is zero-compressed, and doc/DEADPOOL_ACID_REFLECTIONS.md
--     warns that compressed art has no fixed line stride (that was about a CPU
--     walk, not the DMA, but it is the reason to check rather than assume);
--   * oscale is loaded per object by the display loop's mmfm, so it SHOULD
--     apply to bak-list objects exactly as it does to fighters - "should".
--
-- The probe takes a live pillar object off baklst4 and rewrites its oflags and
-- oscale in place, every frame, then snapshots. It corrupts the picture on
-- purpose; it is an experiment, not a feature.
--
-- env: MK2_SCALE_TAG - label prefix (default "scale")
--      MK2_SCALE_Y   - ystep in hex, default 300 (draws 1/3 height)

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_SCALE_TAG") or "scale"
local YSTEP = tonumber(os.getenv("MK2_SCALE_Y") or "300", 16)
local LOG_PATH = ROOT .. "/tools/tower_scale_probe_" .. TAG .. ".log"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
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
local function sym(n) local v = symbols[n]; if not v then print("[scale] FATAL missing " .. n) end; return v end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtly = sym("worldtly"), baklst4 = sym("baklst4"), worldtlx4 = sym("worldtlx4"),
}
local O = { next = 0x000, oxpos = 0x090, oxval = 0x080, oypos = 0x0b0,
            oflags = 0x0f0, osag = 0x100, osize = 0x120, opal = 0x140,
            oflags2 = 0x160, oscale = 0x180 }
local M_FLIPV = 0x20
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_CAGE = 1, 2
local TOWER = 3

local fields, cpu, space = {}, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local done_frame, reported = 0, false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 High Punch"]=true, ["P2 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end
local function screen1()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap() local s = screen1(); if s then pcall(function() s:snapshot() end) end end

local function pillars()
    local out, p, c = {}, r32(A.baklst4), 0
    while p ~= 0 and c < 60 do out[#out + 1] = p; p = r32(p + O.next); c = c + 1 end
    return out
end

local function dump(tag)
    local wx = s16(r32(A.worldtlx4) >> 16)
    print(string.format("[scale] %s worldtlx4=%d", tag, wx))
    for i, p in ipairs(pillars()) do
        local sz = r32(p + O.osize)
        print(string.format("[scale]   pillar[%d] plane(%d,%d) screen y %d  %dx%d sag=0x%08x flags=%04x scale=%08x",
            i, s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
            s16(r16(p + O.oypos)) + 14, sz & 0xffff, (sz >> 16) & 0xffff,
            r32(p + O.osag), r16(p + O.oflags), r32(p + O.oscale)))
    end
end

local HOLD = 320

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[scale] loaded, THE TOWER, ystep=0x%x", YSTEP))
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE); w16(A.curback, TOWER)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, TOWER) end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if rel < HOLD then
            for _, h in ipairs({A.p1_obj, A.p2_obj}) do
                local o = r32(h)
                if o ~= 0 then w32(o + O.oxval, (40 & 0xffff) << 16) end
            end
        end
        if rel == HOLD then
            print("[scale] === BEFORE: pillars as the stage draws them ===")
            dump("before"); snap()
        end
        -- re-apply every frame: bgnd_ud1 rebuilds this plane's list as blocks
        -- scroll, and ani0 would OR the control word back over oflags anyway
        if rel > HOLD and rel <= HOLD + 30 then
            for _, p in ipairs(pillars()) do
                w16(p + O.oflags, r16(p + O.oflags) | M_FLIPV)
                w32(p + O.oscale, (YSTEP << 16) | 0x0100)
            end
        end
        if rel == HOLD + 30 and not reported then
            reported = true
            print(string.format(
                "[scale] === AFTER: m_flipv + oscale [y=0x%x : x=0x100] ===", YSTEP))
            dump("after"); snap()
            print("[scale] compare the two snapshots: pillar should be upside")
            print("[scale] down and 1/" .. string.format("%.1f", YSTEP / 256)
                  .. " of its height, same width")
            done_frame = frame
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 3200 then print("[scale] TIMEOUT"); manager.machine:exit(); return end
    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)
