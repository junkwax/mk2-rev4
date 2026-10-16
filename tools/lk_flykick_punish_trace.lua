-- lk_flykick_punish_trace.lua - what the drone does with Liu Kang's whiffed flying kick.
--
-- Rides the fly rig as FB_ADDON. Triggers on the FLY's p_action becoming act_superk_sd
-- (0617h), which super_kick_land (MKPROP.ASM) sets with the comment "tell da drones", and
-- records the window that follows - the one it makes him "victim to attacks" for with
-- set_no_block + sleep 20 + sleep 10.
--
-- The question, and why counters could not answer it: a whiffed flying kick at mid range is
-- punished 6.6% of 212 whiffs, against 30.9% for a whiffed roundhouse at the same range, and
-- he ends up CLOSER than the roundhouse leaves him (median 116 px vs 128, out of range 15% vs
-- 30%). The drone is wired for it - counter_sitting_duck row 617 -> c_superk_sd -> a fully
-- populated ochar_superk_sd, mostly drone_uppercut_jump. So does it
--   (a) commit an uppercut that falls short from ~116 px, or
--   (b) never commit at all,
-- and is he AIRBORNE for the window (super_kick_land ends in flight_loop), in which case an
-- uppercut is the right answer and some of that 6.6% is legitimate?
-- Those need different fixes: (a) wants the approach that tier 3 buys, (b) wants to know why
-- the handler declines.
--
-- Fields resolved from FB_MAP / DISPEQU / MAINEQU, never assumed:
--   p1_proc p2_proc p1_obj p2_obj p1_bar p2_bar   (map)
--   p_action +1f0h (16)   oxpos +090h (16)   oyval +0a0h (32)
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local WANT = { p1_proc=1, p2_proc=1, p1_obj=1, p2_obj=1, p1_bar=1, p2_bar=1 }
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
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end

local NAME = { [0x0617]="SUPERK_SD", [0x0203]="superkang", [0x0303]="stance", [0x0305]="walkf",
               [0x0307]="walkb", [0x030b]="jumpup", [0x0107]="UPPERCUT", [0x0106]="sweep",
               [0x0103]="hikick", [0x0101]="hipunch", [0x0700]="blockhi", [0x0701]="blocklo",
               [0x0503]="reacting", [0x0606]="upcutted" }
local function nm(a) return NAME[a] or string.format("%04x", a) end

local MAXE = tonumber(os.getenv("TRACE_EVENTS") or "5")
local WINDOW = 45
local ev, armed, t = 0, nil, 0
TALLY = {}

LKFK_HANDLE = emu.add_machine_frame_notifier(function()
  t = t + 1
  local fp, dp = r32(sym.p1_proc), r32(sym.p2_proc)
  if fp == 0 or dp == 0 then return end
  local fa, da = r16(fp + 0x1f0), r16(dp + 0x1f0)
  local fx = s16(r16(r32(sym.p1_obj) + 0x90))
  local dx = s16(r16(r32(sym.p2_obj) + 0x90))
  local fy = s32(r32(r32(sym.p1_obj) + 0xa0))          -- oyval: <0 while airborne
  local dist = math.abs(fx - dx)

  if not armed and fa == 0x0617 and ev < MAXE then
    ev = ev + 1
    -- CLASSIFY BY WHAT THE DRONE WAS DOING WHEN HE LANDED.  The aggregate 6.6% mixes cases
    -- where not punishing is CORRECT: the kick connected (it is in act_reacting), it blocked
    -- and is holding guard, or it is inside its own sitting-duck recovery (06xx). Only a drone
    -- that is FREE at t+0 had a punish to miss, and that is the only rate worth fixing against.
    local cls
    if da == 0x0503 or da == 0x0606 then cls = "was hit"
    elseif da == 0x0700 or da == 0x0701 then cls = "blocking"
    elseif (da & 0xff00) == 0x0600 then cls = "own recovery"
    elseif da == 0x0303 or da == 0x0000 or (da >= 0x0304 and da <= 0x0307) then cls = "FREE"
    else cls = string.format("busy %04x", da) end
    armed = { left = WINDOW, bar = r16(sym.p1_bar), n = ev, hit = false, cls = cls, d0 = dist }
    TALLY[cls] = TALLY[cls] or { 0, 0 }
    TALLY[cls][1] = TALLY[cls][1] + 1
  end
  if armed then
    local bar = r16(sym.p1_bar)
    if bar < armed.bar then
      print(string.format("   t+%-3d  PUNISHED for %d", WINDOW - armed.left, armed.bar - bar))
      armed.hit = true
    end
    armed.bar = bar
    armed.left = armed.left - 1
    if armed.left <= 0 then
      if armed.hit then TALLY[armed.cls][2] = TALLY[armed.cls][2] + 1 end
      if ev % 20 == 0 then
        local out = {}
        for k, v in pairs(TALLY) do
          out[#out + 1] = string.format("%s %d/%d (%.0f%%)", k, v[2], v[1], 100 * v[2] / v[1])
        end
        table.sort(out)
        print("[lkfk] after " .. ev .. " landings, punished by the drone's state at landing: "
              .. table.concat(out, " | "))
      end
      armed = nil
    end
  end
end)
print("[lkfk] armed: tracing Liu Kang's flying-kick recovery window")
for k in pairs(WANT) do if not sym[k] then print("[lkfk] MISSING SYMBOL " .. k) end end
