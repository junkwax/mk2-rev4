-- ermac_babality_test.lua
--
-- End-to-end MAME harness for Ermac's BABALITY, Down, Back, Back + LOW KICK.
--
-- Same scaffolding as ermac_fatal_slam_test.lua and for the same two reasons:
-- Ermac is a hidden fighter, so only the select cheat (Reptile + Block x5)
-- reaches him, and winning two rounds under script is not worth the
-- complexity, so Finish Him is forced. The INPUT is not faked - it goes
-- through the real joystick queue, char_lo_kick[17] -> ermac_lo_kick ->
-- bb_check -> ochar_baby_combos -> restricted_xfer.
--
-- The handshake this watches is the game's own, three stages of it, because
-- each one failing means something different:
--
--   STARTED   f_death reaches bb_fatality (5).  delayed_baby_start ran, so
--             the combo matched, ermac_lo_kick dispatched and bb_check's row
--             for ochar 17 was not zero.
--   SWAPPED   f_death2 reaches 1.  baby_xfer got all the way through
--             gso_dmawnz on baby_images[victim] - the baby is on screen.
--   ENDED     f_death goes to -1.  death_blow_complete ran and the victory
--             pass was reached without wedging.
--
-- EFS_AS=jade is the REFUSAL control, and it is the half of this change that
-- nothing else exercises. bb_check used to refuse everyone at `cmpi 12,ochar
-- / jrhs bbno`; it now bounds the read at ft_kham and treats a ZERO row in
-- ochar_baby_combos as the refusal. Ermac's row is non-zero, so an Ermac pass
-- says nothing about whether the zero rows still refuse. Jade (16) is the one
-- zero-row fighter a player can actually reach, she calls bb_check from
-- jade_lk_normal, and she must still get nothing from this input.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG  = os.getenv("EBB_LOG") or (ROOT .. "/tools/ermac_babality_test.log")
local SNAP = tonumber(os.getenv("EBB_SNAP") or "10")
local AS   = (os.getenv("EBB_AS") or "ermac"):lower()
-- Attempts to allow before a refusal control declares success.
local NEG_ATTEMPTS = tonumber(os.getenv("EBB_NEG_ATTEMPTS") or "8")

local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[ebb] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

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
local FT_MILEENA, FT_REPTILE = 5, 9
local VICTIM = tonumber(os.getenv("EBB_VICTIM") or "11")
local FT_JADE, FT_ERMAC = 16, 17
local ACT_STUNNED = 0x0400
local BB_FATALITY = 5

local BLK="P1 Block"; local LP="P1 Low Punch"; local LK="P1 Low Kick"
local UP="P1 Up"; local DOWN="P1 Down"; local LEFT="P1 Left"; local RIGHT="P1 Right"
local P2LP="P2 Low Punch"

-- Who to be, and how the select cheat that gets us there is shaped.  Both
-- cheats work the same way: hover a fighter, press one button five times,
-- and a pending flag turns the pick into the hidden fighter as select exits.
-- Only the cursor, the flag and the button differ.
local WHO = {
  ermac = { cursor=FT_REPTILE, ochar=FT_ERMAC,
            flag=sym("f_ermac_cheat1"), cnt=sym("c_ermac_cheat1"), button=BLK,
            expect=true },
  -- Jade was the refusal control until 2026-10-05, when she got Kitana's
  -- babality (D,D,D + LK).  Noob is the reachable zero row now.
  noob  = { cursor=8, ochar=15,
            flag=sym("f_noob_cheat1"),  cnt=sym("c_noob_cheat1"),  button=BLK,
            expect=false },
  -- No cheat at all - the cursor char IS the pick.  Reptile is the stock
  -- regression: bb_check's guard was rewritten for EVERYONE, not just Ermac,
  -- so a fighter who has always had a babality has to still have one.  He is
  -- the right one to ask: same scom_nj_baby, same LOW KICK button, and he is
  -- the character Ermac clones.
  reptile = { cursor=FT_REPTILE, ochar=FT_REPTILE,
              flag=0, cnt=0, button=nil, expect=true },
}
local ME = WHO[AS]
if not ME then error("EBB_AS must be ermac, noob or reptile, got " .. tostring(AS)) end

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
              ["UI Select"]=1,[BLK]=1,[LP]=1,[LK]=1,[UP]=1,[DOWN]=1,[LEFT]=1,
              [RIGHT]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

-- Down, Back, Back then LOW KICK.  P1 starts on the left facing right, so
-- Back is LEFT.  Discrete presses with release gaps so the queue records
-- three separate switch CLOSURES; the whole run closes at 34 ticks against
-- scom_nj_baby's 038h (56) window.
local COMBO = {
  { 0, 4, DOWN }, { 8, 12, LEFT }, { 16, 20, LEFT }, { 24, 34, LK },
}

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

    if finish_at > 0 and ready_at == 0 then
      local p2p = r32(A.p2_proc)
      local wake = p2p ~= 0 and r32(p2p + P.wake) or 0
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
      log("attempt %d: input starts rel=%d  l_hp=%#x l_lp=%#x", attempts, rel,
          r32(A.l_hp), r32(A.l_lp))
    end

    if input_at > 0 then
      local t = frame - input_at
      for _,n in ipairs({DOWN,UP,LEFT,RIGHT,LK}) do hold(n,false) end
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
          log("PASS babality_refused_%s: %d attempts of D,B,B + LK as ochar %d, f_death never left 0 (p1act=%#x)",
              AS, attempts, r16(r32(A.p1_obj) + O.ochar), action(A.p1_proc))
          log("finished"); manager.machine:exit()
        end
      end
    end

    local fd = s16(r16(A.f_death))
    if not ME.expect and fd ~= 0 and not done then
      done = true
      log("FAIL babality_refused_%s: ochar %d reached a finisher (f_death=%d) off D,B,B + LK",
          AS, r16(r32(A.p1_obj) + O.ochar), fd)
      log("finished"); manager.machine:exit(); return
    end

    if fd == BB_FATALITY and not started then
      started = true; started_at = frame
      log("STARTED at rel=%d (f_death=%d = bb_fatality) t=%d", rel, fd, frame - input_at)
    end

    if started and not ended then
      local t = frame - started_at
      if r16(A.f_death2) ~= 0 and not swapped then
        swapped = true
        log("SWAPPED at t=%d (f_death2=1: the baby is on screen)", t)
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
      log("%s babality_" .. AS .. ": started=%s swapped=%s ended=%s attempts=%d",
          ok and "PASS" or "FAIL", tostring(started), tostring(swapped),
          tostring(s16(r16(A.f_death)) == -1), attempts)
      log("finished"); manager.machine:exit()
    end
    if not done and rel > 3000 then
      done = true
      log("FAIL ermac_babality: never completed - started=%s swapped=%s attempts=%d f_death=%d p1act=%#x",
          tostring(started), tostring(swapped), attempts, s16(r16(A.f_death)), action(A.p1_proc))
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 8000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
