-- kitana_fan_catch_test.lua
--
-- Verifies what the Kitana fan-boomerang does when it gets back to her
-- (MKZAP.ASM fan_ret_flyby): it does NOT stop there -- no catch, no silent
-- evaporation -- it keeps the velocity it arrived with and runs off the side
-- of the screen.  Two modes, because "she is standing there" and "she jumped
-- out from under it" are the two ways the blade can find her, and the answer
-- has to be the same either way:
--
--   FANCATCH_MODE=ground : she is standing when the blade comes home
--   FANCATCH_MODE=air    : she is airborne when it arrives
--   FANCATCH_MODE=aim    : the blade is steered DOWNWARD on the way out and
--                          the TURN itself is measured -- that the stick only
--                          buys the ceiling, that the blade coasts on past the
--                          turn line before anything bends, that it never
--                          SLOWS DOWN going round (the old hook bled x through
--                          zero, so it stopped dead at the apex: that is what
--                          read as a heavy recoil), that the way home has no
--                          step in it, and that it comes back to HER HAND and
--                          arrives level (fan_home_step).  Every mode also
--                          fails if the fan's art turns round in flight.
--
-- FANCATCH_TRACE=1 adds a per-tick line for the blade -- position, velocity,
-- facing, and the process's parked PC (PWAKE, resolvable with
-- sym_resolve.py) -- which is how the shape of the boomerang arc itself is
-- read back out of a run rather than guessed at from snapshots.
--
-- Both assert the same outcome: it goes past her and off screen, and NO
-- KTSPINCHOP frame ever renders (an earlier build caught it with those --
-- this test is also the guard that the catch stays gone).
--
-- Rig notes:
--   * P2 joins as an IDLE HUMAN (p2_state=active, no P2 inputs) so nothing
--     interrupts the window under test.
--   * P2 is given a permanent Jade-Flash stamp (f_jade_flash p2 word), which
--     proj_strike_check honours by letting every projectile pass through.
--     That is what makes the fan reach the screen edge and boomerang instead
--     of connecting.
--   * The throw is Forward, Forward + HP AND LP together: MOVES.ASM
--     fn1_lo_punch runs two_button_check with a5=0 (=sw_hi_punch), so the
--     entry before the LP in the button queue must be a High Punch no more
--     than 2 ticks old.  Either button alone just throws a punch.
--   * That same HP is then HELD for the whole flight -- MKZAP.ASM
--     fan_check_hp_held is what turns the throw into a boomerang.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local MODE = (os.getenv("FANCATCH_MODE") or "ground"):lower()
local TRACE = (os.getenv("FANCATCH_TRACE") or "") ~= ""

-- Every constant the `aim` mode measures against is READ OUT OF MKZAP.ASM.  A
-- typed copy passes happily against a build whose cap, coast or curl has been
-- changed or removed, which is the whole thing these assertions are for.
local K = {}
do
  local want = { fan_aim_ymax=65536.0, fan_coast=1, fan_curl_rot=1,
                 fan_curl_ticks=1, fan_home_acc=65536.0,
                 fan_home_ymax=65536.0, fan_turn_margin=1 }
  local fh = io.open(ROOT.."/src/MKZAP.ASM", "r")
  if fh then
    for line in fh:lines() do
      local name, val = line:match("^(fan_%a[%w_]*)%s+%.set%s+(%x+)h?")
      if name and want[name] and K[name]==nil then
        K[name] = tonumber(val, 16) / want[name]
      end
    end
    fh:close()
  end
end
local AIM_YMAX = K.fan_aim_ymax
local SCRRGT   = 399            -- DISPEQU.ASM
local LOG  = os.getenv("FANCATCH_LOG") or (ROOT .. "/tools/kitana_fan_catch_" .. MODE .. ".log")

local logfh = io.open(LOG, "w")
-- Separate "frames are actually running" flag for mame_dismiss_warning.ps1.
-- It must NOT watch the log above: that is opened at script load, before a
-- single frame runs, so the poker would quit instantly and leave MAME parked
-- on the red ROM-warning screen forever at ~0 CPU.
local READY = LOG .. ".ready"
os.remove(READY)
local frame = 0
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[fancatch] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

------------------------------------------------------------------ symbols
local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do
    for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end
  end fh:close() end end
local missing = {}
local function sym(n,fb) local v=symbols[n]; if v then return v end
  if fb==nil then missing[#missing+1]=n end; return fb end

local A = {
  active=sym("active"), gstate=sym("gstate"), curback=sym("curback"),
  map_position=sym("map_position",0), battle_num=sym("battle_num",0),
  p1_char=sym("p1_char"), p2_char=sym("p2_char"),
  p1_state=sym("p1_state"), p2_state=sym("p2_state"),
  p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
  p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
  p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
  winner_status=sym("winner_status"), tick=sym("tick"),
  f_jade_flash=sym("f_jade_flash"),
  objlst=sym("objlst"), worldtlx=sym("worldtlx",0),
}

-- KTSPINCHOP piece SAGs, read straight out of the table the ROM uses so the
-- test cannot drift when the sidecar is repacked.
local SAG = {}
do
  local fh=io.open(ROOT.."/src/KITSPIN.TBL","r")
  if fh then
    local pending=nil
    for line in fh:lines() do
      local lbl = line:match("^(KTSPINCHOP%d+[AB]):")
      if lbl then pending=lbl end
      local v = line:match("^%s*%.long%s+0(%x+)[Hh]")
      if v and pending then SAG[pending]=tonumber(v,16); pending=nil end
    end
    fh:close()
  end
end
local SAG_NAME = {}
for k,v in pairs(SAG) do SAG_NAME[v]=k end

------------------------------------------------------------------- offsets
local O = { next=0x000, oxval=0x080, oxpos=0x090, oyval=0x0a0, oypos=0x0b0,
            oxvel=0x040, oflags=0x0f0,
            oyvel=0x060, oimg=0x1a0, oid=0x180 }
local P = { next=0x000, procid=0x020, pa8=0x0c0, action=0x1f0, ganiy=0x200, pwake=0x0e0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KITANA, FT_JAX = 4, 11
local MAX_HP = 0xA1
local ACT_PROJ_SD = 0x0604
local PID_PROJ1 = 0x0700
local JFLASH_TICKS = 60

local cpu, space, fields = nil, nil, {}
local last_gs=-1
local charsel_frame, fighting_frame, p1_confirm = 0,0,0
local throw_frame, sd_left_frame = 0,0
local fan_first, fan_last_x, fan_gone_frame = 0, nil, 0
local fan_max_x, fan_returning, fan_passed = nil, false, false
-- aim mode bookkeeping.  The turn is a COAST and then a ROTATION now, so what
-- is measured is: what the stick bought (the ceiling), how far past the turn
-- line the blade kept going before x started coming back (the run-on), whether
-- it ever SLOWED DOWN going round (the old hook bled x through zero - the
-- blade stopped dead, which is the whole thing that read as a heavy recoil),
-- whether the way home is smooth, and whether it lands level on her hand.
local turned_frame, vy_at_turn = 0, 0
local vy_out, vx_out, v_out, ret_vy, ret_all = 0, 0, 0, {}, {}
local turnline_x, turnline_frame = nil, 0    -- where it crossed the turn line
local curl_min_v, curl_started = nil, 0      -- slowest it ever went round
local fan_y0, arrival_y = nil, nil            -- launch height, arrival height
local arrival_vy = nil                        -- ...and what it was doing vertically
local fan_flip0, fan_flip_changed = nil, nil  -- the art must never turn round
local catch_frame, catch_ticks, catch_airborne = 0, 0, nil
local seen_sags = {}
local airborne_at_arrival, arrival_frame = nil, 0
local snapped = {}
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local function w32(a,v) space:write_u32(a,v&0xffffffff) end
local function s16(v) v=v&0xffff; if v>=0x8000 then return v-0x10000 end; return v end
local function s32(v) v=v&0xffffffff; if v>=0x80000000 then return v-0x100000000 end; return v end

local function cache_fields()
  local want={["UI Select"]=1,["Coin 1"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
              ["P1 High Punch"]=1,["P1 Low Punch"]=1,["P1 Left"]=1,["P1 Right"]=1,
              ["P1 Up"]=1,["P1 Down"]=1}
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(port.fields) do if want[f.name] then fields[f.name]=f end end end
  for n,_ in pairs(want) do
    log("input %-18s %s", n, fields[n] and "ok" or "MISSING") end
end

local function main_screen()
  local ok,s=pcall(function() return manager.machine.screens[":screen"] end); if ok and s then return s end
  ok,s=pcall(function() return manager.machine.screens:at(1) end); return ok and s or nil
end
local function snap(tag)
  if snapped[tag] then return end
  snapped[tag]=true
  local s=main_screen(); if not s then return end
  pcall(function() s:snapshot() end)
  log("SNAP %s frame=%d", tag, frame)
end

local function p1_state_read()
  local o=r32(A.p1_obj); local p=r32(A.p1_proc)
  local act = p~=0 and r16(p+P.action) or 0xffff
  local x, y, yvel, ganiy, sag = 0,0,0,0,0
  if o~=0 then
    x=s16(r16(o+O.oxpos)); y=s16(r16(o+O.oypos)); yvel=r32(o+O.oyvel)
    local img=r32(o+O.oimg); if img~=0 then sag=r32(img) end
  end
  if p~=0 then ganiy=s16(r16(p+P.ganiy)) end
  local air = (yvel~=0) or (y~=ganiy)
  return act, x, y, sag, air
end

local function find_fan()
  local p=r32(A.active); local n=0
  while p~=0 and n<250 do
    n=n+1
    if r16(p+P.procid)==PID_PROJ1 then
      local o=r32(p+P.pa8)
      if o~=0 then return p,o end
    end
    p=r32(p+P.next)
  end
  return nil,nil
end

-- the fan is protected-through P2 forever, so it always reaches the edge
local function keep_flash_on_p2()
  if not (A.f_jade_flash and A.tick) then return end
  local t=r16(A.tick)
  local v=(t + JFLASH_TICKS//2) & 0xffff
  if v==0 then v=1 end
  w16(A.f_jade_flash+16, v)
end

local function force_matchup()
  w16(A.p1_state, PS_ACTIVE)
  w16(A.p2_state, PS_ACTIVE)      -- P2 = idle human, not a drone
  w16(A.p1_char, FT_KITANA)
  w16(A.p2_char, FT_JAX)
  w16(A.curback, 0)
  if A.map_position~=0 then w16(A.map_position, 0) end
  if A.battle_num~=0 then w16(A.battle_num, 1) end
end

----------------------------------------------------------------- schedule
-- rel = frames since the fight started.
local T_SETUP  = 90     -- pin positions here
local T_FWD1   = 120
local T_FWD2   = 132
local T_HP     = 144    -- HP down first, then HELD = the boomerang
local T_LP     = 145    -- ...LP within 2 ticks of it = the fan throw
-- The aim is held from the tick after the fan leaves her hand (it spawns at
-- rel 163, and Down before that would duck the throw) until well past the turn
-- line.  THE WHOLE LEG MATTERS, not just enough of it to reach the ceiling: the
-- turn mirrors the sink the blade HAS when it gets there, so a stick let go
-- half way out leaves the return mirroring a number the outbound leg only
-- reached at the end, and the blade comes home 50px high through no fault of
-- the ROM.  A first cut of this mode held it for 8 ticks from rel 175 and that
-- is exactly what it measured.
local T_AIM    = 166
local T_AIM_HOLD = 40   -- worth 20px/tick uncapped: the ceiling is the only
                        -- thing that can decide the number this mode reads
local T_END    = 460

local hold_up_until = 0

local function pressed(name, rel)
  if fighting_frame==0 then
    if charsel_frame==0 then
      if name=="UI Select" then return frame>=5 and frame<35 end
      if name=="Coin 1" then return frame>=200 and frame<1000 and (frame%80)<20 end
      if name=="1 Player Start" then return frame>=1000 and frame<1080 end
      return false
    end
    if name=="2 Players Start" then
      local r=frame-charsel_frame; return r>=5 and r<45 end
    if name=="P1 High Punch" and p1_confirm>0 then
      return frame>=p1_confirm and frame<p1_confirm+45 end
    return false
  end

  if name=="P1 Right" then
    return (rel>=T_FWD1 and rel<T_FWD1+7) or (rel>=T_FWD2 and rel<T_FWD2+7)
  end
  if name=="P1 Low Punch" then
    return rel>=T_LP and rel<T_LP+6        -- completes the two-button throw
  end
  if name=="P1 High Punch" then
    return rel>=T_HP and rel<T_END-20      -- HELD: this is the boomerang
  end
  if name=="P1 Up" then
    return frame < hold_up_until
  end
  if name=="P1 Down" then
    -- aim mode only.  The flight loop folds 0.5px/tick into oyvel for every
    -- tick the stick is held, and this is held for T_AIM_HOLD of them, which
    -- is worth TWICE the ceiling uncapped.  That margin is the point: hold it
    -- for exactly the ceiling's worth and the assertion below passes whether
    -- the cap is there or not.
    return MODE=="aim" and rel>=T_AIM and rel<T_AIM+T_AIM_HOLD
  end
  return false
end

emu.register_frame(function()
  frame=frame+1
  if frame==1 then
    cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]
    cache_fields()
    log("=== MODE=%s ===", MODE)
    if #missing>0 then log("WARN unresolved map symbols: %s", table.concat(missing,",")) end
    local names={} for k,_ in pairs(SAG) do names[#names+1]=k end
    table.sort(names)
    for _,k in ipairs(names) do log("sag %-16s 0x%08x", k, SAG[k]) end
  end
  if not space or finished then return end
  if frame==120 then
    local fh=io.open(READY,"w"); if fh then fh:write("running"); fh:close() end
  end

  local gs=r16(A.gstate)
  if gs~=last_gs then
    if gs==GS_PSEL and charsel_frame==0 then charsel_frame=frame; log("select at %d", frame) end
    if gs==GS_FIGHTING and fighting_frame==0 then
      fighting_frame=frame; log("fight at %d", frame); snap("fight_start") end
    last_gs=gs
  end

  if charsel_frame>0 and fighting_frame==0 then
    force_matchup()
    if p1_confirm==0 and frame-charsel_frame>90 then p1_confirm=frame end
  end

  local rel = fighting_frame>0 and (frame-fighting_frame) or -1

  if fighting_frame>0 then
    -- keep the round alive and unwinnable, and keep the fan intangible to P2
    w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
    if A.winner_status then w16(A.winner_status, 0) end
    keep_flash_on_p2()

    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if rel==T_SETUP and p1o~=0 and p2o~=0 then
      -- P1 well left, P2 idle to her right with room for the blade to run
      -- far enough from the left edge that the blade has screen to run
      -- out into BEHIND her, which is what the airborne miss has to show
      w32(p1o+O.oxval, 220<<16)
      w32(p2o+O.oxval, 430<<16)
      log("pinned p1x=220 p2x=430")
    end
    if rel>T_SETUP and p2o~=0 then w32(p2o+O.oxval, 430<<16) end

    local act, p1x, p1y, sag, air = p1_state_read()

    if throw_frame==0 and act==ACT_PROJ_SD and rel>T_LP then
      throw_frame=frame; log("throw: act_proj_sd at rel=%d", rel) end
    if throw_frame>0 and sd_left_frame==0 and act~=ACT_PROJ_SD then
      sd_left_frame=frame
      log("throw recovery over at rel=%d (%d ticks)", rel, frame-throw_frame) end

    -- follow the blade
    local fproc, fobj = find_fan()
    if fobj then
      if fan_first==0 then fan_first=frame; log("fan spawned rel=%d", rel) end
      local fx = s16(r16(fobj+O.oxpos))
      local fy = s16(r16(fobj+O.oypos))
      if TRACE then
        log("path rel=%-4d fan=(%d,%d) vx=%.2f vy=%.2f flip=%d p1=(%d,%d)",
            rel, fx, fy,
            s32(r32(fobj+O.oxvel))/65536.0, s32(r32(fobj+O.oyvel))/65536.0,
            (r16(fobj+O.oflags) >> 4) & 1, p1x, p1y)
        log("span  rel=%-4d cam=%d oflags2=0x%04x osizex=%d pwake=0x%08x",
            rel, A.worldtlx~=0 and s16(r32(A.worldtlx)>>16) or -1,
            r16(fobj+0x160), r16(fobj+0x120), r32(fproc+P.pwake))
      end
      -- THE ART FLIES HOME UNTURNED.  Nothing in this rig can hit (P2 is
      -- flash-proof), and contact is the only thing allowed to re-face it.
      local flip = (r16(fobj+O.oflags) >> 4) & 1
      if fan_flip0==nil then fan_flip0=flip
      elseif flip~=fan_flip0 and not fan_flip_changed then
        fan_flip_changed=rel; log("fan art FLIPPED rel=%d (%d -> %d)", rel, fan_flip0, flip)
      end
      fan_last_x = fx
      if fan_max_x==nil or fx>fan_max_x then fan_max_x=fx end
      if fan_max_x and fx < fan_max_x-24 and not fan_returning then
        fan_returning=true; log("fan turned home rel=%d x=%d", rel, fx); snap("fan_returning") end
      -- the turn is over once x has come all the way back up to speed
      local vx = s32(r32(fobj+O.oxvel))/65536.0
      local vy = s32(r32(fobj+O.oyvel))/65536.0
      local vmag = math.sqrt(vx*vx + vy*vy)
      if fan_y0==nil then fan_y0=fy end
      -- What the stick bought, sampled only while the blade is still on its
      -- outbound leg.  "vx > 7.9" is NOT that window: the rotation's first
      -- tick pushes vx UP to 8.87 before it starts coming back, so the sample
      -- landed one tick inside the curl and read the stick's 4.00 as -0.50.
      if turnline_x==nil then
        vy_out=vy; vx_out=vx; v_out=vmag
      end

      -- WHERE THE TURN LINE IS, computed from the camera and the margin read
      -- out of the source, so the run-on is measured from the place the ROM
      -- actually starts the turn and not from wherever the velocity changed.
      if turnline_x==nil and K.fan_turn_margin and A.worldtlx~=0 and vx > 0 then
        local camx = s16(r32(A.worldtlx)>>16)
        if fx >= camx + SCRRGT - K.fan_turn_margin then
          turnline_x=fx; turnline_frame=frame
          log("turn line rel=%d x=%d (cam %d, margin %d)", rel, fx, camx, K.fan_turn_margin)
        end
      end
      -- the slowest the blade ever goes while it is turning round
      if turnline_x~=nil and turned_frame==0 then
        if curl_started==0 and math.abs(vx-vx_out) > 0.01 then
          curl_started=frame
          log("curl begins rel=%d (%d ticks of coast)", rel, frame-turnline_frame)
        end
        if curl_started~=0 and (curl_min_v==nil or vmag<curl_min_v) then curl_min_v=vmag end
      end
      if turned_frame~=0 then
        if arrival_frame==0 then ret_all[#ret_all+1] = vy end  -- the way home
      end
      if turned_frame==0 and vx < -7.0 then
        turned_frame=frame; vy_at_turn=vy
        log("out of the curl rel=%d vx=%.2f vy=%.2f |v|=%.2f", rel, vx, vy, vmag)
      end
      if fan_returning then
        local d = fx - p1x
        if arrival_frame==0 and math.abs(d)<60 then
          arrival_frame=frame; airborne_at_arrival=air; arrival_y=fy; arrival_vy=vy
          log("fan ON her rel=%d fanx=%d p1x=%d fany=%d airborne=%s", rel, fx, p1x, fy, tostring(air))
        end
        -- "past her" cannot be a big number.  The camera never sits more
        -- than ~40px behind the trailing fighter, and the blade is a
        -- MULTIPART object whose pieces hang ~19px to the left of oxpos
        -- when it is flipped, so proj_onscreen_test retires it about two
        -- ticks after it crosses her.  -20 used to just fit; it is one
        -- sample either side of the cull and not a real margin.
        if d < -8 then fan_passed=true end
        -- air mode: get her off the ground before it reaches her
        if MODE=="air" and not air and d>0 and d<190 and frame>=hold_up_until then
          hold_up_until = frame+8
        end
      end
      if fan_gone_frame~=0 then fan_gone_frame=0 end
    elseif fan_first~=0 and fan_gone_frame==0 then
      fan_gone_frame=frame
      log("fan gone rel=%d last_x=%d passed=%s", rel, fan_last_x or -1, tostring(fan_passed))
      snap("fan_gone")
    end

    -- guard: no KTSPINCHOP frame may render off the back of a fan throw
    if sd_left_frame>0 and frame>sd_left_frame+10 then
      if SAG_NAME[sag] then
        seen_sags[SAG_NAME[sag]] = (seen_sags[SAG_NAME[sag]] or 0)+1
        if catch_frame==0 then
          catch_frame=frame; catch_airborne=air
          log("CATCH-ANIM rel=%d act=0x%04x sag=%s(0x%08x) airborne=%s",
              rel, act, SAG_NAME[sag], sag, tostring(air))
          snap("catch_anim")
        end
        if act==ACT_PROJ_SD then catch_ticks=catch_ticks+1 end
      end
    end

    if rel%30==0 then
      log("rel=%-4d act=0x%04x p1=(%d,%d) air=%s cam=%d sag=0x%08x fan=%s objs=%d",
          rel, act, p1x, p1y, tostring(air),
          A.worldtlx~=0 and s16(r32(A.worldtlx)>>16) or -1, sag,
          fobj and string.format("(%d,%d)", s16(r16(fobj+O.oxpos)), s16(r16(fobj+O.oypos))) or "-",
          (function() local p=r32(A.objlst); local n=0
             while p~=0 and n<300 do n=n+1; p=r32(p+O.next) end; return n end)())
    end
  end

  for n,f in pairs(fields) do f:set_value(pressed(n, rel) and 1 or 0) end

  if fighting_frame>0 and rel>T_END then
    finished=true
    snap("final")
    local names={} for k,v in pairs(seen_sags) do names[#names+1]=string.format("%s x%d",k,v) end
    table.sort(names)
    log("sags seen: %s", #names>0 and table.concat(names,", ") or "(none)")
    log("summary throw=%s fan_seen=%s returned=%s arrival_airborne=%s catch=%s catch_air=%s catch_ticks=%d passed=%s",
        tostring(throw_frame~=0), tostring(fan_first~=0), tostring(fan_returning),
        tostring(airborne_at_arrival), tostring(catch_frame~=0), tostring(catch_airborne),
        catch_ticks, tostring(fan_passed))

    local ok, why = true, {}
    if throw_frame==0 then ok=false; why[#why+1]="fan was never thrown" end
    if not fan_returning then ok=false; why[#why+1]="fan never boomeranged" end
    if MODE=="air" then
      if airborne_at_arrival~=true then ok=false; why[#why+1]="she was not airborne on arrival" end
    else
      if airborne_at_arrival~=false then ok=false; why[#why+1]="she was not grounded on arrival" end
    end
    if catch_frame~=0 then ok=false; why[#why+1]="a KTSPINCHOP frame rendered - the catch is back" end
    if not fan_passed then ok=false; why[#why+1]="fan did not continue past her" end
    if fan_flip_changed then ok=false; why[#why+1]="the fan's art turned round in flight" end
    if MODE=="aim" then
      -- FIVE properties, and between them they are the move.
      local runon = (turnline_x and fan_max_x) and (fan_max_x - turnline_x) or nil
      local land  = (arrival_y and fan_y0) and (arrival_y - fan_y0) or nil
      local maxstep = nil
      for i=3,#ret_all do
        local d = math.abs(ret_all[i]-ret_all[i-1])
        if maxstep==nil or d>maxstep then maxstep=d end
      end
      log("aim: stick bought vy=%.2f (ceiling %s) |v|=%.2f out; coast %s ticks, "..
          "run-on %s px past the turn line, slowest |v| going round %s; "..
          "way home: %d ticks, biggest vy step %s; arrived %s px off her hand at vy=%s",
          vy_out, AIM_YMAX and string.format("%.2f", AIM_YMAX) or "UNREADABLE", v_out,
          curl_started~=0 and tostring(curl_started-turnline_frame) or "?",
          runon and string.format("%.0f", runon) or "?",
          curl_min_v and string.format("%.2f", curl_min_v) or "?",
          #ret_all, maxstep and string.format("%.2f", maxstep) or "?",
          land and string.format("%+.0f", land) or "?",
          arrival_vy and string.format("%.2f", arrival_vy) or "?")

      -- 1. THE PLAYER ONLY GETS SO MUCH OF THE ARC.  Down is held for twice
      --    the ceiling's worth, so this number can only be the ceiling.
      if AIM_YMAX == nil then
        ok=false; why[#why+1]="could not read fan_aim_ymax out of src/MKZAP.ASM"
      elseif math.abs(vy_out - AIM_YMAX) > 0.05 then
        ok=false
        why[#why+1]=string.format("outbound vy settled at %.2f, not the %.2f ceiling", vy_out, AIM_YMAX)
      end

      -- 2. IT CARRIES ON FORWARD FIRST.  A coast of fan_coast ticks at the
      --    outbound velocity, untouched, and then a curl that carries it
      --    further still: the old hook turned within 13px of the turn line.
      if K.fan_coast == nil then
        ok=false; why[#why+1]="could not read fan_coast out of src/MKZAP.ASM"
      elseif curl_started == 0 then
        ok=false; why[#why+1]="the blade never started to turn"
      elseif math.abs((curl_started - turnline_frame) - K.fan_coast) > 2 then
        ok=false
        why[#why+1]=string.format("coasted %d ticks past the turn line, not the %d it is set to",
                                  curl_started-turnline_frame, K.fan_coast)
      end
      if runon == nil then
        ok=false; why[#why+1]="never saw the blade cross the turn line"
      elseif runon < 40 then
        ok=false
        why[#why+1]=string.format("only ran on %.0fpx past the turn line before coming back", runon)
      end

      -- 3. IT EASES ROUND BUT NEVER STOPS.  The old turn bled x through ZERO
      --    - 0.5px/tick at its slowest - a dead halt and a recoil.  The turn
      --    after that kept full speed all the way round and read as blunt.
      --    Now it is drawn at fan_curl_pace eighths of its speed, 3/8 at the
      --    apex: so the slowest must be well under the throw speed (it hangs)
      --    and well above a stop (it is not a reflection).
      if curl_min_v == nil then
        ok=false; why[#why+1]="never sampled the blade going round"
      elseif curl_min_v < v_out * 0.25 then
        ok=false
        why[#why+1]=string.format("blade slowed to |v|=%.2f going round, from %.2f - that is a reflection, not a turn",
                                  curl_min_v, v_out)
      elseif curl_min_v > v_out * 0.6 then
        ok=false
        why[#why+1]=string.format("blade only slowed to |v|=%.2f going round, from %.2f - the apex has no hang",
                                  curl_min_v, v_out)
      end

      -- 4. THE WAY HOME HAS NO STEP IN IT.  It leaves the curl on what the
      --    rotation left it and moves at most fan_home_acc a tick from there.
      local acc = K.fan_home_acc
      local step = (#ret_all >= 2) and math.abs(ret_all[2] - ret_all[1]) or nil
      if acc == nil then
        ok=false; why[#why+1]="could not read fan_home_acc out of src/MKZAP.ASM"
      elseif step == nil or maxstep == nil then
        ok=false; why[#why+1]="never sampled the way home"
      else
        if step > acc + 1.2 then
          ok=false
          why[#why+1]=string.format("vertical speed stepped %.2fpx/tick coming out of the curl", step)
        end
        if maxstep > acc + 0.05 then
          ok=false
          why[#why+1]=string.format("vertical speed stepped %.2fpx/tick on the way home, more than fan_home_acc %.2f", maxstep, acc)
        end
      end

      -- 5. AND IT COMES BACK TO HER HAND, LEVEL.  Down was held all the way
      --    out, so the blade turns ~100px under the line it was thrown on.
      --    The old return (the mirror of the outbound sink) got back near the
      --    line too, but still CLIMBING at the ceiling - so the level arrival
      --    is the half that says it is homing on her.
      if land == nil or arrival_vy == nil then
        ok=false; why[#why+1]="never measured the height it came back to"
      else
        if math.abs(land) > 14 then
          ok=false
          why[#why+1]=string.format("came home %+.0fpx off her hand", land)
        end
        if math.abs(arrival_vy) > 2.0 then
          ok=false
          why[#why+1]=string.format("arrived still moving %.2fpx/tick vertically - not settled on her", arrival_vy)
        end
      end
    end
    if fan_gone_frame==0 then ok=false; why[#why+1]="fan never left the screen" end
    if ok then log("PASS %s", MODE) else log("ERROR %s: %s", MODE, table.concat(why,"; ")) end
    manager.machine:exit()
  end

  if fighting_frame==0 and frame>6500 then
    log("ERROR never reached the fight"); manager.machine:exit()
  end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh=nil end end)
