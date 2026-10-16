-- sweep_addon_dronehole.lua - measure a move the drone has no reaction row for.
--
-- Generalises the Cage ceiling-uppercut rig to the other holes found by
-- tools/audit_drone_reactions.py. Each is an action the game assigns whose
-- row in the drone's beware tables is 0, so the AI has no answer to it at all.
--
--   HOLE=square  Kitana, F,D,B + HP   act_square       0207h
--   HOLE=portal  Noob,   D,D   + LK   act_noob_portal  0117h
--   HOLE=tks     Ermac,  B,D,B + HK   act_ermac_tks    011bh
--
-- HOW A CONNECT IS CLASSIFIED. Damage alone will not do it here: these three
-- have different hit and chip bytes and the ranges overlap, so a threshold
-- that works for one mislabels another. Instead the drone's OWN ACTION is
-- sampled on the frame the damage lands:
--
--   07xx  he is still blocking  -> GUARDED
--   any other action            -> he was hit
--
-- which is what the two outcomes actually look like from his side, whatever
-- the numbers happen to be.
--
-- The drone's bar is refilled every frame after the delta is taken, or he dies
-- and the rest of the run measures a corpse.
--
-- Env: HOLE (square|portal|tks), HOLE_LOG, HOLE_DIFF
-- Driven by run_dronehole_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local WHICH = (os.getenv("HOLE") or "square"):lower()
local OUT  = os.getenv("HOLE_LOG") or (ROOT .. "/tools/dronehole.txt")
local DIFF = tonumber(os.getenv("HOLE_DIFF") or "9")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local diff = sym.diff

local P_ACTION, OXPOS, OXVAL = 0x1f0, 0x090, 0x080
local MAX_HP = 0xA1

-- act code, and the stick/button pattern. Ticks are offsets into a 64-tick
-- cycle; the stick must RELEASE between repeats or the reader sees one press.
local MOVES = {
    square = {act = 0x0207, name = "Kitana square wave (F,D,B + HP)",
              stick = {{"fwd",0,2},{"down",5,7},{"back",10,12}}, btn = "P1 High Punch", bt = 12},
    portal = {act = 0x0117, name = "Noob shadow portal (D,D + LK)",
              stick = {{"down",0,2},{"down",6,8}}, btn = "P1 Low Kick", bt = 9},
    tks    = {act = 0x011b, name = "Ermac telekinetic slam (B,D,B + HK)",
              stick = {{"back",0,2},{"down",5,7},{"back",10,12}}, btn = "P1 High Kick", bt = 12},
}
local M = MOVES[WHICH]

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[hole] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local last_hp, in_move = nil, false
local logged_char = false
local dmg, guarded = 0, false
local tries, hit, blocked, missed = 0, 0, 0, 0
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

emu.register_frame(function()
    frame = frame + 1
    if not M then return end
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== %s === diff %d", M.name, DIFF)
        logged_char = false
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    if not logged_char then
        logged_char = true
        -- Confirm the fighter was actually FORCED before blaming the inputs:
        -- Noob and Ermac are hidden, and select-forcing does not always take.
        local o1 = space:read_u32(p1_obj)
        log("  p1 ochar=%d (wanted the mover), p2 ochar=%d",
            o1 ~= 0 and (space:read_u16(o1 + 0x1f0) & 0xffff) or -1,
            (function() local o = space:read_u32(p2_obj)
             return o ~= 0 and (space:read_u16(o + 0x1f0) & 0xffff) or -1 end)())
    end
    local t = frame - fight0

    space:write_u16(diff, DIFF)
    space:write_u16(p1_bar, MAX_HP)

    local dp = space:read_u32(p2_proc)
    local dact = dp ~= 0 and (space:read_u16(dp + P_ACTION) & 0xffff) or 0

    local hp = space:read_u16(p2_bar) & 0xffff
    if last_hp and hp < last_hp then
        dmg = dmg + (last_hp - hp)
        -- his action ON THE DAMAGE FRAME is what says guarded or not
        if (dact >> 8) == 7 then guarded = true end
    end
    space:write_u16(p2_bar, MAX_HP)
    last_hp = MAX_HP

    local pr = space:read_u32(p1_proc)
    if pr == 0 then return end
    local act = space:read_u16(pr + P_ACTION) & 0xffff

    if act == M.act and not in_move then
        in_move, dmg, guarded = true, 0, false
        tries = tries + 1
    elseif act ~= M.act and in_move then
        in_move = false
        if dmg == 0 then missed = missed + 1
        elseif guarded then blocked = blocked + 1
        else hit = hit + 1 end
    end

    -- hold the distance so range is not the variable under test
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
    local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
    if o1 ~= 0 and o2 ~= 0 then
        local tx = (x1 < x2) and (x1 + 70) or (x1 - 70)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end

    local fwd = (x1 < x2) and "P1 Right" or "P1 Left"
    local back = (x1 < x2) and "P1 Left" or "P1 Right"
    press("P1 Left", false); press("P1 Right", false); press("P1 Down", false)
    press(M.btn, false)

    local c = t % 64
    for _, seg in ipairs(M.stick) do
        if c >= seg[2] and c <= seg[3] then
            if seg[1] == "fwd" then press(fwd, true)
            elseif seg[1] == "back" then press(back, true)
            else press("P1 Down", true) end
        end
    end
    press(M.btn, c == M.bt or c == M.bt + 1)
end)

emu.register_stop(function()
    if not M then log("VERDICT NO-CASE (unknown HOLE=%s)", tostring(WHICH)); return end
    local conn = hit + blocked
    log("RESULT %-7s diff %d  tries=%d  hit=%d  guarded=%d  whiffed=%d",
        WHICH, DIFF, tries, hit, blocked, missed)
    if tries == 0 then
        log("VERDICT NO-CASE (the move never came out - check the input)")
    elseif conn == 0 then
        log("VERDICT NO-CASE (it never connected either way)")
    else
        log("VERDICT %s: guarded %d of %d connections (%d%%)",
            WHICH, blocked, conn, math.floor(blocked * 100 / conn))
    end
end)
