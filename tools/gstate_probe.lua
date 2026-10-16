local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
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
local GS = symbols["gstate"] or 0x0112a830
local fh = assert(io.open(ROOT .. "/tools/gstate_probe.log", "w"))
local cpu, space, frame, last = nil, nil, 0, nil
fh:write(string.format("gstate addr = %08x\n", GS)); fh:flush()
emu.register_frame(function()
    if not space then
        cpu = manager.machine.devices[":maincpu"]; if not cpu then return end
        space = cpu.spaces["program"]; if not space then return end
    end
    frame = frame + 1
    local gs = space:read_u16(GS)
    if gs ~= last then
        fh:write(string.format("frame %5d  gstate=%04x\n", frame, gs)); fh:flush()
        last = gs
    end
    if frame > 3600 then fh:write("done\n"); fh:flush(); manager.machine:exit() end
end)
