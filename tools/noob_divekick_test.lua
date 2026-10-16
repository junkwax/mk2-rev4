-- Runtime proof for Noob Saibot's airborne shadow dive kick (D,B + LK in air).
--
-- The move shares its motion AND its action (act_noob_shadow, 0116h) with the
-- ground shadow slide, so p_action alone cannot tell the two apart.  What
-- separates them is on screen:
--
--   ground   D,B+LK with his feet down spawns a NOOBSLIDE shadow - the shipped
--            move must not have been eaten by the split
--   dive     D,B+LK from a jump spawns a NOOBAIRKICK shadow that DESCENDS
--            (the D,B+HK kick climbs; this is the sign flip that makes it a
--            dive), Noob HANGS at the cast instead of riding his jump arc, he
--            comes back to the ground afterwards, and the shadow takes HP
--
-- Structure, addressing and the boot schedule are lifted from
-- tools/noob_moves_test.lua: all offsets are TMS34010 BIT units, mk2.map values
-- go in raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("NOOB_DIVE_LOG") or (ROOT .. "/tools/noob_divekick_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[dive] " .. string.format(fmt, ...)
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
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    p1_proc = sym("p1_proc"), ground_y = sym("ground_y"), objlst = sym("objlst"),
    worldtlx = sym("worldtlx"),
}
local P_ACTION = 0x100 + 0xf0
local OIMG, MP_LEN, ONEXT, OXPOS, OYPOS = 0x1a0, 0x70, 0x00, 0x90, 0xb0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_NOOB, FT_JAX, MAX_HP = 10, 15, 11, 0x00a1

local ACT_SHADOW = 0x0116        -- act_noob_shadow: all three casts share it
-- The height gate the handler applies, straight out of hh_hi_kick:
-- distance_from_ground must be >= 0a0h or the dive is refused.
local HEIGHT_GATE = 0xa0

-- SAG -> frame name, straight out of the generated tables.
--
-- MKNJ.TBL as well as NOOBFX.TBL, because the shadows no longer fly authored
-- NOOBFX art: the slide shadow is a_slide (NJSLIDE1/2/3) and the dive shadow is
-- a_njflipkick (NJFLIPKICK1/2/3), both ordinary ninja records.  The label
-- pattern is generic rather than "NOOB%u+" for the same reason.
local sag_name = {}
local marker_count = 0
for _, tbl in ipairs({ "NOOBFX.TBL", "MKNJ.TBL" }) do
    local fh = assert(io.open(ROOT .. "/src/" .. tbl, "r"), "missing src/" .. tbl)
    local label
    for line in fh:lines() do
        local l = line:match("^%s*(%u[%u%d_]*):")
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
local fields, held = {}, {}
local charsel_frame, vs_frame, confirm_frame, fighting_frame = 0, 0, 0, 0
local last_gstate = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local R = {}
local function res(k, v) R[k] = v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- field report ----")
    for _, k in ipairs({ "ground_slide_seen", "ground_slide_ok",
                         "dive_fired", "dive_height_at_fire", "dive_spacing", "dive_shadow_seen",
                         "dive_shadow_descends", "dive_shadow_runs",
                         "dive_step_dx", "dive_dy_first_last", "dive_accelerating",
                         "dive_noob_hangs",
                         "dive_noob_landed", "dive_body_pose", "dive_body_is_jump",
                         "dive_damage", "dive_hit",
                         "dive_victim_rise", "dive_flipkick_reaction" }) do
        log("  %-22s %s", k, tostring(R[k]))
    end
    log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true,
        ["P1 Left"]=true, ["P1 Right"]=true, ["P1 Up"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

-- Frame name shown on an object, or nil.
local function obj_frame(obj)
    if obj == 0 then return nil end
    local image = r32(obj + OIMG); if image == 0 then return nil end
    for i = 0, 7 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        if sag_name[sag] then return sag_name[sag] end
    end
    return nil
end

-- First object other than the two fighters showing a frame named `prefix`...
local function find_shadow(prefix)
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frame(obj)
            if n and n:sub(1, #prefix) == prefix then
                return n, s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS)), obj
            end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return nil
end

local function p1_action()
    local proc = A.p1_proc and r32(A.p1_proc) or 0
    if proc == 0 then return -1 end
    return r16(proc + P_ACTION)
end

local function noob_y() return s16(r16(r32(A.p1_obj) + OYPOS)) end
local function height() return s16(r16(A.ground_y)) - noob_y() end

-- ------------------------------------------------------------------- phases
-- The ground phase is the regression guard and runs first: if the shipped
-- slide were broken by the split it has to fail loudly before anything about
-- the dive is reported.
--
-- Window shape is the proven one from the Jade/Noob harnesses: 4-frame taps
-- with a 2-frame neutral gap, then the button.  The dive adds a jump in front
-- and does NOT start the motion on a fixed frame - it waits for Noob to
-- actually leave the ground, because boot timing and the drone both drift.
local SPACING_GROUND = 300
-- Retries sweep BOTH unknowns.  DELAYS decides where in the jump arc the LK
-- press lands (the height gate is only satisfied near the apex), SPACINGS how
-- far the 45-degree descent has to reach to find Jax - the shadow drops one
-- pixel per pixel it travels, so the right distance is roughly the height Noob
-- is casting from above Jax's body.
local DELAYS   = { 6, 2, 10, 6, 2, 10, 0, 8, 4, 12, 6, 2, 10, 6, 2 }
local SPACINGS = { 70, 90, 110, 70, 90, 110, 50, 130, 70, 90, 110, 50, 130, 70, 90 }
local MAX_TRIES, RETRY_AFTER = 15, 130

local phase, phase_try, phase_start = 0, 0, 0
local takeoff_at, motion_at, ground_h = nil, nil, nil
local fired_at, peak_height, height_at_lk = nil, 0, nil
local jax_hp0, jax_hp_min = nil, nil
local shadow_y0, shadow_descent, shadow_name = nil, 0, nil
local shadow_x0, shadow_run = nil, 0
local shadow_lx, shadow_ly = nil, nil
local step_dx, first_dy, max_dy = nil, nil, nil
local hang_y, hang_frames = nil, 0
local ground_seen_at = 0
local body_pose = nil
-- The cast action and the spawned shadow are NOT observable on the same frame:
-- act_noob_shadow is set at the top of the windup and the object only appears
-- several frames later, at the release.  Accumulate them over the attempt
-- instead of testing both at once, which is what made the ground phase read as
-- "never fired" while Jax was visibly losing 22 HP a go.
local saw_act, saw_shadow = false, nil
-- Proof that the VICTIM's reaction is the flip kick's and not the jump kick's.
-- Damage cannot show this: stk_noob_dive and stk_noob_kick both deal 26 on the
-- hit.  The reactions differ completely though - r_hhjumpupk (stk_noob_kick,
-- react_to_nj row 0a) pushes a grounded victim with away_x_vel 010000h and
-- plays a chest hit, feet on the floor, while r_flipk (row 0b, the word
-- stk_noob_dive now carries) puts him into `flight` at -080000h, i.e. 8px/tick
-- STRAIGHT UP.  So: did he leave the ground?
local jax_y_prehit, jax_min_y = nil, nil
local function jax_y() return s16(r16(r32(A.p2_obj) + OYPOS)) end

local function place(sp)
    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
    w16(r32(A.p1_obj) + OXPOS, (jx - sp) & 0xffff)
end

local function begin_phase(p, try)
    phase, phase_try, phase_start = p, try, frame
    takeoff_at, motion_at, fired_at, height_at_lk, peak_height = nil, nil, nil, nil, 0
    shadow_y0, shadow_descent, shadow_name = nil, 0, nil
    shadow_x0, shadow_run = nil, 0
    shadow_lx, shadow_ly = nil, nil
    step_dx, first_dy, max_dy = nil, nil, nil
    hang_y, hang_frames = nil, 0
    body_pose = nil
    saw_act, saw_shadow = false, nil
    jax_y_prehit, jax_min_y = nil, nil
    place(p == 1 and SPACING_GROUND or (SPACINGS[try] or 110))
    -- Standing is NOT zero here: distance_from_ground measures @ground_y down
    -- to his (head-anchored) oypos, so a fighter with his feet on the floor
    -- already reads ~120.  Takeoff has to be judged against that baseline, not
    -- against 0, or every frame looks airborne.
    ground_h = height()
    jax_hp0 = r16(A.p2_bar); jax_hp_min = jax_hp0
    log("--- phase %d (%s) try %d at frame %d  standing height=%d jax hp=%d",
        p, p == 1 and "ground" or "dive", try, frame, ground_h, jax_hp0)
end

local function drive()
    local rel = frame - phase_start
    if phase == 1 then
        if rel >= 0  and rel < 4  then held["P1 Down"] = true end
        if rel >= 6  and rel < 10 then held["P1 Left"] = true end
        if rel >= 12 and rel < 18 then held["P1 Low Kick"] = true end
    elseif phase == 2 then
        if rel >= 0 and rel < 5 then held["P1 Up"] = true end
        if not takeoff_at and rel > 5 and (height() - ground_h) >= 0x20 then
            takeoff_at = frame
        end
        if takeoff_at and not motion_at
           and frame - takeoff_at >= (DELAYS[phase_try] or 6) then
            motion_at = frame
        end
        if motion_at then
            local m = frame - motion_at
            if m >= 0  and m < 4  then held["P1 Down"] = true end
            if m >= 6  and m < 10 then held["P1 Left"] = true end
            if m >= 12 and m < 18 then
                held["P1 Low Kick"] = true
                if not height_at_lk then height_at_lk = height() end
            end
        end
    end
end

-- Everything except the boot schedule and the final input write, so this can
-- `return` freely without skipping either.
local function tick()
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
        last_gstate = gs
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        -- Noob has no grid portrait; confirm a visible ninja, then swap the
        -- fighter slot during post-select the way the Noob harness does.
        w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        if vs_frame == 0 then vs_frame = frame end
        w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d ground_y=%d", r16(A.p1_char), r16(A.p2_char),
            s16(r16(A.ground_y)))
    end

    if fighting_frame == 0 then return end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end

    if phase == 0 then
        if frame - fighting_frame >= 150 then
            if r16(A.p1_char) ~= FT_NOOB then finish(false, "p1_not_noob") return end
            begin_phase(1, 1)
        end
        return
    end

    local act = p1_action()
    local h = height()
    if h > peak_height then peak_height = h end
    local hp = r16(A.p2_bar)
    if hp < jax_hp_min then jax_hp_min = hp end

    -- ------------------------------------------------------- phase 1: ground
    if phase == 1 then
        if act == ACT_SHADOW then saw_act = true end
        saw_shadow = saw_shadow or find_shadow("NJSLIDE")
        if saw_act and saw_shadow then
            if not R.ground_slide_ok then
                res("ground_slide_seen", saw_shadow)
                res("ground_slide_ok", true)
                ground_seen_at = frame
                log("  ground shadow slide fired on try %d (%s)", phase_try, saw_shadow)
                -- opal is the object's const:pal long, which MKDISP feeds
                -- straight to the DMA - so this is exactly which colour map
                -- the shadow is drawn through.  Compare it with Noob's own: if
                -- they differ, get_noob_shadow_obj's getfpal override took.
                local _, _, _, sobj = find_shadow("NJSLIDE")
                if sobj then
                    log("  shadow opal=%04x  noob opal=%04x",
                        r16(sobj + 0x140), r16(r32(A.p1_obj) + 0x140))
                end
            end
            -- Snap LATE, not on detection: the shadow spawns on Noob's own
            -- anchor, so at frame 0 it is drawn inside him and a snapshot there
            -- proves nothing about how it renders.  Let it travel clear first.
            if frame - ground_seen_at >= 14 then
                snap("ground_slide_mid")
                begin_phase(2, 1)
            end
            return
        end
        if frame - phase_start >= RETRY_AFTER then
            if phase_try >= MAX_TRIES then
                res("ground_slide_ok", false)
                finish(false, "ground_slide_never_fired")
                return
            end
            begin_phase(1, phase_try + 1)
            return
        end
        drive()
        return
    end

    -- --------------------------------------------------------- phase 2: dive
    if not fired_at then
        -- It counts as the DIVE only if the cast happened off the ground and
        -- above the gate; the same action at ground level is the slide.
        if act == ACT_SHADOW and h >= HEIGHT_GATE then
            fired_at = frame
            res("dive_fired", true)
            res("dive_height_at_fire", h)
            hang_y = noob_y()
            log("  DIVE cast on try %d  height=%d (gate %d, at LK press %s, peak %d)",
                phase_try, h, HEIGHT_GATE, tostring(height_at_lk), peak_height)
            snap("dive_cast")
            return
        end
        if frame - phase_start >= RETRY_AFTER then
            log("  dive: no airborne cast after %d frames (peak height %d, at LK %s)",
                RETRY_AFTER, peak_height, tostring(height_at_lk))
            if phase_try >= MAX_TRIES then
                res("dive_fired", false)
                finish(false, "dive_never_fired")
                return
            end
            begin_phase(2, phase_try + 1)
            return
        end
        drive()
        return
    end

    -- Measuring window.  Three things are watched at once:
    local since = frame - fired_at

    --  1. the shadow: it must exist, and it must go DOWN (the D,B+HK kick
    --     climbs - the descent is what makes this the dive)
    local n, sx, sy = find_shadow("NJFLIPKICK")
    if n then
        shadow_name = n
        if not shadow_y0 then shadow_y0, shadow_x0 = sy, sx end
        if sy - shadow_y0 > shadow_descent then shadow_descent = sy - shadow_y0 end
        local run = math.abs(sx - shadow_x0)
        if run > shadow_run then shadow_run = run end
        -- Per-tick step.  dx should hold at NOOB_DIVE_XVEL's 8 (nothing
        -- accelerates it), while dy GROWS - that growth is the gravity, and it
        -- is the honest signature of the arc.  Angle is not: the dive is
        -- deliberately steeper than Kung Lao's, so a run/drop ratio only says
        -- which angle was picked, never whether it is accelerating at all.
        if shadow_lx then
            local dx, dy = math.abs(sx - shadow_lx), sy - shadow_ly
            if dx > 0 then step_dx = dx end
            if dy > 0 then
                first_dy = first_dy or dy
                max_dy = (max_dy and math.max(max_dy, dy)) or dy
            end
        end
        shadow_lx, shadow_ly = sx, sy
    end
    -- Snap once the shadow has travelled clear of Noob.  It spawns on his own
    -- anchor, so an at-spawn snapshot draws it inside him and shows nothing.
    if since == 14 then snap("dive_shadow_mid") end

    -- His BODY should be holding the jump, not kicking: NJJUMP3, the airborne
    -- pose out of a_njjumpup.  The kick belongs entirely to the shadow, so
    -- finding a NJFLIPKICK frame on the player object would mean the two lanes
    -- had been wired the same way round again.
    local body = obj_frame(r32(A.p1_obj))
    if body and not body_pose then body_pose = body end

    --  2. Noob hangs: stop_me zeroed his velocity and gravity, so his y should
    --     sit still for the hold instead of continuing the jump arc
    if since <= 20 and hang_y and math.abs(noob_y() - hang_y) <= 4 then
        hang_frames = hang_frames + 1
    end

    --  3. the victim: still full HP means the hit has not landed, so his y is
    --     the pre-hit baseline; once it lands, how far UP he goes decides
    --     which reaction ran
    if hp >= jax_hp0 then
        jax_y_prehit = jax_y()
    else
        local jy = jax_y()
        jax_min_y = (jax_min_y and math.min(jax_min_y, jy)) or jy
    end

    if since >= 100 then
        --  4. ...and Noob comes back to the ground on his own
        local launch = (jax_y_prehit and jax_min_y) and (jax_y_prehit - jax_min_y) or 0
        res("dive_spacing", SPACINGS[phase_try] or 110)
        res("dive_shadow_seen", shadow_name or false)
        res("dive_shadow_descends", shadow_descent)
        res("dive_shadow_runs", shadow_run)
        -- Kung Lao's dive leaves SHALLOW and steepens: do_reptile_superk gives
        -- 8px/tick forward against 3px/tick down, so early on it covers roughly
        -- 2.5x more ground than height.  A fixed 45 degrees would be 1:1, which
        -- is what this flew before and what a regression here would look like.
        res("dive_run_over_drop",
            shadow_descent > 0 and string.format("%.2f", shadow_run / shadow_descent) or "n/a")
        res("dive_noob_hangs", hang_frames)
        res("dive_body_pose", body_pose or "none")
        res("dive_body_is_jump", (body_pose or ""):sub(1, 6) == "NJJUMP")
        res("dive_noob_landed", math.abs(height() - ground_h) <= 8)
        res("dive_damage", jax_hp0 - jax_hp_min)
        res("dive_hit", (jax_hp0 - jax_hp_min) > 0)
        res("dive_victim_rise", launch)
        res("dive_flipkick_reaction", launch >= 30)
        log("  shadow %s  ran %d px / dropped %d px  (%s..%s -> %s,%s)",
            tostring(shadow_name), shadow_run, shadow_descent,
            tostring(shadow_x0), tostring(shadow_y0), tostring(shadow_lx), tostring(shadow_ly))
        log("  noob held y for %d frames, back at height %d (stand %d)",
            hang_frames, height(), ground_h)
        log("  jax hp %d -> %d (-%d) ; launched %d px up (pre-hit y %s, peak y %s)",
            jax_hp0, jax_hp_min, jax_hp0 - jax_hp_min, launch,
            tostring(jax_y_prehit), tostring(jax_min_y))

        -- Absolute descent is NOT the measure: on a dive the shadow that
        -- connects has barely dropped, because it arrives sooner, and a
        -- `descends >= 40` threshold scored good hits as misses.  What must
        -- hold is that it is travelling forward at Kung Lao's speed and that
        -- its descent is ACCELERATING.
        res("dive_step_dx", step_dx or 0)
        res("dive_dy_first_last", string.format("%s -> %s",
            tostring(first_dy), tostring(max_dy)))
        res("dive_accelerating", (max_dy or 0) > (first_dy or 0))
        local structural = R.dive_shadow_seen and R.dive_accelerating
                           and (step_dx or 0) >= 7
                           and hang_frames >= 10 and R.dive_noob_landed
                           and R.dive_body_is_jump
        if structural and R.dive_hit and R.dive_flipkick_reaction then
            finish(R.ground_slide_ok and true, "ground_slide_and_dive_both_work")
            return
        end
        -- The move worked but missed: sweep the spacing rather than calling it
        -- a failure, since where a 45-degree descent lands is a distance
        -- question, not a wiring one.
        if phase_try < MAX_TRIES then
            log("  dive did not connect at spacing %d (structural=%s) - retrying",
                SPACINGS[phase_try] or 110, tostring(structural))
            local keep_fired, keep_h = R.dive_fired, R.dive_height_at_fire
            begin_phase(2, phase_try + 1)
            R.dive_fired, R.dive_height_at_fire = keep_fired, keep_h
            return
        end
        finish(false, "see_field_report")
        return
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded %d NOOBFX markers", marker_count)
        for k, v in pairs(A) do
            if not v then log("MISSING SYMBOL %s", k) end
        end
    end
    if not space or finished then return end

    held = {}
    tick()
    if finished then return end

    -- Boot schedule: dismiss the warning, coin up, start, then confirm the
    -- character grid.  Applied AFTER tick() so a phase can never suppress it.
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if confirm_frame > 0 and fighting_frame == 0
       and frame >= confirm_frame and frame < confirm_frame + 45 then
        held["P1 High Punch"] = true
    end

    for name, f in pairs(fields) do f:set_value(held[name] and 1 or 0) end

    if frame > 12000 then finish(false, "global_timeout") end
end)
