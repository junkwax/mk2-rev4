-- dp_force_deadpool_visual.lua
--
-- Lightweight visual test helper for Dead Pool work. Forces curback to
-- Dead Pool during early boot/setup, then only logs stage state. It does not
-- touch players, health, winner state, or fatality flags.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP_PATH = ROOT .. "/src/mk2.map"
local LOG_PATH = ROOT .. "/tmp/dp/force_deadpool_visual.log"

local DEAD_POOL = 0
local FORCE_FRAMES = 900
local LOG_EVERY_FRAMES = 60
local SNAPSHOT_FRAMES = {
    [240] = true,
    [360] = true,
    [480] = true,
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
    gstate = map_symbol("gstate", 0x0112A7D0),
    curback = map_symbol("curback", 0x0112C0D0),
    winner_status = map_symbol("winner_status", 0x0112C110),
}

local function r16(a)
    if not space or not a or a == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(a) end)
    return ok and v or 0
end

local function w16(a, v)
    if not space or not a or a == 0 then return end
    pcall(function() space:write_u16(a, v & 0xffff) end)
end

log("Dead Pool visual force loaded")
log("symbols: gstate=0x%08X curback=0x%08X winner_status=0x%08X",
    A.gstate, A.curback, A.winner_status)

local frame = 0
local last_curback = -1

emu.register_frame_done(function()
    frame = frame + 1

    if frame <= FORCE_FRAMES then
        w16(A.curback, DEAD_POOL)
    end

    local cb = r16(A.curback)
    if cb ~= last_curback then
        log("frame=%d curback=%d gstate=%d winner=%d",
            frame, cb, r16(A.gstate), r16(A.winner_status))
        last_curback = cb
    elseif frame % LOG_EVERY_FRAMES == 0 then
        log("frame=%d curback=%d gstate=%d winner=%d",
            frame, cb, r16(A.gstate), r16(A.winner_status))
    end

    if SNAPSHOT_FRAMES[frame] and manager.machine.video then
        manager.machine.video:snapshot()
        log("snapshot frame=%d", frame)
    end
end)
