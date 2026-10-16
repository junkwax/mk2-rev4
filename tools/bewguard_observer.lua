-- bewguard_observer.lua - wrap the divepunish crash rig and report the drone
-- lookup guard (beware_lookup, MKDRONE.ASM).
--
-- The Dead Pool TRAP 30 was a garbage PC reached inside drone_beware.  The
-- guard refuses any out-of-range action instead of jumping through it, and
-- counts the refusals in c_beware_oob with the last offender in l_beware_oob.
-- A non-zero count is direct evidence that a lookup went out of range - one
-- that would have jumped to an arbitrary address before the guard.
--
-- Runs tools/drone_divepunish_test.lua unchanged (its DIVEP_* env vars, its
-- CRASH/WEDGE verdict) and adds one BEWGUARD line, polled every frame so the
-- first refusal is timestamped even if the run later stalls.
--
-- env: BEW_LOG (this observer's log), MK2_ROOT, plus the rig's DIVEP_*.

local root = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local out = assert(io.open(assert(os.getenv("BEW_LOG"), "BEW_LOG not set"), "w"))
local function log(fmt, ...)
    out:write("[bew] " .. string.format(fmt, ...) .. "\n"); out:flush()
end

local symbols = {}
for line in assert(io.open(root .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local C_OOB, L_OOB = symbols["c_beware_oob"], symbols["l_beware_oob"]
log("loaded c_beware_oob=%s l_beware_oob=%s", C_OOB and string.format("%08x", C_OOB) or "MISSING",
    L_OOB and string.format("%08x", L_OOB) or "MISSING")

dofile(root .. "/tools/drone_divepunish_test.lua")

local space, frame, last = nil, 0, 0
local acts = {}
emu.register_frame(function()
    frame = frame + 1
    space = space or manager.machine.devices[":maincpu"].spaces["program"]
    if not (space and C_OOB) then return end
    local c = space:read_u16(C_OOB)
    if c ~= last then
        local act = space:read_u16(L_OOB)
        acts[act] = (acts[act] or 0) + (c - last)
        log("REFUSED frame=%d count=%d action=%04x", frame, c, act)
        last = c
    end
end)

emu.register_stop(function()
    local list = {}
    for act, n in pairs(acts) do list[#list + 1] = string.format("%04x:%d", act, n) end
    table.sort(list)
    log("BEWGUARD frames=%d refused=%d actions=%s", frame, last,
        #list > 0 and table.concat(list, ",") or "none")
    out:close()
end)
