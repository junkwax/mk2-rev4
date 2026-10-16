-- hole_locate.lua - WHERE IS THE PORTAL HOLE, actually?
--
-- oh_warp_arc anchors its bolt to `worldtlx3` on the theory that the archway
-- is ohspiral2BMOD, the "house" module on plane 3.  The rig that checked it
-- computed the hole's position the same way the ASM does and then asserted the
-- bolt landed there - which proves the two agree with each other and NOTHING
-- about where the hole is.  That is how this shipped drifting.
--
-- So: find the hole in the frame buffer at a series of camera positions, and
-- see which plane's worldtlx keeps `hole_screen_x + worldtlxN` constant.  That
-- constant is the hole's world x, and the plane that produced it is the plane
-- the arc has to hang off.
--
-- The hole is found by its INDEX, not its colour: the frame buffer holds pen
-- numbers, so the void's index is sampled once at a known-good position and
-- then tracked.  Env: MK2_ROOT, HOLE_LOG, HOLE_READY

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("HOLE_LOG") or (ROOT .. "/tools/hole_locate.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[hole] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view", "winner_status",
                     "battle_num", "map_position", "pageaddr", "f_freeze_timer",
                     "p1_obj", "p2_obj", "worldtly",
                     "worldtlx", "worldtlx2", "worldtlx3", "worldtlx4",
                     "worldtlx5", "worldtlx6", "worldtlx7" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_SUBZERO = 1, 8
local OUTER_HAVEN = 22
local OXVAL, OXPOS = 0x080, 0x090

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local PAGE0, PAGE1, VOID = nil, nil, nil
local stops, snap_index = {}, 0
local READY_PATH = os.getenv("HOLE_READY") or (ROOT .. "/tools/hole_locate_ready.flag")
local ready_written = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function world(a) return s16(r32(a) >> 16) end
local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end
local function setx(pobj, x)
    local o = r32(pobj)
    if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end
end
local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end) end
    log("SNAP %04d %s", snap_index, label); snap_index = snap_index + 1
end

-- the widest run of the void's index anywhere on the row band, on whichever
-- page currently holds a drawn frame
local function find_hole()
    if not VOID then return nil end
    local best, bx, by = 0, nil, nil
    for _, page in ipairs({ PAGE0, PAGE1 }) do
        for y = 128, 148 do
            local run, s = 0, nil
            for x = 0, 399 do
                if pxv(page, x, y) == VOID then
                    if run == 0 then s = x end
                    run = run + 1
                    if run > best then best, bx, by = run, s, y end
                else
                    run = 0
                end
            end
        end
    end
    if best < 8 then return nil end
    return bx + best // 2, by, best
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                       ["2 Players Start"] = true, ["P1 High Punch"] = true,
                       ["P2 High Punch"] = true, ["UI Select"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("---- locating the Outer Haven portal hole ----")
    end
    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = space and r16(A.gstate) or 0
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, OUTER_HAVEN)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space or finished then return end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        local pa = r32(A.pageaddr)
        local px, py = pa & 0xffff, (pa >> 16) & 0xffff
        PAGE0 = (py * 512 + px) * 8
        PAGE1 = (((py + 256) % 512) * 512 + px) * 8
    end
    if fighting_frame == 0 then
        if frame > 9000 then log("never reached a fight"); manager.machine:exit() end
        return
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status then w16(A.winner_status, 0) end
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end

    local rel = frame - fighting_frame

    -- sample the void's INDEX at the position it is known to sit at when the
    -- round opens: screen (203,138) with worldtlx3 412
    if rel == 60 then
        local a, b = pxv(PAGE0, 203, 138), pxv(PAGE1, 203, 138)
        VOID = a
        log("void index sampled at (203,138): page0=%02x page1=%02x", a, b)
    end

    -- walk the camera across the stage in eight stops
    local STOPS = { 40, 140, 240, 340, 440, 540, 640, 740 }
    local i = math.floor((rel - 120) / 90) + 1
    if rel > 120 and (rel - 120) % 90 == 0 and STOPS[i] then
        setx(A.p1_obj, STOPS[i]); setx(A.p2_obj, STOPS[i] + 56)
    end
    if rel > 120 and (rel - 120) % 90 == 60 and STOPS[i] then
        local hx, hy, w = find_hole()
        local row = {
            n = i, want = STOPS[i],
            wx = world(A.worldtlx), w2 = world(A.worldtlx2), w3 = world(A.worldtlx3),
            w4 = world(A.worldtlx4), w5 = world(A.worldtlx5), w6 = world(A.worldtlx6),
            hx = hx, hy = hy, hw = w,
            p1 = s16(r16(r32(A.p1_obj) + OXPOS)),
        }
        stops[#stops + 1] = row
        log("stop %d p1world=%d  tlx=%d tlx2=%d tlx3=%d tlx4=%d tlx5=%d tlx6=%d  hole=%s (w=%s) p1=%d",
            i, row.want, row.wx, row.w2, row.w3, row.w4, row.w5, row.w6,
            tostring(hx), tostring(w), row.p1)
        if i == 1 or i == 5 or i == 8 then snap("stop " .. i) end
    end

    if rel > 120 + 90 * 9 then
        log("---- which plane holds the hole still? ----")
        for _, k in ipairs({ "wx", "w2", "w3", "w4", "w5", "w6" }) do
            local vals, ok = {}, true
            for _, r in ipairs(stops) do
                if r.hx then vals[#vals + 1] = r.hx + r[k] end
            end
            if #vals >= 2 then
                local lo, hi = vals[1], vals[1]
                for _, v in ipairs(vals) do lo = math.min(lo, v); hi = math.max(hi, v) end
                log("  hole_screen_x + %-3s : %d..%d  (spread %d)", k, lo, hi, hi - lo)
            end
        end
        finished = true
        manager.machine:exit()
    end
end)
