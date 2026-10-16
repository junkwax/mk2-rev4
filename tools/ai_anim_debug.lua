--[[
    ai_anim_debug.lua — AI/animation health monitor for MK2
    Usage:  mame.exe mk2 -lua tools/ai_anim_debug.lua
       or:  mame.exe mk2 -autoboot_script tools/ai_anim_debug.lua

    Watches both fighters every frame during fights and reports:
      * ANIM-FROZEN : sprite is MOVING but its image pointer hasn't
                      changed for FREEZE_FRAMES frames (the "walking
                      stuck on one frame" bug — a parked/sleeping proc)
      * ACT-STUCK   : p_action unchanged for STUCK_FRAMES frames
                      (crashed/looping move routine, e.g. a retp with
                      no return frame after a drone-dispatched move)
      * NITRO-WATCH : Kitana act_shadk (nitro drive) that never exits
      * act transitions for both players (throttled) + @diff changes

    Everything goes to console and tools/ai_anim_debug.log.
    Addresses from `python sym_resolve.py --dump` for THIS build —
    regenerate them after any rebuild that shifts BSS.
--]]

-- ============================================================
-- Addresses: resolved from MK2.MAP at startup.
--
-- These used to be a hardcoded table snapshotted from one build. Any change
-- to a .bss declaration shifts every symbol after it, and the snapshot had
-- silently drifted by ~0x3d000 bits -- the tool was reading garbage and
-- happily reporting nothing. Read the map instead, and say so loudly if a
-- symbol is missing rather than watching address 0.
-- ============================================================
local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end

local A = {}
for key, name in pairs({
    gstate = "gstate", p1_obj = "p1_obj", p1_proc = "p1_proc",
    p1_char = "p1_char", p1_bar = "p1_bar", p2_obj = "p2_obj",
    p2_proc = "p2_proc", p2_char = "p2_char", p2_bar = "p2_bar",
    curback = "curback", winstat = "winner_status", diff = "diff",
}) do
    A[key] = symbols[name] or 0
    if A[key] == 0 then
        print(string.format("[ai-dbg] MISSING SYMBOL %s - results are worthless", name))
    end
end

-- struct field offsets (bit offsets, added to pointer values as-is)
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0
local PROC_ACTION = 0x1f0

local GS_FIGHTING  = 2
local ACT_SHADK    = 0x0205   -- nitro kick drive (borrowed shadow-kick act)
local ACT_SHADOWSD = 0x0608
local FT_FN1       = 4        -- kitana

-- thresholds (frames @60Hz)
local FREEZE_FRAMES = 60      -- moving w/ frozen image for 1s = report
local STUCK_FRAMES  = 600     -- same act for 10s during a fight = report
local NITRO_FRAMES  = 300     -- nitro act alive for 5s = report
local MOVE_EPS      = 1       -- min |dx| per frame that counts as moving

-- Force the CPU difficulty during fights (nil = leave alone). Attract mode
-- runs at diff 0 where most AI features are dormant -- set 7 to exercise
-- the reaction-delay table, corner escape, desperation, drone specials etc.
local FORCE_DIFF    = 7

-- Y position that no legitimate jump reaches (oypos shrinks going up;
-- floor is ~197, jump peaks ~40). Anything above this is "launched
-- through the background bounds" -- the Portal-stage report.
local Y_LAUNCH_LIMIT = -0x20

local CNAMES = {
    [0]="KungLao",[1]="LiuKang",[2]="Cage",[3]="Baraka",[4]="Kitana",
    [5]="Mileena",[6]="Shang",[7]="Raiden",[8]="SubZero",[9]="Reptile",
    [10]="Scorpion",[11]="Jax",[12]="Kintaro",[13]="ShaoKahn",
    [14]="Smoke",[15]="Noob",[16]="Jade",
}

-- ============================================================
local space, logf
local frame = 0

local function log(msg)
    local s = string.format("[aidbg %7d] %s", frame, msg)
    print(s)
    if logf then logf:write(s, "\n"); logf:flush() end
end

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function i16(v) return (v >= 0x8000) and (v - 0x10000) or v end
local function hx(v) return string.format("0x%08x", v) end

local function snap(label)
    local ok = pcall(function() manager.machine.screens[":screen"]:snapshot() end)
    log(string.format("SNAP (%s) ok=%s", label, tostring(ok)))
end

-- per-player tracker
local function new_tracker(tag, a_obj, a_proc, a_char)
    return {
        tag = tag, a_obj = a_obj, a_proc = a_proc, a_char = a_char,
        last_img = 0, img_age = 0,
        last_act = -1, act_age = 0,
        last_x = 0,
        frozen_reported = false, stuck_reported = false,
        nitro_age = 0, nitro_reported = false,
        launch_reported = false,
        act_log_budget = 0,
        act_hist = {},           -- last few acts, for launch forensics
    }
end

local trk = {
    new_tracker("P1", A.p1_obj, A.p1_proc, A.p1_char),
    new_tracker("P2", A.p2_obj, A.p2_proc, A.p2_char),
}

local last_diff = -1

local function tick_player(t, fighting)
    local obj  = r32(t.a_obj)
    local proc = r32(t.a_proc)
    if obj == 0 or proc == 0 then
        t.img_age, t.act_age, t.nitro_age = 0, 0, 0
        return
    end

    local x    = i16(r16(obj + OBJ_OXPOS))
    local y    = i16(r16(obj + OBJ_OYPOS))
    -- oimg points at a fixed per-player image header; the frame identity
    -- is the SAG behind it (same dereference kitana_nitro_test.lua uses)
    local hdr  = r32(obj + OBJ_OIMG)
    local img  = (hdr ~= 0) and r32(hdr) or 0
    local act  = r16(proc + PROC_ACTION)
    local char = r16(t.a_char)

    -- attract cycles free the fighters; stale pointers then read garbage
    -- (act 3f3f, x=-1 etc). Skip the tick when the data isn't plausible.
    if char > 16 or x < -400 or x > 1200 then
        t.img_age, t.act_age, t.nitro_age = 0, 0, 0
        return
    end
    local name = CNAMES[char] or ("char" .. tostring(char))

    -- act transition log (throttled to 20/sec so mash doesn't spam)
    if act ~= t.last_act then
        if t.act_log_budget < 20 then
            log(string.format("%s %-8s act %04x -> %04x  x=%d y=%d img=%s",
                t.tag, name, (t.last_act < 0) and 0 or t.last_act, act, x, y, hx(img)))
            t.act_log_budget = t.act_log_budget + 1
        end
        table.insert(t.act_hist, string.format("%04x", act))
        if #t.act_hist > 8 then table.remove(t.act_hist, 1) end
        t.last_act = act
        t.act_age  = 0
        t.stuck_reported = false
    else
        t.act_age = t.act_age + 1
    end

    -- launched-through-the-sky detector (Portal-stage report): no legal
    -- jump goes this high; log who, what act, and the recent act history.
    -- Skip winstat != 0 -- fatality launches (slime dunk, spike rise) go
    -- way up on purpose and are not the bug.
    if fighting and y < Y_LAUNCH_LIMIT and r16(A.winstat) == 0 then
        if not t.launch_reported then
            log(string.format(
                "*** SKY-LAUNCH: %s %s y=%d x=%d act=%04x stage=%d winstat=%d img=%s hist=[%s] diff=%d ***",
                t.tag, name, y, x, act, r16(A.curback), r16(A.winstat), hx(img),
                table.concat(t.act_hist, " "), r16(A.diff)))
            snap("sky-launch-" .. t.tag)
            t.launch_reported = true
        end
    elseif y > 0 then
        t.launch_reported = false
    end

    -- image-pointer age vs movement
    local moving = math.abs(x - t.last_x) >= MOVE_EPS
    if img ~= t.last_img then
        t.last_img = img
        t.img_age = 0
        t.frozen_reported = false
    elseif moving then
        t.img_age = t.img_age + 1
    else
        t.img_age = 0          -- standing still on one frame is normal
    end
    t.last_x = x

    if fighting then
        if t.img_age >= FREEZE_FRAMES and not t.frozen_reported then
            log(string.format(
                "*** ANIM-FROZEN: %s %s sliding with img stuck %s for %d frames (act=%04x diff=%d) ***",
                t.tag, name, hx(img), t.img_age, act, r16(A.diff)))
            snap("anim-frozen-" .. t.tag)
            t.frozen_reported = true
        end
        if t.act_age >= STUCK_FRAMES and not t.stuck_reported then
            log(string.format(
                "*** ACT-STUCK: %s %s act=%04x unchanged for %d frames (img=%s diff=%d) ***",
                t.tag, name, act, t.act_age, hx(img), r16(A.diff)))
            snap("act-stuck-" .. t.tag)
            t.stuck_reported = true
        end
        -- nitro-kick specific watch
        if char == FT_FN1 and (act == ACT_SHADK or act == ACT_SHADOWSD) then
            t.nitro_age = t.nitro_age + 1
            if t.nitro_age >= NITRO_FRAMES and not t.nitro_reported then
                log(string.format(
                    "*** NITRO-WATCH: %s Kitana stuck in %04x for %d frames (img=%s) ***",
                    t.tag, act, t.nitro_age, hx(img)))
                snap("nitro-stuck-" .. t.tag)
                t.nitro_reported = true
            end
        else
            t.nitro_age, t.nitro_reported = 0, false
        end
    else
        t.img_age, t.act_age, t.nitro_age = 0, 0, 0
    end
end

-- ============================================================
-- ROM-warning screen dismissal: MAME's checksum warning accepts any
-- mapped input; pulse a P1 field until the game state reads sane.
-- ============================================================
local boot_field
local boot_done = false

local function boot_nudge(gs)
    if boot_done then return end
    if gs >= 1 and gs <= 0x0f then
        boot_done = true
        log("boot complete (gstate sane) -- stopping warning-dismiss pulses")
        if boot_field then pcall(function() boot_field:set_value(0) end) end
        return
    end
    if not boot_field then
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, field in pairs(port.fields) do
                if field.name == "P1 High Kick" or field.name == "1 Player Start"
                   or field.name == "P1 Start" then
                    boot_field = field
                end
            end
        end
    end
    if boot_field then
        local phase = frame % 30
        if phase == 0 then
            pcall(function() boot_field:set_value(1) end)
        elseif phase == 5 then
            pcall(function() boot_field:set_value(0) end)
        end
    end
end

local function on_frame()
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]
        if not space then return end
        log("=== ai_anim_debug attached ===")
    end
    frame = frame + 1

    -- attract-mode demo fights run under gs_amode (1), not gs_fighting (2);
    -- treat both as "a fight is happening" so the detectors stay armed
    local gs = r16(A.gstate)
    boot_nudge(gs)
    local fighting = (gs == GS_FIGHTING) or (gs == 1)

    if FORCE_DIFF and fighting and r16(A.diff) ~= FORCE_DIFF then
        space:write_u16(A.diff, FORCE_DIFF)
        log(string.format("forced @diff -> %d", FORCE_DIFF))
    end

    local d = r16(A.diff)
    if d ~= last_diff then
        log(string.format("@diff %d -> %d", last_diff, d))
        last_diff = d
    end

    if frame % 60 == 0 then
        trk[1].act_log_budget = 0
        trk[2].act_log_budget = 0
    end

    tick_player(trk[1], fighting)
    tick_player(trk[2], fighting)
end

logf = io.open("C:\\Users\\you\\Workplace\\mk2-main\\tools\\ai_anim_debug.log", "w")
log("=== ai_anim_debug.lua start ===")
emu.register_frame_done(on_frame)
