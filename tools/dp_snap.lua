-- dp_snap.lua : snapshot + log key state each second (runs inside MAME).
local logf = io.open("C:/Users/you/Workplace/mk2-main/tmp/dp/state.log","w")
local function lg(s) print(s); if logf then logf:write(s.."\n"); logf:flush() end end

local space
pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)

-- byte addresses (bit/8) from MK2.MAP
local A_gstate = 0x2253b8
local A_curback = 0x2256d8
local A_winner  = 0x2256e0

local n, frame = 0, 0
emu.register_frame_done(function()
    frame = frame + 1
    if frame % 60 ~= 0 then return end
    n = n + 1
    if space then
        local gs = space:read_u16(A_gstate)
        local cb = space:read_u16(A_curback)
        local wn = space:read_u16(A_winner)
        lg(string.format("t=%2ds  gstate=%d curback=%d winner=%d", n, gs, cb, wn))
    end
    if n <= 45 then manager.machine.video:snapshot() end
end)
lg("dp_snap loaded")
