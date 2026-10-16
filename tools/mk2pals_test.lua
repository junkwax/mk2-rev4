-- Runtime proof that START + HIGH PUNCH at the character select screen puts
-- retail's MIRROR-MATCH costume on the fighter: character_palettes_4 rows
-- 0-11, the twelve palettes tools/make_mk2pals.py lifted out of mk2-readonly
-- into data/MK2PALS.IMG and src/MK2PALS.ASM.
--
-- IT DRIVES THE GESTURE, NOT THE TABLE.  Poking @alt_pal_owner would prove
-- the table is wired and nothing about whether a player can reach it; this
-- holds 1P Start with P1 High Punch on the select screen, which is what
-- psr_p1_masks (MKSEL.ASM) claims the lane on, and then reads the COLOUR RAM
-- the fighter's object is pointing at once the fight is running.
--
-- Start+HP is BOTH the claim and the confirm - the same press that takes the
-- alternate also locks the pick in - so the two are one window here.
--
-- The expected words come from tools/mk2pals_expect.lua, regenerated out of
-- data/MK2PALS.IMG by the wrapper before every run, so a pass means "the
-- screen matches the art", not "the screen matches a number in a rig".
--
-- MP_NEGATIVE=1 expects the palette slot 4 held BEFORE this change instead.
-- It must FAIL; a pass means the rig is not reading the colour RAM.
--
-- PASS = P1 wears the expected 63 colours (index 0 is the transparent entry
--        and is not always transferred), b_repalt2_pal is set in his oflags2,
--        and the costume is NOT the one slot 4 used to hold.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local logfh = assert(io.open(os.getenv("MP_LOG") or (ROOT .. "/tools/mk2pals_test.log"), "w"))
local function log(fmt, ...)
    local s = "[mk2pals] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local OCHAR    = tonumber(os.getenv("MP_OCHAR") or "0")
local SETTLE   = tonumber(os.getenv("MP_SETTLE") or "120")
local NEGATIVE = os.getenv("MP_NEGATIVE") == "1"

local EXP = dofile(ROOT .. "/tools/mk2pals_expect.lua")[OCHAR]
if not EXP then log("FAIL reason=no expectation for ochar %d", OCHAR); logfh:close(); return end

local WANT, OTHER = EXP.want, EXP.prev
local WANT_NAME, OTHER_NAME = EXP.name, EXP.prev_name
if NEGATIVE then
    WANT, OTHER = EXP.prev, EXP.want
    WANT_NAME, OTHER_NAME = EXP.prev_name, EXP.name
    log("NEGATIVE CONTROL: expecting %s, the palette slot 4 held BEFORE the "
        .. "change - a PASS here would mean the rig is not reading the screen",
        WANT_NAME)
end

-- P2 is somebody else, so nothing here can be a mirror match: a mirror sends
-- P2 down player_ugly_pal and character_palettes_2, which is a different
-- lane and would muddy what this is measuring.  Jax unless P1 IS Jax.
local P2CHAR = (OCHAR == 11) and 1 or 11

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
    gstate        = sym("gstate",        0x0112a7d0),
    p1_char       = sym("p1_char",       0x0112a880),
    p2_char       = sym("p2_char",       0x0112b450),
    p1_obj        = sym("p1_obj",        0x0112a820),
    alt_pal_owner = sym("alt_pal_owner", 0x0112a8a0),
}

local GS_PSEL, GS_POST, GS_FIGHT = 4, 0x0d, 2
local OPAL, OFLAGS2 = 0x140, 0x160
local COLRAM, PALSIZE = 0x01800000, 0x1000
local M_REPALT2 = 0x0100        -- m_repalt2_pal (DISPEQU.ASM) - "I am on Start+HP"
local M_STARTALT = 0x0080       -- m_start_alt_pal

local frame, space, psel, fight = 0, nil, 0, 0
local fields, finished, owner_seen = {}, false, 0

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
                     ["1 Player Start"] = 1, ["1 Players Start"] = 1,
                     ["P1 High Punch"] = 1, ["P2 High Punch"] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
    local have = {}
    for n in pairs(fields) do have[#have + 1] = n end
    table.sort(have)
    log("input fields: %s", table.concat(have, ", "))
end

-- The select-screen script.  Everything is relative to `psel`, the frame the
-- select screen came up, because the boot and attract lengths are not fixed.
local function pressed(n)
    if n == "UI Select" then return frame >= 5 and frame < 35 end
    if n == "Coin 1" or n == "Coin 2" then
        return frame >= 700 and frame < 980 and frame % 80 < 20
    end
    if n == "2 Players Start" or n == "2 Player Start" then
        return psel == 0 and frame >= 1000 and frame < 1080
    end
    if psel == 0 then return false end
    -- P1: 1P Start HELD across the High Punch.  The start button has to be
    -- down BEFORE the button and stay down through it, or the press reads as
    -- a plain confirm on the default costume.
    if n == "1 Player Start" or n == "1 Players Start" then
        return frame >= psel + 80 and frame < psel + 150
    end
    if n == "P1 High Punch" then
        return frame >= psel + 100 and frame < psel + 135
    end
    -- P2 confirms on his own, no start, so he stays on his default
    if n == "P2 High Punch" then
        return frame >= psel + 170 and frame < psel + 205
    end
    return false
end

local function costume()
    local obj = r32(A.p1_obj)
    if obj == 0 then return nil end
    local opal = r16(obj + OPAL)
    local map = (opal >> 8) & 0xff
    local got = {}
    for i = 1, #WANT do got[i] = cram(map, i - 1) end
    return { obj = obj, map = map, opal = opal, flags = r32(obj + OFLAGS2), words = got }
end

-- index 0 is the transparent entry and is not always transferred, so it is
-- reported but never decides the verdict
local function compare(got, want)
    local bad, first = 0, nil
    for i = 2, #want do
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
        log("ochar %d (%s): expecting %s, %d words", OCHAR, EXP.who, WANT_NAME, #WANT)
        local d = 0
        for i = 2, math.min(#WANT, #OTHER) do if WANT[i] ~= OTHER[i] then d = d + 1 end end
        log("discriminating indices vs %s: %d - that is what makes a pass mean something",
            OTHER_NAME, d)
        if d == 0 then
            finish(false, string.format(
                "%s and %s are the same palette - this trial cannot discriminate",
                WANT_NAME, OTHER_NAME))
            return
        end
    end
    if space and not finished then
        local gs = r16(A.gstate)
        if gs == GS_PSEL then
            if psel == 0 then psel = frame; log("select screen at frame %d", frame) end
            w16(A.p1_char, OCHAR); w16(A.p2_char, P2CHAR)
            local o = r16(A.alt_pal_owner)
            if o ~= 0 and o ~= owner_seen then
                owner_seen = o
                log("alt_pal_owner = %04X at frame %d (+%d)", o, frame, frame - psel)
            end
        elseif gs == GS_POST then
            w16(A.p1_char, OCHAR); w16(A.p2_char, P2CHAR)
        elseif gs == GS_FIGHT then
            if fight == 0 then
                fight = frame
                log("fight started at frame %d, alt_pal_owner=%04X",
                    frame, r16(A.alt_pal_owner))
            end
            if frame - fight == SETTLE then
                for _, scr in pairs(manager.machine.screens) do
                    pcall(function() scr:snapshot() end)
                end
                local c = costume()
                if not c then finish(false, "p1_obj was null"); return end
                log("P1 obj=%08X map=%d opal=%04X oflags2=%08X",
                    c.obj, c.map, c.opal, c.flags)
                -- The lane FIRST: a colour mismatch when the lane was never
                -- claimed is a rig problem (the gesture missed), not a wiring
                -- problem, and the two look identical in a bare diff.
                if (c.flags & M_REPALT2) == 0 then
                    finish(false, string.format(
                        "the Start+HP lane was never claimed - oflags2=%08X has no "
                        .. "b_repalt2_pal (alt_pal_owner=%04X). The gesture missed; "
                        .. "the palette wiring is not what this proved.",
                        c.flags, r16(A.alt_pal_owner)))
                    return
                end
                if (c.flags & M_STARTALT) == 0 then
                    finish(false, "b_repalt2_pal is set but m_start_alt_pal is not")
                    return
                end
                local bad, first = compare(c.words, WANT)
                log("vs %s: %d/%d mismatched%s", WANT_NAME, bad, #WANT - 1,
                    first and ("  first " .. first) or "")
                local ob = compare(c.words, OTHER)
                log("vs %s (the other one): %d/%d mismatched", OTHER_NAME, ob, #OTHER - 1)
                if bad > 0 and ob == 0 then
                    finish(false, string.format(
                        "he is wearing %s, not %s - slot 4 is on the old palette",
                        OTHER_NAME, WANT_NAME))
                    return
                end
                if bad > 0 then
                    finish(false, string.format("%s off by %d of %d",
                        WANT_NAME, bad, #WANT - 1)); return
                end
                finish(true, string.format("%s wears %s on colour map %d, %d/%d exact",
                    EXP.who, WANT_NAME, c.map, #WANT - 1, #WANT - 1))
                return
            end
            if frame - fight > SETTLE + 600 then finish(false, "fight never settled"); return end
        end
        if frame % 300 == 0 then
            log("frame=%d gstate=%d psel=%d fight=%d p1c=%d p2c=%d owner=%04X",
                frame, gs, psel, fight, r16(A.p1_char), r16(A.p2_char),
                r16(A.alt_pal_owner))
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame > 6000 then finish(false, "timeout - never reached a fight") end
end)
