-- jc_headhole_clean_test.lua
-- Verification harness for the rebuilt (2026-07-13) Johnny Cage headhole
-- fatality.  Requires the test ROM (test_mode=1, P1=Cage) installed.
--
-- Flow: boot test fight -> drain P2 to 1 HP -> teleport close -> HP to KO
-- -> FINISH HIM -> HP triggers do_jc_headhole (jc_headhole_hp_test hook)
-- -> watch f_death, victim frame progression (multipart SAG), position,
--    completion and victory; screenshots at keyframes.
--
-- Run:  cd C:\MAME; .\mame.exe mk2 -lua ..\Users\...\jc_headhole_clean_test.lua
-- Result line at the end:  HH_RESULT: PASS/FAIL <reason>

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/tools/jc_headhole_clean_test.log"

-- TMS34010 BIT addresses.  This MAME's TMS34010 Lua program space takes
-- BIT addresses directly (verified: reset vector reads back at
-- 0xffffffc0).  Everything is resolved from src/mk2.map at startup so the
-- harness survives rebuilds; the literals below are fallbacks only.
local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/mk2.map"

local A = {
    gstate        = 0x0112a7d0,
    p1_obj        = 0x0112a820,
    p1_proc       = 0x0112a860,
    p1_bar        = 0x0112a8f0,
    p1_matchw     = 0x0112a910,
    p2_obj        = 0x0112b3f0,
    p2_proc       = 0x0112b430,
    p2_bar        = 0x0112b4c0,
    f_death       = 0x0112bfc0,
    winner_status = 0x0112c110,
    dizzy         = 0xffa284f0,   -- victim finish-him wakeup loop (code)
    dizzy_dude    = 0xffa28130,   -- victim finish-him entry routine (code)
    active        = 0,            -- head of the active process list
    jc_headhole_spill_proc = 0,
    jchsp_loop    = 0,
    jchsp_hold    = 0,
    jchsp_none    = 0,
    worldtlx      = 0,             -- world-space X of screen's top-left
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
        print(string.format("[hh] mk2.map: resolved %d symbols", found))
        for name in pairs(wanted) do
            print(string.format("[hh] WARNING: %s not in map, using fallback", name))
        end
    else
        print("[hh] WARNING: mk2.map not readable, using fallback addresses")
    end
end

-- Process struct bit offsets (MKSTRUCT.ASM).  PLINK=0 (active-list next
-- ptr), PROCID=0x20, PA10=0x80, PA9=0xa0, PA8=0xc0, PWAKE=0xe0.
local P = { plink = 0, procid = 0x20, wake = 0x0e0, pa8 = 0xc0, pa9 = 0xa0,
            pa10 = 0x80, action = 0x1f0, flags = 0x210 }
local ACT_STANCE  = 0x0303
local ACT_STUNNED = 0x0400
local PM_BLOCKING = 0x0004 | 0x0008 | 0x0010   -- reacting|sitduck|special
local PID_HEAD    = 0x0202

-- Object block field bit offsets (DISPEQU.ASM)
local OBJ = { oxval = 0x80, oxpos = 0x90, oypos = 0xb0, ozval = 0xc0,
              oflags = 0xf0, osag = 0x100, opal = 0x140, oflags2 = 0x160,
              oimg = 0x1a0, ochar = 0x1f0 }

local frame = 0
local phase = "boot"
local phase_frame = 0
local fatality_frame = nil
local complete_frame = nil
local hp_hold = 0
local hp_cooldown = 0
local sags = {}
local sag_order = {}
local last_sag = nil
local p2y_at_contact, p2y_final = nil, nil
local snaps_done = {}
local last_gstate, last_ws, last_fd = -1, -1, -1
local round_start = nil
local round_ended = false
local fight_count = 0

local logfh = io.open(LOG_PATH, "w")
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local cpu, space, fields

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
    return rl(img_bits)        -- multipart ram entry #1 = first part SAG
end

local function set_p1_x(x)
    local b = obj_base(A.p1_obj)
    if not b then return end
    ww(b + OBJ.oxpos, x & 0xffff)
    wl(b + OBJ.oxval, (x << 16) & 0xffffffff)
end

local function cache_fields()
    fields = {}
    local wanted = { ["P1 High Punch"] = true, ["P1 Right"] = true, ["P1 Left"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if wanted[f.name] then fields[f.name] = f end
        end
    end
    for name in pairs(wanted) do
        log(string.format("[hh] input %-14s %s", name, fields[name] and "ok" or "MISSING"))
    end
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
        log(string.format("[hh] SNAP frame=%d label=%s", frame, label))
    end
end

local function hex(v) return v and string.format("0x%08x", v) or "nil" end

local function dump_spill_diag()
    if A.active == 0 then
        log("[hh] DIAG: 'active' not resolved from mk2.map, cannot walk process list")
        return
    end
    local p = rl(A.active)
    local n = 0
    local found = 0
    while p ~= 0 and p ~= 0xffffffff and n < 64 do
        n = n + 1
        local procid = rw(p + P.procid)
        if procid == PID_HEAD then
            local wake = rl(p + P.wake)
            local a8 = rl(p + P.pa8)
            local a10 = rl(p + P.pa10)
            found = found + 1
            log(string.format(
                "[hh] DIAG pid_head proc=%s wake=%s pa8(spill obj)=%s pa10(anchor)=%s",
                hex(p), hex(wake), hex(a8), hex(a10)))
            local wtlx = A.worldtlx ~= 0 and i16(rw(A.worldtlx + 0x10)) or nil
            if a8 ~= 0 and a8 ~= 0xffffffff then
                local sx, sy = i16(rw(a8 + OBJ.oxpos)), i16(rw(a8 + OBJ.oypos))
                log(string.format(
                    "[hh] DIAG   spill obj: world=(%d,%d) screen_x=%s ozval=%s oflags=0x%04x oflags2=%s opal=0x%04x osag=%s oimg=%s",
                    sx, sy, tostring(wtlx and (sx - wtlx) or "?"),
                    hex(rl(a8 + OBJ.ozval)), rw(a8 + OBJ.oflags) & 0xffff,
                    hex(rl(a8 + OBJ.oflags2)), rw(a8 + OBJ.opal) & 0xffff,
                    hex(rl(a8 + OBJ.osag)), hex(rl(a8 + OBJ.oimg))))
            end
            if a10 ~= 0 and a10 ~= 0xffffffff then
                local ax, ay = i16(rw(a10 + OBJ.oxpos)), i16(rw(a10 + OBJ.oypos))
                log(string.format(
                    "[hh] DIAG   anchor obj: world=(%d,%d) screen_x=%s",
                    ax, ay, tostring(wtlx and (ax - wtlx) or "?")))
            end
        end
        p = rl(p + P.plink)
    end
    log(string.format("[hh] DIAG: walked %d active procs, %d with pid_head (0x%04x)",
        n, found, PID_HEAD))
end

local function press_hp()
    hp_hold = 5
    hp_cooldown = 40
end

local function finish(result, reason)
    log(string.format("[hh] frames=%d fatality=%s complete=%s distinct_sags=%d",
        frame, tostring(fatality_frame), tostring(complete_frame), #sag_order))
    for i, s in ipairs(sag_order) do
        log(string.format("[hh]   fall frame %d: sag=0x%08x at rel %d", i, s.sag, s.rel))
    end
    log(string.format("HH_RESULT: %s %s", result, reason))
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("[hh] harness up; waiting for test fight")
    end
    if not space then return end

    if frame % 300 == 0 then
        local p1b = rl(A.p1_obj)
        log(string.format("[hh] beat frame=%d phase=%s gs=%d ws=%d fd=0x%04x p1objbits=0x%08x p2bar=%d",
            frame, phase, rw(A.gstate), rw(A.winner_status),
            rw(A.f_death) & 0xffff, p1b, rw(A.p2_bar)))
    end

    -- input latch
    if fields then
        if hp_hold > 0 then
            hp_hold = hp_hold - 1
            fields["P1 High Punch"]:set_value(1)
        else
            fields["P1 High Punch"]:clear_value()
        end
    end
    if hp_cooldown > 0 then hp_cooldown = hp_cooldown - 1 end

    local gs = rw(A.gstate)
    local ws = rw(A.winner_status)
    local fd = rw(A.f_death)
    if gs ~= last_gstate then
        log(string.format("[hh] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == 2 then
            round_start = frame; round_ended = false
            fight_count = fight_count + 1
            log(string.format("[hh] frame=%d fight #%d begins", frame, fight_count))
        end
        last_gstate = gs
    end
    if ws ~= last_ws then log(string.format("[hh] frame=%d winner_status %d -> %d", frame, last_ws, ws)); last_ws = ws end
    if fd ~= last_fd then log(string.format("[hh] frame=%d f_death 0x%04x -> 0x%04x", frame, last_fd & 0xffff, fd & 0xffff)); last_fd = fd end

    local p1x = obj_xy(A.p1_obj)
    local p2x, p2y = obj_xy(A.p2_obj)

    if frame == 900 then snap("99_boot_probe") end

    if phase == "boot" then
        if p1x and p2x and gs ~= 0 and frame > 240 then
            phase = "fight"; phase_frame = frame
            log(string.format("[hh] frame=%d fight detected p1x=%d p2x=%d", frame, p1x, p2x))
        end
    elseif phase == "fight" then
        if gs == 2 and round_start and frame - round_start >= 90 then
            -- Put the victim's process into the game's own finish-him entry
            -- (dizzy_dude parks it in the dizzy wakeup loop, which is the
            -- state the fatality transfer gate requires) and assert Finish
            -- Him.  The round clock keeps running; the bars stay untouched
            -- so the round does not end underneath the fatality.
            local vproc = rl(A.p2_proc)
            if vproc ~= 0 then
                wl(vproc + P.wake, A.dizzy_dude)
                phase = "force"; phase_frame = frame
                log(string.format("[hh] frame=%d victim pwake -> dizzy_dude; begin FINISH HIM force", frame))
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
            -- keep the attacker actionable: no leftover blocking flags
            local fl = rw(aproc + P.flags)
            if (fl & PM_BLOCKING) ~= 0 then ww(aproc + P.flags, fl & ~PM_BLOCKING) end
        end

        if (frame - phase_frame) % 120 == 0 then
            log(string.format("[hh] force frame=%d vwake=0x%08x vact=0x%04x dizzy=%s dist=%s",
                frame, vwake, vact, tostring(victim_dizzy),
                (p1x and p2x) and tostring(math.abs(p2x - p1x)) or "?"))
        end

        if fd == 2 then
            phase = "fatality"; phase_frame = frame; fatality_frame = frame
            p2y_at_contact = p2y
            local p1b, p2b = obj_base(A.p1_obj), obj_base(A.p2_obj)
            log(string.format("[hh] frame=%d fatality started (f_death=2) p1char=%d p2char=%d p2=(%d,%d)",
                frame, p1b and rw(p1b + OBJ.ochar) or -1, p2b and rw(p2b + OBJ.ochar) or -1,
                p2x or -1, p2y or -1))
            snap("00_fatality_start")
        elseif victim_dizzy and p1x and p2x and hp_cooldown == 0 then
            local dist = math.abs(p2x - p1x)
            if dist > 0x48 then
                -- approach from the victim's far side to exercise the
                -- victim re-face and the mirrored attacker pass
                set_p1_x(p2x + 0x40)
                log(string.format("[hh] frame=%d close in for fatality (dist was %d)", frame, dist))
            end
            press_hp()
            log(string.format("[hh] frame=%d fatality HP press", frame))
        end
        if frame - phase_frame > 1800 then finish("FAIL", "fatality hook never fired") end
    elseif phase == "fatality" then
        local rel = frame - fatality_frame
        local sag = obj_sag(A.p2_obj)
        if sag and sag ~= last_sag then
            last_sag = sag
            if not sags[sag] then
                sags[sag] = true
                sag_order[#sag_order + 1] = { sag = sag, rel = rel }
            end
            log(string.format("[hh] frame=%d rel=%d p2 sag -> 0x%08x p2=(%d,%d)",
                frame, rel, sag, p2x or -1, p2y or -1))
        end
        -- authored 12 FPS ticks run x5 at 60 Hz: contact at rel 40, stand
        -- until ~90, knees ~100, wobble ~110-170, ground ~185, pass end 220
        if rel == 20 then snap("01_windup") end
        if rel == 45 then snap("02_contact") end
        if rel == 70 then snap("03_hole_standing") end
        if rel == 100 then snap("04_knees") end
        if rel == 140 then snap("05_wobble") end
        -- KHEART: contact is rel~40, then its own 26 authored ticks (x5)
        -- run to rel~170 (9+1+1+1+1+1+9+1+1+1=26 -> 130 game ticks)
        if rel == 50 then snap("07_kheart_start") end
        if rel == 90 then dump_spill_diag(); snap("08_kheart_mid") end
        if rel == 170 then dump_spill_diag(); snap("09_kheart_munch") end
        if rel == 195 then snap("06_ground") end
        if rel == 210 then dump_spill_diag(); snap("06a_spill_diag") end
        if rel == 230 then snap("06b_spill") end
        if rel == 231 then dump_spill_diag() end
        if fd == 0xffff and not complete_frame then
            complete_frame = frame
            log(string.format("[hh] frame=%d death_blow_complete (rel=%d)", frame, rel))
        end
        if complete_frame and frame - complete_frame == 120 then
            snap("07_victory_hold")
            -- Judge: the victim's multipart frame must have advanced through
            -- the composite fall (stand, knees, wobble alternation, ground).
            -- The object origin does not move during a decap-style fall; the
            -- art falls via the per-part anipoints, so frame progression is
            -- the correct signal, not oypos.
            local n = #sag_order
            if n < 7 then
                finish("FAIL", string.format("only %d distinct victim frames", n))
            else
                finish("PASS", string.format("fall frames=%d complete@rel=%d",
                    n, complete_frame - fatality_frame))
            end
        end
        if rel > 1500 then finish("FAIL", "fatality never completed") end
    end

    if frame > 12000 then finish("FAIL", "global timeout") end
end

emu.register_frame_done(function()
    local ok, err = pcall(on_frame)
    if not ok then
        log("[hh] LUA ERROR: " .. tostring(err))
        if logfh then logfh:flush() end
    end
end)
