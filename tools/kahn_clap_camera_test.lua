-- Corner sonic-clap camera probe.
--
-- Reported: "big glitch with the soniclap move near the corner and the screen
-- going downward on the Y axis".  Static audit ruled out the documented cause
-- (shake_a11 with an ODD iteration count leaves a permanent camera offset) -
-- every shake in the clap path is even and self-cancelling.  So measure the
-- camera directly instead: walk both fighters into a stage edge, fire the clap
-- on a cadence via the kdtest hook, and watch worldtly.
--
-- worldtly is 32 bits with the y value in the HIGH word (the display list
-- reads it at worldtly+16) - see reference_mk2_camera_y_chase.
local f=0; local sp
local S={}
for line in io.lines("C:/Users/you/Workplace/mk2-main/src/mk2.map") do
  for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n]=tonumber(a,16) end
end
local F={}
local charsel,confirm,fighting=0,0,0
local ymin,ymax,ystart=99999,-99999,nil
local claps=0
local placed=false
local gapmax=0
local samples={}
local SIDE=(os.getenv("CLAP_SIDE") or "L")
local function wy() return sp:read_u16(S.worldtly+16) end
emu.register_frame(function()
  f=f+1
  if f==1 then
    sp=manager.machine.devices[":maincpu"].spaces["program"]
    local w={["Coin 1"]=true,["1 Player Start"]=true,["P1 Left"]=true,["P1 Right"]=true,["P1 Block"]=true}
    for _,p in pairs(manager.machine.ioport.ports) do
      for _,fl in pairs(p.fields) do if w[fl.name] then F[fl.name]=fl end end
    end
    return
  end
  local gs=sp:read_u16(S.gstate)
  if gs==4 and charsel==0 then charsel=f end
  if gs==2 and fighting==0 then fighting=f; ystart=wy() end
  if charsel>0 and gs~=2 then
    sp:write_u16(S.p1_state,1) sp:write_u16(S.p2_state,0)
    sp:write_u16(S.p1_char,8) sp:write_u16(S.p2_char,13)
    sp:write_u16(S.curback,8) sp:write_u16(S.map_position,14) sp:write_u16(S.battle_num,15)
  end
  sp:write_u16(S.diff,9)
  if charsel>0 and confirm==0 and f-charsel>90 then confirm=f end
  for n,fl in pairs(F) do
    local on=false
    if charsel==0 then
      if n=="Coin 1" then on=f>=700 and f<980 and (f%80)<20 end
      if n=="1 Player Start" then on=f>=1000 and f<1080 end
    elseif fighting==0 then
      if n=="1 Player Start" and confirm>0 then on=f>=confirm and f<confirm+45 end
    else
      -- walk P1 hard into one stage edge so both end up cornered
      if n=="P1 Block" then on=true end   -- hold guard: every clap is BLOCKED
    end
    fl:set_value(on and 1 or 0)
  end
  if fighting==0 then return end
  sp:write_u16(S.p1_bar,161) sp:write_u16(S.p2_bar,161)

  -- PUPPET MAGIC: kahn_sonic falls through to a SPEAR when the opponent is
  -- past 0a0h, so without this the probe measured 87 zaps and no claps at
  -- all.  debug2 = 050adh makes the clap fire unconditionally.
  sp:write_u16(S.debug2,0x50ad)

  -- Place them ONCE, then let them move freely.  Pinning X every frame
  -- cancels the clap's ~95px blocked-knockback, which is the whole
  -- mechanism under test.
  local p1o,p2o=sp:read_u32(S.p1_obj),sp:read_u32(S.p2_obj)
  if p1o~=0 and p2o~=0 and not placed and (f-fighting)>120 then
    placed=true
    local wall = (SIDE=="L") and 60 or 340
    local off  = (SIDE=="L") and 70 or -70
    sp:write_u32(p2o+0x080, wall<<16)
    sp:write_u32(p1o+0x080, (wall+off)<<16)
  end
  if p1o~=0 and p2o~=0 then
    local g=(sp:read_u32(p1o+0x080)>>16)-(sp:read_u32(p2o+0x080)>>16)
    if g<0 then g=-g end
    if g>gapmax then gapmax=g end
  end

  local y=wy()
  if y<ymin then ymin=y end
  if y>ymax then ymax=y end

  -- fire the clap every ~2s once we have had time to reach the wall
  if (f-fighting)>240 and ((f-fighting)%120)==0 then
    sp:write_u16(S.debug3,3)               -- kdtest_sonic
    claps=claps+1
    samples[#samples+1]=y
  end
end)
emu.register_stop(function()
  print(string.format("=== CORNER CLAP CAMERA (side=%s) ===",SIDE))
  print(string.format("  claps fired = %d   MAX GAP REACHED = %d (screen is 400 wide)", claps, gapmax))
  print(string.format("  worldtly y: start=%s min=%d max=%d final=%d",
    tostring(ystart), ymin, ymax, wy()))
  local s=""
  for i,v in ipairs(samples) do s=s..v.." " ; if i>24 then break end end
  print("  y at each clap: "..s)
  if ystart then
    local drift=wy()-ystart
    print(string.format("  NET DRIFT = %+d  %s", drift,
      (drift>8 or drift<-8) and "<-- CAMERA MOVED AND DID NOT COME BACK" or "(stable)"))
  end
end)
