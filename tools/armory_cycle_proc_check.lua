local LOG_PATH = os.getenv("ARMORY_AUDIT_LOG") or "C:/Users/you/Workplace/mk2-main/tools/armory_cycle_proc_check.log"
local logfh = io.open(LOG_PATH, "w")
local function logprint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end

local ACTIVE = symbols["active"] or 0x010dc6d0
local GSTATE = symbols["gstate"]
local CURBACK = symbols["curback"]
local PID_CYCLE = 0x0f -- MAINEQU.ASM: pid_cycle .set 00fh ; color cycler
local PROC_NEXT = 0x000
local PROC_ID   = 0x020
local PROC_WAKE = 0x0e0
local PROC_PA8  = 0x0a8 -- per vs_transition_test.lua usage pattern (a8 store)

local done = false
local frame = 0
local space
emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        local cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        logprint(string.format("[cycle-check] ACTIVE=0x%08x GSTATE=0x%08x CURBACK=0x%08x", ACTIVE, GSTATE or 0, CURBACK or 0))
    end
    if done or frame < 30 or frame % 20 ~= 0 or frame > 400 then return end

    local cb = space:read_u16(CURBACK)
    local g = space:read_u16(GSTATE)
    local p = space:read_u32(ACTIVE)
    local count, found, ids = 0, false, {}
    while p ~= 0 and count < 100 do
        local id = space:read_u16(p + PROC_ID)
        ids[#ids+1] = string.format("%02x", id)
        if id == PID_CYCLE then found = true end
        p = space:read_u32(p + PROC_NEXT)
        count = count + 1
    end
    logprint(string.format("[cycle-check] frame=%d curback=%d gstate=%d proc_count=%d pid_cycle_found=%s ids=%s",
        frame, cb, g, count, tostring(found), table.concat(ids, ",")))
end)
