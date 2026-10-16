-- mk1_court_objs.lua - MK1 (MAME `mk`): what is on THE COURTYARD's object
-- lists?  MK1's courtyard process (FFCBB780) steps every object on the lists
-- at 104F950h and 104F930h (plane-table entries 2 and 3) through six monk
-- frames; doc/MK1_COURTYARD_GATES.md.  This plays a 1P game held on one
-- stage (MK1C_STAGE, default 0 = THE COURTYARD; 1 = PALACE GATES) and, once
-- fighting, dumps object lists every 60 frames: each object's address and a
-- window of its fields, so the image pointer, x/y and ID can be identified,
-- plus a snapshot.  Env: MK1C_OUT (dir), MK1C_STAGE, MK1C_LISTS (hex list
-- heads, comma separated; default the courtyard's two).
local OUT = (os.getenv("MK1C_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local log = nil
local function L(fmt, ...)
    if not log then log = io.open(OUT .. "objs.log", "w") end
    log:write(string.format(fmt, ...) .. "\n"); log:flush()
end
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local ports = manager.machine.ioport.ports
local function fld(name)
    for _, p in pairs(ports) do if p.fields[name] then return p.fields[name] end end
end
local F = { coin = fld("Coin 1"), start = fld("1 Player Start"), hp = fld("P1 High Punch") }
local A = { gstate = 0x01051190, curback = 0x01051820 }
local STAGE = tonumber(os.getenv("MK1C_STAGE") or "0")
local LISTS = {}
for h in string.gmatch(os.getenv("MK1C_LISTS") or "0104F950,0104F930", "%x+") do
    LISTS[#LISTS + 1] = { tonumber(h, 16), "list" .. h }
end
local frame, fightf, started, sel0 = 0, nil, false, nil
-- MK1C_TAP=1: log the PC of every write of an object ID 1..15 into an object's
-- ID field (+0C0h; objects are 520h bits apart, one is at 01017E80) - which
-- code spawns the ID-animated pieces.
local taps = {}
if os.getenv("MK1C_TAP") == "1" then
    local cpu = manager.machine.devices[":maincpu"]
    local seen = {}
    -- the tap's offset form is checked both ways (bit and byte address)
    local want = { [0x01017F40] = true, [0x01017F40 >> 3] = true, [0x01017F40 >> 3 & ~1] = true }
    taps[1] = mem:install_write_tap(0x00200000, 0x0103FFFF, "idtap", function(offset, data, mask)
        if offset < 0x01017E80 or offset >= 0x01017E80 + 0x520 then return end
        if (data & mask) ~= (2 & mask) and (data & mask) ~= ((2 << 16) & mask) then return end
        local pc = cpu.state["PC"].value
        local key = string.format("%08X:%X", pc, data)
        if not seen[key] then seen[key] = true; L("IDTAP pc %08X data %08X mask %08X at %08X (frame %d)", pc, data, mask, offset, frame) end
    end)
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
        L("mk1_court_objs start")
    end
    frame = frame + 1
    local gs = mem:read_u16(A.gstate)
    -- tools/mk1_throne_capture.lua's sequence: HP at 600, then coin + start
    -- every 400 frames from 1000 until the select screen, HP to confirm
    if gs == 4 and not sel0 then sel0 = frame; L("select at frame %d", frame) end
    local k = (frame - 600) % 400
    local menus = (not sel0) and frame >= 1000
    F.coin:set_value((menus and (k < 6 or (k >= 30 and k < 36))) and 1 or 0)
    F.start:set_value((menus and k >= 120 and k < 126) and 1 or 0)
    F.hp:set_value(((frame >= 600 and frame < 606) or (sel0 and frame >= sel0 + 300 and frame < sel0 + 306)) and 1 or 0)
    if sel0 and gs ~= 2 then mem:write_u16(A.curback, STAGE) end  -- hold the stage
    if gs == 2 and not fightf then fightf = frame; L("fight at frame %d, curback %d", frame, mem:read_u16(A.curback)) end
    if fightf and (frame - fightf) % 60 == 30 and frame - fightf <= 400 then
        L("== frame %d (fight +%d)", frame, frame - fightf)
        for _, lst in ipairs(LISTS) do
            local o, n = mem:read_u32(lst[1]), 0
            while o ~= 0 and n < 40 do
                local t = {}
                for off = 0, 0x2C0, 0x20 do t[#t + 1] = string.format("%03X:%08X", off, mem:read_u32(o + off)) end
                L("%s obj %08X %s", lst[2], o, table.concat(t, " "))
                o = mem:read_u32(o); n = n + 1
            end
            L("%s: %d objects", lst[2], n)
        end
        if frame - fightf == 30 or frame - fightf == 270 then manager.machine.video:snapshot() end
    end
    if fightf and frame - fightf > 420 then L("done"); log:close(); manager.machine:exit() end
    if frame > 12000 then L("no fight by frame 12000, gstate %d", gs); log:close(); manager.machine:exit() end
end)
