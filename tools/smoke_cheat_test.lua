-- smoke_cheat_test.lua
-- Verify the Smoke secret: cursor on Scorpion (ft_scorpion=10), press Block 5x,
-- the 5th confirms and (after select) that player's char becomes ft_smoke=14.
-- Env: SMOKE_PLAYER (1 or 2). P1 tested in a 1P game, P2 in a 2P game.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local P = tonumber(os.getenv("SMOKE_PLAYER") or "1")
local OTHER = (P==1) and 2 or 1
local TWO_P = (P==2)
local LOG = os.getenv("SMOKE_LOG") or (ROOT .. "/tools/smoke_cheat_test.log")
local logfh=io.open(LOG,"w")
local frame=0
local raw=print
print=function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[smoke] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end
local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) return symbols[n] end
local A={ gstate=sym("gstate"), my_char=sym("p"..P.."_char"),
  c=sym("c_smoke_cheat"..P), f=sym("f_smoke_cheat"..P), held=sym("f_smoke_blk_held"..P) }
local BLK="P"..P.." Block"; local LP="P"..P.." Low Punch"; local OLP="P"..OTHER.." Low Punch"
local GS_PSEL=4; local FT_SCORP,FT_SMOKE=10,14
-- SMOKE_HOVER: which char to hover. 10=Scorpion runs the cheat (expect Smoke).
-- Any other char = REGRESSION check: press Block ONCE, expect it to confirm
-- that char normally (Block must still work as confirm off-Scorpion).
local HOVER=tonumber(os.getenv("SMOKE_HOVER") or "10")
local CHEAT=(HOVER==FT_SCORP)
local NPRESS=CHEAT and 5 or 1
local space,fields=nil,{}
local psel=0; local left=0; local p0=0; local phase="boot"; local lc=-1; local lmc=-1; local done=false
local function r16(a) return space:read_u16(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local held={}
local function hold(n,on) held[n]=on and true or false end
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,["UI Select"]=1,
    [BLK]=1,[LP]=1,[OLP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-18s %s",n,fields[n] and "ok" or "MISSING") end
end
emu.register_frame(function()
  frame=frame+1
  if frame==1 then local cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]; cache()
    log("TEST P%d (2P=%s) c=0x%08x f=0x%08x p%d_char=0x%08x",P,tostring(TWO_P),A.c or 0,A.f or 0,P,A.my_char or 0) end
  if not space then return end
  local gs=r16(A.gstate)
  if gs==GS_PSEL and psel==0 then psel=frame; log("select reached frame=%d",frame) end
  if psel==0 then
    hold("Coin 1", frame>=200 and frame<3000 and (frame%80)<20)
    if TWO_P then
      hold("Coin 2", frame>=240 and frame<3000 and (frame%80)>=20 and (frame%80)<40)
      hold("2 Players Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    else
      hold("1 Player Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    end
    hold("UI Select", frame>=5 and frame<35)
  else
    local rel=frame-psel
    if rel==60 then p0=frame; phase="pulsing"; log("pulsing %s %dx (hover char %d, cheat=%s)",BLK,NPRESS,HOVER,tostring(CHEAT)) end
    if phase=="pulsing" then
      w16(A.my_char,HOVER)            -- hover the target char
      local p=frame-p0; local idx=p//10
      if idx<NPRESS then hold(BLK,(p%10)<5)
      else hold(BLK,false)
        if phase~="post" then phase="post"; log("pulses done c=%d f=%d held=%d",r16(A.c),r16(A.f),r16(A.held)) end
      end
      local c=r16(A.c); if c~=lc then log("  c_smoke_cheat%d=%d (frame=%d)",P,c,frame); lc=c end
    end
    -- CHEAT mode: LP fallback confirm. REGRESSION mode: no fallback - Block
    -- itself must confirm off-Scorpion, else we can't tell it's broken.
    if CHEAT and phase=="post" and (frame-p0)>70 then
      hold(LP,(frame%20)<8); if TWO_P then hold(OLP,(frame%20)<8) end
    end
  end
  if psel>0 and phase=="post" and gs~=GS_PSEL then
    if left==0 then left=frame; log("left select frame=%d gs=%d; polling...",frame,gs) end
    local mc=r16(A.my_char); local f=r16(A.f)
    if mc~=lmc then log("  poll rel=%d p%d_char=%d f=%d gs=%d",frame-left,P,mc,f,gs); lmc=mc end
    if CHEAT then
      if mc==FT_SMOKE and not done then done=true; log("PASS smoke_p%d: player %d became Smoke at rel=%d",P,P,frame-left); log("finished"); manager.machine:exit()
      elseif frame-left>200 and not done then done=true; log("FAIL smoke_p%d: p%d_char stayed %d f=%d",P,P,mc,f); log("finished"); manager.machine:exit() end
    else
      -- REGRESSION: single Block on a non-Scorpion char must confirm normally,
      -- NOT trigger the cheat. Confirmed (left psel) + never Smoke = PASS.
      if mc==FT_SMOKE and not done then done=true; log("FAIL regress_p%d: Block wrongly triggered Smoke off-Scorpion (hover=%d)",P,HOVER); log("finished"); manager.machine:exit()
      elseif frame-left>90 and not done then done=true; log("PASS regress_p%d: Block confirmed char %d normally (c=%d, no cheat)",P,mc,r16(A.c)); log("finished"); manager.machine:exit() end
    end
  end
  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame>6000 then log("FAIL timeout phase=%s psel=%d c=%d",phase,psel,r16(A.c)); log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
