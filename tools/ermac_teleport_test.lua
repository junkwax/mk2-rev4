-- ermac_teleport_test.lua
-- Unlock Ermac (Reptile + Block x5), get into a fight, then input Down,Back + HP
-- and check Scorpion's teleport punch runs for him - with Reptile's poof in
-- front of him on a GROUND teleport and no poof on an AIR one.
--
-- Boot/select/cheat handling is ermac_teleslam_test.lua's, unchanged: it is the
-- only thing in the tree that reliably gets a human Ermac into a fight, and the
-- comments there explain every one of its non-obvious moves (feedback-driven
-- Block presses, latch on armed_at not on `pending`, clear the Start holds every
-- frame).  Only the attack and the measurements below are new.
--
-- What each result actually proves, because they fail differently:
--   FIRED    p1_action reaches act_decoy (020ah).  If it never does, the combo,
--            char_hi_punch[17] or the propell slot is wrong - not the move.
--   POOF     an object carrying a babality-cloud frame (scorpfire*) exists
--            during the takeoff.  This is the whole point of the ground
--            case.  Matched on the art's OWN geometry read out of
--            src/MKFX.TBL, so it cannot drift with a repack; a snapshot
--            would only prove that something was drawn.
--   AHEAD    that cloud sits on the side Ermac is FACING.  "A cloud
--            happened" is not the request - baby_poof already centres one on
--            its subject.  This is the half that tests erm_poof_fwd.
--   CROSSED  p1 ends up on the other side of p2.  do_decoy that fires and does
--            not warp is the corner/oxvel failure documented in MKPROP.ASM.
--   ENDED    p1_action leaves 020ah.  A move that fires and never ends is a
--            wedged process, which on MK2's cooperative scheduler stops the
--            whole game.
--   HIDDEN   m_inviso is set during the flight, so he is gone from launch
--            until he arrives on the far side.  BOTH cases - only the cloud
--            is ground-only.
--   STUCK    m_inviso is STILL set 20 ticks after the move ended.  This is
--            the one that matters: an invisible fighter for the rest of the
--            round, with nothing on screen to explain it.  ermac_tele_watch
--            exists to make it impossible; this proves it.
--   AIRDRY   the air teleport fires and produces NO poof.  Ground-only is the
--            spec; if the am_i_airborn test in do_ermac_decoy is inverted or
--            missing this is what catches it.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("TP_LOG") or (ROOT .. "/tools/ermac_teleport_test.log")
local SNAP = tonumber(os.getenv("TP_SNAP") or "3")
local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[tp] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) return symbols[n] end

-- The cloud's own geometry, read out of the table the ROM was built from.
-- The poof is the BABALITY cloud now, not Reptile's NJBIGPOOF: a mirrored
-- pair of a_scorpion_flame multiparts, whose pieces are scorpfire1-12.  Each
-- frame is a different size (11x15 up to 66x167), so the set of (w,h) pairs
-- identifies it, and osag pins it exactly on the frames before `ani` has had
-- a chance to touch anything.
--
-- Matching the ART rather than a label is the point: it survives a repack,
-- and it is the only way to tell a real cloud from "something was drawn".

-- m_inviso is a .set in DISPEQU.ASM, so read it rather than hardcode a bit.
-- A wrong constant here reports "he is visible" for a hidden fighter, which
-- is the exact failure this check exists to catch - so declare it HERE, above
-- the block that fills it.  A `local' after the assignment would shadow it
-- with nil and the check would quietly pass forever.
local M_INVISO = nil
do
  local fh = io.open(ROOT.."/src/DISPEQU.ASM","r")
  if fh then
    for line in fh:lines() do
      local v = line:match("^m_inviso%s+%.set%s+0?(%x+)[hH]")
             or line:match("^m_inviso%s+%.set%s+(%d+)%s*$")
      if v then M_INVISO = tonumber(v, 16) break end
    end
    fh:close()
  end
end

local poof_sag, poof_wh, poof_n = {}, {}, 0
do
  local fh = io.open(ROOT.."/src/MKFX.TBL","r")
  if fh then
    local want = false
    for line in fh:lines() do
      local label = line:match("^(%w+):")
      if label then want = label:match("^scorpfire%d+$") ~= nil end
      if want then
        local w,h = line:match("^%s*%.word%s+(%d+),(%d+),")
        -- Only the BIG frames.  scorpfire1/2 are 11x15 and 23x27, sizes a
        -- blood droplet or a spark shares, and a false POOF is worse than a
        -- missed one here.  Part 2 - the lane this actually animates - is
        -- scorpfire6..12 and every one of those is at least 84 tall, so the
        -- threshold costs nothing and removes the whole ambiguity.
        if w and tonumber(h) >= 60 then
          poof_wh[tonumber(w)*65536 + tonumber(h)] = true; poof_n = poof_n + 1
        end
        local sag = line:match("^%s*%.long%s+0(%x+)[Hh]")
        if sag then poof_sag[tonumber(sag,16)] = true end
      end
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
-- pdata is 100h (MAINEQU.ASM), p_action = pdata+0f0h, p_ganiy = pdata+100h.
-- 0x210 was wrong for p_ganiy - that is pdata+110h - and read back as 1.
local P_ACTION, P_GANIY = 0x1f0, 0x200
local OLINK, OXPOS, OYPOS, OFLAGS, OSAG, OSIZEX, OSIZEY = 0, 0x090, 0x0b0, 0x0f0, 0x100, 0x120, 0x130
local OFLAGS2 = 0x160             -- 32-bit game flags; m_inviso lives here
local GS_PSEL, GS_FIGHT = 4, 2
local FT_REPTILE, FT_ERMAC, FT_JAX = 9, 17, 11
local ACT_DECOY = 0x20a
local B_FLIPH = 4                 -- oflags bit 4; set = facing LEFT

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
local function facing_left() local o=r32(A.p1_obj); if o==0 then return false end
  return (r16(o+OFLAGS) >> B_FLIPH) & 1 == 1 end
local function inviso() local o=r32(A.p1_obj); if o==0 or not M_INVISO then return false end
  return (r32(o+OFLAGS2) & M_INVISO) ~= 0 end

-- Walk objlst looking for a cloud half.  Returns its x, or nil.  Two objects
-- match once both halves are up; either one answers the question.
-- objlst is a 32-bit head pointer (RAM.ASM); each object's olink at offset 0
-- is the next, terminated by 0.  Bounded so a corrupt list cannot hang the rig.
--
-- THE CLOUD IS A MULTIPART, and a multipart parent carries NO ART: its osag is
-- the null image and its osize is 0x0.  ani2 (MKUTIL.ASM) writes the pieces
-- into the RAM buffer at oimg as 112-bit records - sag(32), size(32),
-- control(16), dx(16), dy(16), zero-terminated - and they are never separate
-- objects on the list.  Reading osize/osag off the list entries therefore
-- matches NOTHING for the cloud, the fighters, or any other multipart: this
-- check reported "no poof" for a poof that was on screen the whole time.
-- Measured: objlst carries 14 entries mid-teleport, 5 of them multiparts with
-- osize 0x0, and expanding them finds both cloud halves on scorpfire6..12.
local OIMG = 0x1a0
local M_MULTIPART = 2                 -- m_multipart, DISPEQU.ASM (oflags2)
local function find_poof()
  local p = r32(A.objlst)
  local n = 0
  while p ~= 0 and n < 200 do
    if (r32(p+OFLAGS2) & M_MULTIPART) ~= 0 then
      local buf = r32(p+OIMG)
      if buf ~= 0 then
        for k = 0, 11 do
          local rec = buf + 112*k
          local sag = r32(rec)
          if sag == 0 then break end
          local w, h = r16(rec+32), r16(rec+48)
          if poof_wh[w*65536 + h] or poof_sag[sag] then
            return s16(r16(p+OXPOS)), w, h
          end
        end
      end
    else
      local w, h = r16(p+OSIZEX), r16(p+OSIZEY)
      if poof_wh[w*65536 + h] or poof_sag[r32(p+OSAG)] then
        return s16(r16(p+OXPOS)), w, h
      end
    end
    p = r32(p+OLINK); n = n + 1
  end
  return nil
end

local BLK="P1 Block"; local LP="P1 Low Punch"; local HP="P1 High Punch"
local LEFT="P1 Left"; local RIGHT="P1 Right"; local DOWN="P1 Down"; local UP="P1 Up"
-- P2 is a SECOND HUMAN standing still, for ermac_teleslam_test.lua's reason: a
-- drone walks and attacks, MK2 discards input while the fighter is busy, and a
-- scripted combo then lands or not depending on what the AI was doing - which
-- reads in the log exactly like the move being broken.
local P2LP="P2 Low Punch"
local TWOP = (os.getenv("TP_2P") or "1") ~= "0"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,
              ["2 Players Start"]=1,["UI Select"]=1,
              [BLK]=1,[LP]=1,[HP]=1,[LEFT]=1,[RIGHT]=1,[DOWN]=1,[UP]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

-- results
local done = false
local last_cnt, armed_at = 0, nil
local attempts, atk_start, air_attack = 0, 0, false
local MAX_GROUND, MAX_AIR = 4, 3
local air_tries = 0
local G = { fired=false, poof=false, ahead=false, crossed=false, ended=false,
            hidden=false, stuck=false, poof_dx=nil, side0=nil,
            shown_at=nil, ended_at=nil }
local V = { fired=false, poof=false, ended=false, hidden=false, stuck=false,
            shown_at=nil, ended_at=nil }
local cur = nil                       -- the record this attempt writes into

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    log("act_decoy=%#x  poof frames known=%d  objlst=%#x", ACT_DECOY, poof_n, A.objlst or 0)
    if poof_n == 0 then log("WARNING: no scorpfire geometry parsed from src/MKFX.TBL") end
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
    -- The five Block presses never armed here: check_ermac_blk_cheat gates on
    -- the select CURSOR via *a13(p_mychar), which poking @p1_char does not
    -- move, so every log this rig ever wrote showed p1_char=9 and a press
    -- counter stuck at 0.  Drive the game's own pending flag instead -
    -- f_ermac_cheat1 is what the fifth press sets, and
    -- ermac_select_cheat_apply (MAIN.ASM) is what turns it into ft_ermac.
    -- Cursor AND flag have to be held to the end of select, or the apply
    -- fires early and the pick drifts off Reptile.
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

    -- Start a new attempt every 110 frames until both cases are answered.
    if rel > 120 and rel % 110 == 0 and atk_start == 0 then
      local ground_left = (not (G.fired and G.ended)) and attempts < MAX_GROUND
      if ground_left then
        attempts, cur, air_attack = attempts + 1, G, false
      elseif not (V.fired and V.ended) and air_tries < MAX_AIR then
        air_tries, cur, air_attack = air_tries + 1, V, true
      end
      if cur then
        atk_start = frame
        cur.side0 = objx(A.p1_obj) - objx(A.p2_obj)
        log("attempt %s#%d at rel=%d  p1x=%d p2x=%d facing=%s",
            air_attack and "AIR " or "GND ",
            air_attack and air_tries or attempts, rel,
            objx(A.p1_obj), objx(A.p2_obj), facing_left() and "left" or "right")
      end
    end

    if atk_start > 0 then
      local t = frame - atk_start
      -- Back is a DIRECTION, not a button: it is Left while he faces right and
      -- Right once the teleport has put him on the other side.  Reading the
      -- live facing rather than assuming "P1 starts on the left" is what makes
      -- attempts 2..4 test the same move as attempt 1.
      local back  = facing_left() and RIGHT or LEFT
      local fwd   = facing_left() and LEFT  or RIGHT
      -- scom_decoy's window is 010h - SIXTEEN ticks for the whole motion, half
      -- of what the telekinetic slam allows.  Down, Back and the button all
      -- have to land inside it, so this is deliberately tighter than the
      -- teleslam rig's spacing; there is no room to be generous here.
      -- On the air pass, jump first and let him get off the ground.
      local j = air_attack and 22 or 0
      hold(UP, air_attack and t < 4)
      hold(DOWN,  t>=j    and t<j+4)
      hold(back,  t>=j+5  and t<j+14)   -- held through the button, as a human does
      hold(fwd,   false)
      hold(HP,    t>=j+8  and t<j+12)

      local act = action(A.p1_proc)
      if act == ACT_DECOY and not cur.fired then
        cur.fired = true
        log("  FIRED at t=%d (p1_action=%#x)", t, act)
      end
      if cur.fired and not cur.ended then
        local px, pw, ph = find_poof()
        if px and not cur.poof then
          cur.poof = true
          local dx = px - objx(A.p1_obj)
          cur.poof_dx = dx
          -- "In front" means in the direction he is facing, so the sign of the
          -- offset has to follow the facing, not be positive in world space.
          cur.ahead = facing_left() and (dx < 0) or (dx > 0)
          log("  POOF at t=%d  poof_x=%d p1_x=%d dx=%+d (%dx%d) facing=%s -> %s",
              t, px, objx(A.p1_obj), dx, pw, ph,
              facing_left() and "left" or "right",
              cur.ahead and "IN FRONT" or "BEHIND")
        end
        -- HIDDEN / STUCK.  The ground teleport sets m_inviso for exactly one
        -- tick so the cloud covers his takeoff rather than blooming beside a
        -- man still standing in it.  Two separate things can go wrong and
        -- they need separate answers: he was never hidden at all, or he was
        -- hidden and never came back.  The second one is the dangerous one -
        -- an invisible fighter for the rest of the round, with nothing on
        -- screen to say why - so it is sampled AFTER the move ends, not
        -- during it.
        local hid = inviso()
        if hid then cur.hidden = true end
        local side = objx(A.p1_obj) - objx(A.p2_obj)
        if cur.side0 and side ~= 0 and (side < 0) ~= (cur.side0 < 0) then
          cur.crossed = true
          if cur.shown_at == nil and not hid then cur.shown_at = t end
        end
        if t % 4 == 0 then
          log("    t=%3d act=%#x p1x=%4d p2x=%4d poof=%s inviso=%s", t, act,
              objx(A.p1_obj), objx(A.p2_obj), px and tostring(px) or "-",
              tostring(hid))
        end
        if SNAP > 0 and t % SNAP == 0 then manager.machine.video:snapshot() end
        if act ~= ACT_DECOY and t > 20 then
          cur.ended = true
          cur.ended_at = t
          log("  ENDED at t=%d  crossed=%s poof=%s hidden=%s",
              t, tostring(cur.crossed), tostring(cur.poof), tostring(cur.hidden))
        end
      end

      -- The invisibility must be GONE by the time the attempt closes out.
      -- Sampled well after ENDED so the watcher's 2-tick poll has had its
      -- turn; if it is still set here it is set for good.
      if cur.ended and cur.ended_at and t == cur.ended_at + 20 then
        cur.stuck = inviso()
        if cur.stuck then log("  STILL INVISIBLE %d ticks after the move ended", 20) end
      end

      -- Close the attempt out: release everything and wait for the next slot.
      if t > 95 then
        for _,n in ipairs({UP,DOWN,LEFT,RIGHT,HP}) do hold(n,false) end
        if not cur.fired then log("  no fire on this attempt (t=%d)", t) end
        atk_start, cur = 0, nil
      end
    end

    local ground_done = (G.fired and G.ended) or attempts >= MAX_GROUND
    local air_done    = (V.fired and V.ended) or air_tries >= MAX_AIR
    if ground_done and air_done and atk_start == 0 and not done then
      done = true
      -- THE GROUND CASE HIDES HIM, THE AIR CASE DOES NOT.
      --
      -- The teleport is Scorpion's do_decoy now.  On the ground Ermac adds
      -- the cloud and one tick of m_inviso behind it (ermac_tele_unhide
      -- clears it on the next tick), so the ground pass wants poof=true and
      -- hidden=true.  In the air he is Scorpion exactly - no cloud, no
      -- vanish, the afterimage decoy instead - so the air pass wants
      -- poof=false AND hidden=false.  A stray create_fx breaks the first and
      -- a set_inviso that is not gated on being grounded breaks the second.
      local ok = G.fired and G.poof and G.ahead and G.crossed and G.ended
                 and G.hidden and (not G.stuck)
                 and V.fired and (not V.poof) and (not V.stuck)
                 and (not V.hidden)
      log("ground: fired=%s poof=%s ahead=%s (dx=%s) crossed=%s ended=%s",
          tostring(G.fired), tostring(G.poof), tostring(G.ahead),
          tostring(G.poof_dx), tostring(G.crossed), tostring(G.ended))
      log("ground: hidden=%s (want true) stuck=%s (want false) shown_at=%s",
          tostring(G.hidden), tostring(G.stuck), tostring(G.shown_at))
      log("air   : fired=%s poof=%s (want false) hidden=%s (want false) ended=%s stuck=%s",
          tostring(V.fired), tostring(V.poof), tostring(V.hidden),
          tostring(V.ended), tostring(V.stuck))
      log("%s ermac_teleport", ok and "PASS" or "FAIL")
      log("finished"); manager.machine:exit()
    end
    -- Backstop: a rig that runs out of attempts without a verdict must SAY so.
    -- Silence here is indistinguishable from the move hanging the game.
    if not done and rel > 2400 then
      done = true
      log("ground: fired=%s poof=%s ahead=%s crossed=%s ended=%s",
          tostring(G.fired), tostring(G.poof), tostring(G.ahead),
          tostring(G.crossed), tostring(G.ended))
      log("air   : fired=%s poof=%s ended=%s",
          tostring(V.fired), tostring(V.poof), tostring(V.ended))
      log("FAIL ermac_teleport: out of attempts (gnd=%d air=%d) p1_action=%#x",
          attempts, air_tries, action(A.p1_proc))
      log("finished"); manager.machine:exit()
    end
  end

  -- Every cached field is driven EVERY frame, not just the ones in `held`:
  -- a window that stops re-asserting false leaves its button stuck down for
  -- the rest of the run, which reads in the log as the wrong move firing.
  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 6000 then log("FAIL ermac_teleport: timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
