-- jc_kheart_placement.lua
--
-- Interactive composite-scene editor for the KHEART lane in Cage's restored
-- headhole fatality. The shared harness boots to round 2 Finish Him, then this
-- mode pauses before the fatality and records one placement per scene frame.

JC_HEADHOLE_READOUT = true
JC_KHEART_PLACEMENT = true

local root = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
root = root:gsub("\\", "/")

dofile(root .. "/tools/jc_headhole_fatality_test.lua")
