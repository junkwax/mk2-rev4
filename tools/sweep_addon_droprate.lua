-- sweep_addon_droprate.lua - what each named input hazard actually costs.
--
-- Section 2.2 of doc/TOURNAMENT_READINESS.md names three sharp edges and asks
-- for "a rig that reports drop rate ... and why (window expiry vs button_mask
-- vs a mismatched queue entry)".
--
-- Attributing a failure in the wild is not possible from outside - nothing
-- reports which check rejected. So instead each hazard is INTRODUCED on
-- purpose, one at a time, against a motion already measured as reliable. That
-- turns an unanswerable question ("why did that drop?") into an answerable
-- one ("what does this hazard cost?").
--
-- Baseline is Reptile's spit, F,F+HP with an 8-tick gap - measured 3/3 by
-- tools/sweep_addon_combogap.lua. Anything that drops below that is the
-- hazard, not the motion. Pinned 150 px apart so only the projectile can
-- reach and damage is unambiguous.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/droprate.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, MAX_HP = 0x090, 0x080, 0xA1

-- name, what is done differently
local CASES = {
    "clean",            -- the control: nothing extra
    "block_held",       -- Block down for the whole motion
    "hk_held",          -- a second attack button ridden
    "stray_down",       -- Down tapped between the two forwards
    "diagonal",         -- Down held while tapping forward twice
}
local REPS = 4
local DIST, TRIAL, HOLD, START, GAP = 150, 130, 3, 12, 8

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[drop] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, idx, rep, cur, done, hits = {}, 0, 0, nil, false, 0
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
                       ["P1 Block"] = "BL", ["P1 High Kick"] = "HK" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        local miss = {}
        for _, k in pairs(want) do
            if not fl[k] then miss[#miss + 1] = k end
        end
        log("=== drop rate === spit F,F+HP gap %d%s", GAP,
            (#miss > 0) and (" MISSING: " .. table.concat(miss, ",")) or "")
    end
    if done then return end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 == 0 or o2 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end
    if t0 == nil then t0 = frame end

    local rel = (frame - t0) % TRIAL
    if rel == 0 then
        if cur then hits = hits + (cur.hit and 1 or 0) end
        rep = rep + 1
        if rep > REPS then
            if idx > 0 then
                log("%-12s came out %d/%d", CASES[idx], hits, REPS)
            end
            hits, rep = 0, 1
            idx = idx + 1
            if idx > #CASES then done = true; log("cases_done"); return end
        end
        if idx == 0 then idx = 1 end
        cur = { name = CASES[idx], hit = false }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end

    local vx = s16(space:read_u16(right_edge)) - 60
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o1 + OXVAL, ((vx - DIST) << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - DIST)

    local c = cur.name
    local motion = (rel >= START and rel < START + HOLD)
                or (rel >= START + GAP and rel < START + GAP + HOLD)
    local during = (rel >= START - 2 and rel < START + GAP + 8)

    press("L", false)
    press("R", motion)
    press("HP", rel >= START + GAP + 2 and rel < START + GAP + 2 + HOLD)
    press("BL", c == "block_held" and during)
    press("HK", c == "hk_held" and during)
    -- a stray Down between the two forwards, or held across both
    press("D", (c == "stray_down"
                and rel >= START + 3 and rel < START + 5)
            or (c == "diagonal" and during))

    if space:read_u16(p2_bar) < MAX_HP then cur.hit = true end
end)

emu.register_stop(function()
    if cur and not done and idx > 0 then
        hits = hits + (cur.hit and 1 or 0)
        log("%-12s came out %d/%d", CASES[idx], hits, rep)
    end
    log("run_end")
end)
