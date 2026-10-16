-- clear_test.lua - does the power-up clear (clscrach, MKINIT.ASM) reach all
-- of .bss?
--
-- MAME zero-fills RAM, so a cold boot can never show RAM the game forgot to
-- clear.  This lets the game come up, seeds two bands with a pattern word,
-- and soft-resets: the CPU goes back through POWERUP -> warmset -> clscrach
-- over dirty RAM.  Twenty frames later it counts pattern words left:
--
--   upper    01100000 .. `end` (map)   - the band the old fixed-count clear
--                                        never reached
--   control  010f0000 .. 01100000       - cleared by both old and new
--
-- The seed is written at a point in attract where nothing much is running;
-- the reset throws all of it away anyway.
--
-- env: CL_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("CL_LOG") or (ROOT .. "/tools/clear_test.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[cl] " .. string.format(fmt, ...)
    logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local END = assert(symbols["end"], "missing map symbol end")
local PATTERN = 0xa5a5
local SEED_AT, CHECK_AFTER = 400, 20
local BANDS = { { "upper", 0x01100000, END }, { "control", 0x010f0000, 0x01100000 } }

local frame, space, reset_frame = 0, nil, nil

local function count(lo, hi)
    local n, total = 0, 0
    local a = lo
    while a < hi do
        if space:read_u16(a) == PATTERN then n = n + 1 end
        total = total + 1
        a = a + 16
    end
    return n, total
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        log("end=%08x", END)
    end
    if not space then return end
    if frame == SEED_AT then
        for _, b in ipairs(BANDS) do
            local a = b[2]
            while a < b[3] do space:write_u16(a, PATTERN); a = a + 16 end
            local n, total = count(b[2], b[3])
            log("SEEDED %s %08x..%08x pattern=%d/%d", b[1], b[2], b[3], n, total)
        end
        reset_frame = frame
        manager.machine:soft_reset()
        log("SOFT_RESET frame=%d", frame)
    end
    if reset_frame and frame == reset_frame + CHECK_AFTER then
        for _, b in ipairs(BANDS) do
            local n, total = count(b[2], b[3])
            log("BAND %s %08x..%08x pattern_left=%d of %d", b[1], b[2], b[3], n, total)
        end
        log("RESULT done")
        logfh:close()
        manager.machine:exit()
    end
end)
