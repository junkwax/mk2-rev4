-- Focused Cage headhole/SPILL persistence run.
-- Uses the established boot/fatality driver but exits shortly after victory
-- so its object/process dumps isolate the rel207-rel215 handoff.
_G.JC_HEADHOLE_PASS_REL = 300
_G.JC_HEADHOLE_READOUT = true
local root = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
root = root:gsub("\\", "/")
dofile(root .. "/tools/jc_headhole_fatality_test.lua")
