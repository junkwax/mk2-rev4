-- adj_toast_recheck.lua : boot only, read the two flags back out of the cmos
-- that the previous run left behind.  KOMBAT TOASTS was toggled to ON in the
-- service menu last run; if the write, the cmos and dipinit all work, f_kalout
-- comes up 1 here without anyone touching the menu again.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local logfh = io.open(ROOT.."/tmp/adjprobe/recheck.log","w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end

local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local A={gstate=symbols["gstate"],f_kalout=symbols["f_kalout"],f_kmbcnt=symbols["f_kmbcnt"]}

local space, frame = nil, 0
emu.register_frame_done(function()
  frame = frame + 1
  if frame==1 then space = manager.machine.devices[":maincpu"].spaces["program"] end
  if space and frame % 55 == 0 and frame <= 55*12 then
    print(string.format("[recheck] t=%2ds gstate=%d f_kalout=%d f_kmbcnt=%d",
      frame//55, space:read_u16(A.gstate), space:read_u16(A.f_kalout), space:read_u16(A.f_kmbcnt)))
  end
end)
print("[recheck] loaded")
