-- kahn_boss_moves_test.lua
-- Starts a one-player Liu Kang vs Shao Kahn match on Kahn's Arena.
-- By default it asks the Kahn boss loop to perform one restored move through
-- debug3 command values 1..7. With KAHN_NORMAL_MATCH=1, it leaves the match
-- alone after the skip and only records logs/screenshots.

local frame = 0
local ROOT = os.getenv("KAHN_TEST_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("KAHN_TEST_LOG") or (ROOT .. "/tools/kahn_boss_moves_test.log")
local NORMAL_MATCH = os.getenv("KAHN_NORMAL_MATCH") == "1"
local LIVE_HOLD = os.getenv("KAHN_LIVE_HOLD") == "1"
-- KAHN_P2_PAD=1: puppet mode - the P2 joystick/buttons drive Kahn through
-- the debug3 command hook while @debug2 suppresses his autonomous AI.
-- P1 stays a normal human Liu Kang, so this is local 2-player vs Kahn.
local P2_PAD = os.getenv("KAHN_P2_PAD") == "1"
-- KAHN_PUPPET_HOLD=1: raise the puppet flag WITHOUT handing Kahn to the P2 pad.
-- kahn_stalk then skips all autonomous AI and idles in kahn_puppet_hold polling
-- kahn_debug_test every tick, so a scripted -Move request is consumed at once
-- and the move's own AI gates (cooldowns, range rolls) are bypassed.
-- Without this a scripted run races the live AI: it can sit unacknowledged
-- while Kahn parks in a defensive branch against a passive dummy, or get
-- refused by a cooldown the AI just spent - both of which look like the move
-- being broken when it is not.
local PUPPET_HOLD = os.getenv("KAHN_PUPPET_HOLD") == "1"
-- KAHN_COLBOX=1: draw the game's green collision-box overlay (f_colbox)
-- during the fight - shows hitboxes vs art in snapshots.
local COLBOX = os.getenv("KAHN_COLBOX") == "1"
local PIN_PLAYERS = os.getenv("KAHN_PIN_PLAYERS") == "1"
local PIN_RELEASE_ON_MOVE = os.getenv("KAHN_PIN_RELEASE_ON_MOVE") == "1"
-- Pin Kahn only and leave P1 free to walk.  Deliberately a GLOBAL,
-- not a local: this chunk sits at Lua's 60-upvalue-per-closure
-- ceiling and one more local upvalue stops the whole script loading.
PIN_KAHN_ONLY = os.getenv("KAHN_PIN_KAHN") == "1"
if PIN_KAHN_ONLY then PIN_PLAYERS = true end
-- KAHN_PIN_ESCAPE: walk the VICTIM this many pixels further away, once, a few
-- frames after the move is requested.  Kahn stays pinned where he is.
--
-- This is the only way to make a Kahn move MISS on purpose.  Pinning the pair
-- wide does not do it: every attack stalks first (kahn_stalk_a11 loops until
-- the gap closes to its own target) and a pin Kahn cannot walk out of makes
-- that loop run forever, which the rig then reports as the move never firing.
-- So the gap has to start inside the stalk's target - close enough that it
-- exits on its first check - and then open up DURING the wind-up, which is
-- also the only way a real fight produces a whiff.
--
-- KAHN_PIN_ESCAPE_DELAY is when, in frames after the request.  The default 6
-- is past the one-tick stalk and inside the 7-tick over-the-top wind-up; a
-- move with a longer wind-up wants a larger number, and one with a shorter
-- one cannot be missed this way at all.
--
-- Deliberately GLOBALS for the reason PIN_KAHN_ONLY above documents: this
-- chunk is at Lua's 60-upvalue-per-closure ceiling and one more local upvalue
-- stops the whole script loading.
PIN_ESCAPE_PX = tonumber(os.getenv("KAHN_PIN_ESCAPE") or "0") or 0
PIN_ESCAPE_DELAY = tonumber(os.getenv("KAHN_PIN_ESCAPE_DELAY") or "6") or 6
PIN_ESCAPE_DONE = false
local DEBUG_OBJECTS = os.getenv("KAHN_DEBUG_OBJECTS") == "1"
local MOVE_START_DELAY = tonumber(os.getenv("KAHN_MOVE_START_DELAY") or "90") or 90
local CODE_LIST = rawget(_G, "KAHN_TEST_CODES") or os.getenv("KAHN_TEST_CODES") or os.getenv("KAHN_TEST_CODE") or ""
local UNLIMITED_HEALTH = rawget(_G, "KAHN_UNLIMITED_HEALTH") == true or os.getenv("KAHN_UNLIMITED_HEALTH") == "1"
local ALLOW_P1_DAMAGE = os.getenv("KAHN_ALLOW_P1_DAMAGE") == "1"
-- Hold P1's BLOCK button for the whole move.  BLOCK is a dedicated button in
-- MK2, so no direction is needed and the victim does not have to be walked
-- into a stance first.  The point is the OTHER half of every strike record:
-- the block byte is a different table (block_xfers) from the hit byte, and
-- nothing about a clean hit landing proves the blocked path is wired.
local BLOCK_VICTIM = os.getenv("KAHN_BLOCK_VICTIM") == "1"
local PORTAL_FATALITY = os.getenv("KAHN_PORTAL_FATALITY") == "1"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local MAP_PATH = ROOT .. "/src/mk2.map"
local symbols = {}
do
    local fh = io.open(MAP_PATH, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        print("[kahn-test] WARN could not read " .. MAP_PATH .. "; using fallback addresses")
    end
end

local function symaddr(name, fallback)
    local value = symbols[name]
    if value then return value end
    print(string.format("[kahn-test] WARN missing map symbol %s; using fallback 0x%08x", name, fallback))
    return fallback
end

local A = {
    active        = symaddr("active", 0x010dc6d0),
    objlst        = symaddr("objlst", 0x01127060),
    gstate        = symaddr("gstate", 0x01129dd0),
    curback       = symaddr("curback", 0x0112b6d0),
    p1_state      = symaddr("p1_state", 0x01129df0),
    p1_obj        = symaddr("p1_obj", 0x01129e20),
    p1_proc       = symaddr("p1_proc", 0x01129e60),
    p1_char       = symaddr("p1_char", 0x01129e80),
    p1_bar_view   = symaddr("p1_bar_view", 0x011280f0),
    p1_bar        = symaddr("p1_bar", 0x01129ef0),
    p2_state      = symaddr("p2_state", 0x0112a9c0),
    p2_obj        = symaddr("p2_obj", 0x0112a9f0),
    p2_proc       = symaddr("p2_proc", 0x0112aa30),
    p2_char       = symaddr("p2_char", 0x0112aa50),
    p2_bar_view   = symaddr("p2_bar_view", 0x01128030),
    p2_bar        = symaddr("p2_bar", 0x0112aac0),
    winner_status = symaddr("winner_status", 0x0112b710),
    map_position  = symaddr("map_position", 0x0112b750),
    battle_num    = symaddr("battle_num", 0x0112b760),
    f_colbox      = symaddr("f_colbox", 0x0112bb60),
    -- Training-mode clock freeze (MAIN.ASM:718).  A live watch session is
    -- otherwise ended by the ROUND CLOCK, not by anything the rig does:
    -- unlimited health stops the bars emptying but the timer still runs
    -- out, the match returns to select, and the harness quits on
    -- "p2 is not Kahn" ~76s in.
    f_freeze_timer = symaddr("f_freeze_timer", 0),
    debug2        = symaddr("debug2", 0x0112c6d0),
    debug3        = symaddr("debug3", 0x0112c000),
    debug4        = symaddr("debug4", 0x0112bc90),
    debug5        = symaddr("debug5", 0x0112bcb0),
    round_num     = symaddr("round_num", 0x0112b740),
    -- MPROC.ASM exports this for exactly this purpose: it counts LIVE blood
    -- procs, so a hit that draws blood shows up as a jump here and one that
    -- does not shows nothing.  It falls back to zero on the count as droplets
    -- expire, hence the peak tracking in check_move_progress.
    blood_count   = symaddr("blood_count", 0x0112c710),
    -- The violence DIP. create_blood_proc returns immediately when this is
    -- set, so a "no blood" reading means nothing until you have read it.
    f_no_blood    = symaddr("f_no_blood", 0x0112bb80),
}

-- KAHN_FORCE_ROUND=N pins @round_num to N every frame during the fight, for
-- testing round-gated moves.  round_num is ONE-based: game_init clears it and
-- round_init increments it going in to each round, so round 1 runs with
-- round_num = 1 and the Portal Punch gate (round 3 only, in kahn_portal and
-- again in kahn_portal_try_fatal) wants 3.  Portal fatality runs default to
-- that so -PortalFatality works without also passing KAHN_FORCE_ROUND.
SNAP_EVERY = tonumber(os.getenv("KAHN_SNAP_EVERY") or "3") or 3
-- KAHN_PAL_TRACE=1: log Kahn's live colour map every frame of a move.
-- Prints the palette id out of opal plus four CRAM entries, which is enough
-- to name the palette: the BGGLO ramp steps are only separable by their
-- colours, not by their length, so "the palette changed" is not evidence on
-- its own that it changed to the RIGHT one.
local PAL_TRACE = os.getenv("KAHN_PAL_TRACE") == "1"
-- KAHN_SNAP_ENTRY=1: dense capture of the move's ENTRY as well as its payoff.
local SNAP_ENTRY = os.getenv("KAHN_SNAP_ENTRY") == "1"
-- KAHN_PROC_CENSUS=1: print the active-process count every 10 ticks.
local PROC_CENSUS = os.getenv("KAHN_PROC_CENSUS") == "1"
local census_dumped = false
local last_master_wake, master_stuck_since = -1, 0
-- KAHN_END_HOLD: ticks to keep running after the last move, so a round end
-- (winner tune, FATALITY reveal) can be watched.  Default 80 - see the exit.
local END_HOLD = tonumber(os.getenv("KAHN_END_HOLD") or "80") or 80
local PORTAL_ROUND = 3
local FORCE_ROUND = tonumber(os.getenv("KAHN_FORCE_ROUND") or "")
if not FORCE_ROUND and PORTAL_FATALITY then FORCE_ROUND = PORTAL_ROUND end

local O = {
    next  = 0x000,
    oxval = 0x080,
    oxpos = 0x090,
    oyval = 0x0a0,
    oypos = 0x0b0,
    ozval = 0x0c0,
    ograv = 0x020,
    oyvel = 0x060,
    oflags = 0x0f0,
    opal  = 0x140,
    oflags2 = 0x160,
    oimg  = 0x1a0,
    oid   = 0x1c0,
    oshape = 0x1d0,
    ochar = 0x1f0,
}

local P = {
    next   = 0x000,
    id     = 0x020,
    time   = 0x030,
    sp     = 0x040,
    pa11   = 0x060,
    pa10   = 0x080,
    pa9    = 0x0a0,
    pa8    = 0x0c0,
    wake   = 0x0e0,
    otherguy = 0x140,
    otherproc = 0x170,
    slave  = 0x190,
    action = 0x1f0,
    ganiy = 0x200,
    store1 = 0x230,
    store2 = 0x250,
    store4 = 0x290,
}

local GS_PSEL = 4
local GS_FIGHTING = 2
local FT_KANG = 1
local FT_KAHN = 13
-- KAHN_P1_CHAR=<ochar>: who Kahn fights (default Liu Kang).  2 = Johnny Cage,
-- the fighter data/SHAOSLAMCAGE.WAX authored the throat slam against.
local P1_CHAR = tonumber(os.getenv("KAHN_P1_CHAR") or "") or FT_KANG
local KAHN_ARENA = 8
local MAX_HP = 0x0a1
local HALF_HP = MAX_HP // 2
-- Seed the victim below the hammer's 10% pick gate (010h of full_strength's
-- 0a1h, kahn_hammer in MKBOSS.ASM).  Was 0x20, which is over that line, so
-- Kahn refuses the swing and throws a zap instead - the run then fails with
-- move_not_acknowledged rather than anything about health.  The Portal Punch
-- has no health gate of its own, so this suits both.
local PORTAL_FATAL_HP = 0x10
local PS_ACTIVE = 1
local PS_INACTIVE = 0
local ACT_ANGLE_JUMP = 0x0308
local ACT_JUMPUP = 0x030b
local M_NOBLOCK = 0x0004

local all_moves = {
    { code = 1, name = "big_power" },
    { code = 2, name = "slam" },
    { code = 3, name = "sonic" },
    { code = 4, name = "portal" },
    { code = 5, name = "nupower" },
    { code = 6, name = "jump" },
    { code = 7, name = "fly" },
    -- Hammer smash: kahn_debug_test code 16.  Like the Portal Punch it
    -- self-gates to round 3 and to a critical opponent, so -PortalFatality
    -- (which pins round_num and seeds the victim at 0x20 HP) is what makes
    -- it reach kahn_hammer_try_fatal; without it you get the ordinary
    -- heavy hit and the swing animation only.
    { code = 16, name = "hammer" },
    -- Over-the-top hammer: kahn_debug_test code 17.  Unlike the two
    -- finishers this has no round or health gate, so a plain run fires it.
    -- What it DOES self-gate on is a cooldown (skipped in puppet mode) and
    -- a refusal to land on a man who is already dizzy - a repeat request
    -- inside the stun is meant to come back as an ordinary punch, so a
    -- second press that "does the wrong move" is the guard working.
    -- debug4: 0x5040 started, 0x5041 connected (victim dizzy), 0x5042 blocked.
    { code = 17, name = "hamtop" },
    -- The ordinary BGPUNCH (kahn_debug_test code 8).  The ROM has always
    -- accepted this code; the list simply never offered it, because the
    -- harness was built for the restored SPECIALS.  It is here for the blood
    -- check: stk_sk_punch routes hits to r_kahn_fist, which spawns the
    -- uppercut spray, and the only way to tell that from the outside is to
    -- watch @blood_count across a landed swing.  Run it with -AllowP1Damage
    -- so the victim's health drop confirms contact - without that the rig
    -- tops him back up every frame and a whiff looks like a hit.
    { code = 8, name = "punch" },
    -- The GREEN PROJECTILE (kahn_debug_test code 18, do_kahn_eyeshot).  No
    -- round, health or cooldown gate, so a plain run fires it - but its own
    -- AI entry lives in rt_kahn_far only, so a run pinned at the default 72px
    -- is testing the move rather than the way Kahn actually throws it.  Pin
    -- wide (-PinPlayers -PinSpacing 208) to see it as a zoning tool.
    { code = 18, name = "eyeshot" },
    -- The THROAT SLAM (kahn_debug_test code 19, kahn_throat_slam).  Close band,
    -- the BIG P grab's box.  Verdict below: the two must have swapped sides
    -- and, with -AllowP1Damage, the victim must have lost kslam_damage (040h).
    -- KAHN_P1_CHAR=2 fights Cage, the fighter the lane was authored on.
    { code = 19, name = "throatslam" },
}

local moves = {}
local config_error = nil
if NORMAL_MATCH then
    -- no debug move requested; let the match run naturally
elseif LIVE_HOLD and CODE_LIST == "" then
    -- live harness triggers moves through hotkeys
elseif P2_PAD and CODE_LIST == "" then
    -- P2 pad drives Kahn; no scripted moves
elseif CODE_LIST == "" then
    config_error = "missing KAHN_TEST_CODE or KAHN_TEST_CODES"
else
    for token in CODE_LIST:gmatch("[^,%s]+") do
        local wanted_code = tonumber(token)
        local found = false
        for _, spec in ipairs(all_moves) do
            if spec.code == wanted_code or spec.name == token then
                moves[#moves + 1] = spec
                found = true
                break
            end
        end
        if not found then
            config_error = string.format("unknown Kahn move token '%s'", token)
            break
        end
    end
    if not config_error and #moves == 0 then
        config_error = string.format("no Kahn moves selected from '%s'", CODE_LIST)
    end
end

local fields, cpu, space = {}, nil, nil
local input_sys, hotkey_debounce = nil, {}
local last_gstate = -1
local charsel_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local did_direct_select = false
local did_bad_state = false
local current_move = 1
local move_start = 0
local move_ack = false
local move_done = false
local live_move_spec = nil
local next_move_frame = 0
local finished_frame = 0
local pin_ready = false
local pin_p1_x = 0
local pin_p2_x = 0
local normal_done = false
local normal_sonic_seen = false
local normal_sonic_contact_seen = false
local normal_sonic_frame = 0
local did_seed_kahn_health = false
local sonic_seen_wave = false
local sonic_seen_contact = false
local sonic_contact_debug4 = 0
local sonic_wave_snapshot = false
local last_debug4 = -1
-- Deliberately a global, not a local: this chunk is already near Lua's
-- 60-upvalue-per-closure ceiling and one more local upvalue in the move
-- watcher stops the whole script loading (MAME then sits on the ROM
-- warning screen forever with no error in its log).
pulp_frames = 0			-- frames since the portal-fatality breadcrumb
-- Globals for the same reason pulp_frames is one: check_move_progress is the
-- closure sitting on the upvalue ceiling, and these are read inside it.
hamtop_seen_dizzy = false	-- victim entered r_kahn_hamtop's stun
hamtop_dizzy_ended = false	-- ...and came back out of it
hamtop_dizzy_frame = 0
-- The stun ANIMATING is a separate question from the stun being ENTERED, and
-- the two came apart once already: p_action held act_speared_sd for the full
-- hold while the victim never drew a single frame of the stunned animation,
-- because a shake_him_up ahead of it ate the whole window.  Count the
-- distinct oimg values seen during the stun - 1 means it is a still pose.
hamtop_dizzy_imgs = 0
hamtop_last_img = -1
-- Per-frame action trace for the stun window.  The sampled move= lines are
-- ~20 frames apart, which is too coarse to see WHAT ended the stun - three
-- different theories survived that sampling rate.  This prints every change
-- of either fighter's p_action with both positions, so the transition out of
-- act_speared_sd is attributable rather than guessed at.
hamtop_last_p1a = -1
hamtop_last_p2a = -1
-- Blood watch for the punch run.  Globals for the same reason as the hamtop
-- state above: check_move_progress is the closure sitting on Lua's 60-upvalue
-- ceiling, and one more local upvalue there stops the whole script loading.
punch_blood_base = 0		-- @blood_count as the swing was requested
punch_blood_peak = 0		-- highest it reached during the swing
punch_hp_base = 0		-- victim health at the same moment
punch_hp_low = 0		-- ...and the lowest it got (contact evidence)
punch_verdict_done = false
-- Green-projectile watch.  Globals for the hamtop reason: check_move_progress
-- is called fresh every frame and keeps nothing of its own.
eye_before = {}                 -- objlst membership at the moment of request
eye_bolt_x0 = nil               -- where the star first appeared
eye_bolt_dx = 0                 -- ...and how far forward it got
-- EVERY new non-player object the move makes, not just the first one found.
-- a_sk_eyeshot now ends on `ani_sladd,KAHNGLOW` (MKSK.ASM), so the move puts
-- TWO objects on objlst: the muzzle flash, inserted during mframew, and the
-- star, inserted after it.  The old detector walked objlst, took the first
-- entry that was not there before, and broke - which after the flash landed
-- ahead of the star in the list meant it measured the FLASH and reported
-- star_never_moved while the star was flying and hitting for 35.
--
-- So identify them by BEHAVIOUR rather than by list order: the star is the
-- candidate that travels, the flash is a candidate that never moves and is
-- deleted before the verdict.  That is stable however insobj happens to
-- order them, and it survives any further effect object this move grows.
eye_cand = {}                   -- [obj] = {x0, dx, seen, last, gone}
eye_kahn_x0 = 0
eye_hp_base = 0
eye_hp_low = 0
eye_spawn_rel = -1
eye_hit_rel = -1
eye_verdict_done = false
EYE_HIT, EYE_BLOCK = 35, 6      -- stk_sk_eyeshot's damage word, 02306h

-- SOUND.  Tapped at the HARDWARE LATCH rather than listened to, the way
-- ermac_fireball_test.lua and kahn_fatality_audio_probe.lua do, so the run
-- asserts what the game SENT even under -sound none.  send_code_a3 writes a
-- track as two consecutive 16-bit hits on @sound, each byte OR'd with 0ff00h.
SND_PORT = 0x01d01030
SND_TAP_LO, SND_TAP_HI = 0x01d00000, 0x01d01fff
snd_tap, snd_hi = nil, nil
snd_trace = (os.getenv("KAHN_SNDTRACE") or "0") ~= "0"
snd_seen = 0
snd_log = {}                    -- tracks sent since the move was requested
-- What this move is supposed to send.
SND_CAST  = { [0x00d0]=1, [0x00d1]=2, [0x00d2]=3 }   -- ERMACSHOT triple, 10dh
-- triple_sndtab 0f1h/0f2h, "sk spear hit"/"sk spear blocked".  These are
-- TRIPLES like the cast: the table entry is a BASE track and triple_sound
-- picks whichever of the three channels is free, so base+0/+1/+2 all mean the
-- same sound played.  Measured $014c (base+2) on the first run, which is why
-- these are sets and not the single value they started as.
SND_HIT   = { [0x014a]=1, [0x014b]=2, [0x014c]=3 }
SND_BLOCK = { [0x014d]=1, [0x014e]=2, [0x014f]=3 }
ACT_SPEARED_SD = 0x0605		-- MAINEQU.ASM - the spear stun r_kahn_hamtop reuses
p1_action = nil			-- assigned below; global so the watcher can call it
local live_error_latch = false
local did_active_forensic = false
local player_summary, debug_objects
local r16, r32, w16, w32
local force_portal_fatality_victim

local function hx(value)
    if not value then return "na" end
    return string.format("0x%08x", value)
end

local function s16(value)
    value = value & 0xffff
    if value >= 0x8000 then return value - 0x10000 end
    return value
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["1 Player Start"] = true,
        ["P1 High Punch"] = true,
        ["P1 Block"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[kahn-test] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    local s = main_screen()
    if not s then return end
    local ok, err = pcall(function() s:snapshot() end)
    print(string.format("[kahn-test] SNAP frame=%d label=%s ok=%s %s",
        frame, label, tostring(ok), ok and "" or tostring(err)))
end

local function request_live_move(code, label)
    if not space or fighting_frame == 0 then
        print(string.format("[kahn-test] live_request_ignored move=%s reason=not_fighting", label))
        return
    end
    w16(A.debug4, 0)
    last_debug4 = -1
    if PORTAL_FATALITY and (label == "portal" or label == "hammer") then
        force_portal_fatality_victim()
        print(string.format("[kahn-test] seed_portal_fatality hp=%d/%d %s",
            PORTAL_FATAL_HP, MAX_HP, player_summary()))
    end
    w16(A.debug3, code)
    move_start = frame
    move_ack = false
    move_done = false
    live_move_spec = { code = code, name = label }
    sonic_seen_wave = false
    sonic_seen_contact = false
    sonic_contact_debug4 = 0
    sonic_wave_snapshot = false
    hamtop_seen_dizzy = false
    hamtop_dizzy_ended = false
    hamtop_dizzy_frame = 0
    hamtop_dizzy_imgs = 0
    hamtop_last_img = -1
    live_error_latch = false
    print(string.format("[kahn-test] live_request move=%s code=%d frame=%d %s",
        label, code, frame, player_summary()))
    debug_objects("live_" .. label .. "_request")
    snap("live_" .. label .. "_request")
end

local function live_dump(label)
    print(string.format("[kahn-test] live_dump label=%s frame=%d debug3=%d debug4=0x%04x %s",
        label, frame, r16(A.debug3), r16(A.debug4), player_summary()))
    debug_objects("live_" .. label)
    snap("live_" .. label)
end

local function hotkeys()
    if not input_sys then return end
    local bindings = {
        { "KEYCODE_1", function() request_live_move(1, "big_power") end },
        { "KEYCODE_2", function() request_live_move(2, "slam") end },
        { "KEYCODE_3", function() request_live_move(3, "sonic") end },
        { "KEYCODE_4", function() request_live_move(4, "portal") end },
        { "KEYCODE_5", function() request_live_move(5, "nupower") end },
        { "KEYCODE_6", function() request_live_move(16, "hammer") end },
        { "KEYCODE_7", function() request_live_move(17, "hamtop") end },
        { "KEYCODE_INSERT", function() request_live_move(6, "jump") end },
        { "KEYCODE_DEL", function() request_live_move(7, "fly") end },
        { "KEYCODE_PGUP", function() live_dump("manual") end },
        { "KEYCODE_HOME", function()
            live_error_latch = false
            print("[kahn-test] live_error_latch reset")
        end },
    }
    for _, hk in ipairs(bindings) do
        local code = input_sys:code_from_token(hk[1])
        local down = input_sys:code_pressed(code)
        if down and not hotkey_debounce[hk[1]] then hk[2]() end
        hotkey_debounce[hk[1]] = down
    end
end

-- ---------------------------------------------------------------------
-- P2 pad puppet control (KAHN_P2_PAD=1)
--
-- Command codes consumed by kahn_debug_test (MKBOSS.ASM):
--   1 big_power  2 slam  3 sonic  4 portal  5 nupower  6 jump  7 fly
--   8 punch  9 kick  10 uppercut  11 charge  12 zap  13 block
--   14 step toward  15 step back
--
-- Mapping (toward/away are relative to where P1 stands):
--   toward/away    walk           up             jump
--   HP             punch          down+HP        uppercut
--   toward+HP      charge         LP             zap
--   down+LP        big_power      HK             kick
--   toward+HK      portal         down+HK        sonic
--   LK             fly knee       down+LK        slam
--   BLK            block          down+BLK       nupower (heal)
-- ---------------------------------------------------------------------
local p2pad = {}
local p2pad_prev = {}
local p2pad_last_step_log = 0
local p2pad_last_posted = 0

local function cache_p2_fields()
    local want = {
        up = "Up", down = "Down", left = "Left", right = "Right",
        hp = "High Punch", lp = "Low Punch",
        hk = "High Kick", lk = "Low Kick", blk = "Block",
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            for key, base in pairs(want) do
                if not p2pad[key] then
                    local n = field.name
                    if n == ("P2 " .. base)
                       or (field.player == 1 and n:find(base, 1, true) ~= nil) then
                        p2pad[key] = { port = port, field = field }
                    end
                end
            end
        end
    end
    for key, base in pairs(want) do
        local hit = p2pad[key]
        print(string.format("[kahn-test] p2pad %-5s -> %s", key,
            hit and hit.field.name or "MISSING"))
    end
end

local function pad_down(key)
    local hit = p2pad[key]
    if not hit then return false end
    local v = hit.port:read()
    return ((v ~ hit.field.defvalue) & hit.field.mask) ~= 0
end

local function pad_edge(key)
    local now = pad_down(key)
    local was = p2pad_prev[key]
    p2pad_prev[key] = now
    return now and not was
end

local PUPPET_MAGIC = 0x50ad             -- kahn_stalk's puppet-mode gate value

local function p2_pad_update()

    -- edges must be sampled every frame so held buttons don't re-fire
    local e_hp = pad_edge("hp")
    local e_lp = pad_edge("lp")
    local e_hk = pad_edge("hk")
    local e_lk = pad_edge("lk")
    local e_blk = pad_edge("blk")
    local e_up = pad_edge("up")

    if r16(A.debug3) ~= 0 then return end   -- last command not consumed yet

    local p1o = r32(A.p1_obj)
    local p2o = r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local toward_right = r16(p1o + O.oxpos) > r16(p2o + O.oxpos)
    local held_down = pad_down("down")
    local held_toward = (toward_right and pad_down("right"))
        or (not toward_right and pad_down("left"))
    local held_away = (toward_right and pad_down("left"))
        or (not toward_right and pad_down("right"))

    local code, label
    if e_hp then
        if held_down then code, label = 10, "uppercut"
        elseif held_toward then code, label = 11, "charge"
        else code, label = 8, "punch" end
    elseif e_lp then
        if held_down then code, label = 1, "big_power"
        else code, label = 12, "zap" end
    elseif e_hk then
        if held_down then code, label = 3, "sonic"
        elseif held_toward then code, label = 4, "portal"
        else code, label = 9, "kick" end
    elseif e_lk then
        if held_down then code, label = 2, "slam"
        else code, label = 7, "fly" end
    elseif e_blk then
        if held_down then code, label = 5, "nupower"
        else code, label = 13, "block" end
    elseif e_up then
        code, label = 6, "jump"
    elseif held_toward then
        code, label = 14, "step_toward"
    elseif held_away then
        code, label = 15, "step_back"
    end

    if not code then return end
    w16(A.debug3, code)
    p2pad_last_posted = code
    if code < 14 then
        print(string.format("[kahn-test] p2pad_cmd %s code=%d frame=%d %s",
            label, code, frame, player_summary()))
    elseif frame - p2pad_last_step_log > 120 then
        p2pad_last_step_log = frame
        print(string.format("[kahn-test] p2pad_walk %s frame=%d", label, frame))
    end
end

-- KAHN_P2_SELFTEST=1 (with KAHN_P2_PAD=1): headless proof of the pad
-- chain.  Synthesizes P2 field presses, so the real mapping, debug3
-- posting, and MKBOSS dispatch all get exercised; exits with a
-- p2_selftest PASS/FAIL line.
local P2_SELFTEST = os.getenv("KAHN_P2_SELFTEST") == "1"
-- KAHN_P2_IDLE_WATCH=N: diagnostic - run pad mode with no input for N
-- fight frames, logging HP every second, then exit.
local P2_IDLE_WATCH = tonumber(os.getenv("KAHN_P2_IDLE_WATCH") or "0") or 0
local ST = { idx = 0, phase = "gap", at = 0, x0 = 0, fails = {} }
local st_seq = {
    { key = "left",  hold = 60, settle = 60,  label = "walk_toward", check = "moved", code = 14 },
    { key = "hp",    hold = 4,  settle = 150, label = "punch", code = 8 },
    { key = "up",    hold = 4,  settle = 150, label = "jump",  code = 6 },
    { key = "lk",    hold = 4,  settle = 180, label = "fly",   code = 7 },
    { key = "blk",   hold = 4,  settle = 150, label = "block", code = 13 },
    { key = "right", hold = 40, settle = 60,  label = "walk_back", check = "moved", code = 15 },
}

local function st_p2x()
    local p2o = r32(A.p2_obj)
    if p2o == 0 then return 0 end
    return r16(p2o + O.oxpos)
end

local function st_field(key, v)
    local hit = p2pad[key]
    if not hit then return end
    if v then hit.field:set_value(1) else hit.field:clear_value() end
end

local function p2_selftest_update()
    if ST.phase == "done" then return end
    if frame - fighting_frame < 60 then return end
    if ST.at == 0 then ST.at = frame + 30 end

    if ST.phase == "gap" then
        if frame < ST.at then return end
        ST.idx = ST.idx + 1
        local item = st_seq[ST.idx]
        if not item then
            local msg = (#ST.fails == 0) and "PASS"
                or ("FAIL " .. table.concat(ST.fails, ","))
            print("[kahn-test] p2_selftest " .. msg)
            print("[kahn-test] finished")
            ST.phase = "done"
            manager.machine:exit()
            return
        end
        p2pad_last_posted = 0
        ST.x0 = st_p2x()
        ST.phase = "hold"
        ST.at = frame + item.hold
        print(string.format("[kahn-test] p2_selftest step=%s key=%s frame=%d",
            item.label, item.key, frame))
    elseif ST.phase == "hold" then
        local item = st_seq[ST.idx]
        st_field(item.key, true)
        if frame >= ST.at then
            st_field(item.key, false)
            ST.phase = "settle"
            ST.at = frame + item.settle
        end
    elseif ST.phase == "settle" then
        if frame < ST.at then return end
        local item = st_seq[ST.idx]
        -- allow extra time for a queued command to be consumed
        if item.check ~= "moved" and r16(A.debug3) ~= 0
           and frame < ST.at + 240 then
            return
        end
        local ok
        if item.check == "moved" then
            local dx = st_p2x() - ST.x0
            ok = (p2pad_last_posted == item.code) and math.abs(dx) >= 8
        else
            ok = (p2pad_last_posted == item.code) and r16(A.debug3) == 0
        end
        print(string.format("[kahn-test] p2_selftest step=%s %s posted=%d debug3=%d %s",
            item.label, ok and "ok" or "FAIL", p2pad_last_posted,
            r16(A.debug3), player_summary()))
        if not ok then ST.fails[#ST.fails + 1] = item.label end
        snap("p2st_" .. item.label)
        ST.phase = "gap"
        ST.at = frame + 30
    end
end

local function pressed(name)
    -- Deliberately ABOVE the fighting_frame gate: this is the one input the
    -- rig drives during a fight rather than during the boot schedule.  Held
    -- from the request to well past the impact, so it covers the wind-up as
    -- well - a block that only goes up on the contact frame is not what a
    -- player does and would not exercise blocked_start the same way.
    if name == "P1 Block" then
        return BLOCK_VICTIM and move_start ~= 0 and (frame - move_start) < 120
    end
    if fighting_frame > 0 then return false end
    if charsel_frame > 0 and (name == "UI Select" or name == "Coin 1" or name == "1 Player Start") then
        return false
    end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    return false
end

r16 = function(addr) return space:read_u16(addr) end
r32 = function(addr) return space:read_u32(addr) end
w16 = function(addr, value) space:write_u16(addr, value & 0xffff) end
w32 = function(addr, value) space:write_u32(addr, value & 0xffffffff) end

local function count_objects()
    if not space then return 0 end
    local p = r32(A.objlst)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = r32(p + O.next)
    end
    return count
end

local function object_summary(limit)
    if not space then return "objs=[]" end
    local p = r32(A.objlst)
    local count = 0
    local parts = {}
    while p ~= 0 and count < (limit or 8) do
        parts[#parts + 1] = string.format(
            "%d:%s oid=%04x ch=%d xy=(%d,%d) z=%s img=%s shape=%s pal=%04x fl=%04x fl2=%04x",
            count + 1,
            hx(p),
            r16(p + O.oid),
            r16(p + O.ochar),
            r16(p + O.oxpos),
            s16(r16(p + O.oypos)),
            hx(r32(p + O.ozval)),
            hx(r32(p + O.oimg)),
            hx(r32(p + O.oshape)),
            r16(p + O.opal),
            r16(p + O.oflags),
            r16(p + O.oflags2))
        p = r32(p + O.next)
        count = count + 1
    end
    return "objs=[" .. table.concat(parts, " ; ") .. "]"
end

local function proc_summary(addr)
    if addr == 0 then return "none" end
    return string.format("proc=%s id=0x%04x action=0x%04x pa8=%s wake=%s t=%d",
        hx(addr), r16(addr + P.id), r16(addr + P.action), hx(r32(addr + P.pa8)),
        hx(r32(addr + P.wake)), r16(addr + P.time))
end

local function process_summary(limit)
    if not space then return "procs=[]" end
    local p = r32(A.active)
    local count = 0
    local parts = {}
    while p ~= 0 and count < (limit or 12) do
        parts[#parts + 1] = string.format(
            "%d:%s id=%04x t=%d wake=%s sp=%s pa8=%s pa9=%s a=%04x og=%s op=%s sl=%s s1=%s s2=%s s4=%s",
            count + 1,
            hx(p),
            r16(p + P.id),
            r16(p + P.time),
            hx(r32(p + P.wake)),
            hx(r32(p + P.sp)),
            hx(r32(p + P.pa8)),
            hx(r32(p + P.pa9)),
            r16(p + P.action),
            hx(r32(p + P.otherguy)),
            hx(r32(p + P.otherproc)),
            hx(r32(p + P.slave)),
            hx(r32(p + P.store1)),
            hx(r32(p + P.store2)),
            hx(r32(p + P.store4)))
        p = r32(p + P.next)
        count = count + 1
    end
    return "procs=[" .. table.concat(parts, " ; ") .. "]"
end

function player_summary()
    local p1o = r32(A.p1_obj)
    local p2o = r32(A.p2_obj)
    local p1p = r32(A.p1_proc)
    local p2p = r32(A.p2_proc)
    local p1x, p2x, p1y, p2y = 0, 0, 0, 0
    local p2img, p2ganiy, p2oyval, p2oyvel, p2grav = 0, 0, 0, 0, 0
    if p1o ~= 0 then
        p1x = r16(p1o + O.oxpos)
        p1y = s16(r16(p1o + O.oypos))
    end
    if p2o ~= 0 then
        p2x = r16(p2o + O.oxpos)
        p2y = s16(r16(p2o + O.oypos))
        p2img = r32(p2o + O.oimg)
        p2oyval = r32(p2o + O.oyval)
        p2oyvel = r32(p2o + O.oyvel)
        p2grav = r32(p2o + O.ograv)
    end
    if p2p ~= 0 then
        p2ganiy = r16(p2p + P.ganiy)
    end
    return string.format(
        "p1s=%d p2s=%d p1c=%d p2c=%d p1hp=%d/%d p2hp=%d/%d p1=(%d,%d) p2=(%d,%d) p2g=%d p2oy=%s p2yv=%s p2gr=%s p2img=%s objs=%d %s | %s",
        r16(A.p1_state), r16(A.p2_state), r16(A.p1_char), r16(A.p2_char),
        r16(A.p1_bar), r16(A.p1_bar_view), r16(A.p2_bar), r16(A.p2_bar_view),
        p1x, p1y, p2x, p2y, p2ganiy, hx(p2oyval), hx(p2oyvel), hx(p2grav),
        hx(p2img), count_objects(), proc_summary(p1p), proc_summary(p2p))
end

local function p2_action()
    local p2p = r32(A.p2_proc)
    if p2p == 0 then return 0xffff end
    return r16(p2p + P.action)
end

-- P1 is the VICTIM in this harness (Kahn is the P2 drone), so the dizzy the
-- over-the-top hammer is supposed to leave behind is read here, not from
-- p2_action.
function p1_action()
    local p1p = r32(A.p1_proc)
    if p1p == 0 then return 0xffff end
    return r16(p1p + P.action)
end

local function p2_position()
    local p2o = r32(A.p2_obj)
    if p2o == 0 then return 0, 0 end
    return r16(p2o + O.oxpos), s16(r16(p2o + O.oypos))
end

-- Latch tap.  Bytes arrive one per write and pair into a track number.
--
-- PARITY.  The bytes are a stream and sndres leaves an odd one in it at boot,
-- so blind pairing is a byte out for the whole run - which reads exactly like
-- the move sending nothing.  Re-lock the way tools/decode_sound_trace.py does:
-- a real MK2 track is $0000-$04ff, so a HIGH byte is always <= 7 and anything
-- bigger cannot start a pair.  Anything not wearing the 0ff00h tag is a
-- reset/strobe and re-locks it.
function on_sound_write(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    local code = (snd_hi << 8) | (w & 0xff)
    snd_hi = nil
    if move_start ~= 0 then
        snd_log[#snd_log + 1] = { t = frame - move_start, code = code }
    end
    if snd_trace and snd_seen < 400 then
        snd_seen = snd_seen + 1
        print(string.format("[kahn-test] snd frame=%d rel=%s SEND $%04x", frame,
            move_start ~= 0 and tostring(frame - move_start) or "-", code))
    end
    return data
end

-- Everything currently on the display list.  objlst is a 32-bit head pointer
-- (RAM.ASM) and each object's link at offset 0 is the next, terminated by 0.
-- Bounded so a corrupt list cannot hang the rig.  Used to find a projectile by
-- IDENTITY - what is on the list now that was not before the move - because a
-- multipart root carries osizex/osizey of zero and cannot be matched on size.
local function objset()
    local out, q, n = {}, r32(A.objlst), 0
    while q ~= 0 and n < 200 do
        out[q] = true
        q = r32(q + O.next)
        n = n + 1
    end
    return out
end

function debug_objects(label)
    if DEBUG_OBJECTS then
        print(string.format("[kahn-test] objects label=%s %s", label, object_summary(8)))
        print(string.format("[kahn-test] procs label=%s %s", label, process_summary(16)))
    end
end

local function seed_kahn_health()
    if did_seed_kahn_health then return end
    if r16(A.p2_char) ~= FT_KAHN then return end
    did_seed_kahn_health = true
    if UNLIMITED_HEALTH then
        w16(A.p2_bar, MAX_HP)
        w16(A.p2_bar_view, MAX_HP)
        print(string.format("[kahn-test] unlimited_kahn_health hp=%d/%d %s", MAX_HP, MAX_HP, player_summary()))
        return
    end
    w16(A.p2_bar, HALF_HP)
    w16(A.p2_bar_view, HALF_HP)
    print(string.format("[kahn-test] seed_kahn_health hp=%d/%d %s", HALF_HP, MAX_HP, player_summary()))
end

force_portal_fatality_victim = function()
    local p1o = r32(A.p1_obj)
    if p1o ~= 0 then
        w16(p1o + O.oflags2, r16(p1o + O.oflags2) | M_NOBLOCK)
    end
    w16(A.p1_bar, PORTAL_FATAL_HP)
    w16(A.p1_bar_view, PORTAL_FATAL_HP)
end

local function keep_players_alive(include_kahn)
    if not ALLOW_P1_DAMAGE then
        w16(A.p1_bar, MAX_HP)
        w16(A.p1_bar_view, MAX_HP)
    end
    if UNLIMITED_HEALTH or include_kahn then
        w16(A.p2_bar, MAX_HP)
        w16(A.p2_bar_view, MAX_HP)
    end
end

local function normal_match_progress()
    if finished_frame > 0 then return end

    local rel = frame - fighting_frame
    local debug4_value = r16(A.debug4)
    if debug4_value ~= last_debug4 then
        print(string.format("[kahn-test] normal_debug4_change rel=%d debug4=0x%04x %s",
            rel, debug4_value, player_summary()))
        last_debug4 = debug4_value
    end

    local sonic_debug_ok = debug4_value == 0x5003 or debug4_value == 0x5004
        or debug4_value == 0x5005 or debug4_value == 0x5006
        or debug4_value == 0x5010 or debug4_value == 0x5011
        or debug4_value == 0x501f
    if not normal_sonic_seen and sonic_debug_ok then
        normal_sonic_seen = true
        normal_sonic_frame = frame
        print(string.format("[kahn-test] normal_sonic_seen rel=%d debug4=0x%04x %s",
            rel, debug4_value, player_summary()))
        debug_objects("normal_sonic_seen")
        snap("normal_sonic_seen")
        return
    end

    if normal_sonic_seen and not normal_sonic_contact_seen
       and (debug4_value == 0x5005 or debug4_value == 0x5006) then
        normal_sonic_contact_seen = true
        print(string.format("[kahn-test] normal_sonic_contact rel=%d debug4=0x%04x %s",
            rel, debug4_value, player_summary()))
        debug_objects("normal_sonic_contact")
        snap("normal_sonic_contact")
        finished_frame = frame
        print("[kahn-test] finished")
        return
    end

    if normal_sonic_seen and not normal_sonic_contact_seen
       and normal_sonic_frame > 0 and frame - normal_sonic_frame > 18 then
        print(string.format("[kahn-test] normal_sonic_followup rel=%d debug4=0x%04x %s",
            rel, debug4_value, player_summary()))
        debug_objects("normal_sonic_followup")
        snap("normal_sonic_followup")
        finished_frame = frame
        print("[kahn-test] finished")
        return
    end

    if rel == 1 or rel == 60 or rel == 180 or rel == 360 or rel == 600 or rel == 900 then
        print(string.format("[kahn-test] normal_match rel=%d %s", rel, player_summary()))
        snap("normal_match_" .. tostring(rel))
    end

    if rel > 900 and not normal_done then
        normal_done = true
        finished_frame = frame
        snap("normal_match_done")
        print("[kahn-test] normal_match finished")
        print("[kahn-test] finished")
    end
end

local function force_kahn_ladder()
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, P1_CHAR)
    w16(A.p2_char, FT_KAHN)
    w16(A.curback, KAHN_ARENA)
    w16(A.map_position, 14)
    w16(A.battle_num, 15)
    if P2_PAD or PUPPET_HOLD then
        -- puppet flag must be up BEFORE the round intro: Kahn's brain
        -- enters kahn_stalk during the intro, and without this he gets
        -- one free AI attack in before the fight gstate arrives.
        w16(A.debug2, PUPPET_MAGIC)
    end
    if not did_direct_select then
        did_direct_select = true
        print(string.format("[kahn-test] direct_select frame=%d p1=%d p2=%d curback=%d map_position=%d",
            frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback), r16(A.map_position)))
    end
end

local function pin_players()
    local p1o = r32(A.p1_obj)
    local p2o = r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then
        keep_players_alive(true)
        return
    end

    if not pin_ready then
        local p1x = r16(p1o + O.oxpos)
        local p2x = r16(p2o + O.oxpos)
        if p1x == 0 or p2x == 0 then
            keep_players_alive(true)
            return
        end

        if PIN_KAHN_ONLY then
            -- Leave him where he already is.  Re-centring the pair would
            -- teleport Kahn on the first pinned frame, and the point of this
            -- mode is that only P1 moves.
            pin_p1_x = p1x
            pin_p2_x = p2x
        else
            -- KAHN_PIN_SPACING: distance in PIXELS to hold the pair at.
            -- Defaults to the historic 72.  This is how a move's real reach
            -- gets measured rather than guessed: pin at a series of gaps and
            -- read whether the strike breadcrumb says hit or whiff.  A move
            -- whose own range gate refuses beyond N will simply not start,
            -- which is itself the answer.
            local half = (tonumber(os.getenv("KAHN_PIN_SPACING") or "72") or 72) // 2
            local mid = (p1x + p2x) // 2
            pin_p1_x = mid - half
            pin_p2_x = mid + half
        end
        pin_ready = true
        print(string.format("[kahn-test] pin_targets source_p1=%d source_p2=%d target_p1=%d target_p2=%d spacing=%d kahn_only=%s",
            p1x, p2x, pin_p1_x, pin_p2_x, pin_p2_x - pin_p1_x, tostring(PIN_KAHN_ONLY)))
    end

    -- The escape.  Fired once, and only after the move has had time to get
    -- past its stalk - see KAHN_PIN_ESCAPE at the top of this file.  Only the
    -- victim moves; Kahn keeps the position he swung from, so what is being
    -- tested is the strike missing, not Kahn being teleported out of his own
    -- animation.
    if PIN_ESCAPE_PX > 0 and not PIN_ESCAPE_DONE
       and move_start ~= 0 and frame - move_start >= PIN_ESCAPE_DELAY then
        PIN_ESCAPE_DONE = true
        if pin_p1_x < pin_p2_x then
            pin_p1_x = pin_p1_x - PIN_ESCAPE_PX
        else
            pin_p1_x = pin_p1_x + PIN_ESCAPE_PX
        end
        print(string.format("[kahn-test] pin_escape frame=%d p1->%d p2=%d spacing=%d",
            frame, pin_p1_x, pin_p2_x, math.abs(pin_p2_x - pin_p1_x)))
    end

    if not PIN_KAHN_ONLY then
        w32(p1o + O.oxval, pin_p1_x << 16)
        w16(p1o + O.oxpos, pin_p1_x)
    end
    w32(p2o + O.oxval, pin_p2_x << 16)
    w16(p2o + O.oxpos, pin_p2_x)
    keep_players_alive(true)
end

local function start_next_move()
    local spec = moves[current_move]
    if not spec then
        if finished_frame == 0 then
            finished_frame = frame
            snap("all_moves_done")
            print("[kahn-test] all restored Kahn moves requested")
            print("[kahn-test] finished")
        end
        return
    end

    if PIN_PLAYERS then pin_players() end
    seed_kahn_health()
    if PORTAL_FATALITY and (spec.name == "portal" or spec.name == "hammer") then
        force_portal_fatality_victim()
        print(string.format("[kahn-test] seed_portal_fatality hp=%d/%d %s",
            PORTAL_FATAL_HP, MAX_HP, player_summary()))
    end
    move_start = frame
    move_ack = false
    move_done = false
    w16(A.debug4, 0)
    last_debug4 = -1
    sonic_seen_wave = false
    sonic_seen_contact = false
    sonic_contact_debug4 = 0
    sonic_wave_snapshot = false
    hamtop_seen_dizzy = false
    hamtop_dizzy_ended = false
    hamtop_dizzy_frame = 0
    hamtop_dizzy_imgs = 0
    hamtop_last_img = -1
    punch_blood_base = r16(A.blood_count)
    punch_blood_peak = punch_blood_base
    punch_hp_base = r16(A.p1_bar)
    punch_hp_low = punch_hp_base
    punch_verdict_done = false
    -- Snapshot the object list BEFORE the request so the star can be found by
    -- identity rather than geometry.  The projectile's root object carries
    -- osizex/osizey of zero (the pieces hold the art), so matching on frame
    -- size can never hit - that cost ermac_fireball_test.lua a whole run.
    eye_before = objset()
    eye_bolt_x0 = nil
    eye_bolt_dx = 0
    eye_cand = {}
    eye_kahn_x0 = s16(select(1, p2_position()))
    eye_hp_base = r16(A.p1_bar)
    eye_hp_low = eye_hp_base
    eye_spawn_rel = -1
    eye_hit_rel = -1
    eye_verdict_done = false
    snd_log = {}
    w16(A.debug3, spec.code)
    print(string.format("[kahn-test] request move=%s code=%d frame=%d %s",
        spec.name, spec.code, frame, player_summary()))
    debug_objects(spec.name .. "_request")
    snap(spec.name .. "_request")
end

local function finish_live_move()
    current_move = current_move + 1
    live_move_spec = nil
    move_start = 0
    move_ack = false
    move_done = false
    next_move_frame = frame + MOVE_START_DELAY
end

local function check_move_progress()
    if finished_frame > 0 and not LIVE_HOLD then return end

    local spec = nil
    if LIVE_HOLD and live_move_spec then
        spec = live_move_spec
    else
        if current_move > #moves then return end
        spec = moves[current_move]
    end
    local rel = frame - move_start
    local debug_value = r16(A.debug3)
    local debug4_value = r16(A.debug4)
    local action = p2_action()
    -- Do NOT re-seed once the finisher is under way.  This tops the victim's
    -- health back up every frame, and 0x5031 (Kahn's victory laugh) is not in
    -- the exclusion list - so the rig kept reviving him after the kill and the
    -- round could never end, which looked exactly like the win screen being
    -- broken.
    if PORTAL_FATALITY and (spec.name == "portal" or spec.name == "hammer")
       and debug4_value ~= 0x5020 and debug4_value ~= 0x5030
       and debug4_value ~= 0x5031 then
        force_portal_fatality_victim()
    end

    if debug4_value ~= last_debug4 then
        print(string.format("[kahn-test] debug4_change move=%s rel=%d debug4=0x%04x debug5=0x%08x %s",
            spec.name, rel, debug4_value, r32(A.debug5), player_summary()))
        last_debug4 = debug4_value
    end

    if not move_ack and debug_value == 0 then
        move_ack = true
        -- KAHN_P1_HP=<n>: drop the victim to n health on the ack, so the move
        -- (with -AllowP1Damage) ends the round and Kahn's victory runs.
        local seed_hp = tonumber(os.getenv("KAHN_P1_HP") or "")
        if seed_hp then
            w16(A.p1_bar, seed_hp)
            w16(A.p1_bar_view, seed_hp)
        end
        print(string.format("[kahn-test] ack move=%s rel=%d %s",
            spec.name, rel, player_summary()))
        debug_objects(spec.name .. "_ack")
        snap(spec.name .. "_ack")
    end

    if move_ack and not move_done and (spec.name == "jump" or spec.name == "fly") and rel > 12 then
        local _, p2y = p2_position()
        if p2y < -128 or p2y > 320 then
            print(string.format("[kahn-test] ERROR move_offscreen move=%s rel=%d y=%d action=0x%04x %s",
                spec.name, rel, p2y, action, player_summary()))
            snap(spec.name .. "_offscreen")
            if LIVE_HOLD then
                live_error_latch = true
                live_move_spec = nil
                move_start = 0
                move_ack = false
                move_done = false
                return
            end
            manager.machine:exit()
            return
        end

        local airborne_action = (spec.name == "jump") and ACT_JUMPUP or ACT_ANGLE_JUMP
        if action ~= airborne_action then
            move_done = true
            print(string.format("[kahn-test] complete move=%s rel=%d action=0x%04x %s",
                spec.name, rel, action, player_summary()))
            snap(spec.name .. "_complete")
        elseif rel > 240 then
            print(string.format("[kahn-test] ERROR move_stuck_airborne move=%s rel=%d action=0x%04x %s",
                spec.name, rel, action, player_summary()))
            snap(spec.name .. "_stuck_airborne")
            if LIVE_HOLD then
                live_error_latch = true
                live_move_spec = nil
                move_start = 0
                move_ack = false
                move_done = false
                return
            end
            manager.machine:exit()
            return
        end
    end

    -- BGPUNCH blood watch.  @blood_count rises as upcutted_blood's drips and
    -- the two spray halves are allocated and falls again as they expire, so
    -- the peak is the only reading that survives sampling; the health floor
    -- separates "landed dry" from "never touched him".
    if spec.name == "punch" then
        local bc = r16(A.blood_count)
        if bc > punch_blood_peak then punch_blood_peak = bc end
        local hp = r16(A.p1_bar)
        if hp < punch_hp_low then punch_hp_low = hp end

        if not punch_verdict_done and move_ack and rel >= 150 then
            punch_verdict_done = true
            local spray = punch_blood_peak - punch_blood_base
            local dmg = punch_hp_base - punch_hp_low
            local verdict
            if r16(A.f_no_blood) ~= 0 then
                verdict = "INCONCLUSIVE (blood switched off at the DIP)"
            elseif dmg <= 0 then
                verdict = "INCONCLUSIVE (punch never connected)"
            elseif spray > 0 then
                verdict = "PASS (hit drew blood)"
            else
                verdict = "FAIL (hit landed dry)"
            end
            print(string.format(
                "[kahn-test] punch_blood %s rel=%d blood_base=%d blood_peak=%d spray=%d hp=%d->%d dmg=%d",
                verdict, rel, punch_blood_base, punch_blood_peak, spray,
                punch_hp_base, punch_hp_low, dmg))
            snap("punch_blood")
        end
    end

    -- GREEN PROJECTILE.  Five things have to be true and "the animation looked
    -- right" is not one of them: the star has to EXIST as an object, appear in
    -- FRONT of him, TRAVEL the way he is facing, take exactly stk_sk_eyeshot's
    -- damage off the victim, and leave Kahn out of the move.
    --
    -- The direction test is the one that earns its keep.  A star that spawns
    -- and sits still is set_proj_vel never running; one that goes backwards is
    -- the b_fliph branch inside it reading the wrong object.  Both draw a
    -- perfectly good sprite, and a rig that only checked "damage happened"
    -- would pass either.
    if spec.name == "eyeshot" then
        local hp = r16(A.p1_bar)
        if hp < eye_hp_low then eye_hp_low = hp end

        if move_ack then
            local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
            local p, n = r32(A.objlst), 0
            local live = {}
            while p ~= 0 and n < 200 do
                if not eye_before[p] and p ~= p1o and p ~= p2o then
                    local bx = s16(r16(p + O.oxpos))
                    local c = eye_cand[p]
                    if not c then
                        c = { x0 = bx, dx = 0, seen = rel }
                        eye_cand[p] = c
                        print(string.format(
                            "[kahn-test] eyeshot_obj rel=%d obj=0x%08x x=%d kahn_x=%d lead=%d",
                            rel, p, bx, eye_kahn_x0, bx - eye_kahn_x0))
                        if not eye_bolt_x0 then
                            eye_bolt_x0 = bx
                            eye_spawn_rel = rel
                            snap("eyeshot_spawn")
                        end
                    else
                        local dx = bx - c.x0
                        if math.abs(dx) > math.abs(c.dx) then c.dx = dx end
                    end
                    c.last = rel
                    live[p] = true
                end
                p = r32(p + O.next); n = n + 1
            end
            -- anything we were tracking that has left objlst is gone; the
            -- muzzle flash is supposed to, delete_slave takes it at rel ~19.
            for q, c in pairs(eye_cand) do
                if not live[q] and not c.gone then c.gone = rel end
            end

            if eye_hit_rel < 0 and eye_hp_base - eye_hp_low > 0 then
                eye_hit_rel = rel
                snap("eyeshot_hit")
            end
        end

        if not eye_verdict_done and move_ack and rel >= 150 then
            eye_verdict_done = true
            local dmg = eye_hp_base - eye_hp_low
            -- Kahn faces LEFT at P2, so forward is -x. Read the facing off his
            -- own object rather than assuming it.
            local ko = r32(A.p2_obj)
            local left = (ko ~= 0) and ((r16(ko + O.oflags) >> 4) & 1) == 1
            local forward = left and (eye_bolt_dx < 0) or ((not left) and eye_bolt_dx > 0)
            local fails = {}
            -- Sort the move's objects out by what they DID.  The star is the
            -- one that travelled; the muzzle flash is one that never moved
            -- and was deleted before the verdict.  See eye_cand's note.
            local star, flash, ncand = nil, nil, 0
            for _, c in pairs(eye_cand) do
                ncand = ncand + 1
                if not star or math.abs(c.dx) > math.abs(star.dx) then star = c end
            end
            for _, c in pairs(eye_cand) do
                if c ~= star and c.dx == 0 and c.gone then flash = c end
            end
            if star then
                eye_bolt_x0, eye_bolt_dx = star.x0, star.dx
                eye_spawn_rel = star.seen
                forward = left and (eye_bolt_dx < 0) or ((not left) and eye_bolt_dx > 0)
            end
            if not eye_bolt_x0 then fails[#fails+1] = "no_star" end
            if eye_bolt_dx == 0 then fails[#fails+1] = "star_never_moved"
            elseif not forward then fails[#fails+1] = "star_went_backwards" end
            -- THE MUZZLE FLASH is part of the move now, so its absence is a
            -- failure and not a curiosity: `ani_sladd,KAHNGLOW` at the end of
            -- a_sk_eyeshot is what MK3 left commented out.  It has to appear
            -- AND be taken away again - a flash still on objlst at the
            -- verdict is delete_slave not running, which leaks an object and
            -- a colour map every time he throws.
            if not flash then
                fails[#fails+1] = string.format("no_muzzle_flash(cands=%d)", ncand)
            end
            -- With BLOCK_VICTIM the chip number is the ONLY acceptable one:
            -- letting a run "pass" on 35 while asking for a block is how a
            -- blocked-path test quietly becomes a second hit test.
            local want = BLOCK_VICTIM and EYE_BLOCK or EYE_HIT
            if dmg ~= want then
                fails[#fails+1] = string.format("damage=%d(want %d)", dmg, want)
            end
            if BLOCK_VICTIM and impact_code and SND_HIT[impact_code] then
                fails[#fails+1] = "blocked_but_hit_sound"
            end
            -- AUDIO, asserted from the latch rather than assumed.  Two
            -- separate claims: the CAST fired ERMACSHOT (the clip UMK3 uses
            -- for this very shot) and the IMPACT fired something.  `tsound`
            -- loads its argument into a0 through a macro, so a wired-looking
            -- source line is not evidence the track went out.
            local cast_code, impact_code, sent = nil, nil, {}
            for _, e in ipairs(snd_log) do
                sent[#sent+1] = string.format("$%04x@%d", e.code, e.t)
                if SND_CAST[e.code] and not cast_code then cast_code = e.code end
                if (SND_HIT[e.code] or SND_BLOCK[e.code]) and not impact_code then
                    impact_code = e.code
                end
            end
            if not cast_code then fails[#fails+1] = "no_cast_sound" end
            if dmg > 0 and not impact_code then fails[#fails+1] = "no_impact_sound" end
            print(string.format(
                "[kahn-test] eyeshot %s rel=%d spawn_rel=%d lead=%s travel=%d facing=%s hit_rel=%d hp=%d->%d dmg=%d cast=%s impact=%s flash=%s",
                (#fails == 0) and "PASS" or ("FAIL " .. table.concat(fails, ",")),
                rel, eye_spawn_rel,
                eye_bolt_x0 and tostring(eye_bolt_x0 - eye_kahn_x0) or "n/a",
                eye_bolt_dx, left and "left" or "right", eye_hit_rel,
                eye_hp_base, eye_hp_low, dmg,
                cast_code and string.format("$%04x", cast_code) or "NONE",
                impact_code and string.format("$%04x", impact_code) or "NONE",
                flash and string.format("rel%d-%d", flash.seen, flash.gone) or "NONE"))
            print("[kahn-test] eyeshot_tracks " .. table.concat(sent, " "))
            snap("eyeshot_verdict")
        end
    end

    -- Live process-pool census.  A move that holds a lot of processes across
    -- the round start can starve bonus_count's own `create`, and getprc
    -- failing there hands `kill` a null pointer - which takes the MAIN game
    -- process out and leaves the dispatcher spinning with gstate stuck.
    -- Follow the MASTER process (pid_master = 3) through the round end.  It is
    -- the one that `jsrp bonus_count`, so if gstate parks at gs_bonus the
    -- answer is in its wake address (where it is parked) and its time field
    -- (whether the sleep is counting down at all).
    if PROC_CENSUS then
        local q, master = r32(A.active), 0
        while q ~= 0 and q >= 0x01000000 and q < 0x01200000 do
            if r16(q + P.id) == 3 then master = q break end
            q = r32(q + P.next)
        end
        if master ~= 0 then
            local w, t = r32(master + P.wake), r16(master + P.time)
            if w ~= last_master_wake then
                print(string.format("[kahn-test] master frame=%d rel=%d gstate=%d wake=0x%08x time=%d",
                    frame, rel, r16(A.gstate), w, t))
                last_master_wake = w
                master_stuck_since = frame
            elseif frame - master_stuck_since == 240 then
                print(string.format("[kahn-test] master STUCK 240 frames at wake=0x%08x time=%d gstate=%d",
                    w, t, r16(A.gstate)))
            end
        end
    end

    -- Per-FRAME integrity walk of the active process list.  A census every ten
    -- ticks tells you the list broke somewhere in a ten-tick window; this says
    -- which link went bad, on which frame, and what the process on either side
    -- of it was - which is the difference between bisecting builds and reading
    -- the answer off the log.  RAM is 0x01000000..0x01200000; anything else in
    -- a `next` pointer is garbage.
    if PROC_CENSUS and not census_dumped then
        local p, n, prev = r32(A.active), 0, 0
        while p ~= 0 and n < 80 do
            if p < 0x01000000 or p >= 0x01200000 then
                census_dumped = true
                print(string.format(
                    "[kahn-test] PROCLIST BROKE frame=%d rel=%d gstate=%d: link %d = 0x%08x",
                    frame, rel, r16(A.gstate), n, p))
                if prev ~= 0 then
                    print(string.format(
                        "[kahn-test]   previous proc=0x%08x id=0x%04x a=0x%04x pa8=0x%08x wake=0x%08x",
                        prev, r16(prev + P.id), r16(prev + P.action),
                        r32(prev + P.pa8), r32(prev + P.wake)))
                end
                local q, i = r32(A.active), 0
                while q ~= 0 and i < 20 and q >= 0x01000000 and q < 0x01200000 do
                    i = i + 1
                    print(string.format("[kahn-test]   %02d proc=0x%08x id=0x%04x a=0x%04x pa8=0x%08x",
                        i, q, r16(q + P.id), r16(q + P.action), r32(q + P.pa8)))
                    q = r32(q + P.next)
                end
                break
            end
            prev = p
            p = r32(p + P.next)
            n = n + 1
        end
    end

    if PROC_CENSUS and (rel % 10) == 0 then
        local p, n = r32(A.active), 0
        while p ~= 0 and n < 64 do n = n + 1; p = r32(p + P.next) end
        print(string.format("[kahn-test] census rel=%d active_procs=%d gstate=%d",
            rel, n, r16(A.gstate)))
        -- Runaway = the walk hit its own limit, i.e. the active list has
        -- either grown past anything sane or looped back on itself.  Dump the
        -- links so a cycle can be told from a genuine flood.
        if n >= 40 and not census_dumped then
            census_dumped = true
            local q, seen, i = r32(A.active), {}, 0
            while q ~= 0 and i < 24 do
                i = i + 1
                print(string.format("[kahn-test]   proc%02d=0x%08x id=0x%04x a=0x%04x pa8=0x%08x wake=0x%08x%s",
                    i, q, r16(q + P.id), r16(q + P.action), r32(q + P.pa8),
                    r32(q + P.wake), seen[q] and "  <== CYCLE" or ""))
                if seen[q] then break end
                seen[q] = true
                q = r32(q + P.next)
            end
        end
    end

    -- Colour-map trace.  CRAM is bit-addressed the way pal_xfer builds it
    -- (PALL.ASM, tunit branch): colram + (([pal:8|startcol:8]) << 4), so
    -- entry i of palette P sits at colram + (P*256 + i)*16.  opal holds that
    -- same [#,#] pair, so the palette number is opal >> 8.
    if PAL_TRACE then
        local o = r32(A.p2_obj)          -- Kahn is P2 in this rig
        if o ~= 0 then
            local opal = r16(o + O.opal)
            local pbase = 0x01800000 + ((opal >> 8) * 256) * 16
            local c = {}
            for _, i in ipairs({8, 16, 40, 63}) do
                c[#c + 1] = string.format("c%02d=%04X", i, r16(pbase + i * 16))
            end
            -- First multipart piece's SAG names the frame on screen, so the
            -- log says WHICH art the palette is paired with, not just that
            -- the palette moved.
            local sag = 0
            local ram = r32(o + O.oimg)
            if ram ~= 0 then sag = ram ~= 0 and (r32(ram) % 0x1000000) or 0 end
            -- Both players' positions ride along, so the same per-tick line
            -- shows the BIG P victim's hold: dx from Kahn and the rattle in y.
            local v = r32(A.p1_obj)
            local vx, vy = 0, 0
            if v ~= 0 then
                vx = r16(v + O.oxpos)
                vy = s16(r16(v + O.oypos))
            end
            print(string.format("[pal] rel=%d debug4=0x%04x opal=0x%04x sag=%06x %s k=(%d,%d) v=(%d,%d)",
                rel, debug4_value, opal, sag, table.concat(c, " "),
                r16(o + O.oxpos), s16(r16(o + O.oypos)), vx, vy))
        end
    end

    if rel == 1 or rel == 5 or rel == 10 or rel == 20 or rel == 40
       or rel == 60 or rel == 90 or rel == 120 or rel == 180 or rel == 240 then
        print(string.format("[kahn-test] move=%s rel=%d debug3=%d debug4=0x%04x %s",
            spec.name, rel, debug_value, debug4_value, player_summary()))
        debug_objects(spec.name .. "_" .. tostring(rel))
        snap(spec.name .. "_" .. tostring(rel))
    end

    -- The FISTPULP burst (r_kahn_fist_pulp) is ten frames at three ticks each,
    -- so it is over inside ~30 frames and the schedule above only ever catches
    -- one of them.  Alignment work needs every frame of the arc, so snap
    -- densely once the fatal breadcrumb is up.
    -- Per-TICK position trace through the finisher.  Snapshot-rate sampling
    -- is far too coarse to see a one-or-two-frame wobble; this prints every
    -- frame the fatality is running so a positional shift can be told from
    -- the art simply animating.
    if spec.name == "hammer" and (debug4_value == 0x5030 or debug4_value == 0x5031) then
        local o = r32(A.p1_obj)
        if o ~= 0 then
            local y = r16(o + O.oypos)
            if y >= 32768 then y = y - 65536 end
            local x = r16(o + O.oxpos)
            if x >= 32768 then x = x - 65536 end
            print(string.format("[trace] f=%d x=%d y=%d shape=0x%08x scale=0x%08x",
                pulp_frames, x, y, r32(o + O.oshape), r32(o + 0x180)))
        end
    end

    -- Dump the victim's multipart RAM at the frames the flat-block artifact
    -- shows on, so a bad SAG/size can be told from a bad placement.
    if spec.name == "hammer" and debug4_value == 0x5030
       and (pulp_frames == 40 or pulp_frames == 56 or pulp_frames == 62) then
        local o = r32(A.p1_obj)
        if o ~= 0 then
            print(string.format("[mp] frame=%d obj=0x%08x oscale=0x%08x oflags2=0x%04x oimg=0x%08x",
                pulp_frames, o, r32(o + 0x180), r16(o + O.oflags2), r32(o + O.oimg)))
            local ram = r32(o + O.oimg)
            for pc = 0, 7 do
                local base = ram + pc * 112
                local sag = r32(base)
                if sag == 0 then print(string.format("[mp]   piece %d: END", pc)) break end
                print(string.format("[mp]   piece %d sag=0x%08x size=0x%08x ctrl=0x%04x dx=%d dy=%d",
                    pc, sag, r32(base + 32), r16(base + 64),
                    (r16(base + 80) + 32768) % 65536 - 32768,
                    (r16(base + 96) + 32768) % 65536 - 32768))
            end
        end
    end

    -- KAHN_SNAP_ENTRY=1: also snap densely from the move being acknowledged.
    -- The pulp window below only opens on the FATAL breadcrumb, which is after
    -- the arm has already landed - useless when what is under review is the
    -- arm coming DOWN (the Portal Punch's banded entry).  Off by default: it
    -- multiplies the snapshot count, and a snapshot flood starves the host
    -- sound device, so never leave this on for an audio run.
    if SNAP_ENTRY and rel >= 1 and rel <= 400 and (rel % SNAP_EVERY) == 0 then
        snap(string.format("entry_%03d", rel))
    end

    -- Throat slam watch: trace both fighters through the lane, then judge.
    if spec.name == "throatslam" and move_ack then
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        local p1x = (p1o ~= 0) and s16(r16(p1o + O.oxpos)) or 0
        local p2x = (p2o ~= 0) and s16(r16(p2o + O.oxpos)) or 0
        if kslam_side0 == nil then
            kslam_side0 = (p1x < p2x) and -1 or 1
            kslam_hp0 = r16(A.p1_bar)
        end
        if rel <= 200 and (rel % 4) == 0 then
            print(string.format("[kahn-test] kslam rel=%d p1x=%d p2x=%d hp=%d %s",
                rel, p1x, p2x, r16(A.p1_bar), player_summary()))
        end
        if rel == 240 and not kslam_judged then
            kslam_judged = true
            local side = (p1x < p2x) and -1 or 1
            local dmg = kslam_hp0 - r16(A.p1_bar)
            local swapped = side ~= kslam_side0
            local ok = swapped and ((not ALLOW_P1_DAMAGE) or dmg == 0x40)
            print(string.format("[kahn-test] throatslam %s swapped=%s dmg=%d p1x=%d p2x=%d",
                ok and "PASS" or "FAIL", tostring(swapped), dmg, p1x, p2x))
            snap("throatslam_verdict")
        end
    end

    if PORTAL_FATALITY and (spec.name == "portal" or spec.name == "hammer") then
        -- 0x5031 is Kahn's victory laugh, which OVERWRITES the fatality
        -- breadcrumb - so gating only on 0x5030 stopped the capture before
        -- the win screen and the FATALITY reveal ever appeared.
        if debug4_value == 0x5020 or debug4_value == 0x5030
           or debug4_value == 0x5031 then
            pulp_frames = pulp_frames + 1
            -- 45 frames covered the FISTPULP burst; the hammer smash's
            -- victim sequence (pose + PITFALL1-5 x3 + PITFALL6) runs about
            -- 65 ticks, so the window has to be longer than the burst's.
            -- The hammer fatality now runs well past 120 ticks (hold on the
            -- glass + slow ooze + the FATALITY reveal), and the old window
            -- stopped capturing before the ending it was meant to verify.
            if pulp_frames <= 900 and (pulp_frames % SNAP_EVERY) == 1 then
                snap(string.format("pulp_%03d", pulp_frames))
            end
        end
    end

    if spec.name == "sonic" then
        local wave_debug_ok = debug4_value == 0x5003 or debug4_value == 0x5004
            or debug4_value == 0x5005 or debug4_value == 0x5006
            or debug4_value == 0x5010 or debug4_value == 0x5011
            or debug4_value == 0x501f
        if count_objects() > 2 or wave_debug_ok then
            sonic_seen_wave = true
            if not sonic_wave_snapshot then
                sonic_wave_snapshot = true
                print(string.format("[kahn-test] sonic_wave_seen rel=%d debug4=0x%04x %s",
                    rel, debug4_value, player_summary()))
                debug_objects("sonic_wave_seen")
                snap("sonic_wave_seen")
            end
        end

        if debug4_value == 0x5005 or debug4_value == 0x5006 then
            sonic_seen_contact = true
            sonic_contact_debug4 = debug4_value
        end

        if rel == 120 then
            if not sonic_seen_wave then
                print(string.format("[kahn-test] ERROR sonic_wave_missing debug4=0x%04x %s",
                    debug4_value, player_summary()))
                debug_objects("sonic_wave_missing")
                snap("sonic_wave_missing")
                if LIVE_HOLD then
                    live_error_latch = true
                    finish_live_move()
                    return
                end
                manager.machine:exit()
                return
            end
            if not sonic_seen_contact then
                print(string.format("[kahn-test] ERROR sonic_contact_missing debug4=0x%04x %s",
                    debug4_value, player_summary()))
                debug_objects("sonic_contact_missing")
                snap("sonic_contact_missing")
                if LIVE_HOLD then
                    live_error_latch = true
                    finish_live_move()
                    return
                end
                manager.machine:exit()
                return
            end
            print(string.format("[kahn-test] sonic contact ok debug4=0x%04x current=0x%04x",
                sonic_contact_debug4, debug4_value))
            print("[kahn-test] finished")
            if LIVE_HOLD then
                finish_live_move()
                return
            end
            manager.machine:exit()
            return
        end
    end

    -- The hammer swing is only ~12 ticks between the stalk finishing and
    -- the contact frame, and the rel schedule above steps 40 -> 60 -> 90
    -- straight over it.  Catch every other tick so BGFATHAM1-7 and the
    -- BGHAMSWIPE blur can be checked frame by frame.
    if spec.name == "hammer" and rel >= 44 and rel <= 84 and (rel % 2) == 0 then
        snap(string.format("swing_%03d", rel))
    end

    -- Over-the-top hammer.  The wind-up is five frames before the hammer
    -- comes round the front, so the interesting band starts later than the
    -- fatality swing's and runs through the stun that follows.
    if spec.name == "hamtop" then
        if rel >= 20 and rel <= 140 then
            local a1v, a2v = p1_action(), p2_action()
            if a1v ~= hamtop_last_p1a or a2v ~= hamtop_last_p2a then
                local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
                print(string.format(
                    "[kahn-test] hamtop_trace rel=%d p1_action=0x%04x p2_action=0x%04x p1x=%d p2x=%d p1y=%d p2y=%d p2ganiy=%d debug4=0x%04x",
                    rel, a1v, a2v,
                    p1o ~= 0 and r16(p1o + O.oxpos) or -1,
                    p2o ~= 0 and r16(p2o + O.oxpos) or -1,
                    p1o ~= 0 and s16(r16(p1o + O.oypos)) or -1,
                    p2o ~= 0 and s16(r16(p2o + O.oypos)) or -1,
                    r16(r32(A.p2_proc) + P.ganiy), debug4_value))
                hamtop_last_p1a = a1v
                hamtop_last_p2a = a2v
            end
        end
        if rel >= 40 and rel <= 130 and (rel % 6) == 0 then
            snap(string.format("hamtop_%03d", rel))
        end
        -- The move's whole point is the reaction, so verify the reaction and
        -- not just that the animation played.  ACT_SPEARED_SD is the stun
        -- r_kahn_hamtop puts the victim in - the same one Scorpion's spear
        -- uses, which is why the drone already understands it.
        if debug4_value == 0x5041 and not hamtop_seen_dizzy then
            if p1_action() == ACT_SPEARED_SD then
                hamtop_seen_dizzy = true
                hamtop_dizzy_frame = frame
                print(string.format(
                    "[kahn-test] hamtop dizzy ok frame=%d p1_action=0x%04x %s",
                    frame, p1_action(), player_summary()))
                snap("hamtop_dizzy")
            end
        end
        -- Watch the victim's frame actually CHANGE while he is stunned.
        if hamtop_seen_dizzy and not hamtop_dizzy_ended
           and p1_action() == ACT_SPEARED_SD then
            -- Read the first multipart PIECE's sag, not oimg.  On a fighter
            -- oimg points at the multipart RAM block, which is allocated once
            -- and holds the same address for the life of the object however
            -- much the animation advances - reading it directly reports "1
            -- distinct frame" for a perfectly healthy animation.  mp_sag
            -- (DISPEQU.ASM, offset 0 of the block) is what changes per frame.
            local p1o = r32(A.p1_obj)
            local mp = (p1o ~= 0) and r32(p1o + O.oimg) or 0
            if mp ~= 0 then
                local im = r32(mp)
                if im ~= hamtop_last_img then
                    hamtop_last_img = im
                    hamtop_dizzy_imgs = hamtop_dizzy_imgs + 1
                end
            end
        end
        -- ...and that he comes OUT of it.  A stun that never ends is the
        -- failure mode worth catching, not one that never starts.
        if hamtop_seen_dizzy and not hamtop_dizzy_ended
           and p1_action() ~= ACT_SPEARED_SD then
            hamtop_dizzy_ended = true
            print(string.format(
                "[kahn-test] hamtop dizzy released after %d frames, %d distinct frames drawn, p1_action=0x%04x",
                frame - hamtop_dizzy_frame, hamtop_dizzy_imgs, p1_action()))
            if hamtop_dizzy_imgs < 4 then
                print(string.format(
                    "[kahn-test] ERROR hamtop_stun_not_animating imgs=%d - the victim held act_speared_sd but barely changed pose; something ahead of the stunned animation is eating the window",
                    hamtop_dizzy_imgs))
            end
            snap("hamtop_dizzy_end")
        end
    end

    if spec.name == "big_power" and rel == 40 then
        snap("big_power_mid")
    end

    -- dense coverage of the ~16-tick soul-suck pickup/hold (after the stalk walk)
    if spec.name == "big_power" and rel >= 44 and rel <= 72 and (rel % 4 == 0) then
        print(string.format("[kahn-test] big_power_hold rel=%d %s", rel, player_summary()))
        debug_objects("big_power_hold_" .. tostring(rel))
        snap("big_power_hold_" .. tostring(rel))
    end

    if spec.name == "big_power" and rel == 180 then
        snap("big_power_done")
        print("[kahn-test] big_power animation window elapsed")
        print("[kahn-test] finished")
        if LIVE_HOLD then
            finish_live_move()
            return
        end
        manager.machine:exit()
        return
    end

    if rel > 240 and not move_ack then
        print(string.format("[kahn-test] ERROR move_not_acknowledged move=%s debug3=%d debug5=0x%08x %s",
            spec.name, debug_value, r32(A.debug5), player_summary()))
        -- forensic: walk objlst so a frozen delete target can be checked
        local p = r32(symbols.objlst or 0x011275d0)
        local n = 0
        while p ~= 0 and n < 24 do
            print(string.format("[kahn-test] objlst[%d]=0x%08x oid=0x%04x sag=0x%08x", n, p, r16(p + O.oid), r32(p + 0x100)))
            p = r32(p + O.next)
            n = n + 1
        end
        -- forensic: walk the ACTIVE process list looking for a cycle
        local seen = {}
        local ap = r32(A.active)
        local an = 0
        while ap ~= 0 and an < 300 do
            if seen[ap] then
                print(string.format("[kahn-test] ACTIVE_CYCLE at node 0x%08x (index %d)", ap, an))
                break
            end
            seen[ap] = an
            if an < 40 then
                print(string.format("[kahn-test] active[%d]=0x%08x id=0x%04x wake=0x%08x t=%d",
                    an, ap, r16(ap + P.id), r32(ap + P.wake), r16(ap + P.time)))
            end
            ap = r32(ap + P.next)
            an = an + 1
        end
        print(string.format("[kahn-test] active_walk_end nodes=%d", an))
        snap(spec.name .. "_not_acknowledged")
        if LIVE_HOLD then
            live_error_latch = true
            live_move_spec = nil
            move_start = 0
            move_ack = false
            move_done = false
            return
        end
        manager.machine:exit()
        return
    end

    if (spec.name == "jump" or spec.name == "fly") and move_done then
        current_move = current_move + 1
        if LIVE_HOLD then live_move_spec = nil end
        move_start = 0
        move_ack = false
        move_done = false
        next_move_frame = frame + MOVE_START_DELAY
    elseif rel > (spec.name == "hammer" and 800 or 300) and move_ack then
        current_move = current_move + 1
        if LIVE_HOLD then live_move_spec = nil end
        move_start = 0
        move_ack = false
        move_done = false
        next_move_frame = frame + MOVE_START_DELAY
    end
end

local function check_bad_state()
    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then
        print(string.format("[kahn-test] ERROR bad_gstate frame=%d gs=0x%04x debug4=0x%04x %s",
            frame, gs, r16(A.debug4), player_summary()))
        snap("bad_gstate")
        did_bad_state = true
        if LIVE_HOLD then
            live_error_latch = true
            return true
        end
        manager.machine:exit()
        return true
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        input_sys = manager.machine.input
        local ok, err = pcall(function()
            snd_tap = space:install_write_tap(SND_TAP_LO, SND_TAP_HI,
                                             "kahnsnd", on_sound_write)
        end)
        print(string.format("[kahn-test] sound latch tap %s",
            (ok and snd_tap) and "installed" or ("FAILED: " .. tostring(err))))
        cache_fields()
        if P2_PAD then cache_p2_fields() end
        print("[kahn-test] loaded: one-player Liu Kang vs forced Shao Kahn ladder slot")
        print("[kahn-test] log_path=" .. LOG_PATH)
        if NORMAL_MATCH then print("[kahn-test] mode=normal_match") end
        if LIVE_HOLD then print("[kahn-test] mode=live_hold") end
        if P2_PAD then print("[kahn-test] mode=p2_pad (P2 pad controls Kahn; puppet AI off)") end
        if UNLIMITED_HEALTH then print("[kahn-test] mode=unlimited_health") end
        if ALLOW_P1_DAMAGE then print("[kahn-test] mode=allow_p1_damage") end
        if PORTAL_FATALITY then print("[kahn-test] mode=portal_fatality") end
        if PIN_PLAYERS then
            print(PIN_KAHN_ONLY and "[kahn-test] mode=pin_kahn_only"
                               or "[kahn-test] mode=pin_players")
        end
        if CODE_LIST ~= "" then print(string.format("[kahn-test] move_codes=%s", CODE_LIST)) end
        if LIVE_HOLD then print("[kahn-test] hotkeys: 1=big_power 2=slam 3=sonic 4=portal 5=nupower Insert=jump Del=fly PgUp=snapshot Home=clear latch") end
        print(string.format("[kahn-test] forcing p1=Liu Kang p2=Shao Kahn curback=%d (KAHN'S ARENA)", KAHN_ARENA))
        print(string.format("[kahn-test] symbols debug3=%s curback=%s map_position=%s gstate=%s",
            hx(A.debug3), hx(A.curback), hx(A.map_position), hx(A.gstate)))
        if config_error then
            print("[kahn-test] ERROR " .. config_error)
            manager.machine:exit()
            return
        end
    end

    if space then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            print(string.format("[kahn-test] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                w16(A.debug4, 0)
                last_debug4 = 0
                print("[kahn-test] fight_start " .. player_summary())
                snap("fight_start")
            end
            last_gstate = gs
        end

        if charsel_frame > 0 and fighting_frame == 0 then
            force_kahn_ladder()
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[kahn-test] confirming p1 at frame=%d", frame))
        end

        if check_bad_state() then return end

        if fighting_frame > 0 and not did_bad_state then
            if COLBOX then w16(A.f_colbox, 1) end
            if not P2_PAD then keep_players_alive() end
            if FORCE_ROUND then
                w16(A.round_num, FORCE_ROUND)
            end
            if PIN_PLAYERS and not (PIN_RELEASE_ON_MOVE and move_start ~= 0) then
                -- KAHN_PIN_RELEASE_ON_MOVE: pin only until the move starts,
                -- then let go.  pin_players() rewrites oxpos EVERY frame, so
                -- with it left on a lunge cannot travel and what you measure
                -- is the STATIC strike box, not the move's reach.  Use the
                -- pin to set the spacing, then release it and let the move
                -- close the distance itself.
                pin_players()
            end

            if r16(A.p2_char) ~= FT_KAHN and frame - fighting_frame > 30 then
                if P2_PAD then
                    -- match concluded and the game left the Kahn fight -
                    -- that's the natural end of a play session, not an error
                    print("[kahn-test] p2 session: match over - exiting")
                    print("[kahn-test] finished")
                    manager.machine:exit()
                    return
                end
                print(string.format("[kahn-test] ERROR p2 is not Kahn frame=%d p2_char=%d", frame, r16(A.p2_char)))
                snap("not_kahn")
                manager.machine:exit()
                return
            end

            if PUPPET_HOLD and not P2_PAD then
                w16(A.debug2, PUPPET_MAGIC)     -- hold across round intros too
            end

            if P2_PAD then
                w16(A.debug2, PUPPET_MAGIC)     -- hold across round intros too
                if gs == GS_FIGHTING then
                    p2_pad_update()
                    if P2_SELFTEST then p2_selftest_update() end
                    if P2_IDLE_WATCH > 0 then
                        local rel = frame - fighting_frame
                        if rel % 60 == 0 then
                            print(string.format("[kahn-test] idle_watch rel=%d %s",
                                rel, player_summary()))
                        end
                        if rel == 10 or rel == 25 or rel == 40 or rel == 55
                           or rel == 70 or rel == 90 then
                            snap("idlewatch_" .. tostring(rel))
                        end
                        if rel >= P2_IDLE_WATCH then
                            print("[kahn-test] idle_watch done")
                            print("[kahn-test] finished")
                            manager.machine:exit()
                            return
                        end
                    end
                    local debug4_value = r16(A.debug4)
                    if debug4_value ~= last_debug4 then
                        print(string.format("[kahn-test] p2pad_debug4 frame=%d debug4=0x%04x %s",
                            frame, debug4_value, player_summary()))
                        last_debug4 = debug4_value
                    end
                else
                    w16(A.debug3, 0)    -- between rounds: drop stale pad commands
                end
            elseif NORMAL_MATCH then
                normal_match_progress()
            elseif LIVE_HOLD then
                if #moves > 0 and move_start == 0
                   and frame - fighting_frame >= MOVE_START_DELAY
                   and frame >= next_move_frame and finished_frame == 0 then
                    start_next_move()
                elseif move_start ~= 0 then
                    check_move_progress()
                end
            else
                if move_start == 0 and frame - fighting_frame >= MOVE_START_DELAY
                   and frame >= next_move_frame and finished_frame == 0 then
                    start_next_move()
                elseif move_start ~= 0 then
                    check_move_progress()
                end
            end
        end

        if LIVE_HOLD then
            -- Hold the round clock so the session lasts as long as the
            -- window is open.  Live hold only: a scripted run wants the
            -- stock clock.
            if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
            hotkeys()
            if live_error_latch and (frame % 60) == 0 then
                print(string.format("[kahn-test] live_error_latched frame=%d debug3=%d debug4=0x%04x %s",
                    frame, r16(A.debug3), r16(A.debug4), player_summary()))
                if not did_active_forensic then
                    did_active_forensic = true
                    local seen = {}
                    local ap = r32(A.active)
                    local an = 0
                    while ap ~= 0 and an < 300 do
                        if seen[ap] then
                            print(string.format("[kahn-test] ACTIVE_CYCLE at node 0x%08x (index %d, first seen %d)", ap, an, seen[ap]))
                            break
                        end
                        seen[ap] = an
                        if an < 40 then
                            print(string.format("[kahn-test] active[%d]=0x%08x id=0x%04x wake=0x%08x t=%d",
                                an, ap, r16(ap + P.id), r32(ap + P.wake), r16(ap + P.time)))
                        end
                        ap = r32(ap + P.next)
                        an = an + 1
                    end
                    print(string.format("[kahn-test] active_walk_end nodes=%d debug5=0x%08x", an, r32(A.debug5)))
                end
            end
        end

        -- 80 ticks is enough to see a move finish, and NOT enough to see a
        -- round end: bonus_count sleeps 040h before win6 and the FATALITY
        -- letters reveal at 6 ticks a frame after that, so a fatality run
        -- that stops here has always already cut away before the word
        -- appears.  KAHN_END_HOLD=<ticks> buys the tail when the ending is
        -- what is under review.
        if finished_frame > 0 and not LIVE_HOLD and not P2_PAD then
            local tail = frame - finished_frame
            if END_HOLD > 80 and (tail % 20) == 0 then
                snap(string.format("end_%04d", tail))
                -- PC too: a round that stops advancing is either a process
                -- parked in a loop (PC wanders, gstate stuck) or the machine
                -- hard-locked (PC pinned).  Only the register tells them apart.
                local pc = "?"
                local okpc, cpu = pcall(function() return manager.machine.devices[":maincpu"] end)
                if okpc and cpu then
                    local okv, v = pcall(function() return cpu.state["PC"].value end)
                    if okv then pc = string.format("0x%08x", v) end
                end
                print(string.format("[kahn-test] end_hold tail=%d gstate=%d winner=%d pc=%s %s",
                    tail, r16(A.gstate), r16(A.winner_status), pc, player_summary()))
            end
            if tail > END_HOLD then
                manager.machine:exit()
            end
        end

        if frame > 4200 and not LIVE_HOLD and not P2_PAD then
            print("[kahn-test] ERROR timeout " .. player_summary())
            snap("timeout")
            manager.machine:exit()
        end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end
end)

emu.register_stop(function()
    if space then
        local ok, summary = pcall(function()
            return string.format("[kahn-test] stopped frame=%d gstate=%d curback=%d winner=%d debug3=%d %s",
                frame, r16(A.gstate), r16(A.curback), r16(A.winner_status), r16(A.debug3), player_summary())
        end)
        print(ok and summary or string.format("[kahn-test] stopped frame=%d summary_error=%s", frame, tostring(summary)))
        debug_objects("stopped")
    else
        print(string.format("[kahn-test] stopped frame=%d no_program_space", frame))
    end

    if logfh then
        logfh:flush()
        logfh:close()
        logfh = nil
    end
end)
