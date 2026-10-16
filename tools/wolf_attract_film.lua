-- wolf_attract_film.lua - let the attract loop run untouched for AF_FRAMES
-- frames (default 12000), a snapshot every AF_EVERY (300); illop_count must
-- not move.  Env: WB_LOG, WS_MAP.
local f = io.open(os.getenv("WB_LOG"), "w")
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local N = tonumber(os.getenv("AF_FRAMES") or "12000")
local E = tonumber(os.getenv("AF_EVERY") or "300")
local frame, ill0 = 0, nil
emu.register_frame(function()
    frame = frame + 1
    if frame == 600 then ill0 = space:read_u16(S.illop_count) end
    if frame > 600 and space:read_u16(S.illop_count) ~= ill0 then
        f:write("FAIL illop_count moved at " .. frame .. "\n"); f:close(); manager.machine:exit(); return
    end
    if frame % E == 0 then manager.machine.video:snapshot() end
    if frame >= N then f:write("PASS " .. N .. " frames of attract\n"); f:close(); manager.machine:exit() end
end)
