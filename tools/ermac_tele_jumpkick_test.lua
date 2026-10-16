-- ermac_tele_jumpkick_test.lua
-- "Jump kick in, then teleport" - the case a human actually plays, and the
-- one the plain teleport rig never covers because it fires from a standing
-- jump straight up.
--
-- The difference that matters is HEIGHT.  do_ermac_decoy runs
-- air_init_special, which calls stop_me and zeroes oyvel but deliberately
-- does not ground him, and then flight_call launches him.  crossover_scan
-- only warps when he reaches a screen EDGE, so the flight has to last long
-- enough to get there - and how long it lasts is set entirely by how high he
-- is when it starts plus whatever upward kick the launch gives him.  A jump
-- kick brings him DOWN, so a teleport chained off one starts low.
--
-- Logs per tick: p_action, x, y, oyvel, m_inviso, f_noedge_obj, and the
-- multipart shape pointer, plus whether the man ever crossed the opponent.
--
-- TK_YHINT lets the rig aim the teleport at a height band so a run is
-- repeatable: it holds the input until oypos is at least that far below
-- ground level (0 = fire as soon as the kick is out).

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("TP_LOG") or (ROOT .. "/tools/ermac_tele_jumpkick_test.log")
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
            objlst=sym("objlst"),  ground_y=sym("ground_y"), worldtlx=sym("worldtlx"),
            noedge=sym("f_noedge_obj") }
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
local function sgn32(v) return v >= 0x80000000 and v - 0x100000000 or v end
local function ganiy() local q=r32(A.p1_proc); return q~=0 and s16(r16(q+P_GANIY)) or 0 end
local function height() return ganiy() - objy(A.p1_obj) end
local function inviso() local o=r32(A.p1_obj); if o==0 or not M_INVISO then return false end
  return (r32(o+OFLAGS2) & M_INVISO) ~= 0 end
local function inviso2() local o=r32(A.p2_obj); if o==0 or not M_INVISO then return false end
  return (r32(o+OFLAGS2) & M_INVISO) ~= 0 end
local function bar2() return r16(A.p2_bar) end
local function bar1() return r16(A.p1_bar) end

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

local frame_sag = {}
for _,tf in ipairs({"MKNJ.TBL","MKFX.TBL"}) do
  local fh = io.open(ROOT.."/src/"..tf,"r")
  if fh then
    local cur = nil
    for line in fh:lines() do
      local label = line:match("^(%w+):")
      if label then cur = label end
      local sag = line:match("^%s*%.long%s+0(%x+)[Hh]")
      if sag and cur then frame_sag[tonumber(sag,16)] = cur; cur = nil end
    end
    fh:close()
  end
end

-- Every object on objlst, multiparts expanded into their piece records.
local function live_pieces()
  local p, n, out = r32(A.objlst), 0, {}
  while p ~= 0 and n < 250 do
    if (r32(p+OFLAGS2) & M_MULTIPART) ~= 0 then
      local buf, m = r32(p+OIMG), {}
      if buf ~= 0 then
        for k = 0, 11 do
          local rec = buf + 112*k
          local sag = r32(rec)
          if sag == 0 then break end
          m[#m+1] = frame_sag[sag] or string.format("%06x/%dx%d",
            sag & 0xffffff, r16(rec+32), r16(rec+48))
        end
      end
      if #m > 0 then out[#out+1] = "{"..table.concat(m,",").."}" end
    else
      local w, h = r16(p+OSIZEX), r16(p+OSIZEY)
      if w ~= 0 or h ~= 0 then out[#out+1] = string.format("%dx%d", w, h) end
    end
    p = r32(p+OLINK); n = n + 1
  end
  return string.format("n=%d %s", n, table.concat(out, " "))
end

local BLK="P1 Block"; local LP="P1 Low Punch"; local HP="P1 High Punch"
local HK="P1 High Kick"
local LEFT="P1 Left"; local RIGHT="P1 Right"; local DOWN="P1 Down"; local UP="P1 Up"
-- P2 is a SECOND HUMAN standing still, for ermac_teleslam_test.lua's reason: a
-- drone walks and attacks, MK2 discards input while the fighter is busy, and a
-- scripted combo then lands or not depending on what the AI was doing - which
-- reads in the log exactly like the move being broken.
local P2LP="P2 Low Punch"
local P2L="P2 Left"; local P2R="P2 Right"
local TWOP = (os.getenv("TP_2P") or "1") ~= "0"
-- TP_CORNER=left|right pins the fight against a stage limit.
local CORNER = os.getenv("TP_CORNER") or ""
-- TP_MODE=ground skips the jump-in entirely and tests the BARE teleport.
-- The ground flight is the short one, so it is where a warp that has to
-- reach a screen edge should run out of travel first.
local MODE = os.getenv("TP_MODE") or ""

-- The pop-out contract, read out of src/MAINEQU.ASM rather than hardcoded:
-- after erm_tele_warp_tick ticks hidden he is PLACED erm_tele_inset inside
-- the far edge of the view, at whatever height he already had.  That is a
-- promise the rig can check directly, and it is a better test than "did he
-- end up on the other side" - see the SWAPPED note in the verdict.
-- Consecutive ticks outside the view that still count as a warp landing
-- short of the edge rather than a flight that never warped.  The grace
-- window is 035h = 53px and the flight closes at 12px/tick, so five is
-- the honest worst case; 12 leaves room and still catches a sail-off.
local OFFVIEW_MAX = 12
local INSET, POPTICK, POPOUT = nil, nil, nil
do
  local fh = io.open(ROOT.."/src/MAINEQU.ASM","r")
  if fh then
    for line in fh:lines() do
      local v = line:match("^erm_tele_inset%s+%.set%s+0?(%x+)[hH]")
      if v then INSET = tonumber(v,16) end
      v = line:match("^erm_tele_warp_tick%s+%.set%s+(%d+)")
      if v then POPTICK = tonumber(v) end
      v = line:match("^erm_tele_popout%s+%.set%s+(%d+)")
      if v then POPOUT = tonumber(v) end
    end
    fh:close()
  end
end
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,
              ["2 Players Start"]=1,["UI Select"]=1,
              [BLK]=1,[LP]=1,[HP]=1,[HK]=1,[LEFT]=1,[RIGHT]=1,[DOWN]=1,[UP]=1,[P2LP]=1,[P2L]=1,[P2R]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

-- results
local done = false
local last_cnt, armed_at = 0, nil
local atk_start, attempts = 0, 0
-- One attempt per DELAY after the jump kick, in ticks.  Height is the real
-- variable - a teleport only warps if the flight lasts long enough to reach
-- a screen edge, and how long it lasts is set by how high he is when it
-- starts - but height is not something the rig can hold still, so it sweeps
-- the delay and RECORDS the height each attempt happened to launch from.
--
-- The kick goes out at t=12.  Anything before ~17 is inside its active
-- frames, where airborn_xfer refuses the transfer outright (pm_special), so
-- the sweep starts there and walks down the back of the jump arc.
-- ticks AFTER the kick goes out.  A connected flip kick freezes both
-- men for the hit, so the teleport lands well behind where the same
-- delay puts it on a whiff.
-- Eight passes.  Geometry is the variable that decides whether a teleport
-- warps at all - how far he is from the edge he is flying at - and the rig
-- cannot hold it still, so it takes a lot of samples and records where each
-- one happened to start.
local BANDS = { 4, 4, 4, 4, 4, 4, 4, 4 }
local R = {}
for i = 1, #BANDS do
  R[i] = { band=BANDS[i], kicked=false, fired=false, ended=false,
           crossed=false, hidden=false, stuck=false, launch_y=nil,
           launch_x=nil, ticks=nil, ended_at=nil, side0=nil, offscreen=false,
           noedge_stuck=false, minx=nil, maxx=nil, offticks=0 }
end
local cur, curi = nil, 0

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

    -- One attempt per height band, 150 frames apart.  Longer than the plain
    -- teleport rig's 110 because this sequence is jump + kick + motion and a
    -- failed warp can leave him walking back across the stage.
    if rel > 260 and rel % 300 == 0 and atk_start == 0 and curi < #BANDS then
      curi = curi + 1
      cur, atk_start, attempts = R[curi], frame, attempts + 1
      log("attempt #%d kick+%d at rel=%d  p1x=%d p2x=%d ground_y=%d facing=%s",
          curi, cur.band, rel, objx(A.p1_obj), objx(A.p2_obj), ganiy(),
          facing_left() and "left" or "right")
    end

    -- BETWEEN attempts, walk P2 back toward the middle of the view.  P1
    -- chases him and the reactions knock him further out, so after three
    -- passes both men were pinned against the right stage limit and every
    -- later sample tested the same degenerate corner.  Geometry is the whole
    -- variable here; it has to be varied on purpose.
    if atk_start == 0 then
      local sx2 = objx(A.p2_obj) - s16(r16(A.worldtlx+16))
      if CORNER == "left" then
        -- Drive P2 to the LEFT stage limit so P1, chasing him, does the whole
        -- combo with his back to the wall.  cos_edge carries a pile of
        -- corner-specific history (the left one broke while the right one
        -- passed by luck, because right_padding fitted inside the old 035h
        -- window), so open-stage passes prove nothing about it.
        hold(P2L, true); hold(P2R, false)
      elseif CORNER == "right" then
        hold(P2R, true); hold(P2L, false)
      else
        hold(P2L, sx2 > 250)
        hold(P2R, sx2 < 150)
      end
    else
      hold(P2L, false); hold(P2R, false)
    end

    if atk_start > 0 then
      local t = frame - atk_start
      local back  = facing_left() and RIGHT or LEFT
      local fwd   = facing_left() and LEFT  or RIGHT

      -- WALK IN, JUMP, KICK, then teleport.
      --
      -- The walk is driven by DISTANCE, not a tick count.  A fixed walk put
      -- him wherever the previous attempt happened to leave him, the jump
      -- kick whiffed six times out of six, and a whiffed kick is a different
      -- test entirely: nobody is in a reaction and the combo never opens.
      local dist = math.abs(objx(A.p1_obj) - objx(A.p2_obj))
      if MODE == "ground" then
        hold(fwd, dist > 90)
        cur.jump = -1
      elseif cur.jump == nil then
        -- 105 left him jumping from too far out: the kick came down 25px
        -- short and whiffed three times out of three.  The attempts that
        -- actually connected were all ones where he happened to start close
        -- and jumped at t=1, reaching the kick with dist 5-7.  So walk in
        -- properly first.
        hold(fwd, dist > 62)
        if dist <= 62 or t > 110 then cur.jump = t + 1 end
      else
        hold(fwd, t >= cur.jump and t < cur.jump + 4)
      end
      local JUMP = cur.jump
      -- +11 kicked on the way UP - h was still climbing 56 -> 92 when the
      -- kick came out and it sailed over the man's head six times out of
      -- six.  The apex is around +22; a jump-in wants the kick landing on
      -- the way DOWN.
      local KICK = (MODE == "ground") and 0 or (JUMP and (JUMP + 22) or nil)
      hold(UP,  MODE ~= "ground" and JUMP and t >= JUMP and t < JUMP + 4)
      hold(HK,  MODE ~= "ground" and KICK and t >= KICK and t < KICK + 4)
      hold(BLK, false)
      if MODE ~= "ground" and KICK and t == KICK - 1 then
        log("  jump at t=%d, kick at t=%d, dist=%d h=%d", JUMP, KICK, dist,
            height())
      end
      -- Trace the whole approach, not just the teleport: a kick that never
      -- came out and a kick that came out and missed look the same in a
      -- bar-only check.
      if MODE ~= "ground" and KICK and t >= JUMP and t <= KICK + 18 then
        log("    ~t=%3d p1act=%#-6x x=%4d h=%3d dist=%3d | p2act=%#-6x bars %d/%d",
            t, action(A.p1_proc), objx(A.p1_obj), height(), dist,
            action(A.p2_proc), bar1(), bar2())
        -- Capture from the KICK, not from the teleport: if this combo looks
        -- wrong the wrongness may start at the kick's own reaction.
        if SNAP > 0 and t >= KICK and t % SNAP == 0 then
          manager.machine.video:snapshot()
        end
      end
      if KICK and t == KICK - 1 then cur.bar2_pre = bar2() end
      -- The kick's OWN hit, and only that: once the teleport is out its punch
      -- takes p2's bar too, and counting that as "the kick connected" is how
      -- the first version of this rig reported a connect 29 ticks AFTER the
      -- teleport had already fired.
      if cur.bar2_pre and not cur.kicked and not cur.fired
         and bar2() < cur.bar2_pre then
        cur.kicked, cur.kicked_at = true, t
        log("  KICK CONNECTED at t=%d  p2 %d -> %d", t, cur.bar2_pre, bar2())
      end

      -- Start the motion `band' ticks after the kick, then REPEAT it on a
      -- 16-tick cycle until it takes.  A connected flip kick holds the
      -- attacker in his own action for a while, and airborn_xfer refuses the
      -- transfer outright while pm_special is up - so a single scripted
      -- motion at a fixed offset mostly lands in the refusal window and
      -- reports "no fire", which says nothing about the teleport.  Mashing
      -- is also what a human does, and it finds the EARLIEST tick the game
      -- will accept the move, which is the interesting one.
      local j = KICK and (KICK + cur.band) or nil
      if j and t >= j and not cur.fired then
        local c = (t - j) % 16
        hold(DOWN, c < 3)
        hold(back, c >= 4 and c < 13)
        hold(HP,   c >= 7 and c < 11)
      else
        hold(DOWN, false); hold(back, false); hold(HP, false)
      end
      if cur.go == nil and j and t >= j then cur.go = t end

      local act = action(A.p1_proc)
      if act == ACT_DECOY and not cur.fired then
        cur.fired, cur.fired_at = true, t
        cur.launch_y, cur.launch_x = height(), objx(A.p1_obj)
        -- Which side he is on WHEN THE TELEPORT STARTS.  Sampling this at
        -- the top of the attempt was wrong: the jump-in itself carries him
        -- over the opponent, so every pass scored SWAPPED=false for a
        -- teleport that had in fact put him behind the man.  The move's
        -- claim is about the flight, so the baseline has to be the flight.
        cur.side0 = objx(A.p1_obj) - objx(A.p2_obj)
        cur.minx, cur.maxx = cur.launch_x, cur.launch_x
        local wx = s16(r16(A.worldtlx+16))
        cur.to_left, cur.to_right = cur.launch_x - wx, (wx + 400) - cur.launch_x
        -- THE number that decides whether this teleport works at all.
        -- away_x_vel sends him AWAY from the opponent, and crossover_scan
        -- only warps when he reaches that screen edge - within 3px for
        -- Ermac, where Scorpion gets a 035h grace.  The whole move is a race
        -- between the flight's travel and this distance.
        cur.away = (cur.launch_x >= objx(A.p2_obj)) and 1 or -1
        cur.to_target = (cur.away > 0) and cur.to_right or cur.to_left
        log("  FIRED at t=%d (%d after the kick, kick %s)  height=%d  x=%d  "..
            "%d px to the left edge / %d to the right",
            t, t - (KICK or 0),
            cur.kicked and ("CONNECTED at "..cur.kicked_at) or "whiffed",
            cur.launch_y, cur.launch_x, cur.to_left, cur.to_right)
        log("        flying %s - %d px to the edge it must reach",
            cur.away > 0 and "RIGHT" or "LEFT", cur.to_target)
      end
      if cur.fired and not cur.ended then
        local hid = inviso()
        if hid then cur.hidden = true end
        -- The tick he comes back into view IS the pop-out.  Record where.
        if cur.hidden and not hid and cur.popped_sx == nil then
          cur.popped_sx = objx(A.p1_obj) - s16(r16(A.worldtlx+16))
          cur.popped_at = t - (cur.fired_at or t)
        end
        local x = objx(A.p1_obj)
        if x < cur.minx then cur.minx = x end
        if x > cur.maxx then cur.maxx = x end
        local side = x - objx(A.p2_obj)
        if cur.side0 and side ~= 0 and (side < 0) ~= (cur.side0 < 0) then
          cur.crossed = true
        end
        -- OFF SCREEN, and it has to be measured in TICKS now.
        --
        -- cross_warp is Scorpion's relative wrap (oxpos - SCRRGT), and the
        -- 035h grace window lets it fire up to 53px short of the view edge -
        -- so a normal, correct warp puts him up to 53px OUTSIDE the far side
        -- and he flies back in over the next four or five ticks.  Scorpion
        -- has always done that and Ermac does it now, so a single off-view
        -- tick is not a fault.  What IS a fault is leaving the view and not
        -- coming back: he sailed off under his own velocity and the warp
        -- never happened.
        local wx = s16(r16(A.worldtlx+16))  -- integer half of the 16.16
        if x < wx - 8 or x > wx + 400 + 8 then
          cur.offticks = (cur.offticks or 0) + 1
          if cur.offticks > OFFVIEW_MAX then cur.offscreen = true end
        else
          cur.offticks = 0
        end
        do
          local o = r32(A.p1_obj)
          log("    t=%3d p1act=%#-6x sx=%4d y=%4d h=%3d inviso=%-5s noedge=%-3s "..
              "| p2act=%#-6x p2x=%4d p2y=%4d p2inv=%-5s bars %d/%d",
              t, act, x - s16(r16(A.worldtlx+16)), objy(A.p1_obj), height(),
              tostring(hid), r32(A.noedge) ~= 0 and "set" or "-",
              action(A.p2_proc), objx(A.p2_obj), objy(A.p2_obj),
              tostring(inviso2()), bar1(), bar2())
        end
        if SNAP > 0 and t % SNAP == 0 then manager.machine.video:snapshot() end
        if act ~= ACT_DECOY then
          cur.ended, cur.ended_at = true, t
          cur.ticks = t - (cur.go or 0)
          -- WHERE HE ENDS UP, which is the actual question.  `crossed' only
          -- says he was on the other side at some point during the flight;
          -- a teleport that warps and then flies all the way back past the
          -- man again has done nothing, and lands him on the side he
          -- started.  A teleport is supposed to put him BEHIND you.
          local sideN = objx(A.p1_obj) - objx(A.p2_obj)
          cur.side_end = sideN
          cur.swapped = cur.side0 and sideN ~= 0
                        and ((sideN < 0) ~= (cur.side0 < 0))
          local wx = s16(r16(A.worldtlx+16))
          cur.end_sx = objx(A.p1_obj) - wx
          cur.cornered = cur.end_sx < 40 or cur.end_sx > 360
          log("  ENDED at t=%d (flight %d ticks)  crossed=%s SWAPPED=%s  end sx=%d%s  gap=%d",
              t, cur.ticks, tostring(cur.crossed), tostring(cur.swapped), cur.end_sx,
              cur.cornered and " (IN THE CORNER)" or "", math.abs(sideN))
        end
      end

      if cur.ended and cur.ended_at and t == cur.ended_at + 20 then
        cur.stuck = inviso()
        cur.noedge_stuck = r32(A.noedge) ~= 0
        cur.p2_inviso = inviso2()
        cur.p2_sx_end = objx(A.p2_obj) - s16(r16(A.worldtlx+16))
        cur.p2_act = action(A.p2_proc)
        cur.p2_y = objy(A.p2_obj)
        if cur.p2_inviso then log("  P2 IS INVISIBLE 20 ticks after the move") end
        log("  after: p1act=%#x p2act=%#x p1x=%d p2x=%d p2y=%d bars %d/%d",
            action(A.p1_proc), cur.p2_act, objx(A.p1_obj), objx(A.p2_obj),
            cur.p2_y, bar1(), bar2())
        if cur.stuck then log("  STILL INVISIBLE 20 ticks after the move ended") end
        if cur.noedge_stuck then log("  f_noedge_obj STILL SET 20 ticks after") end
      end

      if t > 260 then
        for _,n in ipairs({UP,DOWN,LEFT,RIGHT,HP,HK}) do hold(n,false) end
        if not cur.fired then
          log("  no fire on this attempt (t=%d, go=%s)", t, tostring(cur.go))
        elseif not cur.ended then
          -- Fired and never left act_decoy.  On MK2's cooperative scheduler
          -- that is a wedged process, and it has to be named rather than
          -- quietly closed out as "no verdict".
          --
          -- But only if the window actually gave it room.  A teleport is a
          -- ~45 tick flight, and the mash loop can land one a tick before
          -- the cutoff; scoring that as wedged reported a hang twice on
          -- moves that were running perfectly normally.
          if (t - (cur.fired_at or t)) >= 60 then
            cur.wedged = true
            log("  STUCK IN act_decoy at t=%d - the move never ended", t)
          else
            -- Not a failure and not a pass: there was no room to see the
            -- outcome.  It has to be excluded from the verdict, or the rig
            -- reports a regression for a move that was running normally.
            cur.unjudged = true
            log("  attempt closed %d ticks after it fired - too short to "..
                "judge, not a verdict", t - (cur.fired_at or t))
          end
        end
        atk_start, cur = 0, nil
      end
    end

    if curi >= #BANDS and atk_start == 0 and not done then
      done = true
      local ok, fired = true, 0
      for i, r in ipairs(R) do
        if r.fired then fired = fired + 1 end
        -- A teleport that fires and does NOT cross is the failure this rig
        -- exists for: crossover_scan only warps at a screen edge, so a flight
        -- too short to reach one lands him back where he started having done
        -- nothing.  Stuck invisibility and a stuck f_noedge_obj are the two
        -- states that outlive the move if it ends the wrong way.
        -- SWAPPED cannot be demanded unconditionally.  A teleport puts you
        -- BEHIND the man, and if he is stood against a wall there is no
        -- behind: the corner rig pins P2 at the stage limit and then failed
        -- the move for not reaching a place that does not exist.  So it is
        -- only required when the arrival side had room for it.
        --
        -- PLACEMENT AND CORNER COVER ARE NO LONGER PROMISED.  The teleport
        -- is Scorpion's do_decoy now - it warps at a screen edge with the
        -- relative wrap and lands wherever the flight runs out.  The clock
        -- pop-out (erm_tele_inset) and the step-past-a-cornered-man
        -- (erm_tele_over) were his private flight and went with it, so
        -- `placed' and `cornered' are logged for information and no longer
        -- decide the verdict.  What the move still owes is: it fires, it
        -- crosses, it puts him behind the man when there is a behind, it
        -- comes back into view, and it leaves nothing stuck behind it.
        local room = true
        if r.popped_sx and r.p2_sx_end then
          room = math.abs(r.p2_sx_end - r.popped_sx) > 40
        end
        local placed = (POPOUT ~= 1) or (r.popped_sx == nil)
                       or math.abs(r.popped_sx - (INSET or 64)) <= 12
                       or math.abs(r.popped_sx - (400 - (INSET or 64))) <= 12
        local good = (not r.fired) or r.unjudged or
                     (r.crossed and (r.swapped or not room) and not r.stuck
                      and not r.noedge_stuck and not r.offscreen
                      and not r.p2_inviso and not r.wedged)
        if not good then ok = false end
        log("#%d kick=%-5s fired=%-5s %-12s crossed=%-5s SWAPPED=%-5s "..
            "end_sx=%-4s corner=%-5s wedged=%-5s stuck=%s%s",
            i, tostring(r.kicked), tostring(r.fired),
            r.popped_sx and string.format("pop@%d/t%d", r.popped_sx,
                                          r.popped_at or -1) or "-",
            tostring(r.crossed), tostring(r.swapped), tostring(r.end_sx),
            tostring(r.cornered), tostring(r.wedged), tostring(r.stuck),
            r.unjudged and "   (not judged)" or (good and "" or "   <-- BAD"))
      end
      if fired == 0 then
        ok = false
        log("NO ATTEMPT EVER FIRED - the input never reached do_ermac_decoy,")
        log("which is a rig problem, not a verdict on the move.")
      end
      log("%s ermac_tele_jumpkick", ok and "PASS" or "FAIL")
      log("finished"); manager.machine:exit()
    end
    -- Backstop: a rig that runs out of attempts without a verdict must SAY so.
    -- Silence here is indistinguishable from the move hanging the game.
    if not done and rel > 3000 then
      done = true
      for i, r in ipairs(R) do
        log("kick+%-3d fired=%s crossed=%s", r.band, tostring(r.fired),
            tostring(r.crossed))
      end
      log("FAIL ermac_tele_jumpkick: out of time after %d attempts, p1_action=%#x",
          attempts, action(A.p1_proc))
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
