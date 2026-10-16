-- tomb_bat_probe.lua
-- Force a match onto KOMBAT TOMB (curback = 1, table_o_mods index 1 = tomb_mod),
-- sweep the camera back and forth across the stage, and watch the two bats on
-- baklst4 (bats_proc / small_bat_proc, BGND.ASM).
--
-- The defect this measures: bat_pause stops a bat (oxvel = 0, no anirate) for
-- 060h ticks once it is 040h past a screen edge.  That is barely off screen, so
-- a camera scroll during the pause drags the frozen bat back into view.
--
-- Per frame, per bat: on screen (rect vs 400x254) and oxvel == 0 -> FROZEN.
-- Moving-and-on-screen frames are counted too as the positive control: a probe
-- that never sees a bat at all would otherwise read as a clean pass.
--
-- env: MK2_TOMB_TAG - label for the log / snapshots (default "base")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_TOMB_TAG") or "base"
local LOG_PATH = ROOT .. "/tools/tomb_bat_probe_" .. TAG .. ".log"
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
    if not v then print("[tomb] FATAL missing map symbol " .. name) end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    worldtly = sym("worldtly"), worldtlx = sym("worldtlx"), worldtlx4 = sym("worldtlx4"),
    baklst4 = sym("baklst4"),
    f_freeze_timer = symbols["f_freeze_timer"],
}

local O = { next = 0x000, oxvel = 0x040, oxval = 0x080, oxpos = 0x090,
            oypos = 0x0b0, osize = 0x120 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_CAGE = 1, 2
local TOMB = 1
local SCR_W, SCR_H = 400, 254

local fields, cpu, space = {}, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end return v end
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

local snaps = 0
local function snap(label)
    if snaps >= 6 then return end
    local s = screen1(); if not s then return end
    pcall(function() s:snapshot() end)
    snaps = snaps + 1
    print(string.format("[tomb] SNAP %s frame=%d %s", TAG, frame, label))
end

local function park(x)
    for _, h in ipairs({A.p1_obj, A.p2_obj}) do
        local o = r32(h)
        if o ~= 0 then w32(o + O.oxval, (x & 0xffff) << 16) end
    end
end

-- Direction reversals at uneven points, so pauses land at every phase of a
-- scroll.  Tomb's camera runs worldtlx 01b0h..04dah; fighters sit ~200 px in.
local STOPS = { 450, 1400, 800, 1150, 500, 1350, 900, 450, 1250, 700, 1400, 600 }
local HOLD = 230
local RUN_FRAMES = #STOPS * HOLD

local bats = {}      -- keyed by object address
local events = 0
local done_frame = 0

local function watch_bats()
    local x4, ty = wx(A.worldtlx4), s16(r32(A.worldtly) >> 16)
    local p, c = r32(A.baklst4), 0
    while p ~= 0 and c < 16 do
        local b = bats[p]
        if not b then
            b = { id = string.format("%08x", p), frozen_on = 0, moving_on = 0,
                  pauses = 0, was_frozen = false, streak = 0, worst = 0 }
            bats[p] = b
        end
        local xv = s32(r32(p + O.oxvel))
        local sx = s16(r16(p + O.oxpos)) - x4
        local sy = s16(r16(p + O.oypos)) - ty
        local size = r32(p + O.osize)
        local w, h = size & 0xffff, size >> 16
        local on = sx < SCR_W and sx + w > 0 and sy < SCR_H and sy + h > 0
        local frozen = (xv == 0)
        if frozen and not b.was_frozen then b.pauses = b.pauses + 1 end
        b.was_frozen = frozen
        if on and frozen then
            b.frozen_on = b.frozen_on + 1
            b.streak = b.streak + 1
            if b.streak > b.worst then b.worst = b.streak end
            if b.streak == 1 then
                events = events + 1
                if events <= 20 then
                    print(string.format(
                        "[tomb] FROZEN-ON-SCREEN bat=%s frame=%d screen=(%d,%d) size=%dx%d worldtlx4=%d",
                        b.id, frame, sx, sy, w, h, x4))
                end
                snap("frozen bat=" .. b.id)
            end
        else
            b.streak = 0
            if on then b.moving_on = b.moving_on + 1 end
        end
        p = r32(p + O.next); c = c + 1
    end
end

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

local function summary()
    print(string.format("[tomb] SUMMARY tag=%s fight_frames=%d", TAG, frame - fighting_frame))
    local total_frozen, total_moving, n = 0, 0, 0
    for _, b in pairs(bats) do
        n = n + 1
        total_frozen = total_frozen + b.frozen_on
        total_moving = total_moving + b.moving_on
        print(string.format("[tomb]   bat=%s pauses=%d frozen_on_screen=%d (longest %d) moving_on_screen=%d",
            b.id, b.pauses, b.frozen_on, b.worst, b.moving_on))
    end
    print(string.format("[tomb] RESULT bats=%d frozen_on_screen_frames=%d events=%d moving_on_screen_frames=%d",
        n, total_frozen, events, total_moving))
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[tomb] loaded, forcing KOMBAT TOMB (curback " .. TOMB .. "), tag=" .. TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[tomb] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, TOMB) end

    if fighting_frame > 0 and done_frame == 0 then
        local rel = frame - fighting_frame
        -- no KO, no TIME OVER: the stage must stay up for the whole sweep
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
        park(STOPS[math.min(#STOPS, rel // HOLD + 1)])
        if rel > 120 then watch_bats() end   -- let the stage settle first
        if rel >= RUN_FRAMES then
            done_frame = frame
            summary()
            print("[tomb] finished")
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 1600 + RUN_FRAMES + 400 then print("[tomb] TIMEOUT"); summary(); manager.machine:exit(); return end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close(); logfh = nil end end)
