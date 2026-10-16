-- switch_probe.lua - hold one input at a time, log the bits the ROM sees at
-- @switch (01600000h) / @switch2 (01600020h).  MAINEQU's j1*/p1b* equates are
-- masks over these, so this is the only honest way to confirm one.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG = os.getenv("PROBE_LOG") or (ROOT .. "/tools/switch_probe.log")
local fh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[probe] " .. (select("#",...) > 0 and string.format(f, ...) or tostring(f))
  print(l); if fh then fh:write(l, "\n"); fh:flush() end
end
local SWITCH, SWITCH2 = 0x01600000, 0x01600020
local names = { "P1 Up","P1 Down","P1 Left","P1 Right","P2 Up","P2 Down","P2 Left","P2 Right" }
local fields, space, frame, idx, base = {}, nil, 0, 0, 0
local HOLD = 40
emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    for _, p in pairs(manager.machine.ioport.ports) do
      for _, fl in pairs(p.fields) do fields[fl.name] = fl end
    end
    for _, n in ipairs(names) do log("field %-10s %s", n, fields[n] and "ok" or "MISSING") end
  end
  if frame < 120 then return end
  local slot = (frame - 120) // HOLD
  if slot > #names then log("done"); manager.machine:exit(); return end
  for _, n in ipairs(names) do
    if fields[n] then fields[n]:set_value((slot > 0 and names[slot] == n) and 1 or 0) end
  end
  if (frame - 120) % HOLD == HOLD - 5 then
    local s1 = (~space:read_u32(SWITCH)) & 0xffffffff
    local s2 = (~space:read_u32(SWITCH2)) & 0xffffffff
    if slot == 0 then base = s1; log("idle          switch=%08x switch2=%08x", s1, s2)
    else log("%-10s switch=%08x (delta %08x) switch2=%08x", names[slot], s1, s1 ~ base, s2) end
  end
end)
