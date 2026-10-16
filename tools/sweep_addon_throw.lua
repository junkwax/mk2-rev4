-- sweep_addon_throw.lua - who wins a simultaneous throw attempt?
--
-- Second half of section 5.3. The trade case is measured (P2 wins clean
-- exchanges, and identically on retail). Throws go through a different gate
-- entirely - joy_toss -> do_body_slam, guarded by a check that reads the
-- OTHER player's stick (`is_stick_away`: holding away refuses the throw) - so
-- the trade result says nothing about it and it needs its own measurement.
--
-- The throw is LOW PUNCH, not high: `joy_lo_punch` sets `movi 040h,a7` and
-- calls toss_check, so the range limit is 64 px.  A first version pressed HP
-- and measured 19 trials of 10-9 "P1 wins" that were entirely ELBOWS -
-- joy_hi_punch runs elbow_check at this range - which is why the tally is
-- gated on act_bodyslam rather than on damage.
--
-- Both players are pinned at throw range and press toward+LP on the SAME
-- frame, and BOTH directions are driven for both players.  Setting only the
-- toward direction left the harness's camera-stress walk holding P1 AWAY for
-- the back half of every run, and holding away is exactly what toss_check
-- reads to refuse a throw - which produced a perfectly clean "P2 wins the
-- first half, P1 wins the second", switching at OBSERVE*0.45. The signal is which health bar drops: the thrown player takes the
-- damage. Health is restored between trials, so each trial is independent.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/throw_priority.txt"
local DIST = tonumber(os.getenv("THROW_DIST") or "40")
-- THROW_SWAP=1 puts P1 on the RIGHT.  Without this control the
-- result cannot tell "player two wins" from "the fighter on the
-- right wins", and those are different findings.
local SWAP = (os.getenv("THROW_SWAP") or "") == "1"
-- THROW_SOLO=1 presses only P1. If P1 cannot throw even with
-- nobody contesting him, this rig was never measuring a contest
-- and every "P2 wins" number it produced is worthless.
local SOLO = (os.getenv("THROW_SOLO") or "") == "1"
-- ODD default on purpose: at an even cadence every trial lands on the
-- same tick parity, so a parity tiebreak produces the same winner every
-- time and looks exactly like no fix at all.
local TRIAL = tonumber(os.getenv("THROW_TRIAL") or "91")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, switch2sym = sym.gstate, sym.switch2
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local right_edge = sym.right_edge
local OXPOS, OXVAL, MAX_HP = 0x090, 0x080, 0xA1
local P_ACTION, ACT_BODYSLAM = 0x1f0, 0x0507

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[throw] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, t0 = nil, 0, 0, nil
local fl = {}
local tally = { p1 = 0, p2 = 0, none = 0, both = 0, nothrow = 0 }
local seen1, seen2 = {}, {}
local seq = {}   -- order matters: 10-9 is also what perfect alternation looks like
local cur
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if fd.name == "P1 Right"      then fl.d1 = fd end
                if fd.name == "P2 Left"       then fl.d2 = fd end
                -- the AWAY directions must be owned too: the
                -- harness walks P1 toward one corner then the
                -- other, and holding away is exactly what
                -- toss_check reads to REFUSE a throw
                if fd.name == "P1 Left"       then fl.a1 = fd end
                if fd.name == "P2 Right"      then fl.a2 = fd end
                if fd.name == "P1 Low Punch" then fl.b1 = fd end
                if fd.name == "P2 Low Punch" then fl.b2 = fd end
            end
        end
        log("=== throw priority (dist %d%s) === fields %s%s%s%s", DIST,
            SWAP and ", P1 ON RIGHT" or "",
            fl.d1 and "" or " NO-P1DIR", fl.d2 and "" or " NO-P2DIR",
            fl.b1 and "" or " NO-P1LP", fl.b2 and "" or " NO-P2LP")
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 == 0 or o2 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end

    -- pin both fighters at throw range, measured from the camera so they
    -- stay inside the clamp (fighters parked outside it are off screen and
    -- every trial silently does nothing)
    local vx = s16(space:read_u16(right_edge)) - 120
    local near, far = o2, o1
    if SWAP then near, far = o1, o2 end
    space:write_u32(near + OXVAL, (vx << 16) & 0xffffffff)
    space:write_u16(near + OXPOS, vx)
    space:write_u32(far + OXVAL, ((vx - DIST) << 16) & 0xffffffff)
    space:write_u16(far + OXPOS, vx - DIST)

    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if r1 ~= 0 and r2 ~= 0 then
        local a1 = space:read_u16(r1 + P_ACTION)
        local a2 = space:read_u16(r2 + P_ACTION)
        seen1[a1] = (seen1[a1] or 0) + 1
        seen2[a2] = (seen2[a2] or 0) + 1
        if cur then
            if a1 == ACT_BODYSLAM then cur.slam1 = true end
            if a2 == ACT_BODYSLAM then cur.slam2 = true end
        end
    end

    if t0 == nil then t0 = frame end
    local rel = (frame - t0) % TRIAL
    if rel == 0 then
        if cur then
            -- "health dropped" is NOT a throw: at this range a refused throw
            -- is just a punch, and it damages too.  Only trials where a
            -- fighter actually entered act_bodyslam are counted.
            local h1 = space:read_u16(p1_bar) < MAX_HP
            local h2 = space:read_u16(p2_bar) < MAX_HP
            if cur.slam1 and cur.slam2 then tally.both = tally.both + 1
                seq[#seq + 1] = "B"
            elseif cur.slam1 then tally.p1 = tally.p1 + 1
                seq[#seq + 1] = "1"
            elseif cur.slam2 then tally.p2 = tally.p2 + 1
                seq[#seq + 1] = "2"
            elseif h1 or h2 then tally.nothrow = tally.nothrow + 1
            else tally.none = tally.none + 1 end
        end
        cur = { slam1 = false, slam2 = false }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end

    -- toward on both sticks, HP on the SAME frame for both
    local dir = (rel >= 4 and rel < 20)
    local btn = (rel >= 10 and rel < 13)
    -- "toward" is a different button once the sides are swapped
    local t1 = SWAP and fl.a1 or fl.d1      -- P1 toward
    local t2 = SWAP and fl.a2 or fl.d2      -- P2 toward
    local w1 = SWAP and fl.d1 or fl.a1
    local w2 = SWAP and fl.d2 or fl.a2
    if t1 then t1:set_value(dir and 1 or 0) end
    if t2 then t2:set_value(dir and 1 or 0) end
    if w1 then w1:set_value(0) end
    if w2 then w2:set_value(0) end
    if fl.b1 then fl.b1:set_value(btn and 1 or 0) end
    if fl.b2 then fl.b2:set_value((btn and not SOLO) and 1 or 0) end
end)

emu.register_stop(function()
    local n = tally.p1 + tally.p2 + tally.none + tally.both
              + tally.nothrow
    log("trials=%d  P1 slam=%d  P2 slam=%d  both=%d  hit-but-no-throw=%d  "
        .. "nothing=%d", n, tally.p1, tally.p2, tally.both, tally.nothrow,
        tally.none)
    local function top(t, who)
        local l = {}
        for k, v in pairs(t) do l[#l + 1] = { a = k, n = v } end
        table.sort(l, function(x, y) return x.n > y.n end)
        local p = {}
        for i = 1, math.min(#l, 5) do
            p[#p + 1] = string.format("%04xh:%d", l[i].a, l[i].n) end
        log("  %s actions: %s", who, table.concat(p, " "))
    end
    top(seen1, "P1"); top(seen2, "P2")
    log("sequence: %s", table.concat(seq, ""))
    if tally.p1 + tally.p2 > 0 then
        log("VERDICT %s",
            (tally.p1 == tally.p2) and "even"
            or string.format("%s wins %d-%d",
                             (tally.p1 > tally.p2) and "P1" or "P2",
                             math.max(tally.p1, tally.p2),
                             math.min(tally.p1, tally.p2)))
    end
end)
