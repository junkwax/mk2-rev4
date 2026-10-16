local n = 0
emu.register_frame_done(function()
    n = n + 1
    if n == 300 or n == 900 or n == 1800 then
        local s = manager.machine.screens[":screen"]
        if s then pcall(function() s:snapshot() end) end
    end
    if n > 1900 then manager.machine:exit() end
end)
