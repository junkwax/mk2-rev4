-- stage_park_probe.lua - tower_stage_probe.lua for ANY stage.
-- Force a match onto curback SPP_STAGE, park the camera at each world x in
-- SPP_STOPS, snapshot each, and log every plane's worldtlx.  Driven by
-- tools/run_stage_park_probe.ps1 (private ROM + its own map, the ROM-warning
-- poker).  Written for THE DEAD POOL's big chains (dpul1, BGND.ASM).
--
-- env: SPP_TAG, SPP_LOG, SPP_MAP, SPP_STAGE (curback), SPP_STOPS ("40,560,1090")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("SPP_TAG") or "base"
local LOG_PATH = os.getenv("SPP_LOG") or (ROOT .. "/tools/stage_park_probe_" .. TAG .. ".log")
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
    local fh = io.open(os.getenv("SPP_MAP") or (ROOT .. "/src/mk2.map"), "r")
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
    if not v then print("[spp] FATAL missing map symbol " .. name) end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtly = sym("worldtly"), ground_y = sym("ground_y"),
    left_edge = sym("left_edge"), right_edge = sym("right_edge"),
    baklst2 = sym("baklst2"), baklst3 = sym("baklst3"), baklst4 = sym("baklst4"), baklst6 = sym("baklst6"),
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
local TOWER = tonumber(os.getenv("SPP_STAGE") or "3")
local DLSKIP = tonumber(os.getenv("SPP_DLSKIP") or "")
local dl_base = nil
A.dlists = symbols["dlists"]
-- SPP_SKYE=<15-bit rgb>: pin the erase colour (@irqskye), e.g. 0x7c1f magenta,
-- so a cut-out's black pixels (hair, trousers) are not mistaken for background.
local SKYE = tonumber(os.getenv("SPP_SKYE") or "")
A.irqskye = symbols["irqskye"]
local ZERO_AT = os.getenv("SPP_ZERO") and symbols[os.getenv("SPP_ZERO")]

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
        ["P1 High Punch"]=true, ["P2 High Punch"]=true, ["P1 Down"]=true }
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
    print(string.format("[spp] SNAP %s frame=%d %s", TAG, frame, label))
end

local function report(label)
    -- peak_overload is prcdsp's frame-overrun meter latched at its worst; 2 =
    -- every process pass finished inside its tick (doc/PERFORMANCE.md). The
    -- guards add four 76x218-class blits to the frame, so this is the number
    -- that says whether that cost anything. qdma_drops counts discarded
    -- sprites and is 0 on stock.
    if A.peak_overload then
        print(string.format("[spp] %s peak_overload=%d qdma_drops=%d",
            label, r16(A.peak_overload), r16(A.qdma_drops)))
    end
    print(string.format(
        "[spp] %s worldtly=%d ground_y=%d edges=%d..%d  x=%d x0=%d x2=%d x3=%d x4=%d x5=%d x6=%d x7=%d x8=%d",
        label, s16(r32(A.worldtly) >> 16), s16(r16(A.ground_y)),
        s16(r16(A.left_edge)), s16(r16(A.right_edge)),
        wx(A.worldtlx), wx(A.worldtlx0), wx(A.worldtlx2), wx(A.worldtlx3),
        wx(A.worldtlx4), wx(A.worldtlx5), wx(A.worldtlx6), wx(A.worldtlx7), wx(A.worldtlx8)))
    for _, n in ipairs({"baklst2", "baklst3", "baklst4", "baklst6"}) do
        local p, c = r32(A[n]), 0
        while p ~= 0 and c < 90 do
            if c < 12 then
                print(string.format("[spp]   %s[%d] xy=(%d,%d) sag=0x%08x size=0x%08x pal=%04x",
                    n, c, s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
                    r32(p + O.osag), r32(p + O.osize), r16(p + O.opal)))
            end
            p = r32(p + O.next); c = c + 1
        end
        print(string.format("[spp]   %s total=%d", n, c))
    end
end

-- park both fighters at a world x so the scroller drags the camera there
-- SPP_SPREAD=<px>: park P1 that far left of the stop and P2 that far right
-- instead of stacking them on one x.
local SPREAD = tonumber(os.getenv("SPP_SPREAD") or "0")
local SHAKE = tonumber(os.getenv("SPP_SHAKE") or "")
local shake_base = 0
local function park(x)
    for i, h in ipairs({A.p1_obj, A.p2_obj}) do
        local o = r32(h)
        local px = x + (i == 1 and -SPREAD or SPREAD)
        if o ~= 0 then w32(o + O.oxval, (px & 0xffff) << 16) end
    end
end

-- The scroller only closes a few px per tick, so a stop needs a long hold to
-- actually reach a scroll limit: 60 frames of parking moved the camera ~120px
-- and left THE TOWER's right-hand statue group off screen entirely, which
-- looked like the group was missing rather than out of shot.  Each stop parks
-- both fighters for `hold` frames and the report prints worldtlx, so a stop
-- that did NOT reach its edge is visible in the log.
local HOLD = 320
local STOPS = {}
for xs in (os.getenv("SPP_STOPS") or "40,560,1090"):gmatch("[^,]+") do
    STOPS[#STOPS + 1] = {name = "x" .. xs, x = tonumber(xs), at = HOLD * (#STOPS + 1)}
end
local done_frame = 0

-- SPP_UPPER=1: at each stop P1 throws an uppercut (Down + High Punch) into the
-- parked P2 and every frame of the hit and the screen shake is snapped
local UPPER = os.getenv("SPP_UPPER") == "1"
local function pressed(name)
    if fighting_frame > 0 then
        if not UPPER then return false end
        local rel = frame - fighting_frame
        for _, st in ipairs(STOPS) do
            local t = rel - (st.at - 90)
            if name == "P1 Down" and t >= 0 and t < 14 then return true end
            if name == "P1 High Punch" and t >= 6 and t < 12 then return true end
        end
        return false
    end
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
        print("[spp] loaded, forcing curback ( " .. TOWER .. "), tag=" .. TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[spp] frame=%d gstate %d -> %d", frame, last_gstate, gs))
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
        if not did_select then did_select = true; print("[spp] forced chars+stage") end
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    -- curback is re-read at stage load; keep pinning it until the fight starts
    if fighting_frame == 0 then w16(A.curback, TOWER) end

    -- SPP_DLSKIP=<bits>: start the display walk that many bits into the
    -- stage's own dlists_ table, so the planes in front of it are not drawn
    -- (e.g. 352 on THE ARMORY skips every baklst and the floor, leaving the
    -- fighters, ghosts and HUD on the erase colour - a cut-out for mockups).
    if fighting_frame > 0 and DLSKIP then
        if not dl_base then
            dl_base = r32(A.dlists)
            print(string.format("[spp] dlists %08x -> +%d bits (entry %08x)",
                dl_base, DLSKIP, r32(dl_base + DLSKIP)))
        end
        w32(A.dlists, dl_base + DLSKIP)
    end
    if fighting_frame > 0 and SKYE and A.irqskye then w16(A.irqskye, SKYE) end
    -- SPP_ZERO=<map symbol>: keep that 32-bit list head empty every frame, so a
    -- private display list draws nothing (a clean plate for mockups)
    if fighting_frame > 0 and ZERO_AT then w32(ZERO_AT, 0) end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        for i, st in ipairs(STOPS) do
            if rel >= st.at - HOLD and rel < st.at then park(st.x) end
            if rel == st.at then
                report(st.name); snap(st.name)
            end
            if UPPER and rel >= st.at - 84 and rel < st.at - 24 then
                snap(string.format("%s_up%02d_wy%d", st.name, rel - (st.at - 84), s16(r16(A.worldtly + 16))))
            end
            -- SPP_SHAKE=<px>: also hold the camera that far UP for a few frames
            -- before each stop's snapshot and snap that too - what es_sub
            -- (MKFX.ASM) does to worldtly on a hard hit
            if SHAKE and rel == st.at - 30 then shake_base = r16(A.worldtly + 16) end
            if SHAKE and rel > st.at - 30 and rel <= st.at - 20 then
                w16(A.worldtly + 16, shake_base - SHAKE)
                if rel == st.at - 22 then snap(st.name .. "_shake") end
            end
            if SHAKE and rel == st.at - 19 then w16(A.worldtly + 16, shake_base) end
        end
        if rel > STOPS[#STOPS].at + 20 and done_frame == 0 then
            done_frame = frame; print("[spp] finished")
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 1400 + HOLD * (#STOPS + 1) then print("[spp] TIMEOUT"); manager.machine:exit(); return end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close(); logfh = nil end end)
