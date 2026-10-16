-- hidden_finisher_test.lua
--
-- Babalities and stage fatalities for the hidden fighters, end to end.
-- Grown out of ermac_babality_test.lua (same select cheat, same forced
-- FINISH HIM); the INPUT is real, through the joystick queue.
--
--   HF_AS    jade | rain | ermac | reptile | kitana | noob   (who performs;
--            noob has no babality - run it with -Negative as the control)
--   HF_KIND  baby | stage
--   HF_STAGE curback to force for a stage fatality (default 6, the Pit II)
--
-- Inputs (P1 on the left, so Back = LEFT):
--   jade/kitana baby  D,D,D + LK      jade/kitana stage F,D,F + HK
--   rain baby         D,B,B + HK      rain/ermac/reptile stage D,F,F + BLOCK
--   ermac/reptile baby D,B,B + LK
--
-- STARTED = f_death reaches the finisher number (bb 5, pit 6, spike 8).
-- MID     = babality: f_death2 1 (baby on screen); stage: the victim's
--           p_action is the stage's fall/rise action.
-- ENDED   = f_death -1 (death_blow_complete ran).
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG  = os.getenv("HF_LOG") or (ROOT .. "/tools/hidden_finisher_test.log")
local SNAP = tonumber(os.getenv("HF_SNAP") or "10")
local AS   = (os.getenv("HF_AS") or "jade"):lower()
-- Attempts to allow before a refusal control declares success.
local NEG_ATTEMPTS = tonumber(os.getenv("HF_NEG_ATTEMPTS") or "8")

local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[hf] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) local v=symbols[n]; if not v then log("WARN missing symbol %s",n) end return v or 0 end

local A = { gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
            p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
            p1_obj=sym("p1_obj"),  p2_obj=sym("p2_obj"),
            winner_status=sym("winner_status"), f_death=sym("f_death"),
            f_death2=sym("f_death2"),
            l_hp=sym("l_hp"), l_lp=sym("l_lp"),
            dizzy=sym("dizzy"), dizzy_dude=sym("dizzy_dude") }

local O = { oxvel=0x040, oxval=0x080, oxpos=0x090, oypos=0x0b0, ochar=0x1f0 }
local P = { wake=0x0e0, action=0x1f0, flags=0x210 }
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local GS_PSEL, GS_FIGHT = 4, 2
local FT_KITANA, FT_MILEENA, FT_REPTILE, FT_SCORPION = 4, 5, 9, 10
local VICTIM = tonumber(os.getenv("HF_VICTIM") or "11")
local FT_JADE, FT_ERMAC, FT_RAIN = 16, 17, 19
local ACT_STUNNED = 0x0400
local KIND  = (os.getenv("HF_KIND") or "baby"):lower()
local STAGE = tonumber(os.getenv("HF_STAGE") or "6")
local GAP   = tonumber(os.getenv("HF_GAP") or "55")   -- px, < check_dtp's 048h
A.curback = sym("curback")

local BLK="P1 Block"; local LP="P1 Low Punch"; local LK="P1 Low Kick"; local HK="P1 High Kick"
local UP="P1 Up"; local DOWN="P1 Down"; local LEFT="P1 Left"; local RIGHT="P1 Right"
local P2LP="P2 Low Punch"

-- The select cheats: hover a fighter, and the game's own pending flag turns
-- the pick into the hidden fighter as select exits (driven, not pressed -
-- see ermac_babality_test.lua).  flag=0: the cursor IS the pick.
local WHO = {
  jade    = { cursor=FT_MILEENA, ochar=FT_JADE,
              flag=sym("f_jade_cheat1"),  cnt=sym("c_jade_cheat1"),  button=LK },
  rain    = { cursor=FT_SCORPION, ochar=FT_RAIN,
              flag=sym("f_rain_cheat1"),  cnt=sym("c_rain_cheat1"),  button=BLK },
  ermac   = { cursor=FT_REPTILE, ochar=FT_ERMAC,
              flag=sym("f_ermac_cheat1"), cnt=sym("c_ermac_cheat1"), button=BLK },
  reptile = { cursor=FT_REPTILE, ochar=FT_REPTILE, flag=0, cnt=0 },
  kitana  = { cursor=FT_KITANA,  ochar=FT_KITANA,  flag=0, cnt=0 },
  -- noob: a ZERO row in ochar_baby_combos - the refusal control (-Negative)
  noob    = { cursor=8, ochar=15,
              flag=sym("f_noob_cheat1"),  cnt=sym("c_noob_cheat1"),  button=BLK },
}
local ME = WHO[AS]
if not ME then error("HF_AS must be jade, rain, ermac, reptile, kitana or noob, got " .. tostring(AS)) end
ME.expect = os.getenv("HF_EXPECT") ~= "0"

-- Discrete presses with release gaps, so the queue records separate CLOSURES;
-- the whole run closes at 34 ticks, inside every window used here (024h+).
local function seq(d1,d2,d3,btn)
  return { {0,4,d1}, {8,12,d2}, {16,20,d3}, {24,34,btn} }
end
local COMBOS = {
  jade    = { baby=seq(DOWN,DOWN,DOWN,LK),  stage=seq(RIGHT,DOWN,RIGHT,HK) },
  kitana  = { baby=seq(DOWN,DOWN,DOWN,LK),  stage=seq(RIGHT,DOWN,RIGHT,HK) },
  rain    = { baby=seq(DOWN,LEFT,LEFT,HK),  stage=seq(DOWN,RIGHT,RIGHT,BLK) },
  ermac   = { baby=seq(DOWN,LEFT,LEFT,LK),  stage=seq(DOWN,RIGHT,RIGHT,BLK) },
  reptile = { baby=seq(DOWN,LEFT,LEFT,LK),  stage=seq(DOWN,RIGHT,RIGHT,BLK) },
  noob    = { baby=seq(DOWN,LEFT,LEFT,LK),  stage=seq(DOWN,RIGHT,RIGHT,BLK) },
}
local COMBO = COMBOS[AS][KIND]
if not COMBO then error("HF_KIND must be baby or stage") end
-- f_death the finisher sets, and the victim action that proves the middle beat
-- (act_* are equates, not in the map - values from MAINEQU.ASM)
local EXPECT_FD, MID_ACT
if KIND == "baby" then EXPECT_FD = 5
elseif STAGE == 1 then EXPECT_FD, MID_ACT = 8, 0x0508      -- act_spike_rise
elseif STAGE == 6 then EXPECT_FD, MID_ACT = 6, 0x0506      -- act_pit_fall
elseif STAGE == 0x18 then EXPECT_FD, MID_ACT = 6, 0x050c   -- act_mtn_fall
elseif STAGE == 0x1a then EXPECT_FD, MID_ACT = 6, 0x050d   -- act_mk1pit_fall
else error("HF_STAGE must be a check_dtp stage: 1, 6, 0x18 or 0x1a") end

local space, fields = nil, {}
local frame, psel, fight = 0, 0, 0
local held = {}
local function hold(n,on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function action(pp) local q=r32(pp); return q~=0 and r16(q+P.action) or 0xffff end
local function objx(op) local o=r32(op); return o~=0 and s16(r16(o+O.oxpos)) or 0 end

local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
              ["UI Select"]=1,[BLK]=1,[LP]=1,[LK]=1,[HK]=1,[UP]=1,[DOWN]=1,[LEFT]=1,
              [RIGHT]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

local armed_at, last_cnt = nil, 0
local finish_at, dizzy_forced, ready_at, input_at = 0, false, 0, 0
local started, started_at, swapped, ended, done = false, 0, false, false, false
local attempts = 0

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    log("as=%s (ochar %d, babality expected: %s)", AS, ME.ochar, tostring(ME.expect))
  end
  if not space then return end
  local gs = r16(A.gstate)

  if gs == GS_PSEL and psel == 0 then psel = frame; log("select at frame %d", frame) end

  if psel == 0 then
    hold("Coin 1", frame>=200 and (frame%80)<20)
    hold("Coin 2", frame>=200 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("2 Players Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif fight == 0 then
    -- Select cheat.  Every comment in ermac_teleslam_test.lua about WHY it is
    -- shaped this way still applies: the Start holds must be cleared every
    -- frame (Start + a button is an alternate-palette confirm that skips the
    -- hidden-character check), the cursor and the pending flag must both be
    -- held to the end of select, and P1 must actually confirm or the override
    -- never lands.  The five real presses cannot arm it from here - the check
    -- reads the select CURSOR via *a13(p_mychar), which poking p1_char does
    -- not move - so the game's own pending flag is driven instead.
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start"}) do hold(n,false) end
    local cnt = ME.cnt ~= 0 and r16(ME.cnt) or 0
    local pending = ME.flag ~= 0 and r16(ME.flag) or 1
    if KIND == "stage" then w16(A.curback, STAGE) end
    if gs == GS_PSEL then
      w16(A.p1_char, ME.cursor)
      if ME.flag ~= 0 then w16(ME.flag, 1) end
      pending = 1
    end
    if not armed_at and gs ~= GS_PSEL then w16(A.p1_char, ME.cursor) end
    if pending == 0 and not armed_at then
      hold(ME.button, (frame % 4) < 2)
      if cnt ~= last_cnt then log("  cheat press %d -> %d", last_cnt, cnt); last_cnt = cnt end
    else
      if ME.button then hold(ME.button, false) end
      if not armed_at then armed_at = frame; log("  cheat ARMED at frame %d", frame) end
      hold(LP, gs == GS_PSEL and ((frame - armed_at) % 16) < 6)
      w16(A.p2_char, VICTIM)
      hold(P2LP, gs == GS_PSEL and ((frame - armed_at) % 12) < 5)
    end
    if gs == GS_FIGHT then
      fight = frame; hold(LP,false); hold(P2LP,false)
      log("fight at frame %d, p1_char=%d (want %d)", frame, r16(A.p1_char), ME.ochar)
    end
  else
    local rel = frame - fight
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)

    if finish_at == 0 and rel > 120 and p1o ~= 0 and p2o ~= 0
       and r16(p1o + O.ochar) == ME.ochar and r16(p2o + O.ochar) == VICTIM then
      w16(A.winner_status, 3); w16(A.f_death, 0)
      local p1p = r32(A.p1_proc)
      if p1p ~= 0 then w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING|PM_SITDUCK|PM_SPECIAL)) end
      local p2p = r32(A.p2_proc)
      if p2p ~= 0 and not dizzy_forced then w32(p2p + P.wake, A.dizzy_dude); dizzy_forced = true end
      finish_at = frame
      log("finish him forced at rel=%d (p1_ochar=%d p2_ochar=%d)", rel,
          r16(p1o + O.ochar), r16(p2o + O.ochar))
    end
    if finish_at > 0 and input_at == 0 then w16(A.winner_status, 3) end
    -- the victim's process can still be 0 on the forcing frame; retry
    if finish_at > 0 and not dizzy_forced then
      local p2p = r32(A.p2_proc)
      if p2p ~= 0 then w32(p2p + P.wake, A.dizzy_dude); dizzy_forced = true
        log("  dizzy forced late at rel=%d", rel) end
    end
    -- A stage fatality has a range (check_dtp: 048h).  Stand P1 GAP px in
    -- front of the victim until the input starts.
    if KIND == "stage" and finish_at > 0 and input_at == 0 and p1o ~= 0 and p2o ~= 0 then
      w16(p1o + O.oxpos, r16(p2o + O.oxpos) - GAP); w32(p1o + O.oxvel, 0)
    end

    if finish_at > 0 and ready_at == 0 then
      local p2p = r32(A.p2_proc)
      local wake = p2p ~= 0 and r32(p2p + P.wake) or 0
      if (frame - finish_at) % 200 == 1 then
        log("  waiting for dizzy rel=%d wake=%#x (dizzy=%#x) p2act=%#x ws=%d", rel, wake, A.dizzy,
            p2p ~= 0 and r16(p2p + P.action) or 0, r16(A.winner_status))
      end
      if wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p2p + P.action) == ACT_STUNNED then
        ready_at = frame
        log("victim dizzy at rel=%d, dist=%d", rel, math.abs(objx(A.p1_obj)-objx(A.p2_obj)))
      end
    end

    if ready_at > 0 and input_at == 0 and frame - ready_at > 20 then
      input_at = frame; attempts = attempts + 1
      -- bb_check refuses if a HIGH or LOW PUNCH was thrown this round
      -- (l_hp / l_lp, p1:p2 pairs).  Log them rather than assume: if a
      -- babality silently never fires, this is the first thing to look at,
      -- and "the rig pressed LP somewhere" is a much likelier explanation
      -- than the wiring being wrong.
      log("attempt %d: input starts rel=%d  l_hp=%#x l_lp=%#x curback=%#x dist=%d", attempts, rel,
          r32(A.l_hp), r32(A.l_lp), r16(A.curback), math.abs(objx(A.p1_obj)-objx(A.p2_obj)))
    end

    if input_at > 0 then
      local t = frame - input_at
      for _,n in ipairs({DOWN,UP,LEFT,RIGHT,LK,HK,BLK}) do hold(n,false) end
      for _,step in ipairs(COMBO) do
        if t >= step[1] and t < step[2] then hold(step[3], true) end
      end
      if t <= 40 and t % 4 == 0 then
        log("  input t=%2d p1act=%#x f_death=%d ws=%d", t, action(A.p1_proc),
            s16(r16(A.f_death)), r16(A.winner_status))
      end
      if t > 120 and not started then
        log("attempt %d MISSED (f_death still %d) - re-arming", attempts, s16(r16(A.f_death)))
        input_at, ready_at = 0, 0
        if not ME.expect and attempts >= NEG_ATTEMPTS and not done then
          done = true
          log("PASS %s_refused_%s: %d attempts as ochar %d, f_death never left 0 (p1act=%#x)",
              KIND, AS, attempts, r16(r32(A.p1_obj) + O.ochar), action(A.p1_proc))
          log("finished"); manager.machine:exit()
        end
      end
    end

    local fd = s16(r16(A.f_death))
    if not ME.expect and fd ~= 0 and not done then
      done = true
      log("FAIL %s_refused_%s: ochar %d reached a finisher (f_death=%d)",
          KIND, AS, r16(r32(A.p1_obj) + O.ochar), fd)
      log("finished"); manager.machine:exit(); return
    end

    if fd == EXPECT_FD and not started then
      started = true; started_at = frame
      log("STARTED at rel=%d (f_death=%d) t=%d", rel, fd, frame - input_at)
    end

    if started and not ended then
      local t = frame - started_at
      local mid = (KIND == "baby" and r16(A.f_death2) ~= 0)
               or (KIND == "stage" and action(A.p2_proc) == MID_ACT)
      if mid and not swapped then
        swapped = true
        log("MID at t=%d (%s)", t, KIND == "baby" and "f_death2=1: the baby is on screen"
            or string.format("victim p_action=%#x", MID_ACT))
      end
      if t % 10 == 0 then
        log("  t=%3d f_death=%d f_death2=%d p1act=%#x p2act=%#x", t, fd,
            r16(A.f_death2), action(A.p1_proc), action(A.p2_proc))
      end
      if SNAP > 0 and t % SNAP == 0 and t <= 300 then manager.machine.video:snapshot() end
      if fd == -1 then
        ended = true
        log("ENDED at t=%d (f_death -1: death_blow_complete ran)", t)
      elseif t > 600 then
        ended = true
        log("TIMED OUT at t=%d without death_blow_complete", t)
      end
    end

    if ended and not done then
      done = true
      local ok = started and swapped and s16(r16(A.f_death)) == -1
      log("%s %s_%s stage=%#x: started=%s mid=%s ended=%s attempts=%d",
          ok and "PASS" or "FAIL", KIND, AS, r16(A.curback), tostring(started), tostring(swapped),
          tostring(s16(r16(A.f_death)) == -1), attempts)
      log("finished"); manager.machine:exit()
    end
    if not done and rel > 3000 then
      done = true
      log("FAIL " .. KIND .. "_" .. AS .. ": never completed - started=%s mid=%s attempts=%d f_death=%d p1act=%#x",
          tostring(started), tostring(swapped), attempts, s16(r16(A.f_death)), action(A.p1_proc))
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 8000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
