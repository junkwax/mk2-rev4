-- battle_stability_sweep.lua
-- Force one matchup+stage, drive P1 to both stage edges (stressing the camera
-- scroll clamp) while P2's AI fights, and watch for:
--   * crashes  : PC in [system_lockup, TVBP)
--   * bad gstate
--   * object-list cycle / explosion, active-proc cycle
--   * "level out of scope": camera worldtlx escaping [left_edge, right_edge]
--   * players flung to insane coordinates
-- One battle per MAME run; run_battle_stability_sweep.ps1 loops the battle list.
-- Env: SWEEP_P1, SWEEP_P2, SWEEP_STAGE (curback idx), SWEEP_OBSERVE (frames),
--      SWEEP_LABEL, SWEEP_LOG.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local P1 = tonumber(os.getenv("SWEEP_P1") or "1")
local P2 = tonumber(os.getenv("SWEEP_P2") or "11")
local STAGE = tonumber(os.getenv("SWEEP_STAGE") or "0")
local OBSERVE = tonumber(os.getenv("SWEEP_OBSERVE") or "700")
-- SWEEP_P2_HUMAN=1 makes P2 a second JOYSTICK player instead of the drone.
-- It has to be decided here, not from an addon: MKGUYS.ASM reads p2_state
-- once, when it creates the fighters, and force_matchup below rewrites that
-- word every frame of character select - so an addon setting it loses the
-- race and silently gets a drone anyway.
local P2_HUMAN = (os.getenv("SWEEP_P2_HUMAN") == "1")
-- SWEEP_NO_HP_PIN=1 stops the harness holding p1_bar at full. The pin exists
-- to keep a battle running its whole window, but it also makes P1's damage
-- INVISIBLE - and the drone is P2, so P1 is the one being hit. Any rig that
-- measures damage has to turn it off, and two rigs have now silently measured
-- zero because it was on. It ALSO stops the harness clearing winner_status,
-- because both are the same thing - refusing to let a round finish - and a rig
-- watching round outcomes needs neither.
local NO_HP_PIN = (os.getenv("SWEEP_NO_HP_PIN") == "1")
local LABEL = os.getenv("SWEEP_LABEL") or string.format("p%d_vs_p%d_stage%d", P1, P2, STAGE)
local LOG = os.getenv("SWEEP_LOG") or (ROOT .. "/tools/battle_stability_sweep.log")

local logfh = io.open(LOG, "a")
local frame = 0
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[sweep] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n,fb) local v=symbols[n]; if v then return v end; if fb==nil then log("WARN missing %s",n) end; return fb end

local A = {
  active=sym("active"), gstate=sym("gstate"), curback=sym("curback"),
  map_position=sym("map_position",0), battle_num=sym("battle_num",0),
  p1_char=sym("p1_char"), p2_char=sym("p2_char"),
  p1_state=sym("p1_state"), p2_state=sym("p2_state"),
  p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
  p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
  p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
  worldtlx=sym("worldtlx"), left_edge=sym("left_edge"), right_edge=sym("right_edge"),
  objlst=sym("objlst"), objlst2=sym("objlst2",0), objlst3=sym("objlst3",0),
  system_lockup=sym("system_lockup"), tvbp=sym("TVBP"),
  winner_status=sym("winner_status",0),
}
local O = { next=0, oxpos=0x090, oypos=0x0b0, oxval=0x080 }
local P = { next=0 }
local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE, PS_INACTIVE = 1, 0
local MAX_HP = 0xA1

local cpu, space, input, fields = nil, nil, nil, {}
local last_gs=-1
local charsel_frame, fighting_frame = 0, 0
local p1_confirm=0
local did_select=false
local fight_start_logged=false
local anomalies={}
local scope_flagged=false
local finished=false
local walk_dir=1
local walk_flip=0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a,v&0xffff) end
local function w32(a,v) space:write_u32(a,v&0xffffffff) end
local function s16(v) v=v&0xffff; if v>=0x8000 then return v-0x10000 end; return v end

-- Fields an addon has claimed for the duration of a fight.
--
-- Bound through _G explicitly. MAME runs this script with its own _ENV, so a
-- bare `ADDON_OWNS = {}` here lands in the chunk's environment - while the
-- addon is pulled in with dofile, which resolves against the REAL globals and
-- would see nil. Both sides have to name the same table.
_G.ADDON_OWNS = {}
local ADDON_OWNS = _G.ADDON_OWNS

local function cache_fields()
  local want={["UI Select"]=1,["Coin 1"]=1,["1 Player Start"]=1,["P1 High Punch"]=1,
    ["P1 Left"]=1,["P1 Right"]=1,["P2 High Punch"]=1,["P2 Up"]=1}
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(port.fields) do if want[f.name] then fields[f.name]=f end end end
end
local held={}
local function hold(n,on) held[n]=on and true or false end

local function main_screen()
  local ok,s=pcall(function() return manager.machine.screens[":screen"] end); if ok and s then return s end
  ok,s=pcall(function() return manager.machine.screens:at(1) end); return ok and s or nil
end
local function snap(tag)
  local s=main_screen(); if not s then return end
  pcall(function() s:snapshot() end)
  log("SNAP %s label=%s frame=%d", LABEL, tag, frame)
end

local function cpu_pc()
  for _,n in ipairs({"PC","CURPC","GENPC"}) do
    local ok,it=pcall(function() return cpu.state[n] end)
    if ok and it then local okv,v=pcall(function() return it.value end); if okv then return v end end
  end
  return nil
end

local function count_list(head, offnext, cap)
  local p=r32(head); local n=0; local seen={}
  while p~=0 and n<cap do if seen[p] then return n,true end; seen[p]=true; n=n+1; p=r32(p+offnext) end
  return n,false
end

-- On a lockup the PC only tells us a trap fired, not what faulted. The
-- TMS34010 pushes the faulting address, so dump both stacks here -- this is
-- the only place the bad state is still on screen. Feed the words to
--   python sym_resolve.py --stack <w0> <w1> ...
local function dump_fault()
  local names={"A0","A1","A2","A3","A4","A5","A6","A7","A8","A9","A10","A11",
               "A12","A13","A14","SP","PC","ST"}
  local line=""
  for _,n in ipairs(names) do
    local ok,it=pcall(function() return cpu.state[n] end)
    if ok and it then line=line..string.format("%s=%08x ", n, it.value & 0xffffffff) end
  end
  log("  FAULT REGS %s", line)
  for _,which in ipairs({"SP","A12"}) do
    local ok,it=pcall(function() return cpu.state[which] end)
    if ok and it then
      local base=it.value
      local w={}
      for i=0,11 do
        local ok2,v=pcall(function() return r32(base+i*32) end)
        w[#w+1]=string.format("%08x", ok2 and (v & 0xffffffff) or 0)
      end
      log("  FAULT %s=%08x stack: %s", which, base & 0xffffffff, table.concat(w," "))
    end
  end
  local o2=r32(A.p2_obj)
  log("  FAULT p1_act=0x%04x p2_act=0x%04x p2_ochar=%d",
      (function() local q=r32(A.p1_proc); return q~=0 and r16(q+0x1f0) or 0xffff end)(),
      (function() local q=r32(A.p2_proc); return q~=0 and r16(q+0x1f0) or 0xffff end)(),
      o2~=0 and r16(o2+0x1a0) or -1)
end

-- Optional instruction trace, for hunting a deterministic lockup. Needs
-- MAME started with -debug. Set SWEEP_TRACE_FROM to a frame a little before
-- the crash: a full trace of the whole battle would be hundreds of MB, but a
-- dozen frames ending at the fault is small and says exactly what ran.
local TRACE_FROM = tonumber(os.getenv("SWEEP_TRACE_FROM") or "0")
local tracing = false
local function dbg(cmd)
  local ok, d = pcall(function() return manager.machine.debugger end)
  if ok and d then pcall(function() d:command(cmd) end); return true end
  return false
end

local function record(kind, detail)
  if not anomalies[kind] then
    anomalies[kind]=detail
    log("ANOMALY %s: %s=%s (frame=%d rel=%d)", LABEL, kind, detail, frame, frame-(fighting_frame>0 and fighting_frame or frame))
    if kind=="CRASH_lockup" then
      pcall(dump_fault)
      if tracing then dbg("trace off"); log("  trace closed at fault") end
    end
    snap("anomaly_"..kind)
  end
end

local function force_matchup()
  w16(A.p1_state, PS_ACTIVE)
  w16(A.p2_state, P2_HUMAN and PS_ACTIVE or PS_INACTIVE)
  w16(A.p1_char, P1)
  w16(A.p2_char, P2)
  w16(A.curback, STAGE)
  if A.map_position~=0 then w16(A.map_position, STAGE) end
  if A.battle_num~=0 then w16(A.battle_num, 1) end
  if not did_select then did_select=true; log("force %s: p1=%d p2=%d stage=%d", LABEL, P1, P2, STAGE) end
end

local function check_crash()
  local pc=cpu_pc()
  if pc and A.system_lockup and A.tvbp and pc>=A.system_lockup and pc<A.tvbp then
    record("CRASH_lockup", string.format("pc=0x%08x", pc)); return true end
  local gs=r16(A.gstate)
  if gs==0xffff or gs>0x40 then record("bad_gstate", string.format("0x%04x",gs)); return true end
  return false
end

local function check_corruption()
  local no,oerr=count_list(A.objlst, O.next, 300)
  if oerr then record("objlist_cycle", "at objlst") end
  if no>240 then record("object_explosion", tostring(no)) end
  local np,perr=count_list(A.active, P.next, 400)
  if perr then record("active_proc_cycle", "at active") end
end

local function check_scope()
  if not (A.worldtlx and A.left_edge and A.right_edge) then return end
  local wx = s16(r32(A.worldtlx) >> 16)         -- integer part of the camera x
  local le = s16(r16(A.left_edge))
  local re = s16(r16(A.right_edge))
  local MARGIN = 12
  if wx < le - MARGIN or wx > re + MARGIN then
    record("level_out_of_scope", string.format("worldtlx=%d bounds=[%d,%d]", wx, le, re))
  end
end

local function check_players()
  for _,o in ipairs({A.p1_obj, A.p2_obj}) do
    local obj=r32(o); if obj~=0 then
      local y=s16(r16(obj+O.oypos))
      -- big jumps/launches (esp. Kintaro's pounce) legitimately go well above
      -- the screen top for a frame; only flag a truly lost player.
      if y < -400 or y > 520 then record("player_offscreen_y", tostring(y)) end
    end
  end
end

emu.register_frame(function()
  frame=frame+1
  if frame==1 then
    cpu=manager.machine.devices[":maincpu"]; space=cpu.spaces["program"]; input=manager.machine.input
    cache_fields()
    log("=== BATTLE %s === p1=%d p2=%d stage=%d observe=%d", LABEL, P1, P2, STAGE, OBSERVE)
  end
  if not space then return end
  if TRACE_FROM>0 and not tracing and frame>=TRACE_FROM then
    if dbg(string.format("trace %s,0", (os.getenv("SWEEP_TRACE_FILE") or "crash_trace.txt"))) then
      tracing=true; log("  TRACE started at frame %d", frame)
    end
  end
  local gs=r16(A.gstate)
  if gs~=last_gs then
    if gs==GS_PSEL and charsel_frame==0 then charsel_frame=frame end
    if gs==GS_FIGHTING and fighting_frame==0 then fighting_frame=frame
      log("fight_start %s frame=%d", LABEL, frame); snap("fight_start") end
    last_gs=gs
  end

  -- boot -> select
  local function pressed(name)
    if fighting_frame>0 then
      -- during fight: drive P1 back and forth to push camera to both edges
      if name=="P1 Left" then return walk_dir<0 end
      if name=="P1 Right" then return walk_dir>0 end
      return false
    end
    if charsel_frame==0 then
      if name=="Coin 1" then return frame>=200 and frame<1000 and (frame%80)<20 end
      if name=="1 Player Start" then return frame>=1000 and frame<1080 end
      if name=="UI Select" then return frame>=5 and frame<35 end
      return false
    end
    if name=="P1 High Punch" and p1_confirm>0 then return frame>=p1_confirm and frame<p1_confirm+45 end
    if P2_HUMAN and name=="P2 High Punch" and p1_confirm>0 then return frame>=p1_confirm and frame<p1_confirm+45 end
    return false
  end

  if charsel_frame>0 and fighting_frame==0 then
    force_matchup()
    if p1_confirm==0 and frame-charsel_frame>90 then p1_confirm=frame end
  end

  if fighting_frame>0 then
    -- keep P1 alive so the battle keeps running the full window
    if not NO_HP_PIN then w16(A.p1_bar, MAX_HP) end
    if A.winner_status~=0 and not NO_HP_PIN then w16(A.winner_status,0) end
    -- walk P1 fully toward one corner, then the other, so the camera is
    -- driven to right_edge then left_edge (stressing both clamp sides)
    local wrel = frame-fighting_frame
    if wrel < OBSERVE*0.45 then walk_dir=1 else walk_dir=-1 end

    check_crash()
    check_corruption()
    -- ONLY WHILE A FIGHT IS ACTUALLY RUNNING. fighting_frame is set once and
    -- never cleared, so with -NoHpPin the round ends and this loop follows
    -- the game through bonus -> next match -> continue -> game over ->
    -- attract mode. Out there the camera and left_edge/right_edge are not a
    -- live pair at all, and comparing them manufactured a 769-frame
    -- `level_out_of_scope worldtlx=0 bounds=[128,816]` on a build with
    -- nothing wrong: the stage had been torn down (the anomaly snapshot is a
    -- black screen) and the bounds were the previous fight's.
    --
    -- check_crash stays OUTSIDE this gate on purpose - a lockup in attract
    -- mode is still a lockup, and is exactly the kind of thing a long
    -- -NoHpPin run is good at finding.
    if gs==GS_FIGHTING then
      check_scope()
      check_players()
    end

    local rel=frame-fighting_frame
    if rel==1 or rel%150==0 then
      local wx = A.worldtlx and s16(r32(A.worldtlx)>>16) or 0
      log("  %s rel=%d wx=%d bounds=[%d,%d] objs=%d p1hp=%d p2hp=%d", LABEL, rel, wx,
        s16(r16(A.left_edge)), s16(r16(A.right_edge)), (count_list(A.objlst,O.next,300)), r16(A.p1_bar), r16(A.p2_bar))
    end
    if rel>=OBSERVE and not finished then
      finished=true
      local n=0; for _ in pairs(anomalies) do n=n+1 end
      if n==0 then log("PASS %s: clean (%d frames)", LABEL, OBSERVE)
      else local list={}; for k in pairs(anomalies) do list[#list+1]=k end
        log("FAIL %s: %d anomalies [%s]", LABEL, n, table.concat(list,",")) end
      log("battle_done %s", LABEL)
      manager.machine:exit()
    end
  end

  for n,f in pairs(fields) do
    -- P2's stick belongs to the addon during a fight; this loop runs first
    -- and would otherwise zero whatever the addon just asked for.
    --
    -- ADDON_OWNS lets an addon claim P1's fields on the same terms, and any
    -- addon comparing the two players MUST claim them. Without it the harness
    -- keeps driving "P1 Left"/"P1 Right" through the fight to make battles
    -- progress while P2 stands still - so the two fighters are in different
    -- states, the same button produces different moves, and a rig that scores
    -- "who won" is really scoring "who was being walked". That is what made a
    -- mirror match report a side advantage: at 64px P1 produced a knee and P2
    -- a mid kick, from the same character on the same frame.
    local owned = fighting_frame>0 and
                  (ADDON_OWNS[n] or (P2_HUMAN and n:sub(1,2)=="P2"))
    if not owned then
      f:set_value(pressed(n) and 1 or 0)
    end
  end

  if fighting_frame==0 and frame>6000 then log("FAIL %s: never_reached_fight", LABEL); log("battle_done %s",LABEL); manager.machine:exit() end
  if frame>20000 then log("FAIL %s: global_timeout", LABEL); log("battle_done %s",LABEL); manager.machine:exit() end
end)

-- Optional experiment hook: if tools/sweep_addon.lua exists it is loaded after
-- this harness is set up, so a probe can piggyback on the character-select and
-- fight sequence instead of reimplementing it.  Delete the file to disable.
-- (Deliberately a file check, not an env var: Start-Process does not reliably
-- carry one through to MAME's Lua.)
do
  local addon = ROOT .. "/tools/sweep_addon.lua"
  local probe = io.open(addon, "r")
  if probe then
    probe:close()
    local ok, err = pcall(dofile, addon)
    if not ok then print("[sweep] addon failed: " .. tostring(err)) end
  end
end

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
