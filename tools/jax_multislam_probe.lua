-- jax_multislam_probe.lua
-- MEASURE Jax's multi-slam throw, slam by slam.
--
-- super_wham (MKSLAM.ASM) is 10 damage and he gets it jax_extra_slams+1 times
-- for tapping High Punch, on top of slammed_by_jx's 18 - and none of it ever
-- passed dmgscale, because every throw applies its damage with damage_to_me,
-- which jumps straight to bar_reducer.  So one throw was 4*10 + 18 = 58, more
-- than Kintaro's 40 and the most in the game for one input.
--
-- What it reports: EVERY bar drop with the tick it landed on, so the curve is
-- read as a sequence rather than inferred from a total.  With throwscale the
-- extra slams take 3/4, 1/2, 1/4 - 10, 8, 5, 2 - and the first slam and the 18
-- are untouched, so the no-tap throw must be unchanged at 28.
--
-- THE TAPS ARE SEEDED, NOT PRESSED.  super_slam_proc keeps the extra slams
-- coming while get_tsl(l_hp) < 10, and l_hp is stamped in bj_hi_punch - the
-- button dispatch - while the thrower is inside act_bodyslam with his buttons
-- disabled.  Whether a scripted press reaches that dispatch is a question about
-- MK2's input gating, not about the damage curve under test, so the rig writes
-- l_hp = @tick directly: that is exactly what a tapping player's stamp looks
-- like, and it is the same move run_rain_halfdmg_probe.ps1 makes with rh_cdmg.
-- -Taps 0 seeds nothing and is the single-slam control.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("JMS_LOG") or (ROOT .. "/tools/jax_multislam_probe.log")
local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[jms] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(os.getenv("JMS_MAP") or (ROOT.."/src/mk2.map"),"r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end

-- A missing symbol is a REFUSAL, not a default.
local NEED = {"gstate","p1_char","p2_char","p1_proc","p2_proc","p1_obj","p2_obj",
              "p1_bar","p2_bar","l_hp","l_lp","tick","f_freeze_timer",
              "cmb_hits","cmb_dmg"}
local A, missing = {}, {}
for _,n in ipairs(NEED) do A[n] = symbols[n]; if not A[n] then missing[#missing+1]=n end end

local P_ACTION, P_HIT, OXPOS = 0x1f0, 0x370, 0x090
local ACT_STANCE, ACT_BODYSLAM = 0x303, 0x507
local ACT_NOOGY = 0x122
-- JMS_MOVE=noogy measures Jax's GOTCHA GRAB (F,F+LP, do_noogy) instead: up to
-- five 9-damage punches while LP is tapped (l_lp seeded, as l_hp is for the
-- throw).  holdhits (MAINEQU) puts both moves' hits on the kombo kounter and
-- scales the punches like any other string: 9 7 4 2 2.
local MOVE = (os.getenv("JMS_MOVE") or "throw"):lower()
local GS_PSEL, GS_FIGHT = 4, 2
local FT_KANG, FT_JAX = 1, 11
-- JMS_CHAR picks the THROWER, so the other six payload sites are exercised too -
-- throw_damage_a10 replaced the bare damage_to_me at all seven, and a refactor
-- that silently paid nothing at one of them would look fine in a Jax-only run.
-- Base damage is the thrower-indexed payload: post_fb_xfers picks the victim's
-- reaction off the THROWER's ochar, and tossed_flight then reads
-- flip_damage_table with the same index.
local THROWERS = {
  jax    = { ochar = 11, base = 18, whams = true  },  -- slammed_by_jx + super_wham
  kang   = { ochar =  1, base = 32, whams = false },  -- tossed_flight
  cage   = { ochar =  2, base = 34, whams = false },  -- slammed_by_cage
  shang  = { ochar =  6, base = 24, whams = false },  -- slammed_by_st
  raiden = { ochar =  7, base = 20, whams = false },  -- slammed_by_rd
  kitana = { ochar =  4, base = 30, whams = false },  -- slammed_by_fn
}
local CHAR = (os.getenv("JMS_CHAR") or "jax"):lower()
local WHO = THROWERS[CHAR]
local TAPS = (os.getenv("JMS_TAPS") or "1") ~= "0"
local SEEDHIT = tonumber(os.getenv("JMS_SEEDHIT") or "0")   -- victim's p_hit at the throw
-- JMS_JAB=1 lands a real High Punch first and throws while the victim is still
-- in the reaction, instead of seeding p_hit.  This is what makes the payload
-- half more than a wiring test: it measures that a throw CAN follow a hit, which
-- the code says it can - toss_check refuses an airborne victim, act_land and
-- b_noflip, and b_noflip has exactly ONE setter in the whole tree
-- (MKPROP.ASM:2960), so an ordinary standing hit reaction does not block a grab.
-- The p_hit it reports is the engine's own, not a poke.
local JAB = (os.getenv("JMS_JAB") or "0") ~= "0"
local MAXHP = 0xa1

local space, fields = nil, {}
local frame, psel, confirm, fight = 0, 0, 0, 0
local held = {}
local function hold(n,on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function action(p) local q=r32(A[p]); return q~=0 and r16(q+P_ACTION) or 0xffff end
local function objx(o) local p=r32(A[o]); return p~=0 and s16(r16(p+OXPOS)) or 0 end

local LP="P1 Low Punch"; local HP="P1 High Punch"
local LEFT="P1 Left"; local RIGHT="P1 Right"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
              ["UI Select"]=1,[LP]=1,[HP]=1,[LEFT]=1,[RIGHT]=1,["P2 Low Punch"]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do if not fields[n] then log("input MISSING %s", n) end end
end

local drops, slam_seen, throw_at, prev_bar, done = {}, false, nil, nil, false
local jab_at, jab_phit, throw_phit = nil, nil, nil
local settled = nil
local kmax, klast_h, klast_d = 0, nil, nil

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    if not WHO then
      log("FAIL jax_multislam: unknown JMS_CHAR %q - refusing rather than defaulting", CHAR)
      log("finished"); manager.machine:exit(); return
    end
    if #missing > 0 then
      log("FAIL jax_multislam: missing symbols: %s", table.concat(missing,","))
      log("finished"); manager.machine:exit(); return
    end
    log("char=%s ochar=%d base=%d whams=%s taps=%s seedhit=%d move=%s",
        CHAR, WHO.ochar, WHO.base, tostring(WHO.whams), tostring(TAPS), SEEDHIT, MOVE)
    if MOVE == "noogy" and CHAR ~= "jax" then
      log("FAIL jax_multislam: the gotcha grab is Jax's - refusing move=noogy for %s", CHAR)
      log("finished"); manager.machine:exit(); return
    end
  end
  if not space then return end
  local gs = r16(A.gstate)

  if psel == 0 and gs == GS_PSEL then
    psel = frame; log("select at frame %d", frame)
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start","UI Select"}) do hold(n,false) end
  end

  if psel == 0 then
    hold("Coin 1", frame>=200 and (frame%80)<20)
    hold("Coin 2", frame>=240 and (frame%80)>=20 and (frame%80)<40)
    hold("2 Players Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif confirm == 0 then
    local rel = frame - psel
    if gs == GS_PSEL then
      w16(A.p1_char, WHO.ochar); w16(A.p2_char, FT_KANG)
      hold("2 Players Start", rel < 60 and (frame % 20) < 8)
    end
    if rel > 130 then hold(LP,(frame%20)<8); hold("P2 Low Punch",(frame%20)<8) end
    if gs ~= GS_PSEL and rel > 60 then
      confirm = frame
      for n in pairs(fields) do hold(n,false) end
    end
  else
    if gs ~= GS_FIGHT then w16(A.p1_char, WHO.ochar); w16(A.p2_char, FT_KANG) end
    if gs == GS_FIGHT and fight == 0 then
      fight = frame
      log("fight at frame %d p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
    end
    if fight == 0 then
      for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
      return
    end

    local rel = frame - fight
    w16(A.f_freeze_timer, 1)
    w16(A.p1_bar, MAXHP)			-- P1's bar is not the instrument

    if rel < 60 then
      for n in pairs(fields) do hold(n,false) end
      for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
      return
    end

    local a1a, a2a = action("p1_proc"), action("p2_proc")
    local dist = math.abs(objx("p1_obj") - objx("p2_obj"))
    local bar = r16(A.p2_bar)
    if prev_bar == nil then prev_bar = bar end

    -- Walk in and grab.  toss_check wants <= 040h and refuses near a wall, so
    -- this closes rather than teleporting: a pinned pair also has its edge
    -- clamp cancelled, which is the trap run_lk_dubknee_test.ps1 documents.
    if throw_at == nil then
      if SEEDHIT > 0 then
        -- Seed the VICTIM's string depth.  back_to_normal clears p_hit whenever
        -- he settles, so it is held every tick right up to the grab.
        local q = r32(A.p2_proc)
        if q ~= 0 then w16(q + P_HIT, (r16(q + P_HIT) & 0xff00) | (SEEDHIT & 0xff)) end
      end
      --
      -- toss_check wants <= 040h (64px), and REPELL WILL NOT LET THEM CLOSER
      -- THAN THAT ANYWAY: measured, a walking pair settles at 63 and stays
      -- there, so an approach threshold tighter than 040h can never be reached
      -- and the grab is never attempted (the first run of this rig sat at
      -- dist=63 forever).  Walk until inside the box, then stop and press.
      --
      hold(RIGHT, dist > 0x40 and objx("p2_obj") > objx("p1_obj"))
      hold(LEFT,  dist > 0x40 and objx("p2_obj") < objx("p1_obj"))
      --
      -- AND AN IDLE FIGHTER READS p_action 0, NOT act_stance: act_mframew_z
      -- clears it when a move ends, which is the same trap JOY.ASM's own
      -- simultaneous-throw guard documents ("0000h counts as free, and missing
      -- that is what made the first version of this do nothing at all").
      -- Testing only for 0303h meant the Low Punch was never pressed.
      --
      local free = (a1a == ACT_STANCE) or (a1a == 0)
      if JAB and jab_at == nil then
        -- One High Punch, then stop pressing it.
        hold(HP, dist <= 0x40 and free)
        if a1a ~= 0 and a1a ~= ACT_STANCE and a1a ~= 0xffff then
          local q = r32(A.p2_proc)
          if q ~= 0 and (r16(q + P_HIT) & 0xff) > 0 then
            jab_at = frame
            jab_phit = r16(q + P_HIT) & 0xff
            log("JAB landed at rel=%d  victim p_hit=%d p2act=%#x", rel, jab_phit, a2a)
          end
        end
      end
      -- Throw.  With JAB on, keep the button down from the jab onward so the
      -- grab goes in as early as the engine will take it - the reaction is only
      -- a few ticks and back_to_normal clears p_hit the moment he settles.
      -- With JAB on, LP must WAIT for the jab to land.  Pressing both while he
      -- was still free meant whichever handler the switch scan reached first
      -- won, and that was the throw - it went in at p_hit 0 and the jab never
      -- happened at all.
      if MOVE == "noogy" then
        -- F, F + LP, toward him: 4 on / 4 off / 4 on, then LP on the second
        -- tap's release, retried every 40 frames while he is free.
        local fwd = objx("p2_obj") > objx("p1_obj") and RIGHT or LEFT
        local ph = frame % 40
        if dist <= 0x40 and free then
          hold(RIGHT, false); hold(LEFT, false)
          hold(fwd, ph < 4 or (ph >= 8 and ph < 12))
          hold(LP, ph >= 11 and ph < 15)
        elseif dist <= 0x40 then
          hold(LP, false)
        end
      else
      hold(LP,    dist <= 0x40 and (not JAB or jab_at ~= nil)
                  and (free or JAB) and (frame % 8) < 3)
      end
      if rel % 60 == 0 then log("  approach rel=%d dist=%d p1act=%#x free=%s", rel, dist, a1a, tostring(free)) end
    end

    local GRAB = (MOVE == "noogy") and ACT_NOOGY or ACT_BODYSLAM
    if a1a == GRAB and throw_at == nil then
      throw_at = frame
      local q = r32(A.p2_proc)
      throw_phit = q ~= 0 and (r16(q+P_HIT) & 0xff) or -1
      log("THROW at rel=%d  dist=%d  p2_bar=%d  p2_p_hit=%d (jab=%s)",
          rel, dist, bar, throw_phit, tostring(jab_phit))
      -- RE-BASELINE THE BAR HERE.  In JAB mode a real hit has already landed, so
      -- a prev_bar from before the throw turns the jab's own damage into the
      -- throw's first "slam" - measured, that scored Cage as [24 34].
      prev_bar = bar
      for n in pairs(fields) do hold(n,false) end
    end

    if throw_at ~= nil then
      local t = frame - throw_at
      -- THE TAPS.  l_hp is a p1:p2 pair of 32-bit halves; P1 is the first.
      if TAPS and a1a == GRAB then
        w16(MOVE == "noogy" and A.l_lp or A.l_hp, r16(A.tick))
      end
      -- THE KOUNTER: P1 is the attacker, so his slot is offset 0.
      local kh, kd = r16(A.cmb_hits), r16(A.cmb_dmg)
      if kh > (kmax or 0) then kmax = kh end
      if kh >= 2 then klast_h, klast_d = kh, kd end
      if bar < prev_bar then
        drops[#drops+1] = prev_bar - bar
        log("  SLAM %d at t=%3d  -%-3d -> %-3d  p1act=%#x p2act=%#x",
            #drops, t, prev_bar - bar, bar, a1a, a2a)
        prev_bar = bar
        settled = frame
      elseif bar > prev_bar then
        prev_bar = bar
      end
      if settled and frame - settled > 120 and not done then
        done = true
        local total, seq = 0, {}
        for i,d in ipairs(drops) do total = total + d; seq[#seq+1] = tostring(d) end
        -- jax_wham_damage is 10 and the curve is full / 3/4 / 1/2 / 1/4:
        -- 10, 10-(10>>2)=8, 10>>1=5, 10>>2=2.  slammed_by_jx's 18 is scaled by
        -- the VICTIM's p_hit, which a throw does not advance - so at seedhit 0
        -- it stays 18.
        -- The whams are indexed by the SLAM NUMBER, so SeedHit does not move
        -- them.  slammed_by_jx's 18 is indexed by the victim's p_hit, which a
        -- throw does not advance - so SeedHit is its index outright, with no
        -- hit of its own to take off.
        local function curve(d, i)
          if i <= 0 then return d end
          if i == 1 then return d - (d >> 2) end
          if i == 2 then return d >> 1 end
          return d >> 2
        end
        local w = {}
        if MOVE == "noogy" then
          -- Untapped is TWO punches, not one: do_noogy throws the next punch
          -- before it tests the "stopped tapping" flag noogy_early_check set
          -- (Midway's order).  Two hits is a string, so the kounter shows it.
          -- The first TWO punches land full and the curve starts on the third
          -- (held_hit_to_him's a1 = -2): 9 9 7 4 2.
          w = TAPS and {9, 9, 7, 4, 2} or {9, 9}
        elseif WHO.whams then
          w[#w+1] = 10
          if TAPS then w[#w+1] = 8; w[#w+1] = 5; w[#w+1] = 2 end
        end
        -- With JAB the index is the p_hit the ENGINE had at the throw, read
        -- off the process - not a number this rig chose.
        local idx = JAB and (throw_phit or 0) or SEEDHIT
        if MOVE ~= "noogy" then w[#w+1] = curve(WHO.base, idx) end
        local wtot = 0
        for _,v in ipairs(w) do wtot = wtot + v end
        local wseq = {}
        for _,v in ipairs(w) do wseq[#wseq+1] = tostring(v) end
        local want = table.concat(wseq," ")
        local got = table.concat(seq," ")
        -- The kounter must show the string only when it IS one (2+ hits), and
        -- then carry every hit and the same total the bar lost.
        local kwant_on
        if MOVE == "noogy" then kwant_on = #w >= 2
        else kwant_on = WHO.whams and TAPS end    -- one slam + 18 is a plain throw
        local kok
        if kwant_on then kok = (klast_h == #w) and (klast_d == wtot)
        else kok = (kmax or 0) < 2 end
        log("  KOUNTER max_hits=%s last_shown=%s hits / %s dmg  (want %s)",
            tostring(kmax), tostring(klast_h), tostring(klast_d),
            kwant_on and string.format("%d hits / %d", #w, wtot) or "no readout")
        local ok = (got == want) and (total == wtot) and kok
        log("%s jax_multislam char=%s taps=%s seedhit=%d jab=%s p_hit@throw=%s drops=[%s] total=%d  want=[%s] %d",
            ok and "PASS" or "FAIL", CHAR, tostring(TAPS), SEEDHIT, tostring(JAB),
            tostring(throw_phit), got, total, want, wtot)
        log("finished"); manager.machine:exit()
      end
      if t > 900 and not done then
        done = true
        log("FAIL jax_multislam: throw never resolved (drops=%d p1act=%#x)", #drops, a1a)
        log("finished"); manager.machine:exit()
      end
    end

    if throw_at == nil and rel > 2400 and not done then
      done = true
      log("FAIL jax_multislam: never threw (dist=%d p1act=%#x)", dist, a1a)
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 9000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
