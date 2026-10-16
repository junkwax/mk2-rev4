-- jade_p1_1p_test.lua
-- Does P1 become Jade via the secret combo in a normal 1-PLAYER game?
-- Boots 1P, forces P1 to hover Mileena, pulses P1 Low Kick 5x (the 5th confirms),
-- then watches p1_char after select. P2 is the CPU (auto-picked).
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("JADE_P1_LOG") or (ROOT .. "/tools/jade_p1_1p_test.log")
local logfh = io.open(LOG,"w")
local frame=0
local raw=print
print=function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[jadep1] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) return symbols[n] end
local A={ gstate=sym("gstate"), p1_char=sym("p1_char"), c1=sym("c_jade_cheat1"),
  f1=sym("f_jade_cheat1"), held1=sym("f_jade_lk_held1") }
local GS_PSEL=4; local FT_FN2,FT_JADE=5,16
local space,fields=nil,{}
local psel=0; local left_psel=0; local pulse0=0; local phase="boot"
local lastc=-1; local lastmc=-1; local done=false
local function r16(a) return space:read_u16(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local held={}
local function hold(n,on) held[n]=on and true or false end
local function cache()
  local want={["Coin 1"]=1,["1 Player Start"]=1,["UI Select"]=1,["P1 Low Kick"]=1,["P1 Low Punch"]=1}
  for _,p in pairs(manager.machine.ioport.ports) do for _,f in pairs(p.fields) do if want[f.name] then fields[f.name]=f end end end
  for n in pairs(want) do log("input %-16s %s",n,fields[n] and "ok" or "MISSING") end
end
emu.register_frame(function()
  frame=frame+1
  if frame==1 then local cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]; cache()
    log("symbols c1=0x%08x f1=0x%08x p1_char=0x%08x",A.c1 or 0,A.f1 or 0,A.p1_char or 0) end
  if not space then return end
  local gs=r16(A.gstate)
  if gs==GS_PSEL and psel==0 then psel=frame; log("select reached frame=%d",frame) end

  if psel==0 then
    hold("Coin 1", frame>=200 and frame<3000 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  else
    local rel=frame-psel
    if rel==60 then pulse0=frame; phase="pulsing"; log("pulsing P1 Low Kick 5x (hover Mileena)") end
    if phase=="pulsing" then
      w16(A.p1_char,FT_FN2)              -- P1 hovers Mileena
      local p=frame-pulse0; local idx=p//10
      if idx<5 then hold("P1 Low Kick", (p%10)<5)
      else hold("P1 Low Kick",false)
        if phase~="post" then phase="post"; log("pulses done c1=%d f1=%d held1=%d",r16(A.c1),r16(A.f1),r16(A.held1)) end
      end
      local c=r16(A.c1); if c~=lastc then log("  c_jade_cheat1=%d (frame=%d)",c,frame); lastc=c end
    end
    -- after pulsing, if the select hasn't ended yet, nudge with Low Punch confirm
    if phase=="post" and (frame-pulse0)>70 then hold("P1 Low Punch", (frame%20)<8) end
  end

  if psel>0 and phase=="post" and gs~=GS_PSEL then
    if left_psel==0 then left_psel=frame; log("left select frame=%d gs=%d; polling p1_char...",frame,gs) end
    local mc=r16(A.p1_char); local f1=r16(A.f1)
    if mc~=lastmc then log("  poll rel=%d p1_char=%d f1=%d gs=%d",frame-left_psel,mc,f1,gs); lastmc=mc end
    if mc==FT_JADE and not done then done=true
      log("PASS p1_jade: P1 became Jade at rel=%d",frame-left_psel); log("finished"); manager.machine:exit()
    elseif frame-left_psel>200 and not done then done=true
      log("FAIL p1_jade: p1_char stayed %d f1=%d",mc,f1); log("finished"); manager.machine:exit() end
  end
  for n,f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
  if frame>6000 then log("FAIL timeout phase=%s psel=%d c1=%d",phase,psel,r16(A.c1)); log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
