-- Dedicated Johnny Cage brain-rip test for Liu Kang's LIUFALL no-wobble lane.
_G.JC_HEADHOLE_VICTIM = 1
_G.JC_HEADHOLE_PASS_REL = 300
_G.JC_HEADHOLE_READOUT = true

local root = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
root = root:gsub("\\", "/")
dofile(root .. "/tools/jc_headhole_fatality_test.lua")
