local fh = io.open("C:/Users/you/Workplace/mk2-main/tools/_hello_probe.log","w")
fh:write("lua started\n"); fh:flush()
local n = 0
emu.register_frame(function()
  n = n + 1
  if n % 60 == 0 then fh:write("frame "..n.."\n"); fh:flush() end
  if n > 600 then fh:close(); manager.machine:exit() end
end)
