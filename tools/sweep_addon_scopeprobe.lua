-- sweep_addon_scopeprobe.lua - NEGATIVE CONTROL for check_scope.
--
-- check_scope was gated on gs==GS_FIGHTING to stop it following the game into
-- attract mode under -NoHpPin.  A gate that is too tight would silently stop
-- reporting real excursions, which is worse than the false positive it
-- replaced.  So: shove worldtlx far outside the level DURING a fight and
-- confirm the harness still says level_out_of_scope.
--
-- Rename to sweep_addon.lua, run one battle, expect FAIL.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local sym = {}
do
  local fh = io.open(ROOT .. "/src/mk2.map", "r")
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
    end
    fh:close()
  end
end
local gstate, worldtlx = sym["gstate"], sym["worldtlx"]
if not (gstate and worldtlx) then print("[scopeprobe] symbols missing"); return end
local space, frame, fight0 = nil, 0, 0
emu.register_frame(function()
  frame = frame + 1
  if not space then
    local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
    if not ok or not space then return end
  end
  if space:read_u16(gstate) ~= 2 then return end
  if fight0 == 0 then fight0 = frame end
  local rel = frame - fight0
  if rel >= 300 and rel < 305 then
    space:write_u32(worldtlx, 0xf4240000)          -- 62000 px: nowhere near any level
    if rel == 300 then print("[scopeprobe] forced worldtlx out of scope at rel 300") end
  end
end)
