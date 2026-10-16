-- Runtime proof for Noob Saibot's REAL slide - Sub-Zero's move on Sub-Zero's
-- input (Away + LP+BL+LK held), not the D,B+LK shadow slide.
--
-- Three things have to be true and only the first is obvious:
--
--   1. the move FIRES at all - slide_check is reachable from Noob's low kick,
--      low punch and block handlers (char_lo_punch / char_block slot 15 used
--      to be `sucide`), so p_action reaches act_slide
--   2. NOOB HIMSELF travels and NOOB HIMSELF shows NJSLIDE art.  This is the
--      one that catches the animation-row bug: do_slide reads TABLE2 row 0,
--      which for Noob is Scorpion's spear throw, so without slide_ani2 he
--      slides the length of the floor holding a spear pose.  Matching the
--      SAGs against MKNJ.TBL's NJSLIDE records is what proves the row.
--   3. it connects - nj_strikes 012h (stk_slide) applies to ochar 15 already,
--      so the victim must lose health.
--
-- Same shape as tools/noob_moves_test.lua (which covers the shadow moves).
-- All addresses are TMS34010 BIT units.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("NOOB_SLIDE_LOG") or (ROOT .. "/tools/noob_slide_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[slide] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
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
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    p1_proc = sym("p1_proc"),
}
local P_ACTION = 0x100 + 0xf0
local OIMG, MP_LEN, OXPOS = 0x1a0, 0x70, 0x90
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_NOOB, FT_JAX, MAX_HP = 10, 15, 11, 0x00a1
local ACT_SLIDE, ACT_SLIDE_SD = 0x020c, 0x060a

-- SAG -> frame name for every NJSLIDE record in MKNJ.TBL.
local sag_name, marker_count = {}, 0
do
    local fh = assert(io.open(ROOT .. "/src/MKNJ.TBL", "r"), "missing src/MKNJ.TBL")
    local label
    for line in fh:lines() do
        local l = line:match("^%s*(NJSLIDE%d%u):")
        if l then label = l end
        local sag = label and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
        if sag then
            sag_name[tonumber(sag, 16) & 0x00ffffff] = label
            marker_count = marker_count + 1
            label = nil
        end
    end
    fh:close()
end

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, vs_frame, confirm_frame, fighting_frame = 0, 0, 0, 0
local last_gstate, last_action = -1, -1
local R = {}

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    for _, k in ipairs({ "fired", "frames", "noob_travel", "damage", "sd_seen" }) do
        log("  %-14s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Punch"]=true, ["P1 Low Kick"]=true,
        ["P1 Block"]=true, ["P1 Left"]=true, ["P1 Right"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

-- Noob's OWN object, not a projectile: the whole point is that he moves.
local function noob_frame()
    local obj = r32(A.p1_obj); if obj == 0 then return nil end
    local image = r32(obj + OIMG); if image == 0 then return nil end
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        if sag_name[sag] then return sag_name[sag] end
    end
    return nil
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

-- Away + LP + BL + LK.  P1 stands on the left facing right, so Away = Left.
-- The stick goes first and stays down (is_stick_away is read live), then the
-- three buttons stagger on so that whichever one lands last runs the detector
-- with the other two already held - which is how a player rolls his hand
-- across the buttons.
local SEQ = {
    { 0, 60, "P1 Left" },
    { 6, 60, "P1 Low Punch" },
    { 9, 60, "P1 Block" },
    { 12, 60, "P1 Low Kick" },
}
local RETRY_AFTER, MAX_TRIES = 70, 8
local SPACING = 200
local WATCH = 130
local tries, fired, move_start = 0, false, 0
local seen, noob_x0, jax_hp0, travel, sd_seen = {}, nil, nil, 0, false

local function place_noob()
    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
    w16(r32(A.p1_obj) + OXPOS, (jx - SPACING) & 0xffff)
end

local function pressed(name)
    local rel = frame - move_start
    for _, w in ipairs(SEQ) do
        if w[3] == name and rel >= w[1] and rel < w[2] then return true end
    end
    return false
end

local function report()
    local names = {}
    for n, _ in pairs(seen) do names[#names+1] = n end
    table.sort(names)
    R.frames = #names > 0 and table.concat(names, ",") or "NONE"
    R.noob_travel = travel
    R.damage = jax_hp0 - r16(A.p2_bar)
    R.sd_seen = sd_seen
    snap("slide")
    local ok = R.fired and #names > 0 and travel >= 40 and R.damage > 0
    finish(ok, ok and "slide_fired_travelled_and_connected" or "see_field_report")
end

-- Boot driver: attract -> coin -> start -> character select.  Copied from
-- tools/noob_moves_test.lua, which is the schedule this ROM is known to boot
-- on.  Once the move phase owns the pad, `pressed` takes over.
local function drive_inputs()
    for name, field in pairs(fields) do
        local on = false
        if name == "UI Select" then on = frame >= 5 and frame < 35
        elseif name == "Coin 1" then on = frame >= 700 and frame < 980 and frame % 80 < 20
        elseif name == "1 Player Start" then on = frame >= 1000 and frame < 1080
        elseif name == "P1 High Punch" and charsel_frame > 0 and fighting_frame == 0 then
            on = confirm_frame > 0 and frame >= confirm_frame and frame < confirm_frame + 45
        elseif tries > 0 and not fired then
            on = pressed(name)
        end
        field:set_value(on and 1 or 0)
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded %d NJSLIDE markers", marker_count)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d p1=%d p2=%d", frame, last_gstate, gs,
            r16(A.p1_char), r16(A.p2_char))
        last_gstate = gs
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        -- Noob has no grid portrait; confirm a visible ninja, then swap the
        -- fighter slot during post-select, the way the shadow-move harness does.
        w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        if vs_frame == 0 then vs_frame = frame end
        w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
    end

    if fighting_frame > 0 then
        w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
        if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end
    end

    if fighting_frame == 0 or frame - fighting_frame < 150 then drive_inputs() return end
    if r16(A.p1_char) ~= FT_NOOB then finish(false, "p1_not_noob") return end

    if tries == 0 then
        tries, move_start = 1, frame
        place_noob()
        noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
        jax_hp0 = r16(A.p2_bar)
        log("--- attempt 1 at frame %d, noob x=%d jax hp=%d", frame, noob_x0, jax_hp0)
    end

    local rel = frame - move_start
    local proc = A.p1_proc and r32(A.p1_proc) or 0
    local act = proc ~= 0 and r16(proc + P_ACTION) or 0
    if act ~= last_action then
        log("  [rel=%3d] p_action %04x -> %04x", rel, last_action, act)
        last_action = act
    end

    if not fired then
        if act == ACT_SLIDE then
            fired, R.fired = true, true
            move_start = frame
            noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
            jax_hp0 = r16(A.p2_bar)
            log("  act_slide on try %d (noob x=%d jax hp=%d)", tries, noob_x0, jax_hp0)
        elseif rel >= RETRY_AFTER then
            tries = tries + 1
            if tries > MAX_TRIES then
                R.fired = false
                finish(false, "slide_never_fired")
                return
            end
            move_start = frame
            place_noob()
            log("  no act_slide after %d frames, retry %d", RETRY_AFTER, tries)
        end
        drive_inputs()
        return
    end

    -- Let go of everything once it is running: the slide owns him now.
    for _, f in pairs(fields) do f:set_value(0) end

    local n = noob_frame()
    if n then
        -- Snapshot the slide WHILE it is running.  The end-of-window shot
        -- lands after recovery and shows a standing ninja, which proves
        -- nothing about the art.
        if next(seen) == nil then snap("slide_start") end
        if rel == 8 then snap("slide_mid") end
        if rel == 18 then snap("slide_late") end
        seen[n] = true
    end
    if act == ACT_SLIDE_SD then sd_seen = true end
    local nx = s16(r16(r32(A.p1_obj) + OXPOS))
    if math.abs(nx - noob_x0) > travel then travel = math.abs(nx - noob_x0) end

    if rel >= WATCH then report() end
    if frame > 12000 then finish(false, "global_timeout") end
end)
