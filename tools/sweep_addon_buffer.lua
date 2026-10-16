-- sweep_addon_buffer.lua - does an input during recovery survive?
--
-- Section 2.4 of doc/TOURNAMENT_READINESS.md: whether a button pressed while
-- a fighter is still busy comes out on the first actionable frame, or is
-- simply dropped, is undocumented - so "why did nothing come out" has had no
-- answer. It decides whether a punish has to be timed to the frame or can be
-- held early, which is most of what a player practises.
--
-- Method: P1 throws a high punch, then a LOW KICK is pressed at a varying
-- offset K ticks after the first press. If the kick appears at all, the input
-- survived; if it appears at a fixed tick regardless of K, that tick is the
-- first actionable frame and the game is buffering.
--
-- The second move is identified by its ACTION (act_medkick, 0104h), not by
-- damage: at this range the high punch also connects, and "health dropped
-- twice" cannot tell a buffered kick from a second hit of the same move.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/buffer.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, P_ACTION, MAX_HP = 0x090, 0x080, 0x1f0, 0xA1
local ACT_STANCE, ACT_HIPUNCH, ACT_MEDKICK = 0x0303, 0x0101, 0x0104

-- The coarse sweep put the boundary between 16 (dropped) and 20
-- (came out at K+3); this narrows it to the tick.
local OFFSETS = { 15, 16, 17, 18, 19, 20, 21, 22 }
local DIST, TRIAL, FIRST, HOLD = 70, 110, 12, 2

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[buf] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, idx, cur, done = {}, 0, nil, false
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on) if fl[n] then fl[n]:set_value(on and 1 or 0) end end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        local want = { ["P1 Right"] = "R", ["P1 Left"] = "L",
                       ["P1 Down"] = "D", ["P1 High Punch"] = "HP",
                       ["P1 Low Kick"] = "LK" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        log("=== recovery buffering === HP at t=0, LK at t=K")
    end
    if done then return end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end
    if t0 == nil then t0 = frame end

    local rel = (frame - t0) % TRIAL
    if rel == 0 then
        if cur then
            log("K=%-3d punch@%-4s kick@%-6s %s", cur.k,
                cur.hp and tostring(cur.hp) or "-",
                cur.lk and tostring(cur.lk) or "never",
                cur.valid and "" or "(REJECTED: dummy not ready)")
        end
        idx = idx + 1
        if idx > #OFFSETS then done = true; log("cases_done"); return end
        cur = { k = OFFSETS[idx] }
    end
    if not cur then return end

    local vx = s16(space:read_u16(right_edge)) - 120
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o1 + OXVAL, ((vx - DIST) << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - DIST)

    press("R", false); press("L", false); press("D", false)
    press("HP", rel >= FIRST and rel < FIRST + HOLD)
    press("LK", rel >= FIRST + cur.k and rel < FIRST + cur.k + HOLD)

    if rel == FIRST then
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
        cur.valid = (space:read_u16(r2 + P_ACTION) == ACT_STANCE)
    end
    if rel < FIRST or not cur.valid then return end
    local since = rel - FIRST
    local a = space:read_u16(r1 + P_ACTION)
    if cur.hp == nil and a == ACT_HIPUNCH then cur.hp = since end
    if cur.lk == nil and a == ACT_MEDKICK then cur.lk = since end
end)

emu.register_stop(function()
    if cur and not done then
        log("K=%-3d punch@%-4s kick@%-6s", cur.k,
            cur.hp and tostring(cur.hp) or "-",
            cur.lk and tostring(cur.lk) or "never")
    end
    log("run_end")
end)
