-- drone_reaction_latency_log.lua - how long the CPU takes to ANSWER what you start.
--
-- Rides the fly rig as FB_ADDON (or runs standalone as an autoboot script) and writes
-- <FB_OUT>/drone_reaction.csv.
--
-- WHY. drone_react_delay (MKDRONE.ASM) is the CPU's notice time, and it was 55-110 ms -
-- ~4x faster than a person - which is what "it feels like it reads my controller" is
-- made of (drnhuman, MAINEQU.ASM). A table value is not a reaction time, though: the answer
-- also waits on the drone's own state, its think loop and whatever it was doing. So this
-- measures it end to end, from the frame the OTHER man's p_action enters an attack or a
-- projectile, to the first frame the drone's own p_action leaves neutral.
--
-- An event starts only while the drone is NEUTRAL (stance/walk/turn/idle), because a drone
-- that is already mid-move cannot answer anything and that is not a reaction time. Each
-- event ends one of three ways:
--   RESP  the drone's action changed first; `lat` frames, `resp` = what it changed to
--         (07xx = a block)
--   HIT   his attack landed first (the drone's bar dropped before it did anything)
--   NONE  60 frames and neither
--
-- Fields from FB_MAP / DISPEQU / MAINEQU: p1_proc p2_proc p1_obj p2_obj p2_bar diff
-- winner_status, p_action +1f0h (16), oxpos +090h (16). P1 is the attacker, P2 the CPU.
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local OUT = (os.getenv("FB_OUT") or "C:/tmp/flybrain/play") .. "/drone_reaction.csv"
local WINDOW = 60
local WANT = { p1_proc=1, p2_proc=1, p1_obj=1, p2_obj=1, p2_bar=1, diff=1, winner_status=1 }
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

-- neutral = stance / walks / turn / idle, the same set drone_decision_log.lua uses
local function neutral(a) return a == 0 or (a >> 8) == 0x03 end
-- an attack (act_attacks 01xx, act_body_propell 02xx) or a projectile (nonzero, category 0)
local function threat(a) return a ~= 0 and ((a >> 8) <= 0x02) end

local fh = io.open(OUT, "w")
if fh then fh:write("frame,diff,dist,his_act,outcome,lat,resp\n"); fh:flush() end
local frame, prev_fa, ev = 0, 0, nil

DRONE_REACT_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local dp, fp = r32(sym.p2_proc), r32(sym.p1_proc)
  if dp == 0 or fp == 0 then prev_fa, ev = 0, nil return end
  local da, fa = r16(dp + 0x1f0), r16(fp + 0x1f0)
  local bar = r16(sym.p2_bar)
  local winner = r16(sym.winner_status)

  if ev then
    local out, lat, resp
    if winner ~= 0 or bar > ev.bar0 then ev = nil                  -- round over: no verdict
    elseif not neutral(da) then out, lat, resp = "RESP", frame - ev.f0, da
    elseif bar < ev.bar0 then out, lat, resp = "HIT", frame - ev.f0, 0
    elseif frame - ev.f0 >= WINDOW then out, lat, resp = "NONE", WINDOW, 0 end
    if out then
      if fh then
        fh:write(string.format("%d,%d,%d,%04x,%s,%d,%04x\n", ev.f0, ev.diff, ev.dist, ev.act, out, lat, resp))
        fh:flush()
      end
      ev = nil
    end
  end

  -- a new attack or projectile, begun while the CPU was doing nothing
  if not ev and threat(fa) and not threat(prev_fa) and neutral(da) and winner == 0 then
    local dx = s16(r16(r32(sym.p2_obj) + 0x90))
    local fx = s16(r16(r32(sym.p1_obj) + 0x90))
    ev = { f0 = frame, bar0 = bar, act = fa, diff = r16(sym.diff), dist = math.abs(dx - fx) }
  end
  prev_fa = fa
end)
