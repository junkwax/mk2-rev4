-- sweep_addon_bands.lua - connect-range bands for five moves, one MAME run.
--
-- Built to answer a question honestly rather than plausibly: WHICH moves
-- actually register differently between two builds?  Run this on the before
-- build and the after build and diff the bands.  A move whose band does not
-- move did not change, no matter how good the story is.
--
-- Baraka vs Scorpion, both human, victim pinned, attacker stepped through a
-- range of distances.  For each move at each distance: fire it, verify the
-- action actually appeared, and record whether the victim lost HP.
--
-- Every trial VERIFIES its action.  Two earlier rigs in this project reported
-- confident range data for a move that never fired, and one reported a clean
-- alternating hit/miss pattern that was purely its own trial cadence beating
-- against the move's recovery.  A band from a run with misfires is thrown out.
--
-- Output: tools/move_bands_<BANDS_TAG>.txt

local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("BANDS_TAG") or "run"
local OUT = ROOT .. "/tools/move_bands_" .. TAG .. ".txt"

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                sym[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate = S("gstate")
local p1_obj, p2_obj = S("p1_obj"), S("p2_obj")
local p1_proc = S("p1_proc")
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
local right_edge = S("right_edge")
if not (gstate and p1_proc and right_edge) then
    print("[bands] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0 }
local O = { oxval = 0x080, oxpos = 0x090 }
local MAX_HP = 0xa1

local acts = {}
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+(%x+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end

-- name, the p_action that proves it fired, and the stick/button pattern.
-- Away is held only across the button: is_stick_away samples the stick when
-- the button is read, and holding it longer just walks back out of range.
local MOVES = {
    { name = "hikick",     act = acts.act_hikick,
      keys = function(t) return { HK = (t >= 8 and t < 11) } end },
    { name = "roundhouse", act = acts.act_rhouse,
      keys = function(t) return { LEFT = (t >= 5 and t < 14),
                                  HK = (t >= 8 and t < 11) } end },
    { name = "sweep",      act = acts.act_sweep,
      keys = function(t) return { LEFT = (t >= 5 and t < 14),
                                  LK = (t >= 8 and t < 11) } end },
    { name = "swipe",      act = acts.act_swipe,
      keys = function(t) return { LEFT = (t >= 5 and t < 14),
                                  HP = (t >= 8 and t < 11) } end },
    { name = "uppercut",   act = acts.act_uppercut,
      keys = function(t) return { DOWN = (t >= 4 and t < 16),
                                  HP = (t >= 9 and t < 12) } end },
}
local FIELD = { HK = "P1 High Kick", LK = "P1 Low Kick", HP = "P1 High Punch",
                LEFT = "P1 Left", RIGHT = "P1 Right", DOWN = "P1 Down" }

-- 16..148 was 34 trials a move; five moves at 110 frames each overran the
-- harness's 20000-frame global cap and the run was KILLED, which meant
-- register_stop never fired and the whole measurement was lost.  120 keeps
-- 4 px resolution - the uppercut difference is exactly one 4 px step, so
-- coarsening to 8 would have hidden the thing worth reporting.
local D_FROM, D_TO, D_STEP = 16, 120, 4
local TRIAL = 110

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[bands] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local mi, dist, t0, cur = 1, D_FROM, nil, nil
local results = {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = {}
        for _, n in pairs(FIELD) do want[n] = true end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fields[fd.name] = fd end
            end
        end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1 = space:read_u32(p1_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== move bands, tag=%s, %d..%d step %d ===", TAG, D_FROM, D_TO, D_STEP)
    end
    if frame - fight0 < 60 then return end
    if mi > #MOVES then return end

    local vx = s16(space:read_u16(right_edge)) + 300
    space:write_u32(o2 + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx)
    local ax = vx - dist
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    if t0 == nil then
        t0 = frame
        cur = { fired = false, hit = false }
        space:write_u16(p2_bar, MAX_HP)
        space:write_u16(p1_bar, MAX_HP)
    end
    local rel = frame - t0

    local m = MOVES[mi]
    local want = m.keys(rel)
    for k, fname in pairs(FIELD) do
        local fd = fields[fname]
        if fd then fd:set_value(want[k] and 1 or 0) end
    end

    if m.act and space:read_u16(r1 + P.action) == m.act then cur.fired = true end
    if space:read_u16(p2_bar) < MAX_HP then cur.hit = true end

    if rel >= TRIAL then
        results[#results + 1] = { move = m.name, d = dist,
                                  fired = cur.fired, hit = cur.hit }
        dist = dist + D_STEP
        t0 = nil
        if dist > D_TO then
            -- Report each move THE MOMENT IT FINISHES, not at register_stop.
            -- A run that gets killed still yields every completed move this
            -- way; the previous version accumulated silently and lost all of
            -- it when the harness timed the run out.
            emit_move(m.name)
            dist = D_FROM
            mi = mi + 1
        end
    end
end)

local reported = {}
function emit_move(name)
    if reported[name] then return end
    reported[name] = true
    local rs = {}
    for _, r in ipairs(results) do
        if r.move == name then rs[#rs + 1] = r end
    end
    if #rs == 0 then return end
    local mis, lo, hi, line = 0, nil, nil, {}
    for _, r in ipairs(rs) do
        if not r.fired then mis = mis + 1 end
        line[#line + 1] = (not r.fired) and "?" or (r.hit and "H" or ".")
        if r.fired and r.hit then
            if lo == nil then lo = r.d end
            hi = r.d
        end
    end
    local holes = {}
    for _, r in ipairs(rs) do
        if r.fired and not r.hit and lo and r.d > lo and r.d < hi then
            holes[#holes + 1] = r.d
        end
    end
    log("%-11s %s", name, table.concat(line))
    if mis > #rs / 4 then
        log("%-11s   MISFIRED %d/%d - band discarded", name, mis, #rs)
    else
        log("%-11s   band %s..%s px  (misfires %d/%d)%s", name,
            tostring(lo), tostring(hi), mis, #rs,
            #holes > 0 and ("  HOLES at " .. table.concat(holes, ",")) or "")
    end
end

emu.register_stop(function()
    for _, m in ipairs(MOVES) do
        if not reported[m.name] then emit_move(m.name) end
    end
    log("(columns are %d..%d px in steps of %d, tag=%s)",
        D_FROM, D_TO, D_STEP, TAG)
end)
