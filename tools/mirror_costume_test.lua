-- Mirror-match costume rig: the automatic alternate player 2 is handed in a
-- mirror match is the START+HP lane (character_palettes_4), not Start+LP.
--
-- Forces a 2-player mirror of fighter MC_CHAR, then identifies the palette
-- each fighter is drawing BY NAME: palram[map] holds the palette's ROM address
-- (PALL.ASM), and the expectation is read out of the ROM's own lane tables -
-- character_palettes_1/2/4[ochar] - so nothing here is a typed number.
--
-- Then it knocks player 2 down three times (P1 pinned in front of him,
-- Down+HP), because every knockdown re-runs player_normpal, and that is where
-- the mirror lane is re-derived rather than read off the object.  The check is
-- repeated after he gets up.
--
-- PASS = P1 on _1, P2 on _4 at both checks, P2's oflags2 carries the Start+HP
-- lane bits (m_start_alt_pal|m_repalt2_pal) and not m_ugly_pal, and at least
-- one knockdown landed.  A fighter whose _4 equals his _1 or _2 cannot
-- discriminate and is NO VERDICT.  MC_NEG=1 expects _2 for player 2 (the old
-- behaviour) and must FAIL.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local CHAR = tonumber(os.getenv("MC_CHAR") or "1")
local NEG  = os.getenv("MC_NEG") == "1"
local logfh = assert(io.open(os.getenv("MC_LOG") or (ROOT .. "/tmp/mirror_costume.log"), "w"))
local function log(fmt, ...)
    local s = "[mirror] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local syms, names = {}, {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        local v = tonumber(a, 16); syms[n] = v
        if not names[v] or #n < #names[v] then names[v] = n end
    end
end
local function sym(n) return assert(syms[n], "symbol " .. n .. " not in map") end
local function name(v) return names[v] or string.format("%08X", v) end

local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"), palram = sym("fpalram"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    cp1 = sym("character_palettes_1"), cp2 = sym("character_palettes_2"),
    cp4 = sym("character_palettes_4"),
}
local GS_PSEL, GS_POST, GS_FIGHT = 4, 0x0d, 2
local OXVAL, OPAL, OFLAGS2 = 0x80, 0x140, 0x160
local M_UGLY, M_START, M_REP2 = 0x40, 0x80, 0x100

local frame, space, psel, fight, finished = 0, nil, 0, 0, false
local fields, knocks, lastbar, checked1 = {}, 0, nil, false
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function finish(verdict, why)
    if finished then return end
    finished = true
    log("%s reason=%s", verdict, why)
    logfh:close(); manager.machine:exit()
end

local function wearing(objsym)
    local obj = r32(objsym)
    if obj == 0 then return nil end
    local map = (r16(obj + OPAL) >> 8) & 0xff
    local row = A.palram + map * 0x40
    return { obj = obj, map = map, id = r32(row), cnt = r16(row + 0x20),
             fl = r32(obj + OFLAGS2) & 0xffff }
end

local want1, want2, alt2
local function check(tag)
    local a, b = wearing(A.p1_obj), wearing(A.p2_obj)
    if not a or not b then return "a fighter object is null" end
    log("%s P1 map=%d %s cnt=%d fl=%04x | P2 map=%d %s cnt=%d fl=%04x", tag,
        a.map, name(a.id), a.cnt, a.fl, b.map, name(b.id), b.cnt, b.fl)
    if a.cnt == 0 or b.cnt == 0 then return "a palram row is not live" end
    if a.id ~= want1 then return string.format("P1 wears %s, want %s", name(a.id), name(want1)) end
    if b.id ~= want2 then return string.format("P2 wears %s, want %s", name(b.id), name(want2)) end
    if not NEG then
        if (b.fl & (M_START | M_REP2)) ~= (M_START | M_REP2) then return "P2 lacks the Start+HP lane bits" end
        if (b.fl & M_UGLY) ~= 0 then return "P2 still carries m_ugly_pal" end
        if (a.fl & (M_UGLY | M_START | M_REP2)) ~= 0 then return "P1 carries an alternate bit" end
    end
    return nil
end

local function cache()
    local wanted = { ["UI Select"] = 1, ["Coin 1"] = 1, ["2 Players Start"] = 1,
                     ["2 Player Start"] = 1, ["P1 High Punch"] = 1, ["P2 High Punch"] = 1,
                     ["P1 Down"] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
end

local KO_START = 150      -- fight frames before the first uppercut
local function pressed(n)
    if n == "UI Select" then return frame >= 5 and frame < 35 end
    if n == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if n == "2 Players Start" or n == "2 Player Start" then return frame >= 1000 and frame < 1080 end
    if n == "P1 High Punch" and fight == 0 or n == "P2 High Punch" then
        return psel > 0 and fight == 0 and frame >= psel + 90 and frame < psel + 135
    end
    if fight > 0 then
        local t = frame - fight - KO_START
        if t >= 0 and t < 3 * 160 then
            local p = t % 160
            if n == "P1 Down" then return p < 24 end
            if n == "P1 High Punch" then return p >= 10 and p < 14 end
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache()
        want1 = r32(A.cp1 + CHAR * 32)
        alt2  = r32(A.cp2 + CHAR * 32)
        local hp = r32(A.cp4 + CHAR * 32)
        want2 = NEG and alt2 or hp
        log("char=%d default=%s startLP=%s startHP=%s expecting P2=%s%s", CHAR,
            name(want1), name(alt2), name(hp), name(want2), NEG and "  (NEGATIVE CONTROL)" or "")
        if hp == want1 or hp == alt2 then
            finish("NO VERDICT", "this fighter's Start+HP equals his default or Start+LP - cannot discriminate")
            return
        end
    end
    if not space or finished then return end
    local gs = r16(A.gstate)
    if gs == GS_PSEL or gs == GS_POST then
        if gs == GS_PSEL and psel == 0 then psel = frame; log("select at frame %d", frame) end
        w16(A.p1_char, CHAR); w16(A.p2_char, CHAR)
    elseif gs == GS_FIGHT then
        if fight == 0 then fight = frame; log("fight at frame %d", frame) end
        local t = frame - fight
        w16(A.p1_bar, 0xa1)                         -- P1 never loses
        if t == 100 and not checked1 then
            checked1 = true
            local e = check("start")
            if e then finish("FAIL", "at fight start: " .. e); return end
        end
        -- park P1 just in front of P2 while the uppercuts go in
        if t >= KO_START - 20 and t < KO_START + 3 * 160 then
            local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
            if p1 ~= 0 and p2 ~= 0 then w32(p1 + OXVAL, r32(p2 + OXVAL) - 0x3c0000) end
        end
        local bar = r16(A.p2_bar)
        if lastbar and bar < lastbar then knocks = knocks + 1; log("P2 hit at t=%d bar %d -> %d", t, lastbar, bar) end
        lastbar = bar
        if t == KO_START + 3 * 160 + 250 then
            if knocks == 0 then finish("NO VERDICT", "no uppercut landed - player_normpal was never re-run"); return end
            local e = check("after")
            if e then finish("FAIL", "after knockdowns: " .. e); return end
            finish("PASS", string.format("P1=%s P2=%s at fight start and after %d hits",
                name(want1), name(want2), knocks))
            return
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame > 6000 then finish("NO VERDICT", "timeout - never reached the verdict") end
end)
