-- Runtime proof for the ALLDUDES per-character electrocution table.
-- Drives Raiden vs Jax, forces a normal Raiden win, then verifies that
-- Raiden's victory-lightning loop alternates his object palette.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local logfh = assert(io.open(ROOT .. "/tools/electric_palette_test.log", "w"))
local function log(fmt, ...)
    local s = "[electric-pal] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end
local syms = {}
local mf = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
if mf then
    for line in mf:lines() do
        for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n]=tonumber(a,16) end
    end
    mf:close()
end
local function sym(n,d) return syms[n] or d end
local A={gstate=sym("gstate",0x0112a7d0),p1_char=sym("p1_char",0x0112a880),
 p2_char=sym("p2_char",0x0112b450),p1_obj=sym("p1_obj",0x0112a820),
 p1_bar=sym("p1_bar",0x0112a8f0),p2_bar=sym("p2_bar",0x0112b4c0),
 p1_bar_view=sym("p1_bar_view",0x011285f0),p2_bar_view=sym("p2_bar_view",0x01128530),
 winner=sym("winner_status",0x0112c110)}
local GS_PSEL,GS_POST,GS_FIGHT=4,0x0d,2
local FT_RAIDEN,FT_JAX,OPAL,MAX_HP=7,11,0x140,0xa1
local frame,space,psel,confirm,post,fight,won=0,nil,0,0,0,0,0
local fields,pals,finished={}, {}, false
local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a,v) if space then space:write_u16(a,v&0xffff) end end
local function finish(ok,why)
 if finished then return end; finished=true
 local n=0 for _ in pairs(pals) do n=n+1 end
 log("%s reason=%s palette_values=%d",ok and "PASS" or "ERROR",why,n)
 logfh:close(); manager.machine:exit()
end
local function cache()
 local wanted={["UI Select"]=1,["Coin 1"]=1,["1 Player Start"]=1,["P1 High Punch"]=1,["P1 Low Kick"]=1}
 for _,p in pairs(manager.machine.ioport.ports) do for _,f in pairs(p.fields) do if wanted[f.name] then fields[f.name]=f end end end
end
local function pressed(n)
 if n=="UI Select" then return frame>=5 and frame<35 end
 if n=="Coin 1" then return frame>=700 and frame<980 and frame%80<20 end
 if n=="1 Player Start" then return frame>=1000 and frame<1080 end
 if n=="P1 High Punch" then return confirm>0 and frame>=confirm and frame<confirm+45 end
 if n=="P1 Low Kick" then return post>0 and frame>=post+260 and frame<post+305 end
 return false
end
emu.register_frame(function()
 frame=frame+1
 if frame==1 then space=manager.machine.devices[":maincpu"].spaces["program"]; cache() end
 if space and not finished then
  local gs=r16(A.gstate)
  if gs==GS_PSEL then
   if psel==0 then psel=frame end
   w16(A.p1_char,FT_RAIDEN); w16(A.p2_char,FT_JAX)
   if confirm==0 and frame-psel>90 then confirm=frame end
  elseif gs==GS_POST then
   if post==0 then post=frame end
   w16(A.p1_char,FT_RAIDEN); w16(A.p2_char,FT_JAX)
  elseif gs==GS_FIGHT and fight==0 then fight=frame; log("fight started") end
  if fight>0 and won==0 and frame-fight>180 then
   w16(A.p1_bar,MAX_HP); w16(A.p1_bar_view,MAX_HP); w16(A.p2_bar,0); w16(A.p2_bar_view,0)
   won=frame; log("forced Raiden win")
  end
  if won>0 and r16(A.winner)~=0 then
   local obj=r32(A.p1_obj); if obj~=0 then pals[r16(obj+OPAL)]=true end
   local n=0 for _ in pairs(pals) do n=n+1 end
   if n>=2 then finish(true,"raiden_victory_electric_cycle") return end
   if frame-won>900 then finish(false,"palette_did_not_cycle") return end
  end
 end
 for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
 if frame>6000 then finish(false,"timeout") end
end)
