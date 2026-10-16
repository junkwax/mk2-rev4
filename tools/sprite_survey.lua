-- sprite_survey.lua
-- Inserts coins + start to keep fights going; takes a screenshot every 3 seconds.
-- Usage:
--   C:\MAME\mame.exe mk2 -script C:\Users\you\Workplace\mk2-main\tools\sprite_survey.lua

local frame = 0
local fields = {}
local snap_count = 0
local SNAP_INTERVAL = 180   -- every 3 seconds at 60 fps

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function cache_fields()
    local wanted = {
        ["Coin 1"]=true, ["1 Player Start"]=true, ["2 Player Start"]=true,
        ["2 Players Start"]=true, ["UI Select"]=true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

local function pressed(name)
    -- Dismiss MAME ROM warning only; let attract mode run on its own
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cache_fields()
        print("[survey] started — snapshot every " .. SNAP_INTERVAL .. " frames")
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    if frame % SNAP_INTERVAL == 0 then
        snap_count = snap_count + 1
        local screen = main_screen()
        local ok, err = pcall(function()
            if not screen then error("no screen") end
            screen:snapshot()
        end)
        print(string.format("[survey] snap %d frame=%d ok=%s", snap_count, frame, tostring(ok)))
    end
end)
