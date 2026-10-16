-- mileena_victory_ab.lua - Mileena's victory pose, for an A/B between the
-- stock ROM (KT2VARMLEFT1A-8A packed as art) and the one that draws them as
-- mirrored aliases of KT2VARMRIGHT1A-8A (ani2's flip XOR, MKUTIL.ASM).
--
-- A two-player game, Mileena on MV_SIDE (1 = P1, faces right; 2 = P2, faces
-- LEFT - the run that exercises the XOR, since her own flip then combines with
-- the aliases').  At fight rel 300 the other player's bar is emptied, the
-- round ends, and she takes her victory pose.  Snapshots every 3 frames until
-- the pose has played; each logs whether her body piece is KT2VICTORY1A, i.e.
-- whether the frame shows the eight arm rows the aliases replaced.
--
-- env: MV_SIDE, MV_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local SIDE = tonumber(os.getenv("MV_SIDE") or "1") == 2 and 2 or 1
local LOG = os.getenv("MV_LOG") or (ROOT .. "/tools/mileena_victory_ab.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[mv] " .. string.format(fmt, ...)
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
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = symbols["p1_bar_view"], p2_bar_view = symbols["p2_bar_view"],
    ofree = symbols["ofree"], f_freeze_timer = symbols["f_freeze_timer"],
}
-- The eight right-arm SAGs (the runner reads them out of MKFN.TBL; the right
-- arms sit BEFORE the removed left arms in MK3MIL, so they are the same in both
-- ROMs).  KT2VICTORY1A itself is not in the map - MKFN.ASM never includes the
-- .GLO that would export it - which left the first run blind to the arm frames.
local ARM = {}
for h in (os.getenv("MV_ARMSAGS") or ""):gmatch("%x+") do ARM[tonumber(h, 16)] = true end
local FT_FN2, FT_CAGE, MAX_HP = 5, 2, 0xa1
local OIMG, OXPOS = 0x1a0, 0x090
local GS_PSEL, GS_FIGHTING = 4, 2
local WASTELAND = 2
local WIN_AT, SNAP_FROM, SNAP_UNTIL, SNAP_EVERY = 300, 300, 1100, 3

local ME_CHAR, FOE_CHAR = (SIDE == 2) and A.p2_char or A.p1_char, (SIDE == 2) and A.p1_char or A.p2_char
local ME_OBJ = (SIDE == 2) and A.p2_obj or A.p1_obj
local ME_BAR, FOE_BAR = (SIDE == 2) and A.p2_bar or A.p1_bar, (SIDE == 2) and A.p1_bar or A.p2_bar
local FOE_VIEW = (SIDE == 2) and A.p1_bar_view or A.p2_bar_view

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
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
        local n = 0
        for _ in pairs(ARM) do n = n + 1 end
        log("side=%d arm_sags=%d", SIDE, n)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("GSTATE frame=%d %d -> %d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(ME_CHAR, FT_FN2); w16(FOE_CHAR, FT_CAGE)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, WASTELAND) end
    if frame > 9000 and fighting_frame == 0 then log("ERROR never reached the fight"); logfh:close(); manager.machine:exit(); return end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        w16(ME_BAR, MAX_HP)
        if rel < WIN_AT then w16(FOE_BAR, MAX_HP) end
        if rel == WIN_AT - 1 then
            local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
            log("PREARM p1x=%d p2x=%d objfree=%d",
                o1 ~= 0 and s16(r16(o1 + OXPOS)) or -9999, o2 ~= 0 and s16(r16(o2 + OXPOS)) or -9999, count_list(A.ofree))
        end
        if rel == WIN_AT then
            w16(FOE_BAR, 0)
            if FOE_VIEW then w16(FOE_VIEW, 0) end
            log("FORCE_WIN frame=%d", frame)
        end
        if rel >= SNAP_FROM and rel <= SNAP_UNTIL and (rel - SNAP_FROM) % SNAP_EVERY == 0 then
            pcall(function() manager.machine.screens[":screen"]:snapshot() end)
            local o = r32(ME_OBJ)
            local arm = 0
            if o ~= 0 then
                local ram = r32(o + OIMG)
                -- piece 2 of a KT2VIC1n frame is the right arm (112-bit records)
                if ram ~= 0 and r32(ram) ~= 0 and ARM[r32(ram + 112)] then arm = 1 end
            end
            log("SNAP rel%d arm=%d gs=%d", rel, arm, gs)
        end
        if rel == SNAP_UNTIL + 2 then
            log("RESULT done")
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
