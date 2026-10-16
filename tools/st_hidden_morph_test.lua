-- st_hidden_morph_test.lua
--
-- Shang Tsung's hidden-fighter morphs (stmorph_hidden, MAINEQU.ASM):
--   JADE  = Forward, Forward, Down, Down + Block   (stblk_jade, MOVES.ASM)
--   ERMAC = Down, Down, Up, stick only, Block held  (st_up,      MOVES.ASM)
-- each gated on f_jade_unlocked / f_ermac_unlocked - the same flags the
-- select screen's START tap reads (mst_up, MKSEL.ASM), so "can morph" and
-- "can be picked" are one answer.  P2 is never Jade or Ermac here: who
-- Shang faces must not matter.
--
-- And RAIN (stmorph_rain):
--   RAIN  = hold Down + Block, tap Low Kick        (stlk2,      MOVES.ASM)
-- which has NO unlock flag - he is always pickable (a START tap on Sub-Zero,
-- morph_table MKSEL.ASM) - so he must morph in BOTH modes.  Its negative
-- ("rainnb") releases block before the kick and must get BARAKA, Down,Down+LK,
-- proving the chord did not swallow the plain low-kick morph next to it.
--
-- ST_HM_MODE:
--   unlocked - the ROM's power-on state.  P2 sits on Mileena and taps
--              START for real: the tap must raise f_jade_cheat2 (Jade
--              pickable), then a second tap drops it again, so the fight is
--              Shang vs Mileena.  Both morphs must work.
--   locked   - the rig zeroes both flags after boot (what an achievement
--              system would leave at power-on).  The START tap must do
--              nothing and both morph inputs must do nothing.
--
-- Every mode also runs retail morphs as controls: Cage B,B,D+LP, Liu Kang
-- B,F,F+Block (Jade's button), Scorpion Block+U,U (Ermac's Up handler).
-- Each morph that lands is reverted with Block+Up+HK.
--
-- Every trial that morphs also checks the COSTUME (stmorph_defpal): the
-- palette the fighter is actually wearing, read out of palram through his
-- opal, must be character_palettes_1[ochar] - the TARGET's default - no
-- matter which of Shang's seven costumes ST_HM_COSTUME seeded.  Reverting
-- must then put him back in THAT costume, which is what proves the seed was
-- live: without that check a defpal run would pass on a Shang who had been
-- on his default the whole time.  Calibrated against stmorph_defpal 0, where
-- a -Costume hk run fails 6 of 7 (Ermac's Start+HK row IS his default).
--
-- P1 is Shang, pinned 130 px left of P2, so away = Left.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("ST_HM_LOG") or (ROOT .. "/tools/st_hidden_morph_test.log")
local MODE     = os.getenv("ST_HM_MODE") or "unlocked"
local STAGE_ID = getenv_int("ST_HM_STAGE", 5)      -- Armory
local SNAPS    = (os.getenv("ST_HM_SNAPS") or "1") ~= "0"
-- ST_HM_COSTUME: which SELECT-SCREEN ALTERNATE Shang was picked in, as the
-- @alt_pal_owner bit that records it (see player_normpal's pnorm_*_owner
-- branches, MKGUYS.ASM).  0 = his default.  The rig seeds the OWNER word
-- rather than the object's oflags2, because that word is the durable record
-- the recovery branches re-derive the lane from - seeding it is what makes
-- this a real "picked in a costume" Shang rather than a flag that the next
-- repalette would wipe.  P1 bits: 1 start+block, 0x10 start+lp, 4 start+hp,
-- 0x40 start+hk, 0x100 start+lk, 0x400 start+coin.
local COSTUME  = getenv_int("ST_HM_COSTUME", 0)
local COSTUME_TABLE = { [0]=1, [1]=3, [0x10]=2, [4]=4, [0x40]=5, [0x100]=6, [0x400]=7 }

local FT_ST, FT_JADE, FT_ERMAC, FT_RAIN = 6, 16, 17, 19
local MODES = {
    unlocked = { seat = 5, lock = false, jade = true,  ermac = true  },
    locked   = { seat = 5, lock = true,  jade = false, ermac = false },
}
local M = MODES[MODE]

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[st-hmorph] " .. msg)
end
local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local missing_syms = {}
local function sym(name)
    local v = symbols[name]
    if v == nil then missing_syms[#missing_syms + 1] = name; return 0 end
    return v
end

local A = {
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),
    p2_state      = sym("p2_state"),
    p1_char       = sym("p1_char"),
    p2_char       = sym("p2_char"),
    p1_obj        = sym("p1_obj"),
    p2_obj        = sym("p2_obj"),
    p1_bar        = sym("p1_bar"),
    p2_bar        = sym("p2_bar"),
    curback       = sym("curback"),
    pf_ram        = sym("pf_ram"),
    system_lockup = sym("system_lockup"),
    tvbp          = sym("TVBP"),
    jade_ok       = sym("f_jade_unlocked"),
    ermac_ok      = sym("f_ermac_unlocked"),
    earned        = symbols["hid_earned"],  -- hidearn: optional, older maps lack it
    jade_cheat2   = sym("f_jade_cheat2"),
    alt_pal_owner = sym("alt_pal_owner"),
    palram        = sym("palram"),
}
local PALRSIZ = 0x40
local CPAL = {}
for i = 1, 7 do CPAL[i] = sym("character_palettes_" .. i) end
local O = { oxval = 0x080, oxpos = 0x090, opal = 0x140, ochar = 0x1f0 }
local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local MAX_HP = 0xa1

-- {press_at, release_at, input}, frames from the trial start.
local IN_JADE   = { {0,5,"P1 Right"}, {9,14,"P1 Right"}, {18,23,"P1 Down"}, {27,32,"P1 Down"}, {34,40,"P1 Block"} }
local IN_ERMAC  = { {0,44,"P1 Block"}, {6,11,"P1 Down"}, {15,20,"P1 Down"}, {24,30,"P1 Up"} }
local IN_SCORP  = { {0,34,"P1 Block"}, {6,11,"P1 Up"}, {15,20,"P1 Up"} }
local IN_LIU    = { {0,5,"P1 Left"}, {9,14,"P1 Right"}, {18,23,"P1 Right"}, {25,31,"P1 Block"} }
local IN_CAGE   = { {0,5,"P1 Left"}, {9,14,"P1 Left"}, {18,23,"P1 Down"}, {25,31,"P1 Low Punch"} }
local IN_BARAKA = { {0,5,"P1 Down"}, {9,14,"P1 Down"}, {16,22,"P1 Low Kick"} }
local IN_RAIDEN = { {0,5,"P1 Down"}, {9,14,"P1 Left"}, {18,23,"P1 Right"}, {25,31,"P1 Low Kick"} }
-- RAIN is a CHORD, not a motion: hold Down and Block, then tap Low Kick
-- (stlk2 / st_rain_holding, MOVES.ASM).  Block is held THROUGH the kick -
-- st_rain_holding reads @switch on the press, so letting go first is a miss,
-- which is what the "rain_noblock" negative below drives.
local IN_RAIN   = { {0,40,"P1 Block"}, {0,40,"P1 Down"}, {14,22,"P1 Low Kick"} }
-- The same chord with block released before the kick: Down,Down+LK is
-- Baraka's morph (scom_st_2_sa), so this must land on BARAKA (3), never Rain
-- and never nothing - it proves the chord did not steal the plain LK morph.
local IN_RAIN_NB= { {0,12,"P1 Block"}, {0,5,"P1 Down"}, {9,14,"P1 Down"}, {16,22,"P1 Low Kick"} }
-- Shang -> MILEENA is a HELD HIGH PUNCH, released (st_hp_open, MOVES.ASM:
-- get_tsl on l_hp must read at least 030h = 48 ticks since the press).  P2 IS
-- Mileena here, so this is the MORPH MIRROR: he becomes the man in front of
-- him, that man is on his default, so Shang must take the ALTERNATE
-- (character_palettes_2) to stay tellable apart - the one branch of
-- pnorm_morph_default that no other trial reaches.
local IN_MIRROR = { {0,60,"P1 High Punch"} }
local UNMORPH   = { {0,34,"P1 Block"}, {6,34,"P1 Up"}, {14,22,"P1 High Kick"} }

local TRIALS = {
    { name = "cage",   script = IN_CAGE,   want = 2 },
    { name = "jade",   script = IN_JADE,   want = M and M.jade and FT_JADE or FT_ST, snap = true },
    { name = "liukang", script = IN_LIU,   want = 1 },
    { name = "ermac",  script = IN_ERMAC,  want = M and M.ermac and FT_ERMAC or FT_ST, snap = true },
    { name = "scorp",  script = IN_SCORP,  want = 10 },
    -- Rain has NO unlock flag: he is a START tap on Sub-Zero at the select
    -- screen and is always pickable, so he must morph in BOTH modes - the
    -- "locked" run is the assertion that he is ungated, not a negative.
    { name = "rain",   script = IN_RAIN,   want = FT_RAIN, snap = true },
    { name = "rainnb", script = IN_RAIN_NB, want = 3 },
    { name = "mirror", script = IN_MIRROR, want = 5, mirror = true },
}

local MORPH_WINDOW  = 100
local UNMORPH_START = 125
local TRIAL_LEN     = UNMORPH_START + 70
local SNAP_AT = { [30]=true, [38]=true, [46]=true, [54]=true, [MORPH_WINDOW]=true,
                  [UNMORPH_START+20]=true, [UNMORPH_START+28]=true, [UNMORPH_START+36]=true,
                  [UNMORPH_START+60]=true }

local cpu, space = nil, nil
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local last_gstate = -1
local confirm_start = 0
local cheat_raised = false
local settle_done = false
local trial_index, trial_frame0 = 0, 0
local morphed, unmorph_delay, early = nil, nil, false
local morph_pal, want_pal = nil, nil
local results = {}
local finished, did_error = false, false
local checks = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function check(name, ok, detail)
    checks[#checks + 1] = { name = name, ok = ok, detail = detail }
    log("check %-22s %s  %s", name, ok and "OK" or "FAIL", detail or "")
    if not ok then did_error = true end
end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Low Punch"] = true, ["P1 Block"] = true,
        ["P1 High Kick"] = true, ["P1 Low Kick"] = true,
        ["P1 Up"] = true, ["P1 Down"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("MISSING input %s", name); return false end
    end
    return true
end

local function p1_ochar()
    local o = r32(A.p1_obj)
    if o == 0 then return -1 end
    return r16(o + O.ochar)
end

-- Which ROM palette P1 is actually wearing.  palram is numpal entries of
-- PALRSIZ bits whose first long is the palette ID - and a palette ID IS the
-- ROM address of the .word block (findpal, PALL.ASM).  The object's opal
-- carries the colour map doubled into both bytes, so the slot is the low one.
local function p1_palette()
    local o = r32(A.p1_obj)
    if o == 0 then return 0 end
    local slot = r16(o + O.opal) & 0xff
    return r32(A.palram + slot * PALRSIZ)
end

-- character_palettes_N[ochar] straight out of the ROM.
local function char_palette(table_base, ochar)
    return r32(table_base + ochar * 32)
end

local function pin_positions()
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    local x = r16(p2 + O.oxpos) - 130
    w16(p1 + O.oxpos, x)
    w32(p1 + O.oxval, (x << 16) & 0xffffffff)
    w16(A.p1_bar, MAX_HP)
    w16(A.p2_bar, MAX_HP)
end

local function script_wants(script, base, name)
    local rel = frame - base
    for _, step in ipairs(script) do
        if name == step[3] and rel >= step[1] and rel < step[2] then return true end
    end
    return false
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
        return false
    end
    if fighting_frame == 0 then
        if confirm_start == 0 then return false end
        if name == "P1 High Punch" then
            return frame >= confirm_start and frame < confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= confirm_start + 80 and frame < confirm_start + 120
        end
        -- P2's START taps on Mileena: the second only matters if the first
        -- was accepted (it toggles her back), and is harmless otherwise.
        if name == "2 Players Start" then
            local r = frame - confirm_start
            return (r >= 45 and r < 50) or (r >= 62 and r < 67)
        end
        return false
    end
    local t = TRIALS[trial_index]
    if t and trial_frame0 > 0 and frame >= trial_frame0 then
        local rel = frame - trial_frame0
        if rel < MORPH_WINDOW then return script_wants(t.script, trial_frame0, name) end
        if rel >= UNMORPH_START and t.want ~= FT_ST then
            return script_wants(UNMORPH, trial_frame0 + UNMORPH_START, name)
        end
    end
    return false
end

local function cpu_pc()
    for _, n in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, item = pcall(function() return cpu.state[n] end)
        if ok and item then
            local okv, v = pcall(function() return item.value end)
            if okv then return v end
        end
    end
    return nil
end

local function snap(tag)
    if not SNAPS then return end
    pcall(function() manager.machine.video:snapshot() end)
    log("snap %s frame=%d ochar=%d", tag, frame, p1_ochar())
end

local function finish(reason)
    if finished then return end
    finished = true
    log("---- results (mode=%s) ----", MODE)
    local fail = 0
    for _, r in ipairs(results) do
        log("%-7s want=%-2d got=%-2d %s%s%s", r.name, r.want, r.got,
            r.ok and "OK" or "FAIL",
            r.want ~= FT_ST and string.format("  unmorph=%s after %s frames",
                tostring(r.back), tostring(r.delay)) or "",
            r.pal and string.format("  pal=%s want=%s %s", hx(r.pal), hx(r.palwant),
                r.pal_ok and "OK" or "WRONG") or "")
        if not r.ok then fail = fail + 1 end
    end
    for _, c in ipairs(checks) do if not c.ok then fail = fail + 1 end end
    local all = (#results == #TRIALS) and fail == 0 and not did_error
    log("%s mode=%s reason=%s trials=%d/%d failures=%d",
        all and "PASS" or "FAIL", MODE, reason, #results, #TRIALS, fail)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function step()
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d p1_char=%d p2_char=%d jade_ok=%d ermac_ok=%d",
                frame, r16(A.p1_char), r16(A.p2_char), r16(A.jade_ok), r16(A.ermac_ok))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.curback, STAGE_ID)
        -- Seat both players until P2's confirm begins; after that the ROM
        -- owns p2_char (the pending flag rewrites it) and so must we not.
        if confirm_start == 0 or frame < confirm_start + 80 then
            w16(A.p1_char, FT_ST)
            w16(A.p2_char, M.seat)
            w16(A.p1_state, PS_ACTIVE)
            w16(A.p2_state, PS_ACTIVE)
        end
        if charsel_frame > 0 and confirm_start == 0 and frame > charsel_frame + 90 then
            confirm_start = frame + 25
            log("confirm_start=%d P2 seat=%d", confirm_start, M.seat)
        end
        -- hidearn: Jade/Ermac/Rain must also be EARNED (hid_earned, bit 0
        -- Jade, 1 Ermac, 2 Rain - beat her / Shao Kahn / Smoke).  A fresh
        -- cmos has none, so the rig grants them: all three unlocked, only
        -- Rain locked (his trial must still morph).  Older maps: zero flags.
        if A.earned then
            w16(A.earned, M.lock and 4 or 7)
        elseif M.lock then
            w16(A.jade_ok, 0)
            w16(A.ermac_ok, 0)
        end
        if confirm_start > 0 and frame == confirm_start + 57 then
            local v = r16(A.jade_cheat2)
            check("start tap on mileena", (v ~= 0) == M.jade,
                  string.format("f_jade_cheat2=%d want %s", v, M.jade and "raised" or "refused"))
        end
        if confirm_start > 0 and frame == confirm_start + 75 then
            check("second tap / none", r16(A.jade_cheat2) == 0,
                  "f_jade_cheat2=" .. r16(A.jade_cheat2))
        end
        if frame > 9000 then finish("never_reached_fight") end
        return
    end

    local pc = cpu_pc()
    if pc and A.system_lockup ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
        log("ERROR lockup pc=%s pf=%s", hx(pc), hx(r32(A.pf_ram)))
        did_error = true
        finish("lockup")
        return
    end
    pin_positions()

    if not settle_done then
        if frame - fighting_frame < 150 then return end
        settle_done = true
        check("p2 is mileena", r16(A.p2_char) == M.seat,
              string.format("p2_char=%d want %d", r16(A.p2_char), M.seat))
        local earned = A.earned and r16(A.earned) or 7
        check("jade unlocked", (r16(A.jade_ok) ~= 0 and earned & 1 ~= 0) == M.jade,
              string.format("flag=%d earned=%d want %s", r16(A.jade_ok), earned, tostring(M.jade)))
        check("ermac unlocked", (r16(A.ermac_ok) ~= 0 and earned & 2 ~= 0) == M.ermac,
              string.format("flag=%d earned=%d want %s", r16(A.ermac_ok), earned, tostring(M.ermac)))
        check("p1 starts as shang", p1_ochar() == FT_ST, "ochar=" .. p1_ochar())
        if COSTUME ~= 0 then
            w16(A.alt_pal_owner, COSTUME)
            log("costume: alt_pal_owner=0x%x -> Shang on character_palettes_%d",
                COSTUME, COSTUME_TABLE[COSTUME] or -1)
        end
        trial_index = 1
        trial_frame0 = frame + 25
        log("trial 1/%d %s begins frame=%d", #TRIALS, TRIALS[1].name, trial_frame0)
        return
    end

    local t = TRIALS[trial_index]
    if not t then finish("all_trials_done"); return end
    if frame < trial_frame0 then return end
    local rel = frame - trial_frame0
    local oc = p1_ochar()

    if t.snap and t.want ~= FT_ST and SNAP_AT[rel] then snap(string.format("%s_rel%03d", t.name, rel)) end
    if t.snap and t.want == FT_ST and rel == MORPH_WINDOW then snap(t.name .. "_locked") end

    if rel == MORPH_WINDOW then
        morphed = oc
        log("%-7s morph_read frame=%d ochar=%d want=%d %s", t.name, frame, oc, t.want,
            oc == t.want and "OK" or "MISS")
        -- stmorph_defpal: whatever costume SHANG was picked in, a morph lands
        -- on the TARGET's default.  P2 is Mileena and no trial becomes her, so
        -- the morph-mirror alternate never applies and cpal_1 is the answer
        -- for every one of them.
        if oc ~= FT_ST then
            local want_tab = t.mirror and 2 or 1
            morph_pal = p1_palette()
            want_pal = char_palette(CPAL[want_tab], oc)
            log("%-7s palette=%s want=%s (cpal_%d[%d]) %s", t.name, hx(morph_pal),
                hx(want_pal), want_tab, oc,
                morph_pal == want_pal and "OK" or "WRONG COSTUME")
        end
    end
    if morphed and morphed ~= FT_ST and rel > MORPH_WINDOW and rel < UNMORPH_START
        and oc == FT_ST and not early then
        early = true
        log("%-7s WARN reverted at rel=%d, before the gesture", t.name, rel)
    end
    if morphed and morphed ~= FT_ST and rel >= UNMORPH_START and unmorph_delay == nil
        and oc == FT_ST then
        unmorph_delay = rel - UNMORPH_START
    end

    if rel >= TRIAL_LEN then
        local final = p1_ochar()
        local ok = (morphed == t.want)
        local back = nil
        if t.want ~= FT_ST then
            back = (final == FT_ST) and unmorph_delay ~= nil and not early
            ok = ok and back
        else
            ok = ok and final == FT_ST
        end
        local pal_ok = true
        if t.want ~= FT_ST and morphed == t.want then
            pal_ok = (morph_pal ~= nil) and (morph_pal == want_pal)
            ok = ok and pal_ok
        end
        -- THE DETECTOR CALIBRATION.  With a costume seeded, reverting must put
        -- Shang back in THAT costume - which is also the proof the seed was
        -- live.  Without it a defpal run would pass even if alt_pal_owner had
        -- never taken, because "morph lands on the default" is trivially true
        -- for a Shang who was on his default all along.
        local home_pal, home_want = nil, nil
        if final == FT_ST then
            home_pal = p1_palette()
            home_want = char_palette(CPAL[COSTUME_TABLE[COSTUME] or 1], FT_ST)
            if home_pal ~= home_want then
                log("%-7s WARN back as shang on %s, want %s (cpal_%d)", t.name,
                    hx(home_pal), hx(home_want), COSTUME_TABLE[COSTUME] or 1)
                ok = false
            end
        end
        results[#results + 1] = { name = t.name, want = t.want, got = morphed or -1,
                                  ok = ok, back = back, delay = unmorph_delay,
                                  pal = morph_pal, palwant = want_pal, pal_ok = pal_ok,
                                  home = home_pal, homewant = home_want }
        if final ~= FT_ST then
            local o = r32(A.p1_obj)
            if o ~= 0 then w16(o + O.ochar, FT_ST) end
            log("%-7s forced back to ft_st", t.name)
        end
        trial_index = trial_index + 1
        trial_frame0 = frame + 35
        morphed, unmorph_delay, early = nil, nil, false
        morph_pal, want_pal = nil, nil
        if TRIALS[trial_index] then
            log("trial %d/%d %s begins frame=%d", trial_index, #TRIALS,
                TRIALS[trial_index].name, trial_frame0)
        end
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not M then log("ERROR unknown ST_HM_MODE=%s", MODE); finish("bad_mode"); return end
        if #missing_syms > 0 then
            log("ERROR missing symbols: %s", table.concat(missing_syms, ", "))
            finish("missing_symbols"); return
        end
        if not cache_fields() then finish("required_input_missing"); return end
        log("mode=%s P2 seat=%d stage=%d", MODE, M.seat, STAGE_ID)
    end
    if not space or finished then return end
    step()
    if frame > 16000 then finish("global_timeout") end
    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)

emu.register_stop(function()
    if logfh then logfh:close(); logfh = nil end
end)
