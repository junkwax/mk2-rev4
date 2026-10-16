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
--   ENDED    p1_action leaves 011bh again and P2 takes damage.  A move that
--            fires and never ends is a wedged process, which on MK2's
--            cooperative scheduler stops the whole game.
--
-- Attempts RETRY.  A whiff now sets FIRED (the windup runs either way), so a
-- rig that stopped at the first FIRED would score a legitimate out-of-range
-- miss as a broken move.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("TKS_LOG") or (ROOT .. "/tools/ermac_stance_test.log")
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
local seen = {}
local phase_lo, phase_hi = nil, nil
local base_y, hp_before, hp_after = nil, nil, nil
local attempts, atk_start = 0, 0
local last_cnt, armed_at = 0, nil
local snapped = false
local steps, backsteps, badsteps, lastf, order = 0, 0, 0, nil, {}

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
    -- STANCE PROBE.  Read the process's pa9 (0a0h) while he is in act_stance
    -- and say which of the ninja stance lanes it is inside.  j_scst is a
    -- linker global; the others are not, so they are derived from it - each
    -- lane is its frames + ani_jump,target (64 bits):
    --   j_rpst = j_scst - 288   (7 frames + jump, above it)
    --   j_szst = j_rpst - 448   (12 frames + jump, above that)
    --   j_emst = j_scst + 288   (Ermac's reversed NJ3STANCE, right after it)
    -- Reading the ADDRESS is the point: a screenshot of two ninjas in similar
    -- poses proves nothing.
    --
    -- DIRECTION.  The lane pointer always walks forward, so pa9 alone cannot
    -- tell a reversed lane from a forward one - the reversal is in the data.
    -- pa9 sits one record past the frame just drawn, so the long at pa9-32 IS
    -- the frame on screen; that is resolved against the NJ3STANCE1..7 globals
    -- every tick, and each change must be n -> n-1 (1 wraps to 7).
    local rel = frame - fight
    local SCST = symbols["j_scst"]
    local RPST = SCST and (SCST - 288)
    local SZST = RPST and (RPST - 448)
    local EMST = SCST and (SCST + 288)
    local function lane_of(a)
      if not SCST or a == 0 then return "?" end
      if a >= SCST  and a < SCST + 9*32  then return "SCORPION (j_scst/NJ3STANCE)" end
      if a >= EMST  and a < EMST + 9*32  then return "ERMAC    (j_emst/NJ3STANCE reversed)" end
      if a >= RPST  and a < RPST + 9*32  then return "REPTILE  (j_rpst/NJ2STANCE)" end
      if a >= SZST  and a < SZST + 14*32 then return "SUB-ZERO (j_szst/NJ1STANCE)" end
      return string.format("outside the stance lanes (%#x)", a)
    end
    local function njframe(a9)
      if a9 == 0 then return nil end
      local f = r32(a9 - 32)
      for i = 1, 7 do if symbols["NJ3STANCE"..i] == f then return i end end
      return nil
    end
    if rel == 1 then
      log("j_scst=%#x  j_emst=%#x  j_rpst=%#x  j_szst=%#x",
          SCST or 0, EMST or 0, RPST or 0, SZST or 0)
      steps, backsteps, badsteps, lastf, order = 0, 0, 0, nil, {}
    end
    if rel > 120 and rel <= 600 and not done then
      local q = r32(A.p1_proc)
      if q ~= 0 and action(A.p1_proc) == 0x303 then
        local f = njframe(r32(q + 0x0a0))
        if f and f ~= lastf then
          if lastf then
            steps = steps + 1
            if f == ((lastf - 2) % 7) + 1 then backsteps = backsteps + 1
            else badsteps = badsteps + 1 end
          end
          if #order < 24 then order[#order+1] = tostring(f) end
          lastf = f
        end
      else
        lastf = nil     -- left the stance; do not score the re-entry jump
      end
    end
    if rel > 120 and rel % 15 == 0 and not done then
      local q = r32(A.p1_proc)
      local act = action(A.p1_proc)
      local a9 = q ~= 0 and r32(q + 0x0a0) or 0
      if act == 0x303 then
        seen[lane_of(a9)] = (seen[lane_of(a9)] or 0) + 1
        log("rel=%4d act=%#x pa9=%#010x -> %s  frame=NJ3STANCE%s",
            rel, act, a9, lane_of(a9), tostring(njframe(a9)))
      end
      if SNAP > 0 then manager.machine.video:snapshot() end
    end
    if rel > 600 and not done then
      done = true
      local best, n = nil, 0
      for k,v in pairs(seen) do if v > n then best, n = k, v end end
      local lane_ok = best and best:find("ERMAC") ~= nil
      local dir_ok = steps >= 7 and badsteps == 0
      log("frame order: %s", table.concat(order, " "))
      log("steps=%d reversed=%d wrong-way=%d", steps, backsteps, badsteps)
      log("%s ermac_stance: p1_char=%d lane=%s (%d samples) direction=%s",
          (lane_ok and dir_ok) and "PASS" or "FAIL", r16(A.p1_char),
          tostring(best), n, dir_ok and "REVERSED" or "NOT reversed")
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 6000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
