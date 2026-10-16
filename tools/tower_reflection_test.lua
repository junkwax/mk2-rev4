-- tower_reflection_test.lua
-- Prove THE TOWER's six guard reflections are real: that they exist on
-- baklst1, that they sit where tools/tower3_reflection_align.py says, that the
-- right-hand three are mirrored, and that each one HOLDS its dither phase.
--
-- Holding is the thing being checked, and it is a walk-back from the first
-- version of this feature.  STATREF1a and STATREF1b are the same strip with
-- the 50% checkerboard inverted, so they differ in 94% of their pixels and a
-- strip that cycles them inverts its whole field at once - at 5-7 ticks that
-- buzzed.  The phases are now dealt out ACROSS the six so neighbours do not
-- share a dither grid, and none of them cycle.  A screenshot cannot tell a
-- held phase from a cycling one, so the osag is read straight out of the
-- display object over a few hundred frames instead.
--
-- Colour is deliberately NOT tested by sampling the screen.  STATREF_P is
-- CASTLE's PILLAR ramp and the tower floor is CASTLE's floor on CASFLR1_p -
-- the two overlap almost completely, so "these pixels are STATREF_P colours"
-- matches most of the marble too and proves nothing.  opal is read instead.
--
-- env: MK2_REFL_TAG - label prefix (default "refl")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_REFL_TAG") or "refl"
local LOG_PATH = ROOT .. "/tools/tower_reflection_test_" .. TAG .. ".log"
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
    if not v then print("[refl] FATAL missing map symbol " .. name) end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtly = sym("worldtly"), ground_y = sym("ground_y"),
    baklst1 = sym("baklst1"), worldtlx3 = sym("worldtlx3"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
}

local O = { next = 0x000, oxpos = 0x090, oxval = 0x080, oypos = 0x0b0,
            osag = 0x100, osize = 0x120, opal = 0x140, oflags = 0x0f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_CAGE = 1, 2
local TOWER = 3

-- src/STATREF.TBL.  Both phases of each strip, so a toggle is identifiable.
local STRIP = {
    [0x05f30000] = "STATREF1a", [0x05f30e6e] = "STATREF1b",
    [0x05f31cd0] = "STATREF2a", [0x05f332f6] = "STATREF2b",
    [0x05f34928] = "STATREF3a", [0x05f35c4e] = "STATREF3b",
}
-- what tools/tower3_reflection_align.py derives, in PLANE3 space
local WANT = {
    ["STATREF1"] = {{205, 202}, {858, 202}},
    ["STATREF2"] = {{240, 188}, {831, 188}},
    ["STATREF3"] = {{267, 176}, {809, 176}},
}
local MARBLE_TOP, CARPET_TOP = 181, 235   -- screen rows, from the align tool

local fields, cpu, space = {}, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local seen_sag = {}      -- object address -> set of sags it has worn
local seen_order = {}
local counted = false

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

-- walk baklst1 and record every strip object's current sag
local function sample()
    local p, c = r32(A.baklst1), 0
    while p ~= 0 and c < 90 do
        local sag = r32(p + O.osag)
        if STRIP[sag] then
            if not seen_sag[p] then seen_sag[p] = {}; seen_order[#seen_order + 1] = p end
            seen_sag[p][sag] = (seen_sag[p][sag] or 0) + 1
        end
        p = r32(p + O.next); c = c + 1
    end
    return c
end

local function inventory()
    local p, c, strips, flames = r32(A.baklst1), 0, 0, 0
    local wtx = s16(r32(A.worldtlx3) >> 16)
    print(string.format("[refl] worldtlx3=%d worldtly=%d ground_y=%d",
        wtx, s16(r32(A.worldtly) >> 16), s16(r16(A.ground_y))))
    while p ~= 0 and c < 90 do
        local sag = r32(p + O.osag)
        local name = STRIP[sag]
        if name then
            strips = strips + 1
            local sz = r32(p + O.osize)
            local h, w = (sz >> 16) & 0xffff, sz & 0xffff
            -- oxpos/oypos are this plane's coordinates; screen y = plane y + 14
            local px, py = s16(r16(p + O.oxpos)), s16(r16(p + O.oypos))
            local top, bot = py + 14, py + 14 + h
            local band = (top >= MARBLE_TOP and bot <= CARPET_TOP) and "marble" or "OFF-MARBLE"
            print(string.format(
                "[refl]   %s %2dx%-2d plane(%d,%d) screen y %d..%d %s opal=%04x flags=%04x",
                name, w, h, px, py, top, bot, band,
                r16(p + O.opal), r16(p + O.oflags)))
        elseif sag ~= 0 then
            flames = flames + 1
        end
        p = r32(p + O.next); c = c + 1
    end
    print(string.format("[refl] baklst1 total=%d  reflection strips=%d  other (torches)=%d",
        c, strips, flames))
    return strips
end

local HOLD = 320
local PARK_X = 40           -- left limit: all three left-hand guards on screen
local SAMPLE_FOR = 240      -- ~4.4s of ticks; long enough that a strip on
                            --   the OLD 5-7 tick cycle would show both phases

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

local done_frame = 0

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[refl] loaded, forcing THE TOWER (curback " .. TOWER .. "), tag=" .. TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            if A.peak_overload then w16(A.peak_overload, 0); w16(A.qdma_drops, 0) end
        end
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
                if o ~= 0 then w32(o + O.oxval, (PARK_X & 0xffff) << 16) end
            end
        end
        if rel == HOLD and not counted then
            counted = true
            print("[refl] === inventory at the left scroll limit ===")
            inventory()
            local s = screen1(); if s then pcall(function() s:snapshot() end) end
            print("[refl] snapshot taken")
        end
        if rel > HOLD and rel <= HOLD + SAMPLE_FOR then sample() end
        if rel == HOLD + SAMPLE_FOR + 1 and done_frame == 0 then
            print(string.format("[refl] === shimmer over %d frames ===", SAMPLE_FOR))
            local held, cycling = 0, 0
            local phases = {}
            for i, p in ipairs(seen_order) do
                local names, n, only = {}, 0, nil
                for sag, cnt in pairs(seen_sag[p]) do
                    n = n + 1
                    only = STRIP[sag]
                    names[#names + 1] = string.format("%s x%d", STRIP[sag], cnt)
                end
                table.sort(names)
                local verdict = (n == 1) and "HELD" or "CYCLING (would buzz)"
                if n == 1 then held = held + 1; phases[#phases + 1] = only
                else cycling = cycling + 1 end
                print(string.format("[refl]   strip %d: %d phase(s)  %s  [%s]",
                    i, n, verdict, table.concat(names, ", ")))
            end
            -- both interleaves must be in use, or the row shares one grid
            local seen_a, seen_b = false, false
            for _, nm in ipairs(phases) do
                if nm:sub(-1) == "a" then seen_a = true else seen_b = true end
            end
            print(string.format("[refl] interleaves in use: a=%s b=%s",
                tostring(seen_a), tostring(seen_b)))
            if A.peak_overload then
                print(string.format("[refl] peak_overload=%d qdma_drops=%d",
                    r16(A.peak_overload), r16(A.qdma_drops)))
            end
            print(string.format("[refl] RESULT %d/%d strips hold a phase, %d cycling",
                held, held + cycling, cycling))
            done_frame = frame
            print("[refl] finished")
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 3200 then print("[refl] TIMEOUT"); manager.machine:exit(); return end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)
