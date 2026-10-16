-- ghost_test.lua - ghost_rec (MKDISP.ASM): constant-colour afterimages of
-- one fighter on a display list of their own.  doc/graphics_opportunities/
-- GHOSTS_PROTOTYPE.md.
--
-- THE WASTELAND, Liu Kang (P1) vs Cage (P2), both visible, the round clock
-- frozen.  P1 walks right, then left, so his ghosts trail him.  One boot per
-- mode, identical inputs:
--
--   GH_MODE=off   nothing armed                                (baseline)
--   GH_MODE=on    4 ghosts of P1, 3 ticks apart, a pen per age, armed
--                 from rel 300, disarmed at rel 560
--
-- Every snapshot logs the ghost list length and the free-object and
-- free-process counts, so the runner can prove the ghosts took neither.
--
-- env: GH_MODE, GH_N, GH_GAP, GH_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("GH_MODE") or "off"
local NGH = tonumber(os.getenv("GH_N") or "4")
local GAP = tonumber(os.getenv("GH_GAP") or "3")
local LOG = os.getenv("GH_LOG") or (ROOT .. "/tools/ghost_test.log")
local PENS = { 0x0b0b, 0x0505, 0x0404, 0x0a0a, 0x0606, 0x0c0c }   -- blue, purple, hot purple, dark red, green, yellow

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[gh] " .. string.format(fmt, ...)
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
    -- optional: GH_MODE=off also runs on a ROM WITHOUT the ghost code, as a control
    ghost_lst = symbols["ghost_lst"], gh_src = symbols["gh_src"], gh_n = symbols["gh_n"],
    gh_gap = symbols["gh_gap"], gh_col = symbols["gh_col"], gh_snaps = symbols["gh_snaps"],
    ofree = symbols["ofree"], pfree = symbols["free"],
    peak_overload = symbols["peak_overload"], deep_dmaq = symbols["deep_dmaq"],
    dmaq_late = symbols["dmaq_late"], f_freeze_timer = symbols["f_freeze_timer"],
    worldtlx = symbols["worldtlx"],
}
local CRAM = 0x01800000
local GS_PSEL, GS_FIGHTING = 4, 2
local WASTELAND = 2
local ARM_FROM, DISARM_AT = 300, 560
local SNAPS = {}
for r = 320, 550, 10 do SNAPS[#SNAPS + 1] = r end
SNAPS[#SNAPS + 1] = 570
SNAPS[#SNAPS + 1] = 590

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local snaps0, peak, deep_max, late0 = 0, 0, 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true, ["P2 High Punch"] = true,
                   ["P1 Right"] = true, ["P1 Left"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function count_list(head)
    if not head then return -1 end
    local o, n = r32(head), 0
    while o ~= 0 and n < 2000 do n = n + 1; o = r32(o) end
    return n
end

local function pressed(name)
    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if name == "P1 Right" then return rel >= 310 and rel < 430 end
        if name == "P1 Left" then return rel >= 440 and rel < 540 end
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
        log("mode=%s n=%d gap=%d", MODE, NGH, GAP)
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
        if rel == ARM_FROM then
            for k = 1, #PENS do
                local p = PENS[k] & 0xff
                log("PEN age=%d word=%04x rgb555=%04x", k, PENS[k], r16(CRAM + p * 16))
            end
            snaps0 = A.gh_snaps and r16(A.gh_snaps) or 0
            late0 = A.dmaq_late and r16(A.dmaq_late) or 0
            if A.peak_overload then w16(A.peak_overload, 0) end
            if A.deep_dmaq then w16(A.deep_dmaq, 0) end
            if MODE == "on" then
                for k = 1, 6 do w16(A.gh_col + (k - 1) * 16, PENS[k]) end
                w16(A.gh_n, NGH); w16(A.gh_gap, GAP)
                w32(A.gh_src, A.p1_obj)
            end
        end
        if MODE == "on" and rel == DISARM_AT then w32(A.gh_src, 0) end
        -- PREARM: the state both boots must share before anything is armed.  The
        -- attract/select automation is scheduled on Lua frame callbacks and is NOT
        -- deterministic under load (measured: 3 different fight starts in 8 boots
        -- of the same ROM), so the runner compares this line and re-boots a pair
        -- that did not start identical rather than scoring two different fights.
        if rel == ARM_FROM - 1 then
            local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
            log("PREARM p1x=%d p2x=%d wx=%d objfree=%d", o1 ~= 0 and s16(r16(o1 + 0x090)) or -9999,
                o2 ~= 0 and s16(r16(o2 + 0x090)) or -9999,
                A.worldtlx and s16(r16(A.worldtlx + 16)) or 0, count_list(A.ofree))
        end
        -- GH_DIAG=1: a per-frame trace around the arm point - where the CPU is,
        -- where P1 is, what state he is in - to catch a divergence as it starts
        if os.getenv("GH_DIAG") == "1" and rel >= 294 and rel <= 360 then
            local o = r32(A.p1_obj)
            local pc = 0
            pcall(function() pc = manager.machine.devices[":maincpu"].state["PC"].value end)
            log("DIAG rel%d pc=%08x p1obj=%08x p1x=%d p1y=%d p1state=%d ghosts=%d snaps=%d objfree=%d",
                rel, pc, o, o ~= 0 and s16(r16(o + 0x090)) or -9999, o ~= 0 and s16(r16(o + 0x0b0)) or -9999,
                symbols["p1_state"] and r16(symbols["p1_state"]) or -1,
                count_list(A.ghost_lst), A.gh_snaps and r16(A.gh_snaps) or -1, count_list(A.ofree))
        end
        if rel >= ARM_FROM then
            if A.peak_overload then local p = r16(A.peak_overload); if p > peak then peak = p end end
            if A.deep_dmaq then local q = r16(A.deep_dmaq); if q > deep_max then deep_max = q end end
        end
        for _, at in ipairs(SNAPS) do
            if rel == at then
                pcall(function() manager.machine.screens[":screen"]:snapshot() end)
                local o = r32(A.p1_obj)
                log("SNAP rel%d frame=%d armed=%d ghosts=%d objfree=%d procfree=%d p1x=%d wx=%d", at, frame,
                    (MODE == "on" and at < DISARM_AT) and 1 or 0, count_list(A.ghost_lst),
                    count_list(A.ofree), count_list(A.pfree),
                    o ~= 0 and s16(r16(o + 0x090)) or -9999,
                    A.worldtlx and s16(r16(A.worldtlx + 16)) or 0)
            end
        end
        if rel == SNAPS[#SNAPS] + 5 then
            log("RESULT mode=%s snapshots_taken=%d peak_overload=%d deep_dmaq_words=%d dmaq_late=%s",
                MODE, A.gh_snaps and ((r16(A.gh_snaps) - snaps0) & 0xffff) or 0, peak, deep_max,
                A.dmaq_late and tostring((r16(A.dmaq_late) - late0) & 0xffff) or "n/a")
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
