-- tower_feet_probe.lua - do THE TOWER's shadows meet the feet (shad_feet)?
-- Jade (swapped in after select) jabs a 1-HP P2 to win round 1; snapshots
-- while standing and through her victory, logging her art bottom each time.
-- Built on stage_park_probe.lua.  Driven by tools/run_tower_feet_probe.ps1.
-- (was: stage_park_probe.lua - tower_stage_probe.lua for ANY stage.)
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
    p2_bar = sym("p2_bar"), winner_status = sym("winner_status"),
    p1_proc = sym("p1_proc"), shad_feet = sym("shad_feet"), f_shadows = sym("f_shadows"), shad_ytop = sym("shad_ytop"), shad_ybot = sym("shad_ybot"), shad_bias = sym("shad_bias"),
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
local FT_P1 = tonumber(os.getenv("TFP_CHAR") or "16")   -- ft_jade
local FEET_OFF = os.getenv("TFP_FEET") == "0"
local TOWER = tonumber(os.getenv("SPP_STAGE") or "3")

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
        ["P1 High Punch"]=true, ["P2 High Punch"]=true, ["P1 Low Punch"]=true }
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


-- multipart node (DISPEQU): mp_sag 0, mp_sizey 48, mp_anixy 80 (y high), 112 bits
local MP_LEN = 112
local function art_bottom(o)
    local ram = r32(o + O.oimg)
    local oy = s16(r16(o + O.oypos))
    local best = -99999
    for i = 0, 10 do
        local n = ram + i * MP_LEN
        if r32(n) == 0 then break end
        local ay = s16(r32(n + 80) >> 16)
        local sy = s16(r16(n + 48))
        local b = oy - ay + sy
        if b > best then best = b end
    end
    return best
end

local function park(x1, x2)
    local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
    if o1 ~= 0 then w32(o1 + O.oxval, (x1 & 0xffff) << 16) end
    if o2 ~= 0 then w32(o2 + O.oxval, (x2 & 0xffff) << 16) end
end

local won_frame, done_frame, snapn = 0, 0, 0
local off_at, off_saved = 0, 1
local function shot(label)
    local o = r32(A.p1_obj)
    local gy = s16(r16(A.ground_y))
    local bot = o ~= 0 and art_bottom(o) or 0
    snapn = snapn + 1
    if o ~= 0 then
        local ram = r32(o + O.oimg); local parts = {}
        for i = 0, 10 do
            local n = ram + i * MP_LEN
            if r32(n) == 0 then break end
            parts[#parts+1] = string.format("[sag=%08x w=%d h=%d dx=%d dy=%d ctl=%04x]", r32(n), r16(n+32), r16(n+48), s16(r16(n+80)), s16(r16(n+96)), r16(n+64))
        end
        print(string.format("[tfp]   oscale=%08x oyval=%08x oflags=%04x pieces %s", r32(o + 0x180), r32(o + 0x0a0), r16(o + 0x0f0), table.concat(parts, " ")))
    end
    print(string.format("[tfp] #%03d %s oypos=%d art_bottom(world)=%d ground_y=%d gap=%d sag=%08x shad_feet=%d worldtly=%d ytop=%d ybot=%d bias=%d",
        snapn, label, o ~= 0 and s16(r16(o + O.oypos)) or 0, bot, gy, gy - bot,
        o ~= 0 and r32(r32(o + O.oimg)) or 0, r16(A.shad_feet), s16(r32(A.worldtly) >> 16),
        s16(r16(A.shad_ytop)), s16(r16(A.shad_ybot)), s16(r16(A.shad_bias))))
    local s = screen1(); if s then pcall(function() s:snapshot() end) end
    -- its twin with shadows OFF two frames later: the diff of the pair is
    -- the shadow alone, so where it lands is measured, not eyeballed
    off_saved = r16(A.f_shadows); w16(A.f_shadows, 0); off_at = frame + 2
end
local function shot_off()
    local s = screen1(); if s then pcall(function() s:snapshot() end) end
    print(string.format("[tfp] #%03d-off", snapn))
    w16(A.f_shadows, off_saved); off_at = 0
end

local function pressed(name)
    if fighting_frame > 0 then
        if name == "P1 Low Punch" and won_frame == 0 then return (frame % 16) < 6 end
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
        print("[tfp] loaded, stage " .. TOWER .. " p1 char " .. FT_P1)
    end
    if not space then return end
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[tfp] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if gs == GS_PSEL then
            w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE)
        else
            w16(A.p1_char, FT_P1); w16(A.p2_char, FT_CAGE)   -- post-select: the swap
        end
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, TOWER) end

    if FEET_OFF and fighting_frame > 0 then w16(A.shad_feet, 0) end   -- TFP_FEET=0: the stock anchor, as a control
    if off_at > 0 and frame == off_at then shot_off() end
    if fighting_frame > 0 and done_frame == 0 then
        local rel = frame - fighting_frame
        local ws = r16(A.winner_status)
        if won_frame == 0 then
            if rel < 60 then park(380, 600)
            elseif rel < 240 then park(380, 600)       -- standing apart: stance shots
            else park(380, 440) end
            if rel == 120 or rel == 150 or rel == 180 or rel == 210 then shot("stance") end
            if rel >= 240 and r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
            if ws ~= 0 and rel > 240 then won_frame = frame; print("[tfp] round decided ws=" .. ws .. " rel=" .. rel) end
            if rel > 2400 then print("[tfp] TIMEOUT never won"); done_frame = frame end
        else
            local wr = frame - won_frame
            if wr % 6 == 0 and wr <= 120 then shot(string.format("win+%d", wr)) end
            if wr > 560 then done_frame = frame; print("[tfp] finished") end
        end
    end
    if done_frame > 0 and frame - done_frame > 5 then manager.machine:exit(); return end
    if frame > 6000 then print("[tfp] TIMEOUT"); manager.machine:exit(); return end
    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close(); logfh = nil end end)
