local LOG_PATH = os.getenv("ARMORY_AUDIT_LOG") or "C:/Users/you/Workplace/mk2-main/tools/armory_space_probe.log"
local logfh = io.open(LOG_PATH, "w")
local function logprint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local done = false
local frame = 0
emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame < 60 then return end
    done = true

    logprint("[probe] devices:")
    for tag, dev in pairs(manager.machine.devices) do
        logprint("  device " .. tag)
    end

    local cpu = manager.machine.devices[":maincpu"]
    logprint("[probe] maincpu spaces:")
    for name, sp in pairs(cpu.spaces) do
        logprint("  space " .. name .. " dataw=" .. tostring(sp.data_width))
    end
end)
