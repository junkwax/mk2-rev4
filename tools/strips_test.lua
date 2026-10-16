-- strips_test.lua - strip_layer (MKDISP.ASM): one background list drawn in
-- horizontal bands, each at its own x.  Prototype #8,
-- doc/graphics_opportunities/STRIPS_PROTOTYPE.md.
--
-- THE WASTELAND, the round clock frozen, baklst6 the banded list.  One boot
-- per mode:
--
--   ST_MODE=base   f_strip 0: the ordinary list entry
--   ST_MODE=zero   8 bands, every offset 0      -> must equal base
--   ST_MODE=plus   1 band covering the screen, +D
--   ST_MODE=minus  1 band covering the screen, -D
--   ST_MODE=alt    8 bands, +D / -D alternating -> band k's rows equal plus
--                  (k even) or minus (k odd); all other rows equal base
--   ST_MODE=wave   f_strip 2, the built-in wave (for the strip image only)
--
-- ST_MOTION=0 (default): fighters hidden and parked, camera still, three
-- snapshots.  ST_MOTION=1: fighters VISIBLE and walking - both right, then
-- both left - so the camera scrolls and the fighters cross the banded rows;
-- fifteen snapshots, each logging the camera, worldtlx6 and how many baklst6
-- objects carry a velocity.
--
-- env: ST_MODE, ST_MOTION, ST_TOP, ST_H, ST_N, ST_D, ST_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("ST_MODE") or "base"
local MOTION = (os.getenv("ST_MOTION") or "0") == "1"
local TOP = tonumber(os.getenv("ST_TOP") or "40")
local H = tonumber(os.getenv("ST_H") or "12")
local N = tonumber(os.getenv("ST_N") or "8")
local D = tonumber(os.getenv("ST_D") or "6")
local LOG = os.getenv("ST_LOG") or (ROOT .. "/tools/strips_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[st] " .. string.format(fmt, ...)
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
    f_strip = sym("f_strip"), strip_n = sym("strip_n"), strip_top = sym("strip_top"),
    strip_h = sym("strip_h"), strip_off = sym("strip_off"), strip_ran = sym("strip_ran"),
    strip_refused = sym("strip_refused"), strip_v0 = sym("strip_v0"), strip_v1 = sym("strip_v1"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
    deep_dmaq = symbols["deep_dmaq"], dmaq_late = symbols["dmaq_late"], dmaq_lost = symbols["dmaq_lost"],
    f_freeze_timer = symbols["f_freeze_timer"],
    worldtlx = symbols["worldtlx"], worldtlx6 = symbols["worldtlx6"], baklst6 = symbols["baklst6"],
}
local OXVAL, OXVEL, OYVEL, OFLAGS2, M_INVISO = 0x080, 0x040, 0x060, 0x160, 0x20
local VTOTAL_REG = 0xc0000070
local GS_PSEL, GS_FIGHTING = 4, 2
local WASTELAND = 2
local ARM_FROM = 300
local SNAPS = { 400, 430, 460 }
if MOTION then
    SNAPS = {}
    for r = 320, 600, 20 do SNAPS[#SNAPS + 1] = r end
end

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local ran0, last_ran, peak = nil, nil, 0
local cost_max, cost_sum, cost_n = 0, 0, 0
local late0, deep_max = nil, 0
local moving_max = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true, ["P2 High Punch"] = true,
                   ["P1 Right"] = true, ["P1 Left"] = true, ["P2 Right"] = true, ["P2 Left"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

-- baklst6: how many objects, and how many carry a velocity
local function list_census()
    if not A.baklst6 then return -1, -1 end
    local o, n, moving = r32(A.baklst6), 0, 0
    while o ~= 0 and n < 400 do
        n = n + 1
        if r32(o + OXVEL) ~= 0 or r32(o + OYVEL) ~= 0 then moving = moving + 1 end
        o = r32(o)
    end
    return n, moving
end

local function arm()
    local offs = {}
    local f, n, top, h = 1, N, TOP, H
    if MODE == "base" then f = 0
    elseif MODE == "zero" then for k = 1, N do offs[k] = 0 end
    elseif MODE == "plus" or MODE == "minus" then
        n, top, h = 1, 0, 254
        offs[1] = (MODE == "plus") and D or -D
    elseif MODE == "alt" then for k = 1, N do offs[k] = (k % 2 == 1) and D or -D end
    elseif MODE == "wave" then f = 2 end
    for k = 1, 8 do w16(A.strip_off + (k - 1) * 16, offs[k] or 0) end
    w16(A.strip_n, n); w16(A.strip_top, top); w16(A.strip_h, h)
    w16(A.f_strip, f)
end

local function pressed(name)
    if fighting_frame > 0 then
        if not MOTION then return false end
        local rel = frame - fighting_frame
        if name == "P1 Right" or name == "P2 Right" then return rel >= 310 and rel < 440 end
        if name == "P1 Left" or name == "P2 Left" then return rel >= 450 and rel < 600 end
        return false
    end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("mode=%s motion=%d top=%d h=%d n=%d d=%d", MODE, MOTION and 1 or 0, TOP, H, N, D)
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
        if not MOTION then
            for _, h in ipairs({ A.p1_obj, A.p2_obj }) do
                local o = r32(h)
                if o ~= 0 then
                    w32(o + OXVAL, (620 & 0xffff) << 16)
                    w16(o + OFLAGS2, r16(o + OFLAGS2) | M_INVISO)
                end
            end
        end
        if rel == ARM_FROM then
            -- ST_VEL=1: give baklst6's first object 1 px/refresh of x velocity.  dispnext
            -- adds velocities once per walk, so a banded draw that forgot to suppress
            -- them after the first pass would move it ten times as fast and the zero
            -- boot would stop matching base.
            if os.getenv("ST_VEL") == "1" and A.baklst6 then
                local o = r32(A.baklst6)
                if o ~= 0 then w32(o + OXVEL, 0x10000); log("VEL object %08x oxvel=1.0", o) end
            end
            arm()
            ran0 = r16(A.strip_ran); last_ran = ran0
            late0 = A.dmaq_late and r16(A.dmaq_late) or 0
            if A.peak_overload then w16(A.peak_overload, 0) end
            if A.deep_dmaq then w16(A.deep_dmaq, 0) end
        end
        if rel >= ARM_FROM then
            local ran = r16(A.strip_ran)
            if ran ~= last_ran then
                local d = r16(A.strip_v1) - r16(A.strip_v0)
                if d < 0 then d = d + r16(VTOTAL_REG) + 1 end
                if d > cost_max then cost_max = d end
                cost_sum, cost_n, last_ran = cost_sum + d, cost_n + 1, ran
            end
            if A.peak_overload then
                local p = r16(A.peak_overload); if p > peak then peak = p end
            end
            if A.deep_dmaq then
                local q = r16(A.deep_dmaq); if q > deep_max then deep_max = q end
            end
            local _, mv = list_census()
            if mv > moving_max then moving_max = mv end
        end
        for _, at in ipairs(SNAPS) do
            if rel == at then
                pcall(function() manager.machine.screens[":screen"]:snapshot() end)
                local objs, mv = list_census()
                log("SNAP rel%d frame=%d wx=%d wx6=%d objs=%d moving=%d", at, frame,
                    A.worldtlx and s16(r16(A.worldtlx + 16)) or 0,
                    A.worldtlx6 and s16(r16(A.worldtlx6 + 16)) or 0, objs, mv)
            end
        end
        if rel == SNAPS[#SNAPS] + 5 then
            log("RESULT mode=%s banded=%d refused=%d cost_max_lines=%d cost_mean_lines=%.2f peak_overload=%d deep_dmaq_words=%d dmaq_late=%s qdma_drops=%s moving_max=%d",
                MODE, (r16(A.strip_ran) - (ran0 or 0)) & 0xffff, r16(A.strip_refused), cost_max,
                cost_n > 0 and cost_sum / cost_n or 0, peak, deep_max,
                A.dmaq_late and tostring((r16(A.dmaq_late) - late0) & 0xffff) or "n/a",
                A.qdma_drops and tostring(r16(A.qdma_drops)) or "n/a", moving_max)
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
