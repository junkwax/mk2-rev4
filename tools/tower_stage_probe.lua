-- tower_stage_probe.lua
-- Force a match onto THE TOWER (curback = 3, table_o_mods index 3 = tower_mod),
-- park the camera at the left limit / centre / right limit, and snapshot each.
-- Logs worldtly + every plane's worldtlx so the preview tool can be checked
-- against the real machine.
--
-- env: MK2_TOWER_TAG  - label prefix for snapshot log lines (default "base")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_TOWER_TAG") or "base"
local LOG_PATH = ROOT .. "/tools/tower_stage_probe_" .. TAG .. ".log"
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
local function sym(name)
    local v = symbols[name]
    if not v then print("[tower] FATAL missing map symbol " .. name) end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtly = sym("worldtly"), ground_y = sym("ground_y"),
    left_edge = sym("left_edge"), right_edge = sym("right_edge"),
    baklst3 = sym("baklst3"), baklst4 = sym("baklst4"), baklst6 = sym("baklst6"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
}
for i, n in ipairs({"worldtlx", "worldtlx0", "worldtlx2", "worldtlx3", "worldtlx4",
                    "worldtlx5", "worldtlx6", "worldtlx7", "worldtlx8"}) do
    A[n] = sym(n)
end

local O = { next = 0x000, oxpos = 0x090, oxval = 0x080, oypos = 0x0b0,
            osag = 0x100, osize = 0x120, opal = 0x140, oimg = 0x1a0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_CAGE = 1, 2
local TOWER = 3

local fields, cpu, space = {}, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local did_select = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
-- worldtlx* are 16.16; the integer part is the HIGH word and is signed.
local function wx(a) return s16(r32(a) >> 16) end

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

local function snap(label)
    local s = screen1(); if not s then return end
    pcall(function() s:snapshot() end)
    print(string.format("[tower] SNAP %s frame=%d %s", TAG, frame, label))
end

local function report(label)
    -- peak_overload is prcdsp's frame-overrun meter latched at its worst; 2 =
    -- every process pass finished inside its tick (doc/PERFORMANCE.md). The
    -- guards add four 76x218-class blits to the frame, so this is the number
    -- that says whether that cost anything. qdma_drops counts discarded
    -- sprites and is 0 on stock.
    if A.peak_overload then
        print(string.format("[tower] %s peak_overload=%d qdma_drops=%d",
            label, r16(A.peak_overload), r16(A.qdma_drops)))
    end
    print(string.format(
        "[tower] %s worldtly=%d ground_y=%d edges=%d..%d  x=%d x0=%d x2=%d x3=%d x4=%d x5=%d x6=%d x7=%d x8=%d",
        label, s16(r32(A.worldtly) >> 16), s16(r16(A.ground_y)),
        s16(r16(A.left_edge)), s16(r16(A.right_edge)),
        wx(A.worldtlx), wx(A.worldtlx0), wx(A.worldtlx2), wx(A.worldtlx3),
        wx(A.worldtlx4), wx(A.worldtlx5), wx(A.worldtlx6), wx(A.worldtlx7), wx(A.worldtlx8)))
    for _, n in ipairs({"baklst3", "baklst4", "baklst6"}) do
        local p, c = r32(A[n]), 0
        while p ~= 0 and c < 90 do
            if c < 12 then
                print(string.format("[tower]   %s[%d] xy=(%d,%d) sag=0x%08x size=0x%08x pal=%04x",
                    n, c, s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
                    r32(p + O.osag), r32(p + O.osize), r16(p + O.opal)))
            end
            p = r32(p + O.next); c = c + 1
        end
        print(string.format("[tower]   %s total=%d", n, c))
    end
end

-- park both fighters at a world x so the scroller drags the camera there
local function park(x)
    for _, h in ipairs({A.p1_obj, A.p2_obj}) do
        local o = r32(h)
        if o ~= 0 then w32(o + O.oxval, (x & 0xffff) << 16) end
    end
end

-- The scroller only closes a few px per tick, so a stop needs a long hold to
-- actually reach a scroll limit: 60 frames of parking moved the camera ~120px
-- and left THE TOWER's right-hand statue group off screen entirely, which
-- looked like the group was missing rather than out of shot.  Each stop parks
-- both fighters for `hold` frames and the report prints worldtlx, so a stop
-- that did NOT reach its edge is visible in the log.
local HOLD = 320
local STOPS = {
    {name = "left",  x = 40,   at = HOLD},
    {name = "mid",   x = 560,  at = HOLD * 2},
    {name = "right", x = 1090, at = HOLD * 3},
}
local done_frame = 0

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
        print("[tower] loaded, forcing THE TOWER (curback " .. TOWER .. "), tag=" .. TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[tower] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            -- peak_overload latches the worst frame since power-on, and boot,
            -- character select and the stage load are all heavy transitions
            -- (doc/PERFORMANCE.md) - reading it raw reports those, not the
            -- fight. Nothing in the ROM branches on either counter, so zeroing
            -- them here is free and makes the numbers below fight-only.
            if A.peak_overload then w16(A.peak_overload, 0); w16(A.qdma_drops, 0) end
        end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE); w16(A.curback, TOWER)
        if not did_select then did_select = true; print("[tower] forced chars+stage") end
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    -- curback is re-read at stage load; keep pinning it until the fight starts
    if fighting_frame == 0 then w16(A.curback, TOWER) end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        for i, st in ipairs(STOPS) do
            if rel >= st.at - HOLD and rel < st.at then park(st.x) end
            if rel == st.at then
                report(st.name); snap(st.name)
            end
        end
        if rel > STOPS[#STOPS].at + 20 and done_frame == 0 then
            done_frame = frame; print("[tower] finished")
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 3200 then print("[tower] TIMEOUT"); manager.machine:exit(); return end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close(); logfh = nil end end)
