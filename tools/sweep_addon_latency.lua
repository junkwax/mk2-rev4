-- sweep_addon_latency.lua - button edge to the hit landing.
--
-- Section 2.3 of doc/TOURNAMENT_READINESS.md. NETPLAY.md records that debounce
-- went from 2 frames to 1, and that change is global so offline got it too,
-- but the whole path was never measured: press to acceptance, and press to the
-- moment the other fighter actually loses health. It is the number people
-- compare cabinets and emulators with.
--
-- Two numbers per move, both counted from the tick the button goes down:
--
--   accept   ticks until P1 leaves stance - the game took the input
--   impact   ticks until P2's bar drops   - the hit landed
--
-- accept is the input path on its own. impact is accept plus the move's
-- startup, so it should agree with FRAME_ADVANTAGE.md's startup column; where
-- it does not, one of the two is wrong and that is worth knowing.
--
-- The dummy is a second human port with nothing pressed. Both fighters are
-- pinned at a distance the move connects from, taken from the behaviour cases
-- that already measured which ranges connect.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/latency.txt"

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
local ACT_STANCE = 0x0303

-- name, distance, held direction, button, trials
local CASES = {
    { "hipunch",  70, nil, "HP" },
    { "lowkick",  70, nil, "LK" },
    { "uppercut", 50, "d", "HP" },
    { "swipe",    90, "b", "HP" },
}
-- 90, not 70: an uppercut knocks the dummy down, and a trial that
-- restarts while he is still getting up scores no impact at all -
-- the first run landed 4 of 8 for exactly that reason.
local TRIAL, PRESS_AT, HOLD = 90, 12, 2

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[lat] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, idx, cur, done = {}, 0, nil, false
local acc, imp = {}, {}
local rejected = 0
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on) if fl[n] then fl[n]:set_value(on and 1 or 0) end end

local function report(name)
    local function stat(t, what)
        if #t == 0 then log("%-9s %-7s no samples", name, what); return end
        table.sort(t)
        local s = 0
        for _, v in ipairs(t) do s = s + v end
        log("%-9s %-7s n=%-3d min=%-3d median=%-3d max=%-3d mean=%.2f ticks",
            name, what, #t, t[1], t[math.floor(#t / 2) + 1], t[#t], s / #t)
    end
    stat(acc, "accept"); stat(imp, "impact")
    if rejected > 0 then
        log("%-9s %-7s %d trial(s) rejected: dummy not standing "
            .. "and whole at the press", name, "", rejected)
    end
    acc, imp, rejected = {}, {}, 0
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        local want = { ["P1 Right"] = "R", ["P1 Left"] = "L",
                       ["P1 Down"] = "D", ["P1 High Punch"] = "HP",
                       ["P1 Low Punch"] = "LP", ["P1 Low Kick"] = "LK" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        log("=== input latency === press held %d ticks", HOLD)
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
    local trial = math.floor((frame - t0) / TRIAL)
    local case = CASES[idx == 0 and 1 or idx]

    if rel == 0 then
        -- 8 trials per case, then move on
        if cur and cur.n >= 8 then
            report(cur.name)
            idx = idx + 1
            if idx > #CASES then done = true; log("cases_done"); return end
            cur = nil
        end
        if idx == 0 then idx = 1 end
        local c = CASES[idx]
        cur = cur or { name = c[1], dist = c[2], dir = c[3], btn = c[4], n = 0 }
        cur.n = cur.n + 1
        cur.acc, cur.imp, cur.base = nil, nil, nil
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end
    local c = CASES[idx]

    local vx = s16(space:read_u16(right_edge)) - 120
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o1 + OXVAL, ((vx - c[2]) << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - c[2])

    -- direction is held from well before the press, so the measurement is the
    -- BUTTON's latency and not the stick's
    local holding = (rel >= 4 and rel < PRESS_AT + 14)
    press("R", holding and c[3] == "f")
    press("L", holding and c[3] == "b")
    press("D", holding and c[3] == "d")
    for _, b in ipairs({ "HP", "LP", "LK" }) do
        press(b, (rel >= PRESS_AT and rel < PRESS_AT + HOLD) and b == c[4])
    end

    -- Baseline the action AT THE PRESS, not against stance. A case that
    -- holds a direction has already left stance - ducking for the uppercut,
    -- walking back for the swipe - so "not stance" scored those as accept=0
    -- and measured nothing at all.
    -- A trial only counts if the dummy is STANDING and untouched when the
    -- button goes down. An uppercut knocks him over, and a trial that starts
    -- while he is still on the floor scores an impact from the previous hit's
    -- damage or none at all - which is why the uppercut landed 4 of 8 twice
    -- running while every other case landed 8 of 8.
    if rel == PRESS_AT then
        cur.base = space:read_u16(r1 + P_ACTION)
        cur.valid = (space:read_u16(r2 + P_ACTION) == ACT_STANCE)
                    and (space:read_u16(p2_bar) == MAX_HP)
        if not cur.valid then rejected = rejected + 1 end
    end
    if not cur.valid then return end
    if rel < PRESS_AT then return end
    local since = rel - PRESS_AT
    if cur.acc == nil and cur.base
       and space:read_u16(r1 + P_ACTION) ~= cur.base then
        cur.acc = since
        acc[#acc + 1] = since
    end
    if cur.imp == nil and space:read_u16(p2_bar) < MAX_HP then
        cur.imp = since
        imp[#imp + 1] = since
    end
end)

emu.register_stop(function()
    if cur and not done then report(cur.name) end
    log("run_end")
end)
