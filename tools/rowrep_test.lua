-- rowrep_test.lua - graphics audit row 24: TMS34010 row repetition.
--
-- Sets @f_rowrep (the low DPYSTRT bits dirq ORs into the page flip) to 0,1,2,3
-- and back to 0 inside several short windows of ONE boot, snapshotting each.
-- tools/run_rowrep_test.py keeps the windows whose two 0-captures are
-- identical (a static scene), then checks each stretched capture against its
-- 0-capture row by row.  One boot, so boot nondeterminism cannot matter.
--
--   ROWREP_ROOT   repo or frozen copy holding src/mk2.map
--   ROWREP_LOG    log path
--   ROWREP_STARTS comma list of window start frames (default 700,1000,1400,1900,2600)

local ROOT = (os.getenv("ROWREP_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("ROWREP_LOG") or (ROOT .. "/tools/rowrep_test.log")
local STARTS = {}
for v in (os.getenv("ROWREP_STARTS") or "700,1000,1400,1900,2600"):gmatch("%d+") do
    STARTS[#STARTS + 1] = tonumber(v)
end

local fh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rowrep] " .. string.format(fmt, ...)
    print(line); fh:write(line, "\n"); fh:flush()
end

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
if not sym.f_rowrep then log("FATAL f_rowrep not in mk2.map - build with rowrep .set 1") end

local R_DPYSTRT, R_DPYADR = 0xc0000090, 0xc00001e0
-- step within a window: frame offset -> (value to set, or nil), then snap label
local STEPS = {
    { at = 0,  set = 0 },
    { at = 4,  snap = "r0a", set = 1 },
    { at = 8,  snap = "r1",  set = 2 },
    { at = 12, snap = "r2",  set = 3 },
    { at = 16, snap = "r3",  set = 0 },
    { at = 20, snap = "r0b" },
}

local space, frame, snaps, done = nil, 0, 0, false
emu.register_frame_done(function()
    if done then return end
    space = space or manager.machine.devices[":maincpu"].spaces["program"]
    frame = frame + 1
    for w, s in ipairs(STARTS) do
        for _, st in ipairs(STEPS) do
            if frame == s + st.at then
                if st.snap then
                    manager.machine.video:snapshot()
                    log("SNAP idx=%04d window=%d label=%s frame=%d f_rowrep=%d dpystrt=%04x dpyadr=%04x gstate=%d",
                        snaps, w, st.snap, frame, space:read_u16(sym.f_rowrep),
                        space:read_u16(R_DPYSTRT), space:read_u16(R_DPYADR), space:read_u16(sym.gstate))
                    snaps = snaps + 1
                end
                if st.set and sym.f_rowrep then space:write_u16(sym.f_rowrep, st.set) end
            end
        end
    end
    if frame > STARTS[#STARTS] + 30 then
        done = true
        space:write_u16(sym.f_rowrep, 0)
        log("DONE %d snapshots", snaps)
        manager.machine:exit()
    end
end)
