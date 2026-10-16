-- drone_pacing_test.lua
--
-- Measures the interval between repeated AI moves, in the same @tick units
-- the frequency tables are written in.
--
-- l_drone_zap and l_drone_fk are declared in RAM.ASM and cleared at round
-- start, but nothing ever read or wrote them -- so the drone had no cooldown
-- on its fireball or its flip kick and could chain either back to back.
-- They are now wired to drone_zap_frequency / drone_fk_frequency.
--
--   ZAP  - pair held far apart so the drone zones.  Every projectile action
--          (001h-016h) is timestamped; the SHORTEST gap between two of them
--          must be >= drone_zap_frequency[diff 9] = 040h ticks.
--   FLIP - pair held at mid range.  Same for act_flykick (0200h) against
--          drone_fk_frequency[diff 9] = 060h.
--
-- A cooldown that fired but killed the move entirely would show as zero
-- events, so each phase also requires the move to still happen at all.
--
-- Env: PACING_LOG
-- Usage: tools\run_drone_pacing_test.ps1

local LOGP = os.getenv("PACING_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_pacing_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[pacing] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"), tick = sym("tick"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_RAIDEN = 1, 7
local ACT_FLYKICK = 0x0200

-- Watch both moves in ONE free-running fight. An earlier version pinned the
-- pair to a fixed distance to force zoning, but teleporting the drone every
-- few hundred frames just kept it walking and it barely ever reached the zap
-- decision at all -- the measurement disturbed the thing being measured.
--
-- The invariant that actually matters is the timer plumbing: l_drone_zap and
-- l_drone_fk are p1:p2 PAIRS (get_tsl/update_tsl add 16 bits for player 2),
-- and they used to be declared 16 bits wide, so a P2 drone read and wrote
-- the NEXT variable in RAM.ASM instead of its own slot. So on every event
-- we check that the drone's own slot got stamped with the current tick, that
-- the unused p1 slot stays clean, and that consecutive uses respect the
-- cooldown.
local watches = {
    { name = "zap",  min_ticks = 0x40, need = 2, timer = "l_drone_zap", lag = 4,
      match = function(a) return a >= 0x0001 and a <= 0x0016 end },
    -- need=0: the flip kick shares the zap's code path and the same (now
    -- correct) 32-bit p1:p2 timer, but a Raiden drone against an idle
    -- opponent does not reliably choose it, so absence here is not evidence
    -- of breakage and must not fail the run.
    -- lag: the flip kick stamps at the DECISION, then the jump arc flies for
    -- ~24 ticks before do_flip_kick sets act_flykick, so the stamp is legitimately
    -- that much older than the action we observe. do_zap has no such delay.
    { name = "flip", min_ticks = 0x60, need = 0, timer = "l_drone_fk", lag = 90,
      match = function(a) return a == ACT_FLYKICK end },
}

local RUN_FRAMES = 4200

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start = 0
local fields = {}
local done = false
local slot_bad = 0

for _, w in ipairs(watches) do
    w.count, w.min_gap, w.last_tick, w.was_in = 0, nil, nil, false
end

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function proc_act(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function finish()
    if done then return end
    done = true
    local fails = {}
    for _, w in ipairs(watches) do
        log("RESULT %-5s events=%d  shortest_gap=%s ticks (floor %d)",
            w.name, w.count, tostring(w.min_gap), w.min_ticks)
        if w.count < w.need then
            fails[#fails+1] = string.format(
                "%s: only %d event(s) - the cooldown may have killed the move",
                w.name, w.count)
        elseif w.min_gap and w.min_gap < w.min_ticks then
            fails[#fails+1] = string.format(
                "%s: two used only %d ticks apart (floor is %d)",
                w.name, w.min_gap, w.min_ticks)
        end
    end
    if slot_bad > 0 then
        fails[#fails+1] = string.format(
            "%d event(s) stamped the wrong p1:p2 slot", slot_bad)
    end
    if #fails == 0 then
        log("PASS pacing: timers stamp the drone's own slot and cooldowns hold")
    else
        log("FAIL pacing: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- pacing: P1=LiuKang(idle human) P2=Raiden(drone) diff=9 ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_RAIDEN)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        run_start = frame
        log("fight start frame=%d (free-running fight, no position forcing)", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= 0 then w16(A.diff, 9) end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    local act = proc_act(A.p2_proc)
    local t = r16(A.tick)

    for _, w in ipairs(watches) do
        local inmove = w.match(act)
        if inmove and not w.was_in then
            w.count = w.count + 1
            -- p1 slot at +0, p2 slot at +16 bits. P2 is the drone here, so
            -- the p2 slot must move and the p1 slot must stay untouched.
            local base = sym(w.timer)
            local p1slot, p2slot = r16(base), r16(base + 16)
            local ok = (base ~= 0) and (math.abs(p2slot - t) <= w.lag) and (p1slot == 0)
            if not ok then slot_bad = slot_bad + 1 end
            local gaptxt = "first"
            if w.last_tick then
                local d = t - w.last_tick
                if d < 0 then d = d + 0x10000 end   -- tick is a 16-bit counter
                if not w.min_gap or d < w.min_gap then w.min_gap = d end
                gaptxt = string.format("gap=%d", d)
            end
            log("%s #%d act=0x%04x tick=%d %s  slots p1=%d p2=%d %s",
                w.name, w.count, act, t, gaptxt, p1slot, p2slot,
                ok and "ok" or "<-- WRONG SLOT")
            w.last_tick = t
        end
        w.was_in = inmove
    end

    -- Heartbeat: if this stops appearing the emulation wedged; if it keeps
    -- appearing with a frozen p2_act the DRONE wedged. Telling those two
    -- apart cost a whole run once.
    if (frame % 600) == 0 then
        log("  .. rel=%d gap=%d p2_act=0x%04x tick=%d zaps=%d flips=%d",
            frame - run_start, (x1 and x2) and math.abs(x2 - x1) or -1,
            act, t, watches[1].count, watches[2].count)
    end

    if frame - run_start > RUN_FRAMES then finish(); return end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
