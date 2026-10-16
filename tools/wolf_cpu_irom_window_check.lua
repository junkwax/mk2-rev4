-- wolf_cpu_irom_window_check.lua - how does the Wolf CPU see image ROM?
-- For each image bank (sysctrl bits 8-9) read words through the CPU window
-- (bit address 02000000h + 8*offset) and compare them with MAME's :video
-- region at bank*8MB + offset.  The answer decides where Wolf-only data the
-- CPU reads (the VS portraits, UNZIP.ASM) can live.  Restores sysctrl after.
local LOG = os.getenv("WB_LOG")
local SYSCTRL = 0x01b00000
local done = false
emu.register_frame(function()
    if done or manager.machine.time:as_double() < 2.0 then return end
    done = true
    local cpu = manager.machine.devices[":maincpu"]
    local space = cpu.spaces["program"]
    local vid = manager.machine.memory.regions[":video"]
    local f = io.open(LOG, "w")
    local syscopy = tonumber(os.getenv("WB_SYSCOPY") or "0", 16)
    local base = space:read_u16(syscopy) & 0xFCFF
    for bank = 0, tonumber(os.getenv("WB_MAXBANK") or "1") do
        space:write_u16(SYSCTRL, base | (bank << 8))
        for _, span in ipairs({ { 0, "low half" }, { 0x400000, "high half" } }) do
            local ok, n = 0, 0
            for k = 0, 255 do
                local off = span[1] + k * 16382              -- 256 even offsets, all inside this 4 MB half
                local cpuw = space:read_u16(0x02000000 + off * 8)
                local lin = bank * 0x800000 + off
                local vw = vid:read_u8(lin) | (vid:read_u8(lin + 1) << 8)
                n = n + 1
                if cpuw == vw then ok = ok + 1 end
            end
            f:write(string.format("bank %d %s: CPU window == video[bank*8MB+off] for %d/%d words\n", bank, span[2], ok, n))
        end
    end
    -- bank 0, upper half: which 4 MB block of the video region does the CPU see?
    space:write_u16(SYSCTRL, base)
    local hist = {}
    for k = 0, 255 do
        local off = 0x400000 + k * 16382
        local cpuw = space:read_u16(0x02000000 + off * 8)
        for j = 0, 7 do
            local lin = j * 0x400000 + (off - 0x400000)
            if lin + 1 < vid.size and (vid:read_u8(lin) | (vid:read_u8(lin + 1) << 8)) == cpuw then
                hist[j] = (hist[j] or 0) + 1
            end
        end
    end
    local shown = 0
    for k = 0, 255 do
        local off = 0x400000 + k * 16382
        local cpuw = space:read_u16(0x02000000 + off * 8)
        local function vw(o) return vid:read_u8(o) | (vid:read_u8(o + 1) << 8) end
        if cpuw ~= vw(off) and shown < 10 then
            shown = shown + 1
            f:write(string.format("  miss off %06X cpu %04X | vid off %04X  off^2 %04X  off+2 %04X  off-2 %04X  again %04X\n",
                off, cpuw, vw(off), vw(off ~ 2), vw(off + 2), vw(off - 2), space:read_u16(0x02000000 + off * 8)))
        end
    end
    local t = {}
    for j = 0, 7 do t[#t + 1] = string.format("%dMB:%d", j * 4, hist[j] or 0) end
    f:write("bank 0 upper half (CPU 04000000h+) matches video block: " .. table.concat(t, " ") .. "\n")
    space:write_u16(SYSCTRL, space:read_u16(syscopy))
    f:close()
    manager.machine:exit()
end)
