-- drone_decision_log.lua - what the CPU CHOOSES, and what each choice costs it.
--
-- Rides the fly rig as FB_ADDON and writes <FB_OUT>/drone_decisions.csv.
--
-- Everything measured so far has been the drone's REACTIONS - how often it punishes a
-- recovery, how often it guards a projectile. That is one half. The other half is what it
-- picks when nothing is being done to it: drone_stalk chooses a band (d_close 050h, d_med
-- 070h, d_far 0c0h) and close_rapid_pick and its siblings choose a move. Nothing in this tree
-- has ever measured whether those choices pay.
--
-- A DECISION here is the drone's p_action leaving the neutral set (stance / walk / turn /
-- idle) for something it chose. For each one this records the range it was taken at, what the
-- FLY was doing at that instant (so a choice made into an incoming attack can be told from one
-- made into open space), and then the bar movement over the next TRADE_WINDOW frames.
--
-- Read it as: for this action at this range, how often does the drone come out ahead. A choice
-- that mostly takes damage is a decision worth fixing - and unlike the whiff screen, no
-- filtering guesswork is involved, because the drone's own action code says what it picked.
--
-- Fields from FB_MAP / DISPEQU / MAINEQU: p1_proc p2_proc p1_obj p2_obj p1_bar p2_bar,
-- p_action +1f0h (16), oxpos +090h (16).
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local OUT = (os.getenv("FB_OUT") or "C:/tmp/flybrain/play") .. "/drone_decisions.csv"
local WANT = { p1_proc=1, p2_proc=1, p1_obj=1, p2_obj=1, p1_bar=1, p2_bar=1, diff=1,
               winner_status=1, gstate=1, debug2=1 }
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

-- neutral = the drone is not committed to anything; leaving this set IS the decision
local NEUTRAL = { [0x0000]=1, [0x0301]=1, [0x0302]=1, [0x0303]=1, [0x0304]=1,
                  [0x0305]=1, [0x0306]=1, [0x0307]=1 }
local TRADE = 60

local fh = io.open(OUT, "w")
-- winner and gstate are logged because the user reports the CPU still making moves after a
-- match is done, and the source agrees it can: drone_round_over exists but only SIX of the
-- drone's 161 routines call it, so nearly every attack loop runs on regardless. A decision
-- logged with winner ~= 0 IS that bug caught in the act, and a candidate cause for the open
-- gstate-5 park (a drone still committed when round-end tries to take its process over).
if fh then fh:write("frame,diff,act,dist,band,fly_act,fly_busy,dealt,taken,winner,gstate,site\n") end
local prev, pend, frame = 0, {}, 0

DRONE_DEC_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local dp, fp = r32(sym.p2_proc), r32(sym.p1_proc)
  if dp == 0 or fp == 0 then return end
  local da, fa = r16(dp + 0x1f0), r16(fp + 0x1f0)
  local fbar, dbar = r16(sym.p1_bar), r16(sym.p2_bar)

  -- close out decisions whose window has expired
  for i = #pend, 1, -1 do
    local e = pend[i]
    if frame - e.frame >= TRADE then
      if fh then
        fh:write(string.format("%d,%d,%04x,%d,%s,%04x,%d,%d,%d,%d,%d,%d\n", e.frame, e.diff, e.act,
          e.dist, e.band, e.fly_act, e.fly_busy, math.max(0, e.fbar - fbar),
          math.max(0, e.dbar - dbar), e.winner, e.gstate, e.site))
      end
      table.remove(pend, i)
    end
  end

  if NEUTRAL[prev] and not NEUTRAL[da] then
    local dx = s16(r16(r32(sym.p2_obj) + 0x90))
    local fx = s16(r16(r32(sym.p1_obj) + 0x90))
    local d = math.abs(dx - fx)
    pend[#pend + 1] = { frame = frame, act = da, dist = d,
      band = d <= 0x50 and "close" or d <= 0x70 and "med" or d <= 0xc0 and "far" or "out",
      fly_act = fa, fly_busy = NEUTRAL[fa] and 0 or 1,
      fbar = fbar, dbar = dbar, diff = r16(sym.diff),
      winner = r16(sym.winner_status), gstate = r16(sym.gstate),
      -- @debug2 carries WHICH do_uppercut site ran (upcut_census, MKDRONE.ASM)
      site = sym.debug2 and r16(sym.debug2) or 0 }
    if #pend > 40 then table.remove(pend, 1) end
  end
  prev = da
  if frame % 3600 == 0 and fh then fh:flush() end
end)
print("[dronedec] logging the CPU's own decisions -> " .. OUT)
for k in pairs(WANT) do if not sym[k] then print("[dronedec] MISSING SYMBOL " .. k) end end
