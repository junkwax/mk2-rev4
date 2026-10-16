-- sweep_addon_assert.lua - canonical interactions, measured every run.
--
-- Section 8.2 of doc/TOURNAMENT_READINESS.md: the stability sweep catches
-- crashes and camera scope. It does not catch "this move now whiffs at point
-- blank". balance.lock guards the numbers a human typed and hurtbox.lock the
-- ones the art decides; neither notices when the two combine into different
-- BEHAVIOUR.
--
-- This does not assert what the game SHOULD do - nobody has agreed that - it
-- records what it DOES, case by case, so a change shows up as a diff. Same
-- contract as the two locks.
--
-- Setup is a practice dummy: P2 is a second human port with nothing pressed,
-- so it stands still and does not fight back. Both fighters are pinned at the
-- case distance every frame, and P1's inputs are driven here, after the
-- harness has zeroed them.
--
-- The traps this session already paid for, all of them live in these cases:
--   * `elbow_check` turns a close HP into an elbow, `knee_check` a close HK
--     into a knee - so a "jab" case at 40 px is really an elbow case, and it
--     is named that way rather than pretending otherwise.
--   * The harness walks P1 corner to corner, so BOTH directions must be
--     driven or the stick fights the rig.
--   * Damage is not evidence of a particular move. Each case records the
--     victim's action too, so "something hit him" and "the swipe hit him"
--     are distinguishable.

local ROOT  = "C:/Users/you/Workplace/mk2-main"
local OUT   = ROOT .. "/tools/behaviour_run.txt"

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

-- name, distance px, held direction ("f"/"b"/"d"/nil), button, note
local CASES = {
    { "elbow_close",     40,  nil, "HP", "close HP becomes an elbow" },
    { "hipunch_mid",     70,  nil, "HP", "standing high punch" },
    { "hipunch_far",    130,  nil, "HP", "out of range - must whiff" },
    { "swipe_back_hp",   90,  "b", "HP", "Baraka back+HP swipe" },
    { "throw_close",     40,  "f", "LP", "toward+LP throw, 64 px limit" },
    { "throw_far",       90,  "f", "LP", "past the throw range" },
    { "uppercut_point",  12,  "d", "HP", "documented point-blank dead zone" },
    { "uppercut_mid",    50,  "d", "HP", "uppercut in range" },
    { "sweep_back_lk",   90,  "b", "LK", "back+LK sweep" },
    { "lowkick_mid",     70,  nil, "LK", "standing low kick" },
}

local TRIAL = 100          -- ticks per case: long enough for a full recovery

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[assert] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl, idx, cur, done = {}, 0, nil, false
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local function press(name, on)
    if fl[name] then fl[name]:set_value(on and 1 or 0) end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        local want = {
            ["P1 Right"] = "R", ["P1 Left"] = "L", ["P1 Down"] = "D",
            ["P1 High Punch"] = "HP", ["P1 Low Punch"] = "LP",
            ["P1 High Kick"] = "HK", ["P1 Low Kick"] = "LK",
        }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fl[want[fd.name]] = fd end
            end
        end
        local miss = {}
        for _, k in pairs(want) do
            if not fl[k] then miss[#miss + 1] = k end
        end
        log("=== behaviour cases ===%s",
            (#miss > 0) and (" MISSING: " .. table.concat(miss, ",")) or "")
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
            log("%-16s dist=%-3d dmg=%-3d victim_act=%04xh attacker_act=%04xh",
                cur.name, cur.dist, cur.dmg, cur.vact, cur.aact)
        end
        idx = idx + 1
        if idx > #CASES then
            done = true
            log("cases_done %d", #CASES)
            return
        end
        local c = CASES[idx]
        cur = { name = c[1], dist = c[2], dir = c[3], btn = c[4],
                dmg = 0, vact = 0, aact = 0 }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    if not cur then return end

    -- pin both, measured from the camera clamp so they stay on screen
    local vx = s16(space:read_u16(right_edge)) - 120
    space:write_u32(o2 + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + OXPOS, vx)
    space:write_u32(o1 + OXVAL, ((vx - cur.dist) << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx - cur.dist)

    -- P1 is on the LEFT, so "forward" is Right. Every direction is driven,
    -- including the ones this case does not want, or the harness's own walk
    -- keeps a stick held and quietly changes the move.
    local holding = (rel >= 4 and rel < 24)
    press("R", holding and cur.dir == "f")
    press("L", holding and cur.dir == "b")
    press("D", holding and cur.dir == "d")
    for _, b in ipairs({ "HP", "LP", "HK", "LK" }) do
        press(b, (rel >= 10 and rel < 13) and b == cur.btn)
    end

    local lost = MAX_HP - space:read_u16(p2_bar)
    if lost > cur.dmg then cur.dmg = lost end
    local va = space:read_u16(r2 + P_ACTION)
    local aa = space:read_u16(r1 + P_ACTION)
    -- 0 is "nothing read yet", not an action: without excluding it the
    -- victim column latched 0000h on cases that plainly connected.
    if va ~= 0 and va ~= 0x0303 and cur.vact == 0 then cur.vact = va end
    if aa ~= 0 and aa ~= 0x0303 and cur.aact == 0 then cur.aact = aa end
end)

emu.register_stop(function()
    if cur and not done then
        log("%-16s dist=%-3d dmg=%-3d victim_act=%04xh attacker_act=%04xh",
            cur.name, cur.dist, cur.dmg, cur.vact, cur.aact)
    end
    log("run_end")
end)
