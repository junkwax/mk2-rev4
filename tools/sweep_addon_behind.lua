-- sweep_addon_behind.lua - does an uppercut land on an opponent facing AWAY?
--
-- Reported from play: "when I was behind the opponent and tried uppercutting
-- them it went through them."
--
-- The uppercut is not covered by tools/box_align_audit.py, and that is worth
-- saying out loud: `do_uppercut` reaches `upcut_striker`, which enters the
-- shared loop at `attk5` with `a9` ALREADY ADVANCED by do_first_a9_frame and
-- do_next_a9_frame. There is no `movk <n>,a9` for the audit to read, so the
-- static tool cannot resolve its contact pose. It is exactly as exposed to the
-- "box authored for the wrong frame" trap as Baraka's swipe was; it simply
-- cannot be checked from the source alone. Hence measuring it here.
--
-- Two things are varied and nothing else:
--   * the victim's FACING, forced every frame - toward the attacker, or away
--     from him, which is the reported situation (jumped over, not turned yet)
--   * the distance
--
-- The prediction worth testing: under `anchorcol = 1` facing should NOT matter
-- at all. sq_punch centres the hit column on `oxpos` and `ani2` mirrors a
-- piece's dx to `xsize - dx` on flip, so the anipoint stays on the same part
-- of the body and the column is symmetric about it either way. Retail's
-- middle-quarter-of-the-bounding-box IS facing-dependent. So if AWAY whiffs
-- where TOWARD connects, the cause is NOT the anchored column, and this rig
-- says so instead of letting a plausible story stand.
--
-- BEHIND_FACING=away|toward   (default away)
--
-- Run: rename to sweep_addon.lua, then
--   run_battle_stability_sweep.ps1 -Only baraka_scorpion_swipe -P2Human
--     -Observe 3000 -Backstop 200

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/behind_uppercut.txt"
local FACING = (os.getenv("BEHIND_FACING") or "away"):lower()

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
    print("[behind] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0 }
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0,
            oflags = 0x0f0, oimg = 0x1a0 }
local MP = { sag = 0, xsize = 32, dx = 80, stride = 112, max = 13 }
local M_FLIPH = 0x0010
local ACT_UPPERCUT = 0x0100   -- resolved from MAINEQU below
local MAX_HP = 0xa1

do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local v = line:match("^act_uppercut%s+%.set%s+(%x+)h")
            if v then ACT_UPPERCUT = tonumber(v, 16) end
        end
        fh:close()
    end
end

-- stk_sauppercut, read from source.  It does NOT appear in
-- doc/frame_data_records.csv: the extractor wants six consecutive `.word`
-- lines and this record has a blank line and a commented-out old version in
-- the middle of it, so it is silently dropped.  Worth fixing there separately.
local BOX = { xoff = 0x4e, xsize = 0x33 }

-- Through ZERO and out the other side.  The first pass ran 16..140 and found
-- a clean 16..84 band with facing making no difference at all - so facing is
-- not the variable.  What it never tested is standing ON the opponent, which
-- is what "I was behind them" usually means after a cross-up.  The box starts
-- at oxpos+27, so a victim whose hit column is inside that gap cannot be
-- touched: predicted dead zone below about 19 px, mirrored on the other side.
-- Negative d puts the attacker on the victim's RIGHT; face_opponent turns him
-- and strike_check mirrors the box, so both sides are real cases.
-- 60 frames was too short: the uppercut plus its act_upcut_sd recovery runs
-- past it, so every other trial began while the previous move was still going
-- and the input was swallowed - a clean alternating H/?/H/? pattern, the rig
-- measuring its own cadence.  The misfire guard caught it and refused to
-- report, which is what the guard is for.
local D_FROM, D_TO, D_STEP = -60, 100, 4
local TRIAL = 110
local TRACE_AT = { [40] = true, [64] = true }

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[behind] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function sprite_span(obj)
    local img = space:read_u32(obj + O.oimg)
    if img == 0 or img < 0x01000000 or img >= 0x01400000 then return nil end
    local ox = s16(space:read_u16(obj + O.oxpos))
    local l, r, n = 30000, -30000, 0
    for i = 0, MP.max - 1 do
        local rec = img + i * MP.stride
        if space:read_u32(rec + MP.sag) == 0 then break end
        local xs = s16(space:read_u16(rec + MP.xsize))
        local dx = s16(space:read_u16(rec + MP.dx))
        local pl = ox - dx
        if pl < l then l = pl end
        if pl + xs > r then r = pl + xs end
        n = n + 1
    end
    if n == 0 then return nil end
    return l - ox, r - ox, n
end

local dist, t0, cur = D_FROM, nil, nil
local rows, traced = {}, {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = { ["P1 High Punch"] = true, ["P1 Down"] = true }
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
        log("=== uppercut vs a victim facing %s, %d..%d step %d ===",
            FACING:upper(), D_FROM, D_TO, D_STEP)
        log("stk_sauppercut: box spans oxpos+%d .. oxpos+%d",
            BOX.xoff - BOX.xsize, BOX.xoff)
    end
    if frame - fight0 < 60 then return end
    if dist > D_TO then return end

    -- attacker on the LEFT, victim pinned on the right
    local vx = s16(space:read_u16(right_edge)) + 300
    space:write_u32(o2 + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx)
    local ax = vx - dist
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    -- FORCE the victim's facing every frame.  Art is drawn facing right, so
    -- m_fliph clear = facing right = facing AWAY from an attacker on his left.
    local vf = space:read_u16(o2 + O.oflags)
    if FACING == "away" then vf = vf & (~M_FLIPH & 0xffff)
    else vf = vf | M_FLIPH end
    space:write_u16(o2 + O.oflags, vf)

    if t0 == nil then
        t0 = frame
        cur = { fired = false, hit = false }
        space:write_u16(p2_bar, MAX_HP)
        space:write_u16(p1_bar, MAX_HP)
    end
    local rel = frame - t0

    -- Down + HP.  joy_hi_punch tests is_stick_down FIRST and takes the
    -- uppercut branch, so Down must be held across the button.
    local down = (rel >= 4 and rel < 16)
    local hp   = (rel >= 9 and rel < 12)
    for n, fd in pairs(fields) do
        local on = (n == "P1 Down" and down) or (n == "P1 High Punch" and hp)
        fd:set_value(on and 1 or 0)
    end

    local act = space:read_u16(r1 + P.action)
    if act == ACT_UPPERCUT then
        cur.fired = true
        if TRACE_AT[dist] then
            local l, r, n = sprite_span(o1)
            local vl, vr = sprite_span(o2)
            if l and vl then
                traced[#traced + 1] = string.format(
                    "  d=%3d t=%2d attacker %+4d..%+4d (%d pc)  box %+4d..%+4d"
                    .. "   victim %+4d..%+4d  fliph a=%d v=%d",
                    dist, rel, l, r, n, BOX.xoff - BOX.xsize, BOX.xoff, vl, vr,
                    (space:read_u16(o1 + O.oflags) & M_FLIPH) ~= 0 and 1 or 0,
                    (space:read_u16(o2 + O.oflags) & M_FLIPH) ~= 0 and 1 or 0)
            end
        end
    end
    if space:read_u16(p2_bar) < MAX_HP then cur.hit = true end

    if rel >= TRIAL then
        rows[#rows + 1] = { d = dist, fired = cur.fired, hit = cur.hit }
        dist = dist + D_STEP
        t0 = nil
    end
end)

emu.register_stop(function()
    if #traced > 0 then
        log("--- per tick of act_uppercut (relative to each fighter's anipoint) ---")
        for _, l in ipairs(traced) do log("%s", l) end
    end
    if #rows == 0 then log("no trials ran"); return end
    local misfires, lo, hi, line = 0, nil, nil, {}
    for _, r in ipairs(rows) do
        if not r.fired then misfires = misfires + 1 end
        line[#line + 1] = string.format("%3d:%s", r.d,
            (not r.fired) and "?" or (r.hit and "H" or "."))
        if r.fired and r.hit then
            if lo == nil then lo = r.d end
            hi = r.d
        end
    end
    log("--- facing=%s: H = connected, . = whiffed, ? = never fired ---", FACING)
    for i = 1, #line, 12 do
        log("  %s", table.concat(line, " ", i, math.min(i + 11, #line)))
    end
    log("%d trials, %d never produced act_uppercut", #rows, misfires)
    if misfires > #rows / 4 then
        log("VERDICT: the rig failed to fire the move - range data is meaningless")
    elseif lo == nil then
        log("VERDICT facing=%s: connected at NO distance in %d..%d",
            FACING, D_FROM, D_TO)
    else
        log("VERDICT facing=%s: connects %d..%d px", FACING, lo, hi)
        local holes = {}
        for _, r in ipairs(rows) do
            if r.fired and not r.hit and r.d > lo and r.d < hi then
                holes[#holes + 1] = r.d
            end
        end
        if #holes > 0 then
            log("  HOLES inside the band at: %s", table.concat(holes, ", "))
        end
    end
end)
