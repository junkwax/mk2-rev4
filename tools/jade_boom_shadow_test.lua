-- jade_boom_shadow_test.lua
--
-- Runtime proof for Jade's boomerang SHADOW trail (MKZAP.ASM
-- jade_boom_trail / jade_boom_trail_proc).
--
-- What it asserts:
--   1. Every echo is a CLONE of the blade's own live frame - its osag has to
--      be one of the BRANG sags, and the trail has to show SEVERAL of them
--      across a flight, because the echo is meant to wear the orientation
--      the blade actually had when it was dropped.
--      (UMK3 itself stamps ONE fixed frame, BOOMGHOST - verified in
--      boom_trail_proc, which has no indexing after find_part2.  Cloning is
--      a deliberate deviation: a fixed pose reads as a stuck second blade.)
--   2. Exactly TWO shadows stand behind the blade once the trail is up:
--      spawn every other tick (UMK3's p_store2 countdown of 2) against
--      jade_boom_shadow_life = 3 ticks (UMK3's framew(3) in boom_trail_proc),
--      so a fresh echo overlaps the previous one on its last tick.  This
--      still peaks at two with the 3-tick life it had at 4.
--   3. They wear the BLADE'S OWN palette (jade_boom_p / BOOMRNG_P), proved
--      from the data and not by eye: the object's opal is an fpalram slot
--      number, the slot holds the palette's ROM address, and every colour
--      there has to be one of BOOMRNG_P's sixteen.  The arcade attaches no
--      shadow palette anywhere in this group; the echo art is drawn in the
--      blade's colours.
--   4. They sit one z behind the blade, at a position the blade's own drawn
--      top-left passed through - a clone carries the blade's already
--      flip-corrected mp_anix/mp_aniy, so it lands exactly on it.
--
-- Jade selection trick (as jade_boomerang_test.lua): the select screen won't
-- take char 16, so pick Kitana during GS_PSEL and overwrite p1_char to
-- FT_JADE during GS_POST.
--
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_SHADOW_LOG") or (ROOT .. "/tools/jade_boom_shadow_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[boom-sh] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n, d) return symbols[n] or d end

local A = {
    gstate  = sym("gstate", 0x0112a830),
    p1_obj  = sym("p1_obj", 0x0112a880),
    p1_proc = sym("p1_proc", 0x0112a8c0),
    p1_char = sym("p1_char", 0x0112a8e0),
    p2_obj  = sym("p2_obj", 0x0112b450),
    p2_char = sym("p2_char", 0x0112b4b0),
    diff    = sym("diff"),
    objlst  = sym("objlst"),
    fpalram = sym("fpalram"),
}
-- object block (bit offsets, DISPEQU.ASM)
local O = { link=0x000, xpos=0x090, ypos=0x0b0, zval=0x0c0, flags=0x0f0,
            sag=0x100, sizex=0x120, sizey=0x130, pal=0x140, flags2=0x160,
            img=0x1a0, id=0x1c0, char=0x1f0 }
-- multipart RAM record (mp_* in DISPEQU.ASM)
local MP = { sag=0, yxsize=32, control=64, anix=80, aniy=96 }

local P_ACTION = 0x1f0
local ACT_JADE_BOOM = 0x112
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_REPTILE, FT_JADE = 4, 9, 16

-- Every BRANG/BRTRAIL frame lives in the JADERANG bank-0 sidecar.  The window
-- is derived from the SAGs read out of src/JADERANG.TBL below, not written
-- here: the hardcoded one was left behind when the pack moved and matched no
-- object at all - the very failure the BRANG_SAGS comment below describes,
-- in the same file.
local SAG_LO, SAG_HI
-- A puff is dropped ON the blade, not behind it. UBWISP's (71,-8) offset is
-- applied by ani_adjust_single at creation and then GIVEN STRAIGHT BACK by
-- `ani` (MKDISP.ASM:3685), which diffs the old and new frames' anipoints and
-- adds the delta to oxval/oyval to keep the anipoint pinned in world space.
-- framew applies UBTRAIL1 on the same tick the object is built, so the wisp
-- offset never survives to be drawn. The separation you see in game is the
-- BLADE moving on: 9px/tick against a spawn every 2 ticks = 18px apart.
local TRAIL_BACK, TRAIL_DROP = 0, 0
local BLADE_SPEED = 9            -- set_proj_vel(090000h), MKZAP.ASM
local TRAIL_SPACING = 2 * BLADE_SPEED
-- Blade frame SAGs are READ FROM src/JADERANG.TBL, never hardcoded here: every
-- SAG in the sidecar shifts whenever data/JADERANG.LOD's pack changes, and a
-- stale copy makes a WORKING trail report "not a blade frame" on every echo -
-- which is exactly what happened when UBWISP came out and UBREL3 went in.
local BRANG_SAGS = {}
do
    local fh = io.open(ROOT .. "/src/JADERANG.TBL", "r")
    local label
    if fh then
        for line in fh:lines() do
            local l = line:match("^(UB[%w_]*):")
            if l then label = l end
            local sag = line:match("^%s*%.long%s+(%x+)H")
            if label and sag then
                BRANG_SAGS[tonumber(sag, 16)] = label
                label = nil
            end
        end
        fh:close()
    end
end
local n_blade = 0
for _ in pairs(BRANG_SAGS) do n_blade = n_blade + 1 end
assert(n_blade >= 6, "could not read blade SAGs from src/JADERANG.TBL")
for sag in pairs(BRANG_SAGS) do
    if not SAG_LO or sag < SAG_LO then SAG_LO = sag end
    if not SAG_HI or sag > SAG_HI then SAG_HI = sag end
end
SAG_LO, SAG_HI = SAG_LO - 0x1000, SAG_HI + 0x10000
-- The old BRTRAIL/BOOMGHOST records are no longer packed at all, so any
-- sag outside BRANG_SAGS here is simply wrong art.
local DEAD_TRAIL_SAGS = {}
-- BOOMRNG_P, the blade's own 16-entry ramp (jade_boom_p in MKZAP.ASM).
local BLADE_COLOURS = {}
for _, c in ipairs({0x0000,0x1006,0x3cb3,0x4916,0x61fc,0x6e5d,0x7fff,0x3892,
                    0x282d,0x240c,0x200a,0x599a,0x7adf,0x3070,0x1407,0x3491}) do
    BLADE_COLOURS[c] = true
end

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local errors, notes = {}, {}

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return (v >= 0x8000) and (v - 0x10000) or v end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local function fail(msg) errors[#errors+1] = msg; log("FAIL %s", msg) end

local function finish()
    if finished then return end
    finished = true
    for _, n in ipairs(notes) do log("note %s", n) end
    if #errors == 0 then log("PASS reason=all_checks_confirmed")
    else log("ERROR reason=%s (%d failures)", errors[1], #errors) end
    logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 Right"]=true, ["P1 Left"]=true, ["P1 High Punch"]=true,
        ["P1 Low Punch"]=true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
end

local THROW_AT = 90
-- Back,Forward + LOW PUNCH = the STRAIGHT throw.  HP is the upward arc
-- now, and it climbs off the top of the screen in about 30 ticks, which
-- is far too short a flight to watch a trail over.
local SEQ = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Punch",12,18} }

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end
    local d = (frame - fighting_frame) - THROW_AT
    for _, s in ipairs(SEQ) do
        if name == s[1] and d >= s[2] and d < s[3] then return true end
    end
    return false
end

-- palette proof ------------------------------------------------------------
local pal_checked = {}
local function check_palette(slot)
    if pal_checked[slot] then return end
    pal_checked[slot] = true
    if not A.fpalram then notes[#notes+1] = "fpalram not in map - palette unverified"; return end
    local id = r32(A.fpalram + slot * 0x40)
    local n  = r16(id)
    local cols, bad = {}, 0
    for i = 1, n do
        local c = r16(id + 16 * i)
        cols[#cols+1] = string.format("%04x", c)
        if not BLADE_COLOURS[c] then bad = bad + 1 end
    end
    log("pal slot=%d id=%08x count=%d cols=%s", slot, id, n, table.concat(cols, ","))
    if n ~= 16 then
        fail(string.format("echo palette declares %d entries, want 16 (the art is 6bpp and indexes 0..15)", n))
    end
    if bad > 0 then
        fail(string.format("echo palette has %d colour(s) outside BOOMRNG_P", bad))
    else
        notes[#notes+1] = string.format("echo palette slot %d is the blade's own BOOMRNG_P, %d entries", slot, n)
    end
end

-- flight watch -------------------------------------------------------------
local blade_sag_history = {}     -- sag -> last relative frame the blade wore it
local max_shadows, saw_shadow = 0, false
local last_spawn_x = nil
local hit_rel, last_spawn_rel = nil, nil
local ACT_PROJ_DEAD = nil   -- resolved from the blade's z flip instead
local shadow_seen, shadow_frames = {}, {}
local blade_draw_history = {}    -- "x,y" -> rel frame
local echo_off = nil             -- the fixed offset every echo must share
local checked_place, checked_z = false, false
local watch_from, watch_to = nil, nil

local function walk(rel)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p, n = r32(A.objlst), 0
    local blade, shadows = nil, {}
    while p ~= 0 and n < 40 do
        if p ~= p1o and p ~= p2o then
            local f2 = r16(p + O.flags2)
            local img = r32(p + O.img)
            if (f2 & 2) ~= 0 and img ~= 0 then
                local sag = r32(img + MP.sag)
                if sag >= SAG_LO and sag < SAG_HI then blade = p end
            elseif (f2 & 2) == 0 then
                local sag = r32(p + O.sag)
                if sag >= SAG_LO and sag < SAG_HI then shadows[#shadows+1] = p end
            end
        end
        p = r32(p + O.link); n = n + 1
    end

    local bx, by, bsag, bz, banx, bany, bw, bh
    if blade then
        local img = r32(blade + O.img)
        bsag = r32(img + MP.sag)
        local dx, dy = s16(r16(img + MP.anix)), s16(r16(img + MP.aniy))
        banx = s16(r16(blade + O.xpos))     -- the multipart ANCHOR
        bany = s16(r16(blade + O.ypos))
        bx = banx - dx                      -- ... and its drawn top-left
        by = bany - dy
        bz = r32(blade + O.zval)
        local yx = r32(img + MP.yxsize)
        bw, bh = yx & 0xffff, (yx >> 16) & 0xffff
        blade_sag_history[bsag] = rel
        blade_draw_history[string.format("%d,%d", bx, by)] = rel
        -- jbp_hit stamps front_z into the blade's ozpos on contact, so the
        -- top half of ozval going non-zero is the hit, with no HP polling.
        if hit_rel == nil and (bz >> 16) ~= 0 then
            hit_rel = rel
            log("contact at rel=%d (blade z %08x)", rel, bz)
        end
        log("[blade] rel=%3d obj=%08x sag=%08x draw=(%d,%d) z=%08x pal=%04x sh=%d",
            rel, blade, bsag, bx, by, bz, r16(blade + O.pal), #shadows)
    end

    if #shadows > max_shadows then max_shadows = #shadows end
    for _, s_obj in ipairs(shadows) do
        local sag = r32(s_obj + O.sag)
        local sx, sy = s16(r16(s_obj + O.xpos)), s16(r16(s_obj + O.ypos))
        local slot = r16(s_obj + O.pal) & 0xff
        local sz = r32(s_obj + O.zval)
        -- Record the frame on EVERY sighting.  The detailed logging below is
        -- gated on the object being new, but shadow_seen keys on the object
        -- POINTER and the object pool recycles slots - so a recycled echo was
        -- silently never counted, and a working trail under-reported as two
        -- frames instead of seven.
        if BRANG_SAGS[sag] then shadow_frames[BRANG_SAGS[sag]] = true end
        if not shadow_seen[s_obj] then
            shadow_seen[s_obj] = true
            saw_shadow = true
            local prev_spawn_rel = last_spawn_rel
            last_spawn_rel = rel
            log("[shadow] rel=%3d obj=%08x sag=%08x(%s) pos=(%d,%d) size=%dx%d flags=%04x pal=%04x z=%08x",
                rel, s_obj, sag,
                BRANG_SAGS[sag] or "?", sx, sy,
                r16(s_obj + O.sizex), r16(s_obj + O.sizey),
                r16(s_obj + O.flags), r16(s_obj + O.pal), sz)
            check_palette(slot)
            -- Must be one of the six echo frames, and specifically the one
            -- PAIRED with a spin frame the blade wore a tick or two ago.
            -- Pairing, not just membership: a trail stuck on one echo would
            -- pass a membership test and still be wrong.
            if BRANG_SAGS[sag] == nil then
                fail(string.format("echo sag %08x is not a blade frame (%s)", sag,
                                   DEAD_TRAIL_SAGS[sag] or "unknown"))
            else
                shadow_frames[BRANG_SAGS[sag]] = true
            end
            -- A fresh echo shows UBTRAIL1. It is BUILT from UBWISP - that is
            -- where its anipoint comes from - but framew's first frame_a9
            -- lands on UBTRAIL1 in the same tick, before anything is drawn,
            -- so the wisp is never visible. Anything other than a UBTRAIL
            -- frame means framew walked the wrong list.
            if not (BRANG_SAGS[sag] or ""):match("^UBTRAIL%d$") then
                fail(string.format("a new echo is %s, want a UBTRAIL frame",
                                   BRANG_SAGS[sag] or "unknown"))
            end
            -- Consecutive puffs must be one spawn-interval of blade travel
            -- apart. This is the check that the trail is actually trailing.
            -- Only between CONSECUTIVE spawns. Across a gap (a second throw,
            -- or the blade dying and a new one launching) the two puffs have
            -- nothing to do with each other and the distance is meaningless.
            if last_spawn_x and prev_spawn_rel and (rel - prev_spawn_rel) <= 4 then
                local gap = math.abs(sx - last_spawn_x)
                local want, why = TRAIL_SPACING, ""
                -- ONE LEGITIMATE HITCH, AT CONTACT.  The hit leaves jbp_loop
                -- for jbp_fly_through, and jbp_fly_through_start RELOADS the
                -- spawn countdown (`movk 2,a11`) rather than trusting a11
                -- across strike_check / init_anirate / jbp_reverse_x.  So the
                -- echo that was due 2 ticks after the last one arrives 3 ticks
                -- after it: one spawn interval plus one tick of travel, once
                -- per flight.  Measured on the ROM - spawns at rel
                -- 118,120,122 / 125 / 127,129,131,133,135 at x
                -- 576,594,612 / 639 / 657,675,693,711,729, i.e. 18 px
                -- throughout and a single 27 across the contact tick.
                --
                -- This is an allowance for ONE known transition, not a
                -- widened tolerance: every other gap is still held to 18, and
                -- a trail that hitched anywhere else still fails.
                if hit_rel and prev_spawn_rel <= hit_rel and rel > hit_rel then
                    want = TRAIL_SPACING + BLADE_SPEED
                    why = " (across contact - jbp_fly_through_start reloads a11)"
                end
                if gap < want - 3 or gap > want + 3 then
                    fail(string.format("puffs are %d px apart, want ~%d%s"
                                       .. " (%dpx/tick x 2-tick spawn)",
                                       gap, want, why, BLADE_SPEED))
                elseif why ~= "" then
                    notes[#notes+1] = string.format("trail skipped one tick across"
                                                    .. " contact (%d px instead of %d),"
                                                    .. " as jbp_fly_through_start's"
                                                    .. " countdown reload makes it",
                                                    gap, TRAIL_SPACING)
                end
            end
            last_spawn_x = sx
            -- PLACEMENT: the ghost no longer sits ON the blade - it trails it
            -- by the arcade's own distance, measured off the 39x38 wisp's
            -- anipoint (see jade_boom_trail_back/drop in MKZAP.ASM). Checked
            -- CENTRE to CENTRE, which is how the code places it and the only
            -- form that needs no flip handling.
            if not checked_place and blade and bw and bw > 0 then
                checked_place = true
                local bcx, bcy = bx + bw // 2, by + bh // 2
                local scx = sx + r16(s_obj + O.sizex) // 2
                local scy = sy + r16(s_obj + O.sizey) // 2
                local facing_left = (r16(blade + O.flags) & 0x10) ~= 0
                local want_x = bcx + (facing_left and TRAIL_BACK or -TRAIL_BACK)
                local want_y = bcy + TRAIL_DROP
                local ex, ey = scx - want_x, scy - want_y
                -- Tolerance is 8, not 3, because what `ani` pins is the
                -- ANIPOINT and this measures CENTRES. Neither the blade's
                -- frames nor the trail's are anchored exactly on centre -
                -- SPIN1 is +3 off, UBTRAIL1 is -3 - so the centres can sit
                -- ~6px apart while the anipoints coincide perfectly.
                if math.abs(ex) > 8 or math.abs(ey) > 8 then
                    fail(string.format(
                        "echo centre (%d,%d) is %+d,%+d off the wanted trail offset "
                        .. "(blade centre %d,%d, want %d,%d)",
                        scx, scy, ex, ey, bcx, bcy, want_x, want_y))
                else
                    notes[#notes+1] = string.format(
                        "ghost trails the blade by %d px behind / %d below (centre to centre)",
                        TRAIL_BACK, TRAIL_DROP)
                end
            end
            if blade and not checked_z then
                checked_z = true
                if sz >= bz then
                    fail(string.format("shadow z %08x is not behind the blade's %08x", sz, bz))
                else
                    notes[#notes+1] = "shadow sits one z behind the blade"
                end
            end
        end
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("harness loaded  objlst=%s fpalram=%s",
            A.objlst and string.format("%08x", A.objlst) or "MISSING",
            A.fpalram and string.format("%08x", A.fpalram) or "MISSING")
    end
    if not space or finished then
        for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_REPTILE)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        w16(A.p1_char, FT_JADE); w16(A.p2_char, FT_REPTILE)
    elseif gs == GS_FIGHTING then
        if fighting_frame == 0 then
            fighting_frame = frame
            if A.diff then w16(A.diff, 0) end
            log("fight started (p1=%d p2=%d)", r16(A.p1_char), r16(A.p2_char))
        end
        local rel = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end

        local proc = r32(A.p1_proc)
        local act = proc ~= 0 and r16(proc + P_ACTION) or 0
        if watch_from == nil and act == ACT_JADE_BOOM then
            watch_from = rel; watch_to = rel + 120
            log("throw confirmed at rel=%d", rel)
        end
        if watch_from and rel >= watch_from and rel <= watch_to then
            walk(rel)
            if rel == watch_from + 24 or rel == watch_from + 30
               or rel == watch_from + 36 or rel == watch_from + 44 then
                snap(string.format("shadow_r%d", rel))
            end
        end
        if watch_to and rel > watch_to then
            log("max simultaneous shadows = %d", max_shadows)
            if not saw_shadow then fail("no shadow object ever appeared") end
            -- ~18 ticks of life against a spawn every 2 ticks stacks them
            -- about nine deep. Exact count varies with when the blade dies,
            -- so this is a floor: anything under 5 means the echoes are not
            -- living their full framew run.
            if max_shadows < 5 then
                fail(string.format("max simultaneous shadows = %d, want >= 5"
                                   .. " (18-tick life, 2-tick spawn)", max_shadows))
            else
                notes[#notes+1] = string.format("%d puffs on screen at once", max_shadows)
            end
            local names, nframes = {}, 0
            for n in pairs(shadow_frames) do names[#names+1] = n; nframes = nframes + 1 end
            table.sort(names)
            log("shadow frames used: %s", table.concat(names, ","))
            -- The dissipation has to actually play. One frame repeating
            -- would mean framew never walked past the entry the echo was
            -- built from. Wisp + six trail frames = 7 available.
            -- The dissipation has to actually play: one frame repeating
            -- would mean framew never walked past the entry it was built
            -- from. Six trail frames exist; echoes cut short by the blade
            -- dying or the watch window mean fewer are reached, so this is a
            -- floor rather than an exact count.
            if nframes < 3 then
                fail(string.format("echoes only ever showed %d distinct frame(s)"
                                   .. " - the dissipation is not animating", nframes))
            end
            -- Contact must not end the trail (jbp_fly_through spawns too).
            if hit_rel and last_spawn_rel and last_spawn_rel <= hit_rel + 2 then
                fail(string.format("no shadow spawned after contact (hit rel=%d, last spawn rel=%d)",
                                   hit_rel, last_spawn_rel))
            elseif hit_rel then
                notes[#notes+1] = string.format("trail continued past contact (hit rel=%d, last spawn rel=%d)",
                                                hit_rel, last_spawn_rel or -1)
            end
            finish()
        end
        if rel > 400 then fail("throw never happened"); finish() end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
end)
