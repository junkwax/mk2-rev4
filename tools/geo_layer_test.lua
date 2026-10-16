-- geo_layer_test.lua - is CPU geometry drawn BETWEEN display lists?
--
-- geo_layer (MKDISP.ASM) is a `.long -1,geo_layer' entry in THE WASTELAND's
-- display list, after the far planes and the floor and before baklst2/1 and
-- the fighters.  Whatever it draws should cover everything before it and be
-- covered by everything after it.  geo_pass, at dsa9, draws on top of all.
--
-- One boot per mode, same ROM, same inputs, camera parked, fighters HIDDEN so
-- the only thing on screen that differs between boots is the geometry:
--
--   GL_MODE=none    nothing armed                       (baseline)
--   GL_MODE=front   two lines into geo_list  -> dsa9    (front-most)
--   GL_MODE=layer   the same two lines into geo_llist -> geo_layer
--
-- The lines are re-armed every refresh (both lists are consumed per frame)
-- and are full-width horizontals: one high in the sky, one through the
-- foreground plane.  tools/run_geo_layer_test.py diffs the snapshots.
--
-- env: GL_MODE, GL_PEN (pen byte, boonpal), GL_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("GL_MODE") or "none"
local PEN = tonumber(os.getenv("GL_PEN") or "1")
local LOG = os.getenv("GL_LOG") or (ROOT .. "/tools/geo_layer_test.log")
local SHOW = (os.getenv("GL_SHOW") or "0") ~= "0"   -- 1 = leave the fighters visible
local ROWS = {}
for r in (os.getenv("GL_ROWS") or "40,175"):gmatch("[^,]+") do ROWS[#ROWS + 1] = tonumber(r) end

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[gl] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    geo_count = sym("geo_count"), geo_list = sym("geo_list"),
    geo_lcount = sym("geo_lcount"), geo_llist = sym("geo_llist"),
    geo_lran = sym("geo_lran"), geo_drew = sym("geo_drew"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
    f_freeze_timer = symbols["f_freeze_timer"],
}
local OXVAL, OFLAGS2, M_INVISO = 0x080, 0x160, 0x20
local GS_PSEL, GS_FIGHTING = 4, 2
local WASTELAND = 2

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local lran0, peak = nil, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then
        pcall(function() s:snapshot() end)
        local wx = symbols["worldtlx"] and ((space:read_u32(symbols["worldtlx"]) >> 16) & 0xffff) or 0
        if wx >= 0x8000 then wx = wx - 0x10000 end
        local function sx(h)
            local o = space:read_u32(h); if o == 0 then return -9999 end
            local x = space:read_u16(o + 0x090); if x >= 0x8000 then x = x - 0x10000 end
            return x - wx
        end
        log("SNAP %s frame=%d p1x=%d p2x=%d", label, frame, sx(A.p1_obj), sx(A.p2_obj))
    end
end

-- [colour, xy0, dydx]: map 0 (boonpal) in the high half, pen replicated low
local function arm(list, count_addr)
    local colour = PEN * 0x01010101 & 0x0000ffff
    for i, y in ipairs(ROWS) do
        local base = list + (i - 1) * 96
        w32(base, colour)
        w32(base + 32, (y << 16) | 0)        -- start y:x = (y, 0)
        w32(base + 64, (0 << 16) | 399)      -- delta dy:dx = (0, 399)
    end
    w16(count_addr, #ROWS)
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

local SNAPS = { 400, 430, 460 }
emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("mode=%s pen=%d rows=%s", MODE, PEN, table.concat(ROWS, ","))
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, 1); w16(A.p2_char, 2)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, WASTELAND) end
    if frame > 9000 and fighting_frame == 0 then log("ERROR never reached the fight"); logfh:close(); manager.machine:exit(); return end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        -- park both fighters mid-stage and hide them: the camera holds still
        for _, h in ipairs({ A.p1_obj, A.p2_obj }) do
            local o = r32(h)
            if o ~= 0 then
                w32(o + OXVAL, (((h == A.p1_obj) and 560 or 700) & 0xffff) << 16)
                if not SHOW then w16(o + OFLAGS2, r16(o + OFLAGS2) | M_INVISO) end
            end
        end
        if rel == 300 then
            lran0 = r16(A.geo_lran)
            if A.peak_overload then w16(A.peak_overload, 0) end
        end
        if rel >= 300 then
            if MODE == "front" then arm(A.geo_list, A.geo_count)
            elseif MODE == "layer" then arm(A.geo_llist, A.geo_lcount) end
            if A.peak_overload then
                local p = r16(A.peak_overload); if p > peak then peak = p end
            end
        end
        for _, at in ipairs(SNAPS) do
            if rel == at then snap(string.format("rel%d", at)) end
        end
        if rel == SNAPS[#SNAPS] + 5 then
            log("RESULT mode=%s geo_layer_calls=%d peak_overload=%d qdma_drops=%s",
                MODE, (r16(A.geo_lran) - (lran0 or 0)) & 0xffff, peak,
                A.qdma_drops and tostring(r16(A.qdma_drops)) or "n/a")
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
