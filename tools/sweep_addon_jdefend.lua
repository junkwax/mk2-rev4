-- sweep_addon_jdefend.lua - does the PERFECT BLOCK exist, and is it worth it?
--
-- jdefend (MAINEQU.ASM) says a guard raised in the last few ticks before a
-- strike lands is a better block: less chip, less stun, and a white flash.
-- This measures the two halves that are numbers.
--
-- THE CLASSIFICATION IS NOT GUESSED. strike_blocked writes the victim's
-- f_jdefend word on every blocked strike - 1 if it judged the block perfect,
-- 0 if not - so the rig reads that word on the frame the chip lands and
-- buckets the result. It never has to assume its own timing worked, which
-- matters because the whole point is a 4-tick window.
--
-- Getting both buckets: P1 throws a high kick on a fixed period and P2's
-- block is raised at an offset that WALKS across that period, so over a few
-- hundred frames the guard goes up everywhere from 20 ticks early to on the
-- contact frame itself. Some of those land inside jdwindow and some do not.
--
-- The stun is measured as "frames from the chip landing until P2 leaves
-- act_blockhi". The rig drops P2's block button on the contact frame, so the
-- only thing keeping him in the block action is block_shake - and the moment
-- it lets go, joy_block_loop sees the button gone and do_unblock_hi clears
-- p_action. The unblock animation is the same length in both buckets, so the
-- DIFFERENCE between them is the shake repetitions jd_shake_cap took off.
--
-- P2 must be a HUMAN (SWEEP_P2_HUMAN=1): jdjoyonly is 1, so a drone cannot
-- earn a perfect block and every sample would land in the ordinary bucket.
--
-- Env: JD_LOG.  Driven by run_jdefend_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("JD_LOG") or (ROOT .. "/tools/jdefend.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate   = sym.gstate
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p2_bar   = sym.p2_bar
local p1_bar   = sym.p1_bar
local f_jdefend, l_jdguard = sym.f_jdefend, sym.l_jdguard
local tick_sym = sym.tick

local acts = {}
for line in io.lines(ROOT .. "/src/MAINEQU.ASM") do
    local n, v = line:match("^(act_[%w_]+)%s+%.set%s+(%x+)h")
    if n and v then acts[n] = tonumber(v, 16) end
end
local ACT_BLOCKHI, ACT_BLOCKLO = acts.act_blockhi, acts.act_blocklo

local P_ACTION = 0x1f0
local OXPOS, OXVAL = 0x090, 0x080
local MAX_HP = 0xA1
local PERIOD, DIST = 26, 70

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[jd] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

if not (f_jdefend and l_jdguard) then
    log("f_jdefend / l_jdguard are not in mk2.map - jdefend is compiled OUT.")
    log("VERDICT: NOT BUILT")
    return
end

for _, n in ipairs({
    "P1 Left", "P1 Right", "P1 Up", "P1 Down",
    "P1 High Punch", "P1 Low Punch", "P1 High Kick", "P1 Low Kick", "P1 Block",
    "P2 Left", "P2 Right", "P2 Up", "P2 Down",
    "P2 High Punch", "P2 Low Punch", "P2 High Kick", "P2 Low Kick", "P2 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local last_hp, off, measuring, meas_start, meas_class = nil, 0, false, 0, 0
local cooldown = 0
-- A drop is not classified on the frame it happens.  The reaction transfer
-- has not run yet, so p_action still reads act_blockhi for a CLEAN hit too -
-- and since f_jdefend is only rewritten by a BLOCKED strike, a clean hit
-- landing after a perfect block inherits its flag and lands in the wrong
-- bucket.  That is not a small effect: it put clean 24s into the perfect
-- bucket and reported it as "perfect blocks take MORE chip".  Wait two frames
-- and ask again; by then a clean hit is unmistakably out of the block action.
local pend, pend_at, pend_drop = false, 0, 0
local B = {                                   -- [class] = bucket
    [0] = { n = 0, chip = 0, stun = 0, stun_n = 0, gap = 0 },
    [1] = { n = 0, chip = 0, stun = 0, stun_n = 0, gap = 0 },
}
local hist = { [0] = {}, [1] = {} }
local gapmin = { [0] = 9999, [1] = 9999 }
local gapmax = { [0] = -1, [1] = -1 }
local clean_hits = 0
-- JD_SHOTS=1: snapshot the white flash.  jd_flash_proc waits one tick (so
-- blocked_start's own player_normpal cannot wipe it), holds white for jdflash
-- ticks, then restores - so the picture is only there for a handful of frames
-- around contact+2, and a fixed offset from the ATTACK would miss it.  Anchor
-- on the contact frame instead.
local SHOTS = os.getenv("JD_SHOTS") == "1"
local shot_at, shots_done = nil, 0

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end
local function p2_word(base)
    return space:read_u16(base + 16) & 0xffff
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== perfect block === chip and stun, bucketed by f_jdefend")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame; last_hp = nil end
    local t = frame - fight0
    if t < 45 then return end

    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r2 = space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r2 == 0 then return end

    -- both bars pinned: chip is the signal, so it has to be read then refilled
    space:write_u16(p1_bar, MAX_HP)
    local hp_now = space:read_u16(p2_bar) & 0xffff
    local drop = (last_hp and hp_now < last_hp) and (last_hp - hp_now) or 0
    space:write_u16(p2_bar, MAX_HP)
    last_hp = MAX_HP

    local a2 = space:read_u16(r2 + P_ACTION) & 0xffff
    local guarding = (a2 == ACT_BLOCKHI or a2 == ACT_BLOCKLO)

    -- pin the distance (oxval - a write to oxpos is overwritten before the draw)
    local x1 = s16(space:read_u16(o1 + OXPOS))
    local x2 = s16(space:read_u16(o2 + OXPOS))
    local tx = (x1 < x2) and (x1 + DIST) or (x1 - DIST)
    space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)

    -- shots run ahead of every branch below, because the last one is taken
    -- after the stun measurement has already released the frame
    if shot_at then
        local d = frame - shot_at
        if d == 2 or d == 3 or d == 4 or d == 5 or d == 16 then
            pcall(function() manager.machine.screens[":screen"]:snapshot() end)
        end
        if d >= 16 then shot_at = nil end
    end

    ------------------------------------------------------------------ measuring
    if measuring then
        press("P1 High Kick", false)
        press("P2 Block", false)          -- only block_shake holds him now
        if not guarding then
            local b = B[meas_class]
            b.stun = b.stun + (frame - meas_start)
            b.stun_n = b.stun_n + 1
            measuring = false
            cooldown = 20
        elseif frame - meas_start > 90 then
            measuring = false             -- something else has him; drop it
            cooldown = 20
        end
        return
    end

    ------------------------------------------------------------------- a hit ?
    if pend then
        press("P1 High Kick", false)
        press("P2 Block", false)
        if frame - pend_at < 2 then return end
        pend = false
        if not guarding then
            clean_hits = clean_hits + 1   -- he was transferred to a reaction
            cooldown = 20
            return
        end
        local cls = (p2_word(f_jdefend) ~= 0) and 1 or 0
        local b = B[cls]
        b.n = b.n + 1
        b.chip = b.chip + pend_drop
        hist[cls][pend_drop] = (hist[cls][pend_drop] or 0) + 1
        local gap = (space:read_u16(tick_sym) - p2_word(l_jdguard)) & 0xffff
        if gap < gapmin[cls] then gapmin[cls] = gap end
        if gap > gapmax[cls] then gapmax[cls] = gap end
        if SHOTS and cls == 1 and shots_done < 8 then
            shot_at = pend_at
            shots_done = shots_done + 1
            log("  flash sample %d: perfect block at frame %d", shots_done, pend_at)
        end
        -- the stun clock starts at the CONTACT frame, not here
        measuring, meas_start, meas_class = true, pend_at, cls
        return
    end
    if drop > 0 then
        pend, pend_at, pend_drop = true, frame, drop
        press("P1 High Kick", false)
        press("P2 Block", false)
        return
    end

    if cooldown > 0 then
        cooldown = cooldown - 1
        press("P1 High Kick", false); press("P2 Block", false)
        return
    end

    ------------------------------------------------------- drive the two sticks
    local ph = t % PERIOD
    if ph == 0 then off = (off + 1) % PERIOD end
    press("P1 High Kick", ph >= 0 and ph <= 2)
    -- P2's guard goes up at a walking offset and stays up for 8 ticks, so
    -- across the sweep it is raised everywhere from "long before" to "now"
    local bph = (ph - off) % PERIOD
    press("P2 Block", bph <= 8)
end)

emu.register_stop(function()
    log("clean (unguarded) hits: %d", clean_hits)
    for _, cls in ipairs({0, 1}) do
        local b = B[cls]
        local name = (cls == 1) and "PERFECT " or "ordinary"
        if b.n == 0 then
            log("%s block: no samples", name)
        else
            log("%s block: n=%-3d  chip avg %.2f  stun avg %.1f frames (n=%d)"
                .. "   guard age %d..%d ticks",
                name, b.n, b.chip / b.n,
                b.stun_n > 0 and (b.stun / b.stun_n) or -1, b.stun_n,
                gapmin[cls], gapmax[cls])
            local keys = {}
            for k in pairs(hist[cls]) do keys[#keys + 1] = k end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = string.format("%d x%d", k, hist[cls][k])
            end
            log("          damage seen: %s", table.concat(parts, ", "))
        end
    end
    if B[1].n == 0 then
        log("VERDICT: no perfect block was ever recognised")
    elseif B[0].n == 0 then
        log("VERDICT: EVERY block was perfect - the window is not discriminating")
    else
        local dc = B[0].chip / B[0].n - B[1].chip / B[1].n
        local ds = (B[0].stun_n > 0 and B[1].stun_n > 0)
                   and (B[0].stun / B[0].stun_n - B[1].stun / B[1].stun_n) or 0
        log("VERDICT: perfect block saves %.2f chip and %.1f frames of stun", dc, ds)
    end
end)
