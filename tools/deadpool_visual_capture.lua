-- deadpool_visual_capture.lua
--
-- Screenshot helper for the MKAMODE test-fight Dead Pool path.
-- This intentionally does not force curback after setup; MKAMODE.ASM's
-- test_stage must be 0 so the background is created as Dead Pool.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP_PATH = ROOT .. "/src/mk2.map"
local LOG_PATH = ROOT .. "/tmp/dp/deadpool_visual_capture.log"

local DEAD_POOL = 0
local SNAPSHOT_FRAMES = {
    [120] = "boon_chain_hold",
    [180] = "boon_drop_mid",
    [240] = "boon_drop_low",
    [300] = "boon_submerged",
    [360] = "acid_check_1",
    [480] = "acid_check_2",
    [600] = "acid_check_3",
    [840] = "acid_wait",
    [930] = "chain_breach_bubbles",
    [1080] = "bubble_window",
    [1200] = "bubble_cleanup",
    [1020] = "acid_rise_start",
    [1120] = "acid_rise_mid",
    [1220] = "acid_rise_high",
    [1320] = "acid_rise_hold",
}

local logf = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
    print(line)
    if logf then
        logf:write(line .. "\n")
        logf:flush()
    end
end

local function map_symbol(name, fallback)
    local f = io.open(MAP_PATH, "r")
    if not f then return fallback end
    for line in f:lines() do
        for addr, sym in line:gmatch("([0-9A-Fa-f]+)%s+([_%w]+)") do
            if sym == name then
                f:close()
                return tonumber(addr, 16)
            end
        end
    end
    f:close()
    return fallback
end

local space
pcall(function()
    space = manager.machine.devices[":maincpu"].spaces["program"]
end)

local A = {
    objlst = map_symbol("objlst", 0x01127570),
    gstate = map_symbol("gstate", 0x0112A7D0),
    curback = map_symbol("curback", 0x0112C0D0),
    winner_status = map_symbol("winner_status", 0x0112C110),
    worldtlx = map_symbol("worldtlx", 0x0112C050),
}

local PID_EDPOOL_FX = 0x0111
local PID_EDPOOL_PREVIEW = 0x0112
local M_MULTIPART = 0x0002
local M_INVIS = 0x0020

local O = {
    olink = 0x000,
    oxpos = 0x090,
    oypos = 0x0b0,
    ozpos = 0x0d0,
    oflags2 = 0x160,
    oimg = 0x1a0,
    oid = 0x1c0,
}

local function r16(a)
    if not space or not a or a == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(a) end)
    return ok and v or 0
end

local function r32(a)
    if not space or not a or a == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u32(a) end)
    return ok and v or 0
end

local function s16(v)
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

local function log_edpool_objects()
    local wx = s16(r16(A.worldtlx + 16))
    local p = r32(A.objlst)
    local count = 0
    local seen = 0

    while p ~= 0 and count < 160 do
        local oid = r16(p + O.oid)
        if oid == PID_EDPOOL_FX or oid == PID_EDPOOL_PREVIEW then
            local flags2 = r16(p + O.oflags2)
            local x = s16(r16(p + O.oxpos))
            local y = s16(r16(p + O.oypos))
            local z = s16(r16(p + O.ozpos))
            local multipart = (flags2 & M_MULTIPART) ~= 0
            local invis = (flags2 & M_INVIS) ~= 0
            seen = seen + 1
            local kind = (oid == PID_EDPOOL_FX) and "edpool_fx" or "edpool_preview"
            log("  %s[%d] obj=0x%08X multipart=%s invis=%s world=(%d,%d,%d) screen=(%d,%d,%d) img=0x%08X",
                kind, seen, p, tostring(multipart), tostring(invis), x, y, z, x - wx, y, z, r32(p + O.oimg))
        end
        p = r32(p + O.olink)
        count = count + 1
    end

    if seen == 0 then
        log("  edpool preview/fx none found")
    end
end

log("Dead Pool visual capture loaded")
log("symbols: gstate=0x%08X curback=0x%08X winner_status=0x%08X",
    A.gstate, A.curback, A.winner_status)

local frame = 0
emu.register_frame_done(function()
    frame = frame + 1
    if not space then return end

    local tag = SNAPSHOT_FRAMES[frame]
    if tag then
        local cb = r16(A.curback)
        local gs = r16(A.gstate)
        local win = r16(A.winner_status)
        if cb ~= DEAD_POOL then
            log("WARNING snapshot=%s frame=%d curback=%d, expected Dead Pool curback=0", tag, frame, cb)
        else
            log("snapshot=%s frame=%d curback=%d gstate=%d winner=%d", tag, frame, cb, gs, win)
        end
        log_edpool_objects()
        if manager.machine.video then
            manager.machine.video:snapshot()
        end
    end
end)
