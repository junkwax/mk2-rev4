-- kahn_fatality_audio_probe.lua
--
-- Sound-call TRACER for the Shao Kahn hammer fatality ending.
--
-- Every complaint about this ending so far ("clipping", "spotty", "part 2
-- didn't fire") has been diagnosed by ear and answered with a timing guess.
-- This taps the hardware sound latch instead, so the log says exactly which
-- DCS track was sent, on which channel, at what millisecond - and, crucially,
-- which ones were NEVER SENT because triple_sound refused them.
--
-- It drives nothing itself: it installs the tap and then hands over to
-- kahn_boss_moves_test.lua, which already knows how to boot into Liu Kang vs
-- Shao Kahn, pin round 3, seed the victim at 0x20 HP and ask for the hammer.
--
-- Decoding: send_code_a3 (MKSOUND.ASM) writes a DCS track as two consecutive
-- 16-bit hits on @sound (SYSEQU.ASM `sound` = bit address 01d01030h), each
-- byte OR'd with 0ff00h.  triple_sound sends the table's channel-1 track for
-- channel 1, +1 for channel 2, +2 for channel 3 (tsnd1/tsnd2/tsnd3), so the
-- track number alone tells us which channel arbitration picked.

local ROOT = os.getenv("KAHN_TEST_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local SND_PORT = 0x01d01030          -- bit address of the sound latch
local TAP_LO   = 0x01d00000
local TAP_HI   = 0x01d01fff

-- Track name lookup, parsed straight out of MKSOUND.ASM so it never goes
-- stale.  Both triple_sndtab and triple_sndtab2 use the same row shape:
--      .word  sp_bossv1|121,03b4h   ; 16 = "fatality"
local names = {}
local durs  = {}
local pris  = {}

local function learn(base, pri, dur, label)
    for ch = 0, 2 do
        local code = base + ch
        if not names[code] then
            names[code] = string.format("%s [ch%d]", label, ch + 1)
            if pri then pris[code] = pri end
            if dur then durs[code] = dur end
        end
    end
end

do
    local fh = io.open(ROOT .. "/src/MKSOUND.ASM", "r")
    if fh then
        local table_name = "?"
        for line in fh:lines() do
            if line:match("^triple_sndtab2") then table_name = "t2"
            elseif line:match("^triple_sndtab") then table_name = "t1" end
            local head, code, comment =
                line:match("^%s*%.word%s+([%w_|]+),0?(%x+)h%s*;%s*(.-)%s*$")
            if head and code then
                local pri, dur = head:match("^(sp_%w+)|(%d+)$")
                learn(tonumber(code, 16), pri, tonumber(dur),
                      string.format("%s %s", table_name, comment))
            end
        end
        fh:close()
    end
end

-- Raw send_code_a3 callers (tunes and stings) do not come from those tables.
local raw = {
    [0x0034] = "STING death-blow (make_db_tone)",
    [0x0035] = "TUNE death-blow-over (death_blow_complete)",
    [0x003f] = "TUNE babality/friendship over",
    [0x0037] = "TUNE ENDGUY (no-op'd in stlaugh_patch)",
}
for code, label in pairs(raw) do names[code] = label end

local function track_name(code)
    return names[code] or string.format("(unknown $%04x)", code)
end

-- ---------------------------------------------------------------- tracing

local space, tap, d4tap
local pending_hi = nil
local last_write_frame = -1
local probe_frame = 0

local function now_ms()
    local ok, t = pcall(function() return manager.machine.time:as_double() end)
    if ok and t then return t * 1000.0 end
    return probe_frame * 16.667
end

local function on_sound_write(offset, data, mask)
    if offset ~= SND_PORT then
        -- the 32-bit `move a3,@sound` puts its (always zero) high half one
        -- word up; anything else in the aux-port block is not ours
        if (data & 0xffff) ~= 0 then
            print(string.format("[snd] %8.1fms  aux write @%08x = %04x",
                now_ms(), offset, data & 0xffff))
        end
        return data
    end

    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then
        print(string.format("[snd] %8.1fms  RAW latch %04x (reset/strobe)", now_ms(), w))
        pending_hi = nil
        return data
    end

    local byte = w & 0xff
    if pending_hi == nil then
        pending_hi = byte
    else
        local code = (pending_hi << 8) | byte
        pending_hi = nil
        local extra = ""
        if durs[code] then
            extra = string.format("  pri=%s dur=%d ticks (~%dms)",
                pris[code] or "?", durs[code], math.floor(durs[code] * 18.4))
        end
        print(string.format("[snd] %8.1fms  frame=%d  SEND $%04x  %s%s",
            now_ms(), probe_frame, code, track_name(code), extra))
    end
    return data
end

-- The slide-and-kill tail: r_kahn_hammer_smash walks the victim's oypos down
-- until he is past worldtly+scrbot+140, then zeroes his health, which is what
-- ends the round.  Log it so "the ending fired late / never" can be read off
-- positions instead of guessed at.
local SYM = {
    worldtly = 0x010ea260,
    gstate   = 0x010ed820,
    p1_bar   = 0x010ed940,
    f_death  = 0x010ef010,
    p1_obj   = 0x01129e20,   -- overwritten from the map below
    p1_proc  = 0x010ed8b0,
    debug4   = 0x010f0690,
    debug2   = 0x010f0650,
    p1_bar_view = 0x010eb640,
}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                if SYM[name] ~= nil then SYM[name] = tonumber(addr, 16) end
            end
        end
        fh:close()
    end
end

-- Sound-channel arbitration RAM.  These are MKSOUND.ASM .bss locals so they are
-- not in mk2.map by name, but the map DOES place the whole block:
--     010f6870  00000100   MKSOUND.OBJ (.bss)
-- and MKSOUND.ASM declares exactly chan1..4 x {pri 16, dur 16, scp 32} = 0x100
-- bits, 0x40 per channel (which is the `sll 6,a0` in triple_tune).
--
-- Why watch it: triple_sound only hands out a channel whose pri is 0, or steals
-- the first one whose pri is <= the new call's.  soundup clears a pri when its
-- dur counts down.  A channel left with a pri that never expires means every
-- later sound has to steal one that is genuinely playing - which sounds like
-- everything cutting everything else off, and would persist into the next round.
local CHAN_BASE = 0x010f6870
local CHAN_STRIDE = 0x40
local last_chan = nil

local OYPOS = 0x0b0
local last_state = nil

-- debug4 changes, every frame.  The shared harness only samples it at its rel
-- checkpoints, which is far too coarse for breadcrumbs that get overwritten in
-- the same frame they are set (khm_contact's 5033/5034 are replaced by
-- kahn_hammer_try_fatal's 5030 a few instructions later).
local last_d4 = nil
local D4_NAMES = {
    [0x6200] = "kahn stalk",
    [0x5030] = "hammer fatal triggered",
    [0x5031] = "victory laugh",
    [0x5033] = "contact: BLOCKED (chip damage)",
    [0x5034] = "contact: CLEAN HIT (full damage)",
    [0x5040] = "hammer-top started",
    [0x5041] = "hammer-top connected -> dizzy",
    [0x5042] = "hammer-top blocked",
}

local function d4_watch()
    local d4 = space:read_u16(SYM.debug4)
    if d4 ~= last_d4 then
        last_d4 = d4
        print(string.format("[dbg4] %8.1fms  debug4=0x%04x  %s  hp=%d",
            now_ms(), d4, D4_NAMES[d4] or "", space:read_u16(SYM.p1_bar)))
    end
end

local function chan_watch()
    local parts, key = {}, ""
    for c = 0, 3 do
        local base = CHAN_BASE + c * CHAN_STRIDE
        local pri = space:read_u16(base)
        local dur = space:read_u16(base + 0x10)
        parts[#parts + 1] = string.format("ch%d pri=%04x dur=%-3d", c + 1, pri, dur)
        key = key .. string.format("%04x/%d,", pri, dur > 0 and 1 or 0)
    end
    if key ~= last_chan then
        last_chan = key
        print(string.format("[chan] %8.1fms  %s", now_ms(), table.concat(parts, "  ")))
    end
end

local function slide_watch()
    local obj = space:read_u32(SYM.p1_obj)
    if obj == 0 then return end
    local y = space:read_u16(obj + OYPOS)
    local floor = ((space:read_u32(SYM.worldtly) >> 16) & 0xffff) + 253 + 140
    local state = string.format("%d|%d|%d|%d|%d",
        y, floor, space:read_u16(SYM.p1_bar),
        space:read_u16(SYM.f_death), space:read_u16(SYM.gstate))
    if state ~= last_state then
        last_state = state
        print(string.format(
            "[fall] %8.1fms  victim_y=%d  exit_at=%d  p1_bar=%d  f_death=0x%04x  gstate=%d",
            now_ms(), y, floor, space:read_u16(SYM.p1_bar),
            space:read_u16(SYM.f_death), space:read_u16(SYM.gstate)))
    end
end

-- Emulation speed.  If this drops under ~100% the HOST audio device starves and
-- you hear small repetitive blanks in everything - which is a harness/host
-- symptom, not a ROM one: -wavwrite taps the emulated mix and stays clean
-- through it.  Snapshot writing (PNG encode per snap) and -video gdi are the
-- two things here most likely to cause it.
local speed_min, speed_sum, speed_n = 999, 0, 0

local function speed_watch()
    local ok, s = pcall(function() return manager.machine.video.speed_percent end)
    if not ok or not s then return end
    s = s * 100.0
    speed_sum = speed_sum + s
    speed_n = speed_n + 1
    if s < speed_min then speed_min = s end
    if probe_frame % 120 == 0 then
        print(string.format("[speed] %8.1fms  now=%5.1f%%  avg=%5.1f%%  min=%5.1f%%",
            now_ms(), s, speed_sum / speed_n, speed_min))
    end
end

-- KAHN_FAT_BLOCK=1: make the victim BLOCK the hammer, to exercise the path
-- where chip damage is what depletes him.  Two things are in the way: the
-- shared harness sets M_NOBLOCK on him when it seeds the fatality, and nobody
-- is holding a button.  So clear that flag every frame and hold P1 Block from
-- the moment Kahn starts his stalk (debug4 = 6200h) until well past contact.
-- KAHN_FAT_BLOCK=2: the CHIP MEASUREMENT.  Holding block at 16 HP cannot show
-- how much a blocked hammer actually costs, because 16 is inside the fatality
-- window and every outcome ends the round.  So bypass the pick gate with the
-- puppet magic (debug2 = 050adh, which kahn_hammer honours before it looks at
-- round or health), hold the victim at FULL health, and read the damage off
-- the bar: 005h means the block registered, 040h means it did not.
local BLOCK_MEASURE = os.getenv("KAHN_FAT_BLOCK") == "2"
local BLOCK_TEST = os.getenv("KAHN_FAT_BLOCK") == "1" or BLOCK_MEASURE
local PUPPET_MAGIC = 0x050ad
local FULL_HP = 0x0a1
local measured = false
local M_NOBLOCK = 0x0004
local OFLAGS2 = 0x160
local block_field, block_held, block_until, block_state = nil, false, 0, nil

local function block_watch()
    if not BLOCK_TEST then return end
    if not block_field then
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if f.name == "P1 Block" then block_field = f end
            end
        end
        if not block_field then
            print("[block] ERROR no 'P1 Block' input field")
            BLOCK_TEST = false
            return
        end
        print("[block] holding P1 Block through the swing; M_NOBLOCK cleared")
    end

    local obj = space:read_u32(SYM.p1_obj)
    if obj ~= 0 then
        local fl = space:read_u16(obj + OFLAGS2)
        if (fl & M_NOBLOCK) ~= 0 then
            space:write_u16(obj + OFLAGS2, fl & ~M_NOBLOCK)
        end
    end

    local d4 = space:read_u16(SYM.debug4)

    if BLOCK_MEASURE then
        space:write_u16(SYM.debug2, PUPPET_MAGIC)   -- skip round + 10% gate
        -- top him back up until the swing is actually on its way, so the only
        -- damage the bar shows is this hammer's
        if d4 ~= 0x6200 and not measured then
            space:write_u16(SYM.p1_bar, FULL_HP)
            space:write_u16(SYM.p1_bar_view, FULL_HP)
        elseif not measured then
            local hp = space:read_u16(SYM.p1_bar)
            if hp ~= FULL_HP and hp < 0x8000 then
                measured = true
                print(string.format(
                    "[block] %8.1fms  HAMMER LANDED: hp %d -> %d = %d damage  (%s)",
                    now_ms(), FULL_HP, hp, FULL_HP - hp,
                    (FULL_HP - hp) <= 0x10 and "BLOCKED, chip" or "NOT blocked, full hit"))
            end
        end
    end

    if d4 == 0x6200 and block_until == 0 then
        block_until = probe_frame + 240
        print(string.format("[block] %8.1fms  stalk seen - block goes down", now_ms()))
    end
    local want = block_until > 0 and probe_frame < block_until
    -- re-assert EVERY frame, not just on the transition: setting it once let the
    -- victim flicker out of act_blocks (0700h -> 0303h -> 0700h), and a strike
    -- landing in one of those gaps is a clean hit, which is exactly the thing
    -- this test is trying to rule out
    block_field:set_value(want and 1 or 0)
    if want ~= block_held then
        block_held = want
        print(string.format("[block] %8.1fms  P1 Block %s", now_ms(), want and "DOWN" or "up"))
    end

    -- What state is he ACTUALLY in?  act_blocks is 0700h (MAINEQU.ASM); if the
    -- strike lands while he is in anything else it is a clean hit and the chip
    -- value never comes into it.
    if want then
        local proc = space:read_u32(SYM.p1_proc)
        local act = proc ~= 0 and space:read_u16(proc + 0x1f0) or -1
        local fl = obj ~= 0 and space:read_u16(obj + OFLAGS2) or 0
        -- is_he_airborn (JOY.ASM) refuses a block unless oyvel is EXACTLY zero
        -- and oypos EXACTLY equals p_ganiy.  Either one off by a pixel and the
        -- block never registers, which looks identical to "he didn't press it".
        local oyvel = obj ~= 0 and space:read_u32(obj + 0x060) or 0
        local oypos = obj ~= 0 and space:read_u16(obj + OYPOS) or 0
        local ganiy = proc ~= 0 and space:read_u16(proc + 0x200) or 0
        local key = string.format("%04x/%04x/%d/%d/%d/%d",
            act, fl, space:read_u16(SYM.p1_bar), oyvel, oypos, ganiy)
        if key ~= block_state then
            block_state = key
            print(string.format(
                "[block] %8.1fms  act=0x%04x oflags2=0x%04x noblock=%s hp=%d"
                .. "  oyvel=%d oypos=%d ganiy=%d  airborne=%s",
                now_ms(), act, fl, ((fl & M_NOBLOCK) ~= 0) and "SET" or "clear",
                space:read_u16(SYM.p1_bar), oyvel, oypos, ganiy,
                (oyvel ~= 0 or oypos ~= ganiy) and "YES -> CANNOT BLOCK" or "no"))
        end
    end
end

emu.register_frame(function()
    probe_frame = probe_frame + 1
    if space then pcall(slide_watch) end
    if space then pcall(chan_watch) end
    if space then pcall(d4_watch) end
    if space then pcall(speed_watch) end
    if space then pcall(block_watch) end
    if probe_frame == 1 then
        local cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local ok, err = pcall(function()
            tap = space:install_write_tap(TAP_LO, TAP_HI, "sndtap", on_sound_write)
            -- debug4 needs a TAP, not a per-frame poll: khm_contact's
            -- 5033/5034 breadcrumb is overwritten by try_fatal's 5030 a few
            -- instructions later, so it never survives to the end of a frame.
            d4tap = space:install_write_tap(SYM.debug4, SYM.debug4 + 0x0f, "d4tap",
                function(offset, data, mask)
                    local v = data & 0xffff
                    print(string.format("[dbg4w] %8.1fms  debug4 <- 0x%04x  %s  hp=%d",
                        now_ms(), v, D4_NAMES[v] or "", space:read_u16(SYM.p1_bar)))
                    return data
                end)
        end)
        if ok and tap then
            print("[snd] sound-latch tap installed on the aux port block")
        else
            print("[snd] ERROR could not install write tap: " .. tostring(err))
        end
    end
end)

-- Hand over to the real driver script.
dofile(ROOT .. "/tools/kahn_boss_moves_test.lua")
