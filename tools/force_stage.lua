-- force_stage.lua - every match is fought on one stage, for playtesting it.
--   mame mk2 -autoboot_script tools/force_stage.lua      (FS_STAGE env, default 5 = THE ARMORY)
-- Pins curback (BGND.ASM table_o_mods index) whenever a fight is not running,
-- so the stage load at each round reads it.  Addresses come from src/mk2.map.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local STAGE = tonumber(os.getenv("FS_STAGE") or "5")
local sym = {}
for line in io.lines(os.getenv("FS_MAP") or (ROOT .. "/src/mk2.map")) do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_]+)") do sym[n] = tonumber(a, 16) end
end
local space
emu.register_frame(function()
    if not space then space = manager.machine.devices[":maincpu"].spaces["program"] end
    if space:read_u16(sym.gstate) ~= 2 then space:write_u16(sym.curback, STAGE) end
end)
print("[force_stage] every match on curback " .. STAGE)
