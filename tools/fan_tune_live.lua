-- fan_tune_live.lua - tune Kitana's fan boomerang turn LIVE.
--
-- Launch with tools/run_fan_tune_live.ps1.  Boots a Kitana vs (idle) Jax
-- fight, then edits `fan_tune` (MKZAP.ASM) IN THE LOADED ROM: every number
-- the turn is shaped by is data there, so a change applies to the next tick
-- of the next (or current) throw with no rebuild.
--
-- Writes go through the :maincpu REGION, not the program space - the program
-- space maps ROM read-only, so a space:write to it is silently dropped.  The
-- region is what the CPU actually reads from, which is checked at start-up.
--
-- KEYS (none of them are MK2 player keys):
--   J / L      previous / next curl tick (the column)
--   I / K      previous / next row: PACE, TURN, TICKS, COAST, HALF, BEND
--   U / O      value down / up        (hold Shift for x4 on BEND)
--   T          throw one boomerang    Y   auto-throw on/off
--   H          aim during auto-throw: none / down / up
--   G          ghost P2 (fan passes through him) on/off
--   P          pin the layout (P1 left, P2 right) on/off
--   M          save the current numbers -> tools/fan_tune_saved.txt
--              (then: python tools/fan_tune_apply.py bakes them into MKZAP)
--   N          reset to the numbers the ROM was built with
--   V          hide / show the overlay
-- You can also just play Kitana yourself: HP+LP throws, keep HP held to bring
-- it back.  The rig only drives the buttons while T / auto is throwing.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG  = os.getenv("FANTUNE_LOG") or (ROOT.."/tools/fan_tune_live.log")
local SAVE = (os.getenv("FANTUNE_SAVE") or (ROOT.."/tools/fan_tune_saved.txt")):gsub("\\","/")
local READY = LOG..".ready"
local SELFTEST = (os.getenv("FANTUNE_SELFTEST") or "") ~= ""
os.remove(READY)

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local s = "[fantune] "..(select("#",...)>0 and string.format(f,...) or tostring(f))
  print(s); if logfh then logfh:write(s,"\n"); logfh:flush() end
end

------------------------------------------------------------------ symbols
local symbols = {}
-- the launcher hands over the map it packaged WITH the zip: the tree's own
-- src/mk2.map moves whenever any session relinks
local MAP = (os.getenv("FANTUNE_MAP") or (ROOT.."/src/mk2.map")):gsub("\\","/")
do local fh=io.open(MAP,"r")
  if fh then for line in fh:lines() do
    for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end
  end fh:close() end end
local function sym(n) return symbols[n] end

local A = {
  active=sym("active"), gstate=sym("gstate"), curback=sym("curback"),
  map_position=sym("map_position"), battle_num=sym("battle_num"),
  p1_char=sym("p1_char"), p2_char=sym("p2_char"),
  p1_state=sym("p1_state"), p2_state=sym("p2_state"),
  p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"), p1_proc=sym("p1_proc"),
  p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
  winner_status=sym("winner_status"), tick=sym("tick"),
  f_jade_flash=sym("f_jade_flash"), f_freeze_timer=sym("f_freeze_timer"),
  worldtlx=sym("worldtlx"), worldtly=sym("worldtly"),
  fan_tune=sym("fan_tune"),
}

local O = { oxval=0x080, oxpos=0x090, oyval=0x0a0, oypos=0x0b0, oxvel=0x040, oyvel=0x060 }
local P = { next=0x000, procid=0x020, pa8=0x0c0, action=0x1f0 }
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KITANA, FT_JAX = 4, 11
local MAX_HP = 0xA1
local PID_PROJ1 = 0x0700
local ROM_ORG = 0xFF800000

-- fan_tune layout, bit offsets - MUST match the block in MKZAP.ASM
local T = { coast=0, half=16, bend=32, ticks=64, turn=80, pace=464, max=24 }

local cpu, space, region, input, screen = nil, nil, nil, nil, nil
local fields = {}
local frame = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v=v&0xffff; if v>=0x8000 then return v-0x10000 end; return v end
local function s32(v) v=v&0xffffffff; if v>=0x80000000 then return v-0x100000000 end; return v end

-- ROM through the region (byte offset = bit offset / 8)
local function roff(bit) return (A.fan_tune + bit - ROM_ORG) >> 3 end
local function rom16(bit) return region:read_u16(roff(bit)) end
local function rom32(bit) return region:read_u32(roff(bit)) end
local function wrom16(bit,v) region:write_u16(roff(bit), v & 0xffff) end
local function wrom32(bit,v) region:write_u32(roff(bit), v & 0xffffffff) end

------------------------------------------------------------------- tuning
local V, DEF = nil, nil      -- current values, and the build's own

local function read_tune()
  local t = { coast=rom16(T.coast), half=rom16(T.half), bend=rom32(T.bend),
              ticks=rom16(T.ticks), turn={}, pace={} }
  for i=1,T.max do
    t.turn[i] = rom16(T.turn + (i-1)*16)
    t.pace[i] = rom16(T.pace + (i-1)*16)
  end
  return t
end
local function copy(t)
  local c = { coast=t.coast, half=t.half, bend=t.bend, ticks=t.ticks, turn={}, pace={} }
  for i=1,T.max do c.turn[i]=t.turn[i]; c.pace[i]=t.pace[i] end
  return c
end
local function write_tune()
  wrom16(T.coast, V.coast); wrom16(T.half, V.half); wrom32(T.bend, V.bend)
  wrom16(T.ticks, V.ticks)
  for i=1,T.max do
    wrom16(T.turn + (i-1)*16, V.turn[i])
    wrom16(T.pace + (i-1)*16, V.pace[i])
  end
end

-- what the table predicts: total angle, and the cross-track sweep in throw
-- speeds (what fan_ret_bend has to pay back - the shipped curl is ~4.0)
local function predict()
  local th, sweep, run, maxrun = 0, 0, 0, 0
  for i=1,V.ticks do
    local n = V.turn[i]
    if n>0 then th = th + 2.0^(-n) end
    sweep = sweep + V.pace[i]/8 * math.sin(th)
    run = run + V.pace[i]/8 * math.cos(th)
    if run > maxrun then maxrun = run end
  end
  return th, sweep, maxrun
end

local function save()
  local fh = io.open(SAVE, "w")
  if not fh then log("cannot write %s", SAVE); return end
  local turn, pace = {}, {}
  for i=1,T.max do turn[i]=tostring(V.turn[i]); pace[i]=tostring(V.pace[i]) end
  fh:write(string.format("coast %d\nhalf %d\nbend %d\nticks %d\n", V.coast, V.half, V.bend, V.ticks))
  fh:write("turn "..table.concat(turn," ").."\n")
  fh:write("pace "..table.concat(pace," ").."\n")
  fh:close()
  log("saved -> %s  (python tools/fan_tune_apply.py bakes it into MKZAP.ASM)", SAVE)
  log("  ticks=%d coast=%d half=%d bend=0x%x", V.ticks, V.coast, V.half, V.bend)
  log("  pace %s", table.concat(pace," ",1,V.ticks))
  log("  turn %s", table.concat(turn," ",1,V.ticks))
end

------------------------------------------------------------------- UI state
local ROWS = { "PACE", "TURN", "TICKS", "COAST", "HALF", "BEND" }
local row, col = 1, 1
local show = true
local auto, ghost, pin = false, true, true
local AIMS = { "none", "down", "up" }
local aim = 1
local flash_msg, flash_until = nil, 0
local function say(m) flash_msg = m; flash_until = frame + 120; log("%s", m) end

local keys = {}
local function key(tok)
  local c = keys[tok]
  if c == nil then c = input:code_from_token("KEYCODE_"..tok); keys[tok] = c end
  return input:code_pressed(c)
end
local held = {}
local function hit(tok)              -- edge, with auto-repeat after 20 frames
  local d = key(tok)
  local h = held[tok] or 0
  if d then held[tok] = h + 1 else held[tok] = 0 end
  if not d then return false end
  return h == 0 or (h > 20 and h % 4 == 0)
end

local function clamp(v, lo, hi) if v<lo then return lo elseif v>hi then return hi end return v end

local function adjust(d)
  local r = ROWS[row]
  if r == "PACE" then V.pace[col] = clamp(V.pace[col] + d, 1, 16)
  elseif r == "TURN" then V.turn[col] = clamp(V.turn[col] + d, 0, 4)
  elseif r == "TICKS" then V.ticks = clamp(V.ticks + d, 1, T.max); col = clamp(col, 1, V.ticks)
  elseif r == "COAST" then V.coast = clamp(V.coast + d, 0, 40)
  elseif r == "HALF" then V.half = clamp(V.half + d, 0, 40)
  elseif r == "BEND" then
    local step = key("LSHIFT") and 0x4000 or 0x1000
    V.bend = clamp(V.bend + d*step, 0, 0x40000)
  end
  write_tune()
end

local function handle_keys()
  if hit("V") then show = not show end
  if hit("J") then col = clamp(col-1, 1, V.ticks) end
  if hit("L") then col = clamp(col+1, 1, V.ticks) end
  if hit("I") then row = clamp(row-1, 1, #ROWS) end
  if hit("K") then row = clamp(row+1, 1, #ROWS) end
  if hit("U") then adjust(-1) end
  if hit("O") then adjust(1) end
  if hit("Y") then auto = not auto; say("auto-throw "..(auto and "ON" or "off")) end
  if hit("H") then aim = aim % #AIMS + 1; say("aim "..AIMS[aim]) end
  if hit("G") then ghost = not ghost; say("ghost P2 "..(ghost and "ON" or "off")) end
  if hit("P") then pin = not pin; say("pin layout "..(pin and "ON" or "off")) end
  if hit("M") then save(); say("saved to tools/fan_tune_saved.txt") end
  if hit("N") then V = copy(DEF); write_tune(); col = clamp(col,1,V.ticks); say("reset to the built numbers") end
end

------------------------------------------------------------------- inputs
local WANT = { "UI Select", "Coin 1", "1 Player Start", "2 Players Start",
               "P1 High Punch", "P1 Low Punch", "P1 Up", "P1 Down", "P1 Left", "P1 Right" }
local forced = {}
local function force(name, on)
  local f = fields[name]; if not f then return end
  if on then f:set_value(1); forced[name] = true
  elseif forced[name] then
    f:set_value(0)
    pcall(function() f:clear_value() end)
    forced[name] = nil
  end
end

------------------------------------------------------------------- game
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local last_gs = -1

local function find_fan()
  local p = r32(A.active); local n = 0
  while p ~= 0 and n < 250 do
    n = n + 1
    if r16(p+P.procid) == PID_PROJ1 then
      local o = r32(p+P.pa8)
      local p1o = r32(A.p1_obj)
      if o ~= 0 and o ~= p1o and o ~= r32(A.p2_obj) then return p, o end
    end
    p = r32(p+P.next)
  end
end

local function keep_flash_on_p2()
  if not (A.f_jade_flash and A.tick) then return end
  local v = (r16(A.tick) + 30) & 0xffff
  if v == 0 then v = 1 end
  w16(A.f_jade_flash+16, v)
end

-- throw state machine
local th = { on=false, t0=0, seen=false, gone=0 }
local function start_throw()
  if th.on then return end
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  if pin and p1o ~= 0 and p2o ~= 0 then
    w32(p1o+O.oxval, 220<<16); w32(p2o+O.oxval, 430<<16)
  end
  -- Forward is whichever way she faces him
  local fwd = "P1 Right"
  p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  if p1o ~= 0 and p2o ~= 0 and s16(r16(p1o+O.oxpos)) > s16(r16(p2o+O.oxpos)) then fwd = "P1 Left" end
  th = { on=true, t0=frame, seen=false, gone=0, fwd=fwd }
end

-- flight recording
local path, prev_path = {}, {}
local stats, stats0 = nil, nil
local rec = nil
local function cam()
  local cx = A.worldtlx and s16(r32(A.worldtlx)>>16) or 0
  local cy = A.worldtly and s16(r32(A.worldtly)>>16) or 0
  return cx, cy
end

local function track(fobj)
  local x, y = s16(r16(fobj+O.oxpos)), s16(r16(fobj+O.oypos))
  local vx, vy = s32(r32(fobj+O.oxvel))/65536.0, s32(r32(fobj+O.oyvel))/65536.0
  local v = math.sqrt(vx*vx+vy*vy)
  local cx, cy = cam()
  if not rec then
    prev_path = path; path = {}
    rec = { x0=x, y0=y, vout=v, vmin=v, slow=0, maxx=x, minx=x, land=nil, dir=(vx>=0) and 1 or -1 }
  end
  path[#path+1] = { x=x-cx, y=y-cy, v=v }
  if v < rec.vmin then rec.vmin = v end
  if v < rec.vout*0.97 then rec.slow = rec.slow + 1 end
  if x > rec.maxx then rec.maxx = x end
  if x < rec.minx then rec.minx = x end
  local p1o = r32(A.p1_obj)
  if p1o ~= 0 and rec.land == nil and #path > 20 then
    local px = s16(r16(p1o+O.oxpos))
    if math.abs(x - px) < 40 then rec.land = y - rec.y0 end
  end
end

local function finish_track()
  if not rec then return end
  local runon = rec.dir > 0 and (rec.maxx - rec.x0) or (rec.x0 - rec.minx)
  stats = { vout=rec.vout, vmin=rec.vmin, slow=rec.slow, reach=runon, land=rec.land }
  log("throw: |v| %.2f  slowest %.2f (%d%%)  slowed %d ticks  reach %dpx  lands %s",
      stats.vout, stats.vmin, math.floor(100*stats.vmin/math.max(stats.vout,0.01)+0.5),
      stats.slow, stats.reach, stats.land and string.format("%+dpx", stats.land) or "?")
  rec = nil
end

------------------------------------------------------------------- frame
emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    region = manager.machine.memory.regions[":maincpu"]
    input = manager.machine.input
    screen = manager.machine.screens[":screen"]
    for _,port in pairs(manager.machine.ioport.ports) do
      for _,f in pairs(port.fields) do
        for _,n in ipairs(WANT) do if f.name == n then fields[n] = f end end
      end
    end
    if not A.fan_tune then log("ERROR fan_tune is not in src/mk2.map - rebuild"); return end
    -- prove the region IS what the CPU reads, word by word, before trusting it
    for i=0,15 do
      local b = A.fan_tune + i*16
      if space:read_u16(b) ~= region:read_u16((b-ROM_ORG)>>3) then
        log("ERROR region and program space disagree at fan_tune+%d - edits would do nothing", i*16)
        region = nil; return
      end
    end
    DEF = read_tune()
    -- a map from another build points fan_tune at some other data: refuse
    -- rather than write over it (that is how a rebuild by another session
    -- between packaging the zip and launching would show)
    local sane = DEF.ticks>=1 and DEF.ticks<=T.max and DEF.coast<64 and DEF.half<64
                 and DEF.bend < 0x100000
    for i=1,T.max do
      if DEF.turn[i] > 4 or DEF.pace[i] < 1 or DEF.pace[i] > 16 then sane = false end
    end
    if not sane then
      log("ERROR fan_tune @ %08x does not look like the tune block (ticks=%d coast=%d) -"..
          " src/mk2.map is from a different build than rom/mk2.zip.  Re-run makerom.py +"..
          " mamerom.py --no-install and relaunch.  NOTHING WAS WRITTEN.", A.fan_tune, DEF.ticks, DEF.coast)
      region = nil; return
    end
    V = copy(DEF)
    log("fan_tune @ %08x: ticks=%d coast=%d half=%d bend=0x%x", A.fan_tune, V.ticks, V.coast, V.half, V.bend)
  end
  if not region then return end
  if frame == 120 then local fh=io.open(READY,"w"); if fh then fh:write("running"); fh:close() end end

  local gs = r16(A.gstate)
  if gs ~= last_gs then
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if gs == GS_FIGHTING and fighting_frame == 0 then
      fighting_frame = frame
      for n,_ in pairs(forced) do force(n, false) end
      say("FIGHT - T throws, Y auto, J/L I/K U/O edit")
    end
    last_gs = gs
  end

  -- boot: coin, start, force the matchup
  if fighting_frame == 0 then
    if charsel_frame == 0 then
      force("UI Select", frame>=5 and frame<35)
      force("Coin 1", frame>=200 and frame<1000 and (frame%80)<20)
      force("1 Player Start", frame>=1000 and frame<1080)
    else
      force("Coin 1", false); force("1 Player Start", false); force("UI Select", false)
      w16(A.p1_state, 1); w16(A.p2_state, 1)
      w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_JAX)
      w16(A.curback, 0)
      if A.map_position then w16(A.map_position, 0) end
      if A.battle_num then w16(A.battle_num, 1) end
      local r = frame - charsel_frame
      force("2 Players Start", r>=5 and r<45)
      if p1_confirm == 0 and r > 90 then p1_confirm = frame end
      force("P1 High Punch", p1_confirm>0 and frame>=p1_confirm and frame<p1_confirm+45)
    end
    return
  end

  -- the fight never ends
  w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
  if A.winner_status then w16(A.winner_status, 0) end
  if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
  if gs ~= GS_FIGHTING then return end
  if ghost then keep_flash_on_p2() end
  local p2o = r32(A.p2_obj)
  if pin and p2o ~= 0 and th.on then w32(p2o+O.oxval, 430<<16) end

  handle_keys()

  -- throws
  if hit("T") then start_throw() end
  if SELFTEST then
    -- throw on the built numbers, then at full speed with no brake, then save
    local r = frame - fighting_frame
    if r == 120 then start_throw() end
    if r == 420 then
      stats0 = stats
      for i=1,T.max do V.pace[i] = 8 end
      write_tune(); start_throw()
    end
    if r == 560 then screen:snapshot() end
    if r == 720 then
      save()
      local a, b = stats0, stats
      local ok = a and b and a.vmin < a.vout*0.45 and b.vmin > b.vout*0.9
      log("SELFTEST %s: built slowest %.2f/%.2f, live-edited slowest %.2f/%.2f",
          ok and "PASS" or "FAIL", a and a.vmin or -1, a and a.vout or -1, b and b.vmin or -1, b and b.vout or -1)
      manager.machine:exit()
    end
  end
  local _, fobj = find_fan()
  if fobj then track(fobj) elseif rec then finish_track() end
  if auto and not th.on and not fobj and frame % 30 == 0 then start_throw() end

  if th.on then
    local r = frame - th.t0
    if fobj then th.seen = true end
    if SELFTEST and (r==1 or r==24 or r==30 or r==45) then
      local pp = r32(A.p1_proc)
      log("throw r=%d p1act=0x%04x fan=%s hp=%s lp=%s", r, pp~=0 and r16(pp+P.action) or 0xffff,
          tostring(fobj~=nil), tostring(forced["P1 High Punch"]), tostring(forced["P1 Low Punch"]))
    end
    if th.seen and not fobj and th.gone == 0 then th.gone = frame end
    -- Forward, Forward + HP+LP; HP stays held = the boomerang
    force(th.fwd, (r >= 2 and r < 8) or (r >= 12 and r < 18))
    force("P1 High Punch", r >= 22 and (th.gone == 0 or frame < th.gone + 2))
    force("P1 Low Punch", r >= 23 and r < 29)
    local aiming = aim > 1 and r >= 44 and r < 84
    force("P1 Down", aiming and AIMS[aim] == "down")
    force("P1 Up", aiming and AIMS[aim] == "up")
    -- done: fan came and went, or it never came out (she was busy - retry)
    if (th.gone > 0 and frame > th.gone + 30) or (not th.seen and r > 90) then
      th.on = false
      for n,_ in pairs(forced) do force(n, false) end
    end
  end
end)

------------------------------------------------------------------- overlay
local function col_for(v, vout)
  local f = clamp(v / math.max(vout, 0.01), 0, 1)
  local r = math.floor(255 * (1-f)); local g = math.floor(80 + 175*f)
  return 0xff000000 | (r << 16) | (g << 8) | 0x40
end

emu.register_frame_done(function()
  if not (screen and V and show and fighting_frame > 0) then return end
  local s = screen

  -- the last two flights: previous grey, latest coloured by speed
  for _,p in ipairs(prev_path) do s:draw_box(p.x-1, p.y-1, p.x+1, p.y+1, 0x80808080, 0x80808080) end
  local vout = (rec and rec.vout) or (stats and stats.vout) or 9
  for _,p in ipairs(path) do
    local c = col_for(p.v, vout)
    s:draw_box(p.x-1, p.y-1, p.x+1, p.y+1, c, c)
  end

  -- the curl as a graph: bar = pace (n/8), notch below = turn (2^-n rad)
  local n = V.ticks
  local w = math.min(14, math.floor(300 / n))
  local x0, base = 6, 48
  s:draw_box(2, 2, x0 + n*w + 4, base + 16, 0xa0000000, 0xa0000000)
  s:draw_line(x0, base - 40, x0 + n*w, base - 40, 0x60ffffff)      -- full speed
  for i=1,n do
    local x = x0 + (i-1)*w
    local h = V.pace[i] * 5
    local sel = (i == col) and (row == 1 or row == 2)
    local c = sel and 0xffffff40 or 0xff40c0ff
    s:draw_box(x+1, base - h, x + w - 1, base, c, c)
    local t = V.turn[i]
    if t > 0 then
      local th_ = math.floor(12 / (2^(t-1)))
      local tc = sel and 0xffffff40 or 0xffff8040
      s:draw_box(x+2, base + 2, x + w - 2, base + 2 + th_, tc, tc)
    end
  end

  local th_, sweep, run = predict()
  local r = ROWS[row]
  local sel
  if r == "PACE" then sel = string.format("PACE  tick %d/%d = %d/8 speed", col, n, V.pace[col])
  elseif r == "TURN" then sel = string.format("TURN  tick %d/%d = 2^-%d rad", col, n, V.turn[col])
  elseif r == "TICKS" then sel = string.format("TICKS = %d", V.ticks)
  elseif r == "COAST" then sel = string.format("COAST = %d ticks", V.coast)
  elseif r == "HALF" then sel = string.format("HALF = %d ticks", V.half)
  else sel = string.format("BEND = %.3f px/t", V.bend/65536.0) end

  local lines = {
    string.format("> %s    [I/K row  J/L tick  U/O -/+]", sel),
    string.format("turn %.2f rad (want ~3.14)  sweep %.2f (built 4.0)  %d ticks = %dms",
                  th_, sweep, n, math.floor(n*18.28+0.5)),
    stats and string.format("last: |v| %.1f  slowest %.1f (%d%%)  slow %dt  reach %d  lands %s",
                  stats.vout, stats.vmin, math.floor(100*stats.vmin/math.max(stats.vout,0.01)+0.5),
                  stats.slow, stats.reach, stats.land and string.format("%+dpx", stats.land) or "?")
          or "last: (throw one - T)",
    string.format("T throw  Y auto:%s  H aim:%s  G ghost:%s  P pin:%s  M save  N reset  V hide",
                  auto and "ON" or "off", AIMS[aim], ghost and "on" or "off", pin and "on" or "off"),
  }
  if flash_msg and frame < flash_until then lines[#lines+1] = flash_msg end
  local y = 254 - 9 * #lines - 2
  for _,l in ipairs(lines) do
    s:draw_text(2, y, l, 0xffffffff, 0xb0000000)
    y = y + 9
  end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
