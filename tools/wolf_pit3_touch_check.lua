-- wolf_pit3_touch_check.lua - THE PIT III (curback 22h, Wolf): can a fighter
-- TOUCH Shao Kahn once he has stood up off his throne at FINISH HIM?
-- up3_wall (UMK3PIT3.ASM) stops a fighter's anchor short of the throne; this
-- measures, every tick of the FINISH HIM window, the GAP between the winner's
-- drawn pieces (every multipart node: x = oxpos - anix .. +sizex, y = oypos -
-- aniy .. +sizey) and Kahn's leftmost OPAQUE pixel on the same world row
-- (tmp/pit3kahn/profile.lua, tools/pit3_kahn_profile.py - per frame, keyed by
-- the record's WxH).  A gap < 0 is a touch.  The same boxes are also measured
-- against the SEATED Kahn (SHATAUNT1 + the shin) as the chair's reference.
-- The winner is parked inside the wall with the loser to his left, so he faces
-- left with Kahn at his back, then backs into the wall and works through:
-- walk, crouch, block, back jump, jump kick, roundhouse, sweep, HK, uppercut,
-- LK, HP - re-backing into the wall between moves.
-- Env: WS_MAP, P3T_PROF (absolute), P3T_CHAR (winner's ochar, default 6),
--      P3T_MIN (the gap that passes, default 0).
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_pit3_touch_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "curback", "p1_bar", "p2_bar",
                    "winner_status", "up3k_torso", "up3k_leg", "p1_matchw", "worldtlx"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local PROF = dofile(os.getenv("P3T_PROF"))
local CHAR = tonumber(os.getenv("P3T_CHAR") or "6")
local MIN = tonumber(os.getenv("P3T_MIN") or "0")
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function s16(a) local v = r16(a); return v >= 0x8000 and v - 0x10000 or v end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Down", "P1 Up",
               "P1 Right", "P1 Left", "P1 Block", "P1 High Kick", "P1 Low Kick", "P1 Low Punch"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local function key_of(obj)
    local img = r32(obj + 0x1a0)
    if img == 0 then return nil end
    return string.format("%dx%d", r16(img), r16(img + 16))
end
-- Kahn's left edge on row y, as he is drawn now (torso + legs/shin)
local function kahn_left(objs, y)
    local best
    for _, p in ipairs(objs) do
        local x = p.rows[y]
        if x and (not best or x < best) then best = x end
    end
    return best
end
local function boxes(obj)
    local ram = r32(obj + 0x1a0)
    local ox, oy = s16(obj + 0x090), s16(obj + 0x0b0)
    local out = {}
    for n = 0, 31 do
        if r32(ram) == 0 then break end
        local x0 = ox - s16(ram + 80)
        local y0 = oy - s16(ram + 96)
        out[#out + 1] = {x0, x0 + r16(ram + 32) - 1, y0, y0 + r16(ram + 48) - 1}
        ram = ram + 112
    end
    return out
end
local function gap(bx, objs)
    local g
    for _, b in ipairs(bx) do
        for y = b[3], b[4] do
            local k = kahn_left(objs, y)
            if k then
                local d = k - b[2] - 1
                if not g or d < g then g = d end
            end
        end
    end
    return g
end
local SEATED = {PROF["68x59"], PROF["24x48"]}
-- the script: {ticks, inputs...}
local PLAN = {
    {30, "P1 Right"}, {20, "P1 Right", "P1 Down"}, {20, "P1 Right", "P1 Block"},
    {12, "P1 Right"}, {40, "P1 Right", "P1 Up"},
    {12, "P1 Right"}, {6, "P1 Up"}, {14}, {30, "P1 High Kick"},
    {12, "P1 Right"}, {36, "P1 Right", "P1 High Kick"},
    {12, "P1 Right"}, {36, "P1 Right", "P1 Low Kick"},
    {12, "P1 Right"}, {6, "P1 High Kick"}, {30},
    {12, "P1 Right"}, {6, "P1 Down"}, {4, "P1 Down", "P1 High Punch"}, {28},
    {12, "P1 Right"}, {6, "P1 Low Kick"}, {30},
    {12, "P1 Right"}, {6, "P1 High Punch"}, {30},
    {20, "P1 Right"},
}
local PNAME = {"walk", "crouch", "block", "-", "backjump", "-", "jump", "-", "jumpkick", "-", "roundhouse",
               "-", "sweep", "-", "HK", "HK", "-", "uppercut", "uppercut", "uppercut", "-", "LK", "LK", "-",
               "HP", "HP", "walk"}
local frame, started, sel, fight, confirm, fin = 0, false, nil, nil, nil, nil
local worst, worstseat, maxx = {}, {}, -9999
local function finish(ok, why) log("%s: %s", ok and "PASS" or "FAIL", why); f:close(); manager.machine:exit() end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start, winner ochar %d", CHAR)
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, CHAR); w16(A.p2_char, 11); w16(A.curback, 0x22)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; log("fight at %d", frame) end
        if frame > 12000 then finish(false, "no fight - NO VERDICT") end
        return
    end
    local rel = frame - fight
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if not fin then
        w16(A.p1_matchw, 1)
        w16(A.p1_bar, 0xa1)
        if rel < 400 then
            w16(A.p2_bar, 0xa1)
            if p1 ~= 0 and p2 ~= 0 then
                for i, o in ipairs({p1, p2}) do
                    local px = (i == 1) and 990 or 1030
                    w16(o + 0x090, px); w32(o + 0x080, (px & 0xffff) << 16)
                end
            end
            return
        end
        if r16(A.p2_bar) > 30 then w16(A.p2_bar, 30) end
        if r16(A.winner_status) == 3 then
            fin = frame; log("FINISH HIM at rel %d", rel)
            for i, o in ipairs({p1, p2}) do      -- winner inside the wall, loser to his left
                local px = (i == 1) and 960 or 860
                w16(o + 0x090, px); w32(o + 0x080, (px & 0xffff) << 16)
            end
            return
        end
        local c = rel % 150
        if p1 ~= 0 and p2 ~= 0 and c < 40 then
            for i, o in ipairs({p1, p2}) do
                local px = (i == 1) and 990 or 1030
                w16(o + 0x090, px); w32(o + 0x080, (px & 0xffff) << 16)
            end
        elseif c < 60 then
            F["P1 Down"]:set_value(1)
            if c >= 48 and c < 52 then F["P1 High Punch"]:set_value(1) end
        end
        if rel > 5000 then finish(false, "no FINISH HIM - NO VERDICT") end
        return
    end
    local t = frame - fin
    if t < 3 then return end
    -- drive the plan
    local acc, step = 0, nil
    for i, p in ipairs(PLAN) do
        if t - 3 < acc + p[1] then step = i; break end
        acc = acc + p[1]
    end
    if not step then
        local parts = {}
        local bad = false
        for i = 1, #PNAME do
            if worst[i] then
                parts[#parts + 1] = string.format("%s %d/%d", PNAME[i], worst[i], worstseat[i] or 99)
                if worst[i] < MIN then bad = true end
            end
        end
        log("gap to standing Kahn / to the seated one, per beat (px, <0 = touching): %s", table.concat(parts, ", "))
        log("max winner anchor x %d", maxx)
        local g, gs2 = 9999, 9999
        for i = 1, #PNAME do
            if worst[i] and worst[i] < g then g = worst[i] end
            if worstseat[i] and worstseat[i] < gs2 then gs2 = worstseat[i] end
        end
        return finish(not bad, string.format("closest approach %d px to standing Kahn (%d px to the seated one), need >= %d",
            g, gs2, MIN))
    end
    for i = 2, #PLAN[step] do F[PLAN[step][i]]:set_value(1) end
    -- measure, once he is up (torso on a standing frame)
    local tk, lk = key_of(r32(A.up3k_torso)), key_of(r32(A.up3k_leg))
    local objs = {}
    if tk and PROF[tk] then objs[#objs + 1] = PROF[tk] end
    if lk and PROF[lk] then objs[#objs + 1] = PROF[lk] end
    if p1 == 0 then return end
    local bx = boxes(p1)
    maxx = math.max(maxx, s16(p1 + 0x090))
    local g = gap(bx, objs)
    local gseat = gap(bx, SEATED)
    if g and (not worst[step] or g < worst[step]) then
        worst[step] = g
        if g < MIN then log("  t %d %s: gap %d (Kahn %s, winner x %d)", t, PNAME[step], g,
            (objs[1] and objs[1].name or "?"), s16(p1 + 0x090)) end
    end
    if gseat and (not worstseat[step] or gseat < worstseat[step]) then worstseat[step] = gseat end
end)
