-- Regression: a hidden fighter must retain working strike collision after a
-- complete match, rematch character select, and setup of the next match.
local ROOT="C:/Users/you/Workplace/mk2-main"
local WHICH=(os.getenv("SECRET") or "jade"):lower()
local NEXT_NORMAL=(os.getenv("NEXT_NORMAL") or "0")=="1"
local ATTACK=(os.getenv("ATTACK") or "hp"):lower()
local tag=WHICH..(NEXT_NORMAL and "_to_normal_"..ATTACK or "")
local out=assert(io.open(ROOT.."/tools/secret_rematch_hitbox_test_"..tag..".log","w"))
local function log(f,...) local s="[secret-rematch-hitbox:"..tag.."] "..string.format(f,...); print(s); out:write(s,"\n"); out:flush() end
local syms={}; local m=assert(io.open(ROOT.."/src/mk2.map","r"))
for l in m:lines() do for a,n in l:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n]=tonumber(a,16) end end
m:close(); local function s(n) assert(syms[n],n); return syms[n] end
local A={gstate=s("gstate"),p1_char=s("p1_char"),p2_char=s("p2_char"),p1_state=s("p1_state"),p2_state=s("p2_state"),
 p1_obj=s("p1_obj"),p2_obj=s("p2_obj"),p1_proc=s("p1_proc"),p2_proc=s("p2_proc"),
 p1_bar=s("p1_bar"),p2_bar=s("p2_bar"),p1_view=s("p1_bar_view"),p2_view=s("p2_bar_view")}
local GS_PSEL,GS_POST,GS_FIGHT=4,0x0d,2
local choices={jade={base=5,secret=16},smoke={base=10,secret=14},noob={base=8,secret=15}}
local choice=assert(choices[WHICH],"SECRET must be jade, smoke, or noob")
local FT_REPTILE,PS_ACTIVE,MAXHP=9,1,0xa1
local P_ACTION,P_STK,OCHAR,OXPOS=0x1f0,0x350,0x1f0,0x90
local cheat_counter,cheat_flag=s("c_"..WHICH.."_cheat1"),s("f_"..WHICH.."_cheat1")
local frame,space,lastgs=0,nil,-1; local fields={}; local done=false
local selects,psel_frame,pulse_start,fights,fight_frame=0,0,0,0,0
local hp0,hplow=nil,nil
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local function procfield(addr,off) local p=r32(addr); return p~=0 and r16(p+off) or 0xffff end
local function objfield(addr,off) local o=r32(addr); return o~=0 and r16(o+off) or 0xffff end
local function setx(addr,x) local o=r32(addr); if o~=0 then w16(o+OXPOS,x) end end
local function finish(ok,why)
 if done then return end; done=true
 log("%s %s selects=%d fights=%d chars=%d/%d ochar=%d/%d hp=%d->%d action=%04x stk=%04x",ok and "PASS" or "ERROR",why,
  selects,fights,r16(A.p1_char),r16(A.p2_char),objfield(A.p1_obj,OCHAR),objfield(A.p2_obj,OCHAR),hp0 or -1,hplow or -1,
  procfield(A.p1_proc,P_ACTION),procfield(A.p1_proc,P_STK))
 out:close(); manager.machine:exit()
end
local function cache()
 local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
  ["P1 High Punch"]=1,["P1 High Kick"]=1,["P1 Down"]=1,
  ["P1 Low Kick"]=1,["P1 Block"]=1,["P2 High Punch"]=1}
 for _,p in pairs(manager.machine.ioport.ports) do for _,f in pairs(p.fields) do if want[f.name] then fields[f.name]=f end end end
end
local function pressed(n)
 if n=="Coin 1" or n=="Coin 2" then return selects==0 and frame>=700 and frame<980 and frame%80<20 end
 if n=="1 Player Start" then return selects==0 and frame>=1000 and frame<1080 end
 if n=="2 Players Start" then
  if selects==0 then return frame>=1040 and frame<1140 end
  if frame-psel_frame>=5 and frame-psel_frame<45 then return true end
 end
 if selects>0 and r16(A.gstate)==GS_PSEL and pulse_start>0 then
  local p=frame-pulse_start
  if not NEXT_NORMAL or selects==1 then
   local cheat_button=(WHICH=="jade") and "P1 Low Kick" or "P1 Block"
   if n==cheat_button then return p>=0 and p<50 and (p%10)<5 end
  end
  if n=="P2 High Punch" then return p>=70 and p<110 end
  if NEXT_NORMAL and selects==2 and n=="P1 High Punch" then return p>=70 and p<110 end
 end
 if fights==3 and r16(A.gstate)==GS_FIGHT then
  local r=frame-fight_frame
  if ATTACK=="hp" and n=="P1 High Punch" then return r>=70 and r<80 end
  if ATTACK=="hk" and n=="P1 High Kick" then return r>=70 and r<80 end
  if ATTACK=="uppercut" then
   if n=="P1 Down" then return r>=55 and r<90 end
   if n=="P1 High Punch" then return r>=70 and r<80 end
  end
 end
 return false
end
emu.register_frame(function()
 frame=frame+1
 if frame==1 then space=manager.machine.devices[":maincpu"].spaces["program"]; cache(); log("loaded") end
 if done then return end
 local gs=r16(A.gstate)
 if gs~=lastgs then
  log("gstate %d->%d frame=%d chars=%d/%d",lastgs,gs,frame,r16(A.p1_char),r16(A.p2_char)); lastgs=gs
  if gs==GS_PSEL then
   selects=selects+1; psel_frame=frame; pulse_start=frame+60; log("select #%d route pulses begin=%d",selects,pulse_start)
  elseif gs==GS_FIGHT then
   fights=fights+1; fight_frame=frame
   log("fight #%d chars=%d/%d ochar=%d/%d proc=%08x/%08x",fights,r16(A.p1_char),r16(A.p2_char),objfield(A.p1_obj,OCHAR),objfield(A.p2_obj,OCHAR),r32(A.p1_proc),r32(A.p2_proc))
   if fights==3 then hp0=r16(A.p2_bar); hplow=hp0 end
  end
 end
 if gs==GS_PSEL and selects<=2 then
  w16(A.p1_state,PS_ACTIVE); w16(A.p2_state,PS_ACTIVE)
  if NEXT_NORMAL and selects==2 then
   w16(A.p1_char,1); w16(A.p2_char,2) -- Liu Kang vs Johnny Cage
  else
   w16(A.p1_char,choice.base); w16(A.p2_char,FT_REPTILE)
  end
 elseif gs==GS_FIGHT then
  local r=frame-fight_frame
  if fights<=2 and r>120 then
   w16(A.p1_bar,MAXHP); w16(A.p1_view,MAXHP); w16(A.p2_bar,0); w16(A.p2_view,0)
  elseif fights==3 then
   if r==45 then setx(A.p1_obj,560); setx(A.p2_obj,610) end
   hplow=math.min(hplow,r16(A.p2_bar))
   if hplow<hp0 then finish(true,ATTACK.." damaged opponent in second match"); return end
   if r>180 then finish(false,ATTACK.." had no collision in second match"); return end
  end
 end
 if selects<=2 and pulse_start>0 and frame==pulse_start+52 then
  log("route result select=%d counter=%d flag=%d char=%d",selects,r16(cheat_counter),r16(cheat_flag),r16(A.p1_char))
 end
 for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
 if frame>10000 then finish(false,"timeout") end
end)
