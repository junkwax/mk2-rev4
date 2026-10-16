-- Verify the Noob secret: hover Sub-Zero (8), press Block 5x, and confirm
-- that the selected player becomes Noob Saibot (15) after player select.
-- Env: NOOB_PLAYER=1 or 2. P1 uses a 1P game; P2 uses a 2P game.
local ROOT=(os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local P=tonumber(os.getenv("NOOB_PLAYER") or "1")
local OTHER=(P==1) and 2 or 1
local TWO_P=(P==2)
local LOG=os.getenv("NOOB_LOG") or (ROOT.."/tools/noob_cheat_test.log")
local logfh=io.open(LOG,"w")
local frame=0
local raw=print
print=function(...)
  local t={}; for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local line=table.concat(t,"\t"); raw(line)
  if logfh then logfh:write(line,"\n"); logfh:flush() end
end
local function log(f,...)
  print("[noob] "..(select("#",...)>0 and string.format(f,...) or tostring(f)))
end

local symbols={}
do
  local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then
    for line in fh:lines() do
      for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end
    end
    fh:close()
  end
end
local function sym(n) return symbols[n] end
local A={gstate=sym("gstate"),char=sym("p"..P.."_char"),
  count=sym("c_noob_cheat"..P),flag=sym("f_noob_cheat"..P),held=sym("f_noob_blk_held"..P)}
local BLOCK="P"..P.." Block"
local LP="P"..P.." Low Punch"
local OTHER_LP="P"..OTHER.." Low Punch"
local GS_PSEL,FT_SUBZERO,FT_NOOB=4,8,15
local space,fields=nil,{}
local psel,pulse0,left=0,0,0
local phase="boot"
local last_count,last_char=-1,-1
local done=false
local held={}
local function hold(n,on) held[n]=on and true or false end
local function r16(a) return space:read_u16(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end

local function cache_fields()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
    ["UI Select"]=1,[BLOCK]=1,[LP]=1,[OTHER_LP]=1}
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(port.fields) do if want[fld.name] then fields[fld.name]=fld end end
  end
  for n in pairs(want) do log("input %-18s %s",n,fields[n] and "ok" or "MISSING") end
end

emu.register_frame(function()
  frame=frame+1
  if frame==1 then
    local cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]
    cache_fields()
    log("TEST P%d (2P=%s) count=0x%08x flag=0x%08x char=0x%08x",
      P,tostring(TWO_P),A.count or 0,A.flag or 0,A.char or 0)
  end
  if not space then return end
  local gs=r16(A.gstate)
  if gs==GS_PSEL and psel==0 then psel=frame; log("select reached frame=%d",frame) end

  if psel==0 then
    hold("Coin 1",frame>=200 and frame<3000 and (frame%80)<20)
    if TWO_P then
      hold("Coin 2",frame>=240 and frame<3000 and (frame%80)>=20 and (frame%80)<40)
      hold("2 Players Start",frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    else
      hold("1 Player Start",frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    end
    hold("UI Select",frame>=5 and frame<35)
  else
    local rel=frame-psel
    if rel==60 then pulse0=frame; phase="pulsing"; log("pulsing %s 5x on Sub-Zero",BLOCK) end
    if phase=="pulsing" then
      w16(A.char,FT_SUBZERO)
      local p=frame-pulse0; local idx=p//10
      if idx<5 then hold(BLOCK,(p%10)<5)
      else
        hold(BLOCK,false)
        phase="post"
        log("pulses done count=%d flag=%d held=%d",r16(A.count),r16(A.flag),r16(A.held))
      end
      local c=r16(A.count)
      if c~=last_count then log("  count=%d frame=%d",c,frame); last_count=c end
    end
    if phase=="post" and frame-pulse0>70 then
      hold(LP,(frame%20)<8)
      if TWO_P then hold(OTHER_LP,(frame%20)<8) end
    end
  end

  if psel>0 and phase=="post" and gs~=GS_PSEL then
    if left==0 then left=frame; log("left select frame=%d gs=%d",frame,gs) end
    local ch=r16(A.char); local flag=r16(A.flag)
    if ch~=last_char then log("  poll rel=%d char=%d flag=%d gs=%d",frame-left,ch,flag,gs); last_char=ch end
    if ch==FT_NOOB and not done then
      done=true; log("PASS noob_p%d: player %d became Noob",P,P); log("finished"); manager.machine:exit()
    elseif frame-left>200 and not done then
      done=true; log("FAIL noob_p%d: char stayed %d flag=%d",P,ch,flag); log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame>6000 then log("FAIL timeout phase=%s",phase); log("finished"); manager.machine:exit() end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
