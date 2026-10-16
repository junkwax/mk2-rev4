-- raiden_dive_snd_probe.lua - which voice Raiden's torpedo actually sends.
--
-- Rides tools/battle_stability_sweep.lua (it boots, selects, and runs a real
-- fight against the drone) and taps the sound latch on top, printing every
-- code the ROM sends with the frame it went out on.
--
-- Put Raiden on the DRONE side (SWEEP_P2=7) and let it fight: the torpedo is
-- one of its openers, so the yell goes out on its own.  bike_ghost_test.lua
-- has a scripted BG_MOVE=dive, but it is dead on this build - it reads gh_src,
-- and the ghost trails were removed from the ROM.
--
-- Why: do_raiden_dive picks at random between two yells.  The codes are
-- authored in triple_sndtab (MKSOUND.ASM) and the pool is in MOVES.ASM, so
-- "the table says $02AE" is not evidence that the move plays $02AE - only a
-- latch trace of the running game is.  Same tap the Kahn rig's KAHN_SNDTRACE
-- uses (SND_PORT, MKSOUND's command port).
--
-- Run it exactly as battle_stability_sweep.lua:
--   SWEEP_P1=1 SWEEP_P2=7 ... -autoboot_script tools/raiden_dive_snd_probe.lua
--
-- env: RDS_WATCH (comma-separated hex codes to call out, default 2ae,2b4),
--      everything battle_stability_sweep.lua takes.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")

dofile(ROOT .. "/tools/battle_stability_sweep.lua")

local SND_PORT = 0x01d01030
local SND_TAP_LO, SND_TAP_HI = 0x01d00000, 0x01d01fff

local watch = {}
for h in (os.getenv("RDS_WATCH") or "2ae,2b4"):gmatch("[^,]+") do
    watch[tonumber(h, 16)] = true
end

local snd_hi, seen, hits, frame, tap = nil, 0, {}, 0, nil

-- The latch is written as two bytes, high then low, each tagged 0xff00 - the
-- same decode the Kahn rig does; anything else resets the pair.
local function on_sound_write(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    local code = (snd_hi << 8) | (w & 0xff)
    snd_hi = nil
    seen = seen + 1
    if seen <= 400 then
        print(string.format("[rds] snd frame=%d SEND $%04x%s", frame, code,
            watch[code] and "   <-- dive voice" or ""))
    end
    if watch[code] then hits[code] = (hits[code] or 0) + 1 end
    return data
end

-- Installed on the first frame, not at load: at autoboot time the devices are
-- not up yet and install_write_tap throws.
emu.register_frame(function()
    frame = frame + 1
    if frame ~= 1 then return end
    local ok, err = pcall(function()
        local space = manager.machine.devices[":maincpu"].spaces["program"]
        tap = space:install_write_tap(SND_TAP_LO, SND_TAP_HI, "rds_snd", on_sound_write)
    end)
    print(string.format("[rds] sound latch tap %s",
        (ok and tap) and "installed" or ("FAILED: " .. tostring(err))))
end)

emu.register_stop(function()
    local parts = {}
    for code, n in pairs(hits) do parts[#parts + 1] = string.format("$%04x x%d", code, n) end
    table.sort(parts)
    print(string.format("[rds] watched codes sent: %s",
        #parts > 0 and table.concat(parts, ", ") or "NONE"))
end)
