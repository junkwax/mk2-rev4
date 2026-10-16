-- Runtime proof for Noob Saibot's three shadow moves.
--
-- Forces P1 = Noob, starts a normal match, then drives each motion in turn and
-- checks what actually appeared on screen:
--
--   D,B + LK  a projectile object carrying a NOOBSLIDE SAG, moving away from
--             Noob while Noob himself stays put (the whole point - the shadow
--             travels, he does not)
--   D,B + HK  a projectile object carrying a NOOBAIRKICK SAG that climbs
--   D,U       NOOB'S OWN object carrying a NOOBTELE SAG, reverting afterwards
--
-- Pointer-level like the Jade harness: matching SAGs prove the tables are
-- reached, not that the art is right. Look at the snapshots.
--
-- All offsets/addresses are TMS34010 BIT units - MAME's tms34010 program space
-- is bit-addressed, and mk2.map values go in raw.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("NOOB_TEST_LOG") or (ROOT .. "/tools/noob_moves_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[noob] " .. string.format(fmt, ...)
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
    objlst = sym("objlst"), winner_status = sym("winner_status"),
    p1_proc = sym("p1_proc"), ground_y = sym("ground_y"),
}
local P_ACTION = 0x100 + 0xf0     -- pdata + p_action, bit offset in the proc block
local OFLAGS   = 0xf0
local B_FLIPH  = 4
-- Object block offsets, DISPEQU.ASM.  OXVEL used to be 0x80 here, which is
-- oxval (the 16.16 master x POSITION), not a velocity - that is why the old
-- "peak |oxvel|" line logged eight-digit nonsense.  oxvel is 0x40, oyvel 0x60.
local OIMG, MP_LEN, ONEXT, OXPOS, OYPOS = 0x1a0, 0x70, 0x00, 0x90, 0xb0
local OXVEL, OYVEL = 0x40, 0x60
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_NOOB, FT_JAX, MAX_HP = 10, 15, 11, 0x00a1

-- SAG -> frame name, straight out of the generated table.
-- MKNJ.TBL as well as NOOBFX.TBL: the slide shadow flies a_slide (NJSLIDE1/2/3,
-- his real Sub-Zero slide) rather than the authored NOOBSLIDE pair, so the
-- label pattern has to be generic.  The kick is still NOOBFX art.
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
local fields = {}
local charsel_frame, vs_frame, confirm_frame, fighting_frame = 0, 0, 0, 0
local last_gstate = -1
local last_action = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

-- Results, filled in as each move runs.
local R = {}
local function res(k, v) R[k] = v end

local function finish(ok, reason)
    if finished then return end
    finished = true
    for _, k in ipairs({ "slide_seen", "slide_travel", "slide_noob_static",
                         "slide_damage", "slide_popped_up", "slide_no_knockback",
                         "kick_seen", "kick_rise", "kick_damage",
                         "tele_seen", "tele_reverted", "tele_gap", "tele_in_uppercut_range",
                         "airhit_connected", "airhit_knockback",
                         "airhit_air_reaction" }) do
        log("  %-18s %s", k, tostring(R[k]))
    end
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
    for name, _ in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

-- Frame index of a named frame on an object, or nil.
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

-- Find the first object (other than the two fighters) showing a frame whose
-- name starts with `prefix`.  Returns name, x, y.
local function find_shadow(prefix)
    if not A.objlst then return nil end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local obj, guard = r32(A.objlst), 0
    while obj ~= 0 and guard < 256 do
        if obj ~= p1 and obj ~= p2 then
            local n = obj_frame(obj)
            if n and n:sub(1, #prefix) == prefix then
                return n, s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS))
            end
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end
    return nil
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

-- ---------------------------------------------------------------- input plan
-- Each move is one entry: a list of {from, to, field} windows relative to the
-- move's start frame.  P1 stands on the left facing right, so Back = Left.
-- Window shape copied from tools/jade_boomerang_test.lua, which is the proven
-- one for this game: 4-frame taps with a 2-frame neutral gap between them, then
-- the button.  Longer, overlapping holds do not register as a motion.
-- `act` is the p_action a move must reach for the attempt to count as fired.
-- Boot timing drifts run to run, so a single fixed input window is not
-- reliable: the motion can land while Noob is mid-block or mid-recovery and
-- simply not register.  Each move re-drives its motion until the act appears
-- and only then starts measuring.
local ACT_SHADOW, ACT_TELE = 0x0116, 0x0211
local RETRY_AFTER, MAX_TRIES = 50, 8
local MOVES = {
    { name = "slide", prefix = "NJSLIDE", watch = 130, act = ACT_SHADOW,
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Left"}, {12, 18, "P1 Low Kick"} } },
    { name = "kick", prefix = "NOOBAIRKICK", watch = 130, act = ACT_SHADOW,
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Left"}, {12, 18, "P1 High Kick"} } },
    { name = "tele", prefix = "NOOBTELE", watch = 200, act = ACT_TELE,
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Up"} } },
    -- Same input as "kick", but fired from in range with the victim held in
    -- the game's own AIRBORNE state, to prove stk_noob_kick's hit routine 0a
    -- takes the air branch.  r_hhjumpupk enters through reaction_start_abc
    -- with a5 = generic_airborn_hit; reaction_start_abc runs am_i_airborn on
    -- the victim and jumps to a5 when he is off the ground.  Ground path
    -- pushes him with away_x_vel 010000h (1 px/tick) and plays a standing
    -- chest hit; air path runs `flight` at 038000h (3.5 px/tick) into
    -- land_on_my_back.  The two are far enough apart that raw x displacement
    -- tells them apart - see AIRHIT_MIN_KNOCKBACK below.
    { name = "airhit", prefix = "NOOBAIRKICK", watch = 130, act = ACT_SHADOW,
      spacing = 130,           -- inside the kick's reach: it travels ~120px
                               -- before deleting at its apex
      seq = { {0, 4, "P1 Down"}, {6, 10, "P1 Left"}, {12, 18, "P1 High Kick"} } },
}
-- am_i_airborn (JOY.ASM) answers yes on `oyvel != 0` before it ever compares
-- oypos to p_ganiy.  So a small non-zero oyvel puts the victim in exactly the
-- state the branch keys on without hurling him out of the strike box first -
-- much steadier than trying to time a real jump against the drone's AI.
local AIRHIT_OYVEL = -0x8000            -- 0.5 px/tick, 16.16
local AIRHIT_MIN_KNOCKBACK = 40         -- px; ground reaction manages ~10
local move_idx, move_start = 0, 0
local tries, fired = 0, false
local seen_frames, first_x, last_x, first_y, best_rise = {}, nil, nil, nil, 0
local first_rel = nil
local noob_x0, jax_x0, jax_hp0 = nil, nil, nil
local jax_min_x, jax_max_x, jax_min_y, jax_max_y = nil, nil, nil, nil
local jax_y0_start = nil
local jax_peak_vel = 0

-- Put Noob a fixed distance to Jax's left instead of walking him there.
-- Walking with held Back is not reliable - Back is also block, so if the drone
-- happens to attack he stands still.  Distance matters: point blank the shadows
-- connect on their first tick and delete themselves, which reads as "never
-- travelled" even though the move worked.
local SPACING = 300
local function place_noob()
    local sp = (move_idx > 0 and MOVES[move_idx].spacing) or SPACING
    local jx = s16(r16(r32(A.p2_obj) + OXPOS))
    w16(r32(A.p1_obj) + OXPOS, (jx - sp) & 0xffff)
end

local function begin_move(i)
    move_idx = i
    move_start = frame
    tries, fired = 1, false
    place_noob()
    seen_frames, first_x, last_x, first_y, best_rise = {}, nil, nil, nil, 0
    first_rel = nil
    noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
    jax_x0, jax_hp0 = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
    jax_min_x, jax_max_x = jax_x0, jax_x0
    local jy0 = s16(r16(r32(A.p2_obj) + OYPOS))
    jax_min_y, jax_max_y, jax_y0_start = jy0, jy0, jy0
    jax_peak_vel = 0
    log("--- move %d (%s) begins at frame %d, noob x=%d jax x=%d hp=%d",
        i, MOVES[i].name, frame, noob_x0, jax_x0, jax_hp0)
end

local function move_pressed(name)
    if move_idx == 0 then return false end
    local rel = frame - move_start
    for _, w in ipairs(MOVES[move_idx].seq) do
        if w[3] == name and rel >= w[1] and rel < w[2] then return true end
    end
    return false
end

local function finish_move()
    local m = MOVES[move_idx]
    local names = {}
    for n, _ in pairs(seen_frames) do names[#names+1] = n end
    table.sort(names)
    log("move %s: frames seen = %s", m.name, #names > 0 and table.concat(names, ",") or "NONE")

    if m.name == "slide" then
        res("slide_seen", #names > 0)
        res("slide_travel", (first_x and last_x) and math.abs(last_x - first_x) or 0)
        local nx = s16(r16(r32(A.p1_obj) + OXPOS))
        res("slide_noob_static", math.abs(nx - noob_x0) <= 8)
        log("  shadow x %s -> %s ; noob x %d -> %d",
            tostring(first_x), tostring(last_x), noob_x0, nx)
        local jx, hp = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
        res("slide_damage", jax_hp0 - hp)
        -- r_noob_slide pops the victim STRAIGHT UP: a real vertical rise and
        -- no horizontal travel in either direction.  Measured across the whole
        -- window, not just at the end - by then he has landed and the drone has
        -- walked back to station.  Screen y grows downward, so a rise is a
        -- DROP in oypos.  The x tolerance is not zero because the drone keeps
        -- walking for the tick or two before the shadow connects.
        res("slide_popped_up", (jax_y0_start - jax_min_y) >= 30)
        res("slide_no_knockback", (jax_max_x - jax_min_x) <= 8)
        log("  jax x range %d..%d (start %d)   y range %d..%d   peak |oxvel| %d",
            jax_min_x, jax_max_x, jax_x0, jax_min_y, jax_max_y, jax_peak_vel)
        log("  jax x %d -> %d (%+d)  hp %d -> %d (-%d)", jax_x0, jx, jx - jax_x0,
            jax_hp0, hp, jax_hp0 - hp)
    elseif m.name == "kick" then
        res("kick_seen", #names > 0)
        res("kick_rise", best_rise)
        local jx, hp = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
        res("kick_damage", jax_hp0 - hp)
        log("  jax x range %d..%d (start %d)   y range %d..%d   peak |oxvel| %d",
            jax_min_x, jax_max_x, jax_x0, jax_min_y, jax_max_y, jax_peak_vel)
        log("  shadow rose %d px ; jax x %d -> %d (%+d)  hp %d -> %d (-%d)",
            best_rise, jax_x0, jx, jax_x0 and (jx - jax_x0) or 0, jax_hp0, hp, jax_hp0 - hp)
    elseif m.name == "airhit" then
        local hp = r16(A.p2_bar)
        local dmg = jax_hp0 - hp
        -- Noob is on Jax's LEFT, so an air knockback drives Jax's x UP.
        local push = math.max(jax_max_x - jax_x0, jax_x0 - jax_min_x)
        res("airhit_connected", dmg > 0)
        res("airhit_knockback", push)
        res("airhit_air_reaction", dmg > 0 and push >= AIRHIT_MIN_KNOCKBACK)
        log("  jax held airborne; x range %d..%d (start %d)  push %d px (need >=%d)",
            jax_min_x, jax_max_x, jax_x0, push, AIRHIT_MIN_KNOCKBACK)
        log("  jax y range %d..%d   hp %d -> %d (-%d)",
            jax_min_y, jax_max_y, jax_hp0, hp, dmg)
    else
        res("tele_seen", #names > 0)
        -- "back to his normal sprite" has to name the frames it means.  This
        -- was `obj_frame(...) == nil`, which only worked while the SAG table
        -- held NOOBFX records alone - now that it covers MKNJ.TBL as well,
        -- every ordinary ninja stance frame resolves to a name too.
        local body = obj_frame(r32(A.p1_obj))
        res("tele_reverted", not (body and body:sub(1, 8) == "NOOBTELE"))
        -- Where he LANDS is the point of NOOB_TELE_GAP (MKPROP.ASM): the stock
        -- teleport_next_to drops him 054h = 84px out, and stk_njuppercut's box
        -- front only reaches 04eh = 78, so the obvious follow-up whiffed.  He
        -- now re-enters at 040h.  Measured after the drop has finished.
        local gap = math.abs(s16(r16(r32(A.p1_obj) + OXPOS))
                           - s16(r16(r32(A.p2_obj) + OXPOS)))
        res("tele_gap", gap)
        res("tele_in_uppercut_range", gap <= 0x4e)
        log("  landed %d px from Jax (uppercut reach %d)", gap, 0x4e)
    end

    if move_idx < #MOVES then
        begin_move(move_idx + 1)
    else
        local ok = R.slide_seen and R.kick_seen and R.tele_seen
                   and R.slide_noob_static and R.tele_reverted
                   and R.tele_in_uppercut_range
                   and R.slide_popped_up and R.slide_no_knockback
                   and (R.slide_travel or 0) >= 40 and (R.kick_rise or 0) >= 40
                   and R.airhit_air_reaction
        finish(ok, ok and "all_three_moves_fired" or "see_field_report")
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded %d NOOBFX markers, objlst=%s", marker_count,
            A.objlst and string.format("0x%x", A.objlst) or "MISSING")
    end

    if space and not finished then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d p1=%d p2=%d", frame, last_gstate, gs,
                r16(A.p1_char), r16(A.p2_char))
            last_gstate = gs
        end

        if gs == GS_PSEL then
            if charsel_frame == 0 then charsel_frame = frame end
            -- Noob has no grid portrait; confirm a visible ninja, then swap the
            -- fighter slot during post-select the way the Jade harness does.
            w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
            if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        elseif gs == GS_POST then
            if vs_frame == 0 then vs_frame = frame end
            w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
            -- Snapshot the VS screen: Noob's portrait is zipped_pics 28h since
            -- the dead VS_JC entry was retired, so this is where a bad index
            -- would show up as garbage or the wrong fighter.
            if frame - vs_frame == 120 then snap("vs_screen") end
        elseif gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
        end

        -- Keep both bars full so nothing ends the round mid-test.
        -- Keep Noob topped up so nothing ends the round, but leave Jax's bar
        -- alone: the shadows are supposed to hurt him and that is measurable.
        if fighting_frame > 0 then
            w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
            if r16(A.p2_bar) < 0x30 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end
        end

        if fighting_frame > 0 and move_idx == 0 and frame - fighting_frame >= 150 then
            if r16(A.p1_char) ~= FT_NOOB then finish(false, "p1_not_noob") return end
            begin_move(1)
        end

        if move_idx > 0 then
            local m = MOVES[move_idx]
            local rel = frame - move_start
            -- Wait for the move to actually fire before measuring; re-drive the
            -- motion if it did not take.
            if not fired then
                local proc = A.p1_proc and r32(A.p1_proc) or 0
                if proc ~= 0 and r16(proc + P_ACTION) == m.act then
                    fired = true
                    move_start = frame
                    rel = 0
                    place_noob()
                    noob_x0 = s16(r16(r32(A.p1_obj) + OXPOS))
                    jax_x0, jax_hp0 = s16(r16(r32(A.p2_obj) + OXPOS)), r16(A.p2_bar)
                    jax_min_x, jax_max_x = jax_x0, jax_x0
                    local jy = s16(r16(r32(A.p2_obj) + OYPOS))
                    jax_min_y, jax_max_y, jax_y0_start = jy, jy, jy
                    log("  %s fired on try %d (noob x=%d jax x=%d)", m.name, tries, noob_x0, jax_x0)
                elseif rel >= RETRY_AFTER then
                    tries = tries + 1
                    if tries > MAX_TRIES then finish(false, m.name .. "_never_fired") return end
                    move_start = frame
                    place_noob()
                    log("  %s: no act %04x after %d frames, retry %d", m.name, m.act, RETRY_AFTER, tries)
                end
                for name, f in pairs(fields) do f:set_value(move_pressed(name) and 1 or 0) end
                return
            end
            -- Hold the victim in the game's own airborne state for the whole
            -- window.  Stop as soon as he is reacting: from there the reaction
            -- owns his velocities and writing oyvel would fight `flight`.
            if m.name == "airhit" and r16(A.p2_bar) == jax_hp0 then
                local jo = r32(A.p2_obj)
                if jo ~= 0 and space then
                    space:write_u32(jo + OYVEL, AIRHIT_OYVEL & 0xffffffff)
                end
            end
            local jxn = s16(r16(r32(A.p2_obj) + OXPOS))
            if jax_min_x and jxn < jax_min_x then jax_min_x = jxn end
            if jax_max_x and jxn > jax_max_x then jax_max_x = jxn end
            local jv = r32(r32(A.p2_obj) + OXVEL)
            if jv >= 0x80000000 then jv = jv - 0x100000000 end
            if math.abs(jv) > math.abs(jax_peak_vel) then jax_peak_vel = jv end
            local jyn = s16(r16(r32(A.p2_obj) + OYPOS))
            if jax_min_y and jyn < jax_min_y then jax_min_y = jyn end
            if jax_max_y and jyn > jax_max_y then jax_max_y = jyn end
            -- Trace what Noob's own process/object is doing, so a move that
            -- never fires can be told apart from one that fires and draws
            -- nothing.  p_action changing at all means the handler ran.
            if A.p1_proc then
                local proc = r32(A.p1_proc)
                if proc ~= 0 then
                    local act = r16(proc + P_ACTION)
                    if act ~= last_action then
                        local o = r32(A.p1_obj)
                        local fl = r16(o + OFLAGS)
                        log("  [%s rel=%3d] p_action %04x -> %04x  fliph=%d shape=%08x",
                            m.name, rel, last_action, act,
                            (fl >> B_FLIPH) & 1, r32(o + 0x1d0))
                        last_action = act
                    end
                end
            end
            local n, x, y = find_shadow(m.prefix)
            if m.name == "tele" then
                n = obj_frame(r32(A.p1_obj))
                if n and n:sub(1, #m.prefix) ~= m.prefix then n = nil end
            end
            if n then
                if next(seen_frames) == nil then
                    snap(m.name .. "_first")
                    first_x, first_y, first_rel = x, y, rel
                    -- Placement maths, so the DY constants can be tuned from
                    -- numbers instead of eyeballing screenshots.  NOOBSLIDE1
                    -- hangs 139px below its anchor, NOOBAIRKICK1 79px.
                    local gy = A.ground_y and s16(r16(A.ground_y)) or -1
                    local drop = (m.name == "slide") and 139 or 79
                    log("  spawn: shadow oypos=%d bottom=%d ground_y=%d  -> DY correction %+d",
                        y or -1, (y or 0) + drop, gy, gy - ((y or 0) + drop))
                end
                seen_frames[n] = true
                last_x = x or last_x
                if y and first_y then
                    local rise = first_y - y
                    if rise > best_rise then best_rise = rise end
                end
                -- Snapshot once the shadow has travelled clear of Noob; at the
                -- spawn frame it sits right on top of him and proves nothing.
                if first_rel then
                    if rel == first_rel + 10 then snap(m.name .. "_flight1") end
                    if rel == first_rel + 22 then snap(m.name .. "_flight2") end
                    if rel == first_rel + 34 then snap(m.name .. "_flight3") end
                end
            end
            if rel >= m.watch then finish_move() end
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

    if not finished and frame > 12000 then finish(false, "global_timeout") end
end)
