-- deadpool_ed_tuner.lua
--
-- Live Dead Pool Ed/chain tuner.
--
-- Keyboard:
--   Arrows       move the chain anchor on screen
--   W/A/S/D      move Ed relative to the chain anchor
--   Z / X        Ed/body z down/up
--   C / V        chain z down/up
--   Space        pause/play the debug animation clock
--   N            advance one debug animation tick while paused
--   T            restart the debug Ed drop + TINCHAIN4 sequence
--   1 / 2        step 1 / step 4
--   R            write a marked reading to the log
--   P            snapshot
--
-- File control:
--   Edit tmp/dp/ed_tune_control.txt while MAME is running. The script reloads
--   it about twice a second. Current live values are written to
--   tmp/dp/ed_tune_current.txt.
--   Set keyboard=0 in the control file to disable hotkeys. The script ignores
--   keyboard input for the first few seconds so launch/dismissal input does
--   not nudge the test by accident.
--
-- Readout:
--   tmp/dp/ed_tune_current.txt shows Ed x/y/z, bubble z + measured animation
--   speed, and chain z + measured movement speed.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP_PATH = ROOT .. "/src/mk2.map"
local LOG_PATH = ROOT .. "/tmp/dp/deadpool_ed_tuner.log"
local CONTROL_PATH = ROOT .. "/tmp/dp/ed_tune_control.txt"
local CURRENT_PATH = ROOT .. "/tmp/dp/ed_tune_current.txt"

local PID_EDPOOL_FX = 0x0111
local PID_EDPOOL_PREVIEW = 0x0112
local M_MULTIPART = 0x0002
local M_INVIS = 0x0020

local defaults = {
    anchor_x = 334,
    anchor_y = 0,
    ed_xofs = 24,
    ed_yofs = -20,
    ed_z = -2,
    chain_z = -10,
    step = 1,
    keyboard = 1,
    paused = 0,
    freeze_time = 1,
    anim = 1,
    ed_drop_delay = 48,
    ed_drop_interval = 5,
    ed_drop_step = 2,
    ed_drop_end_y = 190,
    chain_tick_interval = 5,
    chain_long_dax = 4,
    chain_long_day = 169,
    chain_long_stop_y = 190,
    chain_tin_dax = 4,
    chain_tin_day = 69,
    chain_tin_show_ticks = 55,
    chain_tin_stop_y = 69,
    chain_vy = 3,
}

local KEYBOARD_START_FRAME = 720
local EDCHAIN_PATH = ROOT .. "/data/EDCHAIN.ASM"
local CONTROL_KEYS = {
    "KEYCODE_1", "KEYCODE_2",
    "KEYCODE_LEFT", "KEYCODE_RIGHT", "KEYCODE_UP", "KEYCODE_DOWN",
    "KEYCODE_A", "KEYCODE_D", "KEYCODE_W", "KEYCODE_S",
    "KEYCODE_Z", "KEYCODE_X", "KEYCODE_C", "KEYCODE_V",
    "KEYCODE_T", "KEYCODE_SPACE", "KEYCODE_F", "KEYCODE_N",
    "KEYCODE_R", "KEYCODE_P",
}

local state = {}
for k, v in pairs(defaults) do state[k] = v end
local anim_tick = 0

local logf = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
    print(line)
    if logf then
        logf:write(line .. "\n")
        logf:flush()
    end
end

local function map_symbol(name, fallback)
    local f = io.open(MAP_PATH, "r")
    if not f then return fallback end
    for line in f:lines() do
        for addr, sym in line:gmatch("([0-9A-Fa-f]+)%s+([_%w]+)") do
            if sym == name then
                f:close()
                return tonumber(addr, 16)
            end
        end
    end
    f:close()
    return fallback
end

local space = manager.machine.devices[":maincpu"].spaces["program"]

local A = {
    objlst = map_symbol("objlst", 0x01127570),
    objlst2 = map_symbol("objlst2", 0x01127590),
    objlst3 = map_symbol("objlst3", 0x011275b0),
    curback = map_symbol("curback", 0x0112c0d0),
    gstate = map_symbol("gstate", 0x0112a7d0),
    worldtlx = map_symbol("worldtlx", 0x0112c050),
    f_freeze_timer = map_symbol("f_freeze_timer", 0),
    clk_tens = map_symbol("clk_tens", 0),
    clk_ones = map_symbol("clk_ones", 0),
    longchain = map_symbol("longchain", 0),
    TINCHAIN4 = map_symbol("TINCHAIN4", 0),
    TINHOOK = map_symbol("TINHOOK", 0),
    BUBL1 = map_symbol("BUBL1", 0),
    BUBL2 = map_symbol("BUBL2", 0),
    BUBL3 = map_symbol("BUBL3", 0),
    BUBL4 = map_symbol("BUBL4", 0),
    greendrip0 = map_symbol("greendrip0", 0),
    greendrip1 = map_symbol("greendrip1", 0),
    greendrip2 = map_symbol("greendrip2", 0),
    greendrip3 = map_symbol("greendrip3", 0),
    greendrip4 = map_symbol("greendrip4", 0),
    greendrip5 = map_symbol("greendrip5", 0),
    greendrip6 = map_symbol("greendrip6", 0),
    greendrip7 = map_symbol("greendrip7", 0),
    greendrip8 = map_symbol("greendrip8", 0),
    aciddrip = map_symbol("aciddrip", 0),
    aciddrip1 = map_symbol("aciddrip1", 0),
    aciddrip2 = map_symbol("aciddrip2", 0),
    aciddrip3 = map_symbol("aciddrip3", 0),
    pooldrip1 = map_symbol("pooldrip1", 0),
}

local img_names = {}
for _, name in ipairs({
    "longchain", "TINCHAIN4", "TINHOOK",
    "BUBL1", "BUBL2", "BUBL3", "BUBL4",
    "greendrip0", "greendrip1", "greendrip2", "greendrip3",
    "greendrip4", "greendrip5", "greendrip6", "greendrip7",
    "greendrip8", "aciddrip", "aciddrip1", "aciddrip2",
    "aciddrip3", "pooldrip1",
}) do
    if A[name] and A[name] ~= 0 then
        img_names[A[name]] = name
    end
end

local O = {
    olink = 0x000,
    oxval = 0x080,
    oxpos = 0x090,
    oyval = 0x0a0,
    oypos = 0x0b0,
    ozval = 0x0c0,
    ozpos = 0x0d0,
    opal = 0x140,
    oflags2 = 0x160,
    oimg = 0x1a0,
    oid = 0x1c0,
    oshape = 0x1d0,
}

local function r16(a)
    local ok, v = pcall(function() return space:read_u16(a) end)
    return ok and v or 0
end

local function r32(a)
    local ok, v = pcall(function() return space:read_u32(a) end)
    return ok and v or 0
end

local function w16(a, v)
    v = v % 0x10000
    pcall(function() space:write_u16(a, v) end)
end

local function w32(a, v)
    v = v % 0x100000000
    pcall(function() space:write_u32(a, v) end)
end

local function s16(v)
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

local function fixed(v)
    return (v * 0x10000) % 0x100000000
end

local function load_edchain_points(label)
    local pts = {}
    local f = io.open(EDCHAIN_PATH, "r")
    if not f then
        return pts
    end
    local in_pts = false
    for line in f:lines() do
        if line:match("^" .. label .. "%s*$") then
            in_pts = true
        elseif in_pts and line:match("^%s*%.word") then
            local x, y = line:match("%.word%s+(-?%d+)%s*,%s*(-?%d+)")
            if x and y then
                pts[#pts + 1] = { x = tonumber(x), y = tonumber(y) }
            end
        elseif in_pts and line:match("^%S") then
            break
        end
    end
    f:close()
    return pts
end

local edchain_long_points = load_edchain_points("edch_s3_pts")
local edchain_tin_points = load_edchain_points("edch_s4_pts")

local function world_xofs()
    return s16(r16(A.worldtlx + 16))
end

local function obj_set_pos(p, x, y, z)
    w16(p + O.oxpos, x)
    w32(p + O.oxval, fixed(x))
    w16(p + O.oypos, y)
    w32(p + O.oyval, fixed(y))
    w16(p + O.ozpos, z)
    w32(p + O.ozval, fixed(z))
end

local function set_visible(p, visible)
    local flags2 = r16(p + O.oflags2)
    if visible then
        flags2 = flags2 & (~M_INVIS & 0xffff)
    else
        flags2 = flags2 | M_INVIS
    end
    w16(p + O.oflags2, flags2)
end

local function apply_round_time_freeze()
    if not A.f_freeze_timer or A.f_freeze_timer == 0 then return end
    if r16(A.gstate) == 2 then
        w16(A.f_freeze_timer, state.freeze_time ~= 0 and 1 or 0)
    else
        w16(A.f_freeze_timer, 0)
    end
end

local function walk_list(addr, fn)
    local p = r32(addr)
    local count = 0
    while p ~= 0 and count < 160 do
        fn(p)
        p = r32(p + O.olink)
        count = count + 1
    end
end

local function find_body()
    local found
    walk_list(A.objlst, function(p)
        if found then return end
        local oid = r16(p + O.oid)
        local flags2 = r16(p + O.oflags2)
        if oid == PID_EDPOOL_FX and (flags2 & M_MULTIPART) ~= 0 then
            found = p
        end
    end)
    return found
end

local function find_chain_objects()
    local out = {}
    local function maybe_add(p)
        local oid = r16(p + O.oid)
        local img = r32(p + O.oimg)
        if oid == PID_EDPOOL_PREVIEW and
            (img == A.longchain or img == A.TINCHAIN4 or img == A.TINHOOK) then
            out[#out + 1] = p
        end
    end
    walk_list(A.objlst, maybe_add)
    walk_list(A.objlst2, maybe_add)
    walk_list(A.objlst3, maybe_add)
    return out
end

local function find_bubble_objects()
    local out = {}
    walk_list(A.objlst, function(p)
        local oid = r16(p + O.oid)
        local flags2 = r16(p + O.oflags2)
        if oid == PID_EDPOOL_FX and (flags2 & M_MULTIPART) == 0 then
            out[#out + 1] = p
        end
    end)
    return out
end

local frame = 0
local track = {}
local chain_seen = false

local function anim_elapsed()
    if state.anim == 0 then return nil end
    return anim_tick
end

local function restart_animation()
    state.anim = 1
    state.paused = 0
    anim_tick = 0
    chain_seen = false
    track = {}
    log("restart animation at anchor=(%d,%d) rel=(%d,%d)",
        state.anchor_x, state.anchor_y, state.ed_xofs, state.ed_yofs)
end

local function ed_anim_y(base_y)
    if state.anim == 0 then
        return base_y
    end
    local elapsed = math.max(0, anim_tick - state.ed_drop_delay)
    if elapsed <= 0 then
        return base_y
    end
    local steps = math.floor(elapsed / math.max(1, state.ed_drop_interval))
    return math.min(state.ed_drop_end_y, base_y + (steps * state.ed_drop_step))
end

local function chain_anim_rows()
    if state.anim == 0 then return 0 end
    local interval = math.max(1, state.chain_tick_interval)
    return math.floor(math.max(0, anim_tick) / interval)
end

local function chain_start_y(points, fallback_day)
    if #points > 0 then
        return state.anchor_y - (points[1].y or fallback_day)
    end
    return state.anchor_y - fallback_day
end

local function longchain_anim_y()
    local y = chain_start_y(edchain_long_points, state.chain_long_day)
    if state.anim == 0 then return y end
    return math.min(state.chain_long_stop_y, y + (chain_anim_rows() * state.chain_vy))
end

local function tinchain_anim_y()
    local y = chain_start_y(edchain_tin_points, state.chain_tin_day)
    if state.anim == 0 then return y, true end
    local rows = chain_anim_rows()
    if rows < state.chain_tin_show_ticks then
        return y, false
    end
    local visible_rows = rows - state.chain_tin_show_ticks
    return math.min(state.chain_tin_stop_y, y + (visible_rows * state.chain_vy)), true
end

local function track_obj(p, kind)
    local key = string.format("%08X:%s", p, kind)
    local img = r32(p + O.oimg)
    local x = s16(r16(p + O.oxpos))
    local y = s16(r16(p + O.oypos))
    local z = s16(r16(p + O.ozpos))
    local t = track[key]
    if not t then
        t = {
            img = img, x = x, y = y, z = z,
            last_img_frame = frame,
            last_move_frame = frame,
            img_interval = 0,
            move_interval = 0,
            dx = 0,
            dy = 0,
        }
        track[key] = t
        return t
    end
    if img ~= t.img then
        t.img_interval = frame - t.last_img_frame
        t.last_img_frame = frame
        t.img = img
    end
    if x ~= t.x or y ~= t.y or z ~= t.z then
        t.move_interval = frame - t.last_move_frame
        t.dx = x - t.x
        t.dy = y - t.y
        t.last_move_frame = frame
        t.x = x
        t.y = y
        t.z = z
    end
    return t
end

local function summarize_bubbles(bubbles)
    local count = #bubbles
    if count == 0 then
        return {
            count = 0,
            z_min = 0,
            z_max = 0,
            img_interval = 0,
            lines = {},
        }
    end
    local z_min, z_max
    local interval_total = 0
    local interval_count = 0
    local lines = {}
    for i, p in ipairs(bubbles) do
        local z = s16(r16(p + O.ozpos))
        z_min = z_min and math.min(z_min, z) or z
        z_max = z_max and math.max(z_max, z) or z
        local t = track_obj(p, "bubble")
        if t.img_interval and t.img_interval > 0 then
            interval_total = interval_total + t.img_interval
            interval_count = interval_count + 1
        end
        if i <= 8 then
            local img = r32(p + O.oimg)
            lines[#lines + 1] = string.format(
                "bubble_%02d obj=0x%08X img=%s/0x%08X screen=(%d,%d,%d) img_speed=%s frames",
                i, p, img_names[img] or "?", img,
                s16(r16(p + O.oxpos)) - world_xofs(), s16(r16(p + O.oypos)),
                z, (t.img_interval and t.img_interval > 0) and tostring(t.img_interval) or "measuring")
        end
    end
    return {
        count = count,
        z_min = z_min or 0,
        z_max = z_max or 0,
        img_interval = interval_count > 0 and (interval_total / interval_count) or 0,
        lines = lines,
    }
end

local function summarize_chains(chains)
    local count = #chains
    local z_min, z_max
    local move_total = 0
    local move_count = 0
    local lines = {}
    for i, p in ipairs(chains) do
        local z = s16(r16(p + O.ozpos))
        z_min = z_min and math.min(z_min, z) or z
        z_max = z_max and math.max(z_max, z) or z
        local t = track_obj(p, "chain")
        if t.move_interval and t.move_interval > 0 then
            move_total = move_total + t.move_interval
            move_count = move_count + 1
        end
        local img = r32(p + O.oimg)
        lines[#lines + 1] = string.format(
            "chain_%02d obj=0x%08X img=%s/0x%08X screen=(%d,%d,%d) move_speed=%s frames dx=%d dy=%d",
            i, p, img_names[img] or "?", img,
            s16(r16(p + O.oxpos)) - world_xofs(), s16(r16(p + O.oypos)),
            z, (t.move_interval and t.move_interval > 0) and tostring(t.move_interval) or "static/measuring",
            t.dx or 0, t.dy or 0)
    end
    return {
        count = count,
        z_min = z_min or 0,
        z_max = z_max or 0,
        move_interval = move_count > 0 and (move_total / move_count) or 0,
        lines = lines,
    }
end

local function first_screen()
    if manager.machine.screens[":screen"] then
        return manager.machine.screens[":screen"]
    end
    for _, screen in pairs(manager.machine.screens) do
        return screen
    end
    return nil
end

local screen = first_screen()
local overlay_warned = false
local function draw_line(y, text)
    if not screen then return end
    local ok = pcall(function()
        screen:draw_text(6, y, text, 0xffffffff, 0x80000000)
    end)
    if not ok and not overlay_warned then
        overlay_warned = true
        log("screen draw_text unavailable; using file readout only")
    end
end

local function draw_overlay(body, chains)
    local wx = world_xofs()
    local bubbles = find_bubble_objects()
    local bubble_summary = summarize_bubbles(bubbles)
    local chain_summary = summarize_chains(chains)
    local body_line = "ED missing"
    if body then
        body_line = string.format("ED screen %d,%d z %d   world %d,%d z %d",
            s16(r16(body + O.oxpos)) - wx, s16(r16(body + O.oypos)),
            s16(r16(body + O.ozpos)), s16(r16(body + O.oxpos)),
            s16(r16(body + O.oypos)), s16(r16(body + O.ozpos)))
    end

    draw_line(8, body_line)
    draw_line(18, string.format("ANCHOR %d,%d  REL %d,%d",
        state.anchor_x, state.anchor_y, state.ed_xofs, state.ed_yofs))
    draw_line(28, string.format("BUB z %d..%d  speed %.1f frames  count %d",
        bubble_summary.z_min, bubble_summary.z_max, bubble_summary.img_interval,
        bubble_summary.count))
    draw_line(38, string.format("CHAIN z %d..%d  speed %.1f frames  count %d",
        chain_summary.z_min, chain_summary.z_max, chain_summary.move_interval,
        chain_summary.count))
    draw_line(48, string.format("KEYS %s step %d  ARROWS chain  WASD Ed",
        (state.keyboard ~= 0 and frame >= KEYBOARD_START_FRAME) and "ON" or "WAIT/OFF",
        state.step))
    draw_line(58, string.format("TIME %s ROUND %s  T restart SPACE pause N step",
        state.paused ~= 0 and "PAUSED" or "PLAY",
        state.freeze_time ~= 0 and "FROZEN" or "LIVE"))
    draw_line(68, string.format("ANIM %s elapsed %s  File: tmp/dp/ed_tune_current.txt",
        state.anim ~= 0 and "ON" or "HOLD",
        anim_elapsed() and tostring(anim_elapsed()) or "-"))
end

local key_cache = {}
local key_prev = {}
local input_ok = true
local keyboard_armed = false
local function key_down(token)
    if not input_ok then return false end
    local code = key_cache[token]
    if code == nil then
        local ok, v = pcall(function()
            return manager.machine.input:code_from_token(token)
        end)
        if not ok or not v then
            input_ok = false
            log("keyboard input API unavailable; edit %s instead", CONTROL_PATH)
            return false
        end
        code = v
        key_cache[token] = code
    end
    local ok, pressed = pcall(function()
        return manager.machine.input:code_pressed(code)
    end)
    if not ok then
        input_ok = false
        log("keyboard polling failed; edit %s instead", CONTROL_PATH)
        return false
    end
    return pressed
end

local function key_pressed(token)
    local down = key_down(token)
    local prev = key_prev[token] or false
    key_prev[token] = down
    return down and not prev
end

local function any_control_key_down()
    for _, token in ipairs(CONTROL_KEYS) do
        if key_down(token) then
            return true
        end
    end
    return false
end

local last_control = nil
local function read_control()
    local f = io.open(CONTROL_PATH, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    if text == last_control then return end
    last_control = text

    local old_anim = state.anim
    for k, v in text:gmatch("([%w_]+)%s*=%s*(-?%d+)") do
        if state[k] ~= nil then
            state[k] = tonumber(v)
        end
    end
    if state.anim ~= 0 and old_anim == 0 then
        anim_tick = 0
    end
    if state.anim ~= 0 and state.paused == 0 and old_anim == 0 then
        restart_animation()
    end
    log("loaded control: anchor=(%d,%d) rel=(%d,%d) ed_z=%d chain_z=%d step=%d paused=%d anim=%d",
        state.anchor_x, state.anchor_y, state.ed_xofs, state.ed_yofs,
        state.ed_z, state.chain_z, state.step, state.paused, state.anim)
end

local function write_control_template()
    local f = io.open(CONTROL_PATH, "r")
    if f then
        f:close()
        return
    end
    f = io.open(CONTROL_PATH, "w")
    if not f then return end
    f:write("# Dead Pool Ed tuner control. Edit/save while MAME is running.\n")
    f:write("# Ed placement uses EDCHAIN slot2: x=anchor_x+ed_xofs, y=anchor_y-ed_yofs.\n")
    f:write(string.format("anchor_x=%d\n", state.anchor_x))
    f:write(string.format("anchor_y=%d\n", state.anchor_y))
    f:write(string.format("ed_xofs=%d\n", state.ed_xofs))
    f:write(string.format("ed_yofs=%d\n", state.ed_yofs))
    f:write(string.format("ed_z=%d\n", state.ed_z))
    f:write(string.format("chain_z=%d\n", state.chain_z))
    f:write(string.format("step=%d\n", state.step))
    f:write(string.format("keyboard=%d\n", state.keyboard))
    f:write(string.format("paused=%d\n", state.paused))
    f:write(string.format("freeze_time=%d\n", state.freeze_time))
    f:write(string.format("anim=%d\n", state.anim))
    f:write(string.format("ed_drop_delay=%d\n", state.ed_drop_delay))
    f:write(string.format("ed_drop_interval=%d\n", state.ed_drop_interval))
    f:write(string.format("ed_drop_step=%d\n", state.ed_drop_step))
    f:write(string.format("ed_drop_end_y=%d\n", state.ed_drop_end_y))
    f:write(string.format("chain_tick_interval=%d\n", state.chain_tick_interval))
    f:write(string.format("chain_long_stop_y=%d\n", state.chain_long_stop_y))
    f:write(string.format("chain_tin_show_ticks=%d\n", state.chain_tin_show_ticks))
    f:write(string.format("chain_tin_stop_y=%d\n", state.chain_tin_stop_y))
    f:write(string.format("chain_vy=%d\n", state.chain_vy))
    f:close()
end

local function write_current(body, chains, reason)
    local wx = world_xofs()
    local ed_screen_x = state.anchor_x + state.ed_xofs
    local ed_screen_y = state.anchor_y - state.ed_yofs
    local bubbles = find_bubble_objects()
    local bubble_summary = summarize_bubbles(bubbles)
    local chain_summary = summarize_chains(chains)

    local f = io.open(CURRENT_PATH, "w")
    if not f then return end
    f:write(string.format("reason=%s\n", reason or "tick"))
    f:write(string.format("curback=%d gstate=%d worldtlx_plus16=%d\n",
        r16(A.curback), r16(A.gstate), wx))
    f:write(string.format("anchor_x=%d\nanchor_y=%d\n", state.anchor_x, state.anchor_y))
    f:write(string.format("ed_xofs=%d\ned_yofs=%d\n", state.ed_xofs, state.ed_yofs))
    f:write(string.format("ed_screen_x=%d\ned_screen_y=%d\ned_z=%d\n",
        ed_screen_x, ed_screen_y, state.ed_z))
    f:write(string.format("chain_z=%d\n", state.chain_z))
    f:write(string.format("paused=%d\n", state.paused))
    f:write(string.format("freeze_time=%d\n", state.freeze_time))
    f:write(string.format("clk_tens=%d\nclk_ones=%d\n",
        A.clk_tens ~= 0 and r16(A.clk_tens) or -1,
        A.clk_ones ~= 0 and r16(A.clk_ones) or -1))
    f:write(string.format("anim=%d\n", state.anim))
    f:write(string.format("anim_elapsed=%s\n", anim_elapsed() and tostring(anim_elapsed()) or "-"))
    f:write(string.format("ed_drop_delay=%d\ned_drop_interval=%d\ned_drop_step=%d\ned_drop_end_y=%d\n",
        state.ed_drop_delay, state.ed_drop_interval, state.ed_drop_step,
        state.ed_drop_end_y))
    f:write(string.format("chain_tick_interval=%d\n", state.chain_tick_interval))
    f:write(string.format("chain_long_stop_y=%d\n", state.chain_long_stop_y))
    f:write(string.format("chain_tin_show_ticks=%d\n", state.chain_tin_show_ticks))
    f:write(string.format("chain_tin_stop_y=%d\n", state.chain_tin_stop_y))
    f:write(string.format("chain_vy=%d\n", state.chain_vy))
    f:write(string.format("bubble_count=%d\n", bubble_summary.count))
    f:write(string.format("bubble_z_min=%d\nbubble_z_max=%d\n", bubble_summary.z_min, bubble_summary.z_max))
    f:write(string.format("bubble_img_speed_frames=%.2f\n", bubble_summary.img_interval))
    f:write(string.format("chain_count=%d\n", chain_summary.count))
    f:write(string.format("chain_z_min=%d\nchain_z_max=%d\n", chain_summary.z_min, chain_summary.z_max))
    f:write(string.format("chain_move_speed_frames=%.2f\n", chain_summary.move_interval))
    f:write("\nASM copyback:\n")
    f:write(string.format("ed_chain_anchor_x .equ\t%d\n", state.anchor_x))
    f:write(string.format("ed_chain_anchor_y .equ\t%d\n", state.anchor_y))
    f:write(string.format("ed_body_chain_xofs .equ\t%d\n", state.ed_xofs))
    f:write(string.format("ed_body_chain_yofs .equ\t%d\n", state.ed_yofs))
    f:write(string.format("ed_preview_body_z .equ\t%d\n", state.ed_z))
    f:write(string.format("ed_preview_chain_z .equ\t%d\n", state.chain_z))
    if body then
        f:write(string.format("\nbody_obj=0x%08X world=(%d,%d,%d) screen=(%d,%d,%d)\n",
            body, s16(r16(body + O.oxpos)), s16(r16(body + O.oypos)),
            s16(r16(body + O.ozpos)), s16(r16(body + O.oxpos)) - wx,
            s16(r16(body + O.oypos)), s16(r16(body + O.ozpos))))
    end
    for i, p in ipairs(chains) do
        f:write(string.format("chain_obj_%d=0x%08X img=0x%08X world=(%d,%d,%d) screen=(%d,%d,%d)\n",
            i, p, r32(p + O.oimg), s16(r16(p + O.oxpos)),
            s16(r16(p + O.oypos)), s16(r16(p + O.ozpos)),
            s16(r16(p + O.oxpos)) - wx, s16(r16(p + O.oypos)),
            s16(r16(p + O.ozpos))))
    end
    f:write("\nBubble readout:\n")
    for _, line in ipairs(bubble_summary.lines) do f:write(line .. "\n") end
    f:write("\nChain readout:\n")
    for _, line in ipairs(chain_summary.lines) do f:write(line .. "\n") end
    f:close()
end

local function mark(reason)
    local body = find_body()
    local chains = find_chain_objects()
    write_current(body, chains, reason)
    log("%s anchor=(%d,%d) rel=(%d,%d) ed_screen=(%d,%d,%d) chain_z=%d body=%s chains=%d",
        reason or "mark", state.anchor_x, state.anchor_y, state.ed_xofs,
        state.ed_yofs, state.anchor_x + state.ed_xofs,
        state.anchor_y - state.ed_yofs, state.ed_z, state.chain_z,
        body and string.format("0x%08X", body) or "missing", #chains)
end

local function poll_keys()
    if state.keyboard == 0 then return false end
    if frame < KEYBOARD_START_FRAME then return false end
    if not keyboard_armed then
        if any_control_key_down() then
            return false
        end
        keyboard_armed = true
        log("keyboard controls armed")
    end
    local step = state.step
    local changed = false
    if key_down("KEYCODE_1") then state.step = 1; step = 1; changed = true end
    if key_down("KEYCODE_2") then state.step = 4; step = 4; changed = true end

    if key_down("KEYCODE_LEFT") then state.anchor_x = state.anchor_x - step; changed = true end
    if key_down("KEYCODE_RIGHT") then state.anchor_x = state.anchor_x + step; changed = true end
    if key_down("KEYCODE_UP") then state.anchor_y = state.anchor_y - step; changed = true end
    if key_down("KEYCODE_DOWN") then state.anchor_y = state.anchor_y + step; changed = true end

    if key_down("KEYCODE_A") then state.ed_xofs = state.ed_xofs - step; changed = true end
    if key_down("KEYCODE_D") then state.ed_xofs = state.ed_xofs + step; changed = true end
    if key_down("KEYCODE_W") then state.ed_yofs = state.ed_yofs + step; changed = true end
    if key_down("KEYCODE_S") then state.ed_yofs = state.ed_yofs - step; changed = true end

    if key_down("KEYCODE_Z") then state.ed_z = state.ed_z - 1; changed = true end
    if key_down("KEYCODE_X") then state.ed_z = state.ed_z + 1; changed = true end
    if key_down("KEYCODE_C") then state.chain_z = state.chain_z - 1; changed = true end
    if key_down("KEYCODE_V") then state.chain_z = state.chain_z + 1; changed = true end

    if key_pressed("KEYCODE_T") then
        restart_animation()
        changed = true
    end
    if key_pressed("KEYCODE_SPACE") then
        state.paused = state.paused == 0 and 1 or 0
        changed = true
    end
    if key_pressed("KEYCODE_F") then
        state.freeze_time = state.freeze_time == 0 and 1 or 0
        changed = true
    end
    if key_pressed("KEYCODE_N") then
        state.anim = 1
        state.paused = 1
        anim_tick = anim_tick + 1
        changed = true
    end
    if key_pressed("KEYCODE_R") then mark("manual") end
    if key_pressed("KEYCODE_P") and manager.machine.video then
        manager.machine.video:snapshot()
    end
    return changed
end

local function apply_state()
    local body = find_body()
    local chains = find_chain_objects()
    if #chains == 0 then
        chain_seen = false
    elseif state.anim ~= 0 and not chain_seen then
        anim_tick = 0
        chain_seen = true
        track = {}
        log("auto animation start at chain spawn")
    end
    local wx = world_xofs()
    local body_x = wx + state.anchor_x + state.ed_xofs
    local body_y = ed_anim_y(state.anchor_y - state.ed_yofs)
    local chain_x = wx + state.anchor_x
    local chain_y = longchain_anim_y()
    local tin_y, tin_visible = tinchain_anim_y()

    if body then
        obj_set_pos(body, body_x, body_y, state.ed_z)
        set_visible(body, true)
    end
    for _, p in ipairs(chains) do
        local img = r32(p + O.oimg)
        if img == A.longchain or img == A.TINHOOK then
            obj_set_pos(p, chain_x, chain_y, state.chain_z)
            set_visible(p, true)
        else
            w16(p + O.oxpos, chain_x)
            w32(p + O.oxval, fixed(chain_x))
            w16(p + O.oypos, tin_y)
            w32(p + O.oyval, fixed(tin_y))
            w16(p + O.ozpos, state.chain_z)
            w32(p + O.ozval, fixed(state.chain_z))
            set_visible(p, tin_visible)
        end
    end
    return body, chains
end

write_control_template()
read_control()
log("Dead Pool Ed tuner loaded")
log("keys: arrows chain, WASD Ed, T restart/play, Space pause, F round timer, N step, Z/X ed z, C/V chain z")
log("readout file: %s", CURRENT_PATH)

local last_mark = -999
emu.register_frame_done(function()
    frame = frame + 1
    if frame % 30 == 0 then read_control() end
    apply_round_time_freeze()
    local changed = poll_keys()
    if state.anim ~= 0 and state.paused == 0 then
        anim_tick = anim_tick + 1
    end
    local body, chains = apply_state()
    draw_overlay(body, chains)
    if (frame == 240 or frame == 360) and manager.machine.video then
        manager.machine.video:snapshot()
    end
    if changed or frame - last_mark >= 60 then
        write_current(body, chains, changed and "changed" or "heartbeat")
        last_mark = frame
    end
end)
