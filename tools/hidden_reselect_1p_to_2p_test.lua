-- Regression: finish a 1P match, join P2 on the rematch select, then use
-- Sub-Zero + Block x5.  The rematch exit must apply P2's pending Noob pick.
local ROOT="C:/Users/you/Workplace/mk2-main"
local out=assert(io.open(ROOT.."/tools/hidden_reselect_1p_to_2p_test.log","w"))
local function log(f,...) local s="[hidden-reselect] "..string.format(f,...); print(s); out:write(s,"\n"); out:flush() end
local syms={}; local m=assert(io.open(ROOT.."/src/mk2.map","r"))
for l in m:lines() do for a,n in l:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n]=tonumber(a,16) end end
m:close(); local function s(n) assert(syms[n],n); return syms[n] end
local A={gstate=s("gstate"),p1_char=s("p1_char"),p2_char=s("p2_char"),p2_state=s("p2_state"),
 p1_bar=s("p1_bar"),p2_bar=s("p2_bar"),p1_view=s("p1_bar_view"),p2_view=s("p2_bar_view"),
 p1_obj=s("p1_obj"),p2_obj=s("p2_obj"),p1_proc=s("p1_proc"),p2_proc=s("p2_proc"),
 count=s("c_noob_cheat2"),flag=s("f_noob_cheat2"),held=s("f_noob_blk_held2")}
local GS_PSEL,GS_POST,GS_FIGHT=4,0x0d,2
local FT_LK,FT_REPTILE,FT_SZ,FT_NOOB,MAXHP=1,9,8,15,0xa1
local frame,space,lastgs=0,nil,-1; local fields={}; local done=false
local selects,psel_frame,confirm1,post_frame,fights,fight_frame=0,0,0,0,0,0
local pulse0=0; local lastcount=-1
local applied=false; local hp0=nil; local hplow=nil
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local function setx(a,x) local o=r32(a); if o~=0 then w16(o+0x90,x) end end
local function finish(ok,why) if done then return end; done=true; log("%s %s selects=%d fights=%d p2=%d count=%d flag=%d state=%d",ok and "PASS" or "ERROR",why,selects,fights,r16(A.p2_char),r16(A.count),r16(A.flag),r16(A.p2_state)); out:close(); manager.machine:exit() end
local function cache()
 local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
  ["P1 High Punch"]=1,["P1 Low Kick"]=1,["P2 Block"]=1,["P2 High Punch"]=1}
 for _,p in pairs(manager.machine.ioport.ports) do for _,f in pairs(p.fields) do if want[f.name] then fields[f.name]=f end end end
 for n in pairs(want) do log("input %-18s %s",n,fields[n] and "ok" or "MISSING") end
end
local function pressed(n)
 if n=="Coin 1" then return selects==0 and frame>=700 and frame<980 and frame%80<20 end
 if n=="1 Player Start" then return selects==0 and frame>=1000 and frame<1080 end
 if selects==1 then
  if n=="P1 High Punch" then return confirm1>0 and frame>=confirm1 and frame<confirm1+40 end
  if n=="P1 Low Kick" then return post_frame>0 and frame>=post_frame+250 and frame<post_frame+310 end
 elseif selects==2 then
  local r=frame-psel_frame
  if n=="Coin 2" then return false end -- free play: avoid Start+Coin auto-confirm
  if n=="2 Players Start" then return r>=5 and r<12 end
  if n=="P1 High Punch" then return r>=140 and r<170 end
  if n=="P2 Block" and pulse0>0 then local p=frame-pulse0; return p>=0 and p<50 and (p%10)<5 end
 end
 if fights==3 and n=="P2 High Punch" then local r=frame-fight_frame; return r>=70 and r<82 end
 return false
end
emu.register_frame(function()
 frame=frame+1
 if frame==1 then space=manager.machine.devices[":maincpu"].spaces["program"]; cache(); log("loaded") end
 if not space or done then return end
 local gs=r16(A.gstate)
 if gs~=lastgs then
  log("gstate %d->%d frame=%d p1=%d p2=%d p2state=%d",lastgs,gs,frame,r16(A.p1_char),r16(A.p2_char),r16(A.p2_state)); lastgs=gs
  if gs==GS_PSEL then
   selects=selects+1; psel_frame=frame; post_frame=0
   log("select #%d",selects)
  elseif gs==GS_POST then post_frame=frame
  elseif gs==GS_FIGHT then
   fights=fights+1; fight_frame=frame; log("fight #%d",fights)
   if fights==3 then hp0=r16(A.p1_bar); hplow=hp0 end
  end
 end
 if gs==GS_PSEL then
  if selects==1 then
   w16(A.p1_char,FT_LK); w16(A.p2_char,FT_REPTILE)
   if confirm1==0 and frame-psel_frame>90 then confirm1=frame end
  elseif selects==2 then
   if frame-psel_frame>30 then w16(A.p1_char,FT_LK); w16(A.p2_char,FT_SZ) end
   if pulse0==0 and frame-psel_frame==70 then pulse0=frame; log("P2 Sub-Zero Block x5 begins") end
   local c=r16(A.count); if c~=lastcount then log("count=%d flag=%d held=%d",c,r16(A.flag),r16(A.held)); lastcount=c end
  end
 elseif gs==GS_FIGHT and selects==1 and frame-fight_frame>120 then
  -- Force P1 to win both rounds normally so MAIN reaches play9.
  w16(A.p1_bar,MAXHP); w16(A.p1_view,MAXHP); w16(A.p2_bar,0); w16(A.p2_view,0)
 end
 if gs==GS_FIGHT and fights==3 then
  local r=frame-fight_frame
  if r==45 then setx(A.p1_obj,560); setx(A.p2_obj,610) end
  hplow=math.min(hplow,r16(A.p1_bar))
  if hplow<hp0 then finish(true,"P2 Noob standing HP damaged P1 after 1P-to-2P rematch"); return end
  if r>190 then finish(false,"P2 Noob standing HP had no collision after 1P-to-2P rematch"); return end
 end
 if selects==2 and gs~=GS_PSEL and pulse0>0 then
  if r16(A.p2_char)==FT_NOOB and not applied then applied=true; log("P2 Noob applied; continuing into match for collision test") end
  if frame-pulse0>500 and not applied then finish(false,"pending Noob override was not applied"); return end
 end
 for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
 if frame>12000 then finish(false,"timeout") end
end)
