local LOG_PATH = os.getenv("ARMORY_AUDIT_LOG") or "C:/Users/you/Workplace/mk2-main/tools/armory_baklst4_scan.log"
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

local CURBACK = symbols["curback"]
local GSTATE  = symbols["gstate"]
local VAT_ADDR = symbols["VAT"]

local O = {
    next=0x000, oxpos=0x090, oypos=0x0b0, ozval=0x0c0, oflags=0x0f0,
    osag=0x100, osize=0x120, opal=0x140, oflags2=0x160, oimg=0x1a0,
    oid=0x1c0, oshape=0x1d0, ochar=0x1f0,
}

local function dump_list(space, label, addr)
    local p = space:read_u32(addr)
    local n = 0
    while p ~= 0 and n < 60 do
        local img  = space:read_u32(p + O.oimg)
        local sag  = space:read_u32(p + O.osag)
        local pal  = space:read_u16(p + O.opal)
        local fl   = space:read_u16(p + O.oflags)
        local oid  = space:read_u16(p + O.oid)
        local x    = space:read_u16(p + O.oxpos)
        local y    = space:read_u16(p + O.oypos)
        logprint(string.format("[baklst-scan] %s #%d obj=0x%08x oid=%04x xy=(%d,%d) img=0x%08x sag=0x%08x pal=%04x fl=%04x",
            label, n+1, p, oid, x, y, img, sag, pal, fl))
        p = space:read_u32(p + O.next)
        n = n + 1
    end
    if n == 0 then logprint(string.format("[baklst-scan] %s EMPTY", label)) end
    return n
end

local done = false
local frame = 0
emu.register_frame(function()
    if done then return end
    frame = frame + 1
    local cpu = manager.machine.devices[":maincpu"]
    local space = cpu.spaces["program"]
    if frame == 1 then
        logprint(string.format("[baklst-scan] VAT=0x%08x", VAT_ADDR or 0))
    end
    if frame % 30 == 0 then
        logprint(string.format("[baklst-scan] heartbeat frame=%d", frame))
    end
    if frame < 240 then return end
    done = true

    local cb = space:read_u16(CURBACK)
    local g = space:read_u16(GSTATE)
    logprint(string.format("[baklst-scan] frame=%d curback=%d gstate=%d", frame, cb, g))

    local PALRAM = symbols["palram"]
    if PALRAM then
        local id28 = space:read_u32(PALRAM + 0x1c * 0x40)
        local id29 = space:read_u32(PALRAM + 0x1d * 0x40)
        logprint(string.format("[baklst-scan] palram slot 0x1c id=0x%08x (VAT=0x%08x match=%s)", id28, VAT_ADDR or 0, tostring(id28 == VAT_ADDR)))
        logprint(string.format("[baklst-scan] palram slot 0x1d id=0x%08x", id29))
    end

    for i = 1, 8 do
        local sym = symbols["baklst" .. i]
        if sym then
            dump_list(space, "baklst" .. i, sym)
        else
            logprint("[baklst-scan] baklst" .. i .. " symbol not found")
        end
    end
end)
