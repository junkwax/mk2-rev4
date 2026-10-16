-- Dedicated Johnny Cage headhole fatality test against Liu Kang.
-- Keep this separate from the established Baraka run so each victim test has
-- an immutable setup and its own reproducible Lua entry point.
_G.JC_HEADHOLE_VICTIM = 1
_G.JC_HEADHOLE_PASS_REL = 300
_G.JC_HEADHOLE_READOUT = true

local root = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
root = root:gsub("\\", "/")
dofile(root .. "/tools/jc_headhole_fatality_test.lua")
