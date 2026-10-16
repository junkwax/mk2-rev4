-- Runtime regression for ambient effects omitted by alternate character paths.
-- MODE=smoke: Scorpion + Block x5 selects playable Smoke and must emit puffs.
-- MODE=morph: Shang performs D,B,F+LK into Raiden, must emit lightning, and
--             must remove that owner's lightning process after morph-back.
local ROOT="C:/Users/you/Workplace/mk2-main"
local MODE=(os.getenv("MODE") or "smoke"):lower()
assert(MODE=="smoke" or MODE=="morph","MODE must be smoke or morph")
local out=assert(io.open(ROOT.."/tools/playable_ambient_effects_test_"..MODE..".log","w"))
local function log(f,...) local s="[ambient:"..MODE.."] "..string.format(f,...); print(s); out:write(s,"\n"); out:flush() end

local syms={}; local map=assert(io.open(ROOT.."/src/mk2.map","r"))
for line in map:lines() do
 for addr,name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[name]=tonumber(addr,16) end
end
map:close(); local function sym(n) assert(syms[n],n); return syms[n] end

local A={active=sym("active"),objlst=sym("objlst"),gstate=sym("gstate"),
 p1_char=sym("p1_char"),p2_char=sym("p2_char"),p1_state=sym("p1_state"),p2_state=sym("p2_state"),
 p1_obj=sym("p1_obj"),p2_obj=sym("p2_obj"),p1_proc=sym("p1_proc")}
local GS_PSEL,GS_FIGHT,PS_ACTIVE=4,2,1
local FT_ST,FT_RAIDEN,FT_REPTILE,FT_SCORPION,FT_SMOKE=6,7,9,10,14
local PID_LIGHTNING,PID_SMOKER,PID_PUFF=8,0x18,0x19
local P_NEXT,P_ID,P_SLAVE=0,0x20,0x190
local O_NEXT,O_XPOS,O_ZVAL,O_ID,O_CHAR=0,0x90,0xc0,0x1c0,0x1f0
local OID_PUFF=0x19
local frame,space,lastgs=0,nil,-1; local fields={}; local done=false
local psel_frame,pulse_start,fight_frame=0,0,0
local saw_form,snapped=false,false; local snap_at=0; local max_effect,max_aux=0,0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local function count_pid(id)
 local p=r32(A.active); local n,g=0,0
 while p~=0 and g<256 do if r16(p+P_ID)==id then n=n+1 end; p=r32(p+P_NEXT); g=g+1 end
 return n
end
local function count_objects(off,value)
 local p=r32(A.objlst); local n,g=0,0
 while p~=0 and g<256 do if r16(p+off)==value then n=n+1 end; p=r32(p+O_NEXT); g=g+1 end
 return n
end
local function count_bolts()
 local p=r32(A.active); local n,g=0,0
 while p~=0 and g<256 do
  if r16(p+P_ID)==PID_LIGHTNING and r32(p+P_SLAVE)~=0 then n=n+1 end
  p=r32(p+P_NEXT); g=g+1
 end
 return n
end
local function objchar(addr) local o=r32(addr); return o~=0 and r16(o+O_CHAR) or 0xffff end
local function setx(addr,x) local o=r32(addr); if o~=0 then w16(o+O_XPOS,x) end end
local function snap()
 if snapped then return end
 local screen=manager.machine.screens[":screen"]
 if screen then screen:snapshot(); snapped=true; log("snapshot frame=%d",frame) end
end
local function finish(ok,why)
 if done then return end; done=true
 log("%s %s char=%d ochar=%d pids(light/smoke/puff)=%d/%d/%d max_effect=%d max_aux=%d",
  ok and "PASS" or "ERROR",why,r16(A.p1_char),objchar(A.p1_obj),
  count_pid(PID_LIGHTNING),count_pid(PID_SMOKER),count_pid(PID_PUFF),max_effect,max_aux)
 out:close(); manager.machine:exit()
end
local function cache()
 local wanted={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
  ["P1 High Punch"]=1,["P2 High Punch"]=1,["P1 Block"]=1,["P1 Low Kick"]=1,
  ["P1 Down"]=1,["P1 Left"]=1,["P1 Right"]=1}
 for _,port in pairs(manager.machine.ioport.ports) do
  for _,field in pairs(port.fields) do if wanted[field.name] then fields[field.name]=field end end
 end
end
local function pressed(name)
 if name=="Coin 1" or name=="Coin 2" then return psel_frame==0 and frame>=700 and frame<980 and frame%80<20 end
 if name=="1 Player Start" then return psel_frame==0 and frame>=1000 and frame<1080 end
 if name=="2 Players Start" then return psel_frame==0 and frame>=1040 and frame<1140 end
 if psel_frame>0 and r16(A.gstate)==GS_PSEL then
  local r=frame-pulse_start
  if MODE=="smoke" and name=="P1 Block" then return r>=0 and r<50 and r%10<5 end
  if MODE=="morph" and name=="P1 High Punch" then return r>=70 and r<110 end
  if name=="P2 High Punch" then return r>=70 and r<110 end
 end
 if MODE=="morph" and fight_frame>0 and r16(A.gstate)==GS_FIGHT then
  local r=frame-fight_frame
  if name=="P1 Down" then return r>=80 and r<85 end
  if name=="P1 Left" then return r>=94 and r<99 end
  if name=="P1 Right" then return r>=108 and r<113 end
  if name=="P1 Low Kick" then return r>=120 and r<128 end
 end
 return false
end

emu.register_frame(function()
 frame=frame+1
 if frame==1 then space=manager.machine.devices[":maincpu"].spaces["program"]; cache(); log("loaded") end
 if done then return end
 if snap_at>0 and frame>=snap_at then snap(); snap_at=0 end
 local gs=r16(A.gstate)
 if gs~=lastgs then
  log("gstate %d->%d frame=%d char=%d ochar=%d",lastgs,gs,frame,r16(A.p1_char),objchar(A.p1_obj)); lastgs=gs
  if gs==GS_PSEL and psel_frame==0 then psel_frame=frame; pulse_start=frame+60 end
  if gs==GS_FIGHT and fight_frame==0 then fight_frame=frame; log("fight started") end
 end
 if gs==GS_PSEL then
  w16(A.p1_state,PS_ACTIVE); w16(A.p2_state,PS_ACTIVE)
  w16(A.p1_char,MODE=="smoke" and FT_SCORPION or FT_ST); w16(A.p2_char,FT_REPTILE)
 elseif gs==GS_FIGHT and fight_frame>0 then
  local r=frame-fight_frame
  if r==45 then setx(A.p1_obj,520); setx(A.p2_obj,760) end
  if MODE=="smoke" then
   local emit=count_pid(PID_SMOKER); local puffs=math.max(count_pid(PID_PUFF),count_objects(O_ID,OID_PUFF))
   max_effect=math.max(max_effect,emit); max_aux=math.max(max_aux,puffs)
   if r>30 and objchar(A.p1_obj)==FT_SMOKE and emit==1 and puffs>0 then snap(); finish(true,"playable Smoke owns one emitter and live clouds"); return end
   if r>300 then finish(false,"playable Smoke clouds not observed"); return end
  else
   local oc=objchar(A.p1_obj); local emit=count_pid(PID_LIGHTNING); local bolts=count_bolts()
   max_effect=math.max(max_effect,emit); max_aux=math.max(max_aux,bolts)
   if oc==FT_RAIDEN then saw_form=true end
   if bolts>0 and not snapped and snap_at==0 then snap_at=frame+1 end
   if saw_form and oc==FT_ST and emit==0 and max_aux>0 then finish(true,"morphed Raiden lightning appeared and cleaned up on morph-back"); return end
   if r>900 then finish(false,"Raiden morph lightning or cleanup not observed"); return end
  end
 end
 for name,field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
 if frame>12000 then finish(false,"global timeout") end
end)
