-- _boot_probe.lua - throwaway: does the ROM boot, and where does it park?
-- Logs gstate + PC every 60 frames, snapshots a few times, then exits.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local fh = assert(io.open(ROOT .. "/tools/_boot_probe_rig.log", "w"))
local function log(f, ...) local l = string.format(f, ...); print(l); fh:write(l, "\n"); fh:flush() end

local symbols = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        if symbols[n] == nil then symbols[n] = tonumber(a, 16) end
    end
end

local frame, cpu, space = 0, nil, nil
local fields = {}
local GSTATE = symbols["gstate"]

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if f.name == "UI Select" or f.name == "Coin 1"
                   or f.name == "1 Player Start" then fields[f.name] = f end
            end
        end
        log("probe up: gstate sym=%08x  fields: %s",
            GSTATE or 0,
            table.concat({ next(fields) and "found" or "NONE" }, ","))
    end
    local gs = space:read_u16(GSTATE)
    local ok, pc = pcall(function() return cpu.state["PC"].value end)
    if frame % 60 == 0 then
        log("frame %5d  gstate=%2d  pc=%s", frame, gs, ok and string.format("%08x", pc) or "?")
    end
    if frame == 400 or frame == 1200 or frame == 2400 then
        pcall(function() manager.machine.screens[":screen"]:snapshot() end)
        log("snapshot at frame %d", frame)
    end
    for n, f in pairs(fields) do
        local on = false
        if n == "UI Select" then on = frame >= 5 and frame < 60 end
        if n == "Coin 1" then on = frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if n == "1 Player Start" then on = frame >= 300 and frame < 1000 and (frame % 80) >= 40 and (frame % 80) < 60 end
        f:set_value(on and 1 or 0)
    end
    if frame >= 2500 then log("done"); manager.machine:exit() end
end)
