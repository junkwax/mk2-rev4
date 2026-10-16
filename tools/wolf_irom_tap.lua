-- wolf_irom_tap.lua - WHO READS IMAGE ROM THROUGH THE CPU, and in which bank.
--
-- The Wolf CPU sees image ROM through a window at 02000000h-06FFFFFFh (bit
-- addresses), banked by sysctrl bits 8-9.  Before any data is moved into image
-- ROM for the CPU to read (doc/WOLF_OPPORTUNITIES.md W07), every CPU reader of
-- that window has to be known: a reader that assumes bank 0 breaks the moment
-- the default bank changes.  This rides tools/wolf_boot_probe.lua (attract,
-- coins, select, VS, a fight - run it through run_wolf_boot_probe.ps1
-- -Script wolf_irom_tap.lua -Coin) and logs, per reading PC: how many reads,
-- the address range, the bank the window was in, and the gstates seen.
--
-- env: as wolf_boot_probe.lua, plus WB_SYSCOPY (raw bit address of syscopy).
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(here .. "/wolf_boot_probe.lua")

local LOG = os.getenv("WB_LOG")
local GSTATE = tonumber(os.getenv("WB_GSTATE") or "0", 16)
local SYSCOPY = tonumber(os.getenv("WB_SYSCOPY") or "0", 16)
local readers, tap, installed = {}, nil, false

local function record(offset)
    local cpu = manager.machine.devices[":maincpu"]
    local sp = cpu.spaces["program"]
    local pc = cpu.state["PC"].value
    local bank = SYSCOPY ~= 0 and ((sp:read_u16(SYSCOPY) >> 8) & 3) or -1
    local key = string.format("%08X b%d", pc, bank)
    local r = readers[key]
    if not r then
        r = { n = 0, lo = offset, hi = offset, gs = {} }
        readers[key] = r
    end
    r.n = r.n + 1
    if offset < r.lo then r.lo = offset end
    if offset > r.hi then r.hi = offset end
    if GSTATE ~= 0 then r.gs[sp:read_u16(GSTATE)] = true end
end

emu.register_frame(function()
    if installed then return end
    installed = true
    local sp = manager.machine.devices[":maincpu"].spaces["program"]
    _G.IROM_TAP = sp:install_read_tap(0x02000000, 0x06ffffff, "irom_readers", function(offset, data, mask)
        record(offset)
        return data
    end)
end)

local function dump()
    local f = io.open(LOG .. ".irom", "w")
    local keys = {}
    for k in pairs(readers) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local r = readers[k]
        local gs = {}
        for g in pairs(r.gs) do gs[#gs + 1] = string.format("%X", g) end
        table.sort(gs)
        f:write(string.format("%s reads=%d addr=%08X..%08X gstates=%s\n", k, r.n, r.lo, r.hi, table.concat(gs, ",")))
    end
    f:write(string.format("READERS %d\n", #keys))
    f:close()
end
-- keep the handles: an unreferenced notifier or tap is collected and goes quiet
_G.IROM_TAP_STOP = emu.add_machine_stop_notifier(dump)
local nfr = 0
_G.IROM_TAP_FRAME = emu.add_machine_frame_notifier(function()
    nfr = nfr + 1
    if nfr % 600 == 0 then dump() end
end)
