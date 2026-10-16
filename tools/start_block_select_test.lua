-- Regression: Start+Block on Sub-Zero must select immediately with palette 3;
-- plain Block remains reserved for the five-press Noob route.
local ROOT="C:/Users/you/Workplace/mk2-main"
local out=assert(io.open(ROOT.."/tools/start_block_select_test.log","w"))
local function log(f,...) local s="[start-block] "..string.format(f,...); print(s); out:write(s,"\n"); out:flush() end
local syms={}; local m=assert(io.open(ROOT.."/src/mk2.map","r"))
for l in m:lines() do for a,n in l:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n]=tonumber(a,16) end end
m:close(); local function s(n) assert(syms[n],n); return syms[n] end
local A={gstate=s("gstate"),p1_char=s("p1_char"),p1_obj=s("p1_obj"),alt=s("alt_pal_owner")}
local GS_PSEL,GS_FIGHT,FT_SZ=4,2,8
local frame,space,psel,choose=0,nil,0,0; local fields={}; local done=false
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local function finish(ok,why) if done then return end; done=true; log("%s %s",ok and "PASS" or "ERROR",why); out:close(); manager.machine:exit() end
local function cache()
  local want={["Coin 1"]=1,["1 Player Start"]=1,["P1 Block"]=1,["P1 Low Kick"]=1}
  for _,p in pairs(manager.machine.ioport.ports) do for _,f in pairs(p.fields) do if want[f.name] then fields[f.name]=f end end end
  for n in pairs(want) do log("input %-16s %s",n,fields[n] and "ok" or "MISSING") end
end
local function pressed(n)
  if n=="Coin 1" then return psel==0 and frame>=700 and frame<980 and frame%80<20 end
  if n=="1 Player Start" then
    return (psel==0 and frame>=1000 and frame<1080) or (choose>0 and frame>=choose and frame<choose+12)
  end
  if n=="P1 Block" then return choose>0 and frame>=choose and frame<choose+12 end
  if n=="P1 Low Kick" then return psel>0 and r16(A.gstate)~=GS_PSEL and frame%80<20 end
  return false
end
emu.register_frame(function()
  frame=frame+1
  if frame==1 then space=manager.machine.devices[":maincpu"].spaces["program"]; cache() end
  if not space or done then return end
  local gs=r16(A.gstate)
  if gs==GS_PSEL then
    if psel==0 then psel=frame; log("select frame=%d",frame) end
    w16(A.p1_char,FT_SZ)
    if choose==0 and frame-psel>90 then choose=frame; log("pressing Start+Block once") end
  elseif psel>0 and choose>0 and gs~=GS_PSEL then
    log("left select after %d frames char=%d owner=%04x",frame-choose,r16(A.p1_char),r16(A.alt))
    if r16(A.p1_char)~=FT_SZ then finish(false,"wrong character")
    elseif (r16(A.alt)&1)==0 then finish(false,"start-block palette owner missing")
    elseif gs==GS_FIGHT then
      local o=r32(A.p1_obj)
      if o~=0 then
        local flags=r16(o+0x160); log("fight flags2=%04x",flags)
        finish((flags&0x80)~=0,(flags&0x80)~=0 and "Sub-Zero selected with start palette" or "start palette flag missing")
      end
    end
  end
  for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
  if frame>5000 then finish(false,"timeout") end
end)
