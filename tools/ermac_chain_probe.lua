-- ermac_chain_probe.lua
-- MEASURE Ermac's teleport -> telekinetic-slam chain.  The report is that it
-- links consistently, and that the four-hit separation
-- (no_unlimited_airhits -> repell_attacker) does not break it because the
-- teleport re-closes any distance it asks for.
--
-- This rig does NOT try to be a human.  It attempts each move the instant the
-- GAME says it is legal - P1 idle in act_stance, the teleport off its l_decoy
-- cooldown, the slam inside its own box - which is the upper bound on what a
-- player can do and therefore the honest measurement of the loop.
--
-- What it reports, and why each number is read rather than inferred:
--   CYCLES   completed teleport+slam pairs
--   BAR      P2's bar before and after.  The loop's worth per cycle.
--   PHITMAX  the victim's own p_hit, the counter no_unlimited_airhits reads at
--            > 3.  If this never passes 3 the separation never fires at all
--            and the reported "four hit push back" is something else.
--   SEP      frames on which p1_xvel carried a separation request - the only
--            evidence attacker_getting_separated ran at all.
--   FREE     frames the victim spent in act_stance, i.e. able to act.  A loop
--            is only an exploit if this is near zero.
--   TTK      ticks from the first hit to P2's bar reaching 0.
--
-- Built on ermac_teleslam_test.lua's select/unlock sequence, which is
-- feedback-driven and proven; do not re-time it.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("ECH_LOG") or (ROOT .. "/tools/ermac_chain_probe.log")
local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[ech] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(os.getenv("ECH_MAP") or (ROOT.."/src/mk2.map"),"r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end

-- A missing symbol is a REFUSAL, not a default: every address below is read out
-- of the build, and a nil would silently read address 0 for the whole run.
local NEED = {"gstate","p1_char","p2_char","c_ermac_cheat1","f_ermac_cheat1",
              "p1_proc","p2_proc","p1_obj","p2_obj","p1_bar","p2_bar",
              "l_decoy","tick","p1_xvel","f_freeze_timer"}
local A, missing = {}, {}
for _,n in ipairs(NEED) do A[n] = symbols[n]; if not A[n] then missing[#missing+1]=n end end

local P_ACTION, P_HIT, OXPOS = 0x1f0, 0x370, 0x090
-- THE CATCH IS THE VICTIM'S p_hit GOING UP while Ermac is in act_ermac_tks.
-- inc_p_hit runs in reaction_start_chores, so the counter rises on the tick the
-- reaction starts - which is the only honest place to read what the victim was
-- doing when the grab took hold: a RE-grab never transitions INTO act_reacting
-- (he is already in it and stays in it), so there is no action-code edge.
--
-- NOT the victim's oyvel.  r_ermac_teleslam opens with oyvel = -erm_tks_liftv
-- (-2.0) and nothing else writes that value outright, so it looks like a clean
-- signal - but the BOUNCE at the end of the same reaction decelerates from
-- -8.0 by 0.375 a tick and 0x80000 - 16*0x6000 is EXACTLY 0x20000, so it
-- passes back through -2.0 sixteen ticks in.  That scored two catches per slam
-- and called every second one a re-grab: ten catches and five "re-grabs" on a
-- build whose hit log shows five connects and five clean whiffs.
local ACT_STANCE = 0x303
local GS_PSEL, GS_FIGHT = 4, 2
local FT_REPTILE, FT_JAX = 9, 11
local MODE    = (os.getenv("ECH_MODE") or "chain")    -- chain | slamonly | teleonly | block | scale | cap | combo | cool
-- scale mode: SEED the victim's p_hit so the slam lands as the (SEED+1)th hit
-- of a string, and read what the impact takes off his bar.  Seeded rather than
-- driven, for the reason run_rain_halfdmg_probe.ps1 seeds rh_cdmg: building a
-- real three-hit juggle into the slam is a second thing to get right, and the
-- counter IS the input dmgscale reads.  back_to_normal clears p_hit whenever
-- the victim settles, so it is held EVERY tick until the catch - and then let
-- go, because the index is read at the IMPACT ~70 ticks later and must carry
-- the catch's own inc_p_hit on top of the seed.
local SEED    = tonumber(os.getenv("ECH_SEED") or "0")
local MAXCYC  = tonumber(os.getenv("ECH_CYCLES") or "12")
local TKS_MAX = tonumber(os.getenv("ECH_TKSMAX") or "200")
local TKS_MIN = tonumber(os.getenv("ECH_TKSMIN") or "110")
local TRACE   = (os.getenv("ECH_TRACE") or "1") ~= "0"

-- THE GATE'S OWN NUMBERS, read out of MAINEQU.ASM rather than written here.
-- erm_tks_maxhit / erm_tks_cool ARE the behaviour under test (UMK3's
-- q_ermac_slam), so a rig carrying its own copy would keep passing after
-- somebody retuned them.
local MAXHIT, COOL
do
  local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
  if fh then
    for line in fh:lines() do
      local n, v = line:match("^(erm_tks_%w+)%s+%.set%s+([%w]+)")
      if n == "erm_tks_maxhit" then MAXHIT = tonumber(v) end
      if n == "erm_tks_cool" then
        COOL = tonumber((v:gsub("h$", "")), v:match("h$") and 16 or 10)
      end
    end
    fh:close()
  end
end

local space, fields = nil, {}
local frame, psel, fight = 0, 0, 0
local held = {}
local function hold(n,on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function action(p) local q=r32(A[p]); return q~=0 and r16(q+P_ACTION) or 0xffff end
local function phit(p)   local q=r32(A[p]); return q~=0 and (r16(q+P_HIT) & 0xff) or 0 end
local function objx(o)   local p=r32(A[o]); return p~=0 and s16(r16(p+OXPOS)) or 0 end

local BLK="P1 Block"
local LP="P1 Low Punch"
local HP="P1 High Punch"
local HK="P1 High Kick"
local LEFT="P1 Left"
local RIGHT="P1 Right"
local DOWN="P1 Down"
local P2BLK="P2 Block"
local P2LP="P2 Low Punch"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
              ["UI Select"]=1,[BLK]=1,[LP]=1,[HP]=1,[HK]=1,[LEFT]=1,[RIGHT]=1,[DOWN]=1,
              [P2BLK]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do if not fields[n] then log("input MISSING %s", n) end end
end

-- combo mode opens on its OWN lead-in: land a plain High Kick first, so the
-- slam that follows has no cooldown pending and the victim is still in
-- act_reacting.  That situation is the whole of the user's complaint and NEITHER
-- of the other modes reaches it - the slam's own cooldown (128) outlasts the
-- victim's recovery (~140), so a masher's next slam always finds him on his feet
-- and this build measures the same as the blunt act_reacting refusal it replaces.
local st, st_t = ((os.getenv("ECH_MODE") or "chain") == "combo") and "prehit" or "approach", 0
local cycles, att_tele, att_slam = 0, 0, 0
local phitmax, sepframes, freeframes, traced = 0, 0, 0, 0
local first_hit_rel, kill_rel = nil, nil
local bar0, prev_bar = nil, nil
local done, last_cnt, armed_at = false, 0, nil
local catches, regrabs = 0, 0
local last_catch_rel, min_gap, gaps = nil, nil, {}
local scale_dmg, scale_bar = nil, nil
local cap_fired, cap_tried = false, 0
local prehit_at, tele_at, prehit_rel = nil, nil, nil
local cool_armed, cool_fired_rel, hk_presses = false, nil, 0
local prev_p2act, prev_ph = nil, nil
local function setst(s) st, st_t = s, frame end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    if #missing > 0 then
      log("FAIL ermac_chain: missing symbols: %s", table.concat(missing,","))
      log("finished"); manager.machine:exit(); return
    end
    log("mode=%s cycles=%d band=%d..%d", MODE, MAXCYC, TKS_MIN, TKS_MAX)
  end
  if not space then return end
  local gs = r16(A.gstate)

  if gs == GS_PSEL and psel == 0 then
    psel = frame; log("select at frame %d", frame)
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start","UI Select"}) do hold(n,false) end
  end

  if psel == 0 then
    hold("Coin 1", frame>=200 and (frame%80)<20)
    hold("Coin 2", frame>=200 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("2 Players Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif fight == 0 then
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start"}) do hold(n,false) end
    local cnt = r16(A.c_ermac_cheat1)
    local pending = r16(A.f_ermac_cheat1)
    if gs == GS_PSEL then
      w16(A.p1_char, FT_REPTILE); w16(A.f_ermac_cheat1, 1); pending = 1
    end
    if not armed_at and gs ~= GS_PSEL then w16(A.p1_char, FT_REPTILE) end
    if pending == 0 and not armed_at then
      hold(BLK, (frame % 4) < 2)
      if cnt ~= last_cnt then last_cnt = cnt end
    else
      hold(BLK, false)
      if not armed_at then armed_at = frame; log("cheat ARMED at frame %d", frame) end
      hold(LP, ((frame - armed_at) % 16) < 6)
      w16(A.p2_char, FT_JAX)
      hold(P2LP, ((frame - armed_at) % 12) < 5)
    end
    if gs == GS_FIGHT then
      fight = frame; hold(LP,false); hold(P2LP,false)
      -- RE-STAMP the phase clock on the first fighting frame.  st_t starts at 0
      -- while `frame` is already ~700 by the time select is over, so any phase
      -- with a timeout expires on its own first tick - combo's lead-in did,
      -- reporting "the High Kick never connected" at the start distance before
      -- it had walked anywhere.  The other modes open on `approach`, which has
      -- no timeout, which is why nothing caught this earlier.
      setst(st)
      log("fight at frame %d, p1_char=%d (17 = Ermac)", frame, r16(A.p1_char))
    end
  else
    local rel = frame - fight
    -- Freeze the round clock.  A 99-second round is ~5400 ticks; a long chain
    -- measurement runs past it, and a round that ends under the rig reports the
    -- loop as having stopped on its own.
    w16(A.f_freeze_timer, 1)

    if rel < 90 then
      for _,n in ipairs({LEFT,RIGHT,DOWN,HP,HK,BLK}) do hold(n,false) end
      hold(P2BLK, MODE == "block")
      for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
      return
    end

    local p1x, p2x = objx("p1_obj"), objx("p2_obj")
    local dist = math.abs(p1x - p2x)
    local fwd  = (p2x >= p1x) and RIGHT or LEFT
    local back = (p2x >= p1x) and LEFT  or RIGHT
    local a1, a2 = action("p1_proc"), action("p2_proc")
    local ph = phit("p2_proc")
    local bar = r16(A.p2_bar)
    if bar0 == nil then bar0 = bar; prev_bar = bar end
    if ph > phitmax then phitmax = ph end
    if a2 == ACT_STANCE then freeframes = freeframes + 1 end
    if s16(r16(A.p1_xvel)) ~= 0 then sepframes = sepframes + 1 end
    if bar < prev_bar then
      if first_hit_rel == nil then first_hit_rel = rel end
      log("  HIT rel=%4d  -%-3d -> %-3d  phit=%d dist=%d p1act=%#x p2act=%#x st=%s",
          rel, prev_bar - bar, bar, ph, dist, a1, a2, st)
      prev_bar = bar
    elseif bar > prev_bar then
      prev_bar = bar
    end
    if bar == 0 and kill_rel == nil then kill_rel = rel end
    -- Did the grab take hold this tick, and on what?
    if prev_ph ~= nil and ph > prev_ph and a1 == 0x11b then
      catches = catches + 1
      local was = prev_p2act or a2
      -- THE GAP BETWEEN CONNECTS is the thing UMK3's timer governs, and it is
      -- measured between CATCHES rather than between attempts: the cooldown is
      -- stamped on a connect, so a whiff in between must not reset it.
      local gap = last_catch_rel and (rel - last_catch_rel) or nil
      if gap then
        gaps[#gaps+1] = gap
        if min_gap == nil or gap < min_gap then min_gap = gap end
      end
      last_catch_rel = rel
      if was == 0x503 then
        -- NOT a failure any more.  A slam that takes hold of a man already in a
        -- reaction is the move being used as a combo ender, which is what UMK3
        -- allows up to erm_tks_maxhit; the blunt act_reacting refusal this
        -- replaced is why it "just doesn't connect".
        regrabs = regrabs + 1
        log("  CATCH %d at rel=%d  IN COMBO (victim was %#x) gap=%s",
            catches, rel, was, tostring(gap))
      else
        log("  CATCH %d at rel=%d  victim was %#x (free) gap=%s",
            catches, rel, was, tostring(gap))
      end
    end
    prev_ph, prev_p2act = ph, a2

    if MODE == "cool" and last_catch_rel ~= nil then
      -- IS THE MOVE PREVENTED, OR DOES IT COME OUT AND WHIFF?  The gaps between
      -- connects cannot tell those apart, and that distinction is the whole
      -- question: a qualifier refusal means act_ermac_tks is never stamped at
      -- all, where an in-window refusal would stamp it and then reach for
      -- nobody.
      --
      -- ARM ONLY ONCE HIS OWN SLAM HAS ENDED.  act_ermac_tks is still set at the
      -- catch (it runs t=24..49 and the catch lands ~t=34), so watching for the
      -- code from the catch onward would re-detect the slam that set the timer.
      if not cool_armed then
        if a1 ~= 0x11b then cool_armed = true end
      elseif cool_fired_rel == nil and a1 == 0x11b then
        cool_fired_rel = rel
        log("  MOVE STARTED AGAIN at rel=%d - %d ticks after the connect at %d "..
            "(%d HK presses offered in between)",
            rel, rel - last_catch_rel, last_catch_rel, hk_presses)
      end
    end

    if MODE == "cap" then
      -- THE HIT-COUNT CAP.  Seed the victim's p_hit and ask only whether the
      -- MOVE STARTED: q_ermac_slam is a qualifier, so a refusal means
      -- ermac_hi_kick falls through to an ordinary high kick and p1_action
      -- never reaches act_ermac_tks.  Nothing about the grab box is under test
      -- here, which is why the victim is parked and left alone.
      --
      -- Held every tick, unlike -Mode scale: the gate reads p_hit when the HK
      -- lands, not at the impact, and back_to_normal clears it the moment he
      -- settles.
      local q = r32(A.p2_proc)
      if q ~= 0 then w16(q + P_HIT, (r16(q + P_HIT) & 0xff00) | (SEED & 0xff)) end
      if a1 == 0x11b then cap_fired = true end
    end

    if MODE == "scale" then
      -- Hold the seed until the grab takes hold, then stop.
      if catches == 0 then
        local q = r32(A.p2_proc)
        if q ~= 0 then w16(q + P_HIT, (r16(q + P_HIT) & 0xff00) | (SEED & 0xff)) end
      elseif scale_dmg == nil then
        if scale_bar == nil then scale_bar = bar end
        if bar < scale_bar then
          scale_dmg = scale_bar - bar
          log("  SCALE seed=%d -> slam damage %d  (p_hit at the catch was %d)",
              SEED, scale_dmg, SEED + 1)
        end
      end
    end

    if TRACE and traced < 4000 then
      traced = traced + 1
      log("T %5d st=%-9s t=%3d d=%4d p1=%#06x p2=%#06x ph=%d bar=%3d xv=%d",
          rel, st, frame-st_t, dist, a1, a2, ph, bar, s16(r16(A.p1_xvel)))
    end

    hold(P2BLK, MODE == "block")
    local idle = (a1 == ACT_STANCE)
    local t = frame - st_t

    if st == "prehit" then
      -- THE TELEPORT PUNCH is the lead-in, because it is the user's own chain:
      -- Down,Back + HP lands for 20 and the slam follows it.  Two other lead-ins
      -- were measured first and neither can link, which is worth keeping:
      --   a plain High Kick  P1's own recovery ~38 ticks + the slam's ~24 of
      --                      startup, and the catch landed 72 ticks after the
      --                      hit with the victim long since on his feet;
      --   an uppercut        91 ticks, same story - an airborne victim does not
      --                      stay in act_reacting as long as the slam needs.
      -- And slam->slam cannot do it either: the slam's own reaction holds him
      -- 91 ticks (measured) against a 128-tick cooldown, so the timer always
      -- outlasts the reaction.
      for _,n in ipairs({HK}) do hold(n,false) end
      if tele_at == nil then
        hold(fwd, dist > 0x60); hold(back, false); hold(DOWN,false); hold(HP,false)
        if idle and dist <= 0x60 then tele_at = frame end
      else
        local u = frame - tele_at
        hold(DOWN, u < 4)
        hold(back, u >= 5 and u < 14)
        hold(fwd,  false)
        hold(HP,   u >= 8 and u < 12)
        if u > 120 then tele_at = nil end	-- it never came out: try again
      end
      if prehit_at == nil and bar < (bar0 or 0) then
        prehit_at = frame; prehit_rel = rel
        log("PREHIT landed at rel=%d  -%d  victim=%#x dist=%d",
            rel, (bar0 or 0) - bar, a2, dist)
        for _,n in ipairs({HK,HP,DOWN,LEFT,RIGHT}) do hold(n,false) end
      end
      -- WAIT FOR HIS OWN RECOVERY FIRST.  The lead-in kick leaves P1 in it
      -- (0x0103 then 0x060c, ~38 ticks measured) and MK2 discards input for the
      -- whole of it, so a motion driven straight off the hit is thrown away and
      -- the slam never comes out at all.  The victim is still in act_reacting
      -- well past that, which is what leaves a window to link into.
      if prehit_at ~= nil then
        hold(HK,false); setst("prewait")
      elseif t > 600 then
        log("combo: the lead-in High Kick never connected (dist=%d)", dist)
        setst("approach")
      end
    elseif st == "prewait" then
      for _,n in ipairs({DOWN,HP,HK,LEFT,RIGHT}) do hold(n,false) end
      if idle then
        setst("slam"); att_slam = att_slam + 1
      elseif t > 200 then
        setst("approach")
      end
    elseif st == "approach" then
      for _,n in ipairs({DOWN,HP,HK}) do hold(n,false) end
      local want_tele = (MODE == "chain" or MODE == "teleonly" or MODE == "block")
      local tsl = (r16(A.tick) - r16(A.l_decoy)) & 0xffff
      if want_tele and idle and tsl >= 0x60 then
        hold(LEFT,false); hold(RIGHT,false); setst("tele"); att_tele = att_tele + 1
      elseif (not want_tele or tsl < 0x60) and idle
             and dist <= TKS_MAX and dist >= TKS_MIN then
        hold(LEFT,false); hold(RIGHT,false); setst("slam"); att_slam = att_slam + 1
      else
        hold(fwd,  dist > TKS_MAX)
        hold(back, dist < TKS_MIN)
      end
    elseif st == "tele" then
      -- Down, Back + HP - ermac_teleport_test.lua's own spacing.
      hold(DOWN, t < 4)
      hold(back, t >= 5 and t < 14)
      hold(fwd,  false)
      hold(HP,   t >= 8 and t < 12)
      hold(HK,   false)
      if t > 90 or (t > 20 and idle) then
        for _,n in ipairs({DOWN,LEFT,RIGHT,HP}) do hold(n,false) end
        if MODE == "teleonly" then setst("approach") else setst("slam_wait") end
      end
    elseif st == "slam_wait" then
      for _,n in ipairs({DOWN,HP,HK}) do hold(n,false) end
      hold(fwd,  dist > TKS_MAX)
      hold(back, dist < TKS_MIN)
      if idle and dist <= TKS_MAX and dist >= TKS_MIN then
        hold(LEFT,false); hold(RIGHT,false); setst("slam"); att_slam = att_slam + 1
      elseif t > 240 then
        setst("approach")
      end
    elseif st == "slam" then
      -- Back, Down, Back then HK - ermac_teleslam_test.lua's proven spacing:
      -- the D makes him duck and a button inside the stand-up WEDGES him, so
      -- HK waits for t=22 and the motion still closes inside the 32-tick window.
      hold(back, (t>=0 and t<4) or (t>=8 and t<18))
      hold(DOWN, t>=4 and t<8)
      hold(fwd,  false)
      hold(HP,   false)
      -- Count the presses, so a PASS cannot be the rig never asking.
      local hknow = (t>=22 and t<26)
      if hknow and not held[HK] then hk_presses = hk_presses + 1 end
      hold(HK,   hknow)
      if t > 170 or (t > 30 and idle) then
        for _,n in ipairs({DOWN,LEFT,RIGHT,HK}) do hold(n,false) end
        cycles = cycles + 1
        if MODE == "cap" then cap_tried = cap_tried + 1 end
        log("cycle %d done at rel=%d  bar=%d  phitmax=%d  capfired=%s",
            cycles, rel, bar, phitmax, tostring(cap_fired))
        setst("approach")
      end
    end

    if MODE == "cool" and not done and cool_fired_rel ~= nil then
      done = true
      local lag = cool_fired_rel - (last_catch_rel or 0)
      -- `hk_presses >= 2` is what stops this passing because the rig never asked:
      -- a run that offered the input once and happened to be late would look
      -- identical to the gate holding it off.
      local ok = COOL ~= nil and lag >= COOL and hk_presses >= 2
      log("%s ermac_chain mode=cool startlag=%d cool=%s presses=%d",
          ok and "PASS" or "FAIL", lag, tostring(COOL), hk_presses)
      log("finished"); manager.machine:exit()
    end

    if MODE == "combo" and not done and (cycles >= 1 or (prehit_at and frame - prehit_at > 400)) then
      done = true
      -- WHAT THIS ASSERTS is that the teleport->slam chain CONNECTS, and what it
      -- MEASURES is the lag from the lead-in's hit to the grab taking hold.  The
      -- lag is the point: at 48 ticks (teleport), 72 (high kick) or 91
      -- (uppercut) the victim has already left act_reacting, because the slam's
      -- grab box opens ~24 ticks after the input and P1's own recovery from any
      -- lead-in adds more.  So `incombo` is reported, not required - the slam
      -- cannot be linked into in MK2, and erm_tks_maxhit is therefore reachable
      -- only by seeding (-Mode cap).  An assertion on incombo would be asking
      -- the rig to prove something the engine does not allow.
      local lag = (prehit_at and last_catch_rel) and (last_catch_rel - (prehit_rel or 0)) or -1
      local ok = (prehit_at ~= nil) and (catches >= 1)
      log("%s ermac_chain mode=combo prehit=%s catches=%d incombo=%d lag=%d phitmax=%d",
          ok and "PASS" or "FAIL", tostring(prehit_at ~= nil), catches, regrabs, lag, phitmax)
      log("finished"); manager.machine:exit()
    end

    if MODE == "cap" and not done and cap_tried >= 3 then
      done = true
      -- UMK3: refused when get_his_p_hit > 4, i.e. at a seed of erm_tks_maxhit
      -- or more.  Below that it must come out.
      -- NOT `(MAXHIT ~= nil) and (SEED < MAXHIT) or nil`.  Lua's and/or is not a
      -- conditional: when SEED < MAXHIT is false that collapses to `false or nil`
      -- = nil, so every REFUSED seed - the half of the cap worth testing - came
      -- back as "no expectation" and failed.  CLAUDE.md documents the identical
      -- trap in the slicehat rig; it is easy to write twice.
      local want
      if MAXHIT ~= nil then want = (SEED < MAXHIT) end
      local ok = (want ~= nil) and (cap_fired == want)
      log("%s ermac_chain mode=cap seed=%d maxhit=%s fired=%s want=%s tries=%d",
          ok and "PASS" or "FAIL", SEED, tostring(MAXHIT),
          tostring(cap_fired), tostring(want), cap_tried)
      log("finished"); manager.machine:exit()
    end

    if MODE == "scale" and not done and scale_dmg ~= nil then
      done = true
      -- erm_tks_damage is 9, and the curve is full / 3/4 / 1/2 / 1/4 with a
      -- floor of 1: 9, 9-(9>>2)=7, 9>>1=4, 9>>2=2.
      local want = ({[0]=9,[1]=7,[2]=4,[3]=2})[SEED] or 2
      local ok = (scale_dmg == want)
      log("%s ermac_chain mode=scale seed=%d damage=%d want=%d",
          ok and "PASS" or "FAIL", SEED, scale_dmg, want)
      log("finished"); manager.machine:exit()
    end

    if not done and (cycles >= MAXCYC or kill_rel ~= nil or rel > 5000) then
      done = true
      local ttk = (first_hit_rel and kill_rel) and (kill_rel - first_hit_rel) or -1
      -- THE VERDICT IS THE GAP BETWEEN CONNECTS, not the re-grab count and not
      -- the damage.  UMK3's rule is a 128-tick timer stamped on a connect, so
      -- two slams landing closer than erm_tks_cool is the lock coming back -
      -- and a build with NO gate shows gaps of ~50.  Damage moves with the
      -- rig's own spacing and the re-grab count is now a FEATURE, so neither
      -- can be the assertion.
      --
      -- `catches >= 2` is what makes the gap meaningful: one connect has no gap
      -- to measure, so a run that only ever landed once would pass vacuously.
      local ok = (catches >= 2) and COOL ~= nil and (min_gap ~= nil) and (min_gap >= COOL)
      log("%s ermac_chain mode=%s cycles=%d tele_att=%d slam_att=%d bar %d->%d " ..
          "catches=%d incombo=%d mingap=%s cool=%s gaps=[%s] phitmax=%d sep=%d free=%d ttk=%d",
          ok and "PASS" or "FAIL",
          MODE, cycles, att_tele, att_slam, bar0 or -1, bar,
          catches, regrabs, tostring(min_gap), tostring(COOL),
          table.concat(gaps, " "), phitmax, sepframes, freeframes, ttk)
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 9000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
