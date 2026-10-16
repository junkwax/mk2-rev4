-- Frame-overrun probe.  MPROC.ASM:52-58, prcdsp keeps
--     overload = (overload + 2*timer) / 2
-- with `timer` = the tick counter when the wait loop exits.  Fixed point for
-- timer==1 (no missed frames) is 2; every extra overrun tick pushes it up.
-- Nothing in the game reads it, so sampling is free and non-invasive.
--
-- NOTE addressing: this MAME build's tms34010 program space takes the RAW
-- TMS bit address from mk2.map in space:read_*, NOT bit//8.  Verified against
-- p1_bar/p2_bar reading real health values.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local OVERLOAD, BLOOD, P1, P2 = 0x0109f720, 0x0109f730, 0x010ed920, 0x010ee4f0
local logpath = os.getenv("PERF_LOG") or "tools/perf_probe.log"
local warm    = tonumber(os.getenv("PERF_WARMUP") or "300")
local frames, samples, peak, peak_blood = 0, 0, 0, 0
local hist, worst = {}, {}

local function dump(tag)
  local f = assert(io.open(logpath, "w"))
  local keys = {}
  for k in pairs(hist) do keys[#keys+1] = k end
  table.sort(keys)
  f:write(string.format("%s samples=%d peak_overload=%d peak_blood=%d\n",
                        tag, samples, peak, peak_blood))
  for _, k in ipairs(keys) do
    f:write(string.format("  overload=%-4d %7d  %5.1f%%\n", k, hist[k], 100*hist[k]/samples))
  end
  if #worst > 0 then
    f:write("worst frames (overload > 2):\n")
    for i = 1, math.min(#worst, 20) do
      f:write(string.format("  f=%-7d overload=%-4d blood=%-4d p1=%-4d p2=%d\n", table.unpack(worst[i])))
    end
  end
  f:close()
end

emu.register_frame_done(function()
  frames = frames + 1
  if frames <= warm then return end
  local ov, bl = sp:read_u16(OVERLOAD), sp:read_u16(BLOOD)
  hist[ov] = (hist[ov] or 0) + 1
  samples = samples + 1
  if ov > peak then peak = ov end
  if bl > peak_blood then peak_blood = bl end
  if ov > 2 and #worst < 200 then
    worst[#worst+1] = {frames, ov, bl, sp:read_u16(P1), sp:read_u16(P2)}
  end
  if samples % 2000 == 0 then
    print(string.format("[perf] f=%d ov=%d peak=%d blood=%d peakblood=%d", frames, ov, peak, bl, peak_blood))
    dump("partial")
  end
end)
