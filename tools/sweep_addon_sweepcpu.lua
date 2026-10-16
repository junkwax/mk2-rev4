-- sweep_addon_sweepcpu.lua - can the CPU be swept over and over?
--
-- Player report: "you can continue to sweep the computer and they just try to
-- block high instead of duck block and counter with a low kick or a sweep".
--
-- P1 is a scripted human who sweeps the drone (away + LK) whenever he is free,
-- with P2 parked at a fixed distance between attempts. Two phases:
--
--   plain    sweep from neutral           -> c_sweep (av_sweep / ct_sweep)
--   hk       high kick first, then sweep  -> catches the drone in drone_block's
--                                            standing guard (drone_guard_hold)
--
-- Per attempt it records P2's action when the sweep starts and when it ends,
-- the damage P2 took (hit vs chip vs nothing), and whether P2 answered inside
-- the recovery window with a low kick (act_medkick) or a sweep, and whether
-- that answer took anything off P1.
--
-- BOTH bars are pinned HERE, not by the harness (run with SWEEP_NO_HP_PIN=1):
-- the harness refills p1_bar before this callback runs, which would make every
-- counter look like it missed.
--
-- Env: SWPCPU_LOG, SWPCPU_DIFF (0-9, default 9), SWPCPU_DIST (default 70)
-- Driven by run_sweepcpu_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("SWPCPU_LOG") or (ROOT .. "/tools/sweepcpu.txt")
local DIFF = tonumber(os.getenv("SWPCPU_DIFF") or "9")
local DIST = tonumber(os.getenv("SWPCPU_DIST") or "70")
local PHASE_LEN = 1150

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
local need = {"gstate","p1_proc","p2_proc","p1_obj","p2_obj","p1_bar","p2_bar","diff"}
local missing = {}
for _, n in ipairs(need) do if not sym[n] then missing[#missing + 1] = n end end

local P_ACTION, OXPOS, OXVAL = 0x1f0, 0x090, 0x080
local MAX_HP = 0xA1
local ACT_SWEEP, ACT_SWEEP_SD, ACT_MEDKICK = 0x0106, 0x0600, 0x0104
local ACT_BLOCKHI, ACT_BLOCKLO = 0x0700, 0x0701

-- Opened on the first fight frame, NOT at load: the wrapper's warning-screen
-- poker stops as soon as this file exists.
local fh
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[swpcpu] " .. l)
    if not fh then fh = io.open(OUT, "a") end
    if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({"P1 Left","P1 Right","P1 Up","P1 Down","P1 High Punch",
                    "P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block"}) do
    ADDON_OWNS[n] = true
end

local space, fields, frame, fight0 = nil, {}, 0, 0
local last_p1, last_p2 = MAX_HP, MAX_HP
local PHASES = {"plain", "hk"}
local S = {}
for _, p in ipairs(PHASES) do
    S[p] = {tries=0, hit=0, chip=0, none=0, lowguard=0, higuard_start=0,
            higuard_fixed=0, counter=0, counter_sweep=0, counter_lk=0, counter_landed=0}
end

local cur = nil          -- the attempt being watched
local last_end = -999    -- frame P1's last sweep finished
local hk_at = -999

local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end; return v end
local function press(n, on) local f = fields[n]; if f then f:set_value(on and 1 or 0) end end
local function act_of(procsym)
    local p = space:read_u32(sym[procsym]); if p == 0 then return nil end
    return space:read_u16(p + P_ACTION) & 0xffff
end

local function close(a)
    local st = S[a.phase]
    st.tries = st.tries + 1
    local kind
    if a.dmg2 >= 10 then kind = "HIT"; st.hit = st.hit + 1
    elseif a.dmg2 > 0 then kind = "chip"; st.chip = st.chip + 1
    else kind = "none"; st.none = st.none + 1 end
    if a.saw_lo then st.lowguard = st.lowguard + 1 end
    if a.start2 == ACT_BLOCKHI then
        st.higuard_start = st.higuard_start + 1
        if a.saw_lo then st.higuard_fixed = st.higuard_fixed + 1 end
    end
    local ans = "-"
    if a.ans then
        st.counter = st.counter + 1
        if a.ans == ACT_SWEEP then st.counter_sweep = st.counter_sweep + 1; ans = "SWEEP"
        else st.counter_lk = st.counter_lk + 1; ans = "LOKICK" end
        if a.dmg1 > 0 then st.counter_landed = st.counter_landed + 1; ans = ans .. "+" .. a.dmg1 end
    end
    log("  %-5s #%-2d d=%-3d p2@start=%04x p2@end=%04x lowguard=%s p2dmg=%-3d %-4s answer=%s",
        a.phase, st.tries, a.dist, a.start2, a.end2 or 0, a.saw_lo and "Y" or "n", a.dmg2, kind, ans)
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if ADDON_OWNS[f.name] then fields[f.name] = f end end
        end
    end
    if space:read_u16(sym.gstate) ~= 2 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== sweep the CPU === diff=%d dist=%d%s", DIFF, DIST,
            #missing > 0 and (" MISSING " .. table.concat(missing, ",")) or "")
        log("--- phase: plain")
    end
    local t = frame - fight0
    local pi = math.floor(t / PHASE_LEN) + 1
    local phase = PHASES[pi]
    if not phase then return end

    space:write_u16(sym.diff, DIFF)

    -- damage first, then refill
    local hp1 = space:read_u16(sym.p1_bar) & 0xffff
    local hp2 = space:read_u16(sym.p2_bar) & 0xffff
    local d1 = (hp1 < last_p1) and (last_p1 - hp1) or 0
    local d2 = (hp2 < last_p2) and (last_p2 - hp2) or 0
    space:write_u16(sym.p1_bar, MAX_HP); space:write_u16(sym.p2_bar, MAX_HP)
    last_p1, last_p2 = MAX_HP, MAX_HP

    local a1, a2 = act_of("p1_proc"), act_of("p2_proc")
    if not a1 or not a2 then return end
    local o1, o2 = space:read_u32(sym.p1_obj), space:read_u32(sym.p2_obj)
    if o1 == 0 or o2 == 0 then return end
    local x1, x2 = s16(space:read_u16(o1 + OXPOS)), s16(space:read_u16(o2 + OXPOS))

    -- the attempt
    if cur then
        cur.dmg2 = cur.dmg2 + d2
        if a2 == ACT_BLOCKLO then cur.saw_lo = true end
        if not cur.ended and a1 ~= ACT_SWEEP then
            cur.ended = frame; cur.end2 = a2
        end
        if cur.ended then
            if not cur.ans and (a2 == ACT_SWEEP or a2 == ACT_MEDKICK) then cur.ans = a2 end
            if cur.ans then cur.dmg1 = cur.dmg1 + d1 end
            if frame - cur.ended > 70 then
                close(cur); last_end = frame; cur = nil
            end
        end
    elseif a1 == ACT_SWEEP then
        cur = {phase=phase, start2=a2, dist=math.abs(x2 - x1), dmg2=d2, dmg1=0, saw_lo=(a2 == ACT_BLOCKLO)}
    end

    for n in pairs(ADDON_OWNS) do press(n, false) end

    -- between attempts: park P2 at DIST so every sweep is thrown from the same place
    local idle = (cur == nil) and (frame - last_end > 20)
    if idle and (a2 >> 8) ~= 0x01 and (a2 >> 8) ~= 0x02 then
        local tx = (x1 < x2) and (x1 + DIST) or (x1 - DIST)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end

    -- NOT gated on P1's action: p_action is not reset when a move recovers, so
    -- "is he free" read from it starved the rig (3 tries in 1150 frames). Tap
    -- on a clock and let the game refuse the press while he is busy; attempts
    -- are counted off act_sweep's rising edge, so a refused tap costs nothing.
    -- Taps are 2 frames on, 2 off, so each is a fresh button edge.
    local away = (x1 < x2) and "P1 Left" or "P1 Right"
    local tap = (frame % 4) < 2
    if cur == nil and frame - last_end > 30 then
        if phase == "plain" then
            press(away, tap); press("P1 Low Kick", tap)
        else
            -- the kick first, then sweep into the guard it drew
            if frame - hk_at > 70 then hk_at = frame end
            local k = frame - hk_at
            if k < 2 then press("P1 High Kick", true)
            elseif k > 16 then press(away, tap); press("P1 Low Kick", tap) end
        end
    end

    if t % PHASE_LEN == PHASE_LEN - 1 and PHASES[pi + 1] then log("--- phase: %s", PHASES[pi + 1]) end
end)

emu.register_stop(function()
    for _, p in ipairs(PHASES) do
        local s = S[p]
        log("RESULT %-5s tries=%d  hit=%d chip=%d none=%d  lowguard=%d  hi-guard-at-start=%d (dropped low %d)  answered=%d (sweep %d, lokick %d, landed %d)",
            p, s.tries, s.hit, s.chip, s.none, s.lowguard, s.higuard_start, s.higuard_fixed,
            s.counter, s.counter_sweep, s.counter_lk, s.counter_landed)
    end
    if fh then fh:close() end
end)
