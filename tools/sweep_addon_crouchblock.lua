-- sweep_addon_crouchblock.lua - do roundhouses and uppercuts CONNECT against
--                               a crouch-blocking opponent?
--
-- Tester report: "All character Roundhouses and Uppercuts now connect against
-- crouch block" - i.e. today they do not. This measures whether they make
-- contact at all, before anything is changed, because the boxes look on paper
-- as though they should overlap:
--
--   stk_lkroundh    y_offset  5   y_size 030h (48)  -> oypos+5  .. oypos+53
--   stk_lkuppercut  y_offset -0ah y_size 040h (64)  -> oypos-10 .. oypos+54
--   am_i_short: a crouching fighter is <= 060h (96) tall
--
-- CONTACT IS MEASURED AS CHIP, not as a hitbox overlap. A blocked strike runs
-- strike_blocked, which takes the low byte of the damage word off the bar - so
-- a drop in P2's HP means the move connected and was guarded, and no drop at
-- all means it passed straight through. That is the difference the report is
-- about, and it needs no assumptions about how the boxes are built.
--
-- Four phases, each the same number of attempts:
--
--   rh_stand   roundhouse (away + HK) vs P2 holding Block
--   rh_crouch  roundhouse             vs P2 holding Down + Block
--   up_stand   uppercut   (Down + HP) vs P2 holding Block
--   up_crouch  uppercut               vs P2 holding Down + Block
--
-- The standing rows are the control: if those connect and the crouching ones
-- do not, the report is confirmed and it is a height problem, not a range one.
--
-- Env: CBLOCK_LOG
-- Driven by run_crouchblock_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("CBLOCK_LOG") or (ROOT .. "/tools/crouchblock.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_proc = sym.gstate, sym.p1_proc
local p1_obj, p2_obj, p2_bar = sym.p1_obj, sym.p2_obj, sym.p2_bar
local p2_proc = sym.p2_proc

local P_ACTION = 0x1f0
local OXPOS    = 0x090
local OXVAL    = 0x080          -- the 32-bit value; oxpos writes get overwritten
local OYPOS    = 0x0b0
local OIMG     = 0x1a0
-- multipart record: sag(32) W(16) H(16) control(16) dx(16) dy(16) = 112 bits
local MP_W, MP_H, MP_DX, MP_DY, MP_NEXT = 32, 48, 80, 96, 112

-- P1 is Liu Kang in this rig, so his roundhouse box is stk_lkroundh.
local RH_YOFF, RH_YSIZE = 5, 0x48   -- stk_lkroundh, after the resize
local RH_XOFF, RH_XSIZE = 88, 45
local MAX_HP = 0xA1
local ACT_RHOUSE   = 0x0105        -- act_rhouse (MAINEQU.ASM)
local ACT_UPPERCUT = 0x0107

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[cblock] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left", "P1 Right", "P1 Up", "P1 Down",
    "P1 High Punch", "P1 Low Punch", "P1 High Kick", "P1 Low Kick", "P1 Block",
    "P2 Left", "P2 Right", "P2 Up", "P2 Down",
    "P2 High Punch", "P2 Low Punch", "P2 High Kick", "P2 Low Kick", "P2 Block",
}) do ADDON_OWNS[n] = true end

local PHASES = {"rh_stand", "rh_crouch", "up_stand", "up_crouch"}
local space, frame, fight0 = nil, 0, 0
local fields = {}
local pi, phase_at = 1, 0
local tries, hits = {}, {}
for _, p in ipairs(PHASES) do tries[p], hits[p] = 0, 0 end
local in_move, hp_at_start, hp_dist = false, nil, nil
local ymin, ymax = 9999, -9999
local last_hp, dmg_in_move = nil, 0
local cur_dist = 0
local conn_at = {}
local dmgs = {}
local logged_geo = {}
for _, p in ipairs({'rh_stand','rh_crouch','up_stand','up_crouch'}) do conn_at[p] = {}; dmgs[p] = {} end

local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
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
        log("=== crouch block === do roundhouse / uppercut connect when guarded low?")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame; phase_at = frame end
    local t = frame - fight0
    local phase = PHASES[pi]
    if not phase then return end

    local pr = space:read_u32(p1_proc)
    if pr == 0 then return end
    local act = space:read_u16(pr + P_ACTION) & 0xffff

    -- P2'S BAR HAS TO BE TOPPED UP EVERY FRAME, and this was the bug in the
    -- first four runs of this rig. The harness pins P1's bar, not P2's - so
    -- 17 chips at 8 apiece took him from 161 to nearly nothing during the very
    -- first phase, he died, the round ended, gstate left 2 and every later
    -- phase ran on garbage. That is why the crouching rows appeared to connect
    -- only at the FIRST distance step: everything after it was a corpse.
    --
    -- The damage still has to be READ before it is refilled, because chip is
    -- the contact signal - so take the delta, then restore.
    local hp_now = space:read_u16(p2_bar) & 0xffff
    if last_hp and hp_now < last_hp then
        dmg_in_move = dmg_in_move + (last_hp - hp_now)
    end
    space:write_u16(p2_bar, MAX_HP)
    last_hp = MAX_HP

    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
    local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
    local dist = math.abs(x2 - x1)

    -- One attempt = one execution of the move; a hit = any HP the guard lost
    -- during it. Roundhouse's action is act_rhouse, uppercut's act_uppercut.
    local want = (phase:sub(1, 2) == "rh") and ACT_RHOUSE or ACT_UPPERCUT
    local attacking = (act == want)
    if attacking then
        local yy = s16(space:read_u16(o1 + OYPOS))
        if yy < ymin then ymin = yy end
        if yy > ymax then ymax = yy end
    end
    if attacking and not in_move then
        in_move, hp_dist = true, cur_dist
        dmg_in_move = 0
        ymin, ymax = 9999, -9999
        tries[phase] = tries[phase] + 1
    elseif (not attacking) and in_move then
        in_move = false
        -- THE BOX MOVES WITH HIM. Sampling only the move's first tick reports
        -- where the strike box STARTS, not where it is on the active frames -
        -- so log the attacker's oypos range across the whole move.
        local k = phase .. "y" .. tostring(hp_dist)
        if not logged_geo[k] then
            logged_geo[k] = true
            log("  YRANGE %-9s d=%-3d attacker oypos %d..%d -> box y %d..%d (worst) %d..%d (best)",
                phase, hp_dist or -1, ymin, ymax,
                ymin + RH_YOFF, ymin + RH_YOFF + RH_YSIZE,
                ymax + RH_YOFF, ymax + RH_YOFF + RH_YSIZE)
        end
        if dmg_in_move > 0 then
            hits[phase] = hits[phase] + 1
            conn_at[phase][hp_dist] = (conn_at[phase][hp_dist] or 0) + 1
            -- The MAGNITUDE says whether the guard held. Roundhouse chips 8
            -- and hits for 32; uppercut chips 10 and hits for 40. "Connect"
            -- in the tester's note could mean either, so record both.
            dmgs[phase][dmg_in_move] = (dmgs[phase][dmg_in_move] or 0) + 1
        end
    end

    -- 600, not 1050: four phases have to fit inside ONE round. At 1050 the
    -- round timer expired during the fourth, gstate left 2, and up_crouch got
    -- 2 attempts where the others got 20.
    if frame - phase_at > 600 then
        log("%-9s tries=%2d connected=%2d", phase, tries[phase], hits[phase])
        pi = pi + 1
        phase_at = frame
        if PHASES[pi] then log("--- phase: %s", PHASES[pi]) end
        return
    end

    -- THE DISTANCE IS PINNED, and swept.
    --
    -- Walking into range left the connect rate at 45% for the roundhouse and
    -- 29% for the uppercut, which is a DISTANCE result wearing a height
    -- result's clothes - the two fighters are never in the same place twice.
    -- Pinning removes it: P2 is parked at an exact offset from P1 that steps
    -- every few attempts, so "connects at some distance" and "connects at no
    -- distance" become distinguishable, which is the actual question.
    --
    -- oxval, not oxpos: a write to oxpos is overwritten before the draw.
    --
    local step = math.floor((frame - phase_at) / 86)      -- 0..6
    local want = 40 + step * 12                            -- 40 .. 112 px
    if o1 ~= 0 and o2 ~= 0 then
        local tx = (x1 < x2) and (x1 + want) or (x1 - want)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
        cur_dist = want
    end

    -- WHERE THE BOXES ACTUALLY ARE.  Sampled once per phase while the move is
    -- live, so the fix is sized off the geometry instead of guessed at. The
    -- victim's extent is his multipart chain walked directly: a piece's world
    -- top is `oypos - dy` and it runs H down from there.
    local gkey = phase .. tostring(cur_dist)
    if attacking and not logged_geo[gkey] and o1 ~= 0 and o2 ~= 0 then
        logged_geo[gkey] = true
        local y1 = s16(space:read_u16(o1 + OYPOS))
        local y2 = s16(space:read_u16(o2 + OYPOS))
        local top, bot = 9999, -9999
        local rec = space:read_u32(o2 + OIMG)
        for _ = 1, 12 do
            if rec == 0 or space:read_u32(rec) == 0 then break end
            local h  = space:read_u16(rec + MP_H) & 0xffff
            local dy = s16(space:read_u16(rec + MP_DY))
            local t = y2 - dy
            if t < top then top = t end
            if t + h > bot then bot = t + h end
            rec = rec + MP_NEXT
        end
        local left, right = 9999, -9999
        local rec2 = space:read_u32(o2 + OIMG)
        for _ = 1, 12 do
            if rec2 == 0 or space:read_u32(rec2) == 0 then break end
            local w  = space:read_u16(rec2 + MP_W) & 0xffff
            local dx = s16(space:read_u16(rec2 + MP_DX))
            local l = x2 - dx
            if l < left then left = l end
            if l + w > right then right = l + w end
            rec2 = rec2 + MP_NEXT
        end
        -- Both boxes in the ATTACKER's frame, which is how strike_check
        -- compares them: the strike rect for an unflipped attacker is
        -- [oxpos + x_off - x_size, oxpos + x_off].
        local sx1 = (x1 + RH_XOFF - RH_XSIZE) - x1
        local sx2 = (x1 + RH_XOFF) - x1
        -- P2's ACTION matters as much as his box: a roundhouse whiffing over
        -- a plain DUCK (act_duck 0302h) is correct behaviour, and would look
        -- identical to the bug. Only act_blocklo (0701h) is the case asked
        -- about.
        local p2p = space:read_u32(p2_proc)
        local a2 = p2p ~= 0 and (space:read_u16(p2p + P_ACTION) & 0xffff) or 0xffff
        log("  GEO %-9s d=%-3d p2_act=%04x  strike x=%d..%d y=%d..%d   victim x=%d..%d y=%d..%d",
            phase, cur_dist, a2, sx1, sx2, y1 + RH_YOFF, y1 + RH_YOFF + RH_YSIZE,
            left - x1, right - x1, top, bot)
    end

    local rh = phase:sub(1, 2) == "rh"
    press("P1 Left", false); press("P1 Right", false)
    press("P1 Down", false)
    press("P1 High Kick", false); press("P1 High Punch", false)

    local c = t % 26
    if rh then
        -- away + HK together, two ticks only: is_stick_away is sampled when
        -- the button goes in, and HOLDING away would fight the pin.
        local fire = (c == 22 or c == 23)
        press("P1 Left",  fire and x1 < x2)
        press("P1 Right", fire and x1 > x2)
        press("P1 High Kick", fire)
    else
        press("P1 Down", true)                     -- bt_duck must be installed
        press("P1 High Punch", c == 22 or c == 23)
    end

    -- The guard.
    press("P2 Block", true)
    press("P2 Down", phase:sub(-6) == "crouch")
    press("P2 Left", false); press("P2 Right", false)
end)

emu.register_stop(function()
    for _, p in ipairs(PHASES) do
        local ds = {}
        for d, n in pairs(conn_at[p]) do ds[#ds + 1] = string.format("%d(x%d)", d, n) end
        table.sort(ds)
        local dl = {}
        for d, n in pairs(dmgs[p]) do dl[#dl + 1] = string.format("%d dmg x%d", d, n) end
        table.sort(dl)
        log("RESULT %-9s tries=%2d connected=%2d  at px: %s", p, tries[p], hits[p],
            #ds > 0 and table.concat(ds, " ") or "NONE")
        log("       %-9s damage: %s", p, #dl > 0 and table.concat(dl, ", ") or "-")
    end
    local rs, rc = hits.rh_stand, hits.rh_crouch
    local us, uc = hits.up_stand, hits.up_crouch
    if tries.rh_stand == 0 or tries.up_stand == 0 then
        log("VERDICT NO-CASE (the moves never came out - check the inputs)")
    elseif rs > 0 and rc == 0 then
        log("VERDICT CONFIRMED - roundhouse connects standing, NEVER crouching")
    elseif us > 0 and uc == 0 then
        log("VERDICT CONFIRMED - uppercut connects standing, NEVER crouching")
    elseif rc > 0 and uc > 0 then
        log("VERDICT both connect against crouch block (rh %d, up %d)", rc, uc)
    else
        log("VERDICT MIXED rh %d/%d  up %d/%d (stand/crouch)", rs, rc, us, uc)
    end
end)
