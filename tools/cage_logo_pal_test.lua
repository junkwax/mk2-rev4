-- cage_logo_pal_test.lua - the PALETTE way of hiding Cage's OTOMIX logo
-- (cagepal, MAINEQU.ASM; cp_frame / cp_obj / cp_fill, MKDISP.ASM;
-- src/JCPALEQ.ASM; doc/CAGE_OTOMIX_LOGO.md S3).
--
-- The lettering is baked into his pieces on palette slots of its own, and a
-- MIRRORED Cage is drawn through a TWIN of his colour map (his map + 80, out of
-- the 48 maps the allocator never hands out) with those slots re-pointed at what
-- the logo covers.  Checked on EVERY display pass, from a write tap on
-- `last_dmaq` - dsa9 writes it once a pass right after the last object is
-- queued, so inside the tap the queue is complete and no game process has run
-- since the objects were walked.
--
-- A queue cell is [ctrl, sag, dest, size, const:map, scale]: MMTM stores the
-- highest register lowest, and the walker pushes a6,a8,a9,a10,a11,a12.
--
--   MAP_BAD     a cell on a twin map that is not flipped, or whose source map
--               does not hold one of Cage's palettes, or with the switch off
--   MISSED      a flipped cell on one of Cage's maps drawn on the map ITSELF
--   COLOUR_BAD  a twin in use that is not its map with exactly the logo slots
--               re-pointed at what they hide as
--
-- Scenes: both fighters Cage in a two-player game, pinned; sides swapped so both
-- turn round; then a KO, because the round must still end and the next start.
-- CL_SHARE=1 (default) also puts P2 on P1's colour map with the reference counts
-- kept straight - the two then face opposite ways on ONE map, which is the case
-- a hide done in his own map gets wrong.  CL_ENABLE=0 is the control: no twin
-- may be used at all.
--
-- env: CL_ENABLE (1|0), CL_SHARE (1|0), CL_LOG, MK2_ROOT (src/mk2.map, JCPALEQ)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local ENABLE = tonumber(os.getenv("CL_ENABLE") or "1")
local SHARE = (os.getenv("CL_SHARE") or "1") == "1"
local LOG = os.getenv("CL_LOG") or (ROOT .. "/tools/cage_logo_pal_test.log")

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

-- the ROM's own contract, read from the file the bake generated
local equ = assert(io.open(ROOT .. "/src/JCPALEQ.ASM")):read("a")
local SLOTS = {}                -- layout name -> { {slot, hide}, ... }
for lay, body in equ:gmatch("cp_(%w+)%s*;[^\n]*\n(.-)\n\n") do
    local t = {}
    for slot, hide in body:gmatch("%.word%s+0(%x+)h,0(%x+)h") do
        t[#t + 1] = { tonumber(slot, 16), tonumber(hide, 16) }
    end
    if #t > 0 then SLOTS[lay] = t end
end
assert(SLOTS.cage and SLOTS.blud, "JCPALEQ.ASM: no slot records")
local PAL_LAY = {}              -- palette id -> slot list
for label, lay in equ:gmatch("%.long%s+([%w_]+),cp_(%w+)") do
    if symbols[label] then PAL_LAY[symbols[label]] = SLOTS[lay] end
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"), round_num = sym("round_num"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    palram = sym("palram"), dma_q = sym("dma_q"), last_dmaq = sym("last_dmaq"),
    f_cagepal = sym("f_cagepal"),
}
local OBJQ_1 = A.dma_q + 192 * 500
local OFLAGS, OPAL, OXVAL, OCHAR = 0x0f0, 0x140, 0x080, 0x1f0
local PALRSIZ, PALCNT = 0x40, 0x20
local COLRAM, TWIN, TWIN_MAPS, NCOLS = 0x01800000, 80, 48, 64
local FT_CAGE, GS_PSEL, GS_FIGHTING, MAXBAR = 2, 4, 2, 0xa1
local SCENE_A, SCENE_B, SCENE_C = 60, 760, 1460

local space, fields, frame = nil, {}, 0
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm, finished = 0, 0, false
local round1, round2_at, ko_at = nil, nil, nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function colour(m, i) return r16(COLRAM + ((m << 8) + i) * 16) end
local function slots_of(map) return PAL_LAY[r32(A.palram + map * PALRSIZ)] end

local S = { passes = 0, cells = 0, map_bad = 0, missed = 0, colour_bad = 0, twin_checked = 0,
    twin = { 0, 0 }, own = { 0, 0 }, shared = 0, share_made = false, turns = { 0, 0 },
    last_flip = {}, round2_passes = 0, first_bad = {} }
local function bad(kind, fmt, ...)
    S[kind] = S[kind] + 1
    if (S.first_bad[kind] or 0) < 5 then
        S.first_bad[kind] = (S.first_bad[kind] or 0) + 1
        log("%s pass=%d " .. fmt, kind:upper(), S.passes, ...)
    end
end

local function check_pass(words)
    if fighting_frame == 0 or frame - fighting_frame <= 31 then return end
    if r16(A.gstate) ~= GS_FIGHTING and not (ko_at and not round2_at) then return end
    S.passes = S.passes + 1
    if round2_at then S.round2_passes = S.round2_passes + 1 end
    local on = r16(A.f_cagepal) ~= 0
    local twins = {}
    for k = 1, words // 6 do
        local c = OBJQ_1 - k * 192
        local map = r32(c + 128) & 0xff
        local flip = (r32(c) >> 20) & 1 == 1
        S.cells = S.cells + 1
        if map >= TWIN then
            local sl = slots_of(map - TWIN)
            if not on or not flip or not sl then
                bad("map_bad", "cell=%d map=%d flip=%s on=%s cage=%s",
                    k, map, tostring(flip), tostring(on), tostring(sl ~= nil))
            end
            twins[map - TWIN] = sl
        elseif on and flip and map < TWIN_MAPS and slots_of(map) then
            bad("missed", "cell=%d map=%d flipped Cage drawn on his own map", k, map)
        end
    end
    -- a twin must be its map, with only the logo slots re-pointed
    for m, sl in pairs(twins) do
        if sl then
            S.twin_checked = S.twin_checked + 1
            local want = {}
            for _, pair in ipairs(sl) do want[pair[1]] = colour(m, pair[2]) end
            for i = 0, NCOLS - 1 do
                local expect = want[i] or colour(m, i)
                if colour(m + TWIN, i) ~= expect then
                    bad("colour_bad", "map=%d colour=%d twin=%04x want=%04x",
                        m, i, colour(m + TWIN, i), expect)
                    break
                end
            end
        end
    end
    local maps = {}
    for p = 1, 2 do
        local o = r32(p == 1 and A.p1_obj or A.p2_obj)
        if o ~= 0 then
            local flip = r16(o + OFLAGS) & 0x10 ~= 0
            if S.last_flip[p] ~= nil and S.last_flip[p] ~= flip then S.turns[p] = S.turns[p] + 1 end
            S.last_flip[p] = flip
            local own = r16(o + OPAL) & 0xff
            local want = (on and flip and own < TWIN_MAPS and slots_of(own)) and own + TWIN or own
            if want >= TWIN then S.twin[p] = S.twin[p] + 1 else S.own[p] = S.own[p] + 1 end
            maps[p] = { own = own, want = want }
        end
    end
    if maps[1] and maps[2] and maps[1].own == maps[2].own and maps[1].want ~= maps[2].want then
        S.shared = S.shared + 1
    end
end

local function finish(reason)
    if finished then return end
    finished = true
    log("RESULT enable=%d share=%s passes=%d cells=%d twin_checked=%d map_bad=%d missed=%d colour_bad=%d",
        ENABLE, tostring(SHARE), S.passes, S.cells, S.twin_checked, S.map_bad, S.missed, S.colour_bad)
    log("COVER p1_twin=%d p1_own=%d p2_twin=%d p2_own=%d shared_opposite=%d turns=%d,%d round2=%s round2_passes=%d",
        S.twin[1], S.own[1], S.twin[2], S.own[2], S.shared, S.turns[1], S.turns[2],
        tostring(round2_at ~= nil), S.round2_passes)
    local ok = S.passes >= 1000 and S.map_bad == 0 and S.missed == 0 and S.colour_bad == 0
        and round2_at ~= nil and S.round2_passes >= 200
        and S.turns[1] >= 1 and S.turns[2] >= 1
    if ENABLE ~= 0 then
        ok = ok and S.twin_checked >= 500 and S.twin[1] >= 200 and S.twin[2] >= 200
            and S.own[1] >= 200 and S.own[2] >= 200
            and (not SHARE or (S.share_made and S.shared >= 200))
    else
        ok = ok and S.twin_checked == 0 and S.twin[1] == 0 and S.twin[2] == 0
    end
    log("%s reason=%s", ok and "PASS" or "FAIL", reason)
    logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if f.name:match("^P[12] ") or f.name == "Coin 1" or f.name == "UI Select"
                or f.name == "1 Player Start" or f.name == "2 Players Start" then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        if rel >= SCENE_C then return false end
        local hitter = rel < SCENE_B and "P1" or "P2"
        if name == hitter .. " High Punch" then return rel >= SCENE_A + 20 and (rel % 40) < 4 end
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

-- P2 onto P1's colour map, both maps' reference counts kept exact, so the
-- allocator stays honest when either of them swaps palette later
local function make_shared()
    local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
    local m1, m2 = r16(o1 + OPAL) & 0xff, r16(o2 + OPAL) & 0xff
    if m1 == m2 then S.share_made = true; return end
    local c1 = A.palram + m1 * PALRSIZ + PALCNT
    local c2 = A.palram + m2 * PALRSIZ + PALCNT
    w16(c1, r16(c1) + 1)
    w16(c2, r16(c2) - 1)
    w16(o2 + OPAL, r16(o1 + OPAL))
    S.share_made = true
    log("SHARE p2 moved from map %d onto P1's map %d", m2, m1)
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        S.tap = space:install_write_tap(A.last_dmaq, A.last_dmaq + 15, "cp_pass",
            function(offset, data, mask)
                if not finished then check_pass(data & 0xffff) end
                return data
            end)
        local n = 0
        for _ in pairs(PAL_LAY) do n = n + 1 end
        log("loaded enable=%d share=%s: %d Cage palettes, %d/%d slots",
            ENABLE, tostring(SHARE), n, #SLOTS.cage, #SLOTS.blud)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_CAGE); w16(A.p2_char, FT_CAGE)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, 0) end
    if frame > 9000 and fighting_frame == 0 then log("never reached the fight"); finish("no_fight"); return end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        local o1, o2 = r32(A.p1_obj), r32(A.p2_obj)
        if rel == 30 then
            assert(o1 ~= 0 and o2 ~= 0, "fighters missing")
            assert(r16(o1 + OCHAR) == FT_CAGE and r16(o2 + OCHAR) == FT_CAGE, "both must be Cage")
            w16(A.f_cagepal, ENABLE)
            round1 = r16(A.round_num)
            log("round %d, f_cagepal=%d, maps p1=%d p2=%d", round1, ENABLE,
                r16(o1 + OPAL) & 0xff, r16(o2 + OPAL) & 0xff)
        end
        if rel == 40 and SHARE then make_shared() end
        if rel >= SCENE_A and rel < SCENE_C and o1 ~= 0 and o2 ~= 0 then
            local left, right = 500, 560
            if rel < SCENE_B then
                w32(o1 + OXVAL, left << 16); w32(o2 + OXVAL, right << 16)
            else
                w32(o1 + OXVAL, right << 16); w32(o2 + OXVAL, left << 16)
            end
            w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
        end
        if rel == SCENE_A + 200 or rel == SCENE_B + 200 then
            pcall(function() manager.machine.screens[":screen"]:snapshot() end)
            log("SNAP rel=%d", rel)
        end
        if rel == SCENE_C then
            ko_at = frame
            w16(A.p2_bar, 0)
            log("SCENE_C round %d: P2's bar to 0", r16(A.round_num))
        end
        if rel > SCENE_C and not round2_at and round1 and r16(A.round_num) > round1
            and gs == GS_FIGHTING and o1 ~= 0 and o2 ~= 0 then
            round2_at = frame
            log("ROUND %d started at rel=%d", r16(A.round_num), rel)
        end
        if round2_at and frame - round2_at == 400 then finish("round_advanced"); return end
        if rel > SCENE_C + 3000 and not round2_at then finish("round_never_advanced"); return end
    end
    for name, f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end
end)
