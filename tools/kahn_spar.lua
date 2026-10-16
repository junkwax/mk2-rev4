-- kahn_spar.lua
--
-- YOU play the opponent, Shao Kahn is the AI, and everything you do gets
-- recorded so his exploits can be found and closed.
--
-- Two files come out of a session:
--
--   *_events.log   one line per meaningful thing: your move, his answer, every
--                  hit either way with the range it landed at.  This is the
--                  file that finds exploits.
--   *_inputs.log   raw pad trace, one line per change, frame-stamped.  This is
--                  what makes a run reproducible.
--
-- ...plus a summary table printed at the end (and on demand) that scores every
-- move you used: how often it landed, what it earned, and what Kahn did about
-- it.  A move with a high hit rate and no answer IS the exploit.
--
-- Hotkeys while the MAME window has focus:
--   F5  mark "that was an exploit" in the log at this exact frame
--   F6  print the running move-by-move summary to the console now
--   F7  reset the stats (start a fresh sample without restarting MAME)
--
-- Env:
--   KAHN_SPAR_ROOT / KAHN_SPAR_LOG / KAHN_SPAR_DIFF (default 9)
--   KAHN_SPAR_CHAR  optional ft_* index to force P1; omit to pick your own
--                   fighter on the select screen as normal

local frame = 0
local ROOT = os.getenv("KAHN_SPAR_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_BASE  = os.getenv("KAHN_SPAR_LOG") or (ROOT .. "/tools/kahn_spar_logs/session")
local FORCE_DIFF = tonumber(os.getenv("KAHN_SPAR_DIFF") or "9") or 9
local FORCE_CHAR = tonumber(os.getenv("KAHN_SPAR_CHAR") or "") or nil

local evfh = io.open(LOG_BASE .. "_events.log", "w")
local infh = io.open(LOG_BASE .. "_inputs.log", "w")

local function ev(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[spar] " .. line)
    if evfh then evfh:write(line, "\n"); evfh:flush() end
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
    end
end
local function sym(n) return symbols[n] or 0 end

-- Kahn's per-frame art labels (BGKNOCKDOWN6, BGGETUP2, ...) are FILE-LOCAL
-- in MKSK.ASM and appear nowhere in mk2.map, so matching oimg against symbol
-- names finds nothing and the watcher silently never fires.  Instead MKSK.ASM
-- now exports the four animation TABLES, and the frame-header addresses are
-- derived from them at runtime, below in build_frame_sets().
local FRAME_SET = {}          -- frame header address -> animation name
local function imgname(a)
    if a == 0 then return "-" end
    return FRAME_SET[a] or string.format("img_%08x", a)
end

local A = {
    gstate = sym("gstate"), diff = sym("diff"),
    curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), round_num = sym("round_num"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_matchw = sym("p1_matchw"), p2_matchw = sym("p2_matchw"),
    debug4 = sym("debug4"), worldtly = sym("worldtly"),
    kdrift = sym("c_kahn_drift"), debug6 = sym("debug6"),
    kaa = sym("c_kahn_aa"), kaad = sym("c_kahn_aa_d"), kaan = sym("c_kahn_aa_n"),
    krg = sym("c_kahn_rg"), krgn = sym("c_kahn_rg_n"),
    kphase = sym("f_kahn_phase"),
    worldtlx = sym("worldtlx"), left_edge = sym("left_edge"), right_edge = sym("right_edge"),
}
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, oimg = 0x1a0 }
local P = { action = 0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KAHN, KAHN_ARENA = 13, 8
local PS_ACTIVE, PS_INACTIVE = 1, 0

-- Action id -> readable name. Only the ones a player actually produces; the
-- rest print as raw hex, which is still enough to spot a repeat.
local ACT = {
    [0x101]="hipunch",[0x102]="lopunch",[0x103]="hikick",[0x104]="medkick",
    [0x105]="rhouse",[0x106]="sweep",[0x107]="uppercut",[0x108]="hhspin",
    [0x109]="backbreak",[0x10a]="splits",[0x10b]="hh_backfist",[0x10c]="lk_backfist",
    [0x10d]="jc_ppunch",[0x10e]="jupkick",[0x10f]="knee",[0x110]="jx_powerp",
    [0x111]="fnspinchop",[0x112]="jade_boom",[0x113]="duck_kickh",[0x114]="elbow",
    [0x115]="jade_flash",[0x116]="noob_shadow",[0x118]="juppunch",[0x119]="duckpunch",
    [0x11a]="duck_kickl",[0x11c]="2nd_knee",[0x11d]="shred",[0x11e]="swipe",
    [0x120]="fan_swipe",[0x121]="sa_spin",[0x122]="noogy",[0x123]="sa_swordkick",
    [0x124]="sa_leggrab",[0x12c]="sonic_fan",[0x134]="floor_ice",[0x137]="quake",
    [0x200]="flykick",[0x201]="flypunch",[0x202]="hh_teleport",[0x203]="superkang",
    [0x204]="bike",[0x205]="shadowkick",[0x206]="shoruken",[0x208]="fntele",
    [0x209]="dive",[0x20a]="decoy",[0x20b]="scissor",[0x20c]="slide",
    [0x20d]="reptile_fly",[0x20e]="kano_ball",[0x210]="sz_tornado",[0x211]="noob_tele",
    [0x301]="backup",[0x302]="duck",[0x303]="stance",[0x304]="land",
    [0x305]="walkf",[0x306]="postattack",[0x307]="walkb",[0x308]="angle_jump",
    [0x309]="melt",[0x30a]="getup",[0x30b]="jumpup",
    [0x700]="block_hi",[0x701]="block_lo",
    [0x01]="throw_hat",[0x02]="lkzap_lo",[0x03]="lkzap_hi",[0x04]="lkzap_air",
    [0x05]="jcsnot_lo",[0x06]="jcsnot_hi",[0x07]="spark",[0x08]="throw_fans",
    [0x09]="air_fans",[0x0a]="throw_tsai",[0x0b]="air_tsai",[0x0c]="skull1",
    [0x0d]="skull2",[0x0e]="skull3",[0x0f]="bolt",[0x10]="throw_ice",
    [0x11]="spear",[0x12]="spit",[0x13]="slow_orb",[0x14]="jax_zap",
    [0x15]="air_ice",[0x16]="air_spit",
}
-- Kahn writes a breadcrumb to @debug4 at every decision point.  Decoding it
-- in the log turns "kahn.angle_jump dbg=7001" - which reads like a glitch -
-- into "kahn.angle_jump [fly/knee: entered]", which is just the flying knee
-- doing its job.  That exact line was reported as a random fall.
local DBG = {
    [0x6200]="stalk top",   [0x6300]="close band", [0x6301]="mid band",
    [0x6302]="far band",    [0x6310]="KICK",       [0x6320]="posture:mid",
    [0x6321]="posture:far",
    [0x6420]="heal: check reached", [0x6421]="heal: on cooldown",
    [0x6422]="heal: not hurt enough", [0x6423]="HEAL NOW",
    [0x6424]="heal: no room", [0x6425]="heal: roll said no",
    [0x6426]="heal: still crowded", [0x6427]="HEAL after backup",
    -- turn accounting on the block path: whichever of these dominates is
    -- where his turns are going
    [0x6400]="BLOCK entered",       [0x6401]="BLOCK held to the end",
    [0x6402]="BLOCK timed out",     [0x6403]="punish: roll said no",
    [0x6404]="punish: on cooldown", [0x6405]="PUNISH COMMITTED",
    [0x6406]="block chain capped",  [0x6460]="reground repair",
    [0x5040]="hamtop start",[0x5041]="hamtop->dizzy",[0x5042]="hamtop blocked",
    [0x5030]="hammer",      [0x5031]="hammer",     [0x5034]="hammer clean hit",
    [0x5020]="portal fatal",
    [0x6101]="nupower tail",[0x6110]="nupower",    [0x6111]="nupower",
    [0x7001]="fly/knee: entered", [0x7002]="fly/knee: flight",
    [0x7003]="fly/knee: tip",     [0x7004]="fly/knee: landed",
    [0x7005]="fly/knee: contact",
    -- these live in MKZAP, not MKBOSS (a grep of MKBOSS will not find them)
    [0x5004]="clap: wave running", [0x5010]="clap: frame advance",
    [0x5011]="clap: collision tick", [0x5015]="clap: strike check",
}
local function dbgname(v)
    local n = DBG[v]
    return n and string.format("%04x [%s]", v, n) or string.format("%04x", v)
end

local function actname(a)
    if a == 0 then return "-" end
    return ACT[a] or string.format("act_%03x", a)
end

-- Is this an action the fighter DECIDED to do?  Attacks (01xx), propelling
-- attacks (02xx), projectile throws (00xx), and the approach/defence choices
-- worth tracking as habits.  Everything else - walking, stance, being hit
-- (05xx), recovering (06xx), being frozen (04xx) - is either noise or
-- something the opponent did to him, and must not be scored as his move.
local CHOICE_NONATK = {
    [0x302] = true,   -- duck
    [0x308] = true,   -- angle jump (the jump-in)
    [0x30b] = true,   -- jump straight up
    [0x700] = true,   -- block high
    [0x701] = true,   -- block low
}
local function is_choice(a)
    if a == 0 then return false end
    local cat = a >> 8
    if cat == 0 or cat == 1 or cat == 2 then return true end
    return CHOICE_NONATK[a] == true
end

local cpu, space, input_sys
local boot_fields = {}
local pad = {}
local PAD_KEYS = { "up","down","left","right","hp","lp","hk","lk","blk" }

local function r16(a) return space:read_u16(a) end
-- boss_really_airborn publishes a SIGNED drift in c_kahn_drift, so it needs
-- a signed read; r16 alone turns "1px below the ground line" into 65535.
-- It has its OWN word rather than sharing debug5, because MKBOSS (glow ptr)
-- and MKZAP both write debug5 as a LONG - a drift parked there read back as
-- the low half of somebody's pointer, which is where "drift 20737" came from.
local function s16(a)
    local v = space:read_u16(a)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end
-- debug6 packs two things:
--   low  byte = airborne verdict, 0 grounded / 1 by velocity / 2 by height
--   high byte = the animation slot get_block_ani_offset last handed out.
-- The slot is the decisive one: 08 is the boss block animation (correct),
-- while 0b/0c are a NORMAL fighter's block slots, which on Shao Kahn are
-- getup / getting-hit.  Seeing 0b here proves the block picked getup.
local AIRCODE = { [0] = "grnd", [1] = "AIR-vel", [2] = "AIR-high" }
local function airinfo()
    if A.kdrift == 0 or A.debug6 == 0 then return "n/a" end
    local d6 = r16(A.debug6)
    local slot = (d6 >> 8) & 0xff
    local mark = (slot ~= 0 and slot ~= 0x08) and "  <<WRONG" or ""
    -- f_kahn_phase up = projectiles pass THROUGH him (power-up gather).
    -- Shown because "the freeze did nothing" has two completely different
    -- causes - he blocked it (chip damage, a HIT line) or it phased (no HIT
    -- line at all) - and a stuck flag would look exactly like the first.
    local ph = (A.kphase ~= 0 and r16(A.kphase) ~= 0) and "  PHASING" or ""
    return string.format("%s drift %d  blk %02x%s%s",
        AIRCODE[d6 & 0xff] or "?", s16(A.kdrift), slot, mark, ph)
end
-- Why the anti-air uppercut did not fire.  A session with ZERO uppercuts
-- has to name the gate that refused, not leave it to be guessed at.
local AACODE = { [1]="SWING", [2]="not airborne", [3]="too high",
                 [4]="too low", [5]="right height, OUT OF REACH",
                 [6]="TOO CLOSE (inside the uppercut dead zone)" }
-- 0 is NOT a code: it is the BSS default, i.e. "never polled".
local aa_hist = {}
local function aainfo()
    if A.kaa == 0 then return "n/a" end
    local v = r16(A.kaa)
    local code, dog = v & 0xff, (v >> 8) & 0xff
    return string.format("%s (dog=%d dist=%d)",
        AACODE[code] or ("?" .. code), dog, A.kaad ~= 0 and r16(A.kaad) or -1)
end
-- Count ONE sample per actual poll.  The verdict word keeps its value
-- between polls, so counting it every frame smeared a single verdict across
-- hundreds of frames and reported 1154 SWINGs that were really one.  The
-- ASM bumps c_kahn_aa_n on every call; only a change in that means new data.
local aa_last_n = -1
local function aa_sample()
    if A.kaa == 0 or A.kaan == 0 then return end
    local n = r16(A.kaan)
    if n == aa_last_n then return end
    aa_last_n = n
    local c = r16(A.kaa) & 0xff
    if c == 0 then return end          -- never polled, not a verdict
    aa_hist[c] = (aa_hist[c] or 0) + 1
end
-- Why the stranded-ground-line repair did or did not run.  It reported zero
-- repairs in a session that plainly had a 44px drift, so it has to name the
-- branch it took rather than stay silent.
local RGCODE = { [1]="REPAIRED a stranded ground line",
                 [2]="skipped: he was moving vertically",
                 [3]="skipped: already on his ground line" }
local rg_hist, rg_last_n = {}, -1
local function rg_sample()
    if A.krg == 0 or A.krgn == 0 then return end
    local n = r16(A.krgn)
    if n == rg_last_n then return end
    rg_last_n = n
    local c = r16(A.krg)
    if c == 0 then return end
    rg_hist[c] = (rg_hist[c] or 0) + 1
end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function r32(a) return space:read_u32(a) end

-- Walk each exported animation table and record every frame header it points
-- at, so an oimg can be named.  Entries are 32-bit pointers; 0 terminates a
-- phase (a_skblock has one mid-list) and ani_jump ends a looping list, so a
-- bounded walk that skips zeros covers all four.
local ANI_RANGE = {}          -- {name=, lo=, hi=}
function build_frame_sets()
    local tabs = { {"a_skstance","STANCE"},   {"a_skblock","BLOCK"},
                   {"a_skkdown","KNOCKDOWN"}, {"a_skgetup","GETUP"},
                   -- his OFFENCE.  These are the ones that were showing as
                   -- "nil", which is how a full arsenal read as "he never
                   -- attacks" - his attacks also run with p_action 0, so
                   -- the action column cannot see them either.
                   {"a_skpunch","PUNCH"},     {"a_skkick","KICK"},
                   {"a_skuppercut","UPPERCUT"}, {"a_sk_spear","SPEAR"},
                   {"a_skcharge","CHARGE"},   {"a_sk_bigpow","BIGPOW"},
                   {"a_sk_zap","ZAP"},        {"a_sk_slam","SLAM"},
                   {"a_sk_soniclap","CLAP"},  {"a_sk_portpunch","PORTAL"},
                   {"a_sk_nupower","NUPOWER"},
                   -- and the two that keep getting mistaken for a fall
                   {"a_sk_stumble","STUMBLE"}, {"a_skhit","HIT"},
                   {"a_sk_swept","SWEPT"},
                   {"a_skwalkf","WALKF"},     {"a_skwalkb","WALKB"} }
    -- TIGHT extents.  Bounding each table by the NEXT LABEL's address is
    -- wrong: the gap between two tables is full of the frame data itself
    -- (BGSTANCE1A and friends) and of other animations entirely, so a9
    -- sitting anywhere in that gap got reported as the wrong animation -
    -- it called a hammer-top "KNOCKDOWN frame 624".
    --
    -- A table is a run of consecutive ROM pointers; the first non-pointer
    -- (0, or a small ani_* command constant) ends it.
    for _, t in ipairs(tabs) do
        local base = symbols[t[1]]
        if not base then
            ev("WARN animation table %s missing from mk2.map", t[1])
        else
            -- Cap is 64, not 32: a_sk_portpunch is 41 entries (it holds
            -- BGPORTPUNCH7 for 35 of them) and a 32 cap truncated its range,
            -- so late frames reported as nil.  Overshooting is safe - the
            -- walk stops at the first non-pointer, and every table ends in a
            -- 0 before its own frame data begins.
            local n = 0
            for i = 0, 63 do
                local e = space:read_u32(base + i * 32)
                if e == 0 or (e & 0xff000000) ~= 0xff000000 then break end
                n = i + 1
            end
            if n > 0 then
                ANI_RANGE[#ANI_RANGE+1] =
                    { name = t[2], lo = base, hi = base + (n - 1) * 32, n = n }
            end
        end
    end
    local msg = ""
    for _, b in ipairs(ANI_RANGE) do
        msg = msg .. string.format("%s(%d frames) ", b.name, b.n)
    end
    ev("animation ranges: %s", msg)
end

-- Which animation is his saved a9 currently walking?
local PA9 = 0x0a0
local function kahn_ani()
    local q = r32(A.p2_proc); if q == 0 then return nil end
    local a9 = r32(q + PA9)
    for _, b in ipairs(ANI_RANGE) do
        if a9 >= b.lo and a9 <= b.hi then
            return b.name, (a9 - b.lo) // 32
        end
    end
    return nil
end

local function cache_boot_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then boot_fields[f.name] = f end
        end
    end
end

local function cache_pad()
    local want = { up="Up", down="Down", left="Left", right="Right",
                   hp="High Punch", lp="Low Punch",
                   hk="High Kick", lk="Low Kick", blk="Block" }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            for key, base in pairs(want) do
                if not pad[key] and f.name == ("P1 " .. base) then
                    pad[key] = { port = port, field = f }
                end
            end
        end
    end
    local miss = {}
    for _, k in ipairs(PAD_KEYS) do if not pad[k] then miss[#miss+1] = k end end
    if #miss > 0 then ev("WARN pad fields missing: %s", table.concat(miss, ",")) end
end

local function pad_down(key)
    local h = pad[key]
    if not h then return false end
    return ((h.port:read() ~ h.field.defvalue) & h.field.mask) ~= 0
end

local function pad_state()
    local s, bits = "", 0
    for i, k in ipairs(PAD_KEYS) do
        if pad_down(k) then s = s .. k:upper() .. " "; bits = bits | (1 << i) end
    end
    return bits, (s == "" and "-" or s)
end

-- ---------------------------------------------------------------- stats ----
-- Keyed on the player's action. For each: how many times it came out, how many
-- of those drew blood, total damage, and a histogram of what Kahn was doing at
-- the moment it landed. High uses + high hit% + one dominant Kahn response =
-- a hole to close.
local stats = {}
local function stat(a)
    if not stats[a] then
        stats[a] = { uses=0, hits=0, dmg=0, taken=0, answers={}, ranges={} }
    end
    return stats[a]
end


-- Turn accounting.  debug4 MUST be sampled every frame, not just on Kahn
-- action changes: kahn_stalk rewrites it to 06200h within a few ticks, so a
-- change-sampled read misses almost every breadcrumb (that trap made an
-- earlier probe report zero of everything).
--
-- DECLARED HERE, ABOVE print_summary, ON PURPOSE.  Lua binds upvalues by
-- lexical position: declared below, these are invisible inside print_summary,
-- the indexing errors, and the whole stop handler dies silently after the
-- header line.  That is exactly what happened first time.
local turn_counts, last_dbg = {}, -1
local TURN_CODES = {
    [0x6400]="BLOCK entered", [0x6401]="  block held to the end",
    [0x6402]="  block timed out (he was still swinging)",
    [0x6403]="  punish: roll said no", [0x6404]="  punish: on cooldown",
    [0x6405]="  PUNISH COMMITTED",
    [0x6406]="  chain capped - turn protected from drone_beware",
    [0x6420]="HEAL check reached", [0x6421]="  heal refused: on cooldown",
    [0x6422]="  heal refused: not below 50%",
    [0x6423]="  HEAL NOW (room already)",
    [0x6424]="  heal: no room, trying to make some",
    [0x6425]="  heal refused: make-room roll said no",
    [0x6426]="  heal refused: backed off and still crowded",
    [0x6427]="  HEAL after making room",
}

local function print_summary()
    local rows = {}
    for a, s in pairs(stats) do rows[#rows+1] = { a=a, s=s } end
    table.sort(rows, function(x, y) return x.s.dmg > y.s.dmg end)
    ev("---- MOVE SUMMARY (sorted by damage dealt to Kahn) ----")
    ev(string.format("%-16s %5s %5s %6s %7s  %s", "your move", "used", "hit", "hit%", "dmg", "kahn's usual answer"))
    for _, r in ipairs(rows) do
        local s = r.s
        if s.uses > 0 then
            local best, bestn = "-", 0
            for k, n in pairs(s.answers) do if n > bestn then best, bestn = k, n end end
            local avgr = 0
            if #s.ranges > 0 then
                local t = 0
                for _, v in ipairs(s.ranges) do t = t + v end
                avgr = t // #s.ranges
            end
            ev(string.format("%-16s %5d %5d %5d%% %7d  %s (%d)  avg_range=%d",
                actname(r.a), s.uses, s.hits, math.floor(100 * s.hits / s.uses),
                s.dmg, best, bestn, avgr))
        end
    end
    ev("------------------------------------------------------")
    ev("---- WHERE KAHN'S TURNS WENT (block path) ----")
    local order = {0x6400,0x6406,0x6401,0x6402,0x6403,0x6404,0x6405,
                   0x6420,0x6421,0x6422,0x6423,0x6424,0x6425,0x6426,0x6427}
    local any = false
    for _, k in ipairs(order) do
        if turn_counts[k] then
            any = true
            ev(string.format("%-44s %d", TURN_CODES[k], turn_counts[k]))
        end
    end
    if not any then ev("  (no block-path breadcrumbs seen)") end
    local entered = turn_counts[0x6400] or 0
    local done = (turn_counts[0x6401] or 0) + (turn_counts[0x6402] or 0)
               + (turn_counts[0x6403] or 0) + (turn_counts[0x6404] or 0)
               + (turn_counts[0x6405] or 0)
    if entered > 0 and done < entered then
        ev(string.format("  >> %d of %d blocks NEVER REACHED AN EXIT - drone_beware",
            entered - done, entered))
        ev("     re-dispatched inside the block wait and ate the turn.")
    end
    ev("------------------------------------------------------")
    ev("---- WHY THE ANTI-AIR UPPERCUT DID NOT FIRE ----")
    local any2 = false
    for c = 1, 6 do
        if aa_hist[c] then
            any2 = true
            ev(string.format("%-44s %d", AACODE[c], aa_hist[c]))
        end
    end
    if not any2 then ev("  (kahn_uppercuttable was never even polled)") end
    ev("------------------------------------------------------")
    ev("---- STRANDED GROUND LINE REPAIR ----")
    local any3 = false
    for c = 1, 3 do
        if rg_hist[c] then
            any3 = true
            ev(string.format("%-44s %d", RGCODE[c], rg_hist[c]))
        end
    end
    if not any3 then ev("  (kahn_reground_check was never even polled)") end
    ev("------------------------------------------------------")
end

-- ----------------------------------------------------------------- state ---
local last_gstate, last_p1act, last_p2act = -1, -1, -1
local last_p1hp, last_p2hp = 161, 161
local last_bits = -1
local p1_recent, p2_recent = 0, 0     -- most recent committed action each side
local coin_done = false
local charsel_frame, fighting_frame = 0, 0
local AUTO_CONFIRM = os.getenv("KAHN_SPAR_AUTO") == "1"
local hk_prev = {}
local ground_y = nil                  -- your grounded oypos, sampled at round start
local kahn_ground_y = nil             -- HIS grounded oypos, same
local kahn_y_last = nil
local kahn_img_last = nil
local kahn_ani_last = nil
local a9_trace = 0
local offscreen_last = false

-- ON-SCREEN OVERLAY.  Drawn every frame so a video recording can be
-- cross-referenced against the event log frame-for-frame: the same tick
-- number, Kahn's animation + frame index, his action, and the decision
-- breadcrumb all appear on screen.  F8 toggles it (recordings sometimes
-- want a clean shot of the fight).
local OSD_ON = os.getenv("KAHN_SPAR_OSD") ~= "0"
local osd = {}

-- Distance must come from oxval, NOT oxpos.  oxpos is SCREEN space - it is
-- world-x minus the scroll origin - so a fighter walking with the camera shows
-- a constant oxpos and the difference between two of them is meaningless once
-- the stage scrolls.  The first version of this used oxpos and logged ranges
-- like gap=282 on a 400px screen.  oxval is the 32-bit world position with the
-- pixel value in the high half.
local function gap()
    local a, b = r32(A.p1_obj), r32(A.p2_obj)
    if a == 0 or b == 0 then return -1 end
    local d = (r32(a + O.oxval) >> 16) - (r32(b + O.oxval) >> 16)
    return d < 0 and -d or d
end

-- How far off the floor YOU are, in the same units kahn_uppercuttable tests
-- against (kahn_antiair_height = 058h).  Printed on every Kahn action change
-- so a whiffed anti-air can be read directly: too high = he swung early.
local function his_dog()
    local a = r32(A.p1_obj); if a == 0 then return -1 end
    return (ground_y or 0) - r16(a + O.oypos)
end

local function act_of(procaddr)
    if procaddr == 0 then return 0 end
    return r16(procaddr + P.action)
end

--
-- WEDGE PROBE.  A live session ended with YOUR action stuck at act_flykick
-- (0200h) for 400+ frames while Kahn kept animating - the machine was fine,
-- your process stopped advancing.  do_flip_kick sets act_flykick then jsrp
-- air_strike, and BOTH of air_strike's exits set act_fk_sd, so an action
-- still reading act_flykick means that loop never left.  It has three ways
-- out and this dumps what each one tests, so the stuck one names itself:
--
--   strike_check hits                       -> as6
--   p_store1 (strike frames left) reaches 0 -> as7
--   oyvel >= 0 AND oypos >= p_ganiy         -> lands, as8
--
-- Stance (0303h) and "no action" are skipped: both fighters idling between
-- rounds is not a wedge, and counting it drowned the real one in the
-- ladder run.
--
local OB = { ograv = 0x020, oxvel = 0x040, oyvel = 0x060, oypos = 0x0b0 }
local PR = { ganiy = 0x200, store1 = 0x230 }
local function s32v(v) if v >= 0x80000000 then v = v - 0x100000000 end return v end
local wedge_act, wedge_since, wedge_shots = -1, 0, 0
local function wedge_probe()
    local p1p, p1o = r32(A.p1_proc), r32(A.p1_obj)
    if p1p == 0 or p1o == 0 then return end
    local act = r16(p1p + P.action)
    if act ~= wedge_act then wedge_act, wedge_since, wedge_shots = act, frame, 0; return end
    if act == 0 or act == 0x303 then return end        -- idle is not a wedge
    if frame - wedge_since < 120 then return end
    if wedge_shots >= 3 then return end
    wedge_shots = wedge_shots + 1
    local oyv, grav = s32v(r32(p1o + OB.oyvel)), s32v(r32(p1o + OB.ograv))
    local ypos, gan = r16(p1o + OB.oypos), r16(p1p + PR.ganiy)
    ev("%7d  !! YOU WEDGED in %s for %d frames  oyvel=%d ograv=%d oypos=%d ganiy=%d strike_left=%d  kahn=%s",
        frame, actname(act), frame - wedge_since, oyv, grav, ypos, gan,
        r32(p1p + PR.store1) & 0xffff, actname(act_of(r32(A.p2_proc))))
    local why = "unknown - none of the three exits is obviously blocked"
    if oyv < 0 and grav == 0 then
        why = "RISING with NO GRAVITY - air_strike's 'jrn as2' loops forever"
    elseif oyv == 0 and ypos < gan then
        why = "PARKED MID-AIR (no velocity, above ground line) - never lands"
    elseif ypos < gan then
        why = "above his ground line and not descending"
    end
    ev("            cause: %s", why)
end

local function hotkey(token, name, fn)
    local ok, code = pcall(function() return input_sys:code_from_token(token) end)
    if not ok or not code then return end
    local down = input_sys:code_pressed(code)
    if down and not hk_prev[name] then fn() end
    hk_prev[name] = down
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        build_frame_sets()
        input_sys = manager.machine.input
        cache_boot_fields()
        cache_pad()
        ev("session start  diff=%d  log=%s", FORCE_DIFF, LOG_BASE)
        ev("F5=mark exploit  F6=print summary  F7=reset stats")
        return
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING then
            if fighting_frame == 0 then fighting_frame = frame end
            local po = r32(A.p1_obj)
            ground_y = (po ~= 0) and r16(po + O.oypos) or nil
            local ko = r32(A.p2_obj)
            kahn_ground_y = (ko ~= 0) and r16(ko + O.oypos) or nil
            kahn_y_last = kahn_ground_y
            ev("FIGHT round=%d  you=%d  kahn_hp=%d  ground_y=%s",
                r16(A.round_num), r16(A.p1_char), r16(A.p2_bar), tostring(ground_y))
        end
        last_gstate = gs
    end

    -- Force the Kahn matchup. p1_char is left alone so you pick your own
    -- fighter, unless KAHN_SPAR_CHAR says otherwise.
    --
    -- This has to keep running until the fight is actually LIVE, not just
    -- while the select screen is up: gstate walks 4 -> 13 -> 7 -> 6 -> 7 -> 2
    -- and the stage load happens in those middle states.  Forcing only while
    -- gstate == GS_PSEL stops ~400 frames early, the game reverts to its own
    -- idea of the matchup, and the round comes up with both fighters stood in
    -- stance at the start distance forever.
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p2_char, FT_KAHN)
        w16(A.curback, KAHN_ARENA)
        w16(A.map_position, 14)
        w16(A.battle_num, 15)
        if FORCE_CHAR then w16(A.p1_char, FORCE_CHAR) end
    end
    w16(A.diff, FORCE_DIFF)

    -- Auto coin + start to get you to the select screen, then the controls are
    -- yours - nothing is injected from here on, so your inputs are the only
    -- ones in the trace.  Frame windows match the proven ladder rig: the board
    -- is not ready to take a coin before ~700.
    --
    -- AUTO_CONFIRM is for headless self-tests only.  In a real session YOU
    -- confirm the fighter; if nobody does, the select times out and the round
    -- comes up half-initialised - both fighters stood in stance at the start
    -- distance forever, which is what caught this during the smoke test.
    if not coin_done then
        if gs == GS_PSEL then
            if charsel_frame == 0 then charsel_frame = frame end
            if AUTO_CONFIRM then
                local s = boot_fields["1 Player Start"]
                if s then
                    if frame > charsel_frame + 90 and frame < charsel_frame + 135 then s:set_value(1) else s:clear_value() end
                end
            else
                coin_done = true
                for _, f in pairs(boot_fields) do f:clear_value() end
                ev("select screen is yours - pick your fighter (Kahn/arena/diff are forced)")
            end
        else
            local c, s = boot_fields["Coin 1"], boot_fields["1 Player Start"]
            if c then if frame >= 700 and frame < 980 and (frame % 80) < 20 then c:set_value(1) else c:clear_value() end end
            if s then if frame >= 1000 and frame < 1080 then s:set_value(1) else s:clear_value() end end
        end
    end
    if gs == GS_FIGHTING and not coin_done then
        coin_done = true
        for _, f in pairs(boot_fields) do f:clear_value() end
    end

    hotkey("KEYCODE_F5", "mark", function()
        ev("*** MARK frame=%d  you=%s  kahn=%s  gap=%d  hp=%d/%d  <- flagged as an exploit",
            frame, actname(p1_recent), actname(p2_recent), gap(), r16(A.p1_bar), r16(A.p2_bar))
    end)
    hotkey("KEYCODE_F6", "sum", print_summary)
    hotkey("KEYCODE_F7", "reset", function() stats = {}; ev("*** stats reset at frame %d", frame) end)
    hotkey("KEYCODE_F8", "osd", function()
        OSD_ON = not OSD_ON
        ev("*** on-screen overlay %s", OSD_ON and "ON" or "OFF")
    end)

    if gs ~= GS_FIGHTING then return end

    -- raw pad trace, one line per change
    local bits, human = pad_state()
    if bits ~= last_bits then
        if infh then infh:write(string.format("%d\t%s\n", frame, human)); infh:flush() end
        last_bits = bits
    end

    -- "HE DROPPED RANDOMLY" DETECTOR.
    -- The reported fall happens with his p_action never leaving `stance`, so
    -- an action-change log can never show it - it is his OBJECT moving, or
    -- the camera moving under him.  Watch his y directly and shout when it
    -- moves while he is in a state that has no business moving vertically.
    do
        local ko = r32(A.p2_obj)
        if ko ~= 0 then
            local ky = r16(ko + O.oypos)
            if kahn_y_last then
                local dy = ky - kahn_y_last
                if dy > 6 or dy < -6 then
                    local ka = act_of(r32(A.p2_proc))
                    local cat = ka >> 8
                    -- legitimate vertical movement: jumping, landing, the
                    -- knee, being hit (05xx) or recovering (06xx)
                    local ok = (ka == 0x308) or (ka == 0x30b) or (ka == 0x304)
                               or (cat == 5) or (cat == 6)
                    if not ok then
                        ev("%7d  !! KAHN Y MOVED %d -> %d (%+d) while action=%s  cam_y=%d  dbg=%s",
                            frame, kahn_y_last, ky, dy, actname(ka),
                            A.worldtly ~= 0 and r16(A.worldtly + 16) or -1,
                            dbgname(r16(A.debug4)))
                    end
                end
            end
            kahn_y_last = ky
        end
    end

    -- WHICH ANIMATION IS HE ACTUALLY PLAYING?  Reported: "he unblocks and
    -- then does some of the fall down animation frames, maybe BGKNOCKDOWN6,
    -- and then a few frames of BGGETUP" - with his p_action never leaving
    -- stance.  An action log is blind to that; so was oimg (it points at his
    -- multipart RAM, not ROM art).  His saved a9 is the animation pointer.
    do
        local nm, idx = kahn_ani()
        if nm ~= kahn_ani_last then
            if nm == "KNOCKDOWN" or nm == "GETUP" then
                ev("%7d  !! KAHN ANIMATION %s frame %d  action=%s  dbg=%s  air=%s",
                    frame, nm, idx or -1, actname(act_of(r32(A.p2_proc))),
                    dbgname(r16(A.debug4)), airinfo())
                -- Trace the RAW pointer for the next 30 frames.  The decisive
                -- question is whether a9 WALKED here (stepping +32 a frame,
                -- i.e. it ran off the end of another animation) or was SET
                -- here in one jump (something wrote the wrong index).  Those
                -- are completely different bugs and the frame name alone
                -- cannot tell them apart.
                a9_trace = 30
            end
            kahn_ani_last = nm
        end
        if a9_trace and a9_trace > 0 then
            local q = r32(A.p2_proc)
            if q ~= 0 then
                ev("%7d     a9=%08x  %s  action=%s", frame, r32(q + PA9),
                    tostring(nm), actname(act_of(q)))
            end
            a9_trace = a9_trace - 1
        end
    end

    -- refresh the overlay text
    do
        local an, ai = kahn_ani()
        local p2a2 = act_of(r32(A.p2_proc))
        local ko2 = r32(A.p2_obj)
        osd[1] = string.format("TICK %-6d  ROUND %d   %d - %d",
            frame, r16(A.round_num), r16(A.p1_matchw), r16(A.p2_matchw))
        osd[2] = string.format("KAHN  hp %-4d act %-12s", r16(A.p2_bar), actname(p2a2))
        osd[3] = string.format("      ani %-10s frame %-3s y %-4s",
            tostring(an), tostring(ai),
            ko2 ~= 0 and tostring(r16(ko2 + O.oypos)) or "-")
        osd[4] = string.format("      dbg %-18s air %s",
            dbgname(r16(A.debug4)), airinfo())
        osd[5] = string.format("YOU   hp %-4d act %-12s dog %-4d",
            r16(A.p1_bar), actname(act_of(r32(A.p1_proc))), his_dog())
        local p1o2, p2o2 = r32(A.p1_obj), r32(A.p2_obj)
        osd[6] = string.format("GAP %-5d  cam_y %d  cam_x %d", gap(),
            A.worldtly ~= 0 and r16(A.worldtly + 16) or -1,
            A.worldtlx ~= 0 and r16(A.worldtlx + 16) or -1)
        osd[7] = string.format("worldX  you %-6s kahn %-6s  edges %s..%s",
            p1o2 ~= 0 and tostring(r32(p1o2 + O.oxval) >> 16) or "-",
            p2o2 ~= 0 and tostring(r32(p2o2 + O.oxval) >> 16) or "-",
            A.left_edge ~= 0 and tostring(r16(A.left_edge)) or "-",
            A.right_edge ~= 0 and tostring(r16(A.right_edge)) or "-")
    end

    -- OFF-SCREEN DETECTOR.  Reported with a screenshot: both fighters gone
    -- from view while GAP and cam_y were both sane.  Only the horizontal
    -- camera can do that, and it was the one thing never being logged.
    do
        local p1o3, p2o3 = r32(A.p1_obj), r32(A.p2_obj)
        if p1o3 ~= 0 and p2o3 ~= 0 and A.worldtlx ~= 0 then
            local camx = r16(A.worldtlx + 16)
            local x1 = r32(p1o3 + O.oxval) >> 16
            local x2 = r32(p2o3 + O.oxval) >> 16
            local function off(x) return (x < camx - 8) or (x > camx + 408) end
            local now = off(x1) or off(x2)
            if now and not offscreen_last then
                ev("%7d  !! OFF SCREEN  you=%d kahn=%d  cam_x=%d (window %d..%d)  gap=%d  dbg=%s",
                    frame, x1, x2, camx, camx, camx + 400, gap(),
                    dbgname(r16(A.debug4)))
            end
            offscreen_last = now
        end
    end

    local d4 = r16(A.debug4)
    if d4 ~= last_dbg then
        if TURN_CODES[d4] then turn_counts[d4] = (turn_counts[d4] or 0) + 1 end
        last_dbg = d4
    end

    -- Sample the anti-air gate every frame.  kahn_uppercuttable is polled
    -- from inside stance_wait_yes, so the reject reason is only true for the
    -- tick it was written; counting once per frame is what turns it into the
    -- histogram that names the gate.
    aa_sample()
    rg_sample()
    wedge_probe()

    local p1a = act_of(r32(A.p1_proc))
    local p2a = act_of(r32(A.p2_proc))

    if frame % 600 == 0 then
        ev("%7d  ..alive  gap=%-4d hp=%d/%d  you=%s kahn=%s  kahn_y=%s cam_y=%d",
            frame, gap(), r16(A.p1_bar), r16(A.p2_bar), actname(p1a), actname(p2a),
            tostring(kahn_y_last), A.worldtly ~= 0 and r16(A.worldtly + 16) or -1)
        do
            local ko = r32(A.p2_obj)
            if ko ~= 0 then
                local an, ai = kahn_ani()
                ev("            kahn ani = %s frame %s   air=%s",
                    tostring(an), tostring(ai), airinfo())
                ev("            anti-air gate: %s", aainfo())
            end
        end
    end

    if p1a ~= last_p1act and p1a ~= 0 then
        last_p1act = p1a
        if is_choice(p1a) then
            -- only a move he CHOSE becomes the thing damage is attributed to.
            -- act_reacting (0503) and the 06xx recovery states are things done
            -- TO him; letting those become p1_recent credited Kahn's own
            -- uppercut damage to "act_503" in the summary.
            p1_recent = p1a
            stat(p1a).uses = stat(p1a).uses + 1
            ev("%7d  YOU  %-16s gap=%-4d kahn=%s", frame, actname(p1a), gap(), actname(p2_recent))
        end
    end

    if p2a ~= last_p2act and p2a ~= 0 then
        -- EVERY Kahn action change, not just the ones he chose.  Knowing he
        -- was walking / in stance / in hit reaction at the moment of a
        -- jump-in is the whole diagnosis, and filtering those out is what
        -- left several rounds of guessing about why an anti-air never fired.
        ev("%7d  kahn.%-16s gap=%-4d dog=%-4d you=%-14s dbg=%s",
            frame, actname(p2a), gap(), his_dog(), actname(p1_recent),
            dbgname(r16(A.debug4)))
        last_p2act = p2a
        if is_choice(p2a) then p2_recent = p2a end
    end

    -- damage attribution
    local p1hp, p2hp = r16(A.p1_bar), r16(A.p2_bar)
    if p2hp < last_p2hp and p2hp <= 161 and (last_p2hp - p2hp) <= 161 then
        local d = last_p2hp - p2hp
        local s = stat(p1_recent)
        s.hits = s.hits + 1
        s.dmg  = s.dmg + d
        s.answers[actname(p2_recent)] = (s.answers[actname(p2_recent)] or 0) + 1
        s.ranges[#s.ranges + 1] = gap()
        ev("%7d  HIT  your %-14s -%-3d  kahn_hp=%-4d gap=%-4d (he was %s)",
            frame, actname(p1_recent), d, p2hp, gap(), actname(p2_recent))
    end
    if p1hp < last_p1hp and p1hp <= 161 and (last_p1hp - p1hp) <= 161 then
        local d = last_p1hp - p1hp
        stat(p1_recent).taken = stat(p1_recent).taken + d
        ev("%7d  TAKE kahn %-14s -%-3d  your_hp=%-4d gap=%-4d (you were %s)",
            frame, actname(p2_recent), d, p1hp, gap(), actname(p1_recent))
    end
    last_p1hp, last_p2hp = p1hp, p2hp
end)

-- Render.  Wrapped in pcall because a headless run (-video none) has no
-- screen to draw on, and the overlay must never take the harness down.
local function draw_osd()
    if not OSD_ON then return end
    local scr
    for _, s2 in pairs(manager.machine.screens) do scr = s2 break end
    if not scr then return end
    local y = 2
    for i = 1, #osd do
        if osd[i] then
            scr:draw_text(2, y, osd[i], 0xffffff00, 0xc0000000)
            y = y + 8
        end
    end
end

if emu.register_frame_done then
    emu.register_frame_done(function() pcall(draw_osd) end)
elseif emu.add_machine_frame_notifier then
    emu.add_machine_frame_notifier(function() pcall(draw_osd) end)
end

emu.register_stop(function()
    ev("session end at frame %d  (you %d - %d Kahn)", frame, r16(A.p1_matchw), r16(A.p2_matchw))
    print_summary()
    if evfh then evfh:close() end
    if infh then infh:close() end
end)
