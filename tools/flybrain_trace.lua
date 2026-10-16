-- flybrain_trace.lua - real approach / projectile traces for the fly-brain sim.
--
-- tools/flybrain_sim.py tests the circuit on synthetic stimuli whose speeds are
-- guesses. This records the real thing: Liu Kang (P1, scripted) runs trials at
-- Jax (P2, a human port with nothing pressed, so the "fly" holds still), and
-- every frame of every trial is written as a CSV row:
--
--   trial,name,t,drone_x,drone_y,opp_x,opp_y,opp_w,objs
--
-- drone = P2, opp = P1, x/y are oxpos/oypos, opp_w is P1's osize width, and
-- objs is every OTHER object on objlst as oid:x:y:w joined by '|', so the
-- projectile can be picked out afterwards rather than guessed here.
--
-- Trials, repeated FT_REPS times: walk_in, jump_in, fireball (F,F,HP),
-- flykick (F,F,HK), walk_away. Each one first walks P1 back to >= FT_START px
-- (or until he stops moving - the stage edge), then performs, then records
-- until its window closes.
--
-- Env: FT_MAP, FT_CSV, FT_LOG, FT_READY, FT_REPS (default 3), FT_START (230)

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP = (os.getenv("FT_MAP") or (ROOT .. "/src/mk2.map")):gsub("\\", "/")
local CSV = (os.getenv("FT_CSV") or "C:/tmp/flybrain/traces/trace.csv"):gsub("\\", "/")
local LOG = (os.getenv("FT_LOG") or "C:/tmp/flybrain/traces/trace.log"):gsub("\\", "/")
local READY = os.getenv("FT_READY")
local REPS = tonumber(os.getenv("FT_REPS") or "3")
local START = tonumber(os.getenv("FT_START") or "230")

local fh = io.open(LOG, "w")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[ftrace] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end
local out = io.open(CSV, "w")
out:write("trial,name,t,drone_x,drone_y,opp_x,opp_y,opp_w,objs\n")

local sym = {}
for line in io.lines(MAP) do
  for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
local need = { "gstate", "p1_state", "p2_state", "p1_char", "p2_char", "curback", "p1_obj", "p2_obj",
               "p1_bar", "p2_bar", "winner_status", "objlst" }
local missing = {}
for _, n in ipairs(need) do if not sym[n] then missing[#missing + 1] = n end end
if #missing > 0 then log("ERROR unresolved symbols: %s", table.concat(missing, ",")) end

local O = { next = 0x000, oxpos = 0x090, oypos = 0x0b0, osize = 0x120, oid = 0x1c0 }
local GS_PSEL, GS_FIGHTING = 4, 2
local cpu, space, fields = nil, nil, {}
local frame, charsel, fight, confirm = 0, 0, 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end; return v end

-- ---------------------------------------------------------------- trials
local ACTS = {
  -- name, window (frames recorded after the action starts), input script(t) -> set of buttons
  { "walk_in",  220, function(t, d) if d > 55 then return { "fwd" } end return {} end },
  { "jump_in",  90,  function(t) if t < 8 then return { "up", "fwd" } end return {} end },
  { "fireball", 110, function(t)
      if t < 4 then return { "fwd" } elseif t < 7 then return {} elseif t < 11 then return { "fwd" }
      elseif t < 15 then return { "HP" } end return {} end },
  { "flykick",  90,  function(t)
      if t < 4 then return { "fwd" } elseif t < 7 then return {} elseif t < 11 then return { "fwd" }
      elseif t < 15 then return { "HK" } end return {} end },
  { "walk_away", 120, function(t) return { "back" } end },
}
local plan = {}
for r = 1, REPS do for _, a in ipairs(ACTS) do plan[#plan + 1] = a end end

local idx, phase, pt, stuck, lastx = 1, "setup", 0, 0, nil

local function objs(p1, p2)
  local t, p, n = {}, r32(sym.objlst), 0
  while p ~= 0 and n < 200 do
    if p ~= p1 and p ~= p2 then
      t[#t + 1] = string.format("%x:%d:%d:%d", r16(p + O.oid), s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
                                r32(p + O.osize) & 0xffff)
    end
    p = r32(p + O.next); n = n + 1
  end
  return table.concat(t, "|")
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, f in pairs(port.fields) do fields[f.name] = f end
    end
    log("map %s reps=%d start=%d", MAP, REPS, START)
  end
  if READY and frame == 120 then local r = io.open(READY, "w"); if r then r:write("ok"); r:close() end end
  if #missing > 0 then manager.machine:exit(); return end

  local gs = r16(sym.gstate)
  if gs == GS_PSEL and charsel == 0 then charsel = frame; log("select frame=%d", frame) end
  if gs == GS_FIGHTING and charsel > 0 and fight == 0 then fight = frame; log("fight frame=%d", frame) end

  local press = {}
  if charsel == 0 then
    press["UI Select"] = frame >= 5 and frame < 35
    press["Coin 1"] = frame >= 200 and (frame % 80) < 20
    press["1 Player Start"] = frame >= 1000 and (frame % 120) < 30
  elseif fight == 0 then
    w16(sym.p1_state, 1); w16(sym.p2_state, 1)
    w16(sym.p1_char, 1); w16(sym.p2_char, 11); w16(sym.curback, 0)
    if confirm == 0 and frame - charsel > 90 then confirm = frame end
    local c = confirm > 0 and frame >= confirm and frame < confirm + 45
    press["P1 High Punch"] = c; press["P2 High Punch"] = c
    press["2 Players Start"] = (frame - charsel) % 60 < 10
  end

  if fight > 0 and frame - fight > 60 then
    w16(sym.p1_bar, 0xA1); w16(sym.p2_bar, 0xA1); w16(sym.winner_status, 0)
    local p1, p2 = r32(sym.p1_obj), r32(sym.p2_obj)
    if gs ~= GS_FIGHTING or p1 == 0 or p2 == 0 then
      if frame % 60 == 0 then log("waiting gstate=%d", gs) end
    else
      local x1, x2 = s16(r16(p1 + O.oxpos)), s16(r16(p2 + O.oxpos))
      local d = math.abs(x2 - x1)
      local fwd = x2 > x1 and "P1 Right" or "P1 Left"
      local back = x2 > x1 and "P1 Left" or "P1 Right"
      local act = plan[idx]
      local want = {}
      if phase == "setup" then
        pt = pt + 1
        local target_far = act[1] ~= "walk_away"
        if target_far then
          if d < START then want = { "back" } end
          stuck = (lastx == x1) and stuck + 1 or 0
          if (d >= START or stuck > 20) and pt > 30 then phase = "settle"; pt = 0 end
        else
          if d > 70 then want = { "fwd" } end
          if d <= 70 and pt > 30 then phase = "settle"; pt = 0 end
        end
      elseif phase == "settle" then
        pt = pt + 1
        if pt >= 25 then
          phase = "act"; pt = 0
          log("trial %d %s start dist=%d p1x=%d p2x=%d", idx, act[1], d, x1, x2)
        end
      else
        want = act[3](pt, d)
        out:write(string.format("%d,%s,%d,%d,%d,%d,%d,%d,%s\n", idx, act[1], pt, x2, s16(r16(p2 + O.oypos)),
          x1, s16(r16(p1 + O.oypos)), r32(p1 + O.osize) & 0xffff, objs(p1, p2)))
        pt = pt + 1
        if pt >= act[2] then
          log("trial %d %s end dist=%d", idx, act[1], d)
          idx = idx + 1; phase = "setup"; pt = 0; stuck = 0
          if idx > #plan then
            out:close(); log("DONE %d trials", #plan); manager.machine:exit(); return
          end
        end
      end
      lastx = x1
      for _, w in ipairs(want) do
        if w == "fwd" then press[fwd] = true
        elseif w == "back" then press[back] = true
        elseif w == "up" then press["P1 Up"] = true
        elseif w == "HP" then press["P1 High Punch"] = true
        elseif w == "HK" then press["P1 High Kick"] = true end
      end
    end
  end

  if frame > 60000 then log("ERROR timeout idx=%d phase=%s", idx, phase); out:close(); manager.machine:exit(); return end
  for _, n in ipairs({ "UI Select", "Coin 1", "1 Player Start", "2 Players Start", "P1 High Punch", "P2 High Punch",
                       "P1 High Kick", "P1 Left", "P1 Right", "P1 Up" }) do
    if fields[n] then fields[n]:set_value(press[n] and 1 or 0) end
  end
end)
