-- blood_count_probe.lua - watch MPROC.ASM's cosmetic blood-droplet counter.
--
-- getprc denies every pid_blood allocation once @blood_count reaches
-- MAX_BLOOD (64), and every blood effect funnels through getprc.  sucide
-- decrements the counter when a droplet dies; kilall (i.e. `murder`, which
-- runs on essentially every round/state transition) reclaims blood procs
-- WITHOUT decrementing it, and pinit - the only reset - runs once at
-- power-up, not per round.
--
-- So the question this probe answers is simply: does the counter ever come
-- back down?  Just let attract mode fight; no forcing required.
--
--   mame mk2 -autoboot_script tools/blood_count_probe.lua
--   BLOOD_PROBE_LOG=<path> to redirect the log.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("BLOOD_PROBE_LOG") or (ROOT .. "/tools/blood_count_probe.log")
local logfh = io.open(LOG_PATH, "w")

local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[blood] " .. msg)
    if logfh then logfh:write("[blood] " .. msg .. "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end

local A_BLOOD = symbols["blood_count"]
local A_GSTATE = symbols["gstate"]
if not A_BLOOD then
    log("FATAL blood_count not in mk2.map (needs .global in MPROC.ASM)")
    return
end
log("blood_count @ %08x  gstate @ %s", A_BLOOD, A_GSTATE and string.format("%08x", A_GSTATE) or "?")

local cpu, space
local frame, peak, last, cap_frame = 0, 0, -1, 0
local floor_since_peak = nil

emu.register_frame(function()
    if not cpu then
        cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]
    end
    frame = frame + 1
    local bc = space:read_u16(A_BLOOD)

    if bc > peak then peak = bc; floor_since_peak = bc end
    if floor_since_peak and bc < floor_since_peak then floor_since_peak = bc end

    if bc ~= last then
        last = bc
        if bc >= 64 and cap_frame == 0 then
            cap_frame = frame
            log("*** AT CAP frame=%d - every further blood proc is DENIED ***", frame)
        end
    end

    if frame % 600 == 0 then
        log("frame=%-6d count=%-3d peak=%-3d low_since_peak=%-3d gstate=%s",
            frame, bc, peak, floor_since_peak or -1,
            A_GSTATE and space:read_u16(A_GSTATE) or "?")
    end
end)
