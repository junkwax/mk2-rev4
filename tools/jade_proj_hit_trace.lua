-- jade_proj_hit_trace.lua - PER-EVENT trace of the boomerang hits the drone fails to stop.
--
-- Rides the fly rig as FB_ADDON, alongside or instead of jade_proj_guard_probe.lua.
--
-- Why a trace and not more counters: four aggregate measurements established that the drone
-- SEES the projectile (ground truth 15% of frames live, and its own count agrees), that the
-- check RUNS (1,166 looks), that widening proj_guard_dist put 70% of sightings in range, and
-- that none of it changed the hit rate (53.4% -> 53.3% over 118/122 throws). Counters cannot
-- answer the one question left: was the guard UP at the moment the hit landed? So record the
-- frames around each hit and read them.
--
-- Fields, all from the map / DISPEQU.ASM / MAINEQU.ASM, never guessed - the first cut of the
-- height probe used the wrong oypos and produced a histogram of zeros:
--   active 010b40a0, plink +0 (32), procid +20h (16), pa8 +0c0h (32)
--   oxpos +090h (16), oypos +0b0h (16)
--   p_action = pdata+0f0h = +1f0h (16);  act_blockhi 0700h, act_blocklo 0701h
--   p2_proc/p2_obj/p2_bar are POINTERS/values at fixed .bss addresses, so they move on any
--   rebuild - resolved from FB_MAP here.
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local WANT = { p2_proc = 1, p2_obj = 1, p2_bar = 1, p1_obj = 1, active = 1 }
local sym = {}
do
  local fh = io.open(MAP)
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x+)%s+([%w_]+)") do
        if WANT[n] and not sym[n] then sym[n] = tonumber(a, 16) end
      end
    end
    fh:close()
  end
end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return a and space:read_u16(a) or 0 end
local function r32(a) return a and space:read_u32(a) or 0 end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local MAX_EVENTS = tonumber(os.getenv("TRACE_EVENTS") or "6")
local WINDOW = 40                      -- frames of history kept before each hit
local ring, ri, events, frame = {}, 0, 0, 0
local last_bar = nil

local function act_name(a)
  if a == 0x0700 then return "BLOCKHI" end
  if a == 0x0701 then return "BLOCKLO" end
  if a == 0x0503 then return "reacting" end
  if a == 0x0305 then return "walkf" end
  if a == 0x0307 then return "walkb" end
  return string.format("%04x", a)
end

-- his live projectile (pid family 0700h), as get_his_proj_proc finds it
local function his_proj()
  local p = r32(sym.active)
  local n = 0
  while p ~= 0 and n < 200 do
    if (r16(p + 0x20) & 0xff00) == 0x0700 then
      local ob = r32(p + 0xc0)
      if ob ~= 0 then return ob end
    end
    p = r32(p)
    n = n + 1
  end
  return nil
end

TRACE_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local dobj = r32(sym.p2_obj)
  local dproc = r32(sym.p2_proc)
  local bar = r16(sym.p2_bar)
  local pobj = his_proj()
  local px, py = -1, -1
  if pobj then px, py = s16(r16(pobj + 0x90)), s16(r16(pobj + 0xb0)) end
  local dx = dobj ~= 0 and s16(r16(dobj + 0x90)) or 0
  local act = dproc ~= 0 and r16(dproc + 0x1f0) or 0

  ri = ri % WINDOW + 1
  ring[ri] = { f = frame, px = px, py = py, dx = dx, act = act,
               d = pobj and (px - dx) or nil }

  -- a hit on the DRONE: his bar fell. Only interesting while a projectile is about.
  if last_bar and bar < last_bar and events < MAX_EVENTS then
    local hadproj = false
    for _, e in pairs(ring) do if e.d then hadproj = true end end
    if hadproj then
      events = events + 1
      print(string.format("[trace] ==== EVENT %d: drone lost %d hp at frame %d ====",
            events, last_bar - bar, frame))
      -- oldest first
      local out = {}
      for k = 1, WINDOW do
        local e = ring[(ri + k - 1) % WINDOW + 1]
        if e then out[#out + 1] = e end
      end
      table.sort(out, function(a, b) return a.f < b.f end)
      local prevd
      for _, e in ipairs(out) do
        local dir = ""
        if e.d and prevd then
          dir = (math.abs(e.d) < math.abs(prevd)) and "closing" or "receding"
        end
        print(string.format("   f%-7d proj %s  drone x %-5d act %-8s %s",
              e.f, e.d and string.format("x%-5d y%-4d dist %-5d", e.px, e.py, e.d)
                       or "-- none --",
              e.dx, act_name(e.act), dir))
        if e.d then prevd = e.d end
      end
    end
  end
  last_bar = bar
end)

print(string.format("[trace] per-event hit trace armed (%d events, %d-frame window)",
      MAX_EVENTS, WINDOW))
for k in pairs(WANT) do
  if not sym[k] then print("[trace] MISSING SYMBOL " .. k .. " in " .. MAP) end
end
