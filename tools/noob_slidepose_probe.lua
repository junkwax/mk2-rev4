-- Focused probe for Noob Saibot's shadow-slide POSE + the victim's reaction.
--
-- The main harness (noob_moves_test.lua) proves the shadow spawns and travels;
-- it does not say what NOOB himself is drawing, because it only resolves
-- NOOBFX.TBL SAGs.  This one loads MKNJ.TBL too, so it can name Noob's own
-- frames (NJROUNDKIK1/2, NJSLIDE1/2/3, ...) and print the victim's oypos every
-- frame - the two things the "roundhouse pose + vertical pop" change is about.
--
-- Everything else is lifted from noob_moves_test.lua unchanged.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("NOOB_TEST_LOG") or (ROOT .. "/tools/noob_slidepose_probe.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[pose] " .. string.format(fmt, ...)
    raw_print(line); logfh:write(line, "\n"); logfh:flush()
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
local function sym(n, fb) return symbols[n] or fb end

local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    objlst = sym("objlst"), p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    ground_y = sym("ground_y"), active = sym("active"),
    worldtlx = sym("worldtlx"),
}
local P_ACTION = 0x100 + 0xf0
local OIMG, MP_LEN, ONEXT, OXPOS, OYPOS = 0x1a0, 0x70, 0x00, 0x90, 0xb0
local OSAG, OID = 0x100, 0x1c0
local PLINK, PROCID = 0x00, 0x20
local PID_1_PUFF = 0x19
local OXVEL, OYVEL = 0x40, 0x60
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_NOOB, FT_JAX, MAX_HP = 10, 15, 11, 0x00a1

-- SAG -> frame name, from both tables.  MKNJ.TBL names Noob's own body,
-- NOOBFX.TBL names the shadow.
local sag_name = {}
local function load_tbl(path, pat)
    local fh = io.open(ROOT .. path, "r")
    if not fh then log("MISSING %s", path); return 0 end
    local label, n = nil, 0
    for line in fh:lines() do
        local l = line:match(pat)
        if l then label = l end
        local sag = label and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
        if sag then
            sag_name[tonumber(sag, 16) & 0x00ffffff] = label
            n = n + 1; label = nil
        end
    end
    fh:close()
    return n
end

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, vs_frame, confirm_frame, fighting_frame = 0, 0, 0, 0
local last_gstate = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true, ["P1 High Kick"]=true,
        ["P1 Left"]=true, ["P1 Right"]=true, ["P1 Up"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

-- All frame names an object's multipart chain is showing, in lane order.
local function obj_frames(obj)
    if obj == 0 then return nil end
    local image = r32(obj + OIMG); if image == 0 then return nil end
    local out = {}
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        out[#out+1] = sag_name[sag] or string.format("?%06x", sag)
    end
    return #out > 0 and table.concat(out, "+") or nil
end

-- First non-fighter object showing a NOOBSLIDE frame: the shadow.
local function find_shadow()
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frames(obj)
            if n and n:sub(1, 9) == "NOOBSLIDE" then
                return n, s16(r16(obj + OXPOS))
            end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return nil
end

-- obj_frames only works for MULTIPART objects: their oimg points at multipart
-- RAM whose first long per lane IS the sag.  A SINGLE-part object's oimg
-- points at the IMG record in ROM, where the first long is the packed w,h -
-- so puffs have to be identified off the object's own osag instead.
local function obj_sag_name(obj)
    if obj == 0 then return nil end
    return sag_name[r32(obj + OSAG) & 0x00ffffff]
end

-- Live processes carrying pid_1_puff, straight off the active list.
local function count_puff_procs()
    if not A.active then return -1 end
    local p, guard, n = r32(A.active), 0, 0
    while p ~= 0 and guard < 256 do
        if (r16(p + PROCID) & 0xffff) == PID_1_PUFF then n = n + 1 end
        p = r32(p + PLINK); guard = guard + 1
    end
    return n
end

-- Every non-fighter object with its oid + resolved sag, for one frame.
local function dump_objects(tag)
    if not A.objlst then return end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 64 do
        if obj ~= p1 and obj ~= p2 then
            log("    %s obj=%08x oid=%04x sag=%06x name=%s", tag, obj,
                r16(obj + OID), r32(obj + OSAG) & 0xffffff,
                tostring(obj_sag_name(obj) or obj_frames(obj)))
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
end

-- How many PUFF objects are on the object list right now.
local function count_puffs()
    if not A.objlst then return 0 end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard, n = r32(A.objlst), 0, 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local f = obj_sag_name(obj) or obj_frames(obj)
            if f and f:sub(1, 4) == "PUFF" then n = n + 1 end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return n
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local ACT_SHADOW = 0x0116
local RETRY_AFTER, MAX_TRIES = 50, 8
local SEQ = { {0, 4, "P1 Down"}, {6, 10, "P1 Left"}, {12, 18, "P1 Low Kick"} }
local WATCH = 150
local SLIDE_STOP = 8        -- must match NOOB_SLIDE_STOP in MKZAP.ASM
local SPACING = 250         -- long runway: connect, then run on to the stop line

local move_start, tries, fired = 0, 0, false
local started = false
local last_vpose = nil
local puff_peak, puff_prev, puff_last_rel = 0, -1, -1
local puffproc_prev = -99
local shadow_prev_x = nil
local shadow_first_x, shadow_last_x, shadow_last_rel = nil, nil, nil
local shadow_hit_x, shadow_gone_rel = nil, nil
local last_pose, jax_y0, jax_x0, jax_hp0 = nil, nil, nil, nil

local function place_noob()
    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
    w16(r32(A.p1_obj) + OXPOS, (jx - SPACING) & 0xffff)
end

local function move_pressed(name)
    if not started or fired then return false end
    local rel = frame - move_start
    for _, w in ipairs(SEQ) do
        if w[3] == name and rel >= w[1] and rel < w[2] then return true end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        local a = load_tbl("/src/MKNJ.TBL", "^%s*(NJ[%u%d]+):")
        local b = load_tbl("/src/NOOBFX.TBL", "^%s*(NOOB[%u%d]+):")
        local c = load_tbl("/src/MKJX.TBL", "^%s*(JX[%u%d]+):")
        local d = load_tbl("/src/MKFX.TBL", "^%s*(PUFF[%d]+):")
        log("loaded %d NJ + %d NOOBFX + %d JX + %d PUFF markers", a, b, c, d)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
        last_gstate = gs
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        if vs_frame == 0 then vs_frame = frame end
        w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
    end

    if fighting_frame > 0 then
        w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
        if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end
    end

    if fighting_frame > 0 and not started and frame - fighting_frame >= 150 then
        if r16(A.p1_char) ~= FT_NOOB then finish(false, "p1_not_noob") return end
        started, move_start, tries, fired = true, frame, 1, false
        place_noob()
        log("--- slide probe begins at frame %d", frame)
    end

    if started then
        local rel = frame - move_start
        if not fired then
            local proc = A.p1_proc and r32(A.p1_proc) or 0
            if proc ~= 0 and r16(proc + P_ACTION) == ACT_SHADOW then
                fired = true; move_start = frame; rel = 0
                place_noob()
                jax_x0 = s16(r16(r32(A.p2_obj) + OXPOS))
                jax_y0 = s16(r16(r32(A.p2_obj) + OYPOS))
                jax_hp0 = r16(A.p2_bar)
                log("  fired on try %d (jax x=%d y=%d ground_y=%d)",
                    tries, jax_x0, jax_y0, s16(r16(A.ground_y)))
            elseif rel >= RETRY_AFTER then
                tries = tries + 1
                if tries > MAX_TRIES then finish(false, "never_fired") return end
                move_start = frame; place_noob()
            end
            for name, f in pairs(fields) do f:set_value(move_pressed(name) and 1 or 0) end
            return
        end

        local pprocs = count_puff_procs()
        if pprocs ~= puffproc_prev then
            log("  rel=%3d  pid_1_puff procs=%d", rel, pprocs)
            puffproc_prev = pprocs
        end
        if rel == 6 or rel == 12 then dump_objects("rel"..rel) end
        local puffs = count_puffs()
        if puffs > puff_peak then puff_peak = puffs end
        if puffs > 0 then puff_last_rel = rel end
        if puffs ~= puff_prev then
            log("  rel=%3d  puffs=%d", rel, puffs)
            puff_prev = puffs
        end
        local sname, sx = find_shadow()
        if sx and sx ~= shadow_prev_x then
            -- worldtlx is 16.16; the game reads its integer half at +16 bits.
            local wtlx = A.worldtlx and s16(r16(A.worldtlx + 16)) or 0
            -- Keep SLIDE_STOP in step with NOOB_SLIDE_STOP (MKZAP.ASM) or this
            -- line reports a stop line the game is not using.
            log("  rel=%3d  shadow x=%d  worldtlx=%d  screen_right=%d  margin_line=%d",
                rel, sx, wtlx, wtlx + 399, wtlx + 399 - SLIDE_STOP)
            shadow_prev_x = sx
        end
        if sx then
            shadow_first_x = shadow_first_x or sx
            shadow_last_x, shadow_last_rel = sx, rel
            if r16(A.p2_bar) ~= jax_hp0 and not shadow_hit_x then shadow_hit_x = sx end
        elseif shadow_last_x and not shadow_gone_rel then
            shadow_gone_rel = rel
            log("  SHADOW gone at rel=%d: x %d -> %d (%d px), hit at x=%s, victim edge=%d",
                rel, shadow_first_x, shadow_last_x, shadow_last_x - shadow_first_x,
                tostring(shadow_hit_x), jax_x0)
        end
        local pose = obj_frames(r32(A.p1_obj))
        local vpose = obj_frames(r32(A.p2_obj))
        if vpose ~= last_vpose then
            log("  rel=%3d  JAX=%s", rel, tostring(vpose))
            last_vpose = vpose
        end
        local jy = s16(r16(r32(A.p2_obj) + OYPOS))
        local jx = s16(r16(r32(A.p2_obj) + OXPOS))
        if pose ~= last_pose then
            log("  rel=%3d  noob=%s   jax dx=%+d dy=%+d hp=%d",
                rel, tostring(pose), jx - jax_x0, jy - jax_y0, r16(A.p2_bar))
            last_pose = pose
        elseif rel % 4 == 0 then
            log("  rel=%3d  ..                     jax dx=%+d dy=%+d hp=%d",
                rel, jx - jax_x0, jy - jax_y0, r16(A.p2_bar))
        end
        if rel == 1 or rel == 2 or rel == 3 or rel == 4 or rel == 5
           or rel == 6 or rel == 8 or rel == 12
           or rel == 34 or rel == 42 or rel == 50 then
            snap(string.format("rel%02d", rel))
        end
        if rel >= WATCH then
            log("PUFF SUMMARY: peak=%d, last seen rel=%d, shadow gone rel=%s",
                puff_peak, puff_last_rel, tostring(shadow_gone_rel))
            finish(true, "probe_done") return
        end
    end

    for name, field in pairs(fields) do
        local on = false
        if name == "UI Select" then on = frame >= 5 and frame < 35
        elseif name == "Coin 1" then on = frame >= 700 and frame < 980 and frame % 80 < 20
        elseif name == "1 Player Start" then on = frame >= 1000 and frame < 1080
        elseif name == "P1 High Punch" and charsel_frame > 0 and fighting_frame == 0 then
            on = confirm_frame > 0 and frame >= confirm_frame and frame < confirm_frame + 45
        else
            on = move_pressed(name)
        end
        field:set_value(on and 1 or 0)
    end

    if frame > 12000 then finish(false, "global_timeout") end
end)
