-- kahn_clap_deflect_test.lua
--
-- Shao Kahn's sonic clap as a projectile DEFLECT.
--
-- Rig: P1 = a human character with a projectile, P2 = Shao Kahn parked in
-- puppet mode (debug2 = 0x50ad) so the only move he ever throws is the one
-- this script asks for through debug3.  P1 throws, the script claps, and
-- the projectile's own flight process is watched from the outside:
--
--   p_otherguy  - who the projectile is allowed to hit.  This is what
--                 kahn_deflect_proj (MKZAP.ASM) rewrites, and it is the
--                 only proof that the thing actually changed sides.
--   oxvel       - which way it is travelling.
--   oyvel       - Scorpion's spear only: it is supposed to FALL, not fly.
--   p1_bar      - did it come back and hurt the man who threw it.
--
-- MK2_DEFLECT_CHAR=kang|scorpion   which projectile to clap (default kang)
-- MK2_DEFLECT_GAP=<px>             starting gap, default 250
-- MK2_DEFLECT_LOG / MK2_DEFLECT_ROOT
--
-- Expected:
--   kang     - fireball reverses, comes back, takes health off P1.
--   scorpion - spear never comes back: it drops away and P1 is untouched.

local frame = 0
local ROOT = os.getenv("MK2_DEFLECT_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("MK2_DEFLECT_LOG") or (ROOT .. "/tools/kahn_clap_deflect.log")
local CHAR_NAME = (os.getenv("MK2_DEFLECT_CHAR") or "kang"):lower()
local START_GAP = tonumber(os.getenv("MK2_DEFLECT_GAP") or "250") or 250
local SNAP_ON = os.getenv("MK2_DEFLECT_SNAP") ~= "0"
-- MK2_DEFLECT_NOCLAP=1: control run.  P1 throws and Kahn never claps, so the
-- projectile's ordinary flight is on record to compare the clap run against.
local NOCLAP = os.getenv("MK2_DEFLECT_NOCLAP") == "1"
-- MK2_DEFLECT_AI=1: no puppet, no pinning, no scripted clap.  P1 just keeps
-- throwing from range and the real Shao Kahn AI decides what to do about it.
-- This is the only run that says whether the clap is REACHABLE in a fight
-- (rpt_kahn_clapback in kahn_counter_projectile, MKBOSS.ASM) rather than
-- merely working when it is forced.
local AIMODE = os.getenv("MK2_DEFLECT_AI") == "1"
-- MK2_DEFLECT_CLAPFIRST=1: clap BEFORE the throw, so the wave is already out
-- and sweeping when the projectile lands on Kahn.  This is the order that
-- produces a spent projectile sitting in the live wave's path - "I froze him
-- after the clap and the ice carried on past him".
local CLAPFIRST = os.getenv("MK2_DEFLECT_CLAPFIRST") == "1"
-- MK2_DEFLECT_NOSTEER=1: control for the steering test.  Some projectiles
-- (Cage's ball) add a gravity term to oyvel every tick on their own, so
-- "oyvel moved" alone does not prove the thrower steered it - run once
-- with the stick and once without and compare the traces.
local NOSTEER = os.getenv("MK2_DEFLECT_NOSTEER") == "1"

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n") logfh:flush() end
end

-- ---------------------------------------------------------------- symbols
local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end

local missing = {}
local function sym(name)
    local v = symbols[name]
    if not v then missing[#missing + 1] = name return 0 end
    return v
end

local A = {
    gstate        = sym("gstate"),
    curback       = sym("curback"),
    p1_state      = sym("p1_state"),  p2_state    = sym("p2_state"),
    p1_obj        = sym("p1_obj"),    p2_obj      = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),   p2_proc     = sym("p2_proc"),
    p1_char       = sym("p1_char"),   p2_char     = sym("p2_char"),
    p1_bar        = sym("p1_bar"),    p2_bar      = sym("p2_bar"),
    p1_bar_view   = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
    map_position  = sym("map_position"),
    battle_num    = sym("battle_num"),
    debug2        = sym("debug2"),
    debug3        = sym("debug3"),    debug4      = sym("debug4"),
    objlst        = sym("objlst"),
    active        = sym("active"),
    tick          = sym("tick"),
}

local PUPPET_MAGIC = 0x50ad
local CLAP_CODE = 3                     -- kahn_debug_test slot for kahn_sonic

-- object / process field offsets (DISPEQU.ASM, MAINEQU.ASM) - the TMS34010
-- space MAME hands lua is bit-addressed, so these are the raw equates
local O = { next = 0x000, oxvel = 0x040, oyvel = 0x060, oxval = 0x080,
            oxpos = 0x090, oypos = 0x0b0, oflags = 0x0f0, osizex = 0x120,
            oflags2 = 0x160, oimg = 0x1a0, ochar = 0x1f0 }
local P = { link = 0x000, procid = 0x020, pa8 = 0x0c0,
            otherguy = 0x140, action = 0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
-- ft_* from MAINEQU.ASM
local FT_HATHEAD, FT_KANG, FT_CAGE, FT_BARAKA, FT_KITANA, FT_MILEENA = 0, 1, 2, 3, 4, 5
local FT_SHANG, FT_RAIDEN, FT_SUBZERO, FT_REPTILE, FT_SCORPION, FT_JAX = 6, 7, 8, 9, 10, 11
local FT_KAHN, KAHN_ARENA = 13, 8
local PS_ACTIVE, PS_INACTIVE = 1, 0
local MAX_HP = 0x0a1

-- dir/button are the special's input: Liu Kang's fireball is Forward,
-- Forward + HP, Scorpion's spear and Kitana's fan are both Back, Back + a
-- punch.  Kitana is here because her fan is caught in mid FLIGHT, where Liu
-- Kang's is caught during the wind-up blob - different code paths inside the
-- projectile, same deflect.
local SUBJECTS = {
    kang     = { id = FT_KANG,     name = "Liu Kang", move = "fireball",
                 dir = "fwd",  button = "P1 High Punch", comes_back = true },
    scorpion = { id = FT_SCORPION, name = "Scorpion", move = "spear",
                 dir = "back", button = "P1 Low Punch",  comes_back = false },
    -- scom_throw_fan is Forward, Forward + HP (combo_edit.py list), NOT the
    -- Back, Back the spear uses.
    kitana   = { id = FT_KITANA,   name = "Kitana",   move = "fan",
                 dir = "fwd",  button = "P1 High Punch",
                 button2 = "P1 Low Punch", comes_back = true },
    -- scom_ice_ball is Down, Forward + LP.  Sub-Zero is here for the SPENT
    -- projectile case: the ice freezes Kahn and then plays a shatter that is
    -- pinned to him, and nothing that has already connected may be deflected.
    -- spent_pin: this one is not scored on coming back.  It is scored on
    -- what happens AFTER it connects - the shatter is pinned to the man it
    -- froze and must not move or change hands while a wave sweeps over it.
    -- scom_spit is Forward, Forward + HP.  This is the one reported as
    -- deflecting at Kahn instead of at the wave.
    reptile  = { id = FT_REPTILE,  name = "Reptile",  move = "spit",
                 dir = "fwd", button = "P1 High Punch", comes_back = true },
    -- scom_slow_proj is Back, Back + LP.  Two things ride on this one: the
    -- forceball explodes on PROXIMITY to whoever it is aimed at rather than
    -- on a strike check, and it is steerable in flight - so it covers both
    -- "it went through him" and "he could still fly it after the clap".
    -- ...and rp_try_slow_force also wants HI PUNCH in the button queue
    -- within 4 ticks of the trigger, so both punches go down together.
    forceball = { id = FT_REPTILE, name = "Reptile", move = "forceball",
                  dirs = {"P1 Left", "P1 Left"}, button = "P1 Low Punch",
                  button2 = "P1 High Punch", comes_back = true, steer = true },
    -- The rest of the cast's projectiles, all reported as needing to work.
    -- Inputs from combo_edit.py list; the trigger button is in the MOVES.ASM
    -- handler, not the combo table.
    baraka   = { id = FT_BARAKA,   name = "Baraka",    move = "spark",
                 dirs = {"P1 Down", "P1 Left"},  button = "P1 High Punch",
                 comes_back = true, steer = true },
    jax      = { id = FT_JAX,      name = "Jax",       move = "force wave",
                 dirs = {"P1 Right", "P1 Down", "P1 Left"},
                 button = "P1 High Kick", comes_back = true },
    shang    = { id = FT_SHANG,    name = "Shang Tsung", move = "skull",
                 dirs = {"P1 Left", "P1 Left"},  button = "P1 High Punch",
                 comes_back = true },
    kunglao  = { id = FT_HATHEAD,  name = "Kung Lao",  move = "hat",
                 dirs = {"P1 Left", "P1 Right"}, button = "P1 Low Punch",
                 comes_back = true, steer = true },
    cage     = { id = FT_CAGE,     name = "Johnny Cage", move = "ball",
                 dirs = {"P1 Down", "P1 Right"}, button = "P1 Low Punch",
                 comes_back = true, steer = true },
    -- fn2_hp_open: a plain HP tap, gated on l_hp - no direction at all.
    -- fn2_hp_open measures l_hp, the time since HP went DOWN, and wants
    -- 022h ticks - so the sai is a HOLD and release, not a tap.
    mileena  = { id = FT_MILEENA,  name = "Mileena",   move = "sai",
                 dirs = {},                      button = "P1 High Punch",
                 tap_button = 45, comes_back = true },
    -- Shang throws one, two or three skulls; spawn_a_skull gives EACH its own
    -- object and its own process, so each is deflected independently as the
    -- wave reaches it.  scom_st_zap3 is Back, Back, Forward, Forward + HP.
    shang3   = { id = FT_SHANG, name = "Shang Tsung", move = "3 skulls",
                 dirs = {"P1 Left", "P1 Left", "P1 Right", "P1 Right"},
                 button = "P1 High Punch", comes_back = true },
    raiden   = { id = FT_RAIDEN,   name = "Raiden",    move = "lightning",
                 dirs = {"P1 Down", "P1 Right"}, button = "P1 Low Punch",
                 comes_back = true, steer = true },
    subzero  = { id = FT_SUBZERO,  name = "Sub-Zero", move = "ice",
                 dirs = {"P1 Down", "P1 Right"}, button = "P1 Low Punch",
                 comes_back = false, spent_pin = true },
}
local SUBJECT = SUBJECTS[CHAR_NAME]

local space
local fields = {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm_start, did_select = 0, false
local kahn_pin_x, armed_frame, throw_frame, clap_frame, done_frame = nil, 0, 0, 0, 0
local proj_proc, proj_obj, proj_seen_frame = nil, nil, 0
local base_vel, deflect_frame, deflect_x = nil, 0, nil
local p1_hp_at_deflect, damage_frame, snaps = nil, 0, 0
local fall_seen, proj_gone_frame = false, 0
-- away_dir = the sign of "back towards P1", i.e. the way a deflected
-- projectile has to travel.  back_dir = the sign it actually took.
local away_dir, back_dir = nil, nil
local last_front, proj_damage, hp_before_hit = nil, nil, nil
local spent_at, spent_x = nil, nil
local steer_vy0, steer_flagged = nil, nil
local blood_peak = nil
local soak_tick, soak_from, soak_seen = nil, nil, nil
local ai_deflects = nil
local verdict = nil
-- Freeze watchdog.  This is a cooperative scheduler: one process that spins
-- without sleeping stops the whole machine, and from the outside that looks
-- exactly like "nothing happened".  Sample the CPU's PC when it goes quiet -
-- run the values through sym_resolve.py to name the loop.
local frozen_since, pc_samples = 0, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff if v >= 0x80000000 then return v - 0x100000000 end return v end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap()
    if not SNAP_ON then return end
    local s = main_screen()
    if s then pcall(function() s:snapshot() end) end
end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Punch"]=true,
                   ["P1 Right"]=true, ["P1 Left"]=true, ["P1 Down"]=true,
                   ["P1 Up"]=true, ["P1 High Kick"]=true, ["P1 Low Kick"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        print(string.format("[dfl] input %-16s %s", n, fields[n] and "ok" or "MISSING"))
    end
end

-- Find a live projectile process: procid family 07xx / 08xx, low byte 0-3
-- (proj / hat / orb / ice).  0800ch+ in the same family byte are the
-- printer, diag and sec-bust procs, which is why the low byte is checked.
local function is_proj_id(id)
    local fam, low = id & 0xff00, id & 0x00ff
    return (fam == 0x0700 or fam == 0x0800) and low <= 3
end

local function find_proj(want_otherguy)
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 400 do
        local id = r16(p + P.procid)
        if is_proj_id(id) then
            local obj = r32(p + P.pa8)
            if obj ~= 0 and (want_otherguy == nil or r32(p + P.otherguy) == want_otherguy) then
                return p, obj, id
            end
        end
        p = r32(p + P.link)
        n = n + 1
    end
    return nil
end

-- The victim box strike_check builds: leftmost_mpart / rightmost_mpart walk
-- the multipart RAM and take each piece's x as oxpos - mp_anix.  A projectile
-- that "connects" from across the screen means this box is wrong, so it gets
-- printed rather than assumed.
local MP = { sag = 0, anix = 32 + 32 + 16, length = 32 + 32 + 16 + 32 }
local function mpart_extent(obj)
    local ram = r32(obj + 0x1a0)                    -- oimg
    if ram == 0 then return nil end
    local ox = s16(r16(obj + O.oxpos))
    local lo, hi, n = 32767, -32768, 0
    while n < 32 do
        if r32(ram + MP.sag) == 0 then break end
        local x = ox - s16(r16(ram + MP.anix))
        if x < lo then lo = x end
        if x > hi then hi = x end
        ram = ram + MP.length
        n = n + 1
    end
    if n == 0 then return nil end
    return lo, hi, n, ox
end

-- kahn_proj_span (MKZAP.ASM), transcribed exactly: multipart via
-- leftmost/rightmost (piece x = oxpos - anix, right = +sizex), single part
-- via oxpos/osizex with the fliph case.  This is the span the deflect's
-- containment test actually uses, so it is the only one worth logging.
local MPF = { sag = 0, sizex = 32, anix = 32 + 32 + 16, length = 32 + 32 + 16 + 32 }
local DEFLECT_REACH = 0x30
local function kahn_span(obj)
    if obj == 0 then return nil end
    local ox = s16(r16(obj + O.oxpos))
    local f2 = r16(obj + O.oflags2)
    if (f2 & 0x0002) == 0 then                  -- b_multipart = bit 1
        local w = s16(r16(obj + O.osizex))
        local fl = r16(obj + O.oflags)
        if (fl & 0x0010) ~= 0 then return ox - w, ox end   -- b_fliph = bit 4
        return ox, ox + w
    end
    local ram = r32(obj + O.oimg)
    if ram == 0 then return nil end
    local lo, hi, n = 32767, -32768, 0
    while n < 32 do
        if r32(ram + MPF.sag) == 0 then break end
        local x = ox - s16(r16(ram + MPF.anix))
        if x < lo then lo = x end
        local rgt = x + s16(r16(ram + MPF.sizex))
        if rgt > hi then hi = rgt end
        ram = ram + MPF.length
        n = n + 1
    end
    if n == 0 then return nil end
    return lo, hi
end

-- Every projectile process on the list, with the object each one is
-- steering.  A process block is recycled the instant its owner dies, so a
-- latched pointer alone lies; this is what tells one apart from another.
local function dump_projs(tag)
    local p, n, rows = r32(A.active), 0, {}
    while p ~= 0 and n < 400 do
        local id = r16(p + P.procid)
        if is_proj_id(id) then
            local o = r32(p + P.pa8)
            rows[#rows + 1] = string.format(
                "proc=%08x id=%04x act=%04x og=%08x obj=%08x x=%d y=%d vx=%.2f vy=%.2f oid=%04x char=%d",
                p, id, r16(p + P.action), r32(p + P.otherguy), o,
                o ~= 0 and s16(r16(o + O.oxpos)) or 0,
                o ~= 0 and s16(r16(o + O.oypos)) or 0,
                o ~= 0 and s32(r32(o + O.oxvel)) / 65536.0 or 0,
                o ~= 0 and s32(r32(o + O.oyvel)) / 65536.0 or 0,
                o ~= 0 and r16(o + 0x1c0) or 0,
                o ~= 0 and r16(o + O.ochar) or -1)
        end
        p = r32(p + P.link)
        n = n + 1
    end
    if #rows == 0 then rows[1] = "(none)" end
    for _, r in ipairs(rows) do print(string.format("[proj] %s %s", tag, r)) end
end

-- Where a projectile actually reaches to: its anchor plus the x offset of
-- whatever strike table it last published in p_joyport.  Same calculation
-- the ROM's kahn_proj_front and MKDRONE's get_proj_front do, and the only
-- honest way to say "the fireball is on top of him" - a projectile's oxpos
-- can sit 200px from its own art.
local P_JOYPORT = 0x100
local function proj_front(proc, obj)
    local x = s16(r16(obj + O.oxpos))
    local stk = r32(proc + P_JOYPORT)
    if stk < 0xff800000 then return x, false end
    local off = s16(r16(stk))
    local fl = r16(obj + O.oflags) & 0x10        -- m_fliph
    if fl ~= 0 then off = -off end
    return x + off, true
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function proc_alive(target)
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 400 do
        if p == target then return true end
        p = r32(p + P.link)
        n = n + 1
    end
    return false
end

local function force_ladder()
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, SUBJECT.id)
    w16(A.p2_char, FT_KAHN)
    w16(A.curback, KAHN_ARENA)
    w16(A.map_position, 14)
    w16(A.battle_num, 15)
    if not AIMODE then w16(A.debug2, PUPPET_MAGIC) end
    if not did_select then
        did_select = true
        print(string.format("[dfl] direct_select frame=%d p1=%d p2=%d", frame,
            r16(A.p1_char), r16(A.p2_char)))
    end
end

local function finish(msg, ok)
    if done_frame > 0 then return end
    done_frame = frame
    verdict = ok
    print("[dfl] " .. msg)
    print("[dfl] " .. (ok and "PASS" or "FAIL"))
    print("[dfl] finished")
end

-- Throw window: the input sequence starts at armed_frame+10 and runs ~40
-- frames.  Liu Kang's high fireball is Forward,Forward+HP; Scorpion's spear
-- is Back,Back+LP.
-- Direction taps are 4 frames with a 2 frame gap, then the button.  Kept
-- tight because the combo windows are: Jax's wave is 0x18 ticks for a THREE
-- direction input (Forward, Down, Back), so a leisurely sequence times out
-- before the trigger ever lands.
local TAP, GAP = 4, 2
local function throw_phase()
    if armed_frame == 0 then return "idle" end
    local t = frame - armed_frame - 10
    if t < 0 then return "idle" end
    if AIMODE then t = t % 150 end          -- keep throwing, one every 2.5s
    -- Retry until something actually comes out.  Not every special takes on
    -- the first scripted attempt (a back-back input walks him while it is
    -- being entered), and a rig that gives up after one try reports "never
    -- threw" for a move that works fine.
    if not AIMODE and throw_frame == 0 then t = t % 60 end
    local n = SUBJECT.dirs and #SUBJECT.dirs or 2
    for i = 1, n do
        local base = (i - 1) * (TAP + GAP)
        if t < base + TAP then return "dir" .. i end
        if t < base + TAP + GAP then return "gap" end
    end
    local after = n * (TAP + GAP)
    if t < after + (SUBJECT.tap_button or 10) then return "punch" end
    return "idle"
end

local function pressed(name)
    if fighting_frame == 0 then
        if charsel_frame > 0 then
            if name == "P1 High Punch" and p1_confirm_start > 0 then
                return frame >= p1_confirm_start and frame < p1_confirm_start + 45
            end
            return false
        end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    -- STEERING TEST: once it has been clapped back, lean on the stick.  The
    -- flight loops that read the thrower's joystick nudge the projectile's
    -- y velocity, so if he still has control the oyvel will move.
    --
    -- DOWN, not up.  By the time it comes back his throw recovery is over,
    -- so up makes him JUMP - and he sails over his own returning shot,
    -- which looks exactly like the projectile failing to connect.  Down
    -- crouches him: still grounded, still hittable, still steering input.
    if SUBJECT.steer and deflect_frame > 0 then
        if NOSTEER then return false end     -- control run: no stick at all
        return name == "P1 Down"
    end
    if throw_frame > 0 and not AIMODE then return false end   -- one throw only
    local ph = throw_phase()
    -- P1 starts on the left, so forward = Right and back = Left.  `dirs`
    -- overrides for specials that are not a simple double-tap (Sub-Zero's
    -- ice is Down, Forward).
    local dirs = SUBJECT.dirs
    if not dirs then
        local d = (SUBJECT.dir == "back") and "P1 Left" or "P1 Right"
        dirs = { d, d }
    end
    for i = 1, #dirs do
        if name == dirs[i] and ph == ("dir" .. i) then return true end
    end
    if name == SUBJECT.button then return ph == "punch" end
    if SUBJECT.button2 and name == SUBJECT.button2 then return ph == "punch" end
    return false
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print("[dfl] kahn_clap_deflect_test - sonic clap as a projectile deflect")
        print("[dfl] log=" .. LOG_PATH)
        if not SUBJECT then
            print("[dfl] ERROR unknown MK2_DEFLECT_CHAR=" .. CHAR_NAME)
            manager.machine:exit() return
        end
        print(string.format("[dfl] subject=%s (%s)  gap=%d  expect=%s",
            SUBJECT.name, SUBJECT.move, START_GAP,
            SUBJECT.comes_back and "reversed back at P1" or "dropped, P1 untouched"))
        if #missing > 0 then
            print("[dfl] ERROR unresolved map symbols: " .. table.concat(missing, ","))
            manager.machine:exit() return
        end
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then
        print(string.format("[dfl] ERROR bad_gstate frame=%d gs=0x%04x", frame, gs))
        snap() manager.machine:exit() return
    end
    if gs ~= last_gstate then
        print(string.format("[dfl] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            w16(A.debug4, 0)
        end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then force_ladder() end
    if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0
       and frame - charsel_frame > 90 then
        p1_confirm_start = frame
    end

    -- ------------------------------------------------- AI mode
    -- Both bars are pinned, so the round can only end on the clock; when it
    -- does, report what was seen rather than sitting there until the
    -- harness timeout calls it an error.
    if AIMODE and fighting_frame > 0 and gs ~= GS_FIGHTING
       and frame - fighting_frame > 300 and done_frame == 0 then
        finish(string.format("AI run: Shao Kahn clapped %d of P1's projectiles back before the round ended",
            ai_deflects or 0), (ai_deflects or 0) > 0)
    end

    -- P1 throws on a loop from wherever he is; Kahn is left completely
    -- alone.  All that is scored is how often the wave turned one around.
    if AIMODE and fighting_frame > 0 and gs == GS_FIGHTING then
        w16(A.p1_bar, MAX_HP) w16(A.p1_bar_view, MAX_HP)
        w16(A.p2_bar, MAX_HP) w16(A.p2_bar_view, MAX_HP)
        if armed_frame == 0 and frame - fighting_frame > 60 then armed_frame = frame end
        if r16(A.debug4) == 0x5020 then
            ai_deflects = (ai_deflects or 0) + 1
            w16(A.debug4, 0)
            local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
            print(string.format("[dfl] AI DEFLECT #%d at frame=%d (gap=%d)", ai_deflects, frame,
                math.abs(s16(r16(p2o + O.oxpos)) - s16(r16(p1o + O.oxpos)))))
        end
        if frame - fighting_frame > 3600 then
            finish(string.format("AI run: Shao Kahn clapped %d of P1's projectiles back over 60s",
                ai_deflects or 0), (ai_deflects or 0) > 0)
        end
        for name, field in pairs(fields) do
            if pressed(name) then field:set_value(1) else field:clear_value() end
        end
        if done_frame > 0 and frame - done_frame > 40 then manager.machine:exit() end
        return
    end

    if fighting_frame > 0 and gs == GS_FIGHTING and done_frame == 0 then
        -- Kahn's health is topped back up only when it gets low, so the round
        -- cannot end under the test but a hit on him is still visible for a
        -- frame.  P1's is never touched: the whole point is watching his own
        -- projectile take it off him.
        if r16(A.p2_bar) < 0x60 then
            w16(A.p2_bar, MAX_HP) w16(A.p2_bar_view, MAX_HP)
        end
        w16(A.debug2, PUPPET_MAGIC)

        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o ~= 0 and p2o ~= 0 then
            local p1x, p2x = s16(r16(p1o + O.oxpos)), s16(r16(p2o + O.oxpos))
            local p1hp = r16(A.p1_bar)

            if kahn_pin_x == nil and frame - fighting_frame > 30 then
                kahn_pin_x = p2x
                print(string.format("[dfl] pin_kahn x=%d", kahn_pin_x))
            end
            if kahn_pin_x and deflect_frame == 0 then
                w32(p2o + O.oxval, kahn_pin_x << 16)
                w16(p2o + O.oxpos, kahn_pin_x)
            end

            if armed_frame == 0 and kahn_pin_x and frame - fighting_frame > 60 then
                armed_frame = frame
                local target = kahn_pin_x - START_GAP
                w32(p1o + O.oxval, target << 16)
                w16(p1o + O.oxpos, target)
                print(string.format("[dfl] armed frame=%d p1_x=%d kahn_x=%d gap=%d",
                    frame, target, kahn_pin_x, START_GAP))
                if CLAPFIRST then
                    w16(A.debug4, 0)
                    w16(A.debug3, CLAP_CODE)
                    clap_frame = frame
                    print("[dfl] CLAP FIRST - requested before the throw")
                end
            end

            -- The throw: watch for the flight process appearing, then clap.
            -- Only a projectile aimed at KAHN counts - his own clap wave is a
            -- projectile process too, and it is aimed the other way.
            if armed_frame > 0 and proj_proc == nil then
                local pp, po, id = find_proj(p2o)
                if pp then
                    proj_proc, proj_obj, proj_seen_frame = pp, po, frame
                    throw_frame = frame
                    base_vel = s32(r32(po + O.oxvel))
                    away_dir = (p1x < p2x) and -1 or 1     -- back towards P1
                    print(string.format(
                        "[dfl] THROWN frame=%d proc=0x%08x id=0x%04x obj=0x%08x x=%d oxvel=%.2f otherguy=0x%08x (kahn=0x%08x)",
                        frame, pp, id, po, s16(r16(po + O.oxpos)),
                        base_vel / 65536.0, r32(pp + P.otherguy), p2o))
                    if not NOCLAP and not CLAPFIRST then
                        w16(A.debug4, 0)
                        w16(A.debug3, CLAP_CODE)
                        clap_frame = frame
                        print("[dfl] clap requested")
                    elseif CLAPFIRST then
                        print("[dfl] (wave already out - clap was requested first)")
                    else
                        print("[dfl] CONTROL RUN - no clap requested")
                    end
                    snap()
                end
            end

            -- re-post an unconsumed clap command
            if clap_frame > 0 and deflect_frame == 0 and r16(A.debug3) ~= 0
               and (frame - clap_frame) % 60 == 0 then
                w16(A.debug3, CLAP_CODE)
            end

            -- @tick is the game's own heartbeat; if it stops, the scheduler is
            -- wedged, not merely idle.
            -- Keyed on @tick and NOT on a debug breadcrumb: the wave's
            -- breadcrumbs legitimately stop the moment the wave dies, which
            -- reads as a freeze that never happened.
            if throw_frame > 0 then
                local t = r16(A.tick)
                if t ~= (pc_samples.last_d4 or -1) then
                    pc_samples.last_d4 = t
                    frozen_since = frame
                elseif frame - frozen_since > 45 then
                    local ok, pc = pcall(function()
                        return manager.machine.devices[":maincpu"].state["PC"].value end)
                    pc_samples[#pc_samples + 1] = ok and string.format("%08x", pc) or "?"
                    if #pc_samples >= 12 then
                        -- A cycle in the active list wedges the dispatcher
                        -- itself, so count it with cycle detection.
                        local p, n, seen, cyc = r32(A.active), 0, {}, false
                        while p ~= 0 and n < 500 do
                            if seen[p] then cyc = true break end
                            seen[p] = true n = n + 1 p = r32(p + P.link)
                        end
                        print(string.format("[dfl] active list: %d procs, cycle=%s, last d4=0x%04x",
                            n, tostring(cyc), r16(A.debug4)))
                        print(string.format("[dfl]   d5(kahn_obj per the wave)=%08x  d6(walk cursor)=%08x  p1_obj=%08x p2_obj=%08x",
                            r32(sym("debug5")), r32(sym("debug6")), p1o, p2o))
                        local wp = proj_proc
                        print(string.format("[dfl]   deflected proc og=%08x  wave proc=?  (proj obj=%08x)",
                            r32(wp + P.otherguy), proj_obj))
                        print("[dfl] FROZEN - cpu PC samples: " .. table.concat(pc_samples, " "))
                        print("[dfl]   resolve with: python sym_resolve.py <pc>")
                        finish("the machine stopped dead after the deflect", false)
                    end
                end
            end

            if throw_frame > 0 and frame - throw_frame <= 90 then
                -- Where the ROM thinks the projectile reaches (front, from
                -- its published strike table) vs where its ART actually is.
                -- If those disagree the deflect fires in the wrong place -
                -- that is the "deflects at Kahn, not at the wave" report.
                local pf, had = "-", false
                if proj_proc and proj_obj then
                    local f; f, had = proj_front(proj_proc, proj_obj)
                    local lo, hi = mpart_extent(proj_obj)
                    pf = string.format("front=%d%s art=[%s..%s] anchor=%d",
                        f, had and "" or "(anchor!)", tostring(lo), tostring(hi),
                        s16(r16(proj_obj + O.oxpos)))
                end
                -- SPAN AGAINST SPAN, the way kahn_sonic_deflect asks it.
                -- The wave is the other projectile proc on the list, the one
                -- Kahn owns; find it and print both padded spans plus the
                -- verdict, so a miss says WHICH edge missed.
                local sp = ""
                if proj_proc and proj_obj then
                    local wobj = nil
                    local q, qn = r32(A.active), 0
                    while q ~= 0 and qn < 400 do
                        if is_proj_id(r16(q + P.procid)) and q ~= proj_proc then
                            local o = r32(q + P.pa8)
                            if o ~= 0 and r16(o + O.ochar) == FT_KAHN then wobj = o end
                        end
                        q = r32(q + P.link); qn = qn + 1
                    end
                    local pl, pr = kahn_span(proj_obj)
                    if pl and wobj then
                        local wl, wr = kahn_span(wobj)
                        if wl then
                            local a1, a2 = pl - DEFLECT_REACH, pr + DEFLECT_REACH
                            local hit = not (wl > a2 or wr < a1)
                            sp = string.format(" | span proj=[%d..%d] pad=[%d..%d] wave=[%d..%d] %s",
                                pl, pr, a1, a2, wl, wr, hit and "OVERLAP" or "miss")
                        end
                    elseif pl then
                        sp = string.format(" | span proj=[%d..%d] wave=none", pl, pr)
                    end
                end
                -- The DEFENDER's own numbers, so "the box lies" can be
                -- checked rather than argued: his drawn silhouette, and the
                -- quarter/half columns sq_punch would cut from it.
                do
                    local k = p2o
                    if k and k ~= 0 then
                        local kl, kr = kahn_span(k)
                        if kl then
                            local w = kr - kl
                            local kx = s16(r16(k + O.oxpos))
                            local q = w - 2*((w>>3) + (w>>2))   -- colnarrow 4
                            local h = w >> 1                    -- colnarrow 2
                            pf = pf .. string.format(
                                " | kahn art=[%d..%d] w=%d col4=[%d..%d] col2=[%d..%d]",
                                kl, kr, w,
                                kx - (q>>1), kx + (q - (q>>1)),
                                kx - (h>>1), kx + (h - (h>>1)))
                        end
                    end
                end
                -- MK2_DEFLECT_SNAPALL=1 shoots every tick of the approach,
                -- for reading the ART against the box the log prints.
                if os.getenv("MK2_DEFLECT_SNAPALL") == "1"
                    and frame - throw_frame <= 20 then snap() end
                dump_projs(string.format("rel=%3d d4=%04x p1x=%d p2x=%d hp=%d p2hp=%d %s%s",
                    frame - throw_frame, r16(A.debug4), p1x, p2x, p1hp, r16(A.p2_bar), pf, sp))
            end

            if proj_proc and deflect_frame == 0 then
                -- A dead process's block is handed straight to the next
                -- allocation, so "still on the active list" is not enough:
                -- the object it is steering has to still be ours.
                local recycled = not proc_alive(proj_proc)
                    or not is_proj_id(r16(proj_proc + P.procid))
                    or r32(proj_proc + P.pa8) ~= proj_obj
                if recycled and SUBJECT.spent_pin and spent_at then
                    finish(string.format(
                        "%s's %s froze him and its impact cleared up normally, pinned at x=%d throughout",
                        SUBJECT.name, SUBJECT.move, spent_x), true)
                elseif recycled then
                    finish(string.format(
                        "the %s was gone %d frames after the throw, before the wave ever reached it",
                        SUBJECT.move, frame - proj_seen_frame), false)
                else
                    local og = r32(proj_proc + P.otherguy)
                    local vel = s32(r32(proj_obj + O.oxvel))
                    -- SPENT-PROJECTILE ASSERTION.  act_proj_dead (0x500)
                    -- means it has already connected and is playing its
                    -- impact, pinned to whoever it hit.  Deflecting one is
                    -- always a bug: it flips art that the hit path has
                    -- already lined up, and the sprite jumps off the victim.
                    -- This is the "freeze sprite carried on past him" report.
                    -- Arm only on a projectile that went spent while it was
                    -- STILL KAHN'S, i.e. it connected with him.  A deflected
                    -- one is marked dead too - spear_deflected does it on
                    -- purpose - and that is the intended end state, not this.
                    if r16(proj_proc + P.action) == 0x500
                       and (spent_at ~= nil or og == p2o) then
                        local px = s16(r16(proj_obj + O.oxpos))
                        if spent_at == nil then
                            spent_at, spent_x = frame, px
                            print(string.format(
                                "[dfl] %s has CONNECTED (act_proj_dead) at rel=%d, impact pinned at x=%d - it must not move or change hands now",
                                SUBJECT.move, frame - throw_frame, px))
                        end
                        if og == p1o then
                            finish(string.format(
                                "BUG: a spent %s was deflected %d frames after it connected - its impact sprite gets flipped off the victim",
                                SUBJECT.move, frame - spent_at), false)
                        elseif math.abs(px - spent_x) > 8 then
                            finish(string.format(
                                "BUG: the spent %s slid from x=%d to x=%d after connecting - that is the sprite carrying on past him",
                                SUBJECT.move, spent_x, px), false)
                        elseif SUBJECT.spent_pin and frame - spent_at > 120 then
                            finish(string.format(
                                "%s's %s froze him and its impact stayed pinned at x=%d for %d frames while the wave swept over it",
                                SUBJECT.name, SUBJECT.move, spent_x, frame - spent_at), true)
                        end
                    elseif SUBJECT.spent_pin and spent_at
                           and frame - spent_at > 20 then
                        finish(string.format(
                            "%s's %s froze him and its impact played out and cleared up normally (%d frames)",
                            SUBJECT.name, SUBJECT.move, frame - spent_at), true)
                    end
                    if og == p1o then
                        deflect_frame = frame
                        deflect_x = s16(r16(proj_obj + O.oxpos))
                        p1_hp_at_deflect = p1hp
                        print(string.format(
                            "[dfl] DEFLECT frame=%d rel=%d at x=%d (kahn_x=%d p1_x=%d)  oxvel %.2f -> %.2f  mirror_shift=%d",
                            frame, frame - throw_frame, deflect_x, p2x, p1x,
                            base_vel / 65536.0, vel / 65536.0,
                            s32(r32(sym("debug5")))))
                        snap()
                    end
                end
            end

            -- ------------------------------------------------- after the bat
            if deflect_frame > 0 then
                local rel = frame - deflect_frame
                -- Independent of the projectile still existing: did the hit
                -- draw BLOOD, and does the victim come out of his reaction?
                -- pid_blood is 0201h.  A stuck victim shows the same action
                -- forever; a recovered one drops back to a stance action.
                if rel <= 200 and rel % 5 == 0 then
                    local blood, p, n = 0, r32(A.active), 0
                    while p ~= 0 and n < 400 do
                        if r16(p + P.procid) == 0x0201 then blood = blood + 1 end
                        p = r32(p + P.link) n = n + 1
                    end
                    if blood > (blood_peak or 0) then blood_peak = blood end
                    print(string.format("[dfl] victim rel=%3d hp=%3d act=0x%04x blood_procs=%d y=%d",
                        rel, p1hp, p1_action(), blood, s16(r16(p1o + O.oypos))))
                end
                local alive = proc_alive(proj_proc)
                    and is_proj_id(r16(proj_proc + P.procid))
                    and r32(proj_proc + P.pa8) == proj_obj
                -- The wave lands its own 16 somewhere in here; ignore that
                -- one so it cannot be mistaken for the projectile's hit.
                if damage_frame == 0 and hp_before_hit
                   and p1hp == hp_before_hit - 16
                   and last_front and math.abs(last_front - p1x) >= 100 then
                    hp_before_hit = p1hp
                end

                if alive then
                    local vy = s32(r32(proj_obj + O.oyvel))
                    local vx = s32(r32(proj_obj + O.oxvel))
                    if vy > 0 then fall_seen = true end
                    -- Is he still flying it?  P1 is holding UP from the
                    -- moment of the deflect; a y velocity that answers the
                    -- stick means the thrower kept control of a projectile
                    -- that is now coming back at him.
                    -- Threshold, not "any change": Cage's ball adds its own
                    -- gravity to oyvel every tick (MKZAP snot_noaim), so a
                    -- drifting y proves nothing.  A thrower who still has the
                    -- stick adds 0x8000 (0.5px) EVERY tick on top of that, so
                    -- real steering diverges by whole pixels within a few
                    -- ticks while gravity alone stays small over the same span.
                    if SUBJECT.steer and not NOSTEER then
                        if steer_vy0 == nil then steer_vy0 = vy end
                        if math.abs(vy - steer_vy0) > 0x30000 and steer_flagged == nil then
                            steer_flagged = true
                            finish(string.format(
                                "BUG: P1 is still steering his own %s after it was clapped back - oyvel moved %.2f -> %.2f while holding UP",
                                SUBJECT.move, steer_vy0 / 65536.0, vy / 65536.0), false)
                        end
                    end
                    -- Direction is judged the first tick it is actually
                    -- MOVING.  A clap that catches Liu Kang's fireball while
                    -- it is still the growing blob in his hands finds oxvel
                    -- at 0 - the flight loop has not called set_proj_vel yet -
                    -- and it is the flipped facing that sends it back when it
                    -- finally does.
                    if vx ~= 0 and back_dir == nil then
                        back_dir = (vx > 0) and 1 or -1
                        print(string.format("[dfl] first motion after the bat: oxvel=%.2f (%s)",
                            vx / 65536.0, back_dir == away_dir and "AWAY from Kahn" or "toward Kahn"))
                        if back_dir ~= away_dir and SUBJECT.comes_back then
                            finish(string.format(
                                "it changed sides but is still flying at Kahn (oxvel=%.2f)", vx / 65536.0), false)
                        end
                    end
                    local front = proj_front(proj_proc, proj_obj)
                    last_front = front
                    if rel % 4 == 0 then
                        local plo, phi = mpart_extent(p1o)
                        local px = s16(r16(proj_obj + O.oxpos))
                        -- blood procs on the list, and P1's action, so a
                        -- "no blood / stuck stumbling" report is measurable
                        local blood, p, n = 0, r32(A.active), 0
                        while p ~= 0 and n < 400 do
                            if (r16(p + P.procid) & 0xff00) == 0x0200 then blood = blood + 1 end
                            p = r32(p + P.link) n = n + 1
                        end
                        print(string.format(
                            "[dfl] post rel=%3d proj_x=%4d y=%3d oxvel=%7.2f p1_hp=%3d p1_act=0x%04x blood=%d | p1 art=[%s..%s] p1_y=%d",
                            rel, px, s16(r16(proj_obj + O.oypos)),
                            vx / 65536.0, p1hp, p1_action(), blood,
                            tostring(plo), tostring(phi), s16(r16(p1o + O.oypos))))
                    end
                elseif proj_gone_frame == 0 then
                    proj_gone_frame = frame
                    print(string.format("[dfl] projectile gone rel=%d", rel))
                end
                if snaps < 14 and rel % 6 == 0 then snaps = snaps + 1 snap() end

                -- Whose hit was it?  The clap wave is coming at P1 as well,
                -- so "he lost health" proves nothing on its own.  The
                -- projectile says so itself: every flight loop calls
                -- dead_projectile when it connects, which stamps
                -- act_proj_dead (0x500) on its own process.
                -- (Not for the spear: spear_deflected stamps act_proj_dead
                -- deliberately, as the "this is inert now" marker, so for
                -- that one health is the only evidence that counts.)
                -- Second signal for the ones whose process is gone by the
                -- time we look (Kitana's fan dies on contact): health lost
                -- while the projectile's last known position was ON him.
                -- The clap wave takes exactly 16, so a different number, or
                -- a second drop, is the projectile's.
                local self_hit = false
                if SUBJECT.comes_back and damage_frame == 0 then
                    if alive and r16(proj_proc + P.action) == 0x500 then
                        self_hit = true
                    elseif p1hp < (hp_before_hit or p1hp)
                           and last_front and math.abs(last_front - p1x) < 100 then
                        self_hit = true
                    end
                end
                if self_hit then
                    damage_frame = frame
                    proj_damage = (hp_before_hit or p1hp) - p1hp
                    print(string.format(
                        "[dfl] HIS OWN SHOT CAME BACK AND HIT HIM: rel=%d, front=%s vs p1_x=%d, p1 hp %s -> %d",
                        rel, tostring(last_front), p1x, tostring(hp_before_hit), p1hp))
                    snap()
                end
                if damage_frame == 0 then hp_before_hit = p1hp end
                if damage_frame > 0 and rel % 4 == 0 then
                    proj_damage = math.max(proj_damage or 0, (hp_before_hit or p1hp) - p1hp)
                end

                if SUBJECT.comes_back then
                    -- SOAK after the hit, not a victory lap.  A projectile
                    -- connecting with its own thrower is a state stock MK2
                    -- cannot reach, and the ways it goes wrong (an object
                    -- deleted under a live flight process, a kill on a
                    -- process that has already gone) all end as a wedged
                    -- scheduler a second later rather than a bad hit.  @tick
                    -- is the game's own heartbeat: if it keeps climbing for
                    -- 240 frames after the hit, nothing seized up.
                    if damage_frame > 0 and rel > 30 then
                        local t = r16(A.tick)
                        if soak_tick == nil then
                            soak_tick, soak_from = t, frame
                        elseif t ~= soak_tick then
                            soak_tick, soak_seen = t, (soak_seen or 0) + 1
                        end
                        if frame - (soak_from or frame) > 240 then
                            if (soak_seen or 0) < 30 then
                                finish(string.format(
                                    "the hit landed but the game stopped ticking afterwards (%d ticks in 240 frames)",
                                    soak_seen or 0), false)
                            else
                                finish(string.format(
                                    "%s's %s was clapped back and took %d off him; game still running %d frames later",
                                    SUBJECT.name, SUBJECT.move, proj_damage or 0, frame - soak_from), true)
                            end
                        end
                    elseif rel > 240 then
                        finish(string.format(
                            "%s reversed but never reached him again (proj %s, p1_hp=%d)",
                            SUBJECT.move, alive and "still flying" or "gone", p1hp), false)
                    end
                else
                    -- The clap wave itself is still inbound and takes 16 off
                    -- him; anything beyond that would have to be the spear.
                    if p1hp < (p1_hp_at_deflect or 999) - 20 then
                        finish(string.format(
                            "the %s still hit P1 after being clapped - it was supposed to drop", SUBJECT.move), false)
                    elseif proj_gone_frame > 0 and rel > 30 then
                        finish(string.format(
                            "%s's %s dropped away without touching him (fell=%s, gone after %d frames)",
                            SUBJECT.name, SUBJECT.move, tostring(fall_seen),
                            proj_gone_frame - deflect_frame), fall_seen)
                    elseif rel > 300 then
                        finish(string.format("the %s never went away (fell=%s)",
                            SUBJECT.move, tostring(fall_seen)), false)
                    end
                end
            end

            if throw_frame > 0 and deflect_frame == 0 and frame - throw_frame > 400 then
                finish(string.format("no deflect: debug3=%d debug4=0x%04x (clap never met the %s)",
                    r16(A.debug3), r16(A.debug4), SUBJECT.move), false)
            end
            if armed_frame > 0 and proj_proc == nil and frame - armed_frame > 300 then
                finish("P1 never threw anything - check the input sequence", false)
            end
        end
    end

    if done_frame > 0 and frame - done_frame > 40 then manager.machine:exit() end
    if frame > 5000 then
        print("[dfl] ERROR timeout")
        snap() manager.machine:exit()
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end
end)

emu.register_stop(function()
    print(string.format("[dfl] stopped frame=%d verdict=%s", frame, tostring(verdict)))
    if logfh then logfh:flush() logfh:close() logfh = nil end
end)
