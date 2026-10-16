-- palrect_test.lua - pal_rect (MKDISP.ASM): recolour a rectangle through the
-- palette-map plane.  Prototype #7, doc/graphics_opportunities/PALRECT_PROTOTYPE.md.
--
-- THE WASTELAND, Liu Kang (P1) vs Cage (P2), both visible and parked, the
-- camera still, the round clock frozen.  One boot per mode:
--
--   PR_MODE=none    nothing armed                               (baseline)
--   PR_MODE=ident   the rectangle, identity selector table
--   PR_MODE=swap    the rectangle, P1's selector -> P2's selector
--
-- Armed every frame from rel 300 to 439 (pr_count is consumed per frame),
-- snapshots at rel 400 and 430 (armed) and 460 (disarmed).  Logs both
-- fighters' opal, both palettes out of colour RAM, the rectangle, and the
-- pass's cost in scanlines.  tools/run_palrect_test.py judges the frames.
--
-- env: PR_MODE, PR_RECT ("y,x,h,w"), PR_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("PR_MODE") or "none"
local LOG = os.getenv("PR_LOG") or (ROOT .. "/tools/palrect_test.log")
local RECT = {}
for v in (os.getenv("PR_RECT") or "96,80,64,80"):gmatch("[^,]+") do RECT[#RECT + 1] = tonumber(v) end
local RY, RX, RH, RW = RECT[1], RECT[2], RECT[3], RECT[4]

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[pr] " .. string.format(fmt, ...)
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
    pr_count = sym("pr_count"), pr_xy = sym("pr_xy"), pr_hw = sym("pr_hw"),
    pr_map = sym("pr_map"), pr_ran = sym("pr_ran"), pr_refused = sym("pr_refused"),
    pr_v0 = sym("pr_v0"), pr_v1 = sym("pr_v1"),
    peak_overload = symbols["peak_overload"], qdma_drops = symbols["qdma_drops"],
    f_freeze_timer = symbols["f_freeze_timer"], worldtlx = symbols["worldtlx"],
}
local OXVAL, OXPOS, OPAL = 0x080, 0x090, 0x140
local VTOTAL_REG = 0xc0000070          -- 34010 i/o register, bit address
local CRAM = tonumber(os.getenv("PR_CRAM") or "0x01800000")   -- Wolf: 0x01880000
local GS_PSEL, GS_FIGHTING = 4, 2
local WASTELAND = 2
local ARM_FROM, ARM_UNTIL = 300, 440
local SNAPS = { 400, 430, 460 }

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

local function dump_pal(sel)
    local t = {}
    for i = 0, 255 do t[#t + 1] = string.format("%04x", r16(CRAM + (sel * 256 + i) * 16)) end
    log("PAL sel=%d %s", sel, table.concat(t))
end

local function load_table()
    for i = 0, 255 do w16(A.pr_map + i * 16, i) end
    local o1, o2 = r16(r32(A.p1_obj) + OPAL), r16(r32(A.p2_obj) + OPAL)
    log("OPAL p1=%04x p2=%04x", o1, o2)
    local sels = { o1 & 0xff, (o1 >> 8) & 0xff, o2 & 0xff, (o2 >> 8) & 0xff }
    local seen = {}
    for _, s in ipairs(sels) do if not seen[s] then seen[s] = true; dump_pal(s) end end
    if MODE == "swap" then
        w16(A.pr_map + (o1 & 0xff) * 16, o2 & 0xff)
        w16(A.pr_map + ((o1 >> 8) & 0xff) * 16, (o2 >> 8) & 0xff)
    end
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
        log("mode=%s rect y=%d x=%d h=%d w=%d", MODE, RY, RX, RH, RW)
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
        if rel == ARM_FROM then
            load_table()
            ran0 = r16(A.pr_ran); last_ran = ran0
            if A.peak_overload then w16(A.peak_overload, 0) end
        end
        if rel >= ARM_FROM then
            local ran = r16(A.pr_ran)
            if ran ~= last_ran then
                local d = r16(A.pr_v1) - r16(A.pr_v0)
                if d < 0 then d = d + r16(VTOTAL_REG) + 1 end
                if d > cost_max then cost_max = d end
                cost_sum, cost_n, last_ran = cost_sum + d, cost_n + 1, ran
            end
            if A.peak_overload then
                local p = r16(A.peak_overload); if p > peak then peak = p end
            end
        end
        if MODE ~= "none" and rel >= ARM_FROM and rel < ARM_UNTIL then
            w32(A.pr_xy, (RY << 16) | RX)
            w32(A.pr_hw, (RH << 16) | RW)
            w16(A.pr_count, 1)
        end
        for _, at in ipairs(SNAPS) do
            if rel == at then
                pcall(function() manager.machine.screens[":screen"]:snapshot() end)
                log("SNAP rel%d frame=%d p1x=%d p2x=%d", at, frame, screen_x(A.p1_obj), screen_x(A.p2_obj))
            end
        end
        if rel == SNAPS[#SNAPS] + 5 then
            log("RESULT mode=%s passes=%d refused=%d cost_max_lines=%d cost_mean_lines=%.2f vtotal=%d peak_overload=%d qdma_drops=%s",
                MODE, (r16(A.pr_ran) - (ran0 or 0)) & 0xffff, r16(A.pr_refused), cost_max,
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
