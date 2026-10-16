-- umk3_stage_sweep.lua - RETAIL UMK3 as the reference for a stage port.
-- Starts a 2-player game, holds UMK3's stage index (RAM 01062260h - read off
-- the code at FF9B95B0, which indexes the stage table FF9501F0 with it) at
-- U3_STAGE (12 = BKGD_HADES_MOD, Scorpion's Lair), then walks both fighters to
-- the left end and to the right end, snapshotting every U3_EVERY frames.
-- Schedule-driven (no RAM map for UMK3's game state), so the snapshots carry
-- the frame number and the timing is read off them.
-- Env: U3_LOG, U3_STAGE (decimal), U3_EVERY, U3_END.
local LOG = os.getenv("U3_LOG") or "umk3_stage_sweep.log"
local STAGE = tonumber(os.getenv("U3_STAGE") or "12")
local EVERY = tonumber(os.getenv("U3_EVERY") or "60")
local ENDF = tonumber(os.getenv("U3_END") or "7200")
local CURBACK = 0x01062260
local fh = io.open(LOG, "w")
local function log(f, ...) fh:write(string.format(f, ...) .. "\n"); fh:flush() end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local F = {}
for _, p in pairs(manager.machine.ioport.ports) do for n, f in pairs(p.fields) do F[n] = f end end
local function hold(n, on) if F[n] then F[n]:set_value(on and 1 or 0) end end
local frame = 0
emu.register_frame(function()
    frame = frame + 1
    for n in pairs(F) do if n:match("^P[12] ") or n:match("^Coin") or n:match("Start") then hold(n, false) end end
    -- boot screens want a game button; then credits and a 2-player start
    if frame < 1200 then hold("P1 High Punch", frame % 120 < 4) end
    if frame >= 1200 and frame < 1500 then hold("Coin 1", frame % 40 < 4); hold("Coin 2", (frame + 20) % 40 < 4) end
    if frame >= 1500 and frame < 1700 then hold("1 Player Start", frame % 60 < 4); hold("2 Players Start", (frame + 30) % 60 < 4) end
    if frame >= 1700 and frame < 2600 then
        hold("P1 High Punch", frame % 90 < 4); hold("P2 High Punch", (frame + 45) % 90 < 4)
    end
    if frame >= 1000 and frame < (tonumber(os.getenv("U3_POKE_END") or "3600")) then space:write_u16(CURBACK, STAGE) end
    -- in the fight: left end, then right end
    if frame >= (tonumber(os.getenv("U3_L0") or "3400")) and frame < (tonumber(os.getenv("U3_R0") or "4000")) then hold("P1 Left", true); hold("P2 Left", true) end
    if frame >= (tonumber(os.getenv("U3_R0") or "4000")) and frame < (tonumber(os.getenv("U3_R1") or "5600")) then hold("P1 Right", true); hold("P2 Right", true) end
    if frame >= 2400 and frame % EVERY == 0 then
        manager.machine.video:snapshot()
        -- MK3 RAM order: scrollx8..1, scrollx, worldtlx8..1, worldtlx (32-bit,
        -- 16.16), scrollx1 = 0105D990h (doc/UMK3_SCORPIONS_LAIR.md)
        local t = {}
        for k = 0, 8 do
            local a = 0x0105D9D0 + k * 0x20
            local v = space:read_u16(a + 16); if v >= 0x8000 then v = v - 0x10000 end
            t[#t + 1] = string.format("%s:%d", k < 8 and tostring(8 - k) or "w", v)
        end
        log("snap frame %d stage %d worldtlx %s", frame, space:read_u16(CURBACK), table.concat(t, " "))
    end
    if frame >= ENDF then log("done"); fh:close(); manager.machine:exit() end
end)
