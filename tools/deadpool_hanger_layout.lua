-- deadpool_hanger_layout.lua
--
-- THE DEAD POOL hanger LAYOUT EDITOR.  Drives a 2-player idle match onto the
-- Dead Pool, then hands you the nine hanging bodies: pick one, move it with
-- the arrows, pan the camera across the whole acid, and save.  The saved file
-- (tools/hanger_layout.txt) is what gets plugged into hanger_initab
-- (src/MKHANG.ASM).
--
-- It works because hanger_coords (MKHANG.ASM, RAM) is read EVERY TICK by
-- hp_compute_base_x / hp_place_y while a body hangs, so writing it moves the
-- body, its chain and its hook live.  x is the body's LEFT edge, y its TOP,
-- both in stage-world pixels - the same numbers hanger_initab carries.
--
-- Drops are held off the whole time (hp_next_drop_ticks kept high), the round
-- timer is frozen and both life bars pinned full, so the match never ends.
--
-- ON SCREEN
--   yellow box   the camera's view when FIGHT appears (captured in the round
--                intro, not assumed) - what the player sees at the start
--   cyan box     the selected body; white boxes the others; RED means he is
--                off the acid (195..947) or his feet are below the 186 line
--   bottom strip the WHOLE acid in miniature: every body, the FIGHT view
--                (yellow) and what the camera shows now (green)
--
-- KEYS
--   1-9 or [ ]   pick a body (numbers are hanger_initab order, shown on screen)
--   arrows       move him 1px; hold to speed up.  (The arrows also reach P1 -
--                harmless, both fighters are pinned in place.)
--   PgUp / PgDn  pan the camera left / right
--   End          bring the camera to the selected body
--   Home         camera back to the FIGHT view
--   Backspace    put the selected body back where the ROM has him
--   F            show / hide the two fighters (hidden: they would stand in
--                front of the bodies; they are only there to steer the camera)
--   Enter        SAVE -> tools/hanger_layout.txt
--
-- A saved layout is loaded again on the next run, so you can pick up where you
-- left off.  Unsaved changes are written to tools/hanger_layout_autosave.txt
-- when MAME closes.
--
-- Env: HL_ROOT (repo), HL_READY (launcher handshake), HL_P1_CHAR/HL_P2_CHAR.

local ROOT = (os.getenv("HL_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local READY_PATH = os.getenv("HL_READY")
local SAVE_PATH = os.getenv("HL_SAVE") or (ROOT .. "/tools/hanger_layout.txt")
-- HL_AUTOTEST=1: no keyboard - move a body, pan, snapshot, save, quit (a rig)
local AUTOTEST = os.getenv("HL_AUTOTEST") == "1"
local AUTOSAVE_PATH = ROOT .. "/tools/hanger_layout_autosave.txt"

local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function log(fmt, ...) print("[layout] " .. string.format(fmt, ...)) end

--------------------------------------------------------------------------
-- the bodies, straight out of hanger_initab
--------------------------------------------------------------------------

local H = {}            -- [i] = { name=, rom_x=, rom_y=, x=, y= }  (i = 0..8)
local NH = 0
do
    local fh = io.open(ROOT .. "/src/MKHANG.ASM", "r")
    local inside, pending = false, nil
    if fh then
        for line in fh:lines() do
            if line:match("^hanger_initab") then inside = true
            elseif inside then
                local lab = line:match("^%s+%.long%s+a_(%w+)hang1_full")
                if lab then pending = lab:upper() end
                local x, y = line:match("^%s+%.word%s+(%-?%d+)%s*,%s*(%-?%d+)")
                if x and pending then
                    H[NH] = { name = pending, rom_x = tonumber(x), rom_y = tonumber(y) }
                    H[NH].x, H[NH].y = H[NH].rom_x, H[NH].rom_y
                    NH = NH + 1
                    pending = nil
                end
                if NH > 0 and line:match("^%S") and not line:match("^%*") then break end
            end
        end
        fh:close()
    end
end

-- the acid, and the line his feet must stay above (BGND.ASM / MKHANG.ASM)
local ACID_L, ACID_R, FEET_MAX = 195, 947, 186
do
    local fh = io.open(ROOT .. "/src/BGND.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n = line:match("^dp_acid_raw_lft%s+%.equ%s+(%d+)")
            if n then ACID_L = tonumber(n) end
            n = line:match("^dp_acid_raw_rgt%s+%.equ%s+(%d+)")
            if n then ACID_R = tonumber(n) end
        end
        fh:close()
    end
end

-- a saved layout overrides the ROM's, so a session can be resumed
local loaded_file = false
do
    local fh = io.open(SAVE_PATH, "r")
    if fh then
        for line in fh:lines() do
            local name, x, y = line:match("^(%u+)%s+(%-?%d+)%s+(%-?%d+)%s*$")
            if name then
                for i = 0, NH - 1 do
                    if H[i].name == name then
                        H[i].x, H[i].y = tonumber(x), tonumber(y); loaded_file = true
                    end
                end
            end
        end
        fh:close()
    end
end

--------------------------------------------------------------------------
-- symbols
--------------------------------------------------------------------------

local symbols, missing = {}, {}
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
local function sym(n)
    local v = symbols[n]; if v == nil then missing[#missing + 1] = n; return 0 end; return v
end
local function sym_opt(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    worldtlx = sym("worldtlx"), worldtly = sym("worldtly"),
    hanger_coords = sym("hanger_coords"),
    hp_body_ptr = sym("hp_body_ptr"),
    hp_next_drop_ticks = sym("hp_next_drop_ticks"),
    -- The editor places ALL NINE, but a match only hangs three
    -- (hp_pick_lineup).  A forced lineup of everybody puts the other six back
    -- on their hooks for as long as the editor is up, and leaves the
    -- rotation's own state untouched.
    hp_lineup_force = sym_opt("hp_lineup_force"),
    f_freeze_timer = sym_opt("f_freeze_timer"),
    -- A CORNER body ignores hp_next_drop_ticks: he goes once he has been in
    -- view side_view_ticks in a row (MKHANG.ASM), so that count is pinned too.
    hp_view_ticks = sym_opt("hp_view_ticks"),
}
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, oflags2 = 0x160, oimg = 0x1a0 }
local M_INVISO = 0x0020   -- DISPEQU m_inviso, in oflags2
local MP = { sag = 0, sizex = 32, sizey = 48, anix = 80, aniy = 96, length = 112 }
local GS_PSEL, GS_FIGHTING, GS_PFSETUP, GS_INTRO = 4, 2, 6, 7
local FT_P1 = tonumber(os.getenv("HL_P1_CHAR") or "") or 1
local FT_P2 = tonumber(os.getenv("HL_P2_CHAR") or "") or 11
local STAGE_DEADPOOL = 0

local cpu, space, screen, input = nil, nil, nil, nil
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) if a ~= 0 then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if a ~= 0 then space:write_u32(a, v & 0xffffffff) end end

--------------------------------------------------------------------------
-- boot: coin up, 2 players, force the pair and THE DEAD POOL
--------------------------------------------------------------------------

local frame, charsel_frame, fight_frame, confirm_at = 0, 0, 0, 0
local fields = {}
local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                     ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
end
local function boot_pressed(name)
    if fight_frame > 0 then return false end
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    elseif confirm_at > 0 then
        if name == "P1 High Punch" then return frame >= confirm_at and frame < confirm_at + 40 end
        if name == "P2 High Punch" then return frame >= confirm_at + 80 and frame < confirm_at + 120 end
    end
    return false
end

--------------------------------------------------------------------------
-- the editor
--------------------------------------------------------------------------

local sel = 0
local live = false             -- hangers exist and we own their coords
local fight_tlx, fight_tly = nil, nil
local cam_pin = nil            -- world x the camera is being steered to (centre)
local dirty, saved_msg_until, saved_msg = false, 0, ""
local held = {}

local function key(tok)
    local code = input:code_from_token(tok)
    return code and input:code_pressed(code)
end
-- press = fires once, then repeats: every frame after 12, 3 px a frame after 50
local function hold_step(tok)
    if key(tok) then
        held[tok] = (held[tok] or 0) + 1
        local n = held[tok]
        if n == 1 then return 1 end
        if n > 50 then return 3 end
        if n > 12 then return 1 end
        return 0
    end
    held[tok] = 0
    return 0
end
local function pressed_once(tok)
    if key(tok) then
        held[tok] = (held[tok] or 0) + 1
        return held[tok] == 1
    end
    held[tok] = 0
    return false
end

local function cam_left() return s16(r16(A.worldtlx + 16)) end
local function cam_top() return s16(r16(A.worldtly + 16)) end

-- a body's real drawn extent, from its pieces: each is drawn at
-- oxpos - anix, oypos - aniy (DISPEQU mp_anix/mp_aniy)
local function body_bounds(i)
    local obj = r32(A.hp_body_ptr + i * 32)
    if obj == 0 then return nil end
    local ox, oy = s16(r16(obj + O.oxpos)), s16(r16(obj + O.oypos))
    local mp = r32(obj + O.oimg)
    if mp == 0 then return nil end
    local l, t, r, b
    for _ = 1, 32 do
        if r32(mp + MP.sag) == 0 then break end
        local pl = ox - s16(r16(mp + MP.anix))
        local pt = oy - s16(r16(mp + MP.aniy))
        local pr, pb = pl + r16(mp + MP.sizex), pt + r16(mp + MP.sizey)
        l = l and math.min(l, pl) or pl; t = t and math.min(t, pt) or pt
        r = r and math.max(r, pr) or pr; b = b and math.max(b, pb) or pb
        mp = mp + MP.length
    end
    if not l then return nil end
    return l, t, r, b
end

local function write_coords()
    for i = 0, NH - 1 do
        w16(A.hanger_coords + i * 32, H[i].x)
        w16(A.hanger_coords + i * 32 + 16, H[i].y)
    end
end

local function pin_fighters(cx)
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return end
    local ax, bx = cx - 40, cx + 40
    w16(a + O.oxpos, ax); w32(a + O.oxval, ax << 16)
    w16(b + O.oxpos, bx); w32(b + O.oxval, bx << 16)
end
-- the fighters steer the camera but would stand in front of the bodies:
-- hidden while editing (F toggles them back)
local show_fighters = false
local function hide_fighters()
    for _, p in ipairs({ A.p1_obj, A.p2_obj }) do
        local o = r32(p)
        if o ~= 0 then
            local f = r16(o + O.oflags2)
            w16(o + O.oflags2, show_fighters and (f & ~M_INVISO) or (f | M_INVISO))
        end
    end
end

local function layout_text(header)
    local out = { header,
        "# name  x  y   (x = left edge, y = top; stage-world pixels)" }
    for i = 0, NH - 1 do
        out[#out + 1] = string.format("%-6s %d %d", H[i].name, H[i].x, H[i].y)
    end
    out[#out + 1] = ""
    out[#out + 1] = "# as hanger_initab (src/MKHANG.ASM):"
    for i = 0, NH - 1 do
        out[#out + 1] = string.format("#\t.long\ta_%shang1_full", H[i].name:lower())
        out[#out + 1] = string.format("#\t.word\t%d,%d", H[i].x, H[i].y)
    end
    if fight_tlx then
        out[#out + 1] = ""
        out[#out + 1] = string.format("# FIGHT view: world x %d..%d, y %d..%d",
            fight_tlx, fight_tlx + 399, fight_tly, fight_tly + 253)
    end
    return table.concat(out, "\n") .. "\n"
end

local function save(path, header)
    local fh = io.open(path, "w")
    if not fh then return false end
    fh:write(layout_text(header)); fh:close()
    return true
end

local function handle_keys()
    if AUTOTEST then return end
    for n = 1, math.min(9, NH) do
        if pressed_once("KEYCODE_" .. n) then sel = n - 1 end
    end
    if pressed_once("KEYCODE_OPENBRACE") then sel = (sel - 1) % NH end
    if pressed_once("KEYCODE_CLOSEBRACE") then sel = (sel + 1) % NH end

    local dx = hold_step("KEYCODE_RIGHT") - hold_step("KEYCODE_LEFT")
    local dy = hold_step("KEYCODE_DOWN") - hold_step("KEYCODE_UP")
    if dx ~= 0 or dy ~= 0 then
        H[sel].x, H[sel].y = H[sel].x + dx, H[sel].y + dy
        dirty = true
        -- keep him on screen: steer the camera if he walks off it
        local l = cam_left()
        if H[sel].x < l + 20 or H[sel].x > l + 360 then cam_pin = H[sel].x + 20 end
    end
    if pressed_once("KEYCODE_F") then show_fighters = not show_fighters end
    if pressed_once("KEYCODE_BACKSPACE") then
        H[sel].x, H[sel].y = H[sel].rom_x, H[sel].rom_y; dirty = true
    end

    local pan = hold_step("KEYCODE_PGDN") - hold_step("KEYCODE_PGUP")
    if pan ~= 0 then cam_pin = (cam_pin or (cam_left() + 200)) + pan * 6 end
    if pressed_once("KEYCODE_END") then cam_pin = H[sel].x + 20 end
    if pressed_once("KEYCODE_HOME") and fight_tlx then cam_pin = fight_tlx + 200 end
    if cam_pin then cam_pin = math.max(ACID_L - 100, math.min(ACID_R + 100, cam_pin)) end

    if pressed_once("KEYCODE_ENTER") then
        if save(SAVE_PATH, "# THE DEAD POOL hanger layout - saved by tools/deadpool_hanger_layout.lua") then
            dirty = false; saved_msg = "SAVED tools/hanger_layout.txt"
            log("saved %s", SAVE_PATH)
        else
            saved_msg = "SAVE FAILED: " .. SAVE_PATH
        end
        saved_msg_until = frame + 150
    end
end

--------------------------------------------------------------------------
-- drawing (emulated-screen pixels, 400 x 254)
--------------------------------------------------------------------------

local C = { fight = 0xffffe000, sel = 0xff00ffff, other = 0xc0ffffff, bad = 0xffff3030,
            cam = 0xff40ff40, acid = 0xff40c040, text = 0xffffffff, bg = 0xc0000000,
            mapbg = 0xa0000000 }

local function outline(x1, y1, x2, y2, col)
    screen:draw_line(x1, y1, x2, y1, col); screen:draw_line(x2, y1, x2, y2, col)
    screen:draw_line(x2, y2, x1, y2, col); screen:draw_line(x1, y2, x1, y1, col)
end

local function bad_spot(i, l, r, b)
    if l and (l < ACID_L or r > ACID_R) then return "off the acid" end
    if b and b > FEET_MAX then return "feet below " .. FEET_MAX end
    return nil
end

local function draw()
    if not live then
        screen:draw_text(4, 4, "layout editor: waiting for THE DEAD POOL...", C.text, C.bg)
        return
    end
    local cl, ct = cam_left(), cam_top()

    -- the FIGHT view
    if fight_tlx then
        local x1, y1 = fight_tlx - cl, fight_tly - ct
        outline(x1, y1, x1 + 399, y1 + 253, C.fight)
        outline(x1 + 1, y1 + 1, x1 + 398, y1 + 252, C.fight)
        screen:draw_text(math.max(2, math.min(330, x1 + 3)), 200, "FIGHT view", C.fight, C.bg)
    end

    -- the bodies
    local bounds = {}
    for i = 0, NH - 1 do
        local l, t, r, b = body_bounds(i)
        bounds[i] = { l, t, r, b }
        local col = (i == sel) and C.sel or C.other
        if bad_spot(i, l, r, b) then col = C.bad end
        if l then
            outline(l - cl, t - ct, r - cl, b - ct, col)
            if i == sel then outline(l - cl - 1, t - ct - 1, r - cl + 1, b - ct + 1, col) end
            screen:draw_text(l - cl + 1, b - ct + 1, string.format("%d %s", i + 1, H[i].name), col, C.bg)
        end
    end

    -- the whole acid in miniature
    local mx0, mx1, my0, my1 = 8, 392, 214, 252
    local wl, wr = ACID_L - 40, ACID_R + 40
    local sx = (mx1 - mx0) / (wr - wl)
    local sy = (my1 - my0) / 254
    local function mx(x) return mx0 + (x - wl) * sx end
    local function my(y) return my0 + y * sy end
    screen:draw_box(mx0, my0, mx1, my1, C.mapbg, C.mapbg)
    screen:draw_line(mx(ACID_L), my(FEET_MAX), mx(ACID_R), my(FEET_MAX), C.acid)
    if fight_tlx then outline(mx(fight_tlx), my0, mx(fight_tlx + 399), my1, C.fight) end
    outline(mx(cl), my0 + 1, mx(cl + 399), my1 - 1, C.cam)
    for i = 0, NH - 1 do
        local l, t, r, b = table.unpack(bounds[i])
        if l then
            local col = (i == sel) and C.sel or C.other
            if bad_spot(i, l, r, b) then col = C.bad end
            screen:draw_box(mx(l), my(t), mx(r), my(b), col, col)
        end
    end

    -- the status line
    local l, t, r, b = table.unpack(bounds[sel])
    local why = bad_spot(sel, l, r, b)
    local line = string.format("%d %s  x=%d y=%d%s%s", sel + 1, H[sel].name, H[sel].x, H[sel].y,
        (H[sel].x ~= H[sel].rom_x or H[sel].y ~= H[sel].rom_y)
            and string.format("  (ROM %d,%d)", H[sel].rom_x, H[sel].rom_y) or "",
        why and ("  ! " .. why) or "")
    screen:draw_text(4, 42, line, why and C.bad or C.sel, C.bg)
    screen:draw_text(4, 51, "1-9/[ ] pick  arrows move  PgUp/PgDn pan  End=him  Home=FIGHT  Bksp=ROM  F=fighters  Enter=SAVE"
        .. (dirty and "  *unsaved*" or ""), C.text, C.bg)
    if frame < saved_msg_until then screen:draw_text(4, 60, saved_msg, C.fight, C.bg) end
end

--------------------------------------------------------------------------
-- the frame
--------------------------------------------------------------------------

emu.register_frame(function()
    frame = frame + 1
    if space and A.hp_lineup_force then
        space:write_u16(A.hp_lineup_force, (1 << NH) - 1)
    end
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        input = manager.machine.input
        for _, s in pairs(manager.machine.screens) do screen = s; break end
        cache_fields()
        if #missing > 0 then log("FATAL missing symbols: %s", table.concat(missing, " ")) end
        log("%d bodies from hanger_initab%s", NH, loaded_file and " (positions from tools/hanger_layout.txt)" or "")
    end
    if frame == 30 and READY_PATH then
        local fh = io.open(READY_PATH, "w"); if fh then fh:write("1"); fh:close() end
    end
    if not space or #missing > 0 then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if fight_frame == 0 then
        w16(A.p1_char, FT_P1); w16(A.p2_char, FT_P2); w16(A.curback, STAGE_DEADPOOL)
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        if charsel_frame > 0 and confirm_at == 0 and frame > charsel_frame + 90 then
            confirm_at = frame + 25
        end
        if gs == GS_FIGHTING then fight_frame = frame; log("fight frame=%d", frame) end
    end
    for name, f in pairs(fields) do f:set_value(boot_pressed(name) and 1 or 0) end

    -- hangers exist from the pre-fight setup on; the ROM copies hanger_initab
    -- into hanger_coords there, and from then on the coords are ours
    if r16(A.curback) == STAGE_DEADPOOL and (gs == GS_PFSETUP or gs == GS_INTRO or gs == GS_FIGHTING)
        and r32(A.hp_body_ptr) ~= 0 then
        if not live then live = true; log("hangers live gs=%d", gs) end
        -- THE FIGHT VIEW: where the camera sits while FIGHT is on screen
        if gs == GS_INTRO then fight_tlx, fight_tly = cam_left(), cam_top() end
        write_coords()
        w16(A.hp_next_drop_ticks, 30000)          -- nobody goes in
        if A.hp_view_ticks then
            for i = 0, NH - 1 do w16(A.hp_view_ticks + i * 16, 0) end
        end
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
        if gs == GS_FIGHTING and AUTOTEST then
            local t = frame - fight_frame
            if t == 60 then manager.machine.video:snapshot() end
            if t == 70 then sel = 8; H[8].x = H[8].x + 40; H[8].y = H[8].y + 20; dirty = true end
            if t == 90 then manager.machine.video:snapshot() end
            if t == 100 then sel = 1; cam_pin = H[1].x + 20 end
            if t == 400 then manager.machine.video:snapshot() end
            if t == 410 then
                save(SAVE_PATH, "# autotest"); dirty = false
                log("AUTOTEST cam_left=%d fight=%s,%s eric=%d,%d", cam_left(),
                    tostring(fight_tlx), tostring(fight_tly), r16(A.hanger_coords + 8 * 32),
                    r16(A.hanger_coords + 8 * 32 + 16))
                manager.machine:exit()
            end
        end
        if gs == GS_FIGHTING then
            handle_keys()
            if cam_pin then pin_fighters(cam_pin) end
            hide_fighters()
        end
    end
end)

emu.register_frame_done(function()
    if screen and space and #missing == 0 then draw() end
end)

emu.register_stop(function()
    if dirty then
        save(AUTOSAVE_PATH, "# UNSAVED layout at exit - tools/deadpool_hanger_layout.lua")
        print("[layout] unsaved changes written to " .. AUTOSAVE_PATH)
    end
end)

log("Dead Pool hanger layout editor loaded")
