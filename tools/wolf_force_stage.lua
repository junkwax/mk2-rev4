-- wolf_force_stage.lua - play the Wolf build normally, but every fight is on
-- one stage.  While the game is choosing a stage (any state but a fight in
-- progress) curback is held at WFS_STAGE (hex, default 23 = NOOB'S DORFEN);
-- nothing else is touched - coin up, pick fighters and play.
-- Env: WS_MAP (absolute path to tmp/wolf/src/MK2.MAP), WFS_STAGE.
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local GSTATE = S.gstate or error("no gstate in map")
local CURBACK = S.curback or error("no curback in map")
local STAGE = tonumber(os.getenv("WFS_STAGE") or "23", 16)
local space = manager.machine.devices[":maincpu"].spaces["program"]
emu.register_frame(function()
    if space:read_u16(GSTATE) ~= 2 then space:write_u16(CURBACK, STAGE) end
end)
