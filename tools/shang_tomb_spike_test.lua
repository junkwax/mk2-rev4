-- shang_tomb_spike_test.lua
-- Verification harness for Shang Tsung's Kombat Tomb spike fatality
-- (do_up_the_spike -> st_tomb_backflip), fixed to hand the victim directly
-- to r_spike_rise instead of relying on strike_check_a0 collision detection
-- against the stationary backflip pose.
--
-- Requires test ROM: test_mode=1, P1=ft_st (6), test_stage=1 (Kombat Tomb).
--
-- The real joystick combo (Down,Down,Up,Down + LK) is UI-timing-sensitive
-- and not what's under test here, so this harness forces the same
-- preconditions fatality_xfer checks (winner_status=3, f_death=0, close
-- range, victim dizzy, not airborne) and then forces P1's own process wake
-- straight to do_up_the_spike - the same forcing technique already used
-- below to park the victim in the dizzy wakeup loop.
--
-- Result line at the end: ST_RESULT: PASS/FAIL <reason>

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/tools/shang_tomb_spike_test.log"
local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/mk2.map"

local A = {
    gstate        = 0x0112a7d0,
    p1_obj        = 0x0112a820,
    p1_proc       = 0x0112a860,
    p1_bar        = 0x0112a8f0,
    p2_obj        = 0x0112b3f0,
    p2_proc       = 0x0112b430,
    p2_bar        = 0x0112b4c0,
    f_death       = 0x0112bfc0,
    winner_status = 0x0112c110,
    dizzy         = 0xffa284f0,
    dizzy_dude    = 0xffa28130,
    do_up_the_spike = 0,
    do_st_flip_decap = 0,
    reaction_exit = 0,
    diag_marker = 0,
    active        = 0,
}

do
    local wanted = {}
    for name in pairs(A) do wanted[name] = true end
    local fh = io.open(MAP_PATH, "r")
    if fh then
        local found = 0
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x+)%s+([%w_]+)") do
                if wanted[name] then
                    A[name] = tonumber(addr, 16)
                    wanted[name] = nil
                    found = found + 1
                end
            end
        end
        fh:close()
        print(string.format("[st] mk2.map: resolved %d symbols", found))
        for name in pairs(wanted) do
            print(string.format("[st] WARNING: %s not in map, using fallback", name))
        end
    else
        print("[st] WARNING: mk2.map not readable, using fallback addresses")
    end
end

local P = { plink = 0, procid = 0x20, wake = 0x0e0, pa8 = 0xc0, pa9 = 0xa0,
            pa10 = 0x80, action = 0x1f0, flags = 0x210, store2 = 0x250 }
local ACT_STUNNED = 0x0400
local PM_BLOCKING = 0x0004 | 0x0008 | 0x0010

local OBJ = { oxval = 0x80, oxpos = 0x90, oypos = 0xb0, ozval = 0xc0,
              oflags = 0xf0, osag = 0x100, opal = 0x140, oflags2 = 0x160,
              oimg = 0x1a0, ochar = 0x1f0 }

local frame = 0
local phase = "boot"
local phase_frame = 0
local fatality_frame = nil
local complete_frame = nil
local last_activity_frame = 0
local last_p1_sag, last_p2_sag = nil, nil
local snaps_done = {}
local last_gstate, last_ws, last_fd = -1, -1, -1
local round_start = nil
local fight_count = 0

local logfh = io.open(LOG_PATH, "w")
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local cpu, space

local function rw(a) return space:read_u16(a) end
local function rl(a) return space:read_u32(a) end
local function ww(a, v) space:write_u16(a, v & 0xffff) end
local function wl(a, v) space:write_u32(a, v & 0xffffffff) end
local function i16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function obj_base(ptr_addr)
    local bits = rl(ptr_addr)
    if bits == 0 or bits == 0xffffffff then return nil end
    return bits
end

local function obj_xy(ptr_addr)
    local b = obj_base(ptr_addr)
    if not b then return nil, nil end
    return i16(rw(b + OBJ.oxpos)), i16(rw(b + OBJ.oypos))
end

local function obj_sag(ptr_addr)
    local b = obj_base(ptr_addr)
    if not b then return nil end
    local img_bits = rl(b + OBJ.oimg)
    if img_bits == 0 then return nil end
    return rl(img_bits)
end

local function set_p1_x(x)
    local b = obj_base(A.p1_obj)
    if not b then return end
    ww(b + OBJ.oxpos, x & 0xffff)
    wl(b + OBJ.oxval, (x << 16) & 0xffffffff)
end

-- Real fatality_xfer (MOVES.ASM) hands the attacker off to its fatality
-- routine via calla fastxfer, then pushes reaction_exit onto the now-reset
-- process stack so a later retp lands somewhere valid instead of popping
-- stale garbage.  A bare pwake overwrite skips both steps and leaves the
-- process running against whatever was left on its stack from normal
-- fight state - replicate the real sequence so a hang here reflects the
-- fatality code itself, not a test-harness shortcut.
local PS = { ptime = 0x30, psptr = 0x40, pwake = 0xe0, prcsiz = 0x6f0 }

local function force_fatality_xfer(proc_addr, target_wake, return_addr)
    ww(proc_addr + PS.ptime, 1)
    local top = proc_addr + (PS.prcsiz - PS.psptr)
    wl(proc_addr + PS.psptr, top)
    wl(proc_addr + PS.pwake, target_wake)
    local sp = rl(proc_addr + PS.psptr) - 32
    wl(sp, return_addr)
    wl(proc_addr + PS.psptr, sp)
end

local function snap(label)
    if snaps_done[label] then return end
    snaps_done[label] = true
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not s then
        ok, s = pcall(function() return manager.machine.screens:at(1) end)
    end
    if s then
        pcall(function() s:snapshot() end)
        log(string.format("[st] SNAP frame=%d label=%s", frame, label))
    end
end

local function finish(result, reason)
    log(string.format("[st] frames=%d fatality=%s complete=%s",
        frame, tostring(fatality_frame), tostring(complete_frame)))
    log(string.format("ST_RESULT: %s %s", result, reason))
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        log("[st] harness up; waiting for test fight")
        if A.do_up_the_spike == 0 then
            finish("FAIL", "do_up_the_spike not resolved from mk2.map")
            return
        end
    end
    if not space then return end

    if frame % 300 == 0 then
        log(string.format("[st] beat frame=%d phase=%s gs=%d ws=%d fd=0x%04x p2bar=%d",
            frame, phase, rw(A.gstate), rw(A.winner_status), rw(A.f_death) & 0xffff, rw(A.p2_bar)))
    end

    local gs = rw(A.gstate)
    local ws = rw(A.winner_status)
    local fd = rw(A.f_death)
    if gs ~= last_gstate then
        log(string.format("[st] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == 2 then
            round_start = frame
            fight_count = fight_count + 1
            log(string.format("[st] frame=%d fight #%d begins", frame, fight_count))
        end
        last_gstate = gs
    end
    if ws ~= last_ws then log(string.format("[st] frame=%d winner_status %d -> %d", frame, last_ws, ws)); last_ws = ws end
    if fd ~= last_fd then log(string.format("[st] frame=%d f_death 0x%04x -> 0x%04x", frame, last_fd & 0xffff, fd & 0xffff)); last_fd = fd end

    local p1x = obj_xy(A.p1_obj)
    local p2x, p2y = obj_xy(A.p2_obj)

    if frame == 900 then snap("00_boot_probe") end

    if phase == "boot" then
        if p1x and p2x and gs ~= 0 and frame > 240 then
            phase = "fight"; phase_frame = frame
            log(string.format("[st] frame=%d fight detected p1x=%d p2x=%d", frame, p1x, p2x))
        end
    elseif phase == "fight" then
        if gs == 2 and round_start and frame - round_start >= 90 then
            local vproc = rl(A.p2_proc)
            if vproc ~= 0 then
                wl(vproc + P.wake, A.dizzy_dude)
                phase = "force"; phase_frame = frame
                log(string.format("[st] frame=%d victim pwake -> dizzy_dude; begin FINISH HIM force", frame))
            end
        end
        if frame - phase_frame > 2400 then finish("FAIL", "fight never stabilized") end
    elseif phase == "force" then
        ww(A.winner_status, 3)

        local vproc = rl(A.p2_proc)
        local aproc = rl(A.p1_proc)
        local vwake = vproc ~= 0 and rl(vproc + P.wake) or 0
        local vact = vproc ~= 0 and rw(vproc + P.action) or 0
        local victim_dizzy = vwake >= A.dizzy and vwake < A.dizzy + 0x200
                             and vact == ACT_STUNNED
        if aproc ~= 0 then
            local fl = rw(aproc + P.flags)
            if (fl & PM_BLOCKING) ~= 0 then ww(aproc + P.flags, fl & ~PM_BLOCKING) end
        end

        if (frame - phase_frame) % 120 == 0 then
            log(string.format("[st] force frame=%d vwake=0x%08x vact=0x%04x dizzy=%s dist=%s",
                frame, vwake, vact, tostring(victim_dizzy),
                (p1x and p2x) and tostring(math.abs(p2x - p1x)) or "?"))
        end

        if victim_dizzy and p1x and p2x and fd == 0 then
            local dist = math.abs(p2x - p1x)
            if dist > 0x40 then
                set_p1_x(p2x + 0x30)
                log(string.format("[st] frame=%d close in for fatality (dist was %d)", frame, dist))
            else
                -- Conditions match what fatality_xfer checks (winner_status=3,
                -- f_death=0, close range, victim dizzy/not airborne): force
                -- the attacker's own process straight into do_up_the_spike
                -- via the same fastxfer + reaction_exit push fatality_xfer
                -- itself does, bypassing only the joystick-combo input layer.
                if aproc ~= 0 then
                    force_fatality_xfer(aproc, A.do_up_the_spike, A.reaction_exit)
                    phase = "fatality"; phase_frame = frame; fatality_frame = frame
                    last_activity_frame = frame
                    log(string.format("[st] frame=%d forced attacker -> do_up_the_spike", frame))
                    snap("01_fatality_start")
                end
            end
        end
        if frame - phase_frame > 1800 then finish("FAIL", "preconditions never stabilized") end
    elseif phase == "fatality" then
        local rel = frame - fatality_frame
        local p1sag = obj_sag(A.p1_obj)
        local p2sag = obj_sag(A.p2_obj)
        if p1sag and p1sag ~= last_p1_sag then
            last_p1_sag = p1sag
            last_activity_frame = frame
            log(string.format("[st] frame=%d rel=%d p1(attacker) sag -> 0x%08x", frame, rel, p1sag))
        end
        if p2sag and p2sag ~= last_p2_sag then
            last_p2_sag = p2sag
            last_activity_frame = frame
            log(string.format("[st] frame=%d rel=%d p2(victim) sag -> 0x%08x p2=(%d,%d)",
                frame, rel, p2sag, p2x or -1, p2y or -1))
        end

        if rel == 10 then snap("02_windup") end
        if rel == 40 then snap("03_contact") end
        if rel == 70 then snap("04_post_contact") end

        if fd == 0xffff and not complete_frame then
            complete_frame = frame
            last_activity_frame = frame
            log(string.format("[st] frame=%d death_blow_complete (rel=%d)", frame, rel))
        end
        if complete_frame and frame - complete_frame == 90 then
            snap("05_victory_hold")
            finish("PASS", string.format("completed@rel=%d p1_sags=%s p2_sags=%s",
                complete_frame - fatality_frame, tostring(last_p1_sag ~= nil), tostring(last_p2_sag ~= nil)))
        end

        -- Hang detector: the reported bug is a freeze, not a crash - if
        -- neither participant's sag nor f_death changes for a long stretch
        -- after the fatality started, the game is stuck exactly as
        -- described, not merely slow.
        if frame - last_activity_frame > 600 then
            snap("hang_snapshot")
            local aproc = rl(A.p1_proc)
            local vproc = rl(A.p2_proc)
            if aproc ~= 0 then
                log(string.format("[st] DIAG attacker proc=0x%08x wake=0x%08x action=0x%04x flags=0x%04x",
                    aproc, rl(aproc + P.wake), rw(aproc + P.action), rw(aproc + P.flags)))
            end
            if A.diag_marker ~= 0 then
                log(string.format("[st] DIAG diag_marker=%d", rw(A.diag_marker)))
            end
            if vproc ~= 0 then
                log(string.format("[st] DIAG victim proc=0x%08x wake=0x%08x action=0x%04x flags=0x%04x",
                    vproc, rl(vproc + P.wake), rw(vproc + P.action), rw(vproc + P.flags)))
            end
            local p1b, p2b = obj_base(A.p1_obj), obj_base(A.p2_obj)
            if p1b then
                log(string.format("[st] DIAG attacker obj oshape=0x%08x oflags=0x%04x ozval=0x%08x",
                    rl(p1b + 0x1d0), rw(p1b + OBJ.oflags) & 0xffff, rl(p1b + OBJ.ozval)))
            end
            if p2b then
                log(string.format("[st] DIAG victim obj oshape=0x%08x oflags=0x%04x ozval=0x%08x",
                    rl(p2b + 0x1d0), rw(p2b + OBJ.oflags) & 0xffff, rl(p2b + OBJ.ozval)))
            end
            finish("FAIL", string.format("no activity for 600 frames (hang) at rel=%d", rel))
        end
        if rel > 1200 then finish("FAIL", "fatality never completed") end
    end

    if frame > 12000 then finish("FAIL", "global timeout") end
end

emu.register_frame_done(function()
    local ok, err = pcall(on_frame)
    if not ok then
        log("[st] LUA ERROR: " .. tostring(err))
        if logfh then logfh:flush() end
    end
end)
