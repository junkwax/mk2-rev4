-- sweep_addon_jcceiling.lua - how badly does spamming Cage's ceiling uppercut
--                             beat the drone?
--
-- Tester report: "johnnys shadow from ceiling to floor uppercut basically
-- destroys them when spammed over and over".
--
-- The move (do_jc_ceiling, MKPROP.ASM) rockets off the top of the screen,
-- TELEPORTS to 28px in front of the opponent and rises with stk_jcuppercut -
-- 40 damage, the top tier. Walking away cannot beat it, so the only answer is
-- to guard it.
--
-- The drone has no answer at all: beware_lookup maps an action to a handler
-- through catagory_table, and counter_propell's row 20f (act_jc_ceiling) is a
-- literal 0, "no reaction", under a stale comment claiming the action is never
-- set. do_jc_ceiling sets it on its third instruction.
--
-- WHAT IS COUNTED, and why it is damage and not "did it hit": the outcome that
-- matters is which of three things happened, and the damage says it exactly -
--
--   ~40   clean uppercut, the drone ate it
--   ~10   guarded, chip only  (stk_jcuppercut's block byte)
--     0   whiffed or avoided
--
-- P2's bar is refilled every frame AFTER the delta is taken, or the drone dies
-- in the first few attempts and the rest of the run measures a corpse.
--
-- Env: JCC_LOG, JCC_DIFF (drone difficulty 0-9, default 9)
-- Driven by run_jcceiling_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("JCC_LOG") or (ROOT .. "/tools/jcceiling.txt")
local DIFF = tonumber(os.getenv("JCC_DIFF") or "9")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local diff = sym.diff

local P_ACTION = 0x1f0
local ACT_JC_CEILING = 0x020f
local MAX_HP = 0xA1

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[jcc] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local last_hp, dmg, in_move = nil, 0, false
local tries, hit, blocked, missed = 0, 0, 0, 0
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
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
        log("=== jc ceiling === Cage spams D,D,U+HP at the drone (diff %d)", DIFF)
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    space:write_u16(diff, DIFF)
    space:write_u16(p1_bar, MAX_HP)

    local hp = space:read_u16(p2_bar) & 0xffff
    if last_hp and hp < last_hp then dmg = dmg + (last_hp - hp) end
    space:write_u16(p2_bar, MAX_HP)
    last_hp = MAX_HP

    local pr = space:read_u32(p1_proc)
    if pr == 0 then return end
    local act = space:read_u16(pr + P_ACTION) & 0xffff

    if act == ACT_JC_CEILING and not in_move then
        in_move, dmg = true, 0
        tries = tries + 1
    elseif act ~= ACT_JC_CEILING and in_move then
        in_move = false
        if dmg >= 25 then hit = hit + 1
        elseif dmg > 0 then blocked = blocked + 1
        else missed = missed + 1 end
        if tries <= 4 then log("  try %d: %d damage", tries, dmg) end
    end

    -- Forward, Forward, Back + HP (scom_jc_ceiling, window 48 ticks).
    -- NOT "D,D,U + HP" - that is what the comment at the dispatch site in
    -- MOVES.ASM says, and it is stale; combo_edit.py reads the real table.
    -- P1 starts on the left, so forward is Right.
    -- The stick must RELEASE between the two forwards or the reader sees one
    -- long press instead of two.
    local c = t % 64
    press("P1 Right", (c >= 0 and c <= 2) or (c >= 6 and c <= 8))
    press("P1 Left",  c >= 12 and c <= 14)
    press("P1 High Punch", c == 14 or c == 15)
end)

emu.register_stop(function()
    log("RESULT tries=%d  clean hit=%d  blocked=%d  whiffed/avoided=%d",
        tries, hit, blocked, missed)
    if tries == 0 then
        log("VERDICT NO-CASE (the move never came out - check the input)")
    else
        -- The guard rate is measured against attempts that CONNECTED, not
        -- against every attempt. A whiff means the drone happened to be
        -- somewhere else - it says nothing about whether he can read the move,
        -- and its share swings enough between runs to hide the difficulty
        -- curve completely.
        local conn = hit + blocked
        if conn == 0 then
            log("VERDICT NO-CASE (nothing connected either way)")
        else
            log("VERDICT diff %d: guarded %d of %d connections (%d%%), %d whiffed",
                DIFF, blocked, conn, math.floor(blocked * 100 / conn), missed)
        end
    end
end)
