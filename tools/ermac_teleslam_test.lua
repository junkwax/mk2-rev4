-- ermac_teleslam_test.lua
-- Unlock Ermac (Reptile + Block x5), get into a fight, then input B,D,B + HK
-- and check the telekinetic slam actually runs.
--
-- The three things worth measuring, because each fails differently:
--   FIRED    p1_action reaches act_ermac_tks (011bh).  If it never does, the
--            combo or the char_hi_kick dispatch is wrong, not the move.
--   CAUGHT   the VICTIM leaves the ground.  This is the only honest proof the
--            grab connected - the attacker holding a pose proves nothing, and
--            since the rewrite p1_action is set at the START of the windup, so
--            FIRED alone no longer implies anything landed.
--   LIFTED   how far he got.  The arcade sequence is a 16-tick shake-up of
--            ~33px, then 8 ticks of NEGATIVE gravity that take him off the top
--            of the screen entirely - so a real catch reads as hundreds of
--            pixels, not the ~130 the first (wrong) port produced.
--   CLOCK    the combo window is still open the tick his feet touch down.
--            The catch arms it (a clean hit, damage 0) and the flight is
--            ~85 ticks against a 040h window, so without r_ermac_teleslam's
--            cmb_lifted the string times out mid-air and whatever follows
--            him down reads as a new combo.
--   ENDED    p1_action leaves 011bh again and P2 takes damage.  A move that
--            fires and never ends is a wedged process, which on MK2's
--            cooperative scheduler stops the whole game.
--
-- Attempts RETRY.  A whiff now sets FIRED (the windup runs either way), so a
-- rig that stopped at the first FIRED would score a legitimate out-of-range
-- miss as a broken move.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("TKS_LOG") or (ROOT .. "/tools/ermac_teleslam_test.log")
local SNAP = tonumber(os.getenv("TKS_SNAP") or "1")
local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[tks] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) return symbols[n] end

local A = { gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"), cheatc=sym("c_ermac_cheat1"), cheatf=sym("f_ermac_cheat1"), dbg=sym("debug_shock_frame"),
            p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
            p1_obj=sym("p1_obj"),  p2_obj=sym("p2_obj"),
            p1_bar=sym("p1_bar"),  p2_bar=sym("p2_bar"),
            cmb_tick=sym("cmb_tick"), cmb_hits=sym("cmb_hits"),
            cmb_lifted=sym("cmb_lifted"),
            c=sym("c_ermac_cheat1"), f=sym("f_ermac_cheat1") }
local P_ACTION, OYPOS, OXPOS = 0x1f0, 0x0b0, 0x090
local NOHK = (os.getenv("TKS_NOHK") or "0") ~= "0"
-- erm_tks_reach is 0ceh (206) since the box was read out of the arcade ROM,
-- and x_size is 06ah (106) - so the box covers roughly 100..206px in front of
-- him and there is a genuine dead zone CLOSER than that.  Aim for the middle
-- of it, not for "as close as possible": standing on top of the victim whiffs,
-- which is the arcade's behaviour and not a bug to script around.
local TKS_RANGE = tonumber(os.getenv("TKS_RANGE") or "150")
local TKS_MIN   = tonumber(os.getenv("TKS_MIN") or "120")
local GS_PSEL, GS_FIGHT = 4, 2
local FT_REPTILE, FT_ERMAC, FT_JAX = 9, 17, 11
local ACT_TKS = 0x11b

local space, fields = nil, {}
local land_t, land_tick, lift_seen = nil, nil, false
-- TKS_CLOCK=1 (default) makes the slam the SECOND hit of a string instead of
-- the first, which is the only way the combo clock can be observed at all:
-- cmb_fly - the process that counts cmb_tick DOWN - is not created until the
-- string reaches hudcmb_min (2) hits, so a lone slam leaves the clock parked
-- at the value hud_combo_hit armed it to and a rig watching it learns
-- nothing.  Two poked words and one process byte stand in for the opening
-- hit: the victim's p_hit (non-zero = a string is already running, which is
-- what hud_combo_hit tests) and P1's cmb_hits/cmb_tick.
local CLOCK = (os.getenv("TKS_CLOCK") or "1") ~= "0"
local P_HIT = 0x370          -- pdata (100h) + p_hit (270h), like P_ACTION above
local frame, psel, fight = 0, 0, 0
local held = {}
local function hold(n,on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function action(procptr) local q=r32(procptr); return q~=0 and r16(q+P_ACTION) or 0xffff end
local function objy(objptr) local o=r32(objptr); return o~=0 and s16(r16(o+OYPOS)) or 0 end
local function objx(objptr) local o=r32(objptr); return o~=0 and s16(r16(o+OXPOS)) or 0 end

local BLK="P1 Block"; local LP="P1 Low Punch"; local HK="P1 High Kick"
local LEFT="P1 Left"; local RIGHT="P1 Right"; local DOWN="P1 Down"
-- P2 is a SECOND HUMAN, not the drone.  A CPU opponent walks, attacks and
-- knocks P1 into hit-reactions, and MK2 DISCARDS input while the fighter is
-- busy - so a scripted combo lands or not depending on what the AI happened
-- to be doing, which is indistinguishable in the log from the move being
-- broken.  It also cannot be made to block on demand, so the block path was
-- untestable.  Two players: P2 stands still, or blocks when asked.
local P2BLK="P2 Block"; local P2LP="P2 Low Punch"
local BLOCKMODE = (os.getenv("TKS_BLOCK") or "0") ~= "0"
local TWOP = (os.getenv("TKS_2P") or "1") ~= "0"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,
              ["2 Players Start"]=1,["UI Select"]=1,
              [BLK]=1,[LP]=1,[HK]=1,[LEFT]=1,[RIGHT]=1,[DOWN]=1,
              [P2BLK]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

-- results
local fired, caught, lifted, ended, done = false, false, 0, false, false
local phase_lo, phase_hi = nil, nil
local base_y, hp_before, hp_after = nil, nil, nil
local attempts, atk_start = 0, 0
local last_cnt, armed_at = 0, nil
local snapped = false

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    log("act_ermac_tks=%#x  p1_proc=%#x p2_obj=%#x", ACT_TKS, A.p1_proc or 0, A.p2_obj or 0)
  end
  if not space then return end
  local gs = r16(A.gstate)

  if gs == GS_PSEL and psel == 0 then
    psel = frame; log("select at frame %d", frame)
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start",
                       "UI Select"}) do hold(n,false) end
  end

  if psel == 0 then
    hold("Coin 1", frame>=200 and (frame%80)<20)
    hold("Coin 2", TWOP and frame>=200 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("2 Players Start", TWOP and frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif fight == 0 then
    -- Block x5 on Reptile, then Low Punch to confirm out of the screen.
    -- FEEDBACK-DRIVEN select, not timing-driven.  The old version pulsed
    -- Block on a fixed schedule and hoped; whether the presses landed varied
    -- with boot/NVRAM timing, so the same rig would arm the cheat on one run
    -- and not the next - and in 2P, where select lasts longer because it
    -- waits for BOTH players, it usually did not.  Now every press is
    -- confirmed against the game's own counter (c_ermac_cheat1) before the
    -- next one is sent, so it cannot drift.
    -- MKSEL treats Start+Block as an ALTERNATE-PALETTE confirm and skips the
    -- hidden-character check entirely while Start is down (csmk_start_checked
    -- -> cmove9).  Clearing the boot holds once, on the frame select opens,
    -- is not enough: hold them false every frame or the cheat silently never
    -- counts a press.  This is what broke 2P - two Start buttons instead of
    -- one, so twice the chance of one still being latched.
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start"}) do
      hold(n,false)
    end
    local cnt = r16(A.cheatc)
    local pending = r16(A.cheatf)
    -- LATCH on armed_at, never on `pending`.  ermac_select_cheat_apply
    -- (MAIN.ASM) CLEARS f_ermac_cheat1 as it applies the override, so
    -- `pending` drops back to 0 the instant the override lands - and a rig
    -- that keys off pending then resumes forcing p1_char and stamps Reptile
    -- straight back over the Ermac it just got.  Once armed, stop touching
    -- p1_char for good.
    -- The five Block presses NEVER arm here, and that is not timing:
    -- check_ermac_blk_cheat gates on the select CURSOR via *a13(p_mychar),
    -- which poking @p1_char does not move.  Every log this rig ever wrote
    -- shows p1_char=9 with the counter stuck at 0 - it has been testing
    -- REPTILE.  Drive the game's own pending flag instead (the flag the fifth
    -- press sets, which ermac_select_cheat_apply turns into ft_ermac), and
    -- hold BOTH the cursor and the flag to the end of select: let go early and
    -- the apply fires, gets overwritten, and the pick drifts off Reptile.
    if gs == GS_PSEL then
      w16(A.p1_char, FT_REPTILE)
      w16(A.cheatf, 1)
      pending = 1
    end
    if not armed_at and gs ~= GS_PSEL then
      w16(A.p1_char, FT_REPTILE)        -- keep the cursor's char on Reptile
    end
    if pending == 0 and not armed_at then
      -- Pulse Block: one frame down, one frame up (the cheat edge-detects, so
      -- a held button counts once).  Five presses: 1-4 are swallowed, the
      -- 5th confirms Reptile and arms the Ermac override.
      hold(BLK, (frame % 4) < 2)
      if cnt ~= last_cnt then
        log("  cheat press %d -> %d at frame %d", last_cnt, cnt, frame)
        last_cnt = cnt
      end
    else
      -- Armed.  Stop touching p1_char (writing it now would stamp Reptile
      -- back over the Ermac the override is about to apply) and let P2 in.
      hold(BLK, false)
      if not armed_at then
        armed_at = frame
        log("  cheat ARMED at frame %d", frame)
      end
      -- Arming is NOT confirming.  The override only lands when select
      -- actually EXITS, so P1 has to commit; left alone he sits unconfirmed
      -- until the select timer expires and auto-picks, which does not carry
      -- the pending Ermac override - the fight then starts as plain Reptile
      -- and nothing about Ermac is under test at all.
      hold(LP, ((frame - armed_at) % 16) < 6)
      if TWOP then
        w16(A.p2_char, FT_JAX)
        hold(P2LP, ((frame - armed_at) % 12) < 5)
      end
    end

    if gs == GS_FIGHT then
      fight = frame
      hold(LP,false)
      log("fight at frame %d, p1_char=%d (17 = Ermac)", frame, r16(A.p1_char))
    end
  else
    local rel = frame - fight
    -- Let the round actually start, then walk into range and throw the motion.
    if rel <= 120 and rel % 20 == 0 then
      log("  post-fight rel=%3d p1_char=%d", rel, r16(A.p1_char))
    end
    -- CLOSE THE DISTANCE FIRST.  erm_tks_reach is 090h - a 144px front edge -
    -- and the round starts the fighters ~192px apart, with the opening Back of
    -- B,D,B walking him FURTHER out (measured: 192 -> 200).  Every attempt this
    -- rig ever made was thrown from outside the grab box, so the move fired,
    -- the windup played, and the grab had nothing to catch.  `fired` only trips
    -- on act_ermac_tks, which is set after the CATCH, so that read as "the move
    -- never fired" for as long as this rig has existed.
    if atk_start == 0 then
      local d = math.abs(objx(A.p1_obj) - objx(A.p2_obj))
      hold(RIGHT, d > TKS_RANGE)      -- P1 starts on the left, so fwd = Right
      hold(LEFT,  d < TKS_MIN)        -- ...and back off if he is INSIDE the box
      if rel % 30 == 0 then log("  approach rel=%d dist=%d", rel, d) end
    end
    local dnow = math.abs(objx(A.p1_obj) - objx(A.p2_obj))
    local in_range = dnow <= TKS_RANGE and dnow >= TKS_MIN
    -- ...and only while he is actually IDLE.  Attempts fire on a fixed rel%90
    -- schedule, so one occasionally landed while he was still in a recovery
    -- (seen once as act=0604h) and the motion went nowhere - a rig that fails
    -- 1 run in 5 for its own timing reasons is worse than no rig, because the
    -- failure looks exactly like a regression in the move.
    local idle = action(A.p1_proc) == 0x303
    if rel > 120 and rel % 90 == 0 and not caught and atk_start == 0
       and in_range and idle then
      attempts = attempts + 1
      atk_start = frame
      base_y = objy(A.p2_obj)
      hp_before = r16(A.p2_bar)
      log("attempt %d at rel=%d  dist=%d  p2_y=%d hp=%d",
          attempts, rel, math.abs(objx(A.p1_obj)-objx(A.p2_obj)), base_y, hp_before)
    end
    -- B, D, B then HK, one tick apart with a gap - MK2 has no input buffer,
    -- so each press has to land on its own tick.
    if atk_start > 0 then
      local t = frame - atk_start
      -- Each hold() call unconditionally sets the field EVERY tick it runs,
      -- so a window that never re-asserts "false" once it has passed leaves
      -- the button stuck held forever - which is exactly what the old
      -- `if t>=10 and t<13 then hold(LEFT,true) end` did: nothing ever set
      -- LEFT back to false after t=13, so every later attempt inherited a
      -- permanently-held Left and read as Reptile's own dive-kick/angle-jump
      -- input instead of the B,D,B combo.  Every window below is now an
      -- explicit boolean evaluated fresh every tick, matching the other
      -- three lines that were already correct.
      -- Widened well past MK2's documented 3-tick accept window (see
      -- reference_mk2_input_timing.md) - the goal here is to prove the GAME
      -- LOGIC works, not to hit a frame-perfect input in a scripted rig, and
      -- a too-tight script is indistinguishable from a real miss in the log.
      -- TIGHTENED 2026-09-02.  The old spacing ran Back..HK across 28 ticks
      -- against scom_ermac_tks's 32-tick window - inside it on paper, and it
      -- never once fired.  The fireball rig lands its D,B+LP inside 12 ticks
      -- and matches every time; MK2 measures the window across the whole
      -- motion, so "within the budget" is not the same as "comfortably
      -- inside it".  This is 18 ticks, with the last Back held through the
      -- button the way a human holds it.
      hold(LEFT,  (t>=0 and t<4) or (t>=8 and t<18))
      hold(DOWN,  t>=4 and t<8)
      hold(RIGHT, false)
      -- TKS_NOHK=1 runs the stick motion with NO button, to separate "the
      -- duck recovery stalls" from "the HK press stalls it".
      -- HK at t=22, NOT t=12.  Measured with TKS_NOHK=1: the D in B,D,B makes
      -- him physically duck (act_duck at t=12) and the stand-up runs to t=19,
      -- with act_stance back at t=20.  A button pressed inside that stand-up
      -- does not just get discarded - it WEDGES him in act_backup, which is
      -- what every previous run of this rig was actually recording.  The whole
      -- motion still closes at t=26, inside scom_ermac_tks's 32-tick window.
      hold(HK,    (not NOHK) and t>=22 and t<26)
      -- P2 blocks for the whole attempt when TKS_BLOCK=1.  Held from before
      -- the windup starts so there is no timing question about whether he got
      -- the block up in time - if the grab still connects with this held, it
      -- is genuinely unblockable.
      hold(P2BLK, BLOCKMODE)
      -- Held every tick up to the catch: back_to_normal clears p_hit whenever
      -- the victim settles, so a single poke at the top of the attempt is
      -- gone again long before the grab box goes live.
      if CLOCK and not caught and A.cmb_hits and A.cmb_tick then
        local q = r32(A.p2_proc)
        if q ~= 0 then w16(q + P_HIT, 1) end
        w16(A.cmb_hits, 1)
        w16(A.cmb_tick, 0x40)
      end
      -- unconditional diagnostics for attempt #1 only - trace the whole
      -- windup+active-window regardless of whether it ever fires
      if attempts == 1 and t <= 50 then
        log("  diag t=%2d act=%#x p2act=%#x dbg=%d dist=%d", t, action(A.p1_proc), action(A.p2_proc),
            r16(A.dbg), math.abs(objx(A.p1_obj)-objx(A.p2_obj)))
      end
    end

    local act = action(A.p1_proc)
    if act == ACT_TKS and not fired then
      fired = true
      log("FIRED at rel=%d (p1_action=%#x)  dist=%d", frame-fight, act, dnow)
    end

    -- The victim's height IS the move.  Trace it for the whole attempt and
    -- record where the arcade's three phases show up:
    --   shake-up   ~2px/tick with a +-3px jitter, 16 ticks
    --   zoom       accelerating upward, off the top of the screen
    --   slam       accelerating back down to p_ganiy
    -- then the bounce, which is r_orb's flight and lands him on his back.
    if atk_start > 0 and base_y and not ended then
      local t  = frame - atk_start
      local dy = base_y - objy(A.p2_obj)
      if dy > lifted then lifted = dy end
      if dy > 20 and not caught then
        caught = true
        log("CAUGHT at t=%d (victim left the ground, dy=%d)", t, dy)
      end
      if caught then
        -- THE COMBO CLOCK.  cmb_tick is one word a player indexed by the
        -- ATTACKER, so P1's string is the first slot; cmb_lifted is indexed
        -- by the VICTIM, so P2's is the second (+16 bits).  The catch itself
        -- is a clean hit with damage 0, so hud_combo_hit arms the clock to
        -- hudcmb_hold (040h) the tick the grab connects - and the victim is
        -- then off his feet for ~85 ticks, which is longer than the window.
        -- Before r_ermac_teleslam raised cmb_lifted the window closed with
        -- him still in the air and the hit that followed him down opened a
        -- fresh string.
        local ctick = A.cmb_tick and r16(A.cmb_tick) or -1
        local clift = A.cmb_lifted and r16(A.cmb_lifted+16) or -1
        if dy <= 2 and land_t == nil then
          land_t, land_tick = t, ctick
          log("  FEET DOWN at t=%d  cmb_tick=%d  cmb_lifted=%d", t, ctick, clift)
        end
        if clift ~= 0 then lift_seen = true end
        log("  t=%3d  p2_y=%4d  dy=%4d  p1act=%#x p2act=%#x cmbt=%d cmbl=%d", t,
            objy(A.p2_obj), dy, act, action(A.p2_proc), ctick, clift)
        if SNAP > 0 and t % SNAP == 0 then manager.machine.video:snapshot() end
      end

      -- Attempt over?  Two ways out: he was caught and the whole sequence has
      -- run, or he was not and the windup+recovery finished.  A whiff simply
      -- re-arms - it is a legitimate outcome of a 100px-deep dead zone, not a
      -- failure of the move.
      if caught then
        -- FOLLOW THE VICTIM, NOT THE ATTACKER.  Since the rewrite the slam is
        -- the victim's REACTION and Ermac's own routine finishes long before
        -- it does - measured, his action leaves 011bh at t=50 while the victim
        -- has only reached the top of the shake-up.  Keying the end on the
        -- attacker (which is what this did) stopped the trace 30px in and
        -- scored a working move as a 30px hover.
        -- ...and all the way to the END of the reaction, not just to the
        -- floor: the impact is followed by the bounce (r_orb's own flight
        -- through a_banged) and then land_on_my_back, and stopping at dy<=2
        -- would cut the trace off before either.
        if action(A.p2_proc) ~= 0x503 and t > 60 then
          ended = true
          hp_after = r16(A.p2_bar)
          log("ENDED at rel=%d (t=%d)  peak lift=%dpx  hp %d -> %d",
              frame-fight, t, lifted, hp_before, hp_after)
        end
      elseif t > 90 and act ~= ACT_TKS then
        log("attempt %d WHIFFED (no catch) - re-arming", attempts)
        atk_start, base_y = 0, nil
        land_t, land_tick, lift_seen = nil, nil, false
        for _,n in ipairs({LEFT,RIGHT,DOWN,HK}) do hold(n,false) end
      end
    end

    if ended and not done then
      done = true
      -- The arcade sequence takes the victim off the top of a 254px screen.
      -- 150px of lift is a floor, not a target: anything less means the zoom
      -- phase (negative gravity) is not running and we are back to the parked
      -- hover the first port produced.
      -- ...and the combo window has to still be open when he lands.  The
      -- clock is PAUSED, not re-armed, so a pass reads as very close to the
      -- full 040h: the catch armed it and nothing has been allowed to spend
      -- it while he was in the air.
      -- NEAR FULL, not merely non-zero.  The flight is ~35 ticks against a
      -- 040h window, so an unpaused clock still has ~29 left when he lands
      -- and "> 0" would pass with the hold removed.  Measured with it in:
      -- 63 of 64, the single tick spent on the frame the flag came down.
      local clock_ok = (land_tick or 0) >= 0x38 and lift_seen
      local ok = caught and (lifted > 150) and (hp_after < hp_before) and clock_ok
      log("%s ermac_teleslam: fired=%s caught=%s lift=%dpx damage=%d attempts=%d clock=%d@t%s held=%s",
          ok and "PASS" or "FAIL", tostring(fired), tostring(caught), lifted,
          (hp_before or 0) - (hp_after or 0), attempts,
          land_tick or -1, tostring(land_t), tostring(lift_seen))
      log("finished"); manager.machine:exit()
    end
    if not done and rel > 2400 then
      done = true
      log("FAIL ermac_teleslam: fired=%s caught=%s lift=%dpx attempts=%d p1_action=%#x",
          tostring(fired), tostring(caught), lifted, attempts, action(A.p1_proc))
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 6000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
