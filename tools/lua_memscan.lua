-- Scan wide game RAM to see if TMS34010 is actually executing
local logf = io.open("C:/Users/you/Workplace/mk2-main/memscan.log", "w")
local function lg(s) print(s); logf:write(s.."\n"); logf:flush() end

local space
local ok = pcall(function()
    space = manager.machine.devices[":maincpu"].spaces["program"]
end)
if not ok or not space then lg("ERROR"); return end

-- Scan the entire SCRATCH RAM (0x01000000 bit = 0x200000 byte up to 0x400000 byte)
-- Look for ANY non-zero 32-bit word in the first pass
lg("=== Initial scan of SCRATCH RAM (0x200000..0x240000) ===")
local nonzero_count = 0
for addr = 0x200000, 0x240000, 4 do
    local v = space:read_u32(addr)
    if v ~= 0 then
        nonzero_count = nonzero_count + 1
        if nonzero_count <= 20 then
            lg(string.format("  0x%06X = 0x%08X", addr, v))
        end
    end
end
lg(string.format("Total non-zero longs: %d", nonzero_count))

-- Also check key ROM addresses (verify ROM mapping works)
local rom_sample = space:read_u32(0x1ff0200)  -- start of program ROM (0xFF800000 bit = 0x1FF00000 byte)
-- actually: 0xFF800000 bit / 8 = 0x1FF00000 byte
lg(string.format("ROM @ 0x1FF00200 = 0x%08X (should be non-zero TMS code)", rom_sample))

local frame_count = 0
emu.register_frame_done(function()
    frame_count = frame_count + 1
    if frame_count == 60 then
        lg("=== After 1 second (60 frames) ===")
        local nz = 0
        for addr = 0x200000, 0x240000, 4 do
            if space:read_u32(addr) ~= 0 then nz = nz + 1 end
        end
        lg(string.format("Non-zero longs at T+1s: %d (was %d initially)", nz, nonzero_count))
        -- Sample key game addresses
        lg(string.format("  gstate(old addr)  0x2253B2 = 0x%04X", space:read_u16(0x2253B2)))
        lg(string.format("  gstate(new addr)  0x2253B8 = 0x%04X", space:read_u16(0x2253B8)))
        lg(string.format("  curback(new addr) 0x2256D8 = 0x%04X", space:read_u16(0x2256D8)))
    end
    if frame_count == 300 then
        lg("=== After 5 seconds ===")
        local nz = 0
        for addr = 0x200000, 0x210000, 4 do
            local v = space:read_u32(addr)
            if v ~= 0 then
                nz = nz + 1
                if nz <= 5 then lg(string.format("  0x%06X = 0x%08X", addr, v)) end
            end
        end
        lg(string.format("Non-zero longs in first 64KB: %d", nz))
        lg(string.format("  gstate@0x2253B8 = 0x%04X", space:read_u16(0x2253B8)))
        lg(string.format("  gstate@0x2253B2 = 0x%04X", space:read_u16(0x2253B2)))
    end
end)
lg("init done")
