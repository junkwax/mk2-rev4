-- Minimal MAME Lua API probe
local logf = io.open("C:/Users/you/Workplace/mk2-main/lua_probe.log", "w")
local function lg(s) print(s); if logf then logf:write(s.."\n"); logf:flush() end end

lg("Lua loaded OK")
lg("MAME version: " .. tostring(emu.app_version and emu.app_version() or "unknown"))

-- Test memory access API
local ok, err = pcall(function()
    local cpu = manager.machine.devices[":maincpu"]
    lg("cpu: " .. tostring(cpu))
    local sp = cpu.spaces["program"]
    lg("space: " .. tostring(sp))
    local v = sp:read_u16(0x0112b690 // 8)  -- curback byte addr
    lg("curback word = " .. tostring(v))
end)
if not ok then lg("pcall error: " .. tostring(err)) end

lg("probe done")
