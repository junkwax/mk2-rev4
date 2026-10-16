-- RAIDEN'S ELECTRICITY WEARS THE PALETTE HIS COSTUME PAIRS WITH, and every
-- electrocution runs the four-beat cycle.  Three modes, one rig.
--
--   RE_MODE=costume  he teleports (Down, Up + LK) and the DECOY he melts out of
--                    must be drawn in the ELEC palette paired with the costume
--                    he is actually wearing - and in neither of the other two.
--
--   RE_MODE=cycle    he zaps the other man (Back + HP) and the man it hits must
--                    run FREZ, ELEC, WHITE, BLACK - four distinct palettes, two
--                    of them the solid flashes - AND his ELEC beat must be the
--                    one his own body pairs with Raiden's costume in: JXELEC_P
--                    blue, JXELRED_P red, JXELPUR_P purple.  At shockcyc 0 this
--                    must FAIL with two states and no flashes: the control.
--
--   RE_MODE=victory  he WINS THE MATCH, and his victory charge-up must run the
--                    same four beats IN HIS OWN BODY'S COPY of that colour
--                    (RDELEC_P / RDELRED_P / RDELPUR_P, by name - solid white and
--                    black alone would also be true of the victory FADE) - AND he
--                    must be back in his costume when it stops.  Twelve beats of a four-beat cycle end on BLACK,
--                    so a victory loop that forgets to dress him again holds him
--                    as a solid black silhouette for the rest of the match, and
--                    nothing else in the tree would catch it.
--
-- IT IDENTIFIES THE COSTUME BEFORE IT JUDGES ANYTHING.  The lane is claimed by
-- writing @alt_pal_owner - the lanes' own reachability is proven by
-- tools/run_mk2pals_test.ps1 and tools/run_costume_test.ps1, and this rig is
-- about the PAIRING - and a claim that did not land would leave him on his
-- default, whose partner is ELEC_P.  A rig that only watched the bolt would then
-- report a green run for four lanes it never reached.  So a disagreement here is
-- NO VERDICT: not a pass, and not a failure of the ROM.
--
-- Palette identity comes from `palram`, the allocator's own table: an object's
-- opal names a colour MAP, and palram[map] holds the ROM ADDRESS of the palette
-- loaded into it.  The rig therefore reads the palette the DMA is drawing with
-- BY NAME rather than matching colour words and hoping.  Rows are believed only
-- while palcnt is non-zero: freepal leaves the id behind, so a stale row would
-- read as an electric palette that is no longer on screen.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local logfh = assert(io.open(os.getenv("RE_LOG") or (ROOT .. "/tools/raiden_elec_test.log"), "w"))
local function log(fmt, ...)
    local s = "[rd-elec] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local EXP  = dofile(ROOT .. "/tools/raiden_elec_expect.lua")
local MODE = os.getenv("RE_MODE") or "costume"
local LANE = tonumber(os.getenv("RE_LANE") or "0")
local lane = EXP.lanes[LANE + 1] or EXP.lanes[1]

-- RE_CROSS=1 IS THE NEGATIVE CONTROL.  It keeps the lane and the costume - so
-- the run still reaches a real fight in a real costume - and asks for ANOTHER
-- lane's electric answer.  A working rig must report FAIL; a rig that passes
-- this is not reading the palettes at all and every green run meant nothing.
-- It is not a rebuild: the ROM is untouched, only the expectation.
if os.getenv("RE_CROSS") == "1" then
    local other
    for _, l in ipairs(EXP.lanes) do
        if l.elec ~= lane.elec and l.flash ~= lane.flash then other = l; break end
    end
    lane = { name = lane.name, button = lane.button, ownerbit = lane.ownerbit,
             costume = lane.costume, elec = other.elec, flash = other.flash,
             selfflash = other.selfflash,
             -- both body beats are crossed, or a lane whose FREZ answer happened
             -- to be right would still pass half the verdict
             frez = other.frez, selffrez = other.selffrez,
             crackle = other.crackle, crackleblue = other.crackleblue }
end

local syms = {}
local mf = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
if mf then
    for line in mf:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do syms[n] = tonumber(a, 16) end
    end
    mf:close()
end
local function sym(n)
    if not syms[n] then log("WARN symbol %s not in the map", n) end
    return syms[n] or 0
end

local A = {
    gstate = sym("gstate"),  p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"),  p2_obj  = sym("p2_obj"),
    p1_bar = sym("p1_bar"),  p2_bar  = sym("p2_bar"),
    owner  = sym("alt_pal_owner"), palram = sym("palram"),
}

local GS_PSEL, GS_POST, GS_FIGHT = 4, 0x0d, 2
local FT_RAIDEN, FT_JAX = 7, 11
local OPAL, OXVAL, OXPOS = 0x140, 0x080, 0x090
local PALRSIZ, PALCNT, NMFPAL = 0x40, 0x20, 35
local COLRAM, PALSIZE = 0x01800000, 0x1000
local FULL_BAR = 0xa1

local T0 = 200              -- frames into the fight before the move
local GRAB_DIST = 0x38      -- close enough for a jab and for the short zap
local VIC_WINDOW = 4500     -- frames to win two rounds, see the banners, celebrate

local frame, space, psel, fight = 0, nil, 0, 0
local fields, finished = {}, false
local worn, wornname = nil, nil     -- the costume palette he really has
local seen_elec = {}                -- electric palettes this run ever allocated
local seen_flash = {}               -- ELEC-beat palettes the victim ever wore
local seen_self = {}                -- ELEC-beat palettes RAIDEN ever wore
local seen_frez = {}                -- FREZ-beat palettes the victim ever wore
local seen_selffrez = {}            -- FREZ-beat palettes RAIDEN ever wore
local states, order, hit_at = {}, {}, nil

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end
local function cram(map, idx) return r16(COLRAM + map * PALSIZE + idx * 16) end

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function finish(ok, why)
    if finished then return end
    finished = true
    log("%s mode=%s lane=%s reason=%s", ok and "PASS" or "FAIL", MODE, lane.name, why)
    logfh:close(); manager.machine:exit()
end

local function noverdict(why)
    if finished then return end
    finished = true
    log("NO VERDICT mode=%s lane=%s reason=%s", MODE, lane.name, why)
    logfh:close(); manager.machine:exit()
end

-- palram[map]: the ROM address of the palette in that colour map, and whether
-- anything still holds it
local function palid(map)
    local e = A.palram + map * PALRSIZ
    return r32(e), r16(e + PALCNT)
end

local function obj_pal(objptr)
    local obj = r32(objptr)
    if obj == 0 then return nil end
    local map = (r16(obj + OPAL) >> 8) & 0xff
    local id = palid(map)
    return { obj = obj, map = map, id = id }
end

local function named(addr) return EXP.byaddr[string.format("%08x", addr)] end

-- PARK THE VICTIM INSIDE RANGE, every frame until the move lands.  Once only is
-- not enough: repell pushes them apart the moment they overlap.  oxpos is
-- oxval's top half, so writing the 16.16 field is the whole move.
local function pin_victim()
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return end
    local x = r16(a + OXPOS)
    if x >= 0x8000 then x = x - 0x10000 end
    w32(b + OXVAL, ((x + GRAB_DIST) & 0xffff) << 16)
end

-- a signature for a live colour map, so "how many different palettes" is
-- countable without having to name any of them
local function signature(map)
    local white, black, h = true, true, 0
    for i = 1, 63 do
        local c = cram(map, i)
        if c ~= 0x7fff then white = false end
        if c ~= 0 then black = false end
        h = (h * 33 + c) & 0xffffffff
    end
    return h, white, black
end

-- record one sample of whoever is being watched; returns its palette name
local function sample(objptr, who)
    local p = obj_pal(objptr)
    if not p then return nil, nil end
    local h, white, black = signature(p.map)
    local nm = named(p.id)
    if not states[h] then
        states[h] = { white = white, black = black, name = nm }
        order[#order + 1] = h
        log("%s palette #%d map=%d id=%08x%s", who, #order, p.map, p.id,
            white and "  SOLID WHITE" or (black and "  SOLID BLACK"
            or (nm and ("  " .. nm) or "")))
    end
    return nm, p
end

local function flashes()
    local white, black = false, false
    for _, h in ipairs(order) do
        if states[h].white then white = true end
        if states[h].black then black = true end
    end
    return white, black
end

local function snap()
    for _, scr in pairs(manager.machine.screens) do
        pcall(function() scr:snapshot() end)
    end
end

local function cache()
    local want = { ["UI Select"] = 1, ["Coin 1"] = 1, ["Coin 2"] = 1,
                   ["2 Players Start"] = 1, ["2 Player Start"] = 1,
                   ["P1 High Punch"] = 1, ["P1 Low Kick"] = 1,
                   ["P1 Up"] = 1, ["P1 Down"] = 1, ["P1 Left"] = 1, ["P1 Right"] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
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
    if fight == 0 then return false end
    local t = frame - fight - T0

    if MODE == "costume" then
        -- Down, Up + LK, inside scom_rd_melt's 010h window
        if n == "P1 Down" then return t >= 0 and t < 4 end
        if n == "P1 Up" then return t >= 6 and t < 10 end
        if n == "P1 Low Kick" then return t >= 7 and t < 11 end

    elseif MODE == "cycle" then
        -- Back + HP.  The stick has to be AWAY or rdhp_normal falls through to
        -- the uppercut, and it is HELD so the test cannot miss the press.  P1
        -- opens on the left facing right, so Back is LEFT.  Re-pressed on a slow
        -- beat: rd_hp_open refuses a High Punch inside 050h of the last one, and
        -- one try that landed in the round intro would be the only one made.
        if n == "P1 Left" then return t >= 0 and t < 280 end
        if n == "P1 High Punch" then return t >= 4 and (t % 70) < 6 end

    elseif MODE == "crackle" then
        -- NOTHING IS PRESSED.  The ambient flash is gated on him standing in
        -- his stance (lgt_can_flash / lgt_pose_ok, MKGUYS.ASM), so driving any
        -- input is the one thing that would stop it.

    else    -- victory
        -- a plain close High Punch, over and over.  NO direction: the stick
        -- would make it the zap or the uppercut, and a jab that CONNECTS is all
        -- this needs - the bar is held at 1, so the next one ends the round.
        if n == "P1 High Punch" then return t >= 0 and (t % 24) < 5 end
    end
    return false
end

--
-- THE VICTORY RUN LIVES OUTSIDE THE gstate DISPATCH.  Winning a round takes the
-- game out of GS_FIGHT for the banner and the next round's intro, so a sampler
-- nested under `gs == GS_FIGHT` simply stops for hundreds of frames and its
-- deadline never fires - measured: the t == VIC_WINDOW check was never reached
-- and the run ended on the outer timeout instead.  It counts real frames.
--
local function victory_tick()
    local t = frame - fight - T0
    if t < 0 then return end

    -- ONE HIT FROM DEAD, BOTH ROUNDS.  Held only while the bar is ABOVE 1:
    -- writing 1 unconditionally every frame puts it back the moment bar_reducer
    -- empties it, so the round never ends and the rig sits in a fight forever
    -- (measured: 1800 frames, one palette, "he never won the match").  Raiden's
    -- own bar is held full so he cannot lose a round instead.
    local alive = true
    if A.p2_bar ~= 0 then
        local b = r16(A.p2_bar)
        if b > 1 then w16(A.p2_bar, 1) end
        alive = b > 0
    end
    if A.p1_bar ~= 0 then w16(A.p1_bar, FULL_BAR) end
    if alive then pin_victim() end

    if t % 240 == 0 then
        log("t=%d gs=%d bars %d/%d palettes %d", t, r16(A.gstate),
            r16(A.p1_bar), r16(A.p2_bar), #order)
    end

    local nm = sample(A.p1_obj, "raiden")       -- RAIDEN, not the victim
    if nm and EXP.isselfflash[nm] then seen_self[nm] = true end
    if nm and EXP.isselffrez[nm] then seen_selffrez[nm] = true end

    if t ~= VIC_WINDOW then return end
    snap()
    local white, black = flashes()
    log("raiden wore %d distinct palettes; white=%s black=%s",
        #order, tostring(white), tostring(black))
    if #order < 2 then
        noverdict("raiden never changed palette - he never won the match")
        return
    end
    --
    -- HIS OWN FLASH PALETTE, BY NAME, IS THE REAL ASSERTION.  Solid white and
    -- solid black alone would not do: rvic_fade calls raiden_dimmer, and a full
    -- dim takes his palette to zero, so "a solid black frame happened" is also
    -- true of a build with no cycle at all.  RDELEC_P / RDELRED_P / RDELPUR_P
    -- reach his object only through player_shock_pal.
    --
    local self_got = keys(seen_self)
    if not seen_self[lane.selfflash] then
        finish(false, string.format(
            "%s never reached his object - saw %s.  The victory charge is not "
            .. "going through player_shock_pal", lane.selfflash,
            #self_got > 0 and table.concat(self_got, ",") or "no flash palette at all"))
        return
    end
    local self_wrong = {}
    for _, n2 in ipairs(self_got) do
        if n2 ~= lane.selfflash then self_wrong[#self_wrong + 1] = n2 end
    end
    if #self_wrong > 0 then
        finish(false, string.format("%s was worn, but so was %s",
               lane.selfflash, table.concat(self_wrong, ",")))
        return
    end
    if #order < 4 or not (white and black) then
        finish(false, string.format(
            "%s was worn but there were only %d palettes, white=%s black=%s - the "
            .. "charge is not running all four beats", lane.selfflash,
            #order, tostring(white), tostring(black)))
        return
    end
    -- HIS OWN FREZ BEAT, in the RN row - he fries as RD and freezes as RN.  Same
    -- reasoning as the cycle mode: the count and the flashes are true of the old
    -- cyan wiring too, so the beat has to be named.
    local sfgot = keys(seen_selffrez)
    if not seen_selffrez[lane.selffrez] then
        finish(false, string.format(
            "the ELEC beat was right, but his FREZ one was %s - %s is what this "
            .. "costume pairs with",
            #sfgot > 0 and table.concat(sfgot, ",") or "no known FREZ palette",
            lane.selffrez))
        return
    end
    local sfwrong = {}
    for _, n3 in ipairs(sfgot) do
        if n3 ~= lane.selffrez then sfwrong[#sfwrong + 1] = n3 end
    end
    if #sfwrong > 0 then
        finish(false, string.format("%s was worn for the FREZ beat, but so was %s",
               lane.selffrez, table.concat(sfwrong, ",")))
        return
    end
    -- AND HE IS DRESSED AGAIN.  This is the regression the mode exists for: the
    -- last of twelve beats is BLACK.
    local endnm, p = sample(A.p1_obj, "raiden")
    if endnm ~= lane.costume then
        finish(false, string.format(
            "the four beats ran, but he is left wearing %s instead of %s - the "
            .. "victory loop is not putting his costume back",
            endnm or string.format("%08x", p and p.id or 0), lane.costume))
        return
    end
    finish(true, string.format(
        "%s for the ELEC beat and %s for the FREZ beat, the solid white and black "
        .. "flashes among %d palettes, and he ends in %s",
        lane.selfflash, lane.selffrez, #order, lane.costume))
end

--
-- THE CRACKLE THAT RUNS OVER HIS OWN BODY, per lane.
--
-- The RN*BOLT art is painted against the COSTUME layout, so the flash object is
-- retinted with a costume palette whose slot 63 is the crackle colour
-- (raiden_crackle_pal / raiden_crackle_offer, MKGUYS.ASM; src/RDCRACK.ASM).
-- Nothing is pressed: the flash only fires while he stands in his stance, every
-- 16-47 ticks.
--
-- THE BLUE LANES CANNOT BE JUDGED BY "DID THE PALETTE APPEAR" - their crackle
-- palette IS his costume palette, which his body is already wearing.  So they
-- are judged two ways at once: no RDCRK_* palette may be allocated at all, AND
-- the costume palette's own REFCOUNT has to rise above its resting value, which
-- is the crackle object's getfpal taking a second reference on it.  Without that
-- second test a lane where no flash ever fired would pass for free.
--
local crackle_seen, crackle_base, crackle_peak = {}, nil, 0

local function crackle_tick(t)
    for m = 0, NMFPAL - 1 do
        local id, cnt = palid(m)
        if cnt ~= 0 then
            local nm = named(id)
            if nm and EXP.iscrackle[nm] and not crackle_seen[nm] then
                crackle_seen[nm] = true
                log("t=%d colour map %d holds %s (%08x)", t, m, nm, id)
            end
            if nm and nm == lane.costume then
                -- his body's own palette: watch what else takes a ref on it
                if crackle_base == nil or cnt < crackle_base then crackle_base = cnt end
                if cnt > crackle_peak then
                    crackle_peak = cnt
                    log("t=%d %s refcount %d (resting %d)", t, nm, cnt,
                        crackle_base or -1)
                end
            end
        end
    end

    if t ~= 300 then return end
    snap()
    local got = keys(crackle_seen)
    log("crackle palettes seen: %s; %s refcount %d of a resting %d",
        #got > 0 and table.concat(got, ",") or "none", lane.costume,
        crackle_peak, crackle_base or -1)

    if lane.crackleblue then
        if #got > 0 then
            finish(false, string.format(
                "this lane's crackle should be his costume's own blue, but %s "
                .. "was allocated", table.concat(got, ",")))
            return
        end
        if crackle_base == nil or crackle_peak <= crackle_base then
            noverdict(string.format(
                "no second owner ever took %s (refcount stayed at %d) - the "
                .. "ambient flash never fired, so nothing was measured",
                lane.costume, crackle_peak))
            return
        end
        finish(true, string.format(
            "%s crackles in his costume's own palette - %s went to refcount %d "
            .. "from %d and no RDCRK_* palette was allocated",
            lane.name, lane.costume, crackle_peak, crackle_base))
        return
    end

    if #got == 0 then
        -- NO COLOURED PALETTE - and the costume's refcount says which of the two
        -- reasons it is.  A rise means the flash DID fire and took his costume
        -- palette itself, which is the pre-2026-09-28 behaviour and a real
        -- failure; no rise means nothing fired and nothing was measured.  Told
        -- apart, because "no RDCRK_* appeared" on its own reads the same either
        -- way and would hand a crossed blue lane a free NO VERDICT.
        if crackle_base ~= nil and crackle_peak > crackle_base then
            finish(false, string.format(
                "the flash fired - %s went to refcount %d from %d - but it drew "
                .. "in that costume palette itself, not %s",
                lane.costume, crackle_peak, crackle_base, lane.crackle))
            return
        end
        noverdict("the ambient flash never allocated a crackle palette and never "
                  .. "took a second reference on " .. lane.costume
                  .. " - it did not fire inside the window")
        return
    end
    if not crackle_seen[lane.crackle] then
        finish(false, string.format(
            "the crackle drew in %s - %s is what this costume pairs with",
            table.concat(got, ","), lane.crackle))
        return
    end
    local wrong = {}
    for _, nm in ipairs(got) do
        if nm ~= lane.crackle then wrong[#wrong + 1] = nm end
    end
    if #wrong > 0 then
        finish(false, string.format("%s was allocated, but so was %s",
               lane.crackle, table.concat(wrong, ",")))
        return
    end
    finish(true, string.format("%s crackles in %s, and in no other",
           lane.name, lane.crackle))
end

local function costume_tick(t)
    for m = 0, NMFPAL - 1 do
        local id, cnt = palid(m)
        if cnt ~= 0 then
            local nm = named(id)
            if nm and EXP.iselec[nm] and not seen_elec[nm] then
                seen_elec[nm] = true
                log("t=%d colour map %d holds %s (%08x)", t, m, nm, id)
            end
        end
    end
    if t ~= 120 then return end
    snap()
    local got = keys(seen_elec)
    if not seen_elec[lane.elec] then
        finish(false, string.format("%s never reached a colour map - saw %s",
               lane.elec, #got > 0 and table.concat(got, ",")
               or "no electric palette at all"))
        return
    end
    local wrong = {}
    for _, nm in ipairs(got) do
        if nm ~= lane.elec then wrong[#wrong + 1] = nm end
    end
    if #wrong > 0 then
        finish(false, string.format("%s was drawn, but so was %s",
               lane.elec, table.concat(wrong, ",")))
        return
    end
    finish(true, string.format(
        "%s wears %s and the teleport drew in %s, with neither other electric "
        .. "palette on screen", lane.name, lane.costume, lane.elec))
end

local function cycle_tick(t)
    if #order < 2 then pin_victim() end          -- until the zap lands
    local nm = sample(A.p2_obj, "victim")
    if nm and EXP.isflash[nm] then seen_flash[nm] = true end
    if nm and EXP.isfrez[nm] then seen_frez[nm] = true end
    if #order > 1 and not hit_at then hit_at = t end
    if t % 60 == 0 then
        local a, b = r32(A.p1_obj), r32(A.p2_obj)
        log("t=%d x %d vs %d, palettes so far %d", t,
            r16(a + OXPOS), r16(b + OXPOS), #order)
    end

    if t ~= 280 then return end
    snap()
    local white, black = flashes()
    log("victim wore %d distinct palettes; white=%s black=%s",
        #order, tostring(white), tostring(black))
    if #order < 2 then
        noverdict(string.format("the victim never changed palette - electric "
                  .. "palettes seen: %s", #keys(seen_elec) > 0
                  and table.concat(keys(seen_elec), ",")
                  or "none, so the bolt never came out"))
        return
    end
    if #order < 4 or not (white and black) then
        finish(false, string.format(
            "%d palettes, white=%s black=%s - not the four-beat cycle",
            #order, tostring(white), tostring(black)))
        return
    end
    -- and the ELEC beat has to be HIS body in RAIDEN'S colour
    local got = keys(seen_flash)
    if not seen_flash[lane.flash] then
        finish(false, string.format(
            "the four beats ran, but the ELEC one was %s - %s is what %s pairs "
            .. "with this costume",
            #got > 0 and table.concat(got, ",") or "no known flash palette",
            lane.flash, EXP.victim))
        return
    end
    local wrong = {}
    for _, nm2 in ipairs(got) do
        if nm2 ~= lane.flash then wrong[#wrong + 1] = nm2 end
    end
    if #wrong > 0 then
        finish(false, string.format("%s was worn, but so was %s",
               lane.flash, table.concat(wrong, ",")))
        return
    end
    --
    -- AND SO HAS THE FREZ BEAT (the user's, 2026-09-28).  This is the half the
    -- palette COUNT cannot see: the old wiring drew this beat in the cyan frozen
    -- set whatever colour the bolt was, and that is four distinct palettes with
    -- both solid flashes and the right ELEC beat - every test above passes on it.
    -- JXFREZ_P appearing on a red or purple lane IS the regression.
    --
    local fgot = keys(seen_frez)
    if not seen_frez[lane.frez] then
        finish(false, string.format(
            "the ELEC beat was right, but the FREZ one was %s - %s is what %s "
            .. "pairs with this costume",
            #fgot > 0 and table.concat(fgot, ",") or "no known FREZ palette",
            lane.frez, EXP.victim))
        return
    end
    local fwrong = {}
    for _, nm3 in ipairs(fgot) do
        if nm3 ~= lane.frez then fwrong[#fwrong + 1] = nm3 end
    end
    if #fwrong > 0 then
        finish(false, string.format("%s was worn for the FREZ beat, but so was %s",
               lane.frez, table.concat(fwrong, ",")))
        return
    end
    finish(true, string.format(
        "%d distinct palettes - the solid white and black flashes, %s for the "
        .. "ELEC beat and %s for the FREZ beat; first change at t=%s",
        #order, lane.flash, lane.frez, tostring(hit_at)))
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache()
        log("mode=%s lane=%s (%s): costume %s, lightning %s, victim's flash %s",
            MODE, lane.name, lane.button, lane.costume, lane.elec, lane.flash)
        log("palram=%08x alt_pal_owner=%08x claim bit=%04x",
            A.palram, A.owner, lane.ownerbit)
    end

    if space and not finished then
        local gs = r16(A.gstate)

        if gs == GS_PSEL or gs == GS_POST then
            if gs == GS_PSEL and psel == 0 then psel = frame; log("select at frame %d", frame) end
            w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX)
            w16(A.owner, lane.ownerbit)
        end

        if gs == GS_FIGHT and fight == 0 then
            fight = frame; log("fight at frame %d", frame)
        end

        if fight > 0 then
            w16(A.owner, lane.ownerbit)   -- player_normpal recovers the lane from here

            -- WHAT IS HE ACTUALLY WEARING?  Settled late on purpose: the round
            -- intro repalettes him more than once.
            if not worn and frame - fight == T0 - 20 then
                local p = obj_pal(A.p1_obj)
                if not p then noverdict("no player 1 object"); return end
                worn, wornname = p.id, named(p.id)
                log("P1 obj=%08x map=%d costume=%08x (%s)",
                    p.obj, p.map, p.id, wornname or "UNKNOWN")
                if wornname ~= lane.costume then
                    noverdict(string.format(
                        "asked for lane %s (%s) but he is wearing %s - the claim never "
                        .. "landed, so this would be judged against the wrong pair",
                        lane.name, lane.costume, wornname or "an unknown palette"))
                    return
                end
            end

            if MODE == "victory" then victory_tick() end
        end

        if gs == GS_FIGHT then
            local t = frame - fight - T0
            if t >= 0 then
                if MODE == "costume" then costume_tick(t)
                elseif MODE == "cycle" then cycle_tick(t)
                elseif MODE == "crackle" then crackle_tick(t) end
            end
            if MODE ~= "victory" and frame - fight > T0 + 900 then
                finish(false, "the fight ran out"); return
            end
        end

        if frame % 400 == 0 then
            log("frame=%d gstate=%d psel=%d fight=%d", frame, gs, psel, fight)
        end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    local cap = (MODE == "victory") and 9000 or 6000
    if frame > cap then noverdict("timeout - never reached a fight") end
end)
