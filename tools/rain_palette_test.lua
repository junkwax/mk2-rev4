-- Runtime proof that RAIN wears the palettes authored in data/NINJAS10.IMG.
--
-- Forces a RAIN vs RAIN mirror match (both p1_char and p2_char = ft_rain 19),
-- then reads the COLOUR RAM each fighter's object is actually pointing at and
-- compares it, word for word, with RNUMK3_P and RNUMK2_P as the IMG holds them.
--
-- The expected words are NOT embedded here: tools/run_rain_palette_test.ps1
-- regenerates tools/rain_palette_expect.lua straight out of NINJAS10.IMG
-- before every run, so what this rig proves is "the screen matches the art",
-- not "the screen matches a number somebody typed into a rig".
--
-- A mirror match is the point.  player_normpal sends one man down
-- player_nice_pal (character_palettes_1 -> RNUMK3_P) and the other down
-- player_ugly_pal (character_palettes_2 -> RNUMK2_P), so a mirror is the only
-- fight that exercises both entries at once - and the only one where getting
-- them the wrong way round is visible.
--
-- PASS = P1's colour map holds RNUMK3_P, P2's holds RNUMK2_P, and they differ
-- from each other on every index the two palettes disagree on.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local logfh = assert(io.open(os.getenv("RPT_LOG") or (ROOT .. "/tools/rain_palette_test.log"), "w"))
local function log(fmt, ...)
    local s = "[rain-pal] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

-- expected palettes, generated from the IMG by the wrapper
local EXP = dofile(ROOT .. "/tools/rain_palette_expect.lua")
local P1_WANT, P2_WANT = EXP.RNUMK3_P, EXP.RNUMK2_P

-- RPT_SWAP=1 is the NEGATIVE CONTROL: it asks for the two costumes the wrong
-- way round, which a working rig must report as SWAPPED.  A rig that passes
-- this too is not reading the screen at all.
if os.getenv("RPT_SWAP") == "1" then
    P1_WANT, P2_WANT = P2_WANT, P1_WANT
    log("NEGATIVE CONTROL: expectations deliberately crossed - a PASS here is a broken rig")
end

-- the indices on which the two costumes disagree: the discriminator.  If the
-- mirror slot is ever wired back to a shared palette this list is what fails.
local DIFF = {}
for i = 1, #P1_WANT do
    if P1_WANT[i] ~= P2_WANT[i] then DIFF[#DIFF + 1] = i - 1 end
end

local syms = {}
local mf = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
if mf then
    for line in mf:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n] = tonumber(a, 16) end
    end
    mf:close()
end
local function sym(n, d)
    if not syms[n] then log("WARN symbol %s not in map, using default", n) end
    return syms[n] or d
end

local A = {
    gstate  = sym("gstate",  0x0112a7d0),
    p1_char = sym("p1_char", 0x0112a880),
    p2_char = sym("p2_char", 0x0112b450),
    p1_obj  = sym("p1_obj",  0x0112a820),
    p2_obj  = sym("p2_obj",  0x011047c0),
}

local GS_PSEL, GS_POST, GS_FIGHT = 4, 0x0d, 2
local FT_RAIN = 19
local OPAL, OFLAGS2 = 0x140, 0x160
local COLRAM, PALSIZE = 0x01800000, 0x1000
local M_UGLY = 0x0040            -- m_ugly_pal (DISPEQU.ASM), oflags2: "I took the alternate"

local SETTLE = tonumber(os.getenv("RPT_SETTLE") or "150")  -- frames into the fight

local frame, space, psel, fight = 0, nil, 0, 0
local fields, finished = {}, false

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function cram(map, idx) return r16(COLRAM + map * PALSIZE + idx * 16) end

local function finish(ok, why)
    if finished then return end
    finished = true
    log("%s reason=%s", ok and "PASS" or "FAIL", why)
    logfh:close(); manager.machine:exit()
end

local function cache()
    local wanted = { ["UI Select"] = 1, ["Coin 1"] = 1, ["Coin 2"] = 1,
                     ["2 Players Start"] = 1, ["2 Player Start"] = 1,
                     ["P1 High Punch"] = 1, ["P2 High Punch"] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
end

local function pressed(n)
    if n == "UI Select" then return frame >= 5 and frame < 35 end
    if n == "Coin 1" or n == "Coin 2" then
        return frame >= 700 and frame < 980 and frame % 80 < 20
    end
    if n == "2 Players Start" or n == "2 Player Start" then
        return frame >= 1000 and frame < 1080
    end
    -- lock both picks in once the select screen has settled
    if n == "P1 High Punch" or n == "P2 High Punch" then
        return psel > 0 and frame >= psel + 90 and frame < psel + 135
    end
    return false
end

-- read a fighter's live 64 colours off whatever map his object is wearing
local function costume(objptr)
    local obj = r32(objptr)
    if obj == 0 then return nil end
    local opal = r16(obj + OPAL)
    local map  = (opal >> 8) & 0xff
    local got = {}
    for i = 1, 64 do got[i] = cram(map, i - 1) end
    return { obj = obj, map = map, opal = opal,
             ugly = (r32(obj + OFLAGS2) & M_UGLY) ~= 0, words = got }
end

-- index 0 is the transparent entry and is not always transferred, so it is
-- reported but never decides the verdict
local function compare(got, want)
    local bad, first = 0, nil
    for i = 2, 64 do
        if got[i] ~= want[i] then
            bad = bad + 1
            if not first then
                first = string.format("idx %d: %04X want %04X", i - 1, got[i], want[i])
            end
        end
    end
    return bad, first
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache()
        log("discriminating indices (RNUMK3_P vs RNUMK2_P): %d", #DIFF)
        log("gstate=%08x p1_char=%08x p2_char=%08x p1_obj=%08x p2_obj=%08x",
            A.gstate, A.p1_char, A.p2_char, A.p1_obj, A.p2_obj)
    end
    if space and not finished then
        local gs = r16(A.gstate)
        if gs == GS_PSEL then
            if psel == 0 then psel = frame; log("select screen at frame %d", frame) end
            w16(A.p1_char, FT_RAIN); w16(A.p2_char, FT_RAIN)
        elseif gs == GS_POST then
            w16(A.p1_char, FT_RAIN); w16(A.p2_char, FT_RAIN)
        elseif gs == GS_FIGHT then
            if fight == 0 then fight = frame; log("fight started at frame %d", frame) end
            if frame - fight == SETTLE then
                for _, scr in pairs(manager.machine.screens) do
                    pcall(function() scr:snapshot() end)
                end
                local a, b = costume(A.p1_obj), costume(A.p2_obj)
                if not a or not b then finish(false, "a fighter object was null"); return end
                log("P1 obj=%08x map=%d opal=%04x ugly=%s", a.obj, a.map, a.opal, tostring(a.ugly))
                log("P2 obj=%08x map=%d opal=%04x ugly=%s", b.obj, b.map, b.opal, tostring(b.ugly))
                if a.map == b.map then
                    finish(false, string.format("both fighters share colour map %d - not a mirror", a.map))
                    return
                end
                local ab, af = compare(a.words, P1_WANT)
                local bb, bf = compare(b.words, P2_WANT)
                log("P1 vs RNUMK1_P: %d/63 mismatched%s", ab, af and ("  first " .. af) or "")
                log("P2 vs RNUMK2_P: %d/63 mismatched%s", bb, bf and ("  first " .. bf) or "")
                -- crossed? say so outright rather than just failing
                local xa = compare(a.words, P2_WANT)
                local xb = compare(b.words, P1_WANT)
                if ab > 0 and bb > 0 and xa == 0 and xb == 0 then
                    finish(false, "palettes are SWAPPED: P1 is wearing RNUMK2_P and P2 RNUMK3_P")
                    return
                end
                if ab > 0 or bb > 0 then
                    finish(false, string.format("P1 off by %d, P2 off by %d", ab, bb)); return
                end
                local same = 0
                for _, i in ipairs(DIFF) do
                    if a.words[i + 1] == b.words[i + 1] then same = same + 1 end
                end
                log("discriminating indices agreeing between the two men: %d/%d", same, #DIFF)
                if same > 0 then
                    finish(false, "the two costumes are not distinct on screen"); return
                end
                -- the ugly flag is what player_normpal RECORDS about the choice;
                -- the colour words above are what it ACTUALLY did.  They should
                -- agree, and a disagreement means the flag lies to everything
                -- downstream that asks "is he on his default" - the mirror test
                -- in player_nice_pal included.
                if a.ugly or not b.ugly then
                    finish(false, string.format(
                        "colours are right but m_ugly_pal disagrees: P1 ugly=%s P2 ugly=%s",
                        tostring(a.ugly), tostring(b.ugly)))
                    return
                end
                finish(true, string.format(
                    "P1=RNUMK3_P (map %d) P2=RNUMK2_P (map %d), distinct on all %d indices",
                    a.map, b.map, #DIFF))
                return
            end
            if frame - fight > SETTLE + 600 then finish(false, "fight never settled"); return end
        end
        if frame % 300 == 0 then
            log("frame=%d gstate=%d psel=%d fight=%d p1c=%d p2c=%d",
                frame, gs, psel, fight, r16(A.p1_char), r16(A.p2_char))
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame > 5000 then finish(false, "timeout - never reached a fight") end
end)
