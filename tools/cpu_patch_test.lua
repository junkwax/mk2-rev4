-- cpu_patch_test.lua - cpu_patch (MKDISP.ASM): small CPU pixel operations on
-- the finished picture.  Graphics audit rows 22 (stipple) and 23 (mosaic),
-- doc/graphics_opportunities/CPU_PATCH_PROTOTYPE.md.
--
-- The same fight as palrect_test.lua: THE WASTELAND, Liu Kang (P1) vs Cage
-- (P2), both parked, the camera still, the round clock frozen.  One boot per
-- mode:
--
--   CP_MODE=none     nothing armed                               (baseline)
--   CP_MODE=mosaic   the rectangle in CP_BLOCK x CP_BLOCK blocks
--   CP_MODE=stipple  pen CP_PEN of colour map CP_MAP on the (x+y)-odd checker
--
-- Armed every frame from rel 300 to 439 (cp_count is consumed per frame),
-- snapshots at rel 400 and 430 (armed) and 460 (disarmed).  PREARM at rel 299
-- lets the runner prove the boots are in step before it compares pixels.
--
-- env: CP_MODE, CP_RECT ("y,x,h,w"), CP_BLOCK, CP_PEN, CP_MAP, CP_LOG, MK2_ROOT

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("CP_MODE") or "none"
local LOG = assert(os.getenv("CP_LOG"), "CP_LOG")
local RECT = {}
for v in (os.getenv("CP_RECT") or "100,96,32,32"):gmatch("[^,]+") do RECT[#RECT + 1] = tonumber(v) end
local RY, RX, RH, RW = RECT[1], RECT[2], RECT[3], RECT[4]
local BLOCK = tonumber(os.getenv("CP_BLOCK") or "4")
local PEN = tonumber(os.getenv("CP_PEN") or "14")
local CMAP = tonumber(os.getenv("CP_MAP") or "0")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[cp] " .. string.format(fmt, ...)
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
    cp_count = sym("cp_count"), cp_mode = sym("cp_mode"), cp_xy = sym("cp_xy"), cp_hw = sym("cp_hw"),
    cp_arg = sym("cp_arg"), cp_map = sym("cp_map"), cp_ran = sym("cp_ran"), cp_refused = sym("cp_refused"),
    cp_v0 = sym("cp_v0"), cp_v1 = sym("cp_v1"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
    f_freeze_timer = symbols["f_freeze_timer"], worldtlx = symbols["worldtlx"], rand = symbols["rand"],
}
local OXVAL, OXPOS = 0x080, 0x090
local VTOTAL_REG = 0xc0000070          -- 34010 i/o register, bit address
local CRAM = 0x01800000
local GS_PSEL, GS_FIGHTING = 4, 2
local WASTELAND = 2
local ARM_FROM, ARM_UNTIL = 300, 440
local SNAPS = { 400, 430, 460 }
local MODE_NUM = { mosaic = 1, stipple = 2 }

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local ran0, last_ran, peak = nil, nil, 0
local cost_max, cost_sum, cost_n = 0, 0, 0

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

local function screen_x(h)
    local o = r32(h); if o == 0 then return -9999 end
    local wx = A.worldtlx and ((r32(A.worldtlx) >> 16) & 0xffff) or 0
    if wx >= 0x8000 then wx = wx - 0x10000 end
    local x = r16(o + OXPOS); if x >= 0x8000 then x = x - 0x10000 end
    return x - wx
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

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("mode=%s rect y=%d x=%d h=%d w=%d block=%d pen=%d map=%d", MODE, RY, RX, RH, RW, BLOCK, PEN, CMAP)
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
        for _, h in ipairs({ A.p1_obj, A.p2_obj }) do
            local o = r32(h)
            if o ~= 0 then w32(o + OXVAL, (((h == A.p1_obj) and 560 or 700) & 0xffff) << 16) end
        end
        if rel == ARM_FROM - 1 then
            log("PREARM fight=%d p1x=%d p2x=%d rand=%s", fighting_frame, screen_x(A.p1_obj), screen_x(A.p2_obj),
                A.rand and string.format("%08x", r32(A.rand)) or "n/a")
        end
        if rel == ARM_FROM then
            log("PEN map=%d pen=%d colour=%04x", CMAP, PEN, r16(CRAM + (CMAP * 256 + PEN) * 16))
            ran0 = r16(A.cp_ran); last_ran = ran0
            if A.peak_overload then w16(A.peak_overload, 0) end
        end
        if rel >= ARM_FROM then
            local ran = r16(A.cp_ran)
            if ran ~= last_ran then
                local d = r16(A.cp_v1) - r16(A.cp_v0)
                if d < 0 then d = d + r16(VTOTAL_REG) + 1 end
                if d > cost_max then cost_max = d end
                cost_sum, cost_n, last_ran = cost_sum + d, cost_n + 1, ran
            end
            if A.peak_overload then
                local p = r16(A.peak_overload); if p > peak then peak = p end
            end
        end
        if MODE_NUM[MODE] and rel >= ARM_FROM and rel < ARM_UNTIL then
            w32(A.cp_xy, (RY << 16) | RX)
            w32(A.cp_hw, (RH << 16) | RW)
            w16(A.cp_mode, MODE_NUM[MODE])
            w16(A.cp_arg, MODE == "mosaic" and BLOCK or PEN)
            w16(A.cp_map, CMAP)
            w16(A.cp_count, 1)
        end
        for _, at in ipairs(SNAPS) do
            if rel == at then
                pcall(function() manager.machine.screens[":screen"]:snapshot() end)
                log("SNAP rel%d frame=%d p1x=%d p2x=%d", at, frame, screen_x(A.p1_obj), screen_x(A.p2_obj))
            end
        end
        if rel == SNAPS[#SNAPS] + 5 then
            log("RESULT mode=%s passes=%d refused=%d cost_max_lines=%d cost_mean_lines=%.2f vtotal=%d peak_overload=%d qdma_drops=%s",
                MODE, (r16(A.cp_ran) - (ran0 or 0)) & 0xffff, r16(A.cp_refused), cost_max,
                cost_n > 0 and cost_sum / cost_n or 0, r16(VTOTAL_REG), peak,
                A.qdma_drops and tostring(r16(A.qdma_drops)) or "n/a")
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
