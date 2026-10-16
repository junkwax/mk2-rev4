-- tower_clouds_test.lua - THE TOWER's drifting cloud rows, for an A/B between
-- the stock ROM (cloud1c/cloud1d as art) and the one that draws them as
-- h-flipped cloud1b/cloud1a (cloud_mirror / cloud_set_clip, BGND.ASM).
--
-- Fighters hidden and parked, the round clock frozen.  cloud_proc moves both
-- rows on their own (1.5 and 3 px a refresh), so across the snapshots every
-- cloud crosses both window edges and wraps - which is where the swapped
-- skip bytes matter.  tools/run_tower_clouds_test.py compares the frames.
--
-- Every snapshot logs the clouds on baklst7/8: how many are mirrored, and how
-- many mirrored ones carry an edge clip (ofset nonzero) at that moment.
--
-- env: TC_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("TC_LOG") or (ROOT .. "/tools/tower_clouds_test.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[tc] " .. string.format(fmt, ...)
    logfh:write(line, "\n"); logfh:flush()
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
    baklst7 = sym("baklst7"), baklst8 = sym("baklst8"),
    ofree = symbols["ofree"], f_freeze_timer = symbols["f_freeze_timer"],
    worldtlx = symbols["worldtlx"],
}
local OXVAL, OXPOS, OFSET, OFLAGS, OFLAGS2, M_INVISO = 0x080, 0x090, 0x0e0, 0x0f0, 0x160, 0x20
local B_FLIPH_MASK = 0x0010            -- m_fliph in the oflags word (dmahfl)
local GS_PSEL, GS_FIGHTING = 4, 2
local TOWER = 3
local ARM_FROM = 300
local SNAPS = {}
for r = 300, 1200, 12 do SNAPS[#SNAPS + 1] = r end

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true, ["P2 High Punch"] = true }
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

local function clouds()
    local n, mirrored, mclip, clip, xs = 0, 0, 0, 0, {}
    for _, head in ipairs({ A.baklst8, A.baklst7 }) do
        local o, k = r32(head), 0
        while o ~= 0 and k < 8 do
            n = n + 1; k = k + 1
            local fl, of = r16(o + OFLAGS), r16(o + OFSET)
            local x = s16(r16(o + OXPOS))
            if fl & B_FLIPH_MASK ~= 0 then
                mirrored = mirrored + 1
                if of ~= 0 then mclip = mclip + 1 end
                -- the LOGICAL x: cloud_mirror_on pulled a mirrored cloud left by
                -- its clips and recorded the pull in ozval (BGND.ASM); undo it so
                -- the two ROMs' positions are comparable
                x = x - s16(r16(o + 0x0c0))
            end
            if of ~= 0 then clip = clip + 1 end
            xs[#xs + 1] = tostring(x)
            o = r32(o)
        end
    end
    return n, mirrored, mclip, clip, table.concat(xs, ",")
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
        log("start")
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
    if fighting_frame == 0 then w16(A.curback, TOWER) end
    if frame > 9000 and fighting_frame == 0 then log("ERROR never reached the fight"); logfh:close(); manager.machine:exit(); return end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        for _, h in ipairs({ A.p1_obj, A.p2_obj }) do
            local o = r32(h)
            if o ~= 0 then
                w32(o + OXVAL, (((h == A.p1_obj) and 560 or 700) & 0xffff) << 16)
                w16(o + OFLAGS2, r16(o + OFLAGS2) | M_INVISO)
            end
        end
        if rel == ARM_FROM - 1 then
            local n, _, _, _, xs = clouds()
            log("PREARM wx=%d objfree=%d clouds=%d x=%s",
                A.worldtlx and s16(r16(A.worldtlx + 16)) or 0, count_list(A.ofree), n, xs)
        end
        for _, at in ipairs(SNAPS) do
            if rel == at then
                pcall(function() manager.machine.screens[":screen"]:snapshot() end)
                local n, m, mc, c = clouds()
                log("SNAP rel%d clouds=%d mirrored=%d mirrored_clipped=%d clipped=%d", at, n, m, mc, c)
            end
        end
        if rel == SNAPS[#SNAPS] + 5 then
            log("RESULT done")
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
