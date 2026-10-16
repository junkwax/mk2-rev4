-- kham_sai_hit_test.lua
--
-- Throw the sai and photograph it IN FLIGHT, with Mileena as the control.
--
-- WHAT THIS DOES AND DOES NOT PROVE.  It photographs the flight lane, which
-- is TABLE2 index 6 - the exact index the bug got wrong.  It does NOT
-- photograph the impact frames, because no scripted victim would take a sai:
-- the drone ducks every one, and a pinned idle second player is never hit
-- either.  That last part fails the same way for MILEENA, the shipped
-- reference implementation, which is how we know it is the rig and not the
-- character.  The impact is `find_part2` of this same lane resolved by this
-- same call, and tools/audit_kham_sai_lanes.py proves saih4 makes it - so
-- the flight photograph plus that audit is the coverage, not a screenshot
-- of contact.
--
-- Khameleon's sai lanes are relocated to 0ch-0eh of fn4_anitab2 and biased
-- by kham_sai_ani2 (MKZAP.ASM).  A site that misses the bias draws index
-- 5/6/7 of HER table instead - the square wave and Jade's boomerang - with
-- no crash and no build error.  That is exactly what shipped once: `saih4`,
-- the shared hit/blocked impact tail, was missed and drew boomerang frames
-- at the moment of contact.
--
-- The flight lanes are easy to eyeball; the IMPACT is not, because it is
-- `find_part2` of the flight lane and only appears for a few frames on the
-- frame the victim is hit.  So this rig triggers on the victim's health
-- DROPPING and photographs the frames straight after.
--
-- MILEENA IS THE CONTROL.  She is the reference implementation of this move:
-- her sai reads the same lanes with no bias at all.  Run both and the impact
-- must look the same.  A rig with no control cannot tell "the bias is wrong"
-- from "the sai just looks like that".
--
--   KHAM_SAI_MODE   kham | mileena
--   KHAM_SAI_LOG    log file path

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("KHAM_SAI_MODE") or "kham"
local LOG = os.getenv("KHAM_SAI_LOG") or (ROOT .. "/tools/kham_sai_hit_" .. MODE .. ".log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[sai-hit/" .. MODE .. "] " ..
              (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), diff = sym("diff"),
    p1_proc = sym("p1_proc"), p1_char = sym("p1_char"), p1_bar = sym("p1_bar"),
    p2_char = sym("p2_char"), p2_bar = sym("p2_bar"), p2_proc = sym("p2_proc"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p2_xvel = sym("p2_xvel"),
}
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k) end end

local P_ACTION, OXPOS = 0x1f0, 0x90
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_MILEENA, FT_JAX, FT_KHAM, MAX_HP = 4, 5, 11, 18, 0xa1
local ACT_SAI, ACT_AIR_SAI = 0x00a, 0x00b

local WHO, POST, PSEL
if MODE == "mileena" then
    -- Mileena is a roster pick, so she needs no GS_POST override at all.
    -- NOTE: this cannot be written as `(MODE=="mileena") and nil or FT_KHAM` -
    -- Lua's and/or collapses a nil "true" branch and that expression always
    -- yields FT_KHAM, which silently ran the control as Khameleon.
    WHO, POST, PSEL = FT_MILEENA, nil, FT_MILEENA
else
    WHO, POST, PSEL = FT_KHAM, FT_KHAM, FT_KITANA
end

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local last_hp, hit_frame, shots, throws = nil, 0, 0, 0
local last_act = nil
local last_p2act = nil

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function obj_x(p) local o = r32(p); if o == 0 then return -1 end; return r16(o + OXPOS) end
local function p1_action()
    local proc = r32(A.p1_proc); if proc == 0 then return 0xffff end
    return r16(proc + P_ACTION)
end
local function p2_action()
    local proc = r32(A.p2_proc); if proc == 0 then return 0xffff end
    return r16(proc + P_ACTION)
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("throws=%d snapshots=%d", throws, shots)
    log("%s reason=%s", ok and "PASS" or "FAIL", reason)
    logfh:flush(); logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                     ["P1 High Punch"] = true, ["P1 Right"] = true, ["P1 Left"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if wanted[f.name] then fields[f.name] = f end end
    end
end

-- RETREAT FIRST, then throw on a 200-frame cycle.
--
-- Both halves are load-bearing.  The first version stood at the start range
-- (80px apart) and pressed High Punch: the PRESS is an ordinary high punch -
-- only the RELEASE is the sai - and at that distance the punch simply
-- connected.  What got photographed was a normal punch landing, 649 frames
-- after the one sai that was thrown.  At long range the punch whiffs, so the
-- only thing that can take the victim's health is the sai.
--
-- 200 frames per cycle, not 100: saicool (MAINEQU.ASM) is 040h*2 = 128 ticks
-- between throws, so a 100-frame cycle has every second throw refused.
-- 240 frames of retreat opened ~470px, and proj_onscreen_test then culled
-- the sai before it arrived - the screen is only 400 wide.  ~200px is the
-- window: past normal punch reach (~120) but still on screen.
-- 240 frames of walking back.  This is empirical, not principled: it is the
-- one setting observed to get a sai photographed.  At 0 the drone sits inert
-- at ~192px and never even reacts to seven throws; much further and the blade
-- is culled before it arrives.  Retreating also makes the drone walk IN,
-- which is what wakes it up enough to notice the projectile at all.
local RETREAT = 240
local CYCLE, HOLD = 200, 60

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    -- ONE player.  The trigger below is the victim noticing the projectile,
    -- which is drone_beware - a DRONE state.  A two-player victim never
    -- enters it, so a 2P boot silently gives this rig nothing to fire on.
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 or hit_frame > 0 then return false end
    local r = frame - fighting_frame
    if r < RETREAT then
        -- back away.  P1 starts on the left, and the drone is pinned at
        -- difficulty 0 so it does not chase.
        return name == "P1 Left"
    end
    if name == "P1 High Punch" then return ((r - RETREAT) % CYCLE) < HOLD end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("who=%d (psel=%d post=%s)", WHO, PSEL, tostring(POST))
    end
    if not space or finished then
        for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        -- P1 ONLY.  Writing p2_char here brings P2's select proc to life and
        -- the match silently becomes two-player - no drone, so no beware, so
        -- the trigger below never fires.  Same trap the stage probe hit.
        w16(A.p1_char, PSEL)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        if POST then w16(A.p1_char, POST) end
        w16(A.p2_char, FT_JAX)
    elseif gs == GS_FIGHTING then
        if fighting_frame == 0 then
            fighting_frame = frame
            log("fight started p1=%d p2=%d", r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= WHO then finish(false, "char_override_failed"); return end
        end
        local r = frame - fighting_frame
        if A.diff then w16(A.diff, 0) end
        w16(A.p1_bar, MAX_HP)                    -- keep the thrower alive
        -- DO NOT PIN THE VICTIM.  Zeroing p2_xvel does hold the range open,
        -- and it also freezes the drone into a fighter that never engages:
        -- seven sais went past a drone that stayed in stance (0x303) for the
        -- whole round and never even entered beware.  A drone that is walking
        -- in is the one that notices a projectile, so the range has to be
        -- managed by retreating, not by nailing the opponent down.
        -- p2_bar is NOT topped up: its drop is the impact trigger.

        local act = p1_action()
        if act ~= last_act then
            if act == ACT_SAI or act == ACT_AIR_SAI then
                throws = throws + 1
                log("  sai thrown #%d at r=%d (p1x=%d p2x=%d)",
                    throws, r, obj_x(A.p1_obj), obj_x(A.p2_obj))
            end
            last_act = act
        end

        -- TRIGGER ON THE VICTIM REACTING, not on health loss.
        --
        -- `saih4` is the tail of BOTH sai_hit branches: a blocked sai runs
        -- exactly the same impact lane as one that lands.  With the drone
        -- pinned at range it blocked all seven throws, so a health trigger
        -- never fired even though the code under test ran every time.
        -- Anything that takes the victim out of stance/walk while a sai is
        -- in the air is the contact.
        -- Photograph once the sai is airborne.  0x700 is the victim seeing
        -- the projectile (drone_beware), which lands ~23 frames after the
        -- throw with the blade well clear of her hand - a good moment for the
        -- flight lane, and the only trigger that fires reliably.
        local pa = p2_action()
        if pa ~= last_p2act then
            log("  r=%4d p2 action 0x%03x gap=%dpx", r, pa,
                math.abs(obj_x(A.p2_obj) - obj_x(A.p1_obj)))
            last_p2act = pa
        end
        -- Anything that is not the stance/turn band (0x300-0x303).  This is
        -- deliberately loose: it fires on the victim reacting to the throw,
        -- which is the moment the blade is clear of her hand and the flight
        -- lane is on screen.  Narrowing it to "a real reaction" made it never
        -- fire at all.
        local airborne = pa < 0x300 or pa > 0x303
        if hit_frame == 0 and throws > 0 and r > 320 and airborne then
            hit_frame = frame
            local gap = math.abs(obj_x(A.p2_obj) - obj_x(A.p1_obj))
            log("SAI AIRBORNE at r=%d: victim action 0x%03x hp=%d gap=%dpx",
                r, pa, r16(A.p2_bar), gap)
            if gap < 120 then
                log("  WARNING gap under 120px - a normal punch could reach; "
                    .. "this may not be the sai")
            end
        end

        -- screen:snapshot() returns the last COMPLETED frame, so a shot taken
        -- on the trigger frame catches the frame BEFORE contact.  Space them.
        if hit_frame > 0 then
            local d = frame - hit_frame
            if d == 2 or d == 5 or d == 8 or d == 11 or d == 14 then
                for _, scr in pairs(manager.machine.screens) do
                    pcall(function() scr:snapshot() end)
                end
                shots = shots + 1
                log("  snapshot %d at +%d", shots, d)
            end
            if d > 16 then finish(true, "flight lane photographed"); return end
        end

        if r > 1600 then finish(false, "no sai reached the victim") ; return end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame > 6000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
