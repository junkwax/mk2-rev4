-- sweep_addon_swipe.lua - Baraka's blade swipe (Back+HP): where is the box?
--
-- Reported: "the hitboxes completely miss - the blade completely hits the
-- ninja's face".
--
-- Static reading of the source says exactly that, and this rig exists to
-- confirm it from the running game rather than from my arithmetic:
--
--   do_swipe (MOVES.ASM) calls striker_2 with a11 = 012h = stk_swipe and
--   a10 = 4.  striker_2 plays PART ONE of the animation FIRST and only then
--   holds the final pose for 4 ticks of strike_check.  a_swipe's part one is
--   `UGSWIPE1 / UGSWIPE2 / UGSWIPE3 / ani_nosleep / UGSWIPE4 / 0`, so the
--   contact pose is UGSWIPE4.
--
--   strike_check (JOY.ASM) facing right: box left = oxpos + x_offset - x_size,
--   right = oxpos + x_offset.  stk_swipe is 068h/046h -> +34 .. +104.
--   ani2/box_bounds place a piece at left = oxpos - dx, so from MKSA2.TBL:
--     UGSWIPE3 spans -54 .. +106  (incl. a 76x23 blade strip at +30..+106)
--     UGSWIPE4 spans -45 ..  +29  (no blade strip at all)
--
--   The box matches UGSWIPE3's blade almost exactly - and UGSWIPE3 is off
--   screen before the box exists.  For the whole active window the box floats
--   5 to 75 px in front of a sprite whose blade is already back.
--
-- Two controls say the method is sound, not the arithmetic being lucky:
--   Baraka hi punch  - contact UGHIPUNCH3, fist +40..+77, box +31..+81  (fits)
--   Kitana fan swipe - contact KTFANSWIPE5, fan +58..+93, box +42..+90  (fits)
--
-- So this rig measures, live, per frame of the move:
--   * the composite sprite bounds, walked out of the object's own multipart
--     RAM the same way box_bounds does
--   * where the strike box is, from the record
--   * whether the swipe actually connects, at every distance from 20 to 180
--
-- Every trial VERIFIES act_swipe fired.  An earlier attempt at this map
-- reported "swipe never fired" on most rows and the range data meant nothing.
--
-- A PINNED RIG CANNOT MEASURE A MOVE THAT TRAVELS.  Both fighters are held at
-- an exact distance every frame, which is right here and wrong for anything
-- with a lunge, charge or dive in it: the pin overwrites oxpos before the move
-- can move, so what comes back is the static box, not the move's real reach.
-- Kahn's air knee measured 72 px that way and is actually 224.  Copy this rig
-- for a travelling move and you must release the pin the moment the move
-- starts.
--
-- The swipe is stationary, checked both ways: do_swipe calls init_special ->
-- stop_me and never touches a velocity or multi_adjust_xy, and the range map
-- below stops connecting at 112 with the box front edge at 104 - if Baraka
-- were carrying himself forward the band would run well past that.
--
-- Run: rename to sweep_addon.lua, then
--   run_battle_stability_sweep.ps1 -Only baraka_scorpion_swipe -P2Human
--     -Observe 4000 -Backstop 240
-- P2 must be human: a drone blocks, walks and counter-attacks, none of which
-- belongs in a range map.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/swipe_range.txt"

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
local p1_obj, p2_obj   = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar   = S("p1_bar"), S("p2_bar")
local right_edge = S("right_edge")
local f_colbox = S("f_colbox")
if not (gstate and p1_proc and right_edge) then
    print("[swipe] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0, stk = 0x350 }
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0,
            oimg = 0x1a0, oflags = 0x0d0 }
-- multipart record, same field offsets box_bounds uses (MKDISP.ASM)
local MP = { sag = 0, xsize = 32, ysize = 48, ctrl = 64, dx = 80, dy = 96,
             stride = 112, max = 13 }
local ACT_SWIPE = 0x011e
local ACT_STANCE = 0x0303
local MAX_HP = 0xa1

-- stk_swipe, read straight out of MKSTK.ASM so the rig cannot drift from it
local BOX = { xoff = 0x68, yoff = 0x14, xsize = 0x46, ysize = 0x18 }
do
    local fh = io.open(ROOT .. "/src/MKSTK.ASM", "r")
    if fh then
        local hit, got = false, {}
        for line in fh:lines() do
            if line:match("^stk_swipe%s*$") then hit = true
            elseif hit then
                local v = line:match("^%s*%.word%s+0?(%x+)h")
                if v then
                    got[#got + 1] = tonumber(v, 16)
                    if #got == 4 then break end
                end
            end
        end
        if #got == 4 then
            BOX.xoff, BOX.yoff, BOX.xsize, BOX.ysize = got[1], got[2], got[3], got[4]
        end
        fh:close()
    end
end

local D_FROM, D_TO, D_STEP = 20, 180, 4
local TRIAL = 70
local TRACE_AT = { [60] = true, [90] = true, [120] = true }

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[swipe] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

-- The same walk box_bounds does, in Lua: piece left = oxpos - dx.  Bounded at
-- MP.max for the same reason the ASM is - a chain caught mid-rebuild would
-- otherwise never terminate.
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
    return l - ox, r - ox, n      -- relative to the anipoint
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
        local want = { ["P1 High Punch"] = true, ["P1 Left"] = true,
                       ["P1 Right"] = true }
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
        log("=== baraka blade swipe: box vs art, and a range map ===")
        log("stk_swipe: x_offset=%d x_size=%d -> box spans oxpos+%d .. oxpos+%d",
            BOX.xoff, BOX.xsize, BOX.xoff - BOX.xsize, BOX.xoff)
        if f_colbox then space:write_u16(f_colbox, 5) end
    end
    if frame - fight0 < 60 then return end
    if dist > D_TO then return end

    -- Both fighters pinned: this is a MEASUREMENT rig, distance is the
    -- independent variable, and knockback is noise here rather than physics
    -- worth preserving.
    local vx = s16(space:read_u16(right_edge)) + 300
    space:write_u32(o2 + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx)
    local ax = vx - dist
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    if t0 == nil then
        t0 = frame
        cur = { fired = false, hit = false, lost = 0, inmove = false }
        space:write_u16(p2_bar, MAX_HP)
        space:write_u16(p1_bar, MAX_HP)
    end
    local rel = frame - t0

    -- Away + HP, standing.  joy_hi_punch takes the swipe branch only when the
    -- stick is away AND get_my_height is above 060h; Down is never pressed
    -- here because down+HP is the uppercut instead.
    local away = (rel >= 4 and rel < 14)
    local hp   = (rel >= 8 and rel < 11)
    for n, fd in pairs(fields) do
        local on = (n == "P1 Left" and away) or (n == "P1 High Punch" and hp)
        fd:set_value(on and 1 or 0)
    end

    local act = space:read_u16(r1 + P.action)
    if act == ACT_SWIPE then cur.fired = true; cur.inmove = true end
    -- Trace the WHOLE move, not just the frames tagged act_swipe.
    -- retract_strike calls act_mframew with a1 cleared, so p_action stops
    -- being act_swipe the moment the retract starts - and the retract is
    -- exactly where the follow-through pose now lives.  Gating on act_swipe
    -- hid it, and "does the swing finish" is the question.
    if cur.inmove and act == ACT_STANCE then cur.inmove = false end
    if cur.inmove then
        if TRACE_AT[dist] then
            local l, r, n = sprite_span(o1)
            if l then
                traced[#traced + 1] = string.format(
                    "  d=%3d t=%2d  pieces=%d  sprite %+4d..%+4d   box %+4d..%+4d  %s",
                    dist, rel, n, l, r, BOX.xoff - BOX.xsize, BOX.xoff,
                    (r >= BOX.xoff - BOX.xsize) and "overlap" or "NO OVERLAP")
            end
        end
    end
    local hp2 = space:read_u16(p2_bar)
    if hp2 < MAX_HP then
        cur.hit = true
        if MAX_HP - hp2 > cur.lost then cur.lost = MAX_HP - hp2 end
    end

    if rel >= TRIAL then
        rows[#rows + 1] = { d = dist, fired = cur.fired, hit = cur.hit,
                            lost = cur.lost }
        dist = dist + D_STEP
        t0 = nil
        if dist > D_TO then log("map complete after %d trials", #rows) end
    end
end)

emu.register_stop(function()
    if #traced > 0 then
        log("--- sprite bounds per tick of act_swipe (relative to the anipoint) ---")
        for _, l in ipairs(traced) do log("%s", l) end
    end
    if #rows == 0 then log("no trials ran"); return end
    local misfires, lo, hi = 0, nil, nil
    local line = {}
    for _, r in ipairs(rows) do
        if not r.fired then misfires = misfires + 1 end
        line[#line + 1] = string.format("%3d:%s", r.d,
            (not r.fired) and "?" or (r.hit and "H" or "."))
        if r.fired and r.hit then
            if lo == nil then lo = r.d end
            hi = r.d
        end
    end
    log("--- range map (H = connected, . = whiffed, ? = move never fired) ---")
    for i = 1, #line, 12 do
        log("  %s", table.concat(line, " ", i, math.min(i + 11, #line)))
    end
    log("%d trials, %d never produced act_swipe", #rows, misfires)
    if misfires > #rows / 4 then
        log("VERDICT: the rig failed to fire the move - the range data is meaningless")
    elseif lo == nil then
        log("VERDICT: the swipe connected at NO distance in %d..%d", D_FROM, D_TO)
    else
        log("VERDICT: connects %d..%d px", lo, hi)
        local holes = {}
        for _, r in ipairs(rows) do
            if r.fired and not r.hit and r.d > lo and r.d < hi then
                holes[#holes + 1] = r.d
            end
        end
        if #holes > 0 then
            log("  HOLES inside the connecting band at: %s",
                table.concat(holes, ", "))
        end
    end
end)
