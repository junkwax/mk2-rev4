-- sweep_addon_kickrecover.lua - does the low kick's on-hit hangtime ALSO
--                               happen on block?
--
-- kick2 (MOVES.ASM) ends:
--
--      jsrp    striker
--      jrnc    kik3
--      sleep   012h            ; 18 ticks
--  kik3 ...retract...
--
-- tools/frame_advantage.py drops that sleep from every on-block number, on
-- the stated grounds that it is "on-hit hangtime that never happens on
-- block".  If that is wrong, every kick in doc/FRAME_ADVANTAGE.md reads 18
-- ticks better on block than it really is - which is exactly the kind of
-- number a rebalance would be built on.
--
-- Reading the code says the assumption is wrong: `striker`'s carry comes from
-- strike_check_a0, and strike_check's BLOCKED path (strike_blocked) ends
-- `jruc yes_collision`, which setc's just like a clean hit.  So carry means
-- CONTACT, hit or blocked, and the sleep should fire on both.
--
-- This measures it instead of arguing.  The move's total duration is timed
-- from p_action becoming act_medkick until it is neither that nor
-- act_ret_kick, in three conditions:
--
--   whiff    P2 held far away.  No contact, no sleep.
--   block    P2 in range holding Block.
--   hit      P2 in range doing nothing.
--
-- Predictions:
--   assumption CORRECT -> block == whiff, hit == whiff + 18
--   assumption WRONG   -> block == hit  == whiff + 18
--
-- Env: KICKREC_LOG
-- Driven by run_kick_recovery_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("KICKREC_LOG") or (ROOT .. "/tools/kick_recovery.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_proc, p2_proc = sym.gstate, sym.p1_proc, sym.p2_proc
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar

local P_ACTION = 0x1f0
local OXPOS    = 0x090
local ACT_MEDKICK  = 0x0104
local ACT_RET_KICK = 0x060c

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[kickrec] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left", "P1 Right", "P1 Up", "P1 Down",
    "P1 High Punch", "P1 Low Punch", "P1 High Kick", "P1 Low Kick", "P1 Block",
    "P2 Left", "P2 Right", "P2 Up", "P2 Down",
    "P2 High Punch", "P2 Low Punch", "P2 High Kick", "P2 Low Kick", "P2 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local kick_start, prev_act = nil, nil
local samples = {whiff = {}, block = {}, hit = {}}
local phase, phase_at = "whiff", 0
local hp_last = nil

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

local function median(t)
    if #t == 0 then return -1 end
    table.sort(t)
    return t[(#t + 1) // 2]
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
        log("=== kick recovery === does the kick2 hangtime fire on block?")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame; phase_at = frame end
    local t = frame - fight0

    local pr = space:read_u32(p1_proc)
    if pr == 0 then return end
    local act = space:read_u16(pr + P_ACTION) & 0xffff

    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
    local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
    local dist = math.abs(x2 - x1)

    -- Time the whole move: act_medkick through act_ret_kick.
    local in_move = (act == ACT_MEDKICK or act == ACT_RET_KICK)
    if in_move and kick_start == nil then
        kick_start = frame
        hp_last = space:read_u16(p2_bar) & 0xffff
    elseif (not in_move) and kick_start ~= nil then
        local dur = frame - kick_start
        local hp = space:read_u16(p2_bar) & 0xffff
        -- Only keep samples that match the phase's intent.
        local touched = hp ~= hp_last
        local keep = (phase == "whiff" and not touched and dist > 150)
                  or (phase ~= "whiff" and touched)
        if keep and dur > 4 and dur < 200 then
            table.insert(samples[phase], dur)
            if #samples[phase] <= 3 then
                log("  %-5s dur=%d dist=%d dmg=%d", phase, dur, dist, hp_last - hp)
            end
        end
        kick_start = nil
    end

    -- Phase schedule: whiff, then block, then hit.
    if phase == "whiff" and frame - phase_at > 900 then
        phase, phase_at = "block", frame
        log("--- phase: BLOCK (P2 holds block, P1 kicks in range)")
    elseif phase == "block" and frame - phase_at > 900 then
        phase, phase_at = "hit", frame
        log("--- phase: HIT (P2 stands, P1 kicks in range)")
    end

    -- P1 drives to the range this phase wants, then mashes Low Kick.
    local want_far = (phase == "whiff")
    local c = t % 24
    if want_far then
        press("P1 Left", dist < 190 and x1 < x2)
        press("P1 Right", dist < 190 and x1 > x2)
    else
        press("P1 Left", dist > 70 and x1 > x2)
        press("P1 Right", dist > 70 and x1 < x2)
    end
    press("P1 Low Kick", c == 20 or c == 21)

    -- P2 blocks only in the block phase, and never moves.
    press("P2 Block", phase == "block")
    press("P2 Left", false); press("P2 Right", false)
end)

emu.register_stop(function()
    local w, b, h = median(samples.whiff), median(samples.block), median(samples.hit)
    log("SAMPLES whiff=%d block=%d hit=%d", #samples.whiff, #samples.block, #samples.hit)
    log("MEDIAN DURATION  whiff=%d  block=%d  hit=%d", w, b, h)
    if w < 0 or b < 0 or h < 0 then
        log("VERDICT NO-CASE (a phase produced no usable samples)")
        return
    end
    --
    -- THE SHAPE THIS NOW ASSERTS.  do_lo_kick keeps the 18-tick hangtime on
    -- BLOCK and drops it on a clean HIT, which is what makes the kick exactly
    -- neutral on hit while staying deeply unsafe on block.
    --
    --   whiff  32   startup 6 + 6 active + 20 retract
    --   block  44   + contact, still pays the 18
    --   hit    26   contact, no hangtime: 20 of recovery against 20 of
    --               hitstun = 0
    --
    -- Before the change hit was 44 as well, and the kick was -18 on hit -
    -- worse than whiffing it.
    --
    local W, B, H = 32, 44, 26
    local function near(x, y) return math.abs(x - y) <= 2 end
    if near(w, W) and near(b, B) and near(h, H) then
        log("VERDICT PASS - neutral on hit (%d), still unsafe on block (%d)", h, b)
    elseif near(b, h) then
        log("VERDICT FAIL - block and hit are the same again (%d/%d):", b, h)
        log("        the hangtime is back on the clean-hit path, or b2 is not")
        log("        reading as the blocked flag.  See do_lo_kick.")
    else
        log("VERDICT FAIL - expected whiff/block/hit ~ %d/%d/%d, got %d/%d/%d",
            W, B, H, w, b, h)
    end
end)
