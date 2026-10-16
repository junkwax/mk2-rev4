-- ermac_fatal_slam_test.lua
--
-- End-to-end MAME harness for Ermac's telekinetic slam FATALITY,
-- Down, Up, Down, Down, Down + BLOCK.
--
-- Two rigs are welded together here, and each half is doing something the
-- other cannot:
--
--   SELECT   from ermac_teleslam_test.lua.  Ermac is a hidden fighter and
--            hidden fighters cannot be forced - test_mode parks at gstate 8
--            and poking p1_char does not move the select CURSOR, which is
--            what check_ermac_blk_cheat actually reads.  The only way in is
--            the cheat itself: Reptile + Block x5, confirmed against the
--            game's own counter rather than on a timer.
--   FINISH   from st_decap_fatality_test.lua.  Winning two rounds under
--            script is not worth the complexity, so the fight is put into
--            Finish Him by hand: winner_status=3, f_death=0, and the
--            victim's process pushed into dizzy_dude.  The INPUT is not
--            faked - it goes through the real joystick queue, ermac_block,
--            combo_look_lr and fatality_xfer_close, which is the only part
--            under test.
--
-- What is measured, because each fails differently:
--
--   FIRED   f_death reaches 2.  init_death_blow ran, so the combo, the
--           char_block dispatch AND the whole common gate (distance band,
--           violence, dizzy wakeup) all passed.
--   LIFTED  peak height the victim reaches.  The move takes him off the top
--           of a 254px screen; anything under ~150px means the negative
--           gravity is not running and he is only hovering.
--   SLAMS   how many times he comes back to the floor.  Four is the move.
--           This is the one number that separates the FATALITY from the
--           SPECIAL, which does exactly one.
--   POPPED  m_inviso appears in the victim's oflags2 - r_shocker_pop's
--           set_inviso, i.e. the body is gone and the chunks are out.
--   ENDED   f_death goes to -1.  death_blow_complete ran exactly once and
--           the attacker reached victory_animation without wedging.
--   HEAD    the victim's severed head exists and FALLS.  Two halves, because
--           they fail apart: an object carrying the victim's ochar (no chunk
--           does - decapped_head copies it from the body), and that object's
--           y actually changing.  A head that is built and then never driven
--           looks identical to a working one in a single sample.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG  = os.getenv("EFS_LOG") or (ROOT .. "/tools/ermac_fatal_slam_test.log")
local SNAP = tonumber(os.getenv("EFS_SNAP") or "8")
-- Middle of UMK3's q_fatal_dist(060h,0c0h) band, which ermac_block enforces
-- as erm_tksf_mindist..erm_tksf_maxdist.  Deliberately not at either edge:
-- a rig parked on a boundary fails for rounding reasons and reads as the
-- gate being wrong.
local DIST = tonumber(os.getenv("EFS_DIST") or "130")
-- Ticks to keep watching AFTER death_blow_complete, to prove the victory
-- pass runs instead of wedging.
local SETTLE = tonumber(os.getenv("EFS_SETTLE") or "300")
-- EFS_SIDE=right puts Ermac on the RIGHT of the victim, facing left.  The
-- combo has no horizontals in it so the pattern itself cannot care, but the
-- windup art, the camera hand-off in center_around_me and the victim's
-- flight are all mirrored, and those can.  This is NOT the same as running
-- Ermac as player two - that needs the P2 half of the select cheat and is
-- not covered here.
local SIDE = (os.getenv("EFS_SIDE") or "left"):lower()
local HEADDUMP = (os.getenv("EFS_HEADDUMP") or "0") ~= "0"
-- The three splats the burst throws (BLDXPD1-13, data/BLDXPD.LOD).  Found by
-- SAG window rather than by ochar: unlike the head they copy nothing off the
-- body.  The window is READ OUT OF src/BLDXPD.TBL at start-up - every record
-- from its SAG to SAG + w*h*8 bits - so rebasing or re-cutting the sidecar
-- moves it with the art.  It used to be hardcoded, and swapping the drawn
-- MKSPLASH stand-in for UMK3's real frames would have silently counted zero.
local SPLASH_LO, SPLASH_HI = nil, nil
do
  local fh = io.open(ROOT .. "/src/BLDXPD.TBL", "r")
  if fh then
    local w, h
    for line in fh:lines() do
      local a, b = line:match("^%s*%.word%s+(%d+)%s*,%s*(%d+)%s*,")
      if a then w, h = tonumber(a), tonumber(b) end
      local sag = line:match("^%s*%.long%s+0?(%x+)[Hh]")
      if sag and w then
        local v = tonumber(sag, 16)
        if v and v >= 0x02000000 then
          SPLASH_LO = SPLASH_LO and math.min(SPLASH_LO, v) or v
          local e = v + w * h * 8
          SPLASH_HI = SPLASH_HI and math.max(SPLASH_HI, e) or e
        end
      end
    end
    fh:close()
  end
end
-- EFS_PIT=1 is the FALL-THROUGH regression, not a test of this fatality.
-- char_block[17] used to point straight at check_nj_dtp; it now points at
-- ermac_block, which checks the slam first and falls through.  So Ermac's
-- OTHER finisher - the ninja pit fatality, Down,Forward,Forward + BLOCK,
-- which he shares with Scorpion, Reptile and Smoke - is the thing that could
-- have been broken by wiring this one in.  With EFS_PIT=1 the match is pinned
-- to THE PIT II (curback 6, the way tower_stage_probe.lua pins its stage),
-- the input becomes D,F,F + BLOCK, and a pass is f_death reaching
-- pit_fatality (6).
local PIT = (os.getenv("EFS_PIT") or "0") ~= "0"
-- EFS_REPTILE=1 is the OTHER regression, and it is the one that matters most.
-- check_nj_dtp is reached by FALL-THROUGH from rp_block, so a handler parked
-- in that gap silently joins REPTILE's block path.  The first version of
-- ermac_block was, and Reptile could have thrown Ermac's fatality.  This mode
-- skips the Ermac unlock entirely, plays plain Reptile, and throws
-- D,U,D,D,D + BLOCK at him: a pass is that NOTHING happens.
local REPTILE = (os.getenv("EFS_REPTILE") or "0") ~= "0"
local NEG_ATTEMPTS = tonumber(os.getenv("EFS_NEG_ATTEMPTS") or "8")
local CURBACK_PIT = 6
local FD_PIT = 6

local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[efs] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols={}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n) local v=symbols[n]; if not v then log("WARN missing symbol %s",n) end return v or 0 end

local A = { gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
            cheatc=sym("c_ermac_cheat1"), cheatf=sym("f_ermac_cheat1"),
            p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
            p1_obj=sym("p1_obj"),  p2_obj=sym("p2_obj"),
            p1_bar=sym("p1_bar"),  p2_bar=sym("p2_bar"),
            winner_status=sym("winner_status"), f_death=sym("f_death"),
            curback=sym("curback"),
            objlst=sym("objlst"), objlst2=sym("objlst2"), objlst3=sym("objlst3"),
            dizzy=sym("dizzy"), dizzy_dude=sym("dizzy_dude"),
            palram=sym("palram") }

local O = { next=0x000, oxvel=0x040, oyvel=0x060, oyval=0x0a0, oxval=0x080, oxpos=0x090, ozpos=0x0d0,
            oypos=0x0b0, osag=0x100, oflags2=0x160, oshape=0x1d0, ochar=0x1f0 }
local P = { pa8=0x0c0, wake=0x0e0, action=0x1f0, flags=0x210, downcount=0x220 }
local M_INVISO = 0x0020
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local GS_PSEL, GS_FIGHT = 4, 2
local FT_REPTILE, FT_ERMAC, FT_JAX = 9, 17, 11

-- EFS_VICTIM picks who gets slammed.  Jax by default, which is every run this
-- rig ever made; it exists so the OFF-COLOUR BLEEDERS can be put under the
-- same fatality.  The burst (ermac_splash_blood -> esplat_go, MKBLOOD.ASM)
-- draws BLDXPD1-13, whose records name BLDXPD_P, and bldxpd_blood_pal swaps
-- that for Midway's own green / oil recolour when the body is Reptile's or
-- Noob's.  Nothing else in the tree draws these frames, so this fatality is
-- the only place that wiring can be measured at all.
local VICTIM_NAMES = { jax = FT_JAX, reptile = FT_REPTILE, noob = 15,
                       subzero = 8, scorpion = 10, kang = 1, cage = 2,
                       raiden = 7, kitana = 4, mileena = 5, baraka = 3,
                       kunglao = 0, shang = 6, jade = 16, ermac = 17, rain = 19 }
local VICTIM = VICTIM_NAMES[(os.getenv("EFS_VICTIM") or "jax"):lower()]
                 or tonumber(os.getenv("EFS_VICTIM") or "") or FT_JAX
local ACT_STUNNED = 0x0400

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
local function objy(op) local o=r32(op); return o~=0 and s16(r16(o+O.oypos)) or 0 end
local function objx(op) local o=r32(op); return o~=0 and s16(r16(o+O.oxpos)) or 0 end
local function objflags2(op) local o=r32(op); return o~=0 and r16(o+O.oflags2) or 0 end

-- EFS_TRACE=1 (the runner's -Trace adds MAME -debug): catch the jump into
-- garbage.  A wedge that ends in the illegal-opcode trap parks the PC on its
-- `jauc $`, and by the time a rig notices, the debugger's history ring is all
-- that one instruction - so the history has to be taken AT THE TRAP'S ENTRY,
-- by a breakpoint with an action, not afterwards from this callback.  The
-- action also prints A13, the process that was running: that names WHICH
-- process jumped, and its block is dumped below for its pid and wake address.
local TRACE = (os.getenv("EFS_TRACE") or "0") ~= "0"
local dbg_armed, dbg_seen = false, 0
local function dbg()
  local ok, d = pcall(function() return manager.machine.debugger end)
  return ok and d or nil
end
local function dbg_arm()
  -- The breakpoint itself lives in tools/ermac_trap.ds (-debugscript): -debug
  -- starts the CPU halted and an autoboot script never runs until emulated
  -- time passes, so the script that sets the trap has to be the one that says g.
  dbg_armed = true
  log("debugger: draining console (trap set by -debugscript)")
end
local function dbg_drain()
  local d = dbg(); if not d then return end
  pcall(function()
    local cl = d.consolelog
    for i = dbg_seen + 1, #cl do
      local line = tostring(cl[i])
      print("[efs] H| " .. line)
      local a13 = line:match("TRAP a13=(%x+)")
      if a13 and space then
        local pp = tonumber(a13, 16)
        local words = {}
        for off = 0, 0x2a0, 0x10 do words[#words+1] = string.format("%03x:%04x", off, r16(pp + off)) end
        print("[efs] H| proc@a13 " .. table.concat(words, " "))
        log("    trap process @%08x: pwake=%08x", pp, r32(pp + 0x0e0))
      end
    end
    dbg_seen = #cl
  end)
end

local BLK  = "P1 Block"
local LP   = "P1 Low Punch"
local UP   = "P1 Up"
local DOWN = "P1 Down"
local LEFT = "P1 Left"
local RIGHT= "P1 Right"
local P2LP = "P2 Low Punch"
local function cache()
  local want={["Coin 1"]=1,["Coin 2"]=1,["1 Player Start"]=1,["2 Players Start"]=1,
              ["UI Select"]=1,[BLK]=1,[LP]=1,[UP]=1,[DOWN]=1,[LEFT]=1,[RIGHT]=1,[P2LP]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do if want[fld.name] then fields[fld.name]=fld end end end
  for n in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

-- Down, Up, Down, Down, Down then BLOCK.  Discrete presses with release gaps
-- so the queue records five separate switch CLOSURES - a held stick is one
-- entry, not three.  The whole run closes at 54 ticks against
-- scom_ermac_fatal's 038h (56) window, and Block lands on the last of them,
-- held the way a human holds a block.
local COMBO = {
  {  0,  4, DOWN }, {  8, 12, UP   }, { 16, 20, DOWN },
  { 24, 28, DOWN }, { 32, 36, DOWN }, { 40, 54, BLK  },
}
-- scom_nj_dtp: Down, Forward, Forward + BLOCK.  Forward is Right with Ermac
-- on the left, which is where EFS_PIT leaves him.
local COMBO_PIT = {
  {  0,  4, DOWN }, {  8, 12, RIGHT }, { 16, 20, RIGHT }, { 24, 34, BLK },
}

local armed_at, last_cnt = nil, 0
local finish_at, dizzy_forced, ready_at, input_at = 0, false, 0, 0
local fired, fired_at, popped, ended, done = false, 0, false, false, false
local base_y, lifted, slams, airborne = nil, 0, 0, false
local ended_at, last_shape = 0, nil
local splash_max, splash_seen, splash_ys = 0, false, nil
local head_path, head_obj, head_at, head_moved, head_y0 = false, nil, 0, false, nil
local settle_moved = false
local attempts = 0

-- THE HEAD.  r_raiden_superp sets p_downcount = 1 and, 0a0h ticks after the
-- pop, drops the victim's own head in from above the screen.  Two separate
-- things are worth proving and they fail differently:
--
--   the PATH   p_downcount on the victim's process is 1, i.e. the head-
--              bearing entry ran rather than r_shocker_pop.
--   the HEAD   an object that is not either fighter, carrying the victim's
--              ochar at ozpos 20 - which is what the tail builds.  This is
--              the half that can fail on its own: gso_dmawnz is asked for an
--              object immediately after an explosion that just spawned ~70
--              chunks, and an exhausted pool is a real failure mode here
--              (getobj -> ermac 5 -> the whole game wedges).
local function find_head(victim_ochar)
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
    local obj, guard = r32(list), 0
    while obj ~= 0 and guard < 400 do
      -- The head is the only object in the burst that carries the victim's
      -- ochar - decapped_head copies it from the body, and every exp_burst
      -- chunk leaves it at 0.
      if obj ~= p1o and obj ~= p2o
         and r16(obj + O.ochar) == victim_ochar then
        return obj
      end
      obj = r32(obj + O.next); guard = guard + 1
    end
  end
  return nil
end

-- How many splash objects are live right now, and where.  Counting the MAX
-- simultaneous is the honest measure: three processes are created on the same
-- tick but each deletes itself when its lane ends, so a late sample sees
-- fewer and a "3" from one frame proves nothing about the others.
local function count_splashes()
  local n, ys, sags = 0, {}, {}
  if not SPLASH_LO then return 0, ys, sags end   -- no TBL: count nothing, fail the verdict
  for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
    local obj, guard = r32(list), 0
    while obj ~= 0 and guard < 400 do
      local sag = r32(obj + O.osag) & 0x0fffffff
      if sag >= SPLASH_LO and sag < SPLASH_HI then
        n = n + 1; ys[#ys+1] = s16(r16(obj + O.oypos)); sags[#sags+1] = sag
      end
      obj = r32(obj + O.next); guard = guard + 1
    end
  end
  return n, ys, sags
end

-- WHICH PALETTE THE SPLATS ARE DRAWN IN.
--
-- The object's opal names a colour MAP, not a palette: palram[map] holds the
-- ROM address of whatever is loaded there, and it is only the truth while
-- palcnt is non-zero - freepal leaves the id behind, so a released slot reads
-- as a palette still on screen (reference_palram_names_the_live_palette).
--
-- palram is .bss, so it MOVES on every build that changes RAM ahead of it;
-- it is read out of mk2.map above rather than written down here.  (The
-- EFS_TRACE block below still carries a hard-coded PAL_RAM - that one is a
-- one-off debugger aid, not a verdict.)
local SPLAT_OPAL = 0x140
local pal_seen, pal_names = {}, {}
for _, n in ipairs({ "BLDXPD_P", "BLDXPDG_P", "BLDXPDNB_P" }) do
  if symbols[n] then pal_names[symbols[n]] = n end
end
-- The expectation is the rule bldxpd_blood_pal implements, stated once here:
-- Reptile green, Noob oil, everybody else Midway's red.  EFS_VICTIM is what
-- makes it a real test rather than a restatement - the default Jax run must
-- come out RED, so a swap that fired on the wrong victim fails here too.
local PAL_WANT = (VICTIM == FT_REPTILE and "BLDXPDG_P")
              or (VICTIM == 15 and "BLDXPDNB_P") or "BLDXPD_P"
local function sample_splat_pals()
  if not SPLASH_LO or A.palram == 0 then return end
  for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
    local obj, guard = r32(list), 0
    while obj ~= 0 and guard < 400 do
      local sag = r32(obj + O.osag) & 0x0fffffff
      if sag >= SPLASH_LO and sag < SPLASH_HI then
        local map = (r16(obj + SPLAT_OPAL) >> 8) & 0xff
        local e = A.palram + map * 0x40
        if r16(e + 0x20) ~= 0 then            -- palcnt: anybody still holding it
          local id = r32(e)
          local nm = pal_names[id] or string.format("%08x", id)
          if not pal_seen[nm] then
            pal_seen[nm] = true
            log("BLOODPAL splat on map %d = %s", map, nm)
          end
        end
      end
      obj = r32(obj + O.next); guard = guard + 1
    end
  end
end
local function pal_report()
  local got = {}
  for nm in pairs(pal_seen) do got[#got+1] = nm end
  table.sort(got)
  if #got == 0 then return "unmeasured", false, true end
  return table.concat(got, "+"), (#got == 1 and got[1] == PAL_WANT), false
end

-- EFS_TRACE: follow the splats' palette reference count.  The wedge was
-- measured as freepal's "negative palette count" lockup on the SECOND
-- splat's delobjp - three objects, one reference left.  This logs the slot's
-- palcnt whenever it (or the splat count) changes, and puts a write
-- watchpoint on the palcnt word so every writer prints its PC and process.
local PAL_RAM   = 0x010EEDB0   -- palram, as freepal addresses it (ADDI 10EEDB0h)
local PAL_RSIZ  = 0x40         -- palrsiz
local PAL_CNT   = 0x20         -- palcnt
local OBJ_OPAL  = 0x140        -- opal (delpal: move *a0(opal),a0,w)
local pal_slot, pal_last, pal_wp = nil, nil, false
local function pal_probe()
  if not SPLASH_LO then return end
  local objs = {}
  for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
    local obj, guard = r32(list), 0
    while obj ~= 0 and guard < 400 do
      local sag = r32(obj + O.osag) & 0x0fffffff
      if sag >= SPLASH_LO and sag < SPLASH_HI then objs[#objs+1] = obj end
      obj = r32(obj + O.next); guard = guard + 1
    end
  end
  if #objs > 0 and not pal_slot then pal_slot = r16(objs[1] + OBJ_OPAL) & 0xff end
  if not pal_slot then return end
  local e = PAL_RAM + pal_slot * PAL_RSIZ
  local opals = {}
  for _, o in ipairs(objs) do opals[#opals+1] = string.format("%08x:%04x", o, r16(o + OBJ_OPAL)) end
  local key = string.format("%d/%08x/%s", r16(e + PAL_CNT), r32(e), table.concat(opals, ","))
  if key ~= pal_last then
    pal_last = key
    log("PAL frame=%d slot=%d id=%08x palcnt=%d splats=%d [%s]", frame, pal_slot, r32(e),
        r16(e + PAL_CNT), #objs, table.concat(opals, " "))
  end
  if not pal_wp then
    pal_wp = true
    local d = dbg()
    if d then
      local cmd = string.format('wpset %x,10,w,1,{printf "PALCNT-W new=%%d pc=%%08X a13=%%08X a8=%%08X",wpdata,pc,a13,a8; g}', e + PAL_CNT)
      pcall(function() d:command(cmd) end)
      -- ...and the history behind the FIRST release (the write of 2): that
      -- one came from a process that is not a splat's.
      local cmd2 = string.format('wpset %x,10,w,wpdata==2,{printf "FIRST-RELEASE a0=%%08X a2=%%08X a8=%%08X a13=%%08X sp=%%08X",a0,a2,a8,a13,sp; history ,200; g}', e + PAL_CNT)
      pcall(function() d:command(cmd2) end)
      log("wpset on palcnt @%08x (slot %d)", e + PAL_CNT, pal_slot)
    end
  end
end

local function snap_range()
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  if p1o == 0 or p2o == 0 then return end
  local x = (SIDE == "right") and (r16(p2o + O.oxpos) + DIST) or (r16(p2o + O.oxpos) - DIST)
  w16(p1o + O.oxpos, x); w32(p1o + O.oxval, (x << 16))
  w32(p1o + O.oxvel, 0)
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]; cache()
    log("dist=%d side=%s pit=%s reptile=%s f_death=%#x winner_status=%#x", DIST, SIDE, tostring(PIT), tostring(REPTILE), A.f_death, A.winner_status)
  end
  if not space then return end
  if TRACE then if not dbg_armed then dbg_arm() end; dbg_drain(); pal_probe() end
  local gs = r16(A.gstate)

  if gs == GS_PSEL and psel == 0 then
    psel = frame; log("select at frame %d", frame)
  end

  if psel == 0 then
    hold("Coin 1", frame>=200 and (frame%80)<20)
    hold("Coin 2", frame>=200 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("2 Players Start", frame>=300 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif fight == 0 then
    -- Ermac select cheat, lifted verbatim from ermac_teleslam_test.lua.  Every
    -- comment there about WHY it is shaped this way still applies: the Start
    -- holds must be cleared every frame (Start+Block is an alternate-palette
    -- confirm that skips the hidden-character check), the cursor and the
    -- pending flag must both be held to the end of select, and P1 must
    -- actually confirm or the override never lands.
    for _,n in ipairs({"Coin 1","Coin 2","1 Player Start","2 Players Start"}) do hold(n,false) end
    local cnt, pending = r16(A.cheatc), r16(A.cheatf)
    if gs == GS_PSEL then
      w16(A.p1_char, FT_REPTILE)
      -- The cheat is what turns the pick into Ermac.  EFS_REPTILE leaves it
      -- alone, so P1 confirms as the ordinary Reptile the cursor is on.
      if not REPTILE then w16(A.cheatf, 1); pending = 1 else pending = 1 end
    end
    if not armed_at and gs ~= GS_PSEL then w16(A.p1_char, FT_REPTILE) end
    if pending == 0 and not armed_at then
      hold(BLK, (frame % 4) < 2)
      if cnt ~= last_cnt then log("  cheat press %d -> %d", last_cnt, cnt); last_cnt = cnt end
    else
      hold(BLK, false)
      if not armed_at then armed_at = frame; log("  cheat ARMED at frame %d", frame) end
      hold(LP, ((frame - armed_at) % 16) < 6)
      w16(A.p2_char, VICTIM)
      hold(P2LP, ((frame - armed_at) % 12) < 5)
    end
    if PIT then w16(A.curback, CURBACK_PIT) end
    if gs == GS_FIGHT then
      fight = frame; hold(LP,false); hold(P2LP,false)
      log("fight at frame %d, p1_char=%d (17 = Ermac)", frame, r16(A.p1_char))
    end
  else
    local rel = frame - fight
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)

    -- Force Finish Him once both fighters are really on screen as the right
    -- characters.  Doing it earlier catches the round intro and the victim's
    -- process gets rebuilt underneath the dizzy write.
    if finish_at == 0 and rel > 120 and p1o ~= 0 and p2o ~= 0
       and r16(p1o + O.ochar) == (REPTILE and FT_REPTILE or FT_ERMAC)
       and r16(p2o + O.ochar) == VICTIM then
      w16(A.winner_status, 3); w16(A.f_death, 0)
      local p1p = r32(A.p1_proc)
      if p1p ~= 0 then w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING|PM_SITDUCK|PM_SPECIAL)) end
      local p2p = r32(A.p2_proc)
      if p2p ~= 0 and not dizzy_forced then w32(p2p + P.wake, A.dizzy_dude); dizzy_forced = true end
      finish_at = frame
      log("finish him forced at rel=%d (p1_ochar=%d p2_ochar=%d)", rel,
          r16(p1o + O.ochar), r16(p2o + O.ochar))
    end
    -- Keep asserting it until the input starts; winner_status is rewritten by
    -- the round logic, and a fatality_xfer that arrives one tick after it
    -- flips back reads exactly like a broken combo.
    if finish_at > 0 and input_at == 0 then w16(A.winner_status, 3) end

    if finish_at > 0 and ready_at == 0 then
      local p2p = r32(A.p2_proc)
      local wake = p2p ~= 0 and r32(p2p + P.wake) or 0
      if wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p2p + P.action) == ACT_STUNNED then
        ready_at = frame
        snap_range()
        log("victim dizzy at rel=%d; snapped to dist=%d (p1_x=%d p2_x=%d)",
            rel, DIST, objx(A.p1_obj), objx(A.p2_obj))
      end
    end

    if ready_at > 0 and input_at == 0 and frame - ready_at > 20 then
      input_at = frame; attempts = attempts + 1
      base_y = objy(A.p2_obj)
      log("attempt %d: input starts rel=%d dist=%d p2_y=%d", attempts, rel,
          math.abs(objx(A.p1_obj) - objx(A.p2_obj)), base_y)
    end

    if input_at > 0 then
      local t = frame - input_at
      for _,n in ipairs({DOWN,UP,LEFT,RIGHT,BLK}) do hold(n,false) end
      for _,step in ipairs(PIT and COMBO_PIT or COMBO) do
        if t >= step[1] and t < step[2] then hold(step[3], true) end
      end
      if t <= 60 and t % 4 == 0 then
        log("  input t=%2d p1act=%#x f_death=%#x ws=%d", t, action(A.p1_proc),
            r16(A.f_death), r16(A.winner_status))
      end
      -- Re-arm if the whole motion went past and nothing took.  A silent miss
      -- must not be reported as a broken fatality.
      if t > 150 and not fired then
        log("attempt %d MISSED (f_death still %d) - re-arming", attempts, s16(r16(A.f_death)))
        input_at, ready_at = 0, 0
        if REPTILE and attempts >= NEG_ATTEMPTS and not done then
          done = true
          log("PASS ermac_fatal_slam_not_reptile: %d attempts of D,U,D,D,D + BLOCK as REPTILE, f_death never left 0 (p1_ochar=%d p1act=%#x)",
              attempts, r16(r32(A.p1_obj) + O.ochar), action(A.p1_proc))
          log("finished"); manager.machine:exit()
        end
      end
    end

    local fd = s16(r16(A.f_death))
    if PIT and fd == FD_PIT and not fired then
      -- The pit route owns the rest of the sequence (do_down_the_pit); all
      -- this regression has to show is that ermac_block still REACHES it.
      log("PASS ermac_block_fallthrough: pit fatality fired (f_death=%d) at rel=%d", fd, rel)
      log("finished"); manager.machine:exit(); return
    end
    if REPTILE and fd ~= 0 and not done then
      done = true
      log("FAIL ermac_fatal_slam_not_reptile: REPTILE reached a fatality (f_death=%d) off D,U,D,D,D + BLOCK", fd)
      log("finished"); manager.machine:exit(); return
    end
    if fd == 2 and not fired then
      fired = true; fired_at = frame
      log("FIRED at rel=%d (f_death=2) t=%d", rel, frame - input_at)
    end

    if fired and not ended then
      local t = frame - fired_at
      local dy = base_y and (base_y - objy(A.p2_obj)) or 0
      if dy > lifted then lifted = dy end
      -- One slam = he left the floor and came back to it.  60px of clearance
      -- is well past the shake-up's ~33px wobble, so the shake cannot be
      -- miscounted as a hurl.
      if not airborne and dy > 60 then airborne = true
      elseif airborne and dy < 10 then airborne = false; slams = slams + 1
        log("  SLAM %d at t=%d (peak so far %dpx)", slams, t, lifted) end
      if (objflags2(A.p2_obj) & M_INVISO) ~= 0 and not popped then
        popped = true
        log("POPPED at t=%d (victim inviso - the body is chunks)", t)
      end
      do
        local n, ys = count_splashes()
        if n > splash_max then
          splash_max = n; splash_ys = ys
          table.sort(splash_ys)
          log("SPLASH x%d at t=%d  y=%s", n, t, table.concat(splash_ys, ","))
        end
        if n > 0 then splash_seen = true; sample_splat_pals() end
      end
      if not head_obj then
        local h = find_head(VICTIM)
        if h then
          head_obj, head_at, head_y0 = h, frame, s16(r16(h + O.oypos))
          head_path = true
          log("HEAD at t=%d (obj %#x, y=%d)", t, h, head_y0)
        end
      elseif math.abs(s16(r16(head_obj + O.oypos)) - head_y0) > 8 then
        head_moved = true
      end
      if head_obj and t % 8 == 0 then
        local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end
        log("  head t=%3d y=%d oyval=%d oyvel=%d flags=%#x flags2=%#x", t,
            s16(r16(head_obj + O.oypos)), s32(r32(head_obj + O.oyval)) // 65536,
            s32(r32(head_obj + O.oyvel)), r16(head_obj + 0x0f0),
            r16(head_obj + O.oflags2))
      end
      if t % 8 == 0 then
        log("  t=%3d p2_y=%4d dy=%4d p1act=%#x p2act=%#x f_death=%d",
            t, objy(A.p2_obj), dy, action(A.p1_proc), action(A.p2_proc), fd)
      end
      if SNAP > 0 and t % SNAP == 0 and t <= 420 then manager.machine.video:snapshot() end
      if fd == -1 then
        ended = true; ended_at = frame
        log("ENDED at t=%d (f_death -1: death_blow_complete ran)", t)
      elseif t > 900 then
        ended = true; ended_at = frame
        log("TIMED OUT at t=%d without death_blow_complete", t)
      end
    end

    -- SETTLE.  f_death going to -1 only proves death_blow_complete ran; it
    -- says nothing about whether victory_animation then ran, and a wedged
    -- process is the characteristic failure of this engine - MK2's scheduler
    -- is cooperative, so one stuck process stops the whole game.
    --
    -- The signal is Ermac's own frame pointer MOVING after the fatality ends:
    -- if the process that is supposed to hand him to victory_animation were
    -- spinning, it could not.  Note what this does NOT claim - a_njvictory is
    -- three frames and a terminator, so the pointer legitimately stops
    -- changing once he reaches the last one and holds it.  "settled" means
    -- the victory pass RAN, not that the machine is alive forever.
    if ended and not done then
      local st = frame - ended_at
      local p1o = r32(A.p1_obj)
      -- oshape is the multipart frame pointer a player is drawn from and
      -- osag the single-part blit source; watch both, because which one
      -- moves depends on how the victory lane happens to be authored.
      local shape = p1o ~= 0 and ((r32(p1o + O.oshape) ~ r32(p1o + O.osag)) & 0xffffffff) or 0
      if last_shape ~= nil and shape ~= last_shape then settle_moved = true end
      last_shape = shape

      -- The head lands here, not before: it arrives 0a0h ticks after the pop,
      -- which is ~86 ticks AFTER death_blow_complete.  Watching it in the
      -- settle window is the point, not an accident of where the code sits.
      do
        local n, ys = count_splashes()
        if n > splash_max then
          splash_max = n; splash_ys = ys
          table.sort(splash_ys)
          log("SPLASH x%d at t=%d  y=%s", n, t, table.concat(splash_ys, ","))
        end
        if n > 0 then splash_seen = true; sample_splat_pals() end
      end
      if not head_obj then
        local h = find_head(VICTIM)
        if h then
          head_obj, head_at, head_y0 = h, frame, s16(r16(h + O.oypos))
          log("HEAD at st=%d (obj %#x, y=%d, z=%d)", st, h, head_y0,
              s16(r16(h + O.ozpos)))
          if SNAP > 0 then manager.machine.video:snapshot() end
        end
      else
        -- It has to FALL, not just exist.  head_grav bounces it four times,
        -- so a head that never moves means the object was built and then
        -- nothing drove it.
        if math.abs(s16(r16(head_obj + O.oypos)) - head_y0) > 8 then head_moved = true end
      end

      if st % 30 == 0 then
        log("  settle st=%3d p1act=%#x shape=%#x moved=%s head=%s/%s y=%d", st,
            action(A.p1_proc), shape, tostring(settle_moved),
            tostring(head_obj ~= nil), tostring(head_moved),
            head_obj and s16(r16(head_obj + O.oypos)) or -999)
        -- A wedged cooperative scheduler looks alive on screen (dclipl keeps
        -- applying velocity to the chunks), so the PC is the honest signal: if
        -- it reads the same address sample after sample, the CPU is spinning
        -- there, and sym_resolve.py names the check that failed.
        local okpc, pc = pcall(function()
          return manager.machine.devices[":maincpu"].state["PC"].value end)
        local sn, _, ssags = count_splashes()
        log("    cpu pc=%s  splats live=%d  first splat sag=%s",
            okpc and string.format("%08x", pc) or "?", sn,
            ssags[1] and string.format("%08x", ssags[1]) or "-")
      end
      if HEADDUMP and st % 15 == 0 and st <= 180 then
        local p2p = r32(A.p2_proc)
        -- TOTAL objects on all three lists, fighters included: if the head
        -- is created at all this number goes up by one, whatever my filter
        -- thinks of it.
        local total = 0
        for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
          local o, g = r32(list), 0
          while o ~= 0 and g < 400 do total = total + 1; o = r32(o + O.next); g = g + 1 end
        end
        local p2o2 = r32(A.p2_obj)
        log("    vic st=%3d p2_proc=%#x wake=%#x downcount=%d objs=%d p2obj z=%d ochar=%d y=%d",
            st, p2p, p2p ~= 0 and r32(p2p + P.wake) or 0,
            p2p ~= 0 and r16(p2p + P.downcount) or -1, total,
            s16(r16(p2o2 + O.ozpos)), r16(p2o2 + O.ochar), s16(r16(p2o2 + O.oypos)))
      end
      if HEADDUMP and (st == 30 or st == 105) then
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        for li, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
          local obj, guard, n = r32(list), 0, 0
          while obj ~= 0 and guard < 400 do
            if obj ~= p1o and obj ~= p2o then
              n = n + 1
              -- the chunks are all z=1/ochar=0; anything else is the head
              if r16(obj + O.ochar) ~= 0 or s16(r16(obj + O.ozpos)) ~= 1 then
                log("    dump st=%d list%d obj=%#x z=%d ochar=%d y=%d sag=%#x",
                    st, li, obj, s16(r16(obj+O.ozpos)), r16(obj+O.ochar),
                    s16(r16(obj+O.oypos)), r32(obj+O.osag) & 0xffffff)
              end
            end
            obj = r32(obj + O.next); guard = guard + 1
          end
          log("    dump st=%d list%d total non-fighter objects = %d", st, li, n)
        end
      end
      if st >= SETTLE then
        done = true
        -- An UNMEASURED palette is not a pass and not a failure: if no splat
        -- was ever caught with a live colour map there is nothing to judge,
        -- and scoring that as green is the exact false-green this tree keeps
        -- getting caught by.  It only relaxes the verdict when splash_max
        -- already proves there were no splats to read.
        local pal_got, pal_ok, pal_none = pal_report()
        local ok = fired and popped and slams >= 4 and lifted > 150
                   and s16(r16(A.f_death)) == -1 and settle_moved
                   and head_path and head_obj ~= nil and head_moved
                   and splash_max >= 3 and pal_ok
        log("%s ermac_fatal_slam: fired=%s slams=%d lift=%dpx popped=%s ended=%s settled=%s head=%s(path=%s,fell=%s) splash=%d bloodpal=%s(want %s) victim=%d attempts=%d",
            ok and "PASS" or "FAIL", tostring(fired), slams, lifted, tostring(popped),
            tostring(s16(r16(A.f_death)) == -1), tostring(settle_moved),
            tostring(head_obj ~= nil), tostring(head_path), tostring(head_moved),
            splash_max, pal_got, PAL_WANT, VICTIM, attempts)
        if pal_none then
          log("        BLOODPAL NO VERDICT - no splat was sampled with a live colour map")
        end
        log("        splashes: max %d simultaneous, y=%s", splash_max,
            splash_ys and table.concat(splash_ys, ",") or "-")
        log("finished"); manager.machine:exit()
      end
    end
    if not done and rel > 3000 then
      done = true
      log("FAIL %s: never completed - fired=%s slams=%d lift=%dpx attempts=%d f_death=%d p1act=%#x curback=%d",
          PIT and "ermac_block_fallthrough" or "ermac_fatal_slam",
          tostring(fired), slams, lifted, attempts, s16(r16(A.f_death)),
          action(A.p1_proc), r16(A.curback))
      log("finished"); manager.machine:exit()
    end
  end

  for n,fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 8000 then log("FAIL timeout gs=%d psel=%d fight=%d", gs, psel, fight)
    log("finished"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
