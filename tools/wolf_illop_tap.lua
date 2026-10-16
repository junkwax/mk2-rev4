-- wolf_illop_tap.lua - log the CPU state each time illop_count is written
-- (every "reboot" in this build is illop_recover).  Env: WB_LOG, WS_MAP.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local cpu = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local n = 0
local frame = 0
local function dump(tag)
    local st = cpu.state
    local t = {}
    for _, r in ipairs({"PC", "SP", "A0", "A1", "A7", "A8", "A9", "A11", "A13", "A14", "B0", "B1"}) do
        if st[r] then t[#t + 1] = string.format("%s=%08X", r, st[r].value) end
    end
    log("%s f=%d %s", tag, frame, table.concat(t, " "))
    local sp = st["SP"].value
    local w = {}
    for i = 0, 7 do w[#w + 1] = string.format("%08X", space:read_u32(sp + 32 * i)) end
    log("   stack: %s", table.concat(w, " "))
    local ret = space:read_u32(sp + 64)
    if ret >= 0xFF800000 then
        local c = {}
        for a = ret - 0x100, ret - 0x10, 0x10 do c[#c + 1] = string.format("%04X", space:read_u16(a)) end
        log("   code before %08X: %s", ret, table.concat(c, " "))
    end
end
tap = space:install_write_tap(S.illop_count, S.illop_count + 15, "illop", function(o, d, m)
    n = n + 1
    if n <= 6 then dump("ILLOP#" .. n) end
    return d
end)
emu.register_frame(function()
    frame = frame + 1
    if frame == 2500 then log("done, %d writes", n); f:close(); manager.machine:exit() end
end)
