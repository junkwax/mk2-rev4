local frame = 0
emu.register_frame(function()
    frame = frame + 1
    if frame == 240 then
        local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
        if not ok or not s then ok, s = pcall(function() return manager.machine.screens:at(1) end) end
        if s then pcall(function() s:snapshot() end) end
    end
end)
