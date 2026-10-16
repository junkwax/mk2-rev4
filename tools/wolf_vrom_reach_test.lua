-- wolf_vrom_reach_test.lua - can MK2's sprite DMA draw from video ROM ABOVE
-- the 12 MB it ships with, on the Wolf board?  (doc/WOLF_SPACE.md)
-- Driven by tools/run_wolf_vrom_reach_test.ps1 through run_wolf_boot_probe.ps1.
--
-- WR_MODE census  - record the SAGs the title screen hands the DMA, and for
--                   each, how many times it appears as a long in program ROM
--         control - change nothing; snapshot
--         copy    - copy that sprite's bytes up by WR_DELTA in the video
--                   region and repoint its header (SAG + WR_DELTA*8); snapshot
--         nocopy  - repoint the header only; snapshot.  MUST differ from control
-- WR_SAG / WR_ROMOFS (hex): the sprite and where its header long lives,
-- WR_DELTA (hex bytes), WR_LEN (hex bytes to copy), WR_SNAP (frame to snap).
-- SAG -> video byte offset is ((SAG - 02000000h) >> 3) + WR_BANK * 400000h:
-- a SAG is a BIT address, and bank 1 is 4 MB up (WR_BANK).
local LOG = os.getenv("WB_LOG")
local MODE = os.getenv("WR_MODE") or "census"
local SAG = tonumber(os.getenv("WR_SAG") or "0", 16)
local ROMOFS = tonumber(os.getenv("WR_ROMOFS") or "0", 16)
local DELTA = tonumber(os.getenv("WR_DELTA") or "0", 16)
local LEN = tonumber(os.getenv("WR_LEN") or "10000", 16)
local SNAP = tonumber(os.getenv("WR_SNAP") or "400")
-- MK2 addresses video ROM in two banks: the header's DMA control word picks
-- one, and bank 1 sits 4 MB higher (makevrom.py image_byte_offset).
local BANK = tonumber(os.getenv("WR_BANK") or "0")
local CTRL, SAGL, SAGH = 0x01a00010, 0x01a00020, 0x01a00030   -- Wolf DMA (SYSEQU.ASM)

local f = nil
local function log(s)
    if not f then f = io.open(LOG, "w") end
    f:write(s .. "\n"); f:flush()
end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local rom = manager.machine.memory.regions[":maincpu"]
local vid = manager.machine.memory.regions[":video"]

-- commit-time SAG taps (sag_census.lua's method; learns bit vs byte offsets)
local seen, lo, hi, scale = {}, nil, nil, nil
local counting = false
local traffic, first = 0, {}
local function on_write(offset, data, mask)
    traffic = traffic + 1
    if #first < 6 then first[#first + 1] = string.format("%X", offset) end
    if scale == nil then
        if offset == CTRL or offset == SAGL or offset == SAGH then scale = 1
        elseif offset * 8 == CTRL or offset * 8 == SAGL or offset * 8 == SAGH then scale = 8 end
    end
    if scale == nil then return data end
    local b = offset * scale
    if b == SAGL then lo = data & 0xffff
    elseif b == SAGH then hi = data & 0xffff
    elseif b == CTRL and lo and hi and counting then
        local s = (hi << 16) | lo
        seen[s] = (seen[s] or 0) + 1
    end
    return data
end
local taps = {}
for _, r in ipairs({ { 0x01a00000, 0x01a000ff }, { 0x01a00000 // 8, 0x01a000ff // 8 } }) do
    local ok, h = pcall(function() return space:install_write_tap(r[1], r[2], "wr_" .. r[1], on_write) end)
    if ok and h then taps[#taps + 1] = h end
end

local function rom_hits(v)
    local n, at = 0, nil
    for o = 0, rom.size - 4, 2 do
        if rom:read_u32(o) == v then n = n + 1; at = at or o end
    end
    return n, at
end

local started, frame = false, 0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
        log(string.format("start mode=%s rom=%d bytes video=%d bytes", MODE, rom.size, vid.size))
        if MODE == "copy" or MODE == "nocopy" then
            if rom:read_u32(ROMOFS) ~= SAG then log("ROM long at ROMOFS is not WR_SAG - wrong build"); manager.machine:exit(); return end
            local src = ((SAG - 0x02000000) >> 3) + BANK * 0x400000
            if MODE == "copy" then
                for i = 0, LEN - 1 do vid:write_u8(src + DELTA + i, vid:read_u8(src + i)) end
            end
            rom:write_u32(ROMOFS, SAG + DELTA * 8)
            log(string.format("patched header @%X: %08X -> %08X (%s, video %X -> %X)", ROMOFS, SAG, SAG + DELTA * 8,
                MODE, src, src + DELTA))
        end
    end
    frame = frame + 1
    counting = frame >= 250 and frame <= SNAP
    if frame == SNAP then
        manager.machine.video:snapshot()
        local want = SAG + DELTA * 8
        log(string.format("snap f=%d  DMA commits of the moved SAG %08X: %d, of the original %08X: %d",
            frame, want, seen[want] or 0, SAG, seen[SAG] or 0))
        if MODE == "census" then
            local list = {}
            for s, c in pairs(seen) do list[#list + 1] = { s, c } end
            table.sort(list, function(a, b) return a[2] > b[2] end)
            for i = 1, math.min(#list, 40) do
                local n, at = rom_hits(list[i][1])
                log(string.format("SAG %08X commits %d rom_hits %d first %s", list[i][1], list[i][2], n, at and string.format("%X", at) or "-"))
            end
        end
        log(string.format("taps=%d writes=%d scale=%s first offsets %s", #taps, traffic, tostring(scale), table.concat(first, " ")))
        log("done"); f:close(); manager.machine:exit()
    end
end)
