-- jc_headhole_anim_readout.lua
--
-- Thin wrapper around the Cage headhole fatality harness. It enables the
-- per-native-DBLO2-source-tick readout so a run produces placement data for
-- later tuning. DBLO2 is spelled with the letter O in CAGE10.IMG.

JC_HEADHOLE_READOUT = true

local root = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
root = root:gsub("\\", "/")

dofile(root .. "/tools/jc_headhole_fatality_test.lua")
