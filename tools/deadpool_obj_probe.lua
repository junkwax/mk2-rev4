-- deadpool_obj_probe.lua
--
-- Logs live process/object-list state for the Dead Pool Ed hanger test.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP_PATH = ROOT .. "/src/mk2.map"
local LOG_PATH = ROOT .. "/tmp/dp/deadpool_obj_probe.log"

local WATCH_FRAMES = {
    [180] = "early_fight",
    [360] = "mid_fight",
    [480] = "timer_90_area",
    [600] = "after_timer_90",
}

local logf = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
    print(line)
    if logf then
        logf:write(line .. "\n")
        logf:flush()
    end
end

local function map_symbol(name, fallback)
    local f = io.open(MAP_PATH, "r")
    if not f then return fallback end
    for line in f:lines() do
        for addr, sym in line:gmatch("([0-9A-Fa-f]+)%s+([_%w]+)") do
            if sym == name then
                f:close()
                return tonumber(addr, 16)
            end
        end
    end
    f:close()
    return fallback
end

local space = manager.machine.devices[":maincpu"].spaces["program"]

local function r16(a)
    local ok, v = pcall(function() return space:read_u16(a) end)
    return ok and v or 0
end

local function r32(a)
    local ok, v = pcall(function() return space:read_u32(a) end)
    return ok and v or 0
end

local A = {
    active = map_symbol("active", 0x010dc6d0),
    objlst = map_symbol("objlst", 0x01127570),
    objlst2 = map_symbol("objlst2", 0x01127590),
    objlst3 = map_symbol("objlst3", 0x011275b0),
    curback = map_symbol("curback", 0x0112c0d0),
    EDHANG1 = map_symbol("EDHANG1", 0xffbe8220),
    EDHANG1A = map_symbol("EDHANG1A", 0xffbe82b0),
    EDHANG1B = map_symbol("EDHANG1B", 0xffbe8340),
    EDHANG1C = map_symbol("EDHANG1C", 0xffbe83d0),
    TINCHAIN4 = map_symbol("TINCHAIN4", 0),
    TINHOOK = map_symbol("TINHOOK", 0),
}

local O = {
    olink = 0x000,
    oxpos = 0x090,
    oypos = 0x0b0,
    ozpos = 0x0d0,
    opal = 0x140,
    oflags2 = 0x160,
    oimg = 0x1a0,
    oid = 0x1c0,
    oshape = 0x1d0,
}

local P = {
    plink = 0x000,
    procid = 0x020,
    pa8 = 0x0c0,
}

local img_names = {}
for k, v in pairs(A) do
    if k:match("^EDHANG") or k == "TINCHAIN4" or k == "TINHOOK" then
        img_names[v] = k
    end
end

local function interesting_img(img)
    return img_names[img] ~= nil
end

local function dump_processes(tag)
    local p = r32(A.active)
    local count = 0
    while p ~= 0 and count < 80 do
        local pid = r16(p + P.procid)
        if pid == 0x0006 or pid == 0x0111 or pid == 0x0112 or pid == 0x001b then
            log("%s proc[%02d] ptr=0x%08X pid=0x%04X pa8=0x%08X", tag, count, p, pid, r32(p + P.pa8))
        end
        p = r32(p + P.plink)
        count = count + 1
    end
end

local function dump_obj_list(name, addr, tag)
    local p = r32(addr)
    local count = 0
    local hits = 0
    while p ~= 0 and count < 120 do
        local img = r32(p + O.oimg)
        local oid = r16(p + O.oid)
        if interesting_img(img) or oid == 0x0006 or oid == 0x0111 or oid == 0x0112 then
            log("%s %s[%02d] obj=0x%08X oid=0x%04X img=%s/0x%08X x=%d y=%d z=%d opal=0x%04X flags2=0x%04X shape=0x%08X",
                tag, name, count, p, oid, img_names[img] or "?", img,
                r16(p + O.oxpos), r16(p + O.oypos), r16(p + O.ozpos),
                r16(p + O.opal), r16(p + O.oflags2), r32(p + O.oshape))
            if (r16(p + O.oflags2) & 0x0002) ~= 0 then
                local m = r32(p + O.oimg)
                for i = 0, 2 do
                    local base = m + (i * 0x70)
                    log("%s %s[%02d] mpart[%d] sag=0x%08X size=0x%08X ctrl=0x%04X dx=%d dy=%d",
                        tag, name, count, i, r32(base), r32(base + 0x20),
                        r16(base + 0x40), r16(base + 0x50), r16(base + 0x60))
                end
            end
            hits = hits + 1
        end
        p = r32(p + O.olink)
        count = count + 1
    end
    log("%s %s scanned=%d hits=%d", tag, name, count, hits)
end

log("probe loaded active=0x%08X objlst=0x%08X EDHANG1=0x%08X A=0x%08X B=0x%08X C=0x%08X",
    A.active, A.objlst, A.EDHANG1, A.EDHANG1A, A.EDHANG1B, A.EDHANG1C)

local frame = 0
emu.register_frame_done(function()
    frame = frame + 1
    local tag = WATCH_FRAMES[frame]
    if not tag then return end
    log("----- %s frame=%d curback=%d -----", tag, frame, r16(A.curback))
    dump_processes(tag)
    dump_obj_list("objlst", A.objlst, tag)
    dump_obj_list("objlst2", A.objlst2, tag)
    dump_obj_list("objlst3", A.objlst3, tag)
end)
