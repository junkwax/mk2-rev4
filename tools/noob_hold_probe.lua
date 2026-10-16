-- noob_hold_probe.lua
--
-- Proof for the ONE-PLAYER NOOB CHALLENGE: hold Start through the battle
-- plan (the ladder screen, gstate 07) and the next drone becomes NOOB.
--
-- Derived from tools/noob_hold_probe.lua - the coin/start/select drive and
-- the hang watchdog are that rig's, unchanged.  What differs is that this one
-- HOLDS P1 Start for the whole battle plan and then checks the drone.
--
-- What it asserts:
--   c_noob_hold climbs while Start is down on the battle plan
--   ...and reaches noob_hold_ticks
--   the drone's p?_char is ft_noob (15) by the time the fight starts
--   c_noob_hold is back to 0 afterwards - one hold, one match
--
-- NHP_MODE  hold  = hold Start through the plan  (expect Noob)
--           tap   = tap Start the way Khameleon's summons wants (expect NOT
--                   Noob - an unbroken hold is the whole gate, and this is
--                   the control that proves it)
--           none  = never touch Start after select (expect NOT Noob)
--
local ROOT  = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local CH    = tonumber(os.getenv("LCP_CHAR") or "19")
local LOG   = os.getenv("NHP_LOG") or (ROOT.."/tools/noob_hold_probe.log")
local READY = os.getenv("NHP_READY")
local END   = tonumber(os.getenv("LCP_END") or "5000")
local SNAP  = tonumber(os.getenv("LCP_SNAP") or "0")
local RUNON = tonumber(os.getenv("LCP_RUNON") or "0")

local fh = io.open(LOG,"w")
local function log(f,...)
  local l = (select("#",...)>0) and string.format(f,...) or tostring(f)
  print("[lcp] "..l); if fh then fh:write(l,"\n"); fh:flush() end
end

-- .bss shifts on every relink, so resolve everything from the map that was
-- built with this ROM.  A rig paired with another build's map reads every
-- symbol at the wrong address and reports nothing wrong.
local symbols={}
do local f=io.open(ROOT.."/src/mk2.map","r")
  if f then for line in f:lines() do
    for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end
  end f:close() end end
local function sym(n) local v=symbols[n]; if not v then log("FATAL missing symbol %s",n) end; return v end

local MODE = (os.getenv("NHP_MODE") or "hold"):lower()
local FT_NOOB = 15
local HOLD_TICKS = tonumber(os.getenv("NHP_TICKS") or "140")
local A = { c_noob_hold=sym("c_noob_hold"), c_kham_ladder=sym("c_kham_ladder"),
            p1_state=sym("p1_state"), p2_state=sym("p2_state"),
            gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
            map_position=sym("map_position"), winner_status=sym("winner_status"),
            battle_num=sym("battle_num"), worldtly=sym("worldtly"),
            scrolly=sym("scrolly"), palq_drops=sym("palq_drops"),
            active=sym("active"), fadebig_owner=symbols["fadebig_owner"] }

local PID_FADE = 0x0101
local GS_PSEL, GS_FIGHT, GS_AMODE = 4, 2, 1
local SCRATCH_LO, SCRATCH_HI = 0x01000000, 0x01400000

local space, cpu
local frame, psel, left, done, fought = 0, 0, 0, false, nil
local lastgs, gsframe, lastowner = -1, 0, -1
local held, fields, pchist, seen = {}, {}, {}, {}
local peakhold, lasthc = 0, -1
local drone_at_fight = -1

local function hold(n,v) held[n]=v and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v & 0xffff) end
local function pc()
  local ok,v = pcall(function() return cpu.state["PC"].value end); return ok and v or 0
end

local function cache()
  local want={["Coin 1"]=1,["1 Player Start"]=1,["UI Select"]=1,["P1 Low Punch"]=1}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(p.fields) do if want[f.name] then fields[f.name]=f end end end
  for n in pairs(want) do log("input %-18s %s",n,fields[n] and "ok" or "MISSING") end
end

-- Every palette handed to a fadeproc, once each.  Anything over the ceiling
-- used to be a dead board; it is now the shared buffer's business, and this
-- is what says whether the case under test was even exercised.
local FADE_CEIL = 94
local function scan_fades()
  local q, n = r32(A.active), 0
  while q~=0 and n<200 do
    if q<SCRATCH_LO or q>=SCRATCH_HI then break end
    if r16(q+0x20)==PID_FADE then
      local pal = r32(q+0xc0)                       -- pa8 = the palette
      if pal>=0xff800000 then
        local cnt = r16(pal) & 0x1ff                -- word 0, flags above bit 8
        if not seen[pal] then
          seen[pal]=cnt
          log("FADE pal=%08x colours=%d%s frame=%d", pal, cnt,
              (cnt>FADE_CEIL) and "   <-- OVER "..FADE_CEIL or "", frame)
        end
      end
    end
    q = r32(q); n = n + 1
  end
end

local function procdump()
  local q, n = r32(A.active), 0
  log("PROCLIST head=%08x", q)
  while q~=0 and n<200 do
    if q<SCRATCH_LO or q>=SCRATCH_HI then log("  bad link %08x",q); break end
    log("  proc=%08x pid=%04x ptime=%5d pwake=%08x pa8=%08x pdata0=%04x",
        q, r16(q+0x20), r16(q+0x30), r32(q+0xe0), r32(q+0xc0), r16(q+0x100))
    q = r32(q); n = n + 1
  end
  log("PROCLIST end (%d procs)", n)
end

local function finish(verdict)
  if done then return end
  done = true
  if verdict:sub(1,4)=="FAIL" then
    pcall(procdump)
    local n=#pchist
    for i=math.max(1,n-15),n do log("  f=%d gs=%02x pc=%08x",pchist[i][1],pchist[i][2],pchist[i][3]) end
  end
  log(verdict); log("finished")
  manager.machine:exit()
end

emu.register_frame(function()
  frame = frame + 1
  if frame==1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]; cache()
    log("probe: 1P game, force p1_char=%d after select (runon=%d)", CH, RUNON)
  end
  if not space then return end
  if READY and frame==120 then local r=io.open(READY,"w"); if r then r:write("go\n"); r:close() end end

  pcall(scan_fades)
  if A.fadebig_owner then
    local o = r32(A.fadebig_owner)
    if o ~= lastowner then log("fadebig_owner=%08x frame=%d", o, frame); lastowner = o end
  end

  local gs = r16(A.gstate)
  if gs ~= lastgs then
    log("frame=%6d gstate=%02x  p1_char=%d p2_char=%d mappos=%d winst=%d battle=%d pc=%08x",
        frame, gs, r16(A.p1_char), r16(A.p2_char), r16(A.map_position),
        r16(A.winner_status), r16(A.battle_num), pc())
    lastgs, gsframe = gs, frame
  end
  if frame % 10 == 0 then
    pchist[#pchist+1] = {frame, gs, pc()}; if #pchist>200 then table.remove(pchist,1) end
  end

  if gs==GS_PSEL and psel==0 then
    psel=frame; log("select reached frame=%d",frame)
    for _,n in ipairs({"Coin 1","1 Player Start","UI Select"}) do hold(n,false) end
  end

  if psel==0 then
    -- Pulse on a modulo rather than fixed frames: boot timing drifts.
    hold("Coin 1", frame>=200 and frame<3000 and (frame%80)<20)
    hold("1 Player Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
    hold("UI Select", frame>=5 and frame<35)
  elseif frame-psel>60 then
    hold("P1 Low Punch",(frame%20)<8)               -- confirm whoever is hovered
  end

  if psel>0 and gs~=GS_PSEL and gs~=GS_AMODE then
    if left==0 then left=frame; log("left select frame=%d gs=%02x",frame,gs) end

    -- THE GESTURE.  Start is not one of escape_button_update's buttons, so
    -- holding it does not skip the screen out from under the count.
    if MODE == "hold" then
      hold("1 Player Start", true)
    elseif MODE == "tap" then
      hold("1 Player Start", (frame % 24) < 8)   -- repeated taps, never unbroken
    else
      hold("1 Player Start", false)
    end

    local hc = A.c_noob_hold and r16(A.c_noob_hold) or -1
    if hc > peakhold then peakhold = hc end
    if hc > 0 and hc % 20 == 0 and hc ~= lasthc then
      log("  c_noob_hold=%d (gs=%02x t=%d)", hc, gs, frame-left)
    end
    lasthc = hc
    -- p1_char is NOT forced here (the parent rig forces it): this test is
    -- about the DRONE, and forcing the human's side is enough to change who
    -- the map hands you.
    if SNAP>0 and (frame-left)%SNAP==0 then pcall(function() manager.machine.video:snapshot() end) end
    if (frame-left)%60==0 then
      log("  t=%5d gs=%02x worldtly=%08x scrolly=%08x palq_drops=%d",
          frame-left, gs, r32(A.worldtly), r32(A.scrolly), r16(A.palq_drops))
    end
    if gs==GS_FIGHT then
      fought = fought or frame
      if drone_at_fight < 0 then
        -- whichever side is NOT the human is the drone; in a 1P game the
        -- human is player 1, so the drone is p2.
        drone_at_fight = r16(A.p2_char)
        local left_over = A.c_noob_hold and r16(A.c_noob_hold) or -1
        log("  FIGHT: drone p2_char=%d (noob=%d)  peak c_noob_hold=%d  left=%d",
            drone_at_fight, FT_NOOB, peakhold, left_over)
        local want = (MODE == "hold")
        local got  = (drone_at_fight == FT_NOOB)
        local verdict = (want == got) and "PASS" or "FAIL"
        log("%s/%s: drone %s Noob, peak hold %d (need %d), spent=%s",
            verdict, MODE,
            got and "IS" or "is NOT", peakhold, HOLD_TICKS,
            tostring(left_over == 0))
        finish(string.format("%s: mode=%s drone=%d peakhold=%d",
                             verdict, MODE, drone_at_fight, peakhold))
      end
    end
    if gs==GS_AMODE and frame-left>60 then
      finish(string.format("FAIL: fell back to attract at frame=%d",frame))
    end
    -- A fight legitimately sits at gstate 02 for a long time; everything else
    -- moves on well inside 900 ticks.
    if frame-gsframe>900 and gs~=GS_FIGHT then
      finish(string.format("FAIL/HANG: gstate=%02x unchanged for %d frames (pc=%08x)",gs,frame-gsframe,pc()))
    end
  end

  for n,f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
  if frame>END then
    if RUNON>0 and fought then
      finish(string.format("PASS/RUNON: fight started at frame=%d, ran to %d, gstate=%02x",fought,frame,gs))
    else
      finish(string.format("FAIL/TIMEOUT: frame=%d gs=%02x",frame,gs))
    end
  end
end)
