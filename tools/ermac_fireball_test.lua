-- ermac_fireball_test.lua
-- Unlock Ermac (Reptile + Block x5), get into a fight, then input Down,Back + LP
-- and check his FIREBALL fires, spawns Shao Kahn's green bolt, carries it across
-- the screen and takes 20 off the other guy.
--
-- Boot/select/cheat handling is ermac_teleport_test.lua's, unchanged: it is the
-- only thing in the tree that reliably gets a human Ermac into a fight, and the
-- comments there explain every one of its non-obvious moves (feedback-driven
-- Block presses, latch on armed_at not on `pending`, clear the Start holds every
-- frame).  Only the attack and the measurements below are new.
--
-- What each result actually proves, because they fail differently:
--   FIRED    p1_action reaches act_ermac_zap (017h).  If it never does, the
--            combo, char_lo_punch[17] or the projectile_jumps slot is wrong -
--            not the move.  Reptile's B,B forceball reaching instead shows up
--            here as act_slow_orb (013h), which is the collision this move was
--            specifically built to avoid.
--   SPAWNED  a new object exists after the throw that is neither fighter.  It
--            is matched by IDENTITY, not geometry: the projectile is multipart
--            and its root object carries size and SAG of zero, so there is
--            nothing there to match art against.
--   TRAVEL   the bolt gets at least 60px from where it was born, in the
--            direction he is facing.  A projectile that spawns and sits still
--            is set_proj_vel never running; one that goes backwards is the
--            facing sign being wrong.
--   HIT      p2's bar drops.  This is the only thing that tests the strike
--            record actually being reachable - tell_world_stk, strike index
--            022h and stk_ermac_zap all have to be right for it.
--   DAMAGE   ...and it drops by 20, not Kahn's 40.  The whole point of the new
--            record is that it is not his.
--   ENDED    p1_action leaves 017h.  A move that fires and never ends is a
--            wedged process, which on MK2's cooperative scheduler stops the
--            whole game.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("FB_LOG") or (ROOT .. "/tools/ermac_fireball_test.log")
local SNAP = tonumber(os.getenv("FB_SNAP") or "0")
local DUMP = (os.getenv("FB_DUMP") or "0") ~= "0"
local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[fb] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) return symbols[n] end

-- The starburst's own geometry, read out of the table the ROM was built from.
-- Kept for the log even though the match below no longer leans on it: the
-- projectile is a MULTIPART object and its ROOT carries osizex/osizey/osag of
-- ZERO (the pieces hold the art), so matching the root against frame geometry
-- can never hit.  That cost a whole run to discover - the move was firing and
-- landing while the rig reported spawned=false.
local bolt_n = 0
do
  local fh = io.open(ROOT.."/src/ERMFIRE.TBL","r")
  if fh then
    for line in fh:lines() do
      if line:match("^ERMFIRE%d+:") then bolt_n = bolt_n + 1 end
    end
    fh:close()
  end
end

local A = { gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
            cheatc=sym("c_ermac_cheat1"), cheatf=sym("f_ermac_cheat1"),
            p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
            p1_obj=sym("p1_obj"),  p2_obj=sym("p2_obj"),
            p1_bar=sym("p1_bar"),  p2_bar=sym("p2_bar"),
            objlst=sym("objlst"),  ground_y=sym("ground_y") }
local P_ACTION = 0x1f0
local OLINK, OXPOS, OYPOS, OFLAGS, OSAG, OSIZEX, OSIZEY = 0, 0x090, 0x0b0, 0x0f0, 0x100, 0x120, 0x130
local GS_PSEL, GS_FIGHT = 4, 2
local FT_REPTILE, FT_ERMAC, FT_JAX = 9, 17, 11
local ACT_ERMAC_ZAP = 0x017           -- MAINEQU.ASM
local ACT_SLOW_ORB  = 0x013           -- Reptile's forceball - the near miss
local BLOCKP2 = (os.getenv("FB_BLOCK") or "0") ~= "0"
local WANT_DAMAGE   = BLOCKP2 and 3 or 20   -- stk_ermac_zap hit / block byte
local B_FLIPH = 4                     -- oflags bit 4; set = facing LEFT

-- SOUND.  The throw fires ERMACSHOT, the clip staged on the dead OLDRIP
-- triple ($00D0-$00D2) and wired as triple_sndtab index 10dh - see
-- do_ermac_zap (MKZAP.ASM) and sound/stlaugh_patch.txt note (26).  The rig
-- taps the hardware latch rather than listening, the way
-- kahn_fatality_audio_probe.lua does: send_code_a3 writes a track as two
-- consecutive 16-bit hits on @sound, each byte OR'd with 0ff00h.  The run
-- has -sound none, which does not matter - the game still writes the latch.
--
-- WHICH of the three codes arrives is triple_sound's channel choice, not a
-- property of the move, so any of $00D0/$00D1/$00D2 passes.  Seeing $01C5
-- instead means the build still has the borrowed `tsound 06ah` (subzero
-- throw ice) that stood in before the slot was wired.
local SND_PORT   = 0x01d01030
local TAP_LO, TAP_HI = 0x01d00000, 0x01d01fff
local SND_SHOT   = { [0x00d0]=1, [0x00d1]=2, [0x00d2]=3 }
local SND_ICE    = 0x01c5            -- the stand-in this replaced
local snd_tap, snd_hi = nil, nil
-- FB_SNDTRACE=1 logs EVERY track the game sends, not just this move's.  A
-- run that reports sound=NONE cannot tell "the move sent nothing" apart
-- from "the tap saw nothing"; the trace separates them in one run.
local SNDTRACE = (os.getenv("FB_SNDTRACE") or "0") ~= "0"
local snd_seen = 0

local space, fields = nil, {}
local frame, psel, fight = 0, 0, 0
local held = {}
local function hold(n,on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function action(procptr) local q=r32(procptr); return q~=0 and r16(q+P_ACTION) or 0xffff end
local function objx(objptr) local o=r32(objptr); return o~=0 and s16(r16(o+OXPOS)) or 0 end
local function facing_left() local o=r32(A.p1_obj); if o==0 then return false end
  return (r16(o+OFLAGS) >> B_FLIPH) & 1 == 1 end

-- objlst is a 32-bit head pointer (RAM.ASM); each object's olink at offset 0
-- is the next, terminated by 0.  Bounded so a corrupt list cannot hang the rig.
local function objset()
  local out, p, n = {}, r32(A.objlst), 0
  while p ~= 0 and n < 200 do out[p] = true; p = r32(p+OLINK); n = n + 1 end
  return out
end

-- Find the fireball: the object that was NOT on the list when the throw
-- started and is neither fighter.  Identity, not geometry - see the note above
-- about the multipart root being all zeroes.
local before = {}
local function find_bolt()
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  local p, n = r32(A.objlst), 0
  while p ~= 0 and n < 200 do
    if not before[p] and p ~= p1o and p ~= p2o then
      return s16(r16(p+OXPOS)), r16(p+OSIZEX), r16(p+OSIZEY)
    end
    p = r32(p+OLINK); n = n + 1
  end
  return nil
end

local BLK="P1 Block"; local LP="P1 Low Punch"; local HP="P1 High Punch"
local LEFT="P1 Left"; local RIGHT="P1 Right"; local DOWN="P1 Down"; local UP="P1 Up"
-- P2 is a SECOND HUMAN standing still, for ermac_teleslam_test.lua's reason: a
-- drone walks, blocks and attacks, and a fireball then lands or not depending on
-- what the AI was doing - which reads in the log exactly like the move being
-- broken.  A still human also cannot block, so HIT means a clean 20.
local P2LP="P2 Low Punch"; local P2BLK="P2 Block"
local TWOP = (os.getenv("FB_2P") or "1") ~= "0"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,
              ["2 Players Start"]=1,["UI Select"]=1,
              [BLK]=1,[LP]=1,[HP]=1,[LEFT]=1,[RIGHT]=1,[DOWN]=1,[UP]=1,[P2LP]=1,[P2BLK]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

local done = false
local last_cnt, armed_at = 0, nil
local attempts, atk_start = 0, 0
-- FB_SHOTS: how many fireballs must land before the run passes.  Default 1
-- keeps the quick check quick; the REGRESSION value is 4, because the palette
-- bug this rig missed for a whole session only shows on the SECOND throw - the
-- first one allocates fine and the pool damage is invisible until the next
-- getfpal.  One shot can never see it.
local WANT_SHOTS = tonumber(os.getenv("FB_SHOTS") or "1")
local shots = 0
local MAX_TRIES = 4 + WANT_SHOTS * 2
local R = { fired=false, spawned=false, travelled=false, hit=false, ended=false,
            wrong_move=nil, bolt_x0=nil, bolt_dx=nil, dmg=nil, bar0=nil,
            snd=nil, snd_ice=false }
local cur = nil

-- Latch tap.  Bytes arrive one per write and pair up into a track number;
-- anything that is not the 0ff00h-tagged shape is a reset/strobe and
-- re-locks the parity, exactly as the fatality probe does.
local function on_sound_write(offset, data, mask)
  if offset ~= SND_PORT then return data end
  local w = data & 0xffff
  if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
  -- PARITY.  The bytes are a stream, and sndres leaves an odd one in it at
  -- boot ($ff at frame ~58 here), so blind pairing is a byte out for the
  -- whole run - which reads as "the move sent nothing".  Re-lock the way
  -- tools/decode_sound_trace.py does: a real MK2 track is $0000-$04ff, so a
  -- HIGH byte is always <= 7 and anything bigger cannot start a pair.
  if snd_hi == nil then
    if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
    return data
  end
  local code = (snd_hi << 8) | (w & 0xff)
  snd_hi = nil
  if SNDTRACE and snd_seen < 400 then
    snd_seen = snd_seen + 1
    log("  [snd] frame=%d atk_t=%s SEND $%04x", frame,
        atk_start > 0 and tostring(frame - atk_start) or "-", code)
  end
  if atk_start > 0 and cur then
    local t = frame - atk_start
    if SND_SHOT[code] then
      if not cur.snd then
        cur.snd = code
        log("  SOUND at t=%d  SEND $%04x (ERMACSHOT, channel %d)", t, code, SND_SHOT[code])
      end
    elseif code == SND_ICE then
      cur.snd_ice = true
      log("  SOUND at t=%d  SEND $%04x - the OLD borrowed ice cast, not ERMACSHOT", t, code)
    end
  end
  return data
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    local ok, err = pcall(function()
      snd_tap = space:install_write_tap(TAP_LO, TAP_HI, "fbsnd", on_sound_write)
    end)
    log("sound latch tap %s", (ok and snd_tap) and "installed" or ("FAILED: " .. tostring(err)))
    log("act_ermac_zap=%#x  ERMFIRE frames known=%d  objlst=%#x",
        ACT_ERMAC_ZAP, bolt_n, A.objlst or 0)
    if bolt_n ~= 11 then log("WARNING: expected 11 ERMFIRE frames, parsed %d", bolt_n) end
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
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start"}) do
      hold(n,false)
    end
    -- ARMING THE UNLOCK.
    --
    -- The five Block presses do NOT arm under this harness, and that is not
    -- something this move introduced: every committed Ermac rig log in the
    -- tree (teleslam, teleport) shows the same `p1_char=9` with the press
    -- counter never moving once.  check_ermac_blk_cheat gates on the SELECT
    -- CURSOR via *a13(p_mychar), which a rig poking @p1_char does not move.
    --
    -- So drive the game's own pending flag instead.  f_ermac_cheat1 is the
    -- exact variable check_ermac_blk_cheat sets on the fifth press, and
    -- ermac_select_cheat_apply (MAIN.ASM:437) is what turns it into ft_ermac
    -- before vs_screen.  The unlock path under test is therefore still the
    -- real one - only the five button presses are skipped.
    --
    -- BOTH have to be held all the way to the end of the select screen.  The
    -- first cut latched on the flag and stopped pinning the cursor, and the
    -- pick promptly drifted off Reptile and confirmed as somebody else - the
    -- apply had already fired and been overwritten.  Pin the cursor and
    -- re-arm every frame, and let go only once select is over, so the
    -- override is the last write to p1_char.
    if gs == GS_PSEL then
      w16(A.p1_char, FT_REPTILE)
      w16(A.cheatf, 1)
      if not armed_at then armed_at = frame; log("  cheat ARMED at frame %d", frame) end
      hold(BLK, false)
      hold(LP, ((frame - armed_at) % 16) < 6)
      if TWOP then
        w16(A.p2_char, FT_JAX)
        hold(P2LP, ((frame - armed_at) % 12) < 5)
      end
    else
      hold(BLK, false); hold(LP, false); hold(P2LP, false)
    end
    if gs == GS_FIGHT then
      fight = frame; hold(LP,false)
      log("fight at frame %d, p1_char=%d (17 = Ermac)", frame, r16(A.p1_char))
    end
  else
    local rel = frame - fight

    if rel > 120 and rel % 130 == 0 and atk_start == 0 and attempts < MAX_TRIES
       and shots < WANT_SHOTS then
      attempts = attempts + 1
      cur = R
      atk_start = frame
      -- Reset the per-shot record so shot N is judged on its own merits.
      R.fired, R.spawned, R.travelled, R.hit, R.ended = false,false,false,false,false
      R.bolt_x0, R.bolt_dx, R.dmg = nil, nil, nil
      R.snd, R.snd_ice = nil, false
      R.bar0 = r16(A.p2_bar)
      before = objset()          -- anything already on the list is not the bolt
      log("attempt #%d at rel=%d  p1x=%d p2x=%d p2bar=%d p1act=%#x p2act=%#x facing=%s",
          attempts, rel, objx(A.p1_obj), objx(A.p2_obj), R.bar0,
          action(A.p1_proc), action(A.p2_proc),
          facing_left() and "left" or "right")
    end

    -- FB_BLOCK=1: P2 holds Block for the whole round.  The impact burst must
    -- appear on a BLOCK as well as a clean hit - strike_check_a0 returns carry
    -- for both and only b2 distinguishes them, and the hit path deliberately
    -- never reads b2.  Damage should drop to the chip byte (3), not 20.
    hold(P2BLK, BLOCKP2)

    if atk_start > 0 then
      local t = frame - atk_start
      -- Back is a DIRECTION, not a button: it is Left while he faces right and
      -- Right if the sides ever swap.  Read the live facing rather than assume.
      local back = facing_left() and RIGHT or LEFT
      local fwd  = facing_left() and LEFT  or RIGHT
      -- scom_decoy's window is 010h - SIXTEEN ticks for the whole motion.  Down,
      -- Back and the button all have to land inside it, so this spacing is
      -- deliberately tight; there is no room to be generous.
      hold(DOWN, t < 4)
      hold(back, t>=5 and t<14)     -- held through the button, as a human does
      hold(fwd,  false)
      hold(LP,   t>=8 and t<12)

      local act = action(A.p1_proc)
      if act == ACT_ERMAC_ZAP and not cur.fired then
        cur.fired = true
        log("  FIRED at t=%d (p1_action=%#x)", t, act)
      end
      -- The near miss worth naming: if Reptile's forceball comes out instead,
      -- say so rather than just reporting "not fired".
      if act == ACT_SLOW_ORB and not cur.wrong_move then
        cur.wrong_move = act
        log("  WRONG MOVE at t=%d: act_slow_orb (%#x) - Reptile's forceball", t, act)
      end

      -- Heartbeat OUTSIDE the fired branch.  A move that never fires and a
      -- fighter that is not running at all read identically in a log that only
      -- talks once it has fired, and those are completely different bugs.
      if t % 10 == 0 then
        log("    t=%3d act=%#x p1x=%4d bolt=%s", t, act, objx(A.p1_obj),
            find_bolt() and "yes" or "-")
      end

      -- One-shot object dump while the bolt should be in the air, so a failed
      -- match can be read rather than guessed at.
      if DUMP and cur.fired and t >= 14 and t <= 26 then
        local p, n = r32(A.objlst), 0
        local parts = {}
        while p ~= 0 and n < 60 do
          parts[#parts+1] = string.format("%dx%d@%d/sag=%x",
            r16(p+OSIZEX), r16(p+OSIZEY), s16(r16(p+OXPOS)), r32(p+OSAG))
          p = r32(p+OLINK); n = n + 1
        end
        log("    OBJDUMP t=%d n=%d: %s", t, n, table.concat(parts, "  "))
      end

      if cur.fired then
        local bx, bw, bh = find_bolt()
        if bx and not cur.spawned then
          cur.spawned = true
          cur.bolt_x0 = bx
          log("  SPAWNED at t=%d  bolt_x=%d (%dx%d)", t, bx, bw, bh)
        end
        if bx and cur.bolt_x0 and not cur.travelled then
          local dx = bx - cur.bolt_x0
          -- "Forward" means the way he is facing, so the sign follows facing.
          local fwd_dx = facing_left() and -dx or dx
          if fwd_dx > 60 then
            cur.travelled = true; cur.bolt_dx = dx
            log("  TRAVEL at t=%d  dx=%+d (%d px forward)", t, dx, fwd_dx)
          end
        end
        local bar = r16(A.p2_bar)
        if cur.bar0 and bar < cur.bar0 and not cur.hit then
          cur.hit = true; cur.dmg = cur.bar0 - bar
          log("  HIT at t=%d  p2 bar %d -> %d  (-%d)", t, cur.bar0, bar, cur.dmg)
        end
        if t % 6 == 0 then
          log("    t=%3d act=%#x p1x=%4d p2x=%4d bolt=%s bar=%d", t, act,
              objx(A.p1_obj), objx(A.p2_obj), bx and tostring(bx) or "-", bar)
        end
        if SNAP > 0 and t % SNAP == 0 then manager.machine.video:snapshot() end
        if act ~= ACT_ERMAC_ZAP and t > 20 and not cur.ended then
          cur.ended = true
          log("  ENDED at t=%d  spawned=%s travelled=%s hit=%s",
              tostring(t), tostring(cur.spawned), tostring(cur.travelled),
              tostring(cur.hit))
        end
      end

      -- Close the attempt out: release everything and wait for the next slot.
      if t > 118 then
        for _,n in ipairs({UP,DOWN,LEFT,RIGHT,LP}) do hold(n,false) end
        if not cur.fired then log("  no fire on this attempt (t=%d)", t) end
        atk_start, cur = 0, nil
      end
    end

    -- Bank a completed shot, then let the next attempt start.
    if atk_start == 0 and cur == nil and R.hit and R.ended and not R.banked then
      R.banked = true
      shots = shots + 1
      log("shot %d of %d landed (dmg=%s)", shots, WANT_SHOTS, tostring(R.dmg))
      if shots < WANT_SHOTS then R.banked = false; R.hit = false; R.ended = false end
    end

    local finished = (shots >= WANT_SHOTS) or attempts >= MAX_TRIES
    if finished and atk_start == 0 and not done then
      done = true
      local ok = shots >= WANT_SHOTS and R.spawned and R.travelled
                 and R.dmg == WANT_DAMAGE and R.snd ~= nil
      log("fired=%s spawned=%s travelled=%s (dx=%s) hit=%s dmg=%s (want %d) ended=%s sound=%s",
          tostring(R.fired), tostring(R.spawned), tostring(R.travelled),
          tostring(R.bolt_dx), tostring(R.hit), tostring(R.dmg), WANT_DAMAGE,
          tostring(R.ended), R.snd and string.format("$%04x", R.snd) or "NONE")
      if R.snd_ice then log("NOTE: $01c5 (subzero throw ice) was sent - this build still has tsound 06ah") end
      if R.wrong_move then log("NOTE: act_slow_orb was seen - check ermac_lo_punch order") end
      log("shots landed: %d of %d", shots, WANT_SHOTS)
      log("%s ermac_fireball", ok and "PASS" or "FAIL")
      log("finished"); manager.machine:exit()
    end
    -- Backstop: a rig that runs out of attempts without a verdict must SAY so.
    -- Silence here is indistinguishable from the move hanging the game.
    if not done and rel > 2600 then
      done = true
      log("fired=%s spawned=%s travelled=%s hit=%s dmg=%s ended=%s",
          tostring(R.fired), tostring(R.spawned), tostring(R.travelled),
          tostring(R.hit), tostring(R.dmg), tostring(R.ended))
      log("FAIL ermac_fireball: out of attempts (%d) p1_action=%#x",
          attempts, action(A.p1_proc))
      log("finished"); manager.machine:exit()
    end
  end

  -- Every cached field is driven EVERY frame, not just the ones in `held`:
  -- a window that stops re-asserting false leaves its button stuck down for
  -- the rest of the run, which reads in the log as the wrong move firing.
  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 6000 then log("FAIL ermac_fireball: timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
