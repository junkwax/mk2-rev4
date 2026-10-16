local done = false
emu.register_frame_done(function()
    if done then return end
    done = true
    local s = manager.machine.screens[":screen"]
    local f = io.open("C:/Users/you/Workplace/mk2-main/tmp/refresh.txt", "w")
    local ok, hz = pcall(function() return s.refresh_attoseconds end)
    local ok2, r = pcall(function() return s.refresh end)
    f:write(string.format("refresh_attoseconds=%s\nrefresh=%s\n",
            tostring(ok and hz or "?"), tostring(ok2 and r or "?")))
    if ok and hz and hz > 0 then
        f:write(string.format("Hz=%.4f\ntick_ms=%.3f\n", 1e18/hz, hz/1e15))
    end
    f:close()
    manager.machine:exit()
end)
