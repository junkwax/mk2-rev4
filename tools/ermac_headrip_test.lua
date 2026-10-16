-- ermac_headrip_test.lua
--
-- End-to-end MAME harness for ERMAC'S TELEKINETIC HEAD RIP (MKERFAT.ASM),
-- Forward, Back, Forward, Forward + LOW KICK in FINISH HIM.
--
-- Select and FINISH HIM are ermac_fatal_slam_test.lua's: Reptile + Block x5
-- with the cheat's pending flag held, hid_earned granted (hidearn - a fresh
-- nvram has earned nobody), and FINISH HIM put in by hand.  The INPUT is real:
-- it goes through the joystick queue, ermac_lo_kick, erf_check,
-- combo_look_lr and fatality_xfer_close.
--
-- The beats are read out of src/MKERFAT.ASM (ERF_T_*, generated from
-- data/ERMACFAT2.WAX) and @erf_tick out of src/mk2.map, so a re-authored
-- project moves the rig with it.  What is judged, each beat on its own:
--
--   FIRED   f_death reaches 2 (init_death_blow ran).
--   SHAKE   between GRIP and RIP the victim's x takes >= 2 values, and is
--           back where it started at the rip.
--   RIP     a single-part object carrying the victim's ochar exists (the
--           head - decapped_head's convention), it starts on HIM, and it
--           later reaches ERMAC.
--   SPLIT   at IMPACT a MULTIPART non-fighter with his ochar appears (the
--           legs) on his anchor, and z is torso > head > legs - the head is
--           INSIDE the torso.
--   OVER    after PULL the torso slides toward Ermac and the legs' frame
--           changes (they buckle).
--   ENDED   f_death -1 and Ermac's frame keeps moving (victory ran).
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG  = os.getenv("ERF_LOG") or (ROOT .. "/tools/ermac_headrip_test.log")
local DIST = tonumber(os.getenv("ERF_DIST") or "240")
local SIDE = (os.getenv("ERF_SIDE") or "left"):lower()
local SNAPS = (os.getenv("ERF_SNAPS") or "1") ~= "0"
local SETTLE = 400

local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[erf] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(os.getenv("ERF_MAP") or (ROOT.."/src/mk2.map"),"r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) local v=symbols[n]; if not v then log("WARN missing symbol %s",n) end return v or 0 end

local T = {}
-- erflift (MKERFAT.ASM): 1 = he tears the head off and LIFTS it on Sub-Zero's
-- victory while the body goes down; 0 = the throw-into-him-and-burst version
local LIFT = false
local lift_rise, lift_pose, lift_poses, lift_frames = -999, nil, 0, 0
do local fh=io.open(ROOT.."/src/MKERFAT.ASM","r")
  if fh then for line in fh:lines() do
    local k,v = line:match("^ERF_T_(%u+)%s+%.set%s+(%d+)")
    if k then T[k]=tonumber(v) end
    local lv = line:match("^erflift%s+%.set%s+(%d+)")
    if lv then LIFT = (tonumber(lv) ~= 0) end end fh:close() end end
for _,k in ipairs({"GRIP","RIP","IMPACT","PULL","END"}) do
  if not T[k] then log("FATAL ERF_T_%s not found in src/MKERFAT.ASM", k) end end

local A = { gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
            cheatc=sym("c_ermac_cheat1"), cheatf=sym("f_ermac_cheat1"),
            earned=symbols["hid_earned"],
            p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
            p1_obj=sym("p1_obj"),  p2_obj=sym("p2_obj"),
            winner_status=sym("winner_status"), f_death=sym("f_death"),
            objlst=sym("objlst"), objlst2=sym("objlst2"), objlst3=sym("objlst3"),
            dizzy=sym("dizzy"), dizzy_dude=sym("dizzy_dude"),
            erf_tick=sym("erf_tick"), active=sym("active"), worldtly=sym("worldtly") }
local O = { next=0x000, oxval=0x080, oxpos=0x090, oyval=0x0a0, oypos=0x0b0, ozval=0x0c0,
            oflags=0x0f0, osag=0x100, oflags2=0x160, oimg=0x1a0, oshape=0x1d0, ochar=0x1f0 }
local P = { wake=0x0e0, action=0x1f0, flags=0x210 }
local M_MULTI = 0x0002
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local GS_PSEL, GS_FIGHT = 4, 2
local FT_REPTILE, FT_ERMAC = 9, 17
local ACT_STUNNED = 0x0400
local VICTIM_NAMES = { jax=11, reptile=9, noob=15, subzero=8, scorpion=10, kang=1, cage=2,
                       raiden=7, kitana=4, mileena=5, baraka=3, kunglao=0, shang=6,
                       jade=16, ermac=17, rain=19, smoke=14 }
local VICTIM = VICTIM_NAMES[(os.getenv("ERF_VICTIM") or "jax"):lower()]
               or tonumber(os.getenv("ERF_VICTIM") or "") or 11

local space, fields = nil, {}
local frame, psel, fight = 0, 0, 0
local held = {}
local function hold(n,on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end
local function objx(o) return o ~= 0 and s16(r16(o + O.oxpos)) or 0 end
local function objy(o) return o ~= 0 and s16(r16(o + O.oypos)) or 0 end
local function objz(o) return o ~= 0 and s32(r32(o + O.ozval)) or 0 end

local BLK, LP, LK = "P1 Block", "P1 Low Punch", "P1 Low Kick"
local LEFT, RIGHT = "P1 Left", "P1 Right"
local P2LP = "P2 Low Punch"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
              ["UI Select"]=1,[BLK]=1,[LP]=1,[LK]=1,[LEFT]=1,[RIGHT]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

-- Forward, Back, Forward, Forward + LK, as discrete closures.  Forward is
-- toward the victim: Right with Ermac on the left.
local FWD = (SIDE == "right") and LEFT or RIGHT
local BCK = (SIDE == "right") and RIGHT or LEFT
local COMBO = { {0,4,FWD}, {8,12,BCK}, {16,20,FWD}, {24,28,FWD}, {30,38,LK} }

-- THE HEAD is found through its PROCESS (erf_head_proc, pid_head 0202h,
-- whose saved a8 is the head object) - not by ochar, because Kung Lao is
-- ochar 0 like every object getobj has just zeroed, and an ochar walk matches
-- a stray for him.  Once seen it is cached: the process dies when the head
-- comes to rest and the object stays.  THE LEGS are a multipart non-fighter
-- carrying the victim's ochar AND oid (the split copies both).
local PID_HEAD, PA8 = 0x0202, 0x0c0
local head_cache = nil
local function find_parts()
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  local legs
  if not head_cache and A.active ~= 0 then
    local pp, guard = r32(A.active), 0
    while pp ~= 0 and guard < 200 do
      if r16(pp + 0x020) == PID_HEAD then
        local o = r32(pp + PA8)
        if o ~= 0 and o ~= p1o and o ~= p2o and (r16(o + O.oflags2) & M_MULTI) == 0
           and r16(o + O.ochar) == VICTIM then head_cache = o end
      end
      pp = r32(pp); guard = guard + 1
    end
  end
  local voi = p2o ~= 0 and r16(p2o + 0x1c0) or -1
  for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
    local obj, guard = r32(list), 0
    while obj ~= 0 and guard < 400 do
      if obj ~= p1o and obj ~= p2o and r16(obj + O.ochar) == VICTIM
         and (r16(obj + O.oflags2) & M_MULTI) ~= 0 and r16(obj + 0x1c0) == voi then
        legs = legs or obj
      end
      obj = r32(obj + O.next); guard = guard + 1
    end
  end
  return head_cache, legs
end

local armed_at, finish_at, dizzy_forced, ready_at, input_at = nil, 0, false, 0, 0
local fired, fired_at, ended, ended_at, done = false, 0, false, 0, false
local attempts, last_tick = 0, -1
local ex, vx0 = nil, nil                      -- anchors at the fire
local shake_xs, rip_back = {}, nil
local head_seen, head_start_d, head_min_ermac = false, nil, 1e9
local split_ok, split_z, legs_d = false, nil, nil
local torso_x_pull, torso_x_end, legs_shape_pull, legs_moved = nil, nil, nil, false
local victim_shape_grip, victim_headless = nil, false
local settle_moved, last_shape = false, nil
local head_leak, head_back, head_rest = false, false, nil
local torso_flip_pull, torso_flip_end = nil, nil
local head_prev_d, head_backjump = nil, 0
local head_seen_after = false
local turn_start, turn_seen, turn_end = nil, nil, nil
local exploded, head_above, head_land_x, head_land_y = false, false, nil, nil
local snap_at = {}

local function snap(tag)
  if SNAPS and not snap_at[tag] then snap_at[tag] = true; manager.machine.video:snapshot()
    log("  snapshot %s", tag) end
end

local function snap_range()
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  if p1o == 0 or p2o == 0 then return end
  local x = (SIDE == "right") and (r16(p2o + O.oxpos) + DIST) or (r16(p2o + O.oxpos) - DIST)
  w16(p1o + O.oxpos, x); w32(p1o + O.oxval, (x << 16)); w32(p1o + 0x040, 0)
end

local SPILL_LO, SPILL_HI = symbols["SPILL1"], symbols["SPILL13"]
local spill_at, spill_obj, spill_max_img, spill_z, spill_before_end = nil, nil, nil, nil, false
local spill_y, spill_ground = nil, nil
local function find_spill()
  if not SPILL_LO then return nil end
  for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
    local obj, guard = r32(list), 0
    while obj ~= 0 and guard < 400 do
      local im = r32(obj + O.oimg)
      if im >= SPILL_LO and im <= SPILL_HI then return obj end
      obj = r32(obj + O.next); guard = guard + 1
    end
  end
end
emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    log("victim=%d dist=%d side=%s beats GRIP=%s RIP=%s IMPACT=%s PULL=%s END=%s",
        VICTIM, DIST, SIDE, tostring(T.GRIP), tostring(T.RIP), tostring(T.IMPACT),
        tostring(T.PULL), tostring(T.END))
  end
  if not space then return end
  local gs = r16(A.gstate)
  if A.earned then w16(A.earned, 7) end         -- hidearn: Ermac earned

  if gs == GS_PSEL and psel == 0 then psel = frame; log("select at frame %d", frame) end

  if psel == 0 then
    hold("Coin 1", frame>=200 and (frame%80)<20)
    hold("Coin 2", frame>=200 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("2 Players Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif fight == 0 then
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start"}) do hold(n,false) end
    local pending = r16(A.cheatf)
    if gs == GS_PSEL then w16(A.p1_char, FT_REPTILE); w16(A.cheatf, 1); pending = 1 end
    if not armed_at and gs ~= GS_PSEL then w16(A.p1_char, FT_REPTILE) end
    if pending == 0 and not armed_at then
      hold(BLK, (frame % 4) < 2)
    else
      hold(BLK, false)
      if not armed_at then armed_at = frame; log("  cheat ARMED at frame %d", frame) end
      hold(LP, ((frame - armed_at) % 16) < 6)
      w16(A.p2_char, VICTIM)
      hold(P2LP, ((frame - armed_at) % 12) < 5)
    end
    if gs == GS_FIGHT then
      fight = frame; hold(LP,false); hold(P2LP,false)
      log("fight at frame %d, p1_char=%d (17 = Ermac)", frame, r16(A.p1_char))
    end
  else
    local rel = frame - fight
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)

    if finish_at == 0 and rel > 120 and p1o ~= 0 and p2o ~= 0
       and r16(p1o + O.ochar) == FT_ERMAC and r16(p2o + O.ochar) == VICTIM then
      w16(A.winner_status, 3); w16(A.f_death, 0)
      local p1p = r32(A.p1_proc)
      if p1p ~= 0 then w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING|PM_SITDUCK|PM_SPECIAL)) end
      local p2p = r32(A.p2_proc)
      if p2p ~= 0 and not dizzy_forced then w32(p2p + P.wake, A.dizzy_dude); dizzy_forced = true end
      finish_at = frame
      log("finish him forced at rel=%d", rel)
    end
    if finish_at > 0 and input_at == 0 and not fired then w16(A.winner_status, 3) end

    if finish_at > 0 and ready_at == 0 then
      local p2p = r32(A.p2_proc)
      local wake = p2p ~= 0 and r32(p2p + P.wake) or 0
      if wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p2p + P.action) == ACT_STUNNED then
        ready_at = frame; snap_range()
        log("victim dizzy at rel=%d; snapped to dist=%d (p1_x=%d p2_x=%d)", rel, DIST,
            objx(r32(A.p1_obj)), objx(r32(A.p2_obj)))
      end
    end

    if ready_at > 0 and input_at == 0 and not fired and frame - ready_at > 20 then
      input_at = frame; attempts = attempts + 1
      log("attempt %d: input starts dist=%d", attempts, math.abs(objx(p1o) - objx(p2o)))
    end
    if input_at > 0 and not fired then
      local t = frame - input_at
      for _,n in ipairs({LEFT,RIGHT,LK}) do hold(n,false) end
      for _,st in ipairs(COMBO) do if t >= st[1] and t < st[2] then hold(st[3], true) end end
      if t > 150 then
        log("attempt %d MISSED (f_death %d) - re-arming", attempts, s16(r16(A.f_death)))
        input_at, ready_at = 0, 0
      end
    end

    local fd = s16(r16(A.f_death))
    if fd == 2 and not fired then
      fired = true; fired_at = frame
      for _,n in ipairs({LEFT,RIGHT,LK}) do hold(n,false) end
      ex, vx0 = objx(p1o), objx(p2o)
      log("FIRED at rel=%d ermac_x=%d victim_x=%d", rel, ex, vx0)
    end

    if fired and not ended then
      local tick = r16(A.erf_tick)
      local head, legs = find_parts()
      local vx = objx(p2o)
      if tick >= T.GRIP and tick < T.RIP then
        shake_xs[vx] = true
        if not victim_shape_grip then victim_shape_grip = r32(p2o + O.oshape) end
        if tick == T.GRIP + 8 then snap("grip") end
      end
      if tick >= T.RIP + 2 and rip_back == nil then   -- the victim restores on
        rip_back = vx                                -- his own tick; read after it
      end
      if tick == T.RIP + 3 and victim_shape_grip then
        victim_headless = r32(p2o + O.oshape) ~= victim_shape_grip
        snap("rip")
      end
      if head and tick >= T.RIP and tick < T.IMPACT then
        local hx = objx(head)
        if not head_seen then head_seen = true; head_start_d = math.abs(hx - vx0)
          log("HEAD at tick %d: x=%d (victim %d, ermac %d)", tick, hx, vx0, ex) end
        local d = math.abs(hx - ex)
        -- on its way to Ermac it only ever gets closer: no hop back to an
        -- old authored position (the 2026-10-06 bug: Ermac's clock waited
        -- for the flight and then the hold read a mid-flight row)
        -- signed: px in FRONT of Ermac, toward the victim.  Moving further
        -- behind him (the WAX's wind-up before the throw) is not a jump back.
        local f = (hx - ex) * ((vx0 > ex) and 1 or -1)
        if head_prev_d and tick < (LIFT and T.CATCH or T.THROW) and f > head_prev_d + 6 then
          head_backjump = head_backjump + 1
          log("  BACKJUMP tick=%d front %d -> %d", tick, head_prev_d, f)
        end
        head_prev_d = f
        if d < head_min_ermac then head_min_ermac = d end
      end
      if tick == T.RIP + 6 then snap("ripfly") end
      if tick == T.RIP + 30 then snap("held") end
      if T.THROW and tick == T.THROW + 7 then snap("throw") end
      -- one full turn on the throw: several roll frames, back where it began
      if head and tick == T.THROW - 1 then turn_start = r32(head + O.oimg); turn_seen = {} end
      if head and turn_seen and tick >= T.THROW and tick < T.IMPACT then
        turn_seen[r32(head + O.oimg)] = true; turn_end = r32(head + O.oimg)
      end
      if tick == T.IMPACT + 3 and not split_z then
        if legs and head then
          split_z = { torso = objz(p2o), head = objz(head), legs = objz(legs) }
          legs_d = math.abs(objx(legs) - vx)
          -- legs drawn over the torso; the head is INSIDE him - parked off
          -- the plane (+0800h), single-part objects ignoring m_inviso
          split_ok = split_z.legs > split_z.torso and split_z.head > split_z.torso and objy(head) < 1000
          log("SPLIT at tick %d: z torso=%d head=%d legs=%d; legs x=%d torso x=%d",
              tick, split_z.torso, split_z.head, split_z.legs, objx(legs), vx)
        else
          log("SPLIT MISSING at tick %d: head=%s legs=%s", tick, tostring(head), tostring(legs))
          split_z = {}
        end
        snap("impact")
      end
      if tick == T.IMPACT + 30 then snap("inside") end
      if tick == T.PULL - 2 then torso_flip_pull = r16(p2o + O.oflags) & 0x10 end
      if tick == T.IMPACT + 3 and legs then legs_shape_pull = r32(legs + O.oshape) end
      if tick == T.PULL then
        torso_x_pull = vx
        if legs then legs_shape_pull = r32(legs + O.oshape) end
      end
      if LIFT and tick >= T.RIP then
        local n = r32(p2o + O.oimg); local pose = (n ~= 0) and r32(n) or 0
        if pose ~= lift_pose then lift_pose = pose; lift_poses = lift_poses + 1 end
        if head and objy(head) < 1000 then
          local rise = objy(p1o) - objy(head)
          if rise > lift_rise then lift_rise = rise end
        end
        lift_frames = lift_frames + 1
        if lift_frames == 40 then snap("hold") end
        if lift_frames == 74 then snap("rise") end
        if lift_frames == 115 then snap("look") end
        if lift_frames == 190 then snap("lifted") end
      end
      if tick == T.PULL + 6 then snap("pull") end
      if tick == T.PULL + 30 then snap("over") end
      if legs and legs_shape_pull and r32(legs + O.oshape) ~= legs_shape_pull then legs_moved = true end
      if head and tick > T.PULL + 3 and objy(head) < 1000 then head_leak = true; head_seen_after = true end
      if tick >= T.IMPACT + 2 and (r16(p2o + O.oflags2) & 0x20) ~= 0 then exploded = true end
      if head and tick > T.IMPACT and objy(head) < 1000 then
        local wy = s16(r16(A.worldtly + 16))
        if objy(head) < wy then head_above = true end
        if tick >= T.PULL + 3 and not head_above then snap("shoot") end
        if head_above and objy(head) > wy + 60 then snap("drop") end
        if head_above and objy(head) > objy(p2o) + 100 then snap("landing") end
        head_land_x, head_land_y = objx(head), objy(head)
      end
      if os.getenv("ERF_TRACE") and tick >= T.IMPACT and frame % 6 == 0 then
        local n, pp, g, wakes = 0, r32(A.active), 0, {}
        while pp ~= 0 and g < 200 do
          if r16(pp + 0x020) == 0x0202 then n = n + 1; wakes[#wakes+1] = string.format("%08x", r32(pp + 0x0e0)) end
          pp = r32(pp); g = g + 1
        end
        log("  POST tick=%d pid_head=%d [%s] head=%s legs=%s", tick, n, table.concat(wakes, ","),
            head and string.format("%d,%d vy=%d", objx(head), objy(head), s32(r32(head + 0x060))) or "-",
            legs and string.format("%08x", r32(legs + O.oshape)) or "-")
      end
      if os.getenv("ERF_TRACE") and head and ((tick >= 76 and tick <= 102) or (tick >= 168 and tick <= 190)) then
        log("  TRACE f=%d tick=%d head=%d,%d", frame, tick, objx(head), objy(head))
      end
      if tick ~= last_tick and tick % 10 == 0 then
        log("  tick=%3d ermac_x=%d victim x=%d y=%d z=%d head=%s legs=%s f_death=%d", tick,
            objx(p1o), vx, objy(p2o), objz(p2o),
            head and string.format("%d,%d z=%d", objx(head), objy(head), objz(head)) or "-",
            legs and string.format("%d,%d z=%d", objx(legs), objy(legs), objz(legs)) or "-", fd)
      end
      last_tick = tick
      if fd == -1 then
        ended = true; ended_at = frame; torso_x_end = vx; torso_flip_end = r16(p2o + O.oflags) & 0x10
        snap("end")
        log("ENDED at tick %d (f_death -1)", tick)
      elseif frame - fired_at > 1200 then
        ended = true; ended_at = frame
        log("TIMED OUT without death_blow_complete (tick %d)", tick)
      end
    end

    if fired and frame % 4 == 0 then
      local sp = find_spill()
      if sp and not spill_at then spill_at = frame - fired_at
        log("SPILL appears %d frames after the fire (tick %d, gstate %d, ended=%s)", spill_at,
            r16(A.erf_tick), gs, tostring(ended)) end
      if sp then spill_max_img = r32(sp + O.oimg); spill_z = r32(sp + O.ozval)
        if spill_max_img == SPILL_HI then snap("pool") end
        if os.getenv("ERF_SPILLSNAPS") then
          snap(string.format("spill%08x", spill_max_img))
          log("  spill img=%08x x=%d y=%d flip=%d", spill_max_img, s16(r16(sp + O.oxpos)),
              s16(r16(sp + O.oypos)), r16(sp + 0x0f0) & 0x10)
        end
        if not ended then spill_before_end = true end
        spill_y = s16(r16(sp + O.oypos)); spill_ground = s16(r16(sym("ground_y"))) end
    end
    if ended and not done then
      local st = frame - ended_at
      local shape = p1o ~= 0 and r32(p1o + O.oshape) or 0
      if last_shape ~= nil and shape ~= last_shape then settle_moved = true end
      last_shape = shape
      if head_cache then head_land_x, head_land_y = objx(head_cache), objy(head_cache) end
      if st >= SETTLE then
        done = true
        -- torn out: it lands about a quarter screen from him, toward Ermac
        -- the head went with him: never on screen again after it went in
        local land_ok = not head_seen_after
        local spill_ok = spill_at ~= nil and spill_max_img == SPILL_HI and spill_before_end and spill_z == 0x18000
        local nturn = 0; if turn_seen then for _ in pairs(turn_seen) do nturn = nturn + 1 end end
        local turn_ok = nturn >= 6 and turn_end == turn_start
        local nshake = 0; for _ in pairs(shake_xs) do nshake = nshake + 1 end
        -- it goes back off the screen: its anchor moved away from Ermac

        if LIFT then
          -- the head ends in the air over him, the body went through its fall
          local head_up = head_cache and objy(head_cache) < 1000 and lift_rise >= 25
          local okl = fired and nshake >= 2 and rip_back == vx0 and victim_headless
                      and head_seen and head_min_ermac < 60 and head_up and lift_poses >= 5
                      and head_backjump == 0 and s16(r16(A.f_death)) == -1
          log("%s ermac_headrip (lift): fired=%s shake=%d back=%s headless=%s nearest_ermac=%d rise=%d (head top %s px over his anchor at the end) body_poses=%d backjumps=%d ended=%s victim=%d attempts=%d",
              okl and "PASS" or "FAIL", tostring(fired), nshake, tostring(rip_back == vx0),
              tostring(victim_headless), head_min_ermac, lift_rise,
              tostring(head_cache and (objy(p1o) - objy(head_cache))), lift_poses, head_backjump,
              tostring(s16(r16(A.f_death)) == -1), VICTIM, attempts)
          log("finished"); manager.machine:exit()
          return
        end
        local ok = fired and nshake >= 2 and rip_back == vx0 and victim_headless
                   and head_seen and head_start_d < 60 and head_min_ermac < 60
                   and split_ok and legs_d ~= nil and legs_d <= 2
                   and turn_ok and spill_ok and exploded and legs_moved and not head_leak and land_ok and head_backjump == 0
                   and s16(r16(A.f_death)) == -1 and settle_moved
        log("%s ermac_headrip: fired=%s shake=%d back=%s headless=%s head(start %s px off him, nearest Ermac %d px) split=%s head_hidden=%s backjumps=%d turn=%d frames/back_to_start=%s spill=%s exploded=%s head_gone_after=%s (%s,%s) legs_on_him=%s legs_buckle=%s ended=%s settled=%s victim=%d attempts=%d",
            ok and "PASS" or "FAIL", tostring(fired), nshake, tostring(rip_back == vx0),
            tostring(victim_headless), tostring(head_start_d), head_min_ermac,
            tostring(split_ok), tostring(not head_leak), head_backjump, nturn, tostring(turn_end == turn_start), tostring(spill_at and string.format('%d/%s/z%x/beforeend=%s/y%s/ground%s', spill_at, tostring(spill_max_img == SPILL_HI), spill_z or 0, tostring(spill_before_end), tostring(spill_y), tostring(spill_ground))), tostring(exploded), tostring(not head_seen_after),
            tostring(head_land_x and (head_land_x + 11 - vx0)), tostring(head_land_y), tostring(legs_d), tostring(legs_moved),
            tostring(s16(r16(A.f_death)) == -1), tostring(settle_moved), VICTIM, attempts)
        log("finished"); manager.machine:exit()
      end
    end
    if not done and rel > 4000 then
      done = true
      log("FAIL ermac_headrip: never completed - fired=%s attempts=%d f_death=%d",
          tostring(fired), attempts, s16(r16(A.f_death)))
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 9000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
