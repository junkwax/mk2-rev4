-- umk3_capture.lua
-- Drive UMK3 far enough to record Ermac's telekinetic slam for comparison
-- against our port.  Written as a probe first: UMK3 has no symbol map here, so
-- everything about its select screen has to be found by looking at it.
--
-- UMK3_MODE:
--   probe   coin up, start, snapshot the select screen, dump the input names
--   fight   navigate to (UMK3_COL,UMK3_ROW), confirm, then throw B,D,B + HK
--           and snapshot every UMK3_SNAP frames once the move is under way
local LOG  = os.getenv("UMK3_LOG") or "umk3_capture.log"
local MODE = os.getenv("UMK3_MODE") or "probe"
local COL  = tonumber(os.getenv("UMK3_COL")  or "0")   -- cursor RIGHT presses
local ROW  = tonumber(os.getenv("UMK3_ROW")  or "0")   -- cursor DOWN presses
local SNAP = tonumber(os.getenv("UMK3_SNAP") or "3")
local BOOT = tonumber(os.getenv("UMK3_BOOT") or "600")  -- frames of button-tapping to clear CMOS
local ATK  = tonumber(os.getenv("UMK3_ATK")  or "900") -- frame to start attacking
local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[umk3] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local fields, held, frame = {}, {}, 0
local function hold(n,on) held[n] = on and true or false end

local function cache()
  local names = {}
  for _,p in pairs(manager.machine.ioport.ports) do
    for _,fld in pairs(p.fields) do
      fields[fld.name] = fld
      names[#names+1] = fld.name
    end
  end
  table.sort(names)
  log("%d input fields:", #names)
  for _,n in ipairs(names) do log("   %s", n) end
end

-- UMK3's field names are discovered by the probe pass; these are the ones the
-- fight pass uses, resolved leniently so a naming difference is a log line
-- rather than a crash.
local function want(...)
  for _,n in ipairs({...}) do if fields[n] then return n end end
  return nil
end
local N = {}

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cache()
    N.coin  = want("Coin 1")
    N.start = want("1 Player Start", "Player 1 Start")
    N.uisel = want("UI Select")
    N.left  = want("P1 Left")
    N.right = want("P1 Right")
    N.down  = want("P1 Down")
    N.hk    = want("P1 High Kick")
    N.hp    = want("P1 High Punch")
    N.lp    = want("P1 Low Punch")
    for k,v in pairs(N) do log("bound %-6s -> %s", k, v) end
    log("MODE=%s COL=%d ROW=%d ATK=%d", MODE, COL, ROW, ATK)
  end

  -- Boot.  UMK3 is far slower to come up than MK2 and stops on a CMOS error
  -- screen ("ERRORS DETECTED -- ANY BUTTON TO CONTINUE") that a UI key does
  -- NOT clear - it wants a GAME button.  So tap High Punch right through the
  -- boot as well as pressing UI Select for MAME's own warning screen.
  local booting = frame < BOOT
  if N.uisel then hold(N.uisel, frame>=5 and frame<40) end
  if booting and N.hp then hold(N.hp, (frame%40) < 8) end
  if N.coin  then hold(N.coin,  frame>=BOOT and frame<BOOT+900 and (frame%100)<25) end
  if N.start then hold(N.start, frame>=BOOT+80 and frame<BOOT+900 and (frame%100)>=50 and (frame%100)<75) end

  if MODE == "probe" then
    -- Snapshot a spread of moments so whatever screen we land on is visible.
    if frame % 250 == 0 then
      manager.machine.video:snapshot(); log("snapshot at frame %d", frame)
    end
    if frame > 4500 then log("probe done"); manager.machine:exit() end
    for n,f in pairs(fields) do if held[n] ~= nil then f:set_value(held[n] and 1 or 0) end end
    return
  end

  -- fight mode -----------------------------------------------------------
  -- Walk the select cursor, then confirm, then attack.  Each cursor press is
  -- 4 frames on / 8 off: UMK3 debounces the stick, so a held direction moves
  -- once, not once per frame.
  local t = frame - 620
  if t >= 0 then
    local step = t // 12
    if step < COL then
      if N.right then hold(N.right, (t%12) < 4) end
    elseif step < COL + ROW then
      if N.right then hold(N.right,false) end
      if N.down then hold(N.down, (t%12) < 4) end
    elseif step == COL + ROW then
      if N.down then hold(N.down,false) end
      if N.hp then hold(N.hp, (t%12) < 4) end     -- confirm
    else
      if N.hp then hold(N.hp,false) end
    end
  end

  if frame == ATK - 30 then manager.machine.video:snapshot(); log("pre-attack shot") end

  -- B,D,B + HK, re-thrown every 120 frames until something happens.
  if frame >= ATK then
    local a = (frame - ATK) % 120
    if N.left  then hold(N.left,  a>=0  and a<4) end
    if N.down  then hold(N.down,  a>=6  and a<10) end
    if N.left  then if a>=12 and a<16 then hold(N.left,true) end end
    if N.hk    then hold(N.hk,    a>=17 and a<21) end
    if a >= 22 and a % SNAP == 0 then manager.machine.video:snapshot() end
  end

  for n,f in pairs(fields) do if held[n] ~= nil then f:set_value(held[n] and 1 or 0) end end
  if frame > (ATK + 900) then log("fight pass done"); manager.machine:exit() end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
