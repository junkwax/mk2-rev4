-- ladder_glitch_probe.lua
--
-- SYMBOL-FREE: drives inputs on a fixed frame schedule and snapshots on a
-- fixed schedule, so the same script runs on ANY build - including an old
-- zip whose addresses no longer match src/mk2.map (a rig that reads the
-- current map against an old ROM reads garbage).  Used to A/B the battle-
-- plan (ladder) screen and the round intro between two builds.
--
--   LGP_TAG    prefix for the snapshot names (e.g. "new" / "old")
--   LGP_END    frame to stop at (default 3400)

local TAG = os.getenv("LGP_TAG") or "run"
local END = tonumber(os.getenv("LGP_END") or "3400")
local frame, fields = 0, {}

local function shot(n)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot(string.format("%s_%05d.png", TAG, n)) end) end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    -- confirm whoever is under the cursor, a few times so one lands
    if name == "P1 High Punch" then
        return (frame >= 1500 and frame < 1510) or (frame >= 1600 and frame < 1610)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        local want = { ["UI Select"] = 1, ["Coin 1"] = 1, ["1 Player Start"] = 1, ["P1 High Punch"] = 1 }
        for _, p in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame >= 1400 and frame % 25 == 0 then shot(frame) end
    if frame >= END then manager.machine:exit() end
end)
