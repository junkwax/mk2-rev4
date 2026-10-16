-- flybrain_play.lua - the fruit fly plays MK2 against the computer.
--
-- The fly is PLAYER 1, and it plays through P1's joystick and buttons - the
-- same input path a person uses. That is the fairness rule made structural:
-- it cannot do anything a stick cannot do, every move obeys the game's own
-- physics, startup and recovery, and tap-gated moves work because a "human"
-- is present (two drones wedge the board). It plays a normal one-player game,
-- so it climbs the real ladder against the stock CPU, continues when it loses,
-- and cycles through every main fighter game by game.
--
-- Brain, in two layers:
--   1. The looming circuit: 64 cell types from the MaleCNS connectome
--      (LC4/LPLC2 -> giant fiber, DNp02/04 backward jump, DNp11 forward jump,
--      MDN retreat), exported by tools/flybrain_sim.py --export-lua and run in
--      the same integer arithmetic the simulator validated. It decides WHEN a
--      threat is coming and which escape family wants to answer.
--   2. A mushroom-body style valence learner: every choice (a defence when the
--      circuit fires, a neutral/offence move otherwise) is taken with
--      probability proportional to a weight for (context, option). When the
--      CPU's life bar drops soon after a choice its weight goes up; when the
--      fly's bar drops, down. Weights persist for the whole run per fighter, so
--      it adapts inside a match and keeps what it learned up the ladder.
--
-- No advantage over a person or the CPU:
--   * perception is what is on screen - fighter and projectile positions and
--     both life bars - read ONE FRAME LATE;
--   * a defence may not start sooner than the stock drone's reaction delay at
--     the current @diff (drone_react_delay, MKDRONE.ASM) plus that lag;
--   * inputs are held for at least 2 frames, and the next decision waits for
--     the current input macro to finish.
--
-- Env: FB_MAP  FB_NET  FB_OUT (dir)  FB_READY  FB_CHARS ("cycle" or "1,9,3")
--      FB_GAMES (game overs before exit, default 1; 0 = forever)  FB_SEED  FB_GAIN (5)
--      FB_CONTINUE (1 = continue after a lost match, 0 = game over)  FB_MAXMIN (emu minutes)

local ROOT = "C:/Users/you/Workplace/mk2-main"
do  -- an empty environment variable means "unset" (PowerShell cannot always delete one)
  local raw_getenv = os.getenv
  os.getenv = function(k) local v = raw_getenv(k); if v == "" then return nil end; return v end
end
local function envp(k, d) return (os.getenv(k) or d):gsub("\\", "/") end
local MAP = envp("FB_MAP", ROOT .. "/src/mk2.map")
local NETF = envp("FB_NET", "C:/tmp/flybrain/out/flynet.lua")
local OUT = envp("FB_OUT", "C:/tmp/flybrain/play")
local READY = os.getenv("FB_READY")
local GAMES = tonumber(os.getenv("FB_GAMES") or "1")
local SEED = tonumber(os.getenv("FB_SEED") or "12345")
local MAXMIN = tonumber(os.getenv("FB_MAXMIN") or "120")
local CONTINUE = os.getenv("FB_CONTINUE") ~= "0"   -- 0: a lost match ends the game (next fighter)
BOSSQ = { tries = tonumber(os.getenv("FB_BOSS_TRIES") or "0"), losses = 0, quit = false }   -- global: 200 locals
-- FB_LEARN=0 is the no-learning control: the weights must not move.  It is LEARNING, not
-- LEARN, because `LEARN = { rounds = ... }` further down assigns to the nearest visible LOCAL
-- rather than making a global (its comment says otherwise) - so the flag BECAME that table,
-- and a table is always truthy.  Every `not LEARN` guard below was dead: -NoLearn learned,
-- and so did every EXAM, which run_flybrain_train.ps1 runs with NoLearn precisely to measure
-- a FROZEN brain.  Never name the flag and the table the same thing.
local LEARNING = os.getenv("FB_LEARN") ~= "0"
local WEIGHTS_IN = os.getenv("FB_WEIGHTS_IN")       -- carry training over from an earlier run
local WEIGHTS_OUT = os.getenv("FB_WEIGHTS_OUT")     -- saved at every round end
local ROTATE = os.getenv("FB_ROTATE") or "psel"     -- psel: next fighter at every select screen (continues too)
local LABEL = os.getenv("FB_LABEL") or "fly"
-- DMA guard: MAME's T-Unit video has no bounds check on the sprite address, so a
-- bad SAG from the ROM crashes the EMULATOR (twice in training, vs Kintaro, round
-- 2). A board would just draw garbage. The guard logs the game state the moment a
-- SAG past the video ROM is programmed, and zeroes its high word so MAME lives.
local DMA_GUARD = os.getenv("FB_DMA_GUARD") ~= "0"
-- test rigs only: FB_FORCE_RUNG puts the player on that rung of the 1P tower right
-- after select (13 = Kintaro, 14 = Shao Kahn), the same place the kahn select cheat
-- writes. Do NOT force p2_char/p2_state during select instead: that left player 2
-- counted as an idle HUMAN - Kintaro never attacked and the ladder never promoted
-- (adv_winner_map skips when two players are active).
local FORCE_RUNG = tonumber(os.getenv("FB_FORCE_RUNG") or "")
-- FB_FORCE_P2_LEGACY=12 reproduces the broken select-screen forcing EXACTLY, only so
-- the deterministic Kintaro shadow crash (frame 141790, seed 12345, train/full brain)
-- can still be replayed. Never use it to measure anything.
local FORCE_P2_LEGACY = tonumber(os.getenv("FB_FORCE_P2_LEGACY") or "")
local FORCE_DIFF = tonumber(os.getenv("FB_FORCE_DIFF") or "")
-- FB_STAGE (hex curback) + FB_STAGE_EVERY N: fight every Nth battle on that arena.
-- WAFFLE HOUSE (017h) is a SECRET arena - MKSEL.ASM keeps it out of the VS cycle and out
-- of match_stage_cycle, and in one-player it is only the hidden Smoke fight's arena, so the
-- fly can never reach it by playing. vs_validate_curback accepts it (vs_stage_secret), and
-- curback is re-read when the stage loads, so it has to be held until the fight starts.
-- Bosses and secret opponents keep their own arenas: Kintaro/Kahn/Shang belong in KAHN'S
-- ARENA (the Shang soul escape is built around its stands and back wall), and Smoke/Noob
-- have arenas of their own.
local STAGE = tonumber(os.getenv("FB_STAGE") or "", 16)
local STAGE_EVERY = tonumber(os.getenv("FB_STAGE_EVERY") or "0")
local STAGE_KEEP = { [6] = true, [12] = true, [13] = true, [14] = true, [15] = true }

-- FB_SECRET_OPP_EVERY N: every Nth battle, the CPU is Smoke (14) or Noob (15), alternating.
-- The tower already carries a SECRET SPOT holding ft_smoke, and `adv3` (MAIN.ASM) steps
-- over it on every advance, so the ladder never hands them out. set_drone_ochar copies the
-- map's entry into the drone's p2_char, so writing p2_char during the pre-fight setup is
-- exactly what landing on that spot would have done - not a new capability, an unskipped one.
-- (Noob also has a native route: hold Start at the pre-match handoff, MAIN.ASM ndo_noob.
-- The write is used for both so one mechanism covers Smoke, who has no such route.)
local SECRET_OPP_EVERY = tonumber(os.getenv("FB_SECRET_OPP_EVERY") or "0")
-- FB_SECRET_OPPS="15,17,19": which hidden CPUs that rotation deals (default Smoke, Noob). Any
-- ochar the drone can be: 14 Smoke, 15 Noob, 16 Jade, 17 Ermac, 18 Khameleon, 19 Rain.
local SECRET_OPPS = {}
for n in (os.getenv("FB_SECRET_OPPS") or "14,15"):gmatch("%d+") do SECRET_OPPS[#SECRET_OPPS + 1] = tonumber(n) end
local NO_WAFFLE = os.getenv("FB_NO_WAFFLE") ~= "0"   -- paused by request; set 0 to allow it
local CHARS = {}
do
  local s = os.getenv("FB_CHARS") or "cycle"
  if s == "cycle" then CHARS = { 1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 16, 17, 19 }   -- 16 Jade, 17 Ermac, 19 Rain
  else for n in s:gmatch("%d+") do CHARS[#CHARS + 1] = tonumber(n) end end
end
local CHAR_NAME = { [0] = "KungLao", "LiuKang", "Cage", "Baraka", "Kitana", "Mileena", "Shang", "Raiden",
  "SubZero", "Reptile", "Scorpion", "Jax", "Kintaro", "ShaoKahn", "Smoke", "Noob", "Jade", "Ermac", "Khameleon",
  "Rain" }                                     -- ft_rain = 19 (MAINEQU.ASM)

math.randomseed(SEED)

-- ------------------------------------------------------------------ logging
local logfh = io.open(OUT .. "/play.log", "w")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[fly] " .. l); if logfh then logfh:write(l, "\n"); logfh:flush() end
end
local rounds = io.open(OUT .. "/rounds.csv", "w")
rounds:write("frame,game,battle,round,fly_char,cpu_char,diff,winner,fly_bar,cpu_bar,round_frames,fly_dealt,fly_taken,defences,decisions,mode,punched\n")

-- ------------------------------------------------------------------ symbols
local sym = {}
for line in io.lines(MAP) do
  for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
local want = { "clk_ones", "clk_tens" }   -- optional (the stall detector reads them)
-- ani2_clip (MKUTIL.ASM) counts every runaway animation list the guard refused. It is
-- 0 in ordinary play, so any increment here IS the open Kahn's Arena bug happening, in
-- the wild, with the fighter/stage/battle context of this log around it. Absent on a
-- pre-fix map, hence the nil guard rather than an entry in `need`.
local clip_seen = 0
-- NO-PROGRESS detector. The stall detector only runs inside the three fight states and
-- only fires on a PERFECTLY static signature, so a game that leaves the fight loop - a
-- board reset into boot/attract, say - is invisible to it: on 2026-09-17 21:22 the
-- emulator kept running at 100% while the fly logged nothing for 47 seconds and no
-- detector noticed. Rounds are 20-40s; finishers, the ladder map and the continue
-- countdown can legitimately add up, so the threshold is deliberately generous.
local NOPROG_FRAMES = tonumber(os.getenv("FB_NOPROG_FRAMES") or "5500")  -- ~100 emulated seconds
local last_progress = 0
local need = { "gstate", "p1_state", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_bar", "p2_bar", "objlst",
  "winner_status", "diff", "round_num", "battle_num", "p1_matchw", "p2_matchw", "fly_player", "f_fatal_lock", "p2_state", "curback", "map_position", "map_start", "p1_proc", "p2_proc" }
local missing = {}
for _, n in ipairs(need) do if not sym[n] then missing[#missing + 1] = n end end
if #missing > 0 then log("ERROR unresolved symbols: %s", table.concat(missing, ",")) end

local O = { next = 0x000, oxvel = 0x040, oyvel = 0x060, oxpos = 0x090, oypos = 0x0b0, oid = 0x1c0 }
local GS = { amode = 1, fighting = 2, buyin = 3, psel = 4, bonus = 5, pfsetup = 6, round_intro = 7, initials = 0xa, gameover = 0xb }
local STALL_FRAMES = tonumber(os.getenv("FB_STALL_FRAMES") or "1641")   -- 30 emulated seconds at 54.7 Hz
local stall_sig, stall_n = nil, 0

-- ------------------------------------------------------------------ circuit
local NET = dofile(NETF)
local C, S = NET.constants, NET.sensory
-- How wide an object must LOOK (degrees of angular size) before the two eyes share it
-- equally. A fighter at arm's length spans ~50 deg and is seen by both; one across the
-- screen spans ~10 deg and is nearly all in one hemifield. FB_BINOC=0 restores the old
-- one-eye-only behaviour for an A/B.
S.binoc_span = S.binoc_span or tonumber(os.getenv("FB_BINOC_SPAN") or "40")
-- How much of the looming-size channel is plain ANGULAR SIZE rather than expansion, and the
-- size at which that saturates. 120 degrees is about 55 px apart - inside every fighter's
-- reach - so the channel rises across the whole range a fight is decided in.
-- Default 0 = the old encoder until an A/B says otherwise: the stream restarts itself, and
-- an untested default would reach it through the back door.
S.loom_size = tonumber(os.getenv("FB_LOOM_SIZE") or "0")
S.size_full = tonumber(os.getenv("FB_SIZE_FULL") or "120")
-- THE ESCAPE REFLEX IS A HAIR TRIGGER, and these two set its sensitivity. An offline replica
-- of this circuit (2026-09-28) put a steady LC4 of 8 - of 255 - at escape 72, over `fire`, and
-- LC4 30 at 255 in both nets. With lc4_full 6 deg/frame that is ~0.2 deg/frame: a quarter
-- pixel a frame of approach at 100 px, where a walk is several. So any approach by either man
-- was a maximal threat, the 30-frame refractory set the rhythm, and ~40% of all decisions came
-- 36 frames apart at any range. FB_LC4_FULL raises the expansion that saturates LC4;
-- FB_LPLC2_GATE raises the expansion LPLC2's bell needs at all (it was 0.05 deg/frame, the
-- same hair trigger). Defaults are the old values until an A/B says otherwise.
-- DEFAULTS FLIPPED 2026-09-29 to the working reflex (48 / 1.5; the net file's lc4_full is 6).
-- Set FB_LC4_FULL=6 FB_LPLC2_GATE=0.05 FB_LOOM_SIZE=0.6 FB_SIGNED_SHIFT=0 FB_REACT_MIN=0 to
-- reproduce the old, latched reflex exactly - which is how the fly3_eyes control runs.
S.lc4_full = tonumber(os.getenv("FB_LC4_FULL") or "") or 48
S.lplc2_gate = tonumber(os.getenv("FB_LPLC2_GATE") or "") or 1.5
LOOMH = os.getenv("FB_LOOM_HIST") == "1" and {} or nil   -- global: the chunk is at 200 locals
SIGNED_SHIFT = os.getenv("FB_SIGNED_SHIFT") ~= "0"       -- global, same reason; see circuit_step
REACT_MIN = tonumber(os.getenv("FB_REACT_MIN") or "") or 12 -- frames; see the reflex's delay
local BINOC = os.getenv("FB_BINOC") ~= "0"
local N = #NET.names
local idx, fam_nodes = {}, { escape = {}, jump_bk = {}, jump_fwd = {}, retreat = {},
                             advance = {}, kick = {} }
local sense_idx = {}
-- DNg100 (forward walking) and pIP10 (kick) come from alextitonis/fly.ai's sshfighter, which
-- maps six descending neurons straight onto its buttons. Ours drive LEANINGS, not buttons:
-- the learner still chooses, so the wiring argues rather than commands.
local FAM = { DNp01 = "escape", DNp02 = "jump_bk", DNp04 = "jump_bk", DNp11 = "jump_fwd",
              MDN = "retreat", DNg100 = "advance", pIP10 = "kick" }
for i, n in ipairs(NET.names) do
  idx[n] = i
  local base, side = n:match("^(.-)_([LR])$")
  base = base or n
  if FAM[base] then table.insert(fam_nodes[FAM[base]], { i = i, side = side }) end
  if NET.group[i] == "sense" then sense_idx[base .. "_" .. (side or "")] = i end
end
-- WHICH SENSE CELLS THIS NET HAS. The first net had two (LC4, LPLC2); a net extracted with
-- --ears-eyes also carries the ear (JO-*), the wide-field flow cells (HS/VS/H2), small-object
-- motion (LC11), two more looming channels (LPLC1, LC6) and the ocelli (OCG01*). Each group
-- is driven by the matching sense the rig measures, per side where the cell has a side.
S.grp = { loom_fast = {}, loom_size = {}, small = {}, flow_h = {}, flow_v = {}, chase = {},
          ear = {}, wind = {}, ocelli = {} }   -- on S: the chunk is at Lua's 200 locals
for key, i in pairs(sense_idx) do
  local base = key:gsub("_[LR]?$", "")
  local side = key:match("_([LR])$")
  local g = (base == "LC4" or base == "LC6") and "loom_fast"
         or (base == "LPLC2" or base == "LPLC1") and "loom_size"
         or (base == "LC11") and "small"
         or (base:match("^HS") or base == "H2") and "flow_h"
         or (base == "VS") and "flow_v"
         or (base:match("^JO%-[BD]")) and "ear"          -- JO-B/D: sound and vibration
         or (base:match("^JO%-")) and "wind"             -- JO-A/C/E: wind, gravity, displacement
         or (base == "LC10a") and "chase"
         or (base:match("^OCG01")) and "ocelli" or nil
  if g then S.grp[g][#S.grp[g] + 1] = { key = key, side = side } end
end

-- OCTOPAMINE: the fly's mood, read out of its own cells. A net extracted with
-- flybrain_extract.py --octopamine carries the brain's octopaminergic clusters (OA-VUMa,
-- OA-VPM, OA-AL2, OA-ASM1 - 21 cells in flynet_oa.lua), which get ~175 connections FROM
-- the circuit and send none back into it: octopamine is a neuromodulator, not a fast
-- synapse, so the extractor gives it no sign. Their level is the mood.
--   * the body tells them about the fight: landing a hit excites them, taking one
--     inhibits them (the winner and loser effects), as an input current;
--   * the circuit drives them too - what the fly SEES moves its octopamine;
--   * level = their mean MEMBRANE POTENTIAL, rising fast on a burst and fading slowly,
--     the way a neuromodulator accumulates; mood = how far that sits from its own resting
--     level, in units of its own typical swing.
-- POTENTIAL, NOT FIRING. The first shadow run read their firing (0..255) and found them
-- SATURATED: the circuit drives them to 165-210 all fight and to 255 every round, so a
-- landed hit had no room to register and the mood swung 0.41-0.70 against the hand
-- mood's 0.0-1.0. Release tracks depolarisation, and the 255 cap is an artefact of the
-- activity scale; the potential runs to 16384, and goes NEGATIVE under inhibition, so
-- the loser effect shows as well as the winner effect.
-- SELF-SCALED. rest and spread are the level's own slow mean and mean deviation, so the
-- mapping needs no guessed gain in unknown units: k = 0.2 puts one typical swing at 0.2
-- of mood and 2.5 swings at the ends of the 0..1 range, the hand mood's full span.
-- FB_OA=1 lets it decide. Default (0) is SHADOW: the hand-tuned mood still decides and
-- this one is computed beside it and logged per round, so it can be calibrated and A/B'd
-- before it is trusted. On a net with no octopamine cells none of this runs.
OA = { idx = {}, drive = 0, level = 0, rest = nil, now = 0, mood = nil,       -- global: the
       per_hit = tonumber(os.getenv("FB_OA_HIT") or "90"),                   -- chunk is at
       per_hurt = tonumber(os.getenv("FB_OA_HURT") or "90"),                 -- Lua's 200
       decay = 0.90, rise = 0.05, fall = 0.002, rest_rate = 0.0005,          -- locals
       spread = nil,
       k = tonumber(os.getenv("FB_OA_K") or "0.2"),
       rs = nil }
for i, n in ipairs(NET.names) do
  if n:match("^OA%-VUMa") or n:match("^OA%-VPM") or n:match("^OA%-AL2") or n:match("^OA%-ASM1") then
    OA.idx[#OA.idx + 1] = i
  end
end
OA.use = #OA.idx > 0 and os.getenv("FB_OA") == "1"

-- POKE A NEURON (FB_STIM=1, the stream's show mode - never on in a test or a trainer).
-- What a fly lab does with light-gated channels: drive one named cell type and watch the
-- animal. The dashboard's buttons write <dash>.stim.json {"cell": name, "t": when}; this
-- polls it and, for 1.5 s, injects a strong current into those cells. They then fire, the
-- brain panel shows them lit, and the fly does what that cell does in this circuit:
--   giant      DNp01, the giant fiber - the escape reflex arms and it LEAPS away
--   charge     DNg100, forward walking - the wiring leans it into walking in
--   kick       pIP10 - the wiring leans it into kicking
--   octopamine the octopamine cells - its mood runs hot, so it turns aggressive
--   moonwalk   MDN, the moonwalker descending neuron - a real fly walks BACKWARDS; so does this one
--   loom       LPLC2 + LC4, the looming detectors - it SEES something rush at it. Sensory, not a
--              command: the escape reflex fires through the wiring and it answers with its own
--              learned move, where the giant fiber button forces the leap
--   aipg       aIPg, the aggression neurons (Schretter 2020) - it closes in and hits, up close
--   pc1        pC1, the arousal cluster that holds a fly aggressive for minutes after it is
--              driven (Jung 2020) - so this poke lasts longer than the others
-- It is a push on the wiring, not a button press: the learner still chooses, so a poke
-- makes the move likely rather than certain - which is also how the real thing behaves.
-- The dashboard file's base path, resolved HERE: SENSE is a local declared further down, so
-- nothing defined up here can see SENSE.dash (the first version indexed it and every poll
-- failed silently inside its pcall). Same rule as SENSE.dash: FB_DASH, default, "0" = off.
DASHBASE = (function()
  local d = os.getenv("FB_DASH") or "C:/tmp/flybrain/dash.json"
  if d == "0" then return nil end
  return (d:gsub("%.json$", ""))
end)()
STIM = { on = os.getenv("FB_STIM") == "1", boot = os.time(), last = nil, what = nil,
         left = 0, idx = {}, current = 4000, frames = 82, sets = nil }   -- global: 200 locals
function STIM.cells(what)
  local want = { giant = { "DNp01" }, charge = { "DNg100" }, kick = { "pIP10" }, moonwalk = { "MDN" },
                 loom = { "LPLC2", "LC4" } }
  local prefix = { aipg = "aIPg", pc1 = "pC1_" }            -- whole families (aIPg1..10, pC1_1a..19)
  local out = {}
  if prefix[what] then
    local pre = prefix[what]
    for i, n in ipairs(NET.names) do if n:sub(1, #pre) == pre then out[#out + 1] = i end end
    return out
  end
  if what == "octopamine" then
    for _, i in ipairs(OA.idx) do out[#out + 1] = i end
    return out
  end
  for i, n in ipairs(NET.names) do
    local base = n:gsub("_[LR]$", "")
    for _, w in ipairs(want[what] or {}) do if base == w then out[#out + 1] = i end end
  end
  return out
end
function STIM.poll(frame)
  if STIM.left > 0 then
    STIM.left = STIM.left - 1
    if STIM.left == 0 then STIM.what, STIM.idx = nil, {} end
  end
  if not STIM.on or not DASHBASE or frame % 15 ~= 0 then return end
  local fh = io.open(DASHBASE .. ".stim.json", "r")
  if not fh then return end
  local txt = fh:read("*a"); fh:close()
  local what = txt:match('"cell"%s*:%s*"(%w+)"')
  local t = tonumber(txt:match('"t"%s*:%s*([%d%.]+)'))
  -- only a request made while this session runs: a poke left over from before a restart
  -- must not fire the moment the stream comes back
  if not what or not t or t < STIM.boot or t == STIM.last then return end
  STIM.last = t
  local idx = STIM.cells(what)
  if #idx == 0 then log("STIM: %s - this circuit has no such cells", what); return end
  STIM.what, STIM.idx, STIM.left = what, idx, (what == "pc1") and STIM.frames * 3 or STIM.frames
  log("STIM: %s - %d cells driven for %d frames", what, #idx, STIM.frames)
end

-- THE BODY TELLING THE BRAIN. A net extracted with flybrain_extract.py --body carries the
-- ASCENDING neurons that talk most to this circuit (63 types, >= 1,000 synapses each into
-- it) as groups body_T1/T2/T3/A - the body segment each reports from, which is all the
-- annotations say: there is no modality label on an ascending neuron. So the mapping is
-- per SEGMENT, deliberately coarse, and each segment feels the strongest of what it
-- would plausibly feel in a fight:
--   T1  front legs - flies fight with their forelegs, so TOUCHING the opponent lands here;
--       and walking, and being struck
--   T2  mid legs and wings - the jump is driven from here, so AIRBORNE; walking; struck
--   T3  hind legs - walking; struck
--   A   abdomen - only the whole-body jolt of being STRUCK
--   X   segment not recorded - the same jolt, and nothing it cannot be known to feel
-- They are clamped like the senses (the rig sets them; their own inputs are in the nerve
-- cord, which is not modelled) and send 1,433 connections into the circuit.
BODY = { T1 = {}, T2 = {}, T3 = {}, A = {}, X = {}, clamp = {}, struck = 0 }   -- global: 200 locals
for i, g in ipairs(NET.group) do
  local seg = g:match("^body_(%w+)$")
  if seg and BODY[seg] then BODY[seg][#BODY[seg] + 1] = i end
  BODY.clamp[i] = (g == "sense") or (seg ~= nil)
end
BODY.n = #BODY.T1 + #BODY.T2 + #BODY.T3 + #BODY.A + #BODY.X

local v, a = {}, {}
for i = 1, N do v[i] = 0; a[i] = 0 end

local function theta(dist, hw)
  local d = math.max(dist - S.body_gap, 4.0)
  return math.deg(2.0 * math.atan(hw / d))
end

local prev_theta = {}
local function circuit_step(objs, sen)
  -- objs: { {key, rel_x, half_w, small}, ... } relative to the fly
  -- sen:  { flow, flow_v, sound, wind, light } - the senses that are not objects
  local drive = { LC4_L = 0, LC4_R = 0, LPLC2_L = 0, LPLC2_R = 0 }
  local now = {}
  for _, o in ipairs(objs) do
    local side = o[2] >= 0 and "R" or "L"
    local other = side == "R" and "L" or "R"
    local th = theta(math.abs(o[2]), o[3])
    now[o[1]] = th
    local dth = th - (prev_theta[o[1]] or th)
    local lc4 = math.floor(255 * math.min(math.max(dth, 0.0) / S.lc4_full, 1.0))
    -- HOW BIG HE LOOKS, not only how fast he is growing. LPLC2 was gated on expansion
    -- (dth > 0.05) and tuned to a 60 degree peak - which is ~88 px apart, the FAR edge of
    -- fighting range; at 60 px the opponent spans ~108 degrees and that bell has fallen to
    -- 2%. Measured on a live stream (5 Hz, 75 s): both looming channels sat at zero in 91%
    -- of frames while chase ran at a median of 145, so an opponent standing right in front
    -- of the fly registered as nothing at all. Real looming cells answer to angular SIZE as
    -- well as to expansion, and alextitonis/fly.ai's sshfighter measured its `loom_size`
    -- mix as its single biggest gain (punch AUC 0.685 -> 0.789 offline, 0.863 live).
    -- FB_LOOM_SIZE is that mix: 0 is exactly the old expansion-gated bell (the A/B control).
    local lp = 0
    if dth > S.lplc2_gate then lp = math.exp(-((th - S.lplc2_peak) / S.lplc2_sigma) ^ 2) end
    lp = math.floor(255 * ((1 - S.loom_size) * lp
                           + S.loom_size * math.min(th / S.size_full, 1.0)))
    -- BINOCULAR OVERLAP. Assigning an object to one hemifield by the SIGN of its x put
    -- the whole drive in one eye forever, because MK2 fighters face each other and the
    -- opponent never leaves that side - the overlay looked one-eyed because the model was.
    -- A fly's eyes overlap at the front, and an object wide enough in angle spills across
    -- the midline into both, so the share is its angular size against the overlap width.
    -- The TOTAL is conserved (ipsi + contra = the old single-eye value), so this changes
    -- where the drive goes, never how much of it there is.
    local cross = math.min(th / S.binoc_span, 1.0) * 0.5    -- 0 = far and lateral, 0.5 = shared
    if not BINOC then cross = 0 end
    -- INTEGERS, always: the circuit is an integer model and shifts its inputs (inp >> gain),
    -- and Lua refuses to shift a float with a fraction. Splitting the drive without flooring
    -- threw on every frame the opponent loomed - 2026-09-17 22:04 to 09-18 01:42, ~860k
    -- errors across eleven training segments, the escape circuit dead exactly when needed.
    -- The contra share is floored and the ipsi side takes the remainder, so the total is
    -- still exactly the old single-eye value.
    local lc4_x, lp_x = math.floor(lc4 * cross), math.floor(lp * cross)
    -- the other cell types this net may carry see the same thing their kind sees: LC6 is a
    -- looming channel like LC4, LPLC1 like LPLC2, and LC11 answers to SMALL moving objects
    for _, e in ipairs(S.grp.loom_fast) do
      if e.key:match("^LC6") then
        local sh = (e.side == side) and (lc4 - lc4_x) or (e.side == other) and lc4_x or lc4
        drive[e.key] = math.min(255, (drive[e.key] or 0) + sh)
      end
    end
    for _, e in ipairs(S.grp.loom_size) do
      if e.key:match("^LPLC1") then
        local sh = (e.side == side) and (lp - lp_x) or (e.side == other) and lp_x or lp
        drive[e.key] = math.min(255, (drive[e.key] or 0) + sh)
      end
    end
    if o[4] then
      for _, e in ipairs(S.grp.small) do
        if e.side == side or e.side == nil then drive[e.key] = math.min(255, (drive[e.key] or 0) + lc4) end
      end
    end
    drive["LC4_" .. side]    = math.min(255, drive["LC4_" .. side]    + (lc4 - lc4_x))
    drive["LC4_" .. other]   = math.min(255, drive["LC4_" .. other]   + lc4_x)
    drive["LPLC2_" .. side]  = math.min(255, drive["LPLC2_" .. side]  + (lp - lp_x))
    drive["LPLC2_" .. other] = math.min(255, drive["LPLC2_" .. other] + lp_x)
  end
  -- LOOM POKED: both eyes report something big rushing in (sensory cells are clamped, so
  -- the poke sets what they see rather than injecting current, which they would ignore)
  if STIM.left > 0 and STIM.what == "loom" then
    drive.LC4_L, drive.LC4_R, drive.LPLC2_L, drive.LPLC2_R = 255, 255, 255, 255
  end
  prev_theta = now
  -- THE SENSES THAT ARE NOT OBJECTS. Flow goes to the eye the world is sliding toward (that
  -- is how HS cells are wired), sound and wind to the ear, the flash to the ocelli.
  if sen then
    -- CHASE (LC10a): not "he is rushing me" but "there he is" - the object-tracking cells a
    -- fly pursues with, driven by where the opponent is and how near, on his side of the eyes.
    if sen.chase_dist then
      local c = math.floor(math.min(255, math.max(0, 255 - sen.chase_dist)))
      local his = sen.chase_right and "R" or "L"
      for _, e in ipairs(S.grp.chase) do
        drive[e.key] = (e.side == nil or e.side == his) and c or (c // 3)
      end
    end
    -- INTEGERS ONLY: the circuit shifts its inputs (inp >> gain), and Lua will not shift a
    -- float. A fraction here threw on every frame a sound was heard.
    local fh = math.floor(math.min(255, math.abs(sen.flow or 0) * 12))
    for _, e in ipairs(S.grp.flow_h) do
      local toward = (sen.flow or 0) >= 0 and "R" or "L"
      drive[e.key] = (e.side == nil or e.side == toward) and fh or (fh // 3)
    end
    local fv = math.floor(math.min(255, math.abs(sen.flow_v or 0) * 12))
    for _, e in ipairs(S.grp.flow_v) do drive[e.key] = fv end
    local snd = math.floor(math.min(255, (sen.sound or 0) * 4))
    for _, e in ipairs(S.grp.ear) do drive[e.key] = snd end
    local wnd = math.floor(math.min(255, (sen.wind or 0) * 24))
    for _, e in ipairs(S.grp.wind) do drive[e.key] = wnd end
    local lgt = math.floor(math.min(255, (sen.light or 0) * 40))
    for _, e in ipairs(S.grp.ocelli) do drive[e.key] = lgt end
  end
  for k, i in pairs(sense_idx) do a[i] = drive[k] or 0 end
  if BODY.n > 0 then
    local walk = sen and math.floor(math.min(255, math.abs(sen.walk or 0) * 60)) or 0
    local air = sen and math.floor(math.min(255, math.max(0, sen.air or 0) * 3)) or 0
    local touch = (sen and sen.touch) and 255 or 0
    local hit = math.floor(BODY.struck)
    local feel = { T1 = math.max(touch, walk, hit), T2 = math.max(air, walk, hit),
                   T3 = math.max(walk, hit), A = hit, X = hit }
    for seg, v0 in pairs(feel) do
      for _, i in ipairs(BODY[seg]) do a[i] = v0 end
    end
    BODY.feel = feel
    local r = BODY.rs or { n = 0, T1 = 0, T2 = 0, T3 = 0, A = 0, X = 0 }
    BODY.rs = r
    r.n = r.n + 1
    for seg, v0 in pairs(feel) do r[seg] = r[seg] + v0 end
    BODY.struck = BODY.struck * 0.85                  -- a jolt, gone in a few frames
  end
  local peak = {}
  for i = 1, N do peak[i] = 0 end
  local gain = GAIN_SHIFT
  local gdiv, ldiv = 1 << gain, 1 << C.leak_shift       -- for FB_SIGNED_SHIFT (see below)
  for _ = 1, C.substeps do
    local inp = {}
    for i = 1, N do inp[i] = 0 end
    for _, e in ipairs(NET.edges) do
      local ap = a[e[2]]
      if ap ~= 0 then inp[e[1]] = inp[e[1]] + e[3] * ap end
    end
    -- the body reporting the fight to the octopamine cells (an integer: inp is shifted)
    if OA.drive ~= 0 then
      for _, i in ipairs(OA.idx) do inp[i] = inp[i] + OA.drive end
    end
    if STIM.left > 0 then
      for _, i in ipairs(STIM.idx) do inp[i] = inp[i] + STIM.current end
    end
    for i = 1, N do
      if not BODY.clamp[i] then                      -- senses and body cells are set, not stepped
        -- LUA'S >> IS A LOGICAL SHIFT. In Lua 5.4 `-32 >> 5` is 576460752303423487 (checked
        -- inside MAME, 2026-09-29), so a cell whose summed input is NEGATIVE - inhibited -
        -- got ~5.7e17 added, clamped to vmax and fired at 255. Inhibition became maximal
        -- excitation. An offline replica with Lua's shift: one 5-frame looming burst leaves
        -- escape ON for 100 of the next 100 frames, where the signed arithmetic this
        -- circuit was designed with (flybrain_sim.py - Python's >> keeps the sign) drops it
        -- to 0 of 100. That is the escape METRONOME: the first threat of a session latches
        -- the circuit on, and the 30-frame refractory is all that paces the reflex after.
        -- Floor division is the arithmetic shift. It is the default; FB_SIGNED_SHIFT=0
        -- restores the old latching behaviour, for the fly3_eyes control only.
        local vi
        if SIGNED_SHIFT then vi = v[i] + inp[i] // gdiv - v[i] // ldiv
        else vi = v[i] + (inp[i] >> gain) - (v[i] >> C.leak_shift) end
        if vi > C.vmax then vi = C.vmax elseif vi < -C.vmax then vi = -C.vmax end
        v[i] = vi
        local ai = vi - C.theta
        if ai < 0 then ai = 0 elseif ai > 255 then ai = 255 end
        a[i] = ai
        if ai > peak[i] then peak[i] = ai end
      end
    end
  end
  if #OA.idx > 0 then
    local sum = 0
    for _, i in ipairs(OA.idx) do sum = sum + v[i] end      -- potential, not the capped firing
    local now = sum / #OA.idx
    OA.now = now
    OA.level = OA.level + (now - OA.level) * (now > OA.level and OA.rise or OA.fall)
    OA.rest = OA.rest and (OA.rest + (OA.level - OA.rest) * OA.rest_rate) or OA.level
    local dev = math.abs(OA.level - OA.rest)
    OA.spread = OA.spread and (OA.spread + (dev - OA.spread) * OA.rest_rate) or math.max(1, dev)
    -- the current fades between hits; truncate TOWARD zero, or floor() leaves -1 forever
    local d = OA.drive * OA.decay
    OA.drive = d >= 0 and math.floor(d) or math.ceil(d)
  end
  local fam = {}
  for k, list in pairs(fam_nodes) do
    local m = 0
    for _, nd in ipairs(list) do if peak[nd.i] > m then m = peak[nd.i] end end
    fam[k] = m
  end
  VIS = { drive = drive, fam = fam, peak = peak }   -- for the on-screen overlay
  return fam
end
GAIN_SHIFT = tonumber(os.getenv("FB_GAIN") or "5")

-- ------------------------------------------------------------------ moves
-- Inputs are logical: F/B (toward / away from the CPU), U, D, HP LP HK LK BL.
local function hold(n, ...) return { n = n, keys = { ... } } end
-- AUTOMATIC SPECIALS (FB_AUTO_SPECIALS, on by default). A special is recognised by
-- combo_look_lr (MOVES.ASM) walking the player's joystick CLOSE queue, p1_jcq - so instead
-- of wiggling the stick through the motion like a person and hoping the timing lands (4 in
-- 10 flying kicks never came out, even from a neutral stance), the fly writes the motion
-- into that queue exactly as switch_queue_a0 (MKINIT.ASM) would have, then presses the
-- button. The move still runs through the game's own button handler, move routine,
-- recovery and cooldowns - only the motion input is skipped, which is what the CPU skips.
-- Direction-only finishers ("dirs") and held-button ones ("open") trigger off the switch
-- events themselves, so those keep the stick.
local AUTO_SPECIALS = os.getenv("FB_AUTO_SPECIALS") ~= "0"
local function special(dirs, buttons)
  local m = {}
  if AUTO_SPECIALS and #dirs > 0 and #buttons == 0 then
    -- NO BUTTON: the last direction IS the trigger (Raiden's teleport is Down, Up - checked
    -- when Up closes). Queue the rest and tap that one for real; queuing all of it and
    -- pressing nothing gave the game no event at all - 0 of 447 came out.
    local lead = {}
    for i = 1, #dirs - 1 do lead[#lead + 1] = dirs[i] end
    return { { n = 3, keys = { dirs[#dirs] }, inject = lead }, hold(2) }
  end
  if AUTO_SPECIALS and #dirs > 0 then
    m[#m + 1] = { n = 4, keys = { table.unpack(buttons) }, inject = dirs }
    m[#m + 1] = hold(2)
    return m
  end
  for _, d in ipairs(dirs) do m[#m + 1] = hold(3, d); m[#m + 1] = hold(2) end
  m[#m + 1] = hold(4, table.unpack(buttons))
  m[#m + 1] = hold(2)
  return m
end

-- range buckets: 1 close <= 80, 2 mid <= 160, 3 far
local BASIC = {
  walk_in    = { r = { 2, 3 }, m = { hold(14, "F") } },
  walk_back  = { r = { 1, 2 }, m = { hold(12, "B") } },
  wait       = { r = { 1, 2, 3 }, m = { hold(8) } },
  jump_in    = { r = { 2, 3 }, m = { hold(4, "U", "F"), hold(14), hold(4, "HK"), hold(20) } },
  jump_up_kick = { r = { 1, 2 }, m = { hold(4, "U"), hold(12), hold(4, "HK"), hold(18) } },
  jab        = { r = { 1 }, m = { hold(3, "HP"), hold(3), hold(3, "HP"), hold(4) } },
  low_punch  = { r = { 1 }, m = { hold(3, "LP"), hold(5) } },
  high_kick  = { r = { 1 }, m = { hold(3, "HK"), hold(10) } },
  low_kick   = { r = { 1 }, m = { hold(3, "LK"), hold(8) } },
  sweep      = { r = { 1 }, m = { hold(3, "B", "LK"), hold(14) } },
  uppercut   = { r = { 1 }, m = { hold(4, "D"), hold(3, "D", "HP"), hold(16) } },
  roundhouse = { r = { 1 }, m = { hold(3, "B", "HK"), hold(14) } },
  duck_kick  = { r = { 1 }, m = { hold(3, "D"), hold(3, "D", "LK"), hold(6) } },
  throw      = { r = { 1 }, m = { hold(3, "F"), hold(3, "F", "LP"), hold(10) } },
  block      = { r = { 1, 2 }, m = { hold(16, "BL") } },
  duck_block = { r = { 1, 2 }, m = { hold(16, "D", "BL") } },
}
local SPECIALS = {
  [1] = { fireball = { { "F", "F" }, { "HP" }, { 2, 3 } }, low_fireball = { { "F", "F" }, { "LP" }, { 2, 3 } },
          flykick = { { "F", "F" }, { "HK" }, { 2, 3 } } },
  [0] = { hat = { { "B", "F" }, { "LP" }, { 2, 3 } }, teleport = { { "D", "U" }, { "LK" }, { 1, 2, 3 } },
          spin = { { "F", "F" }, { "LK" }, { 1, 2 } } },
  [2] = { bolt = { { "D", "F" }, { "LP" }, { 2, 3 } }, shadow_kick = { { "B", "F" }, { "LK" }, { 2, 3 } },
          shadow_upper = { { "B", "B" }, { "HP" }, { 1 } } },
  [3] = { spark = { { "D", "B" }, { "HP" }, { 2, 3 } }, blade_fury = { { "B", "B", "B" }, { "LP" }, { 1 } },
          blade_swipe = { {}, { "B", "HP" }, { 1 } } },
  [4] = { fan_throw = { { "F", "F" }, { "HP", "LP" }, { 2, 3 } }, fan_lift = { { "B", "B", "B" }, { "HP" }, { 1, 2 } },
          fan_lift_lp = { { "B", "B", "B" }, { "LP" }, { 1, 2 } }, square_wave = { { "F", "D", "B" }, { "HP" }, { 2, 3 } } },
  -- Jade (16) and Ermac (17): secret fighters. Jade throws one boomerang motion and the
  -- BUTTON picks the arc (LP straight, HP up, LK down); her Flash is the same motion on HK.
  -- Ermac has the telekinetic slam. All read from MOVES.ASM scom_jade_*/scom_ermac_tks.
  [16] = { boom_up = { { "B", "F" }, { "HP" }, { 2, 3 } }, boom_straight = { { "B", "F" }, { "LP" }, { 2, 3 } },
           boom_down = { { "B", "F" }, { "LK" }, { 2, 3 } }, boom_return = { { "B", "B", "F" }, { "LP" }, { 2, 3 } },
           flash = { { "B", "F" }, { "HK" }, { 1, 2, 3 } } },
  [17] = { tk_slam = { { "B", "D", "B" }, { "HP" }, { 1, 2 } } },
  [5] = { roll = { { "B", "B", "D" }, { "HK" }, { 1, 2 } }, teleport_kick = { { "F", "F" }, { "LK" }, { 2, 3 } },
          sai = { { "B", "B" }, { "LP" }, { 2, 3 } } },
  [6] = { skull1 = { { "B", "B" }, { "HP" }, { 2, 3 } }, skull2 = { { "B", "B", "F" }, { "HP" }, { 2, 3 } },
          skull3 = { { "B", "B", "F", "F" }, { "HP" }, { 3 } } },
  [7] = { lightning = { { "D", "F" }, { "LP" }, { 2, 3 } }, teleport = { { "D", "U" }, {}, { 1, 2, 3 } },
          torpedo = { { "B", "B", "F" }, { "LK" }, { 2, 3 } } },
  [8] = { ice_ball = { { "D", "F" }, { "LP" }, { 2, 3 } }, ground_ice = { { "D", "B" }, { "LK" }, { 1, 2 } },
          slide = { {}, { "B", "LP", "BL", "LK" }, { 1, 2 } } },
  [9] = { spit = { { "F", "F" }, { "HP" }, { 2, 3 } }, forceball = { { "B", "B" }, { "HP", "LP" }, { 2, 3 } },
          slide = { {}, { "B", "LP", "BL", "LK" }, { 1, 2 } } },
  [10] = { spear = { { "B", "B" }, { "LP" }, { 2, 3 } }, teleport = { { "D", "B" }, { "HP" }, { 2, 3 } } },
  [11] = { wave = { { "F", "D", "B" }, { "HK" }, { 2, 3 } }, gotcha = { { "F", "F" }, { "LP" }, { 1 } } },
}
local DEFENCE = {
  t_ground = { "block", "duck_block", "back_jump", "sweep", "uppercut" },
  t_air    = { "uppercut", "block", "back_jump", "roundhouse", "jump_up_kick" },
  t_proj   = { "block", "duck_block", "jump_over", "jump_up", "back_jump" },
}
local DEF_MOVES = {
  back_jump = { hold(4, "U", "B"), hold(24) },
  jump_over = { hold(4, "U", "F"), hold(24) },
  jump_up   = { hold(4, "U"), hold(22) },
}

-- Finishers, per fighter: { dirs, button, style, distance }. Inputs are the
-- combo records (combo_edit.py list, oldest input first) with the button taken
-- from the MOVES.ASM handler that checks each one; "open" = hold the button,
-- do the motion, release it (the *_open handlers). Distances are the drone's
-- own ochar_fatality_distances (MKDRONE.ASM). Babality is only
-- legal in a round with no HP or LP thrown (bb_check / fs_check read l_hp and
-- l_lp), which is why a round can be played "kicks_only".
local FATAL = {
  [0] = { hat_slice = { { "F", "F", "F" }, "LK", "tap", 112 }, fatal2 = { { "B", "F" }, "LP", "open", 272 } },
  -- cartwheel: scom_lk_db2 is checked by lk_down - the final DOWN is the trigger, no button
  [1] = { dragon = { { "D", "F", "B", "B" }, "HK", "tap", 75 }, cartwheel = { { "D", "F", "U", "B", "D" }, nil, "dirs", 180 } },   -- limit 0c8h
  [2] = { uppercut_decap = { { "D", "D", "F", "F" }, "LP", "tap", 75 }, torso_rip = { { "F", "F", "D", "U" }, nil, "dirs", 55 } },   -- landed 1 of 8 at 75
  [3] = { decap = { { "B", "B", "B", "B" }, "HP", "tap", 72 }, impale = { { "B", "F", "D", "F" }, "LP", "tap", 80 } },
  -- kiss: scom_fn1_db is checked by fn1_lk_open - LOW KICK RELEASED, not a Block tap
  [4] = { kiss = { { "F", "F", "D", "F" }, "LK", "open", 38 } },   -- limit 045h, charge 038h
  [5] = { inhale = { { "F", "B", "F" }, "LP", "tap", 74 } },
  -- Shang: scom_st_db1 (st_lo_kick), and this ROM's decap and soul drain
  [6] = { db1 = { { "F", "D", "F" }, "LK", "tap", 75 }, decap = { { "B", "B", "F", "U" }, "LP", "tap", 75 },
          soul_drain = { { "U", "D", "U" }, "LK", "tap", 75 } },
  -- (bolt decap exists in source but raiden_bolt_decap_enable is 0 - not in this ROM)
  [7] = { melt = { { "D", "U" }, "LK", "tap", 75 }, lift = { { "F", "F", "F" }, "HK", "tap", 75 } },
  -- ermac_block: only inside the band 060h..0c0h (UMK3's q_fatal_dist) - never point blank
  [17] = { tk_fatal = { { "D", "U", "D", "D", "D" }, "BL", "tap", 140 } },
  [8] = { shatter = { { "F", "D", "F", "F" }, "HP", "tap", 144 }, fatal2 = { { "B", "B", "D", "F" }, "LP", "open", 290 },   -- sz_lp_open REFUSES closer than 0100h
          head_rip = { { "F", "D", "F" }, "LP", "tap", 75 } },
  [9] = { tongue = { { "B", "B", "D" }, "LP", "tap", 208 }, slice = { { "F", "F", "D" }, "HK", "tap", 80 } },
  [10] = { toasty = { { "D", "D", "U", "U" }, "HP", "tap", 160 }, slice = { { "D", "F", "F", "F" }, "HP", "open", 80 },
           umk3 = { { "D", "U", "U", "U" }, "HK", "tap", 80 } },
  -- (a Block-tap "arm_rip_blk" used to sit here: no such pattern exists - scom_jx_db1 is Jax's only one)
  [11] = { arm_rip = { { "F", "F", "F" }, "LP", "open", 55 } },   -- limit 053h, charge 040h
}
-- Stage fatalities ("death to the pit"): one per fighter, legal only on the four
-- stages check_dtp (MOVES.ASM) allows - the Bridge pit (6), Kombat Tomb (1),
-- YOTEIGAI TOR (0x18) and THE PIT/MK1 (0x1a).
local DTP_STAGES = { [1] = true, [6] = true, [0x18] = true, [0x1a] = true }
local STAGE_FATAL = {
  [0] = { { "F", "F", "F" }, "HP" },      -- Kung Lao
  { { "B", "F", "F" }, "LK" },            -- Liu Kang
  { { "D", "D", "D" }, "HK" },            -- Cage
  { { "F", "F", "D" }, "HK" },            -- Baraka
  { { "F", "D", "F" }, "HK" },            -- Kitana  (fn1_hi_kick - HIGH KICK, not Block)
  -- Mileena: joyskip lets later pattern steps SKIP entries, so F,D,F also satisfies her
  -- teleport kick F,F - checked first in fn2_lo_kick - and it steals the fatality every
  -- time, for a human too. The teleport needs both Fs within 018h ticks, the stage
  -- fatality allows 024h, so enter it SLOWLY: spread over 30 ticks (the 3rd field).
  { { "F", "D", "F" }, "LK", 30 },        -- Mileena (fn2_lo_kick - LOW KICK)
  { { "D", "D", "U", "D" }, nil },        -- Shang   (st_down - the final DOWN is the trigger)
  { { "U", "U" }, "HP" },                 -- Raiden
  { { "D", "F", "F" }, "BL" },            -- Sub-Zero (the ninja input)
  { { "D", "F", "F" }, "BL" },            -- Reptile
  { { "D", "F", "F" }, "BL" },            -- Scorpion
  { { "U", "U", "D" }, "LK" },            -- Jax
  -- Ermac: ermac_block falls through to check_nj_dtp - the ninja input is his too
  [17] = { { "D", "F", "F" }, "BL" },
}
local BABY = { [0] = { { "B", "B", "F", "F" }, "HK" }, { { "D", "D", "F", "B" }, "LK" }, { { "B", "B", "B" }, "HK" },
  { { "F", "F", "F" }, "HK" }, { { "D", "D", "D" }, "LK" }, { { "D", "D", "D" }, "HK" }, { { "B", "F", "D" }, "HK" },
  { { "D", "D", "U" }, "HK" }, { { "D", "B", "B" }, "HK" }, { { "D", "B", "B" }, "LK" }, { { "D", "B", "B" }, "HK" },
  { { "D", "U", "D", "U" }, "LK" } }

local function finisher_macro(dirs, button, style)
  -- AUTOMATIC, like special(): the motion goes into the input queue instead of the stick.
  -- "open" finishers are checked when the BUTTON IS RELEASED, so hold it, queue the motion
  -- while it is held, then let go. "dirs" finishers are checked on the LAST DIRECTION's own
  -- press, so queue the others and tap that one for real.
  if AUTO_SPECIALS and #dirs > 0 then
    if style == "open" then
      -- CHARGED: every release-triggered finisher checks how long the button was held
      -- (get_tsl, 40-64 ticks - Kitana's kiss says "gotta charge this puppy"). 30 was
      -- never enough, so Jax, Kung Lao and Kitana landed none; 72 covers the longest.
      return { hold(72, button), { n = 4, keys = { button }, inject = dirs }, hold(4) }
    elseif style == "dirs" then
      local lead = {}
      for i = 1, #dirs - 1 do lead[#lead + 1] = dirs[i] end
      return { { n = 3, keys = { dirs[#dirs] }, inject = lead }, hold(2) }
    end
  end
  local m = {}
  if style == "open" then
    m[#m + 1] = hold(30, button)
    for _, d in ipairs(dirs) do m[#m + 1] = hold(3, d, button); m[#m + 1] = hold(2, button) end
    m[#m + 1] = hold(4)
  elseif style == "dirs" then
    for _, d in ipairs(dirs) do m[#m + 1] = hold(3, d); m[#m + 1] = hold(2) end
  else
    return special(dirs, { button })
  end
  return m
end

-- INNATE MOVES (flyinv, MAINEQU.ASM). A ROM with the fly's move service lets the fly ask for
-- a special or finisher by NUMBER - no joystick motion, no button: the ROM runs that fighter's
-- own handler with the pattern answered "matched", so every cooldown, range gate and refusal a
-- person gets still applies. tools/flybrain_moves.lua (tools/make_fly_moves.py) lists what this
-- build has, per fighter, read out of its switch handlers. FLY.on is decided on the first
-- fight frame: only when the ROM has fly_invoke AND its table is the same length as the list
-- (a mismatched pair would ask for one move and get another). Otherwise the old input-queue
-- path below is used. FB_INVOKE=0 forces the old path.
local FLY = { cat = nil, on = false, checked = false, body = nil,     -- one local: the chunk is at Lua's 200
              now = 0, last = {} }   -- last[switch] = frame the fly last used that button
-- A CHARGE move (hold = N) only works when its button has gone unused for N ticks - the
-- handler measures the time since the last press, and a person charges it by holding the
-- button that long. The fly is held to the same: offered only once it is charged.
function FLY.charged(e) return not e.hold or (FLY.now - (FLY.last[e.sw] or -100000)) >= e.hold end
do
  local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)[/\\]") or "."
  -- FB_MOVES: the move catalogue to use. tools/flybrain_moves.lua is GENERATED from the
  -- source tree and changes whenever someone adds a special, so a rig on a FROZEN ROM must
  -- read the copy frozen with it - the live one belongs to whatever is being built now.
  -- (A mismatch is caught: FLY.on needs rom_n == FLY.cat.count, and falls back to driving
  -- specials through the input queue - but that is a different fly mid-experiment.)
  local ok, cat = pcall(dofile, os.getenv("FB_MOVES") or (here .. "/flybrain_moves.lua"))
  if ok and type(cat) == "table" then FLY.cat = cat end
  -- FB_G5_PROBE=1: also watch for the post-round freeze and dump every live process
  -- while it is parked (tools/gstate5_probe.lua). MAME takes only one boot script.
  if os.getenv("FB_G5_PROBE") == "1" then pcall(dofile, here .. "/gstate5_probe.lua") end
  -- FB_ADDON=<lua file>: a probe that rides along (MAME takes one boot script). It gets its own
  -- frame callbacks and reads FB_MAP itself; errors are printed, never fatal to the fly.
  if os.getenv("FB_ADDON") then
    local ok, err = pcall(dofile, os.getenv("FB_ADDON"))
    if not ok then print("[fly] FB_ADDON failed: " .. tostring(err)) end
  end
end
-- FLY.body: the ochar the fly's body has now (Shang morphs change it)
function FLY.macro(e, after)
  -- A BUTTON SEQUENCE (seq, idx 0xFFFC: a bcom_ record read by button_look_lr - Kitana's fan
  -- decap Block x3 + HK, Jax's Block x4 + LP, Jade's impale, Shang's Block x3 into Kitana).
  -- The ROM's fly service forces only STICK patterns, so these are pressed like a person: one
  -- tap every 8 ticks, inside every record's window (020h-040h for the whole motion).
  if e.seq then
    local m = {}
    for _, k in ipairs(e.seq) do m[#m + 1] = hold(3, k); m[#m + 1] = hold(5) end
    m[#m] = hold(after or 8)
    return m
  end
  return { { n = 1, keys = {}, invoke = e }, { n = after or 8, keys = {} } }
end

local function uses_punch(m)
  for _, st in ipairs(m) do
    for _, k in ipairs(st.keys) do if k == "HP" or k == "LP" then return true end end
    -- an invoked move on the HP/LP switch runs that button's handler, which stamps l_hp/l_lp
    -- exactly as a press would (so the babality refuses it the same way)
    if st.invoke and not st.invoke.open and (st.invoke.sw == 0 or st.invoke.sw == 1) then return true end
  end
  return false
end

local function options_for(char, bucket, kicks_only)
  local list = {}
  for name, o in pairs(BASIC) do
    for _, r in ipairs(o.r) do
      if r == bucket and not (kicks_only and uses_punch(o.m)) then list[#list + 1] = { name = name, m = o.m } end
    end
  end
  if FLY.on then
    local body = FLY.body or char
    for _, e in ipairs(FLY.cat.moves[body] or {}) do
      -- a charge move (0FFFDh) only where the ROM runs it: FB_CHARGE_INVOKE=1, which
      -- run_flybrain_play.ps1 sets from a CHARGE_OK marker beside the frozen ROM (builds
      -- from 2026-09-22 04:23 on). Older ROMs drop the request, so there it is never offered.
      if (e.cls == "special" or (e.cls == "morph" and body == 6)) and FLY.charged(e)
         and (e.idx ~= 0xFFFD or os.getenv("FB_CHARGE_INVOKE") == "1") then
        for _, r in ipairs(e.r) do
          if r == bucket then
            local m = FLY.macro(e)
            if not (kicks_only and uses_punch(m)) then list[#list + 1] = { name = "sp_" .. e.name, m = m } end
          end
        end
      end
    end
    if body == 19 and bucket == 1 then          -- kicks only, so legal in a kicks_only round too
      -- RAIN'S SUPER ROUNDHOUSE IS NOW PLAIN BACK+HK (2026-09-22): rain_rh_pair and its hook
      -- in JOY's joy_sweep_kick were removed, so the old Back+HK+LK entry here asked for an
      -- input that no longer exists - and BASIC.roundhouse already presses Back+HK, so the
      -- fly reaches the super through the move it always had.  What it could NOT reach is the
      -- KNEE LINK: the ordinary knee, then Back+HK inside UMK3's combo window (ticks 4-9
      -- after contact).  An early press is LATCHED and fires on tick 4, so the fly does not
      -- have to hit the window - it presses straight after the knee.  27 over 2 hits.
      list[#list + 1] = { name = "sp_knee_super", m = { hold(3, "HK"), hold(4), hold(3, "B", "HK"), hold(14) } }
    end
    -- THREE MOVES THE INNATE PATH CANNOT REACH.  make_fly_moves.py walks combo_look_lr, so
    -- the catalogue holds every STICK-MOTION special - and nothing else.  These are a LINK,
    -- a LINK and a CHORD, none of which is a scom, so the fly has to press them like a
    -- person.  (Checked 2026-09-27: the catalogue is byte-identical to rom34's, so none of
    -- the last five days' moves arrived through it.)
    -- EVERY entry below goes through uses_punch, exactly as the catalogue's do: a kicks_only
    -- round is what keeps a BABALITY legal, and sp_slide holds LOW PUNCH.  Added
    -- without the filter first, and the rig promptly used it in a kicks_only round.
    if body == 1 and bucket == 1 then          -- kicks only, so legal in a kicks_only round
      -- LIU KANG'S DOUBLE KNEE (lkdknee, MAINEQU; MKLKDK.ASM): close knee, HK again.  The
      -- knee's reaction is chosen AT CONTACT, so the second High Kick has to be in the queue
      -- BEFORE the knee lands - pre-dialled, it stuns and the carry-on kicks him down into
      -- the floor (20 + 11 = 31 over 2 hits); one press, or a late one, is retail's launch.
      -- The HP backfist third link this used to press was removed from the game.
      list[#list + 1] = { name = "sp_double_knee", m = { hold(3, "HK"), hold(3), hold(3, "HK"), hold(24) } }
    end
    if body == 15 and bucket <= 2 and not kicks_only then
      -- NOOB'S SLIDE (Sub-Zero's, on Sub-Zero's chord: Away + LP + BL + LK, slide_check in
      -- noob_lo_kick).  A CHORD, not a scom, so the catalogue never lists it.
      list[#list + 1] = { name = "sp_slide", m = { hold(4, "B", "LP", "BL", "LK"), hold(16) } }
    end
    if body == 6 then   -- no punch in the chord, so it is legal either way
      -- SHANG -> RAIN (stmorph_rain, MAINEQU; stlk2 / st_rain_holding, MOVES): hold Down and
      -- BLOCK, tap Low Kick.  A CHORD, not a motion - st_rain_holding reads the block bit
      -- straight off @switch, because button_mask refuses every combo special while block is
      -- held, which is exactly what makes the gesture free.  Offered at every range, like
      -- his other morphs.
      list[#list + 1] = { name = "sp_2_rain", m = { hold(4, "D", "BL"), hold(3, "D", "BL", "LK"), hold(10) } }
    end
    if char == 6 and body ~= 6 then   -- morphed: no punch, legal either way
      -- SHANG DROPS THE MORPH (shang_unmorph, MAINEQU; shang_unmorph_check, MOVES): Block + Up
      -- + High Kick, out of any of his forms.  Block keeps Up from being a jump and refuses
      -- every combo special, so the gesture collides with nothing.
      list[#list + 1] = { name = "sp_unmorph", m = { hold(4, "BL", "U"), hold(3, "BL", "U", "HK"), hold(10) } }
    end
    table.sort(list, function(x, y) return x.name < y.name end)
    return list
  end
  for name, s in pairs(SPECIALS[char] or {}) do
    for _, r in ipairs(s[3]) do
      if r == bucket then
        local m
        if #s[1] == 0 then m = { hold(4, table.unpack(s[2])), hold(12) } else m = special(s[1], s[2]) end
        if not (kicks_only and uses_punch(m)) then list[#list + 1] = { name = "sp_" .. name, m = m } end
      end
    end
  end
  table.sort(list, function(x, y) return x.name < y.name end)
  return list
end
local function defence_move(name)
  if DEF_MOVES[name] then return DEF_MOVES[name] end
  return BASIC[name].m
end

-- ------------------------------------------------------------------ learner
local W = {}          -- W[char][ctx][option] = weight
local W_INIT, W_MIN, W_MAX = 10, 2, 120
-- RAIN IS SCORPION'S BODY. A new fighter starts with nothing, but Rain is a ninja on the shared
-- TABLE1 - the same punches, kicks, jumps and blocks as Scorpion (MKNJ). (Noob seeds the same
-- way from Sub-Zero, Ermac from Reptile and Jade from Kitana.) So a situation he has
-- never met starts as a copy of what Scorpion knows about the moves they SHARE; the specials
-- (sp_*) are his own and start fresh. It seeds a starting point, it decides nothing: from the
-- first round on he learns his own weights and they drift apart.
local function weights(char, ctx)
  W[char] = W[char] or {}
  if W[char][ctx] == nil then
    local src = ({ [19] = 10, [15] = 8, [17] = 9, [16] = 4 })[char]   -- inline: the chunk is at the 200-local ceiling
    local from = src and W[src] and W[src][ctx]
    -- FB_WHIFF: a "pulling back" situation (class x) is new to every brain trained before it.
    -- It starts as a copy of the same situation with him REACHING (class r), which is what the
    -- brain called it until now, so nothing it knows is thrown away - it refines from there.
    if not from and ctx:match("^r%dx") then
      local rc = ctx:gsub("^(r%d)x", "%1r")
      from = W[char] and W[char][rc]
    end
    local t = {}
    if from then for k, v in pairs(from) do if k:sub(1, 3) ~= "sp_" then t[k] = v end end end
    W[char][ctx] = t
  end
  return W[char][ctx]
end
-- Every decision pulls its context's weights a little back toward W_INIT
-- (FB_DECAY, default 1% per decision). Without it an option punished early sits
-- at W_MIN for good, even after the ladder has moved on to other opponents and a
-- harder CPU - the first long runs got worse in their second half.
local DECAY = tonumber(os.getenv("FB_DECAY") or "0.01")
-- Per-OPPONENT leanings, learned on top of the context weights: the same option
-- can be right against Jax and wrong against Raiden, and learning that separately
-- in every context would need far more rounds than a run provides. W_opp is a
-- second, smaller table added to the context weight at pick time.
local W_opp = {}
local function opp_weights(opp)
  W_opp[opp] = W_opp[opp] or {}
  return W_opp[opp]
end
-- THE MUSHROOM BODY (FB_MB=1): the fly's own learning circuit in place of the table above.
-- The table learns every situation on its own - nothing learned at range 2 carries to
-- range 3. The mushroom body does it the fly's way:
--   1. KENYON CELLS. Each samples ~7 inputs at random. Fly PN->KC wiring is measurably
--      close to random (Caron et al. 2013), so a random expansion IS the anatomy here.
--      2,000 of them: one hemisphere's worth (MaleCNS v1.0 has 4,064 KCs).
--   2. APL. One giant inhibitory cell holds the Kenyon cells sparse: only the top ~5% of
--      a situation's code fires. Similar situations share cells; different ones do not.
--   3. DOPAMINE-GATED PLASTICITY at the Kenyon cell -> output neuron synapse: reward
--      (the PAM cluster) strengthens and punishment (PPL1) weakens, and only on the cells
--      that were active at the decision. Output neurons are one per option.
-- The INPUT is the same information the table keys on - the fighter, the range bucket and
-- the situation's letters - so an A/B compares the LEARNERS, not what they were told. For
-- an identical situation it learns at exactly the table's rate (a credit of k moves that
-- situation's value by k); the difference is that part of it lands on similar ones too.
-- Sizes chosen by a sweep against the unit test (tmp/flybrain/luacheck/mb_sweep.lua): 5%
-- active is the fly's own APL level, and 16-of-256 channels per input gives a GRADED code -
-- r2c shares 81% of its cells with r2cw, 48% with r3c, 68% with another fighter's r2c and
-- 22% with "finish". A random expansion cannot make inputs less alike than they are, so
-- that is the trade: learning spreads to neighbours, and the cells a neighbour does not
-- share are where its differences are learned.
MB = { on = os.getenv("FB_MB") == "1", nkc = 2000, fan = 7, active = 100, G = 256, per_tok = 16,
       char_width = tonumber(os.getenv("FB_MB_CHAR") or "16"),
       conj = os.getenv("FB_MB_CONJ") ~= "0",
       glom = {}, nglom = 0, kc_in = nil, jit = nil, w = {}, cache = {}, learned = 0 }
function MB.init()
  -- a FIXED wiring (its own generator, not the run's seed): an anatomy, not a dice roll
  local seed = 2026
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
  MB.kc_in, MB.jit = {}, {}
  for k = 1, MB.nkc do
    local ins = {}
    for j = 1, MB.fan do ins[j] = rnd(MB.G) end
    MB.kc_in[k] = ins
    MB.jit[k] = rnd(1000) / 2000          -- breaks ties between equally driven cells, < 0.5
  end
end
-- The situation as projection-neuron channels ("glomeruli"): the fighter, then the range
-- and each letter of an r-context, or the whole name for the others (t_air, finish ...).
-- FB_MB_CHAR: how many channels the FIGHTER gets, against per_tok for everything else.
-- At equal width a lesson learned as Liu Kang carried 68% of the way to every other
-- fighter, which is the likeliest reason the first version lost to the table - move sets
-- differ, so that sharing costs more than it gives. Widening the fighter pushes different
-- fighters' situations apart without losing the sharing BETWEEN ranges. 0 = equal width.
function MB.tokens(char, ctx)
  local t = { { "c" .. tostring(char), MB.char_width } }
  local rng, rest = ctx:match("^r(%d+)(.*)$")
  if rng then
    t[#t + 1] = "R" .. rng
    local seen = {}
    for ch in rest:gmatch(".") do
      seen[ch] = (seen[ch] or 0) + 1
      t[#t + 1] = ch .. (seen[ch] > 1 and tostring(seen[ch]) or "")
    end
    if rest == "" then t[#t + 1] = "plain" end
    -- ...and THIS FIGHTER AT THIS RANGE as its own input. Widening the fighter alone
    -- separated fighters (68% -> 38% shared) but blurred that fighter's own situations
    -- together (an unrelated "finish" rose to 60%), because one wide input then dominates
    -- the code. A conjunction keeps the two apart: fighters differ AND situations differ.
    if MB.conj then t[#t + 1] = "c" .. tostring(char) .. "R" .. rng .. rest end
  else
    t[#t + 1] = ctx
    if MB.conj then t[#t + 1] = "c" .. tostring(char) .. "_" .. ctx end
  end
  return t
end
-- Each input is a POPULATION: 16 of 256 channels, fixed by the token's own name (so the
-- code is the same in every run and a saved brain reloads onto the same cells). One
-- channel per input was tried first and its unit test came out BACKWARDS - r2c shared 15
-- cells with r2cw (one letter apart) and 64 with "finish" (nothing alike): with only 3-5
-- channels lit, most Kenyon cells tie on one input and the tie-break picks the same cells
-- for everything. At ~15% of channels lit - odour-like - the input decides who fires.
-- tok is a name, or {name, width} for an input that gets more channels than the rest
function MB.glomeruli(tok)
  local width = MB.per_tok
  if type(tok) == "table" then tok, width = tok[1], tok[2] end
  local g = MB.glom[tok]
  if g then return g end
  local seed = 2166136261
  for i = 1, #tok do seed = ((seed ~ tok:byte(i)) * 16777619) % 4294967296 end
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
  g = {}
  local have = {}
  while #g < width do
    local x = rnd(MB.G)
    if not have[x] then have[x] = true; g[#g + 1] = x end
  end
  MB.glom[tok] = g
  MB.nglom = MB.nglom + 1
  return g
end
-- The Kenyon cells a situation fires: count each cell's active inputs, keep the top
-- `active` (APL), ties broken by the cell's own fixed jitter. Cached - it never changes.
function MB.kcs(char, ctx)
  local key = tostring(char) .. "|" .. ctx
  local hit = MB.cache[key]
  if hit then return hit end
  if not MB.kc_in then MB.init() end
  local on = {}
  for _, tok in ipairs(MB.tokens(char, ctx)) do
    for _, g in ipairs(MB.glomeruli(tok)) do on[g] = true end
  end
  local drive = {}
  for k = 1, MB.nkc do
    local c = 0
    for _, g in ipairs(MB.kc_in[k]) do if on[g] then c = c + 1 end end
    if c > 0 then drive[#drive + 1] = { k, c + MB.jit[k] } end
  end
  table.sort(drive, function(x, y) return x[2] > y[2] end)
  local list = {}
  for i = 1, math.min(MB.active, #drive) do list[i] = drive[i][1] end
  MB.cache[key] = list
  return list
end
-- An output neuron's drive for one option: the synapses from the cells that fired,
-- on top of the same starting value the table uses.
function MB.raw(kcs, opt)
  local s = 0
  for _, k in ipairs(kcs) do
    local row = MB.w[k]
    if row and row[opt] then s = s + row[opt] end
  end
  return W_INIT + s
end
function MB.value(kcs, opt)
  return math.max(W_MIN, math.min(W_MAX, MB.raw(kcs, opt)))
end
-- Dopamine: spread a credit over the active cells so that THIS situation moves by exactly
-- k (clipped to the table's bounds, as the table's own entries are).
function MB.learn(kcs, opt, k)
  if #kcs == 0 then return end
  local raw = MB.raw(kcs, opt)
  local want = math.max(W_MIN, math.min(W_MAX, raw + k))
  local per = (want - raw) / #kcs
  if per == 0 then return end
  for _, c in ipairs(kcs) do
    local row = MB.w[c]
    if not row then row = {}; MB.w[c] = row end
    row[opt] = (row[opt] or 0) + per
  end
  MB.learned = MB.learned + 1
end
-- The table's forgetting (FB_DECAY): pull this situation's value back toward the start.
function MB.decay(kcs, opt, rate)
  for _, c in ipairs(kcs) do
    local row = MB.w[c]
    if row and row[opt] then row[opt] = row[opt] * (1 - rate) end
  end
end

-- WHAT IT HAS LEARNED, for the dashboard's /learning panel. Written at every round end to
-- <dash>.learn.json: this session's record and its last 200 rounds, the record against
-- each opponent, and - read straight out of the weights - its favourite answer in the
-- situations a viewer can picture, in plain words. Nothing here changes how it plays.
-- REFLEX SPLIT (FB_REFLEX_SPLIT=1). Every ground threat was ONE situation, t_ground, so the
-- reflex learned one answer for all of them: the learning panel showed SWEEP at 11.6x its
-- alternatives - a high attack up close, a crouching poke and a lunge from mid range all got
-- the same sweep. Split it by range and what he is doing (the keys every other choice already
-- uses), so each can learn its own answer. A new split starts as a COPY of the old t_ground
-- weights, so on its first use it is exactly as good as the one-note reflex it replaces.
REFLEX = { split = os.getenv("FB_REFLEX_SPLIT") == "1", tally = {} }  -- global: 200 locals
-- OUTCOMES (FB_OUTCOMES, on unless "0"): one row per decision in <out>/outcomes.csv - what the
-- fly chose, where, against whom, and the damage dealt and taken before its NEXT decision (or
-- OUTC.win frames, whichever is first). Each hit is charged to the most recent decision only,
-- so nothing is counted twice. It is the raw material for tools/flybrain_exploits.py: which
-- moves the stock CPU cannot handle, per CPU fighter and range - the list to fix in MKDRONE.
-- FB_EPS=<p>: with probability p a fight decision is a uniformly random legal move instead of
-- the learner's pick - MEASURING runs only (use with -NoLearn), so starved moves get sampled.
-- FB_ROUND_MODE=normal: never play a kicks_only round.  Measuring runs only, for the same
-- reason as FB_EPS.  kicks_only is what keeps a BABALITY legal, and it is 26% of rounds in
-- practice (8,281 of 31,818 in the fly3_eyes trainer) - in every one of them uses_punch strips
-- the punches out of the option list, so no amount of exploration can sample a jab, a low
-- punch or a throw there.  Leave it unset for training: a fly that cannot choose kicks_only
-- cannot set up a babality.
OUTC = { on = os.getenv("FB_OUTCOMES") ~= "0", fh = nil, cur = nil, win = 90, rows = 0,
         eps = tonumber(os.getenv("FB_EPS") or "0") or 0,                 -- global: 200 locals
         force_normal = os.getenv("FB_ROUND_MODE") == "normal",
         pattern = nil }
-- FB_PATTERN=<option,option,...>: a SCRIPTED ADVERSARY. Every fight decision takes the next
-- option in this list that is legal at the current range, instead of the learner's pick.
--
-- It exists because the fly cannot find what we are looking for. The CPU wins 85% of rounds
-- against it at difficulty 7 (145 of 170, measured 2026-09-28), and against an opponent it
-- beats that badly every choice it makes shows a damage profit - 2,269 logged drone decisions,
-- not one net-negative cell. A weakness only appears as lost health if the other man can take
-- it, so damage cannot be the yardstick here. A fixed pattern, executed every time, asks a
-- narrower and answerable question: of N identical attempts, how many did the drone ANSWER.
-- Rates survive an opponent mismatch. Net damage does not, which is why the one CPU fix that
-- ever measured (act_rhouse_sd) was measured as a rate.
--
-- THIS IS AN INSTRUMENT, NOT THE FLY. A pattern repeats perfectly and so is a better executor
-- than a person - that is the point when probing, and it is exactly what the fly itself must
-- never be. It is confined to measuring runs: it needs -NoLearn (a learner fed a forced choice
-- learns the forcing, not the game), it is never on in a trainer or a stream, and the rows it
-- writes are named pat_<option> so no analysis can mistake them for the fly playing.
do
  local list = os.getenv("FB_PATTERN")
  if list and list ~= "" then
    OUTC.pattern, OUTC.pat_i = {}, 0
    for n in list:gmatch("[^,%s]+") do OUTC.pattern[#OUTC.pattern + 1] = n end
  end
end
-- FB_PROBE_MOVES=jab,low_punch,throw: spend the exploration on THESE moves instead of
-- spreading it over everything.  Uniform exploration cannot measure a rare option in
-- reasonable time, and the arithmetic says so: eps 0.30 over the whole option list gave 6 jabs
-- in 2,397 decisions (measure01), because a close-range decision is about a quarter of them
-- and there are ~25 options in the list - so filling flybrain_exploits.py's 30-tries-per-cell
-- for jab across twelve CPUs would take tens of hours.  Concentrated on four moves it is about
-- an hour.  The fly still PLAYS normally for the other 70% of its decisions, so the CPU it is
-- measured against is facing a real fight and not a jab drill.
do
  local list = os.getenv("FB_PROBE_MOVES")
  if list and list ~= "" then
    OUTC.probe = {}
    for n in list:gmatch("[^,%s]+") do OUTC.probe[n] = true end
  end
end
function OUTC.flush(now)
  local c = OUTC.cur
  OUTC.cur = nil
  if not (c and OUTC.on) then return end
  if not OUTC.fh then
    OUTC.fh = io.open(OUT .. "/outcomes.csv", "w")
    if not OUTC.fh then OUTC.on = false; return end
    OUTC.fh:write("frame,fly,cpu,diff,stage,kind,ctx,dist,move,dealt,taken,first_dealt,first_taken,span\n")
  end
  OUTC.fh:write(string.format("%d,%s,%s,%d,%02x,%s,%s,%d,%s,%d,%d,%d,%d,%d\n", c.frame, c.fly, c.cpu, c.diff,
    c.stage, c.kind, c.ctx, c.dist, c.move, c.dealt, c.taken, c.fd or -1, c.ft or -1, math.min(now - c.frame, OUTC.win)))
  OUTC.rows = OUTC.rows + 1
  if OUTC.rows % 50 == 0 then OUTC.fh:flush() end
end
-- p_action values a new input can interrupt: idle, the walk/crouch/turn set, and the two
-- "reacting but free again" codes.  Hoisted off OUTC.begin so BLAME below tests the fighter
-- the same way the outcome log does.
OUTC.FREE = { [0x0000] = 1, [0x0301] = 1, [0x0302] = 1, [0x0303] = 1, [0x0304] = 1, [0x0305] = 1,
              [0x0306] = 1, [0x0307] = 1, [0x0700] = 1, [0x0701] = 1 }
function OUTC.begin(now, kind, fly, cpu, diff, stage, ctx, dist, move)
  -- A decision only COUNTS if the fighter could act on it. An invoked special is a 9-frame
  -- request, so the fly decides again while its fighter is still inside the move, and those
  -- decisions do nothing - left as owners they took the credit for a fireball landing 40
  -- frames later. Free = p_action in the non-attacking set a new input can interrupt.
  local act = OUTC.p1act and OUTC.p1act() or 0   -- defined below r16/r32/sym (they are locals)
  if not OUTC.FREE[act] then
    if OUTC.on and OUTC.fh then
      OUTC.fh:write(string.format("%d,%s,%s,%d,%02x,%s_busy,%s,%d,%s,0,0,-1,-1,0\n", now, CHAR_NAME[fly] or fly,
        CHAR_NAME[cpu] or cpu, diff, stage, kind, ctx, math.floor(dist or -1), move))
    end
    return
  end
  OUTC.flush(now)
  OUTC.cur = { frame = now, kind = kind, fly = CHAR_NAME[fly] or fly, cpu = CHAR_NAME[cpu] or cpu, diff = diff,
               stage = stage, ctx = ctx, dist = math.floor(dist or -1), move = move, dealt = 0, taken = 0 }
end
function OUTC.hit(now, dealt, taken)
  local c = OUTC.cur
  if not c or now - c.frame > OUTC.win then return end
  if dealt > 0 then c.dealt = c.dealt + dealt; c.fd = c.fd or (now - c.frame) end
  if taken > 0 then c.taken = c.taken + taken; c.ft = c.ft or (now - c.frame) end
end
function REFLEX.seed(char, ctx, parent)
  local mine = W[char]
  if mine and mine[ctx] == nil and mine[parent] then
    local t = {}
    for k, v in pairs(mine[parent]) do t[k] = v end
    mine[ctx] = t
  end
end
-- The round-history table.  Deliberately not `local` (the chunk is at the 200-local ceiling),
-- but that does NOT make it a global while a local of the same name is in scope - it used to
-- overwrite the FB_LEARN flag, which is now LEARNING.
LEARN = { rounds = 0, wins = 0, hist = "", vs = {} }
LEARN.SITUATIONS = {
  { "r1g", "Up close, he is standing" }, { "r1r", "Up close, he is attacking" },
  { "r1c", "Up close, he is crouching" }, { "r1a", "Up close, he is in the air" },
  { "r2g", "Mid range" }, { "r3g", "Far away" }, { "r1gw", "Backed into the corner" },
  { "t_ground", "Something is coming at it" }, { "t_ground1r", "He attacks it up close" },
  { "t_ground1c", "He crouches in close" }, { "t_ground2r", "He attacks from mid range" },
  { "t_air", "He jumps at it" },
  { "t_proj", "A projectile is coming" },
}
function LEARN.write(char, opp, won)
  LEARN.rounds = LEARN.rounds + 1
  if won then LEARN.wins = LEARN.wins + 1 end
  LEARN.hist = (LEARN.hist .. (won and "1" or "0")):sub(-200)
  local oname = CHAR_NAME[opp] or tostring(opp)
  local v = LEARN.vs[oname] or { 0, 0 }
  if won then v[1] = v[1] + 1 else v[2] = v[2] + 1 end
  LEARN.vs[oname] = v
  LEARN.publish(char, opp)
end
-- Published at round START too, not just round end: the panel's "playing as" otherwise kept
-- showing the last fighter until the new one had finished a whole round.
function LEARN.publish(char, opp)
  local oname = CHAR_NAME[opp] or tostring(opp)
  if not DASHBASE then return end
  local out = {}
  local function add(f, ...) out[#out + 1] = string.format(f, ...) end
  add('{"fighter":%q,"rounds":%d,"wins":%d,"hist":%q,"vs":{', CHAR_NAME[char] or tostring(char),
      LEARN.rounds, LEARN.wins, LEARN.hist)
  local first = true
  for n, r in pairs(LEARN.vs) do add('%s%q:[%d,%d]', first and "" or ",", n, r[1], r[2]); first = false end
  add('},"learned":[')
  first = true
  local mine = W[char] or {}
  for _, sit in ipairs(LEARN.SITUATIONS) do
    local ws = mine[sit[1]]
    if ws then
      local best, bw, sum, n = nil, -1, 0, 0
      for opt, w in pairs(ws) do
        sum, n = sum + w, n + 1
        if w > bw then best, bw = opt, w end
      end
      if best and n > 1 then
        -- how far ahead of its alternatives: its weight against the average of the rest
        local rest = (sum - bw) / (n - 1)
        add('%s{"when":%q,"does":%q,"lead":%.1f}', first and "" or ",", sit[2], best,
            rest > 0 and bw / rest or 1)
        first = false
      end
    end
  end
  add('],"against":%q,"leans":[', oname)
  -- what it has learned about THIS opponent specifically, on top of the situations
  -- W_opp is shared across every fighter the fly has played, so it holds other fighters'
  -- specials too; list only moves THIS fighter has (seen in any of its situations)
  local own = {}
  for _, ws in pairs(mine) do for opt in pairs(ws) do own[opt] = true end end
  local ow, list = W_opp[opp] or {}, {}
  for opt, w in pairs(ow) do if own[opt] and w > 0 then list[#list + 1] = { opt, w } end end
  table.sort(list, function(x, y) return x[2] > y[2] end)
  for i = 1, math.min(3, #list) do add('%s[%q,%.1f]', i > 1 and "," or "", list[i][1], list[i][2]) end
  add(']}')
  local path = DASHBASE .. ".learn.json"
  local fh = io.open(path .. ".tmp", "w")
  if not fh then return end
  fh:write(table.concat(out)); fh:close()
  os.remove(path); os.rename(path .. ".tmp", path)
end

-- Aggression as a lasting mood, the way a fly's P1/pC1 neurons hold an aggressive
-- state for minutes after a fight starts: landing hits raises it, taking them
-- lowers it, and it drifts back on its own. It biases the CHOICE, nothing else.
local MOOD_BASE = 0.45
local mood = MOOD_BASE
local AGGRESSIVE = { jab = 1, low_punch = 1, high_kick = 1, low_kick = 1, sweep = 1, uppercut = 1,
  roundhouse = 1, duck_kick = 1, throw = 1, jump_in = 1 }
local DEFENSIVE = { walk_back = 1, block = 1, duck_block = 1, wait = 1, duck = 1 }
local function mood_bias(n)
  local k = ((OA.use and OA.mood or mood) - MOOD_BASE) * 24
  if AGGRESSIVE[n] or n:sub(1, 3) == "sp_" then return k end
  if DEFENSIVE[n] then return -k end
  return 0
end

-- FB_SHARP (default 1): pick in proportion to weight^SHARP. 1 is the training setting - plenty
-- of exploration, but a clearly better option at 60 among twenty at 10 is still picked only
-- ~23% of the time. 2 or 3 leans on what it has learned (exams/streams), same knowledge.
local SHARP = tonumber(os.getenv("FB_SHARP") or (os.getenv("FB_CURRICULUM") and "2" or "1"))
local function pick(char, ctx, names, bias, opp)
  local w, total = weights(char, ctx), 0
  local ow = opp and opp_weights(opp) or nil
  if MB.on then
    -- the mushroom body's output neurons stand in for the table's entries
    local kcs = MB.kcs(char, ctx)
    w = {}
    for _, n in ipairs(names) do
      if LEARNING and DECAY > 0 then MB.decay(kcs, n, DECAY) end
      w[n] = MB.value(kcs, n)
    end
  end
  local function score(n)
    return math.max(1, w[n] + ((bias and bias[n]) or 0) + ((ow and ow[n]) or 0) + (opp and mood_bias(n) or 0)) ^ SHARP
  end
  for _, n in ipairs(names) do
    w[n] = w[n] or W_INIT
    if LEARNING and DECAY > 0 and not MB.on then w[n] = w[n] + (W_INIT - w[n]) * DECAY end
    total = total + score(n)
  end
  local r = math.random() * total
  for _, n in ipairs(names) do
    r = r - score(n)
    if r <= 0 then return n end
  end
  return names[#names]
end
local function bump(char, ctx, opt, amount)
  if not LEARNING then return end
  if MB.on then MB.learn(MB.kcs(char, ctx), opt, amount); return end
  local w = weights(char, ctx)
  w[opt] = math.max(W_MIN, math.min(W_MAX, (w[opt] or W_INIT) + amount))
end
local function save_weights()
  if not WEIGHTS_OUT then return end
  local fh = io.open(WEIGHTS_OUT .. ".tmp", "w")
  fh:write("return {\n  opp = {\n")
  for opp, ws in pairs(W_opp) do
    fh:write(string.format("    [%d] = {", opp))
    for n, x in pairs(ws) do fh:write(string.format(" [%q]=%.3f,", n, x)) end
    fh:write(" },\n")
  end
  fh:write("  },\n  w = {\n")
  for char, ctxs in pairs(W) do
    fh:write(string.format("  [%d] = {\n", char))
    for ctx, ws in pairs(ctxs) do
      fh:write(string.format("    [%q] = {", ctx))
      for n, x in pairs(ws) do fh:write(string.format(" [%q]=%.3f,", n, x)) end
      fh:write(" },\n")
    end
    fh:write("  },\n")
  end
  fh:write("  },\n}\n")
  fh:close()
  os.remove(WEIGHTS_OUT)
  os.rename(WEIGHTS_OUT .. ".tmp", WEIGHTS_OUT)
end
if WEIGHTS_IN then
  local ok, t = pcall(dofile, WEIGHTS_IN)
  if ok and type(t) == "table" and t.w then
    -- new format: context weights plus the per-opponent table
    W, W_opp = t.w, t.opp or {}
    print("[fly] loaded weights (with per-opponent leanings) from " .. WEIGHTS_IN)
  elseif ok and type(t) == "table" then
    W = t; print("[fly] loaded weights (old format) from " .. WEIGHTS_IN)
  else print("[fly] no weights loaded from " .. WEIGHTS_IN .. ": " .. tostring(t)) end
end

local recent = {}     -- { frame, char, ctx, option }

-- WHO OWNS A HIT (FB_BLAME, default "fixed" = what it has always done).
--
-- `fixed`: damage at frame F credits every decision in [F-window, F], decayed linearly by
-- age.  Two things are wrong with that, and they pull the same way.  The blame window is 45
-- frames and a JUMP-IN takes about 42 from press to landing, so a jump-in that gets punished
-- on the way down falls outside its own window - it never pays for it, and whatever the fly
-- chose after landing pays instead.  And inside the window the decay means the longer a move
-- takes to resolve, the less of its own outcome it is charged: committal moves are
-- systematically flattered against quick ones.
--
-- `recovery`: a decision owns everything that happens while the move it started is still
-- running - the fighter is not FREE - and only then starts to decay, over the same window,
-- from the frame it recovered.  So the length of a move no longer decides how much of its
-- consequence reaches it.  This is the same ownership rule OUTC.begin already applies to the
-- outcome LOG (an invoked special is a 9-frame request, so the fly decides again while its
-- fighter is still committed; those decisions did nothing and must not be owners) - the
-- LEARNER never got it.
--
-- Not a global table by accident: a bare name is how MB/OA/LEARN avoid the chunk's 200-local
-- ceiling, and `BLAME` collides with no local in this file (LEARN did, which is the bug
-- above).
BLAME = { recovery = os.getenv("FB_BLAME") == "recovery",
          settle = 12,      -- a decision that never made the fighter busy resolved in this
          cap = 180 }       -- ...and nothing owns anything for longer than this

-- Called once per fight frame, BEFORE the life bars are read.  Closes each decision at the
-- moment its move gave the fighter back.
function BLAME.step(now, free)
  if not BLAME.recovery then return end
  for _, d in ipairs(recent) do
    if not d.free_at then
      if not free then
        d.busy = true                          -- the move is under way
      elseif d.busy then
        d.free_at = now                        -- it just gave him back: start the decay here
      elseif now - d.frame >= BLAME.settle then
        d.free_at = d.frame + BLAME.settle     -- never committed him - nothing to wait for
      end
      if not d.free_at and now - d.frame > BLAME.cap then d.free_at = now end
    end
  end
end
local function credit(frame, amount, window)
  if not LEARNING then return end
  for _, d in ipairs(recent) do
    -- age 0 while the move it started is still running, so it owns that stretch outright
    local age = BLAME.recovery and (d.free_at and (frame - d.free_at) or 0) or (frame - d.frame)
    if age >= 0 and age <= window then
      local k = amount * (1.0 - age / (window + 1))
      if MB.on then
        MB.learn(MB.kcs(d.char, d.ctx), d.opt, k)      -- dopamine onto the cells that fired
      else
        local w = weights(d.char, d.ctx)
        w[d.opt] = math.max(W_MIN, math.min(W_MAX, (w[d.opt] or W_INIT) + k))
      end
      if d.opp then
        local ow = opp_weights(d.opp)
        ow[d.opt] = math.max(-20, math.min(20, (ow[d.opt] or 0) + k * 0.4))
      end
    end
  end
end
local function dump_weights(tag)
  local fh = io.open(OUT .. "/weights.txt", "a")
  fh:write(string.format("== %s\n", tag))
  for char, ctxs in pairs(W) do
    for ctx, ws in pairs(ctxs) do
      local t = {}
      for n, x in pairs(ws) do t[#t + 1] = { n, x } end
      table.sort(t, function(p, q) return p[2] > q[2] end)
      local s = {}
      for k = 1, math.min(6, #t) do s[#s + 1] = string.format("%s=%.0f", t[k][1], t[k][2]) end
      fh:write(string.format("  %-9s %-8s %s\n", CHAR_NAME[char] or char, ctx, table.concat(s, " ")))
    end
  end
  fh:close()
end

-- ------------------------------------------------------------------ runtime state
local cpu, space, screen, fields = nil, nil, nil, {}
local frame = 0
local function r16(x) return space:read_u16(x) end
local function r32(x) return space:read_u32(x) end
local function w16(x, val) space:write_u16(x, val & 0xffff) end
local function w32(x, val) space:write_u32(x, val & 0xffffffff) end
-- fly_invoke = [valid:1 | 0:9 | p2:1 | open:1 | switch:4 | index:16] (MAINEQU.ASM flyinv)
function FLY.write(e)
  w32(sym.fly_invoke, 0x80000000 | (e.open and 0x100000 or 0) | ((e.sw & 0xf) << 16) | (e.idx & 0xffff))
end
local function s16(x) x = x & 0xffff; if x >= 0x8000 then return x - 0x10000 end; return x end
local function s32(x) x = x & 0xffffffff; if x >= 0x80000000 then return x - 0x100000000 end; return x end

local game, games_over, fly_char = 0, 0, CHARS[1]
local selections = 0
local last_gs, in_select = -1, false
local sel_frame = 0

-- CHARACTER SELECT WITH THE CURSOR (FB_SEL_MAGIC=1 brings back the old direct write).
-- The fly walks the select grid square by square with the stick and picks with a button,
-- the way a player does. During select p1_char IS the square the cursor is on, so the walk
-- steers by watching it. The neighbours are MKSEL.ASM's own up/down/left/right_change
-- tables (a move off the edge stays put), and each step is a 4-frame tap: the select loop
-- repeats a held stick every 12 frames, so a short tap moves exactly one square.
--   Kang  KungLao  Cage     Reptile
--   SubZ  Shang    Kitana   Jax
--   Mil   Baraka   Scorpion Raiden
-- Jade and Ermac are reached the way a player reaches them: Low Kick x5 on Mileena (the
-- fifth press confirms her), and a clean Start tap on Reptile followed by a confirm.
local SEL_MAGIC = os.getenv("FB_SEL_MAGIC") == "1"
-- FB_PICK: who the fly plays at each select. cycle = FB_CHARS in order (training); random = a
-- random fighter from FB_CHARS, walked to; gamerandom = the game's own random select (hold Up,
-- tap Start on the starting square, Liu Kang for P1 - auto_select_check, MAIN.ASM); mix =
-- random, with the game's random select about one time in four (streams).
local PICK = os.getenv("FB_PICK") or "cycle"
local sel_random = false
local SEL_NEXT = {   -- [square] = { up, down, left, right }
  [0] = { 0, 6, 1, 2 },  [1] = { 1, 8, 1, 0 },  [2] = { 2, 4, 0, 9 },  [3] = { 6, 3, 5, 10 },
  [4] = { 2, 10, 6, 11 }, [5] = { 8, 5, 5, 3 }, [6] = { 0, 3, 8, 4 },  [7] = { 11, 7, 10, 7 },
  [8] = { 1, 5, 8, 6 },  [9] = { 9, 11, 2, 9 }, [10] = { 4, 10, 3, 7 }, [11] = { 9, 7, 4, 11 } }
local SEL_DIR = { "P1 Up", "P1 Down", "P1 Left", "P1 Right" }
local function sel_first_step(from, to)
  -- breadth-first over the grid; returns the direction of the first step
  local seen, queue = { [from] = true }, {}
  for d = 1, 4 do
    local n = SEL_NEXT[from][d]
    if not seen[n] then seen[n] = true; queue[#queue + 1] = { n, d } end
  end
  local i = 1
  while queue[i] do
    local sq, d0 = queue[i][1], queue[i][2]
    if sq == to then return d0 end
    for d = 1, 4 do
      local n = SEL_NEXT[sq][d]
      if not seen[n] then seen[n] = true; queue[#queue + 1] = { n, d0 } end
    end
    i = i + 1
  end
end
local sel = nil
local function sel_cursor(press, target, how)
  if not sel or sel.at ~= sel_frame then
    sel = { at = sel_frame, busy_until = 0, seq = nil, step = 0, logged = false }
  end
  local t = frame - sel_frame
  if t < 45 or frame < sel.busy_until then return end      -- let the screen settle, then pace
  local cur = r16(sym.p1_char)
  if not SEL_NEXT[cur] then return end                         -- cursor not on the grid yet
  if not sel.seq then
    if cur ~= target then
      local d = sel_first_step(cur, target)
      if d then press[SEL_DIR[d]] = true; sel.hold, sel.key = 4, SEL_DIR[d]; sel.busy_until = frame + 16 end
      return
    end
    -- on the square: a short look, then the pick
    if how == "gamerandom" then
      -- hold Up (Liu Kang cannot move up, so the cursor stays put) and tap Start inside it;
      -- the game then walks the cursor itself and confirms. Try again only if it is still
      -- sitting in select long after.
      sel.chord, sel.seq = 16, {}
      sel.busy_until = frame + 900
      return
    elseif how == "jade" and sym.jade_pos then
      -- (Rain and Ermac take the "ermac" branch: one Start tap on their morph square.)
      -- builds with the box morphs: Jade is a clean Start tap on KITANA (she moved
      -- off Mileena 2026-09-25), like Ermac
      sel.seq = { "1 Player Start", "P1 High Punch" }
    elseif how == "jade" then
      -- older builds: Low Kick x5 on Mileena, the fifth press confirms her
      sel.seq = { "P1 Low Kick", "P1 Low Kick", "P1 Low Kick", "P1 Low Kick", "P1 Low Kick" }
    elseif how == "ermac" then
      sel.seq = { "1 Player Start", "P1 High Punch" }
    elseif how == "rain" then
      -- Block x5 on Scorpion (check_rain_blk_cheat, MKSEL.ASM); the fifth press confirms him.
      -- The game tests Rain FIRST on Scorpion's square, so this is never an ordinary confirm.
      sel.seq = { "P1 Block", "P1 Block", "P1 Block", "P1 Block", "P1 Block" }
    else
      sel.seq = { "P1 High Punch" }
    end
    sel.step, sel.busy_until = 0, frame + 20
    return
  end
  -- button sequence: 4 frames down, then up long enough for the game's edge detect
  if sel.hold and sel.hold > 0 then return end
  sel.step = sel.step + 1
  local k = sel.seq[sel.step]
  if not k then
    -- still selecting a second after the last press: start the pick again
    sel.seq, sel.busy_until = nil, frame + 60
    return
  end
  sel.hold, sel.key = 4, k
  press[k] = true
  sel.busy_until = frame + (k == "1 Player Start" and 30 or 12)
end
local function sel_hold_tick(press)
  -- keep a tapped key down for its 4 frames (the pacing gate above skips those frames)
  if sel and sel.chord and sel.chord > 0 then
    press["P1 Up"] = true
    if sel.chord <= 11 and sel.chord >= 7 then press["1 Player Start"] = true end
    sel.chord = sel.chord - 1
  end
  if sel and sel.hold and sel.hold > 0 then
    press[sel.key] = true
    sel.hold = sel.hold - 1
  end
end
local percept_prev, percept_now = nil, nil
local macro, macro_step, macro_left = nil, 0, 0
local armed_at, armed_ctx, armed_bias, refractory_until = nil, nil, nil, 0
local ground1, ground2 = nil, nil
local bars = nil
local rs = nil        -- round stats
local round_open = false
local moving_oids = {}
local mode, punched = "normal", false    -- kicks_only keeps the babality legal
local stand_h = nil                      -- his standing sprite height, for the crouch test
local vis_ctx = nil
local fin = nil                           -- FINISH HIM state
local finlog = io.open(OUT .. "/finishers.csv", "w")
finlog:write("frame,game,battle,round,fly_char,cpu_char,mode,punched,option,try,success\n")

local KEYMAP = { U = "P1 Up", D = "P1 Down", HP = "P1 High Punch", LP = "P1 Low Punch", HK = "P1 High Kick",
  LK = "P1 Low Kick", BL = "P1 Block" }
local ALLKEYS = { "P1 Up", "P1 Down", "P1 Left", "P1 Right", "P1 High Punch", "P1 Low Punch", "P1 High Kick",
  "P1 Low Kick", "P1 Block", "Coin 1", "1 Player Start" }

-- OFF by default: measured at difficulty 2 (same brain + seed) it LOST, 45% vs 57% of rounds.
-- The gate did make every move start from a free state, but the fly then decided 16 times a
-- round instead of 42 - and ibuf (MAINEQU.ASM, 5 ticks) holds a press made late in recovery
-- until the fighter can take it, so pressing early was buffering, not waste.
local GATE = { on = os.getenv("FB_READY_GATE") == "1" }
GATE.acts = { [0x0000] = true, [0x0301] = true, [0x0302] = true, [0x0303] = true, [0x0304] = true,
  [0x0305] = true, [0x0306] = true, [0x0307] = true, [0x0700] = true, [0x0701] = true }
local function start_macro(m, why)
  macro, macro_step, macro_left = m, 1, m[1].n
end

-- The opponent's POSE, from the art actually on screen: walk his multipart piece
-- records (the same ones the renderer draws) and measure the drawn box. A person
-- sees exactly this - how tall he is, and how far he is reaching at us - so it
-- keeps the no-advantage rule, unlike reading his move id out of RAM.
local MP = { sag = 0, sizex = 32, sizey = 48, control = 64, anix = 80, aniy = 96, len = 112 }
local function pose_of(obj, x, facing_left)
  local mp = r32(obj + 0x1a0)
  if mp == 0 then return nil end
  local reach, top, bottom, n = 0, 9999, -9999, 0
  while n < 11 do
    local sag = r32(mp + MP.sag)
    if sag == 0 then break end
    local sx, sy = r16(mp + MP.sizex), r16(mp + MP.sizey)
    local ax, ay = s16(r16(mp + MP.anix)), s16(r16(mp + MP.aniy))
    if sx > 0 and sx < 300 and sy > 0 and sy < 300 then
      -- piece box relative to the fighter's anchor
      local left = -ax
      local right = left + sx
      local far = facing_left and -left or right      -- how far it reaches toward the fly
      if far > reach then reach = far end
      local t = -ay
      if t < top then top = t end
      if t + sy > bottom then bottom = t + sy end
    end
    mp = mp + MP.len; n = n + 1
  end
  if n == 0 or top > bottom then return nil end
  return { reach = reach, height = bottom - top, pieces = n }
end

-- SENSES beyond the two eyes. Everything here is on the screen or is the fly's OWN body,
-- which is what the no-advantage rule allows: where the arena ends, how fast it is moving,
-- whether it is off the ground, whether the two of them are touching, the round clock, the
-- flash and the shake. None of it reads the opponent's move.
local SENSE = { cam = nil, camy = nil, flow = 0, shake = 0, startle = 0,
                on = os.getenv("FB_SENSES") ~= "0",    -- FB_SENSES=0: perceive, but do not act on them
                ctx = os.getenv("FB_SENSE_CTX") ~= "0",   -- wall/air in the learner's situation
                -- FB_WHIFF=1: tell an attack coming out (r) from one being PULLED BACK (x) -
                -- the punish window. Read off the same drawn art as reach: his furthest reach
                -- over the last 12 frames against now. On screen, so no advantage.
                whiff = os.getenv("FB_WHIFF") == "1", rh = {} }
local function perceive()
  local p1, p2 = r32(sym.p1_obj), r32(sym.p2_obj)
  if p1 == 0 or p2 == 0 then return nil end
  local p = { x1 = s16(r16(p1 + O.oxpos)), y1 = s16(r16(p1 + O.oypos)),
              x2 = s16(r16(p2 + O.oxpos)), y2 = s16(r16(p2 + O.oypos)),
              bar1 = r16(sym.p1_bar), bar2 = r16(sym.p2_bar), proj = {} }
  -- HOW MUCH ROOM IS BEHIND ME. The arena's walls, which a player can see coming.
  if sym.left_edge and sym.right_edge then
    local le, re = s16(r16(sym.left_edge)), s16(r16(sym.right_edge))
    if re > le then
      local facing_right = p.x2 >= p.x1
      p.room_back = facing_right and (p.x1 - le) or (re - p.x1)
      p.room_fwd = facing_right and (re - p.x1) or (p.x1 - le)
    end
  end
  -- MY OWN BODY: how fast I am moving, and whether I am off the ground (a fly's halteres
  -- are gyroscopes; a player feels both). ground1 is this round's floor, set at round start.
  p.vx1 = s32(r32(p1 + O.oxvel)) / 65536.0
  p.vy1 = s32(r32(p1 + O.oyvel)) / 65536.0
  p.air1 = ground1 and (ground1 - p.y1) or 0
  p.landing = p.air1 > 2 and p.vy1 > 0
  -- TOUCHING: the two bodies pressed together, what a fly's leg bristles would report
  p.touch = math.abs(p.x2 - p.x1) <= S.fighter_half_w * 2 + 6
  -- WIDE-FIELD FLOW (a fly's HS/VS cells): the whole background sliding past. It is how an
  -- insect tells "the world is moving because I am" from "something is coming at me", and
  -- the camera's own travel is exactly that signal.
  if sym.worldtlx then
    -- signed 16.16 (and worldtly goes NEGATIVE on stages above the origin - The Dead Pool
    -- sits at -8): floor division keeps the sign, Lua's >> does not
    local cam = s32(r32(sym.worldtlx)) // 65536
    SENSE.flow = SENSE.cam and (cam - SENSE.cam) or 0
    if math.abs(SENSE.flow) > 40 then SENSE.flow = 0 end     -- a cut (round start, a teleport), not flow
    SENSE.cam = cam
  end
  -- SHAKE (the quake of a heavy landing) rides the camera's y, which nothing else moves
  -- during a round. Antennae and leg bristles are what a fly feels this with.
  if sym.worldtly then
    local camy = s32(r32(sym.worldtly)) // 65536
    -- only a REVERSAL counts: the camera also follows jumps up and down, smoothly;
    -- a quake jerks it back and forth
    local dy = SENSE.camy and (camy - SENSE.camy) or 0
    if math.abs(dy) > 40 then dy = 0 end
    -- a single reversal is also the top of every jump the camera follows; a quake is
    -- several, close together
    SENSE.shake = 0
    if (SENSE.lastdy or 0) * dy < 0 and math.abs(dy) >= 2 then
      if SENSE.rev_at and frame - SENSE.rev_at <= 8 then SENSE.shake = math.abs(dy) end
      SENSE.rev_at = frame
    end
    if dy ~= 0 then SENSE.lastdy = dy end
    SENSE.camy = camy
  end
  -- THE OCELLI: three simple eyes that only measure light and drive startle. The game's
  -- flash band (MKDISP flash_ticks) and the background fade are its light changes.
  p.flash = (sym.flash_ticks and r16(sym.flash_ticks) or 0)
  p.fade = (sym.f_fade and r16(sym.f_fade) or 0)
  if p.flash > 0 or SENSE.shake >= 3 then SENSE.startle = frame end
  -- THE CLOCK, which a player watches, and the blood a fly would smell
  -- what it has heard lately: the count decays, so a busy exchange reads as loud
  p.heard_ago = SENSE.heard and (frame - SENSE.heard) or 999
  SENSE.heard_n = (SENSE.heard_n or 0) * 0.94
  p.loud = SENSE.heard_n
  if p.heard_ago <= 2 and p.flash and p.flash > 0 then SENSE.startle = frame end
  p.clock = (sym.clk_tens and (r16(sym.clk_tens) * 10 + r16(sym.clk_ones)) or 99)
  p.blood = (sym.blood_count and r16(sym.blood_count) or 0)
  p.opp_pal = r16(p2 + 0x140)          -- his colours: costume and fighter, as a fly would see them
  SENSE.last = p                       -- for the HUD
  -- this round's peaks, so a log line can show what each sense actually did
  local pk = SENSE.peak
  if pk then
    pk.flow = math.max(pk.flow, math.abs(SENSE.flow)); pk.shake = math.max(pk.shake, SENSE.shake)
    pk.air = math.max(pk.air, p.air1 or 0); pk.loud = math.max(pk.loud, p.loud or 0)
    pk.blood = math.max(pk.blood, p.blood or 0)
    if p.touch then pk.touch = pk.touch + 1 end
    if p.room_back and p.room_back < 70 then pk.corner = pk.corner + 1 end
    if p.flash and p.flash > 0 then pk.flash = pk.flash + 1 end
  end
  p.pose = pose_of(p2, p.x2, p.x1 < p.x2)
  if SENSE.whiff then
    local h = SENSE.rh
    h[#h + 1] = p.pose and p.pose.reach or 0
    if #h > 12 then table.remove(h, 1) end
    local pk = 0
    for i = 1, #h do if h[i] > pk then pk = h[i] end end
    p.rpeak = pk
  end
  local o, n = r32(sym.objlst), 0
  while o ~= 0 and n < 200 do
    if o ~= p1 and o ~= p2 then
      local vx = s32(r32(o + O.oxvel)) / 65536.0
      if math.abs(vx) >= 1.5 then
        local oid = r16(o + O.oid)
        if not moving_oids[oid] then moving_oids[oid] = true; log("moving object oid %x vx %.1f", oid, vx) end
        local hi = oid & 0xff00
        if hi == 0x0700 or hi == 0x0800 then
          local x = s16(r16(o + O.oxpos))
          -- EVERY moving speck, not only the ones already coming at the fly (a fly's
          -- small-object cells track anything small that moves). The looming circuit
          -- answers to approach on its own, so one going away simply does not fire it -
          -- but a boomerang that turns round, or a ball thrown past, is now seen.
          if (x - p.x1) * vx < 0 then p.proj[#p.proj + 1] = x
          else p.specks = p.specks or {}; p.specks[#p.specks + 1] = x end
        end
      end
    end
    o = r32(o + O.next); n = n + 1
  end
  return p
end

function SENSE.line(p)
  -- what each sense did over the round just played, then a fresh set of peaks
  local pk = SENSE.peak
  if pk then
    log("SENSES last round: flow %d shake %d | air %d | touching %d frames | cornered %d | flash %d | loud %.0f blood %d",
        pk.flow, pk.shake, pk.air, pk.touch, pk.corner, pk.flash, pk.loud, pk.blood)
  end
  SENSE.peak = { flow = 0, shake = 0, air = 0, touch = 0, corner = 0, flash = 0, loud = 0, blood = 0 }
  if LOOMH then
    -- buckets: 0 | 1-7 | 8-15 | 16-31 | 32-63 | 64-127 | 128-254 | 255
    for _, cls in ipairs({ "proj", "air", "gnd_me", "gnd_him" }) do
      local h = LOOMH[cls]
      if h and h.n > 0 then
        local function row(t) local o = {} for i = 1, 8 do o[i] = t[i] or 0 end return table.concat(o, "/") end
        log("LOOM %-7s frames %6d threat %5.1f%% | LC4 %s | LPLC2 %s", cls, h.n, 100 * h.thr / h.n, row(h.l4), row(h.lp))
      end
    end
    LOOMH = {}
  end
  SENSE.cam, SENSE.camy, SENSE.lastdy = nil, nil, nil      -- a new round starts a new view
  log("SENSES: room back %s fwd %s | clock %d | pal %04x", tostring(p.room_back), tostring(p.room_fwd),
      p.clock or -1, p.opp_pal or 0)
end

-- OUTC's view of player 1's p_action, here because r16/r32/sym are locals declared above
function OUTC.p1act()
  local q = sym.p1_proc and r32(sym.p1_proc) or 0
  return q ~= 0 and r16(q + 0x1f0) or 0
end

local function round_begin(p)
  rs = { start = frame, dealt = 0, taken = 0, defences = 0, decisions = 0 }
  pcall(LEARN.publish, fly_char, r16(sym.p2_char))
  ground1, ground2 = p.y1, p.y2
  bars = { p.bar1, p.bar2 }
  recent = {}
  macro, armed_at, refractory_until = nil, nil, 0
  for i = 1, N do v[i] = 0; a[i] = 0 end
  prev_theta = {}
  round_open = true
  last_progress = frame
  SENSE.line(p)
  fin = nil
  -- how to play this round: normally, or with no punches so a babality or
  -- a fly that is ahead and unhurt plays the next round with no punches, which is
  -- what keeps the babality legal when it comes to FINISH HIM
  local ahead = r16(sym.p1_matchw) > r16(sym.p2_matchw) and p.bar1 >= 0x60
  if OUTC.force_normal then mode = "normal"
  else mode = pick(fly_char, "round_mode", { "normal", "kicks_only" }, ahead and { kicks_only = 8 } or nil) end
  punched = false
  stand_h = nil
  mood = MOOD_BASE + (mood - MOOD_BASE) * 0.5     -- the mood carries over, half faded
  -- DID THE GAME ACTUALLY GIVE US THE FIGHTER WE ASKED FOR?  fly_char is the INTENT - the
  -- pick, not a read - and every line below it (the move table, the brain's per-fighter
  -- weights, this log) is keyed on it, so a select that quietly lands on the wrong square is
  -- invisible: the fly drives one body with another fighter's moves for the whole round and
  -- nothing reads wrong anywhere.  That is not hypothetical.  Rain moved off Scorpion +
  -- Block x5 onto a Start tap on Sub-Zero (rain_select_enable is 0 now), which turned the
  -- old route into an ORDINARY CONFIRM: ask for Rain, get Scorpion, no error anywhere.  No
  -- past run hit it - rain_select_enable went 0 at 2026-09-22 19:14 and the last frozen pair
  -- (rom34, 14:51) predates it, so the cheat still worked in every ROM that has been flown.
  -- It was armed for the next restart, which is when this was found.  Only ROUND 1 adopts,
  -- because a morph changes p1_char mid-round on purpose (Shang) and adopting that would
  -- take his morph options away for the rest of the battle.
  local really = r16(sym.p1_char)
  if really ~= fly_char and CHAR_NAME[really] then
    if r16(sym.round_num) <= 1 then
      log("*** SELECT MISMATCH: asked for %s, the game gave %s - adopting %s so the moves and "
          .. "brain match the body being driven", CHAR_NAME[fly_char] or fly_char,
          CHAR_NAME[really], CHAR_NAME[really])
      fly_char = really
    else
      log("note: p1_char is %s, not %s (a morph - left alone mid-battle)",
          CHAR_NAME[really], CHAR_NAME[fly_char] or fly_char)
    end
  end
  log("round start game=%d battle=%d round=%d fly=%s cpu=%s diff=%d stage=%02x mode=%s", game, r16(sym.battle_num),
      r16(sym.round_num), CHAR_NAME[fly_char] or fly_char, CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char),
      r16(sym.diff), r16(sym.curback), mode)
end

-- CURRICULUM (FB_CURRICULUM=<state file>). Continues carry the fly up the ladder until it
-- sits where it almost never wins - 2,661 rounds at difficulty 6 overnight, 1-5% won - and
-- a learner fed nothing but losses learns little. So pin the CPU difficulty where the fly
-- wins 30-60%, and move it one step when a 20-40 round window says it has outgrown it (or
-- is drowning). The state file survives segment restarts. Pinning `diff` also pins the
-- fly's OWN reaction floor (drone_react_delay is read at that same difficulty), so the
-- fairness rule moves with it.
local CURR = os.getenv("FB_CURRICULUM")
local curr = nil
if CURR then
  curr = { d = 2, win = {} }
  local fh = io.open(CURR, "r")
  if fh then
    local t = fh:read("*a"); fh:close()
    curr.d = tonumber(t:match("diff=(%d+)")) or curr.d
    for c in (t:match("window=([01]*)") or ""):gmatch("[01]") do curr.win[#curr.win + 1] = tonumber(c) end
  end
end
local function curr_save()
  local fh = io.open(CURR, "w")
  if fh then fh:write(string.format("diff=%d\nwindow=%s\n", curr.d, table.concat(curr.win))); fh:close() end
end
-- BOSSES DO NOT VOTE. Kintaro (12) and Shao Kahn (13) are hard at every difficulty - the fly
-- won 3-8% of 835 Kintaro rounds at difficulties 0-2 - and continues keep it retrying them,
-- so they were most of every window: the curriculum read "losing" and dropped to difficulty 0
-- sixteen times in two hours while the fly was beating the twelve regular fighters 82-100%.
-- Difficulty is chosen on the opponents difficulty actually governs.
local CURR_BOSS = { [12] = true, [13] = true }
local BOSS_CAP = curr ~= nil and os.getenv("FB_BOSS_CAP") ~= "0"
-- FB_KAHN_EVERY=N: every Nth GAME starts on Shao Kahn's rung and stays there. The fly
-- reaches him on its own now and then grinds - 535 boss rounds in one measured pair of runs
-- for ONE round won - so the time is already being spent; this makes it deliberate, and the
-- opponent weights (W_opp, keyed on his ochar) are where what it learns there lands. The
-- curriculum never votes on boss rounds (CURR_BOSS), so its difficulty is unaffected.
-- one table, not three locals: the chunk is at Lua's 200-local ceiling
local KAHN = { every = tonumber(os.getenv("FB_KAHN_EVERY") or "0"),
               rung = tonumber((os.getenv("FB_KAHN_RUNG") or "14"):match("%d+")),   -- FB_FORCE_RUNG calls this Kahn
               -- FB_KAHN_RUNG="13,14": boss games alternate Kintaro and Shao Kahn
               rungs = (os.getenv("FB_KAHN_RUNG") or ""):find(",") and (function(t)
                 for n in os.getenv("FB_KAHN_RUNG"):gmatch("%d+") do t[#t + 1] = tonumber(n) end
                 return t end)({}) or nil,
               -- FB_FORCE_OPP=<ochar>: TEST RIGS ONLY - every rung of the tower is that fighter,
               -- written right after select like FB_FORCE_RUNG (so set_drone_ochar picks it up)
               opp = tonumber(os.getenv("FB_FORCE_OPP") or ""),
               game = false }
local cap_first, cap_resets = nil, 0
local function curr_round(won, opp)
  if CURR_BOSS[opp] then return end
  curr.win[#curr.win + 1] = won and 1 or 0
  while #curr.win > 40 do table.remove(curr.win, 1) end
  if #curr.win >= 20 then
    local w = 0
    for _, v in ipairs(curr.win) do w = w + v end
    local rate = w / #curr.win
    local was = curr.d
    if rate > 0.60 and curr.d < 9 then curr.d = curr.d + 1 elseif rate < 0.30 and curr.d > 0 then curr.d = curr.d - 1 end
    if curr.d ~= was then
      log("CURRICULUM: won %d%% of the last %d at difficulty %d -> now %d", math.floor(rate * 100 + 0.5), #curr.win, was, curr.d)
      curr.win = {}
    end
  end
  curr_save()
end

-- MOVES LOG (diagnostic only - nothing here reaches a decision). Which game actions follow
-- each attack the fly starts, so a special can be judged LANDED or DROPPED offline: landed if
-- it produced an action code the basic moves never produce. p_action is the move id the
-- no-advantage rule keeps out of perception; logging it for a human to read is fine.
local moves_fh = io.open(OUT .. "/moves.csv", "w")
-- `start` is the action the fighter was in when the attack was pressed. Only attacks started
-- from a neutral stance can be judged fairly: one pressed mid flying kick inherits the flying
-- kick's action code, and with the flying kick at half of all attacks that carry-over hid it
-- completely from every other test.
if moves_fh then moves_fh:write("frame,char,opt,diff,start,acts\n") end
local mv = nil
local function mv_flush()
  if mv and moves_fh then
    local a = {}
    for k in pairs(mv.acts) do a[#a + 1] = string.format("%04x", k) end
    table.sort(a)
    moves_fh:write(string.format("%d,%s,%s,%d,%04x,%s\n", mv.frame, CHAR_NAME[mv.char] or mv.char, mv.opt, mv.diff,
      mv.start, table.concat(a, ";")))
  end
  mv = nil
end
local function mv_begin(opt)
  mv_flush()
  local q = r32(sym.p1_proc)
  mv = { frame = frame, char = fly_char, opt = opt, diff = r16(sym.diff), acts = {},
         start = q ~= 0 and r16(q + 0x1f0) or 0xffff }
end
local function mv_tick()
  if not mv then return end
  local q = r32(sym.p1_proc)
  if q ~= 0 then mv.acts[r16(q + 0x1f0)] = true end
  if frame - mv.frame > 45 then mv_flush() end
end

local function round_end()
  OUTC.flush(frame)
  local b1, b2 = r16(sym.p1_bar), r16(sym.p2_bar)
  -- the rig's fly_char is what it INTENDED; p1_char is what the game actually fielded.
  -- Every per-fighter table (moves, brain) is keyed on fly_char, so a mismatch means the
  -- fly spent the round driving one body with another fighter's moves and brain.
  if r16(sym.p1_char) ~= fly_char then
    log("MISMATCH: the fly meant to play %s but the game fielded %s", CHAR_NAME[fly_char] or fly_char,
        CHAR_NAME[r16(sym.p1_char)] or r16(sym.p1_char))
  end
  local winner = (b1 > b2) and "FLY" or ((b2 > b1) and "CPU" or "DRAW")
  pcall(LEARN.write, fly_char, r16(sym.p2_char), winner == "FLY")
  if curr and (curr.round_d or curr.d) == curr.d then curr_round(winner == "FLY", r16(sym.p2_char)) end
  rounds:write(string.format("%d,%d,%d,%d,%s,%s,%d,%s,%d,%d,%d,%d,%d,%d,%d,%s,%s\n", frame, game, r16(sym.battle_num),
    r16(sym.round_num), CHAR_NAME[fly_char] or fly_char, CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char),
    r16(sym.diff), winner, b1, b2, frame - rs.start, rs.dealt, rs.taken, rs.defences, rs.decisions, mode,
    punched and "1" or "0"))
  -- the round's result is the verdict on how it was played
  if not OUTC.force_normal then bump(fly_char, "round_mode", mode, winner == "FLY" and 3 or -2) end
  save_weights()
  rounds:flush()
  if moves_fh then moves_fh:flush() end
  log("round end: %s  fly_bar=%d cpu_bar=%d  dealt=%d taken=%d defences=%d decisions=%d  wins fly=%d cpu=%d",
      winner, b1, b2, rs.dealt, rs.taken, rs.defences, rs.decisions, r16(sym.p1_matchw), r16(sym.p2_matchw))
  if MB.on then
    local cells = 0
    for _ in pairs(MB.w) do cells = cells + 1 end
    log("MUSHROOM BODY: %d situations coded, %d input channels, %d of %d Kenyon cells carry learning, %d updates",
        (function() local n = 0 for _ in pairs(MB.cache) do n = n + 1 end return n end)(),
        MB.nglom, cells, MB.nkc, MB.learned)
  end
  do
    local parts = {}
    for k, v in pairs(REFLEX.tally) do parts[#parts + 1] = k .. " " .. v end
    table.sort(parts)
    if #parts > 0 then log("REFLEXES%s: %s", REFLEX.split and " (split)" or "", table.concat(parts, ", ")) end
    REFLEX.tally = {}
  end
  if BODY.rs and BODY.rs.n > 0 then
    local r = BODY.rs
    log("BODY felt (mean 0-255): front legs %.0f  mid %.0f  hind %.0f  abdomen %.0f  over %d frames",
        r.T1 / r.n, r.T2 / r.n, r.T3 / r.n, r.A / r.n, r.n)
    BODY.rs = nil
  end
  if OA.rs and OA.rs.n > 0 then
    local r = OA.rs
    log("MOOD %s: hand mean %.2f [%.2f..%.2f]  octopamine mean %.2f [%.2f..%.2f]  "
        .. "OA cells %d potential %.0f rest %.0f spread %.0f max %.0f", OA.use and "octopamine decides" or "shadow",
        r.hs / r.n, r.hlo, r.hhi, r.os / r.n, r.olo, r.ohi, #OA.idx, OA.level, OA.rest or 0,
        OA.spread or 0, r.top)
    OA.rs = nil
  end

  if screen then pcall(function() screen:snapshot() end) end
  dump_weights(string.format("frame %d game %d battle %d round %d %s", frame, game, r16(sym.battle_num),
    r16(sym.round_num), winner))
  last_progress = frame
  round_open = false
end

-- One queue entry per direction: [switch:16 | tick:16], bit 31 (q_face_left) when facing
-- left. Facing uses sq_stamp_facing's own rule - P2 STRICTLY right of P1 means facing
-- right, a tie stamps left - because two readings that disagree at the boundary drop a
-- motion only when the fighters are exactly level. Entries are spaced 2 ticks apart and
-- end just before now, oldest first, well inside every window (the tightest is 010h).
local SW = { U = 5, D = 6 }
local function inject(dirs, toward, spread)
  local base = sym.p1_jcq
  if not (base and sym.tick) then return end
  local p1o, p2o = r32(sym.p1_obj), r32(sym.p2_obj)
  if p1o == 0 or p2o == 0 then return end
  local function sx(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
  local face_left = not (sx(r16(p2o + O.oxpos)) > sx(r16(p1o + O.oxpos)))
  local fwd = toward == "P1 Right" and 8 or 7          -- sw_right / sw_left, as pushed
  local back = fwd == 8 and 7 or 8
  local now = r16(sym.tick)
  for i, d in ipairs(dirs) do
    local sw = (d == "F" and fwd) or (d == "B" and back) or SW[d]
    if sw then
      -- SPREAD (ticks, optional): lay the motion out over that long instead of 2 ticks a step,
      -- for a move whose shorter-windowed rival would otherwise match it (Mileena's Pit)
      local age = spread and (spread - math.floor((spread - 2) * (i - 1) / math.max(1, #dirs - 1)))
                  or 2 * (#dirs - i + 1)
      local entry = (sw << 16) | ((now - age) & 0xffff)
      if face_left then entry = entry | 0x80000000 end
      local nxt = r32(base)
      w32(nxt, entry)
      nxt = nxt + 32
      if nxt >= base + 21 * 32 then nxt = base + 32 end   -- (sqs+1)*32: wrap to the 1st slot
      w32(base, nxt)
    end
  end
end

local function drive(press, toward, away)
  if not macro then return end
  local step = macro[macro_step]
  if step.inject and macro_left == step.n then inject(step.inject, toward, step.spread) end
  if macro_left == step.n then
    local BTN = { HP = 0, LP = 1, BL = 2, HK = 3, LK = 4 }
    for _, k in ipairs(step.keys) do if BTN[k] then FLY.last[BTN[k]] = frame end end
  end
  if step.invoke and macro_left == step.n then
    if step.invoke.hold and fin then
      -- the GAME's own charge clock too: get_tsl = @tick - l_<button> (update_tsl on every press)
      local lname = ({ [0] = "l_hp", "l_lp", "l_block", "l_hk", "l_lk" })[step.invoke.sw]
      local rom_age = (sym.tick and sym[lname or ""]) and ((r16(sym.tick) - r16(sym[lname])) & 0xffff) or -1
      log("CHARGE RELEASE: %s dist %d, %d ticks since the fly last pressed that button, game clock %d (needs %d)",
          step.invoke.name, math.abs((percept_prev and (percept_prev.x2 - percept_prev.x1)) or -1),
          frame - (FLY.last[step.invoke.sw] or -100000), rom_age, step.invoke.hold)
    end
    FLY.last[step.invoke.sw] = frame
    FLY.write(step.invoke)
    if step.invoke.sw <= 1 and not step.invoke.open then punched = true end
  end
  for _, k in ipairs(step.keys) do
    if k == "F" then press[toward] = true
    elseif k == "B" then press[away] = true
    else
      press[KEYMAP[k]] = true
      if k == "HP" or k == "LP" then punched = true end
    end
  end
  macro_left = macro_left - 1
  if macro_left <= 0 then
    macro_step = macro_step + 1
    if macro_step > #macro then macro = nil else macro_left = macro[macro_step].n end
  end
end

-- FINISH HIM: the CPU stands dazed. Choose how to end it - a fatality, a
-- a babality if no punch was thrown this round, or just walk in and
-- knock him over - get to that move's distance, input it, and see whether a
-- finisher started (f_fatal_lock, set the instant any finisher begins).
-- How dominant the fly's win was, 0..1: health left, plus a bonus for taking the
-- match 2-0. Babality is the most disrespectful thing it can do, so it belongs to
-- a win that was never in doubt; a narrow win gets a plain fatality.
local function swagger(p)
  local health = math.min(1.0, math.max(0.0, p.bar1 / 0xa1))
  local sweep = (r16(sym.p1_matchw) >= 2 and r16(sym.p2_matchw) == 0) and 0.2 or 0.0
  return math.min(1.0, health + sweep)
end

local function finish_tick(p, press)
  local rel = p.x2 - p.x1
  local toward = rel >= 0 and "P1 Right" or "P1 Left"
  local away = rel >= 0 and "P1 Left" or "P1 Right"
  local dist = math.abs(rel)
  if not fin then fin = { phase = "choose", tries = 0, t = 0 } end
  fin.t = fin.t + 1
  if r16(sym.f_fatal_lock) ~= 0 and fin.phase ~= "done" then
    if fin.opt and fin.phase ~= "choose" then
      bump(fly_char, "finish", fin.opt, 30)
      finlog:write(string.format("%d,%d,%d,%d,%s,%s,%s,%d,%s,%d,1\n", frame, game, r16(sym.battle_num), r16(sym.round_num),
        CHAR_NAME[fly_char], CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char), mode, punched and 1 or 0, fin.opt, fin.tries + 1))
      finlog:flush()
      log("FINISHER: %s (%s) try %d", fin.opt, CHAR_NAME[fly_char], fin.tries + 1)
      if screen then pcall(function() screen:snapshot() end) end
    end
    fin.phase, fin.t = "done", 0
  end
  if fin.phase == "done" then
    if fin.spec and fin.spec.mash and fin.t < 600 then
      press[KEYMAP.U] = true                         -- hold Up...
      if fin.t % 8 < 3 then press[KEYMAP.HP] = true end   -- ...and keep tapping HP (window 020h)
      -- the lift's two endings: r_shocker_pop throws BONES (oid_bones 010ch); rd_lift_fizzle,
      -- the mash having stopped, drops him whole. Say which, once per lift.
      if not fin.popped then
        local o, k = r32(sym.objlst), 0
        while o ~= 0 and k < 200 do
          if r16(o + O.oid) == 0x10c then fin.popped = true; log("LIFT: he exploded, %d ticks into the mash", fin.t); break end
          o, k = r32(o + O.next), k + 1
        end
      end
    end
    return
  end

  if fin.phase == "choose" and FLY.on then
    -- every finisher this fighter has in THIS build, asked for directly (flyinv)
    local names, spec = {}, {}
    local body = FLY.body or fly_char
    local on_dtp = DTP_STAGES[r16(sym.curback)]
    for _, e in ipairs(FLY.cat.moves[body] or {}) do
      if e.cls == "fatal" or (e.cls == "stage" and on_dtp) then
        local n = (e.cls == "stage") and "stage_fatality" or ("fatal_" .. e.name)
        if not (e.hold and e.hold > 300) then      -- FINISH HIM does not last long enough to charge more
          names[#names + 1] = n
          spec[n] = { m = FLY.macro(e, 30), d = e.d, charge = e.hold and e }
          -- RAIDEN'S LIFT (rd_hk_open -> do_raiden_lift_fatal): once it starts he has to HOLD UP
          -- AND KEEP TAPPING HP until the body explodes - stop and it just drops
          -- (rd_lift_mash_ok, rd_lift_mash_window 020h ticks since the last HP / Up press)
          -- It is done AFTER the start (the "done" phase below): queued before it, Up + HP on a
          -- dizzy man is a jump punch, which knocks him down and ends FINISH HIM. Its range is
          -- 052h measured the game's way; released at 82 on the fly's count it was refused, so
          -- it closes to 60.
          if e.name == "raiden_lift_fatal" then spec[n].d, spec[n].mash = 60, true end
          -- CHARGE MOVES CANNOT BE INVOKED. make_fly_moves.py lists them as index 0FFFDh ("run
          -- the release handler"), but fly_invoke_poll (MKINIT.ASM) only takes an index inside
          -- the scom table or 0FFFFh (babality) - everything else hits "not in the table" and is
          -- dropped without a trace. Raiden's lift: 4 of 4 releases charged by the GAME's own
          -- clock (282-640 >= 274) and in range (61-67 < 052h), all refused. So a charge
          -- finisher is done the way a person does it: back off out of reach, press and HOLD the
          -- real button while walking in, let go once it has been held long enough - the
          -- release goes through the game's own switch-open path (the "charge" phase below).
          if e.idx == 0xFFFD and os.getenv("FB_CHARGE_FINISH") ~= "invoke" then
            local btn = ({ [0] = "HP", "LP", "BL", "HK", "LK" })[e.sw]
            spec[n].open = { button = btn, dirs = {}, need = e.hold + 12 }
            spec[n].charge = nil
          end
        end
      end
    end
    local BTN_SW = { HP = 0, LP = 1, BL = 2, HK = 3, LK = 4 }
    -- JADE'S STAFF IMPALE (Block, Block, Block, Forward, Block) is catalogued now - as
    -- fatal_jade_impale, a `seq` entry make_fly_moves.py reads off bcom_jade_impale - and so
    -- are Kitana's fan decap and Jax's Block x4 + LP. The hand-written copy that lived here
    -- (fatal_staff_impale) is gone; a brain that learned it relearns the catalogue name.
    -- An older frozen catalogue has no seq entries and simply does not offer them.
    if not punched and BABY[body] then
      names[#names + 1] = "babality"
      spec.babality = { m = FLY.macro({ idx = 0xFFFF, sw = BTN_SW[BABY[body][2]], open = false }, 30), d = 90 }
    end
    if r16(sym.curback) == 0 then      -- THE DEAD POOL: no pattern - an uppercut with LP + LK held
      names[#names + 1] = "stage_fatality"
      spec.stage_fatality = { m = { hold(4, "D", "LP", "LK"), hold(3, "D", "HP", "LP", "LK"), hold(24, "LP", "LK") },
                              d = 45, prehold = { "LP", "LK" } }
    end
    names[#names + 1] = "knock_down"
    spec.knock_down = { m = { hold(4, "D"), hold(3, "D", "HP"), hold(20) }, d = 45 }
    if mode == "kicks_only" then spec.knock_down.m = { hold(3, "B", "HK"), hold(20) } end
    table.sort(names)
    local sw = swagger(p)
    local bias = {}
    if sw >= 0.65 then
      bias.babality = 18; bias.stage_fatality = 6
    elseif sw >= 0.35 then
      bias.stage_fatality = 10
      for _, n in ipairs(names) do if n:sub(1, 6) == "fatal_" then bias[n] = 6 end end
    else
      for _, n in ipairs(names) do if n:sub(1, 6) == "fatal_" then bias[n] = 8 end end
      bias.knock_down = 4
    end
    fin.opt = pick(fly_char, "finish", names, bias)
    -- FB_FINISH=<name>: TEST RIGS ONLY - take that finisher whenever it is on offer, so a new
    -- one can be proved without waiting on the learner to pick it
    for _, n in ipairs(names) do if n == os.getenv("FB_FINISH") then fin.opt = n end end
    log("FINISH HIM: swagger %.2f (health %d) -> %s", sw, p.bar1, fin.opt)
    fin.spec = spec[fin.opt]
    fin.phase, fin.t = "approach", 0
  end
  if fin.phase == "choose" then
    local names, spec = {}, {}
    for name, f in pairs(FATAL[fly_char] or {}) do
      names[#names + 1] = "fatal_" .. name
      spec["fatal_" .. name] = { m = finisher_macro(f[1], f[2], f[3]), d = f[4],
                                 open = f[3] == "open" and { button = f[2], dirs = f[1] } or nil }
    end
    if not punched and BABY[fly_char] then
      names[#names + 1] = "babality"; spec.babality = { m = special(BABY[fly_char][1], { BABY[fly_char][2] }) }
    end
    if DTP_STAGES[r16(sym.curback)] and STAGE_FATAL[fly_char] then
      local sf = STAGE_FATAL[fly_char]
      names[#names + 1] = "stage_fatality"
      spec.stage_fatality = { m = special(sf[1], { sf[2] }), d = 50 }   -- check_dtp: within 048h
      if sf[3] and spec.stage_fatality.m[1].inject then spec.stage_fatality.m[1].spread = sf[3] end
    end
    -- THE DEAD POOL: an uppercut in FINISH HIM with LP + LK held - see flybrain_selfplay.lua
    if r16(sym.curback) == 0 then
      names[#names + 1] = "stage_fatality"
      -- LP + LK are tested when the uppercut CONNECTS (ucut, several frames after the press),
      -- so they stay held through the swing - letting go after the press never slimed anyone
      spec.stage_fatality = { m = { hold(4, "D", "LP", "LK"), hold(3, "D", "HP", "LP", "LK"), hold(24, "LP", "LK") },
                              d = 45, prehold = { "LP", "LK" } }
    end
    names[#names + 1] = "knock_down"
    spec.knock_down = { m = { hold(4, "D"), hold(3, "D", "HP"), hold(20) }, d = 45 }
    if mode == "kicks_only" then spec.knock_down.m = { hold(3, "B", "HK"), hold(20) } end
    table.sort(names)
    -- personality: what this win deserves. The learner still decides in the end -
    -- these are the fly's leanings, added on top of what it has learned lands.
    local sw = swagger(p)
    local bias = {}
    if sw >= 0.65 then
      bias.babality = 18; bias.stage_fatality = 6
    elseif sw >= 0.35 then
      bias.stage_fatality = 10
      for _, n in ipairs(names) do if n:sub(1, 6) == "fatal_" then bias[n] = 6 end end
    else
      for _, n in ipairs(names) do if n:sub(1, 6) == "fatal_" then bias[n] = 8 end end
      bias.knock_down = 4
    end
    fin.opt = pick(fly_char, "finish", names, bias)
    -- FB_FINISH=<name>: TEST RIGS ONLY - take that finisher whenever it is on offer, so a new
    -- one can be proved without waiting on the learner to pick it
    for _, n in ipairs(names) do if n == os.getenv("FB_FINISH") then fin.opt = n end end
    log("FINISH HIM: swagger %.2f (health %d) -> %s", sw, p.bar1, fin.opt)
    fin.spec = spec[fin.opt]
    fin.phase, fin.t = "approach", 0
  end
  -- release-triggered finishers: charge from out of reach - see flybrain_selfplay.lua
  if fin.phase == "approach" and fin.spec.prehold then
    if fin.t < 150 and dist < fin.spec.d + 80 then press[away] = true; return end
    fin.phase, fin.t = "prehold", 0
  end
  if fin.phase == "prehold" then
    for _, k in ipairs(fin.spec.prehold) do press[KEYMAP[k]] = true end
    punched = true
    if dist > fin.spec.d + 8 and fin.t < 200 then press[toward] = true; return end
    start_macro(fin.spec.m, "finish")
    fin.phase, fin.t = "input", 0
    return
  end
  if fin.phase == "approach" and fin.spec.open and AUTO_SPECIALS then
    if fin.t < 150 and dist < fin.spec.d + 80 then press[away] = true; return end
    fin.phase, fin.t, fin.held = "charge", 0, 0
  end
  if fin.phase == "charge" then
    press[KEYMAP[fin.spec.open.button]] = true
    if fin.spec.open.button == "HP" or fin.spec.open.button == "LP" then punched = true end
    fin.held = fin.held + 1
    local need = fin.spec.open.need or 72
    if dist > fin.spec.d + 8 and fin.t < need + 60 then press[toward] = true; return end
    if dist < fin.spec.d - 16 then press[away] = true end    -- a long hold: he can drift in too
    if fin.held < need then return end
    inject(fin.spec.open.dirs, toward)
    fin.phase, fin.t = "release", 0
    return
  end
  if fin.phase == "release" then
    if fin.t >= 2 then fin.phase, fin.t = "wait", 0 end
    return
  end
  if fin.phase == "approach" then
    local d = fin.spec.d
    if d and fin.t < 150 and math.abs(dist - d) > 8 then
      press[(dist > d) and toward or away] = true
      return
    end
    start_macro(fin.spec.m, "finish")
    fin.phase, fin.t = "input", 0
  end
  if fin.phase == "input" and fin.spec.charge and fin.t < 400
     and (FLY.now - (FLY.last[fin.spec.charge.sw] or -100000)) < fin.spec.charge.hold + 10 then
    -- hold off, move still queued: the button is charging. +10: the fly's press reaches the
    -- game a frame or two after it sends it, so a release timed to the tick was 272 by the
    -- game's clock against 274 needed. Keep in range meanwhile - he drifts.
    if fin.spec.d and math.abs(dist - fin.spec.d) > 8 then press[(dist > fin.spec.d) and toward or away] = true end
    return
  end
  if fin.phase == "input" then
    drive(press, toward, away)
    if not macro then fin.phase, fin.t = "wait", 0 end
    return
  end
  if fin.phase == "wait" and fin.t >= 40 then
    if fin.opt ~= "knock_down" then
      bump(fly_char, "finish", fin.opt, -4)
      finlog:write(string.format("%d,%d,%d,%d,%s,%s,%s,%d,%s,%d,0\n", frame, game, r16(sym.battle_num), r16(sym.round_num),
        CHAR_NAME[fly_char], CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char), mode, punched and 1 or 0, fin.opt, fin.tries + 1))
      finlog:flush()
    end
    fin.tries = fin.tries + 1
    fin.phase = (fin.tries >= 5 or fin.opt == "knock_down") and "done" or "choose"
  end
end

-- ------------------------------------------------------------------ overlay
-- FB_OVERLAY=1 draws the fly's brain over the game: the looming detectors it is
-- seeing, the escape neurons lighting up, and what it decided. Pure MAME Lua
-- drawing on top of the emulated screen - the ROM and the fly are untouched, and
-- the fly reads nothing from it.
local OVERLAY = os.getenv("FB_OVERLAY") == "1"
local HUD_SMALL = os.getenv("FB_HUD") == "small"
local vis_action, vis_action_at, vis_move = nil, -999, nil
local function overlay_draw()
  if not OVERLAY or not screen or not VIS then return end
  local W, H = 400, 254
  -- MAME takes the LINE colour first, then the fill
  local function box(x0, y0, x1, y1, fill, line)
    pcall(function() screen:draw_box(x0, y0, x1, y1, line or fill, fill) end)
  end
  local function text(x, y, t, col)
    pcall(function() screen:draw_text(x, y, t, col or 0xffffffff) end)
  end
  local function lamp(x, y, r, level, base)
    -- level 0..255 -> brightness of a small square "neuron"
    local l = math.min(255, math.floor(level))
    local col = 0xff000000 | (((base >> 16 & 0xff) * l // 255) << 16)
                            | (((base >> 8 & 0xff) * l // 255) << 8) | ((base & 0xff) * l // 255)
    box(x - r, y - r, x + r, y + r, col, 0xff202020)
  end
  local d, fam = VIS.drive, VIS.fam
  -- FB_HUD=small: the fly-vs-fly stream's compact panel, top-left under P1's life bar (the
  -- fly is always P1). Name, the two eyes, the escape reflex, mood, and the move it chose.
  if HUD_SMALL then
    local x0, y0, PW = 3, 41, 118
    local function sbar(x, y, w, level, col)
      box(x, y, x + w, y + 3, 0xff101010, 0xff303030)
      local n = math.floor(w * math.min(math.max(level, 0), 255) / 255)
      if n > 0 then box(x, y, x + n, y + 3, col, col) end
    end
    box(x0, y0, x0 + PW, y0 + 38, 0xa0000000, 0xff40a040)
    text(x0 + 2, y0 + 1, "FRUIT FLY", 0xff80ff80)
    sbar(x0 + 64, y0 + 24, 30, (mood or 0.45) * 255, (mood or 0) > 0.5 and 0xffff4040 or 0xff4080ff)
    text(x0 + 97, y0 + 21, (mood or 0) > 0.5 and "hot" or "cool", 0xff608060)
    lamp(x0 + 6, y0 + 16, 3, math.max(d.LC4_L or 0, d.LPLC2_L or 0), 0xff60a0ff)      -- left eye
    lamp(x0 + 16, y0 + 16, 3, math.max(d.LC4_R or 0, d.LPLC2_R or 0), 0xff60a0ff)     -- right eye
    lamp(x0 + 28, y0 + 16, 3, fam.escape or 0, 0xffff4040)                            -- escape reflex
    local recent = frame - vis_action_at < 70 and vis_action
    local mv = (recent or vis_move or ""):gsub("^sp_", "")
    text(x0 + 36, y0 + 12, mv, recent and 0xffffff40 or 0xffd0d0d0)
    text(x0 + 2, y0 + 21, "eyes  panic", 0xff507050)
    -- the body senses: the wall behind it, its ears, its halteres (off the ground)
    local q = SENSE.last or {}
    lamp(x0 + 6, y0 + 32, 3, (q.room_back and q.room_back < 70) and 255 or 0, 0xffffa040)
    lamp(x0 + 16, y0 + 32, 3, (q.heard_ago or 999) < 12 and 255 or 0, 0xff40e0ff)
    lamp(x0 + 26, y0 + 32, 3, (q.air1 or 0) > 20 and 255 or 0, 0xffffffff)
    text(x0 + 34, y0 + 29, "wall ear air", 0xff507050)
    if q.clock then text(x0 + PW - 14, y0 + 29, string.format("%02d", q.clock), 0xff80a080) end
    return
  end
  -- A BOTTOM STRIP, not a box in the corner: a casual viewer needs room for words, and
  -- the floor is the only part of the screen nothing important happens on. It reads left
  -- to right as the signal actually travels: what the eyes see -> what fires -> what it did.
  local px0, py0, px1, py1 = 2, 196, W - 2, 250
  box(px0, py0, px1, py1, 0xb0000000, 0xff40ff40)
  text(px0 + 3, py0 + 2, "FRUIT FLY BRAIN", 0xff80ff80)
  text(px0 + 112, py0 + 2, "what it sees", 0xff6090c0)
  text(px0 + 210, py0 + 2, "what fires", 0xff6090c0)
  text(px0 + 312, py0 + 2, "what it does", 0xff6090c0)

  -- the fly, with an eye lamp each side. Both light when the opponent is close enough to
  -- span the frontal overlap; the near eye leads when he is off to one side.
  local cx, cy = px0 + 46, py0 + 32
  box(cx - 10, cy - 6, cx + 10, cy + 9, 0xff203020, 0xff60a060)
  lamp(cx - 8, cy - 9, 3, math.max(d.LC4_L or 0, d.LPLC2_L or 0), 0xff60a0ff)
  lamp(cx + 8, cy - 9, 3, math.max(d.LC4_R or 0, d.LPLC2_R or 0), 0xff60a0ff)
  text(px0 + 4, py0 + 44, "L eye", 0xff608060)
  text(px0 + 62, py0 + 44, "R eye", 0xff608060)

  -- the two things the eyes measure, named in words rather than cell types
  local function bar(x, y, w, level, col)
    box(x, y, x + w, y + 4, 0xff101010, 0xff303030)
    local n = math.floor(w * math.min(level, 255) / 255)
    if n > 0 then box(x, y, x + n, y + 4, col, col) end
  end
  text(px0 + 112, py0 + 14, "rushing in", 0xffff8080)
  bar(px0 + 112, py0 + 22, 40, d.LC4_L or 0, 0xffff6060)
  bar(px0 + 156, py0 + 22, 40, d.LC4_R or 0, 0xffff6060)
  text(px0 + 112, py0 + 30, "how close", 0xffffc040)
  bar(px0 + 112, py0 + 38, 40, d.LPLC2_L or 0, 0xffffc040)
  bar(px0 + 156, py0 + 38, 40, d.LPLC2_R or 0, 0xffffc040)
  text(px0 + 112, py0 + 46, "left    right", 0xff608060)

  -- the escape neurons, each with the plain-English thing it means
  local esc = { { "PANIC", fam.escape or 0, 0xffff4040 }, { "BACK", fam.jump_bk or 0, 0xff40ff80 },
                { "FWD", fam.jump_fwd or 0, 0xff40c0ff }, { "AWAY", fam.retreat or 0, 0xffc080ff } }
  for k, e in ipairs(esc) do
    local ey = py0 + 12 + (k - 1) * 10
    lamp(px0 + 216, ey + 3, 3, e[2], e[3])
    text(px0 + 224, ey, e[1], e[2] >= (C.fire or 64) and e[3] or 0xff506050)
    bar(px0 + 254, ey + 2, 40, e[2], e[3])
  end

  -- aggression, and the decision itself in words
  text(px0 + 312, py0 + 14, "mood", 0xffff8080)
  bar(px0 + 312, py0 + 22, 76, (mood or 0.45) * 255, (mood or 0) > 0.5 and 0xffff4040 or 0xff4080ff)
  text(px0 + 312, py0 + 28, (mood or 0) > 0.5 and "aggressive" or "cautious", 0xff608060)
  if frame - vis_action_at < 70 and vis_action then
    text(px0 + 312, py0 + 38, vis_action, 0xffffff40)
  elseif vis_move then
    text(px0 + 312, py0 + 38, vis_move, 0xff80a080)
    if vis_ctx then text(px0 + 312, py0 + 46, vis_ctx, 0xff607060) end
  end
end
if OVERLAY then
  local ok = pcall(function() emu.register_frame_done(overlay_draw) end)
  if not ok then print("[fly] overlay: could not register the draw callback") end
end

-- ------------------------------------------------------------- dashboard feed
-- FB_DASH=<file>: publish what the fly is doing, ~20 times a second, for the local
-- dashboard (tools/flybrain_dashboard.py). Written to <file>.tmp and renamed, so the
-- page never reads half a line. Nothing here changes how the fly plays.
-- Published BY DEFAULT: the dashboard was forever showing a stale frame because a rig had
-- been started in a terminal without FB_DASH set, which is not a thing a person should have
-- to remember. FB_DASH names a different file; FB_DASH=0 turns publishing off.
SENSE.dash = os.getenv("FB_DASH") or "C:/tmp/flybrain/dash.json"   -- on SENSE: 200-local ceiling
if SENSE.dash == "0" then SENSE.dash = nil end
-- FB_DASH_SHOT=N: also drop a picture of the screen every N frames, for the page to show.
-- A browser cannot read MAME's window, so the "video" on the page is these stills.
-- Off unless asked: a training rig runs unthrottled at hundreds of frames a second and
-- would spend its time encoding PNGs. run_flybrain_stream.ps1 turns it on.
SENSE.shot_every = tonumber(os.getenv("FB_DASH_SHOT") or "0")
-- Where they land. MAME writes a snapshot relative to -snapshot_directory, which the
-- launcher points at THIS session's folder and moves on every restart, so the rig tells
-- the page where to look rather than the page having to be told again each time.
SENSE.shot_dir = (os.getenv("FB_DASH_SHOTDIR") or ""):gsub("\\", "/")
-- The whole connectome, written ONCE beside the state file: every cell's name and class
-- and every connection between them. The per-tick state then names firing cells by INDEX,
-- which is what makes a 623-cell, 5985-connection picture affordable 18 times a second.
function SENSE.dash_net(path)
  local fh = io.open(path, "w")
  if not fh then return end
  local p = {"{\"nodes\":["}
  for i = 1, N do
    p[#p + 1] = string.format('%s[%q,%q]', i > 1 and "," or "", NET.names[i], NET.group[i] or "inter")
  end
  p[#p + 1] = '],"edges":['
  for k, e in ipairs(NET.edges) do
    p[#p + 1] = string.format('%s[%d,%d,%d]', k > 1 and "," or "", e[1], e[2], e[3] or 0)
  end
  p[#p + 1] = "]}"
  fh:write(table.concat(p)); fh:close()
end

function SENSE.dash_write()
  local DASH = SENSE.dash
  if not DASH or not VIS or frame % 3 ~= 0 then return end
  if not SENSE.net_done then
    SENSE.net_done = true
    pcall(SENSE.dash_net, (DASH:gsub("%.json$", "")) .. ".net.json")
  end
  local d, fam, peak = VIS.drive, VIS.fam, VIS.peak
  local q = SENSE.last or {}
  local out = {}
  local function add(f, ...) out[#out + 1] = string.format(f, ...) end
  add('{"frame":%d,"char":%q,"opp":%q,"bar1":%d,"bar2":%d,"round":%d,"battle":%d,"diff":%d',
      frame, CHAR_NAME[fly_char] or "?", CHAR_NAME[r16(sym.p2_char)] or "?",
      r16(sym.p1_bar), r16(sym.p2_bar), r16(sym.round_num), r16(sym.battle_num), r16(sym.diff))
  add(',"mood":%.2f,"move":%q,"ctx":%q', (OA.use and OA.mood) or mood or 0, vis_move or "", vis_ctx or "")
  if STIM.left > 0 then add(',"stim":{"what":%q,"left":%d}', STIM.what, STIM.left) end
  if #OA.idx > 0 then
    -- z: how many typical swings above (or below) its own rest - the only scale-free way
    -- to show a membrane potential that has no fixed range
    add(',"oa":{"level":%.1f,"rest":%.1f,"z":%.2f,"mood":%.2f,"decides":%s}',
        OA.level, OA.rest or 0, (OA.level - (OA.rest or OA.level)) / math.max(1, OA.spread or 1),
        OA.mood or 0, tostring(OA.use))
  end
  -- what the eyes and the other senses are sending in
  add(',"sense":{"loom_L":%d,"loom_R":%d,"size_L":%d,"size_R":%d',
      d.LC4_L or 0, d.LC4_R or 0, d.LPLC2_L or 0, d.LPLC2_R or 0)
  add(',"chase":%d,"flow":%d,"shake":%d,"loud":%.0f,"air":%d,"room_back":%d,"clock":%d,"touch":%s}',
      (function() local m = 0 for _, e in ipairs(S.grp.chase) do m = math.max(m, d[e.key] or 0) end return m end)(),
      SENSE.flow or 0, SENSE.shake or 0, q.loud or 0, q.air1 or 0, q.room_back or -1,
      q.clock or -1, tostring(q.touch == true))
  -- what fired: the behaviour families, which are the descending neurons
  add(',"fam":{')
  local first = true
  for k, v in pairs(fam) do
    add('%s%q:%d', first and "" or ",", k, v); first = false
  end
  add('}')
  -- the loudest cells this tick, by name, for the wiring panel
  local top = {}
  for i = 1, N do
    if (peak[i] or 0) > 6 then top[#top + 1] = { NET.names[i], peak[i], NET.group[i], i } end
  end
  table.sort(top, function(x, y) return x[2] > y[2] end)
  add(',"cells":[')
  for i = 1, math.min(#top, 40) do
    add('%s{"n":%q,"v":%d,"g":%q}', i > 1 and "," or "", top[i][1], top[i][2], top[i][3])
  end
  -- the same cells again as [index, level] pairs, 200 deep, for the neuron view: the
  -- names above are four times the bytes and the view has the net manifest already
  add('],"fire":[')
  for i = 1, math.min(#top, 200) do
    add('%s[%d,%d]', i > 1 and "," or "", top[i][4], top[i][2])
  end
  add('],"net":{"nodes":%d,"edges":%d}', N, #NET.edges)
  -- the guards, so a stream can show the ROM surviving what used to freeze it
  local function cnt(nm) return sym[nm] and r16(sym[nm]) or 0 end
  add(',"guards":{"sucide":%d,"kill":%d,"palfree":%d,"delobj":%d,"scroll":%d,"illop":%d,"mpart":%d}',
      cnt("sucide_lost"), cnt("kill_lost"), cnt("palfree_bad"), cnt("delobj_lost"),
      cnt("scroll_fast"), cnt("illop_count"), cnt("mpart_clip"))
  if SENSE.shot_every > 0 and SENSE.shot_dir ~= "" then
    add(',"shots":%q', SENSE.shot_dir)
  end
  add('}')
  -- A picture of the screen for the page, if asked for. TWO NAMES IN TURN: the page
  -- fetches the newest-modified file, and a file being written IS the newest, so one
  -- name would hand out truncated PNGs. Alternating always leaves a complete one.
  if SENSE.shot_every > 0 and screen and frame % SENSE.shot_every == 0 then
    SENSE.shot_n = ((SENSE.shot_n or 0) + 1) % 2
    pcall(function() screen:snapshot(string.format("flylive%d.png", SENSE.shot_n)) end)
  end
  local fh = io.open(DASH .. ".tmp", "w")
  if not fh then return end
  fh:write(table.concat(out)); fh:close()
  os.remove(DASH); os.rename(DASH .. ".tmp", DASH)
end

-- Checked EVERY FRAME, not at round end. The latch holds shape/oid/ochar from the moment
-- it fired, but the battle/round/fighters/stage around it are read HERE - sampling only at
-- round end recorded a fight that could be minutes later than the event, which made the
-- context actively misleading (it looked like every clip happened against Kintaro).
local function clip_check()
local clip = sym.ani2_clip and r16(sym.ani2_clip) or 0
if clip > clip_seen then
  log("*** ani2_clip %d (was %d) - a runaway animation list was refused: battle=%d round=%d fly=%s cpu=%s stage=%d gstate=%d",
      clip, clip_seen, r16(sym.battle_num), r16(sym.round_num), CHAR_NAME[fly_char] or fly_char,
      CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char), r16(sym.curback), r16(sym.gstate))
  -- the guard latches the FIRST clip only: that one is the cause, later ones are knock-on.
  -- ani2_clip_shape is the list that ran away - the answer to the whole question - so it
  -- goes in its own file as well as the log, where a crash cannot bury it in scrollback.
  if sym.ani2_clip_shape then
    local oid   = sym.ani2_clip_oid   and r16(sym.ani2_clip_oid)   or 0
    local ochar = sym.ani2_clip_ochar and r16(sym.ani2_clip_ochar) or 0
    local shape = r32(sym.ani2_clip_shape)
    local img   = sym.ani2_clip_img   and r32(sym.ani2_clip_img)   or 0
    -- an empty latch reads ochar 0, which NAMES A FIGHTER (Kung Lao) and would send
    -- someone chasing a character that had nothing to do with it - say "empty" instead
    local who = (shape ~= 0) and (CHAR_NAME[ochar] or ("ochar " .. ochar)) or "latch empty"
    log("    LATCHED FIRST CLIP: shape=%08x img=%08x oid=%d ochar=%d (%s)",
        shape, img, oid, ochar, who)
    local fh = io.open(OUT .. "/ani2_clip.txt", "a")
    if fh then
      fh:write(string.format("frame %d clips %d shape %08x img %08x oid %d ochar %d (%s) " ..
        "battle %d round %d fly %s cpu %s stage %d gstate %d\n", frame, clip, shape, img, oid, ochar,
        who, r16(sym.battle_num), r16(sym.round_num), CHAR_NAME[fly_char] or fly_char,
        CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char), r16(sym.curback), r16(sym.gstate)))
      fh:close()
    end
  end
  clip_seen = clip
end
end
local function fight_tick(press)
  local p = percept_prev          -- ONE FRAME LATE: the fly acts on what was on screen last frame
  if not p then return end
  -- a round is only open while nobody has won it: once somebody has, the bars
  -- are settled and the only thing left to decide is how to finish
  local ws = r16(sym.winner_status)
  if ws ~= 0 then
    if round_open then round_end() end
    if ws == 3 and p.bar2 == 0 and p.bar1 > 0 then finish_tick(p, press)
    elseif fin and fin.phase == "done" and fin.spec and fin.spec.mash then
      -- the lift is under way and the round is no longer "finish him" as far as the check
      -- above can tell - but rd_lift_mash_ok keeps asking for Up + HP until he explodes
      finish_tick(p, press)
    end
    return
  end
  if not round_open then round_begin(p) end
  if ground1 == nil or p.y1 > ground1 then ground1 = p.y1 end
  if ground2 == nil or p.y2 > ground2 then ground2 = p.y2 end

  -- close out any decision whose move has given the fighter back (FB_BLAME=recovery only;
  -- it reads p_action, so it is skipped entirely in the default model)
  if BLAME.recovery then BLAME.step(frame, OUTC.FREE[OUTC.p1act()] ~= nil) end

  -- life bars: the reward signal (on screen, so fair)
  if p.bar2 < bars[2] then
    local d = bars[2] - p.bar2; rs.dealt = rs.dealt + d
    credit(frame, 4 + d / 3, 60)
    OUTC.hit(frame, d, 0)
    mood = math.min(1.0, mood + 0.012 * d)        -- landing hits makes it bolder
    OA.drive = OA.drive + math.floor(OA.per_hit * d)   -- ...and excites its octopamine cells
  end
  if p.bar1 < bars[1] then
    local d = bars[1] - p.bar1; rs.taken = rs.taken + d
    credit(frame, -(3 + d / 4), 45)
    OUTC.hit(frame, 0, d)
    mood = math.max(0.0, mood - 0.010 * d)        -- taking them makes it wary
    OA.drive = OA.drive - math.floor(OA.per_hurt * d)  -- ...and inhibits them
    BODY.struck = math.min(255, BODY.struck + 12 * d)  -- ...and every body segment feels it
  end
  mood = mood + (MOOD_BASE - mood) * 0.002        -- and it drifts back on its own
  if STIM.left > 0 and STIM.what == "octopamine" then mood = math.min(1.0, mood + 0.03) end
  if #OA.idx > 0 then
    OA.mood = math.max(0.0, math.min(1.0, MOOD_BASE + OA.k * (OA.level - (OA.rest or OA.level))
                                                        / math.max(1, OA.spread or 1)))
    -- both moods, every frame, for the round's comparison line
    local r = OA.rs or { n = 0, hs = 0, hlo = 1, hhi = 0, os = 0, olo = 1, ohi = 0, top = 0 }
    OA.rs = r
    r.n = r.n + 1
    r.hs, r.hlo, r.hhi = r.hs + mood, math.min(r.hlo, mood), math.max(r.hhi, mood)
    r.os, r.olo, r.ohi = r.os + OA.mood, math.min(r.olo, OA.mood), math.max(r.ohi, OA.mood)
    r.top = math.max(r.top, OA.now)
  end
  bars = { p.bar1, p.bar2 }

  local rel = p.x2 - p.x1
  local toward = rel >= 0 and "P1 Right" or "P1 Left"
  local away = rel >= 0 and "P1 Left" or "P1 Right"
  local dist = math.abs(rel)
  local opp_air = ground2 and (ground2 - p.y2) > 14

  -- READY: is the fly's OWN fighter free to act? Only its own state, never the opponent's -
  -- the stock CPU's decisions only run when its fighter is idle, and a person sees their own
  -- fighter recover. 87% of attempts are pressed mid-reaction, mid-sweep or in recovery, but
  -- that is mostly not waste: see READY_GATE for why it is off.
  -- 0000 is kept: the stance is logged as 0000 as often as 0303. FB_READY_GATE=1 enables.
  local own = r32(sym.p1_proc)
  local own_act = own ~= 0 and r16(own + 0x1f0) or 0
  local ready = not GATE.on or GATE.acts[own_act] or false

  -- 1. the connectome decides whether something is looming
  local objs = { { "opp", rel, S.fighter_half_w } }
  for k, x in ipairs(p.proj) do objs[#objs + 1] = { "p" .. k, x - p.x1, S.proj_half_w } end
  for k, x in ipairs(p.specks or {}) do objs[#objs + 1] = { "s" .. k, x - p.x1, S.proj_half_w, true } end
  local fam = circuit_step(objs, { chase_dist = dist, chase_right = rel >= 0,
                                   walk = p.vx1, air = p.air1, touch = p.touch,
                                   flow = SENSE.flow, flow_v = SENSE.lastdy or 0,
                                   sound = (p.heard_ago or 999) < 8 and (p.loud or 0) or 0,
                                   wind = SENSE.shake, light = p.flash or 0 })
  -- SELF-MOTION CANCELLED. A fly discounts the expansion its own flight causes, and so
  -- should this one: when the fly is the one closing the distance, the opponent looms
  -- without being a threat. The camera's travel (SENSE.flow) and its own velocity agree
  -- when the motion is the fly's, and that share of the drive is taken out.
  local closing = (rel >= 0 and p.vx1 > 0.5) or (rel < 0 and p.vx1 < -0.5)
  if SENSE.on and closing and math.abs(SENSE.flow) >= 1 then
    local cut = math.min(0.5, 0.15 * math.abs(p.vx1))
    for k, v in pairs(fam) do fam[k] = v * (1 - cut) end
  end
  local threat = math.max(fam.escape, fam.jump_bk) >= C.fire
  -- FB_LOOM_HIST=1: what looming drive each SITUATION produces, and how often it is a threat,
  -- logged at round end - so new thresholds are read off measured levels, not guessed. The
  -- classes are what a person can see: a projectile in flight, him in the air, or him on the
  -- ground (split by whether the fly itself is the one closing, which is self-motion).
  if LOOMH then
    local cls = (#p.proj > 0) and "proj" or (opp_air and "air" or (closing and "gnd_me" or "gnd_him"))
    local d = VIS and VIS.drive or {}
    local l4 = math.max(d.LC4_L or 0, d.LC4_R or 0)
    local lp2 = math.max(d.LPLC2_L or 0, d.LPLC2_R or 0)
    local h = LOOMH[cls] or { n = 0, thr = 0, l4 = {}, lp = {} }
    LOOMH[cls] = h
    h.n = h.n + 1
    if threat then h.thr = h.thr + 1 end
    local function bk(x) return x == 0 and 1 or x < 8 and 2 or x < 16 and 3 or x < 32 and 4
                         or x < 64 and 5 or x < 128 and 6 or x < 255 and 7 or 8 end
    h.l4[bk(l4)] = (h.l4[bk(l4)] or 0) + 1
    h.lp[bk(lp2)] = (h.lp[bk(lp2)] or 0) + 1
  end
  if threat and not armed_at and frame >= refractory_until then
    local delay = C and (NET.react_delay[r16(sym.diff) + 1] or 3) + NET.percept_lag or 4
    -- NO FASTER THAN A PERSON. react_delay is the CPU's own table - 3-6 ticks by the CPU's
    -- difficulty, 55-110 ms - so once the reflex actually answered threats (ac851134) it
    -- reacted 2-4x faster than a human, which breaks the rule that the fly gets no advantage
    -- over one. FB_REACT_MIN floors it, in frames: 12 = 219 ms, the fast end of human
    -- reaction to a visual cue, so the fly is never quicker than a quick person.
    if REACT_MIN > delay then delay = REACT_MIN end
    armed_at = frame + delay
    armed_ctx = (#p.proj > 0) and "t_proj" or (opp_air and "t_air" or "t_ground")
    if REFLEX.split and armed_ctx == "t_ground" then
      local b = dist <= 80 and 1 or (dist <= 160 and 2 or 3)
      local c = "g"
      if p.pose then
        if p.pose.reach > 46 then c = "r"
        elseif stand_h and p.pose.height < stand_h * 0.72 then c = "c" end
      end
      armed_ctx = "t_ground" .. b .. c
      REFLEX.seed(fly_char, armed_ctx, "t_ground")
    end
    armed_bias = {}
    -- the fly's instinct: the family that fired strongest gets a head start
    if fam.jump_bk >= fam.jump_fwd then armed_bias.back_jump = 6 else armed_bias.jump_over = 6 end
  end
  if armed_at and frame >= armed_at and ready then
    local choices = {}
    for _, n in ipairs(DEFENCE[armed_ctx] or DEFENCE[armed_ctx:match("^t_%a+")]) do
      if not (mode == "kicks_only" and uses_punch(defence_move(n))) then choices[#choices + 1] = n end
    end
    local choice = pick(fly_char, armed_ctx, choices, armed_bias, r16(sym.p2_char))
    -- GIANT FIBER POKED: a command neuron, and driving it in a real fly gives a take-off
    -- essentially every time. The first version only armed the reflex and let the learner
    -- answer it - and this fly has learned to answer its escape reflex with a SWEEP, so the
    -- poke never showed (5 of 7 reflexes under it were sweeps). Show mode only.
    if STIM.left > 0 and STIM.what == "giant" then
      choice = (armed_ctx == "t_proj") and "jump_over" or "back_jump"
    end
    vis_action, vis_action_at = "! " .. choice:upper(), frame
    REFLEX.tally[choice] = (REFLEX.tally[choice] or 0) + 1
    OUTC.begin(frame, "reflex", fly_char, r16(sym.p2_char), r16(sym.diff), r16(sym.curback), armed_ctx, dist, choice)
    start_macro(defence_move(choice), "defence")
    if STIM.left > 0 then log("STIM %s: REFLEX %s (frame %d)", STIM.what, choice, frame) end
    -- a move made under a poke is not the fly's to learn from
    if STIM.left == 0 then
      recent[#recent + 1] = { frame = frame, char = fly_char, ctx = armed_ctx, opt = choice, opp = r16(sym.p2_char) }
    end
    rs.defences = rs.defences + 1
    armed_at = nil
    refractory_until = frame + 30
  end

  -- 2. otherwise choose something to do, when not already doing something
  if not macro and not armed_at and ready then
    local bucket = dist <= 80 and 1 or (dist <= 160 and 2 or 3)
    -- What he is DOING, read off his drawn sprite (pose_of): a = airborne,
    -- r = reaching at us (an attack extends the art toward the fly), c = crouched,
    -- g = standing. A person sees exactly this, so the no-advantage rule holds.
    local cls = "g"
    if opp_air then
      cls = "a"
    elseif p.pose then
      if SENSE.whiff and (p.rpeak or 0) > 46 and p.pose.reach < p.rpeak - 8 then cls = "x"
      elseif p.pose.reach > 46 then cls = "r"
      elseif stand_h and p.pose.height < stand_h * 0.72 then cls = "c" end
      if not opp_air and (stand_h == nil or p.pose.height > stand_h) then stand_h = p.pose.height end
    end
    -- two senses are part of the SITUATION the learner keys on, so it finds out for itself
    -- what to do with a wall at its back or its feet off the ground (w / a suffix).
    -- Only two: every extra one splits its experience into more cases to learn apart.
    local ctx = string.format("r%d%s%s%s", bucket, cls,
      (SENSE.ctx and p.room_back and p.room_back < 70) and "w" or "",
      (SENSE.ctx and (p.air1 or 0) > 20) and "a" or "")
    local opts = options_for(fly_char, bucket, mode == "kicks_only")
    local names, bym = {}, {}
    for _, o in ipairs(opts) do names[#names + 1] = o.name; bym[o.name] = o.m end
    local cpu_char = r16(sym.p2_char)
    -- WHAT THE NEW SENSES ARGUE FOR. Leanings on top of what it has learned, never a
    -- veto: the learner still decides, and can learn its way out of any of them.
    local sb = {}
    if not SENSE.on then sb = nil end
    if sb and p.room_back and p.room_back < 70 then        -- the wall is behind me
      sb.walk_back = -10; sb.back_jump = -8; sb.jump_over = 6; sb.jump_in = 4
    end
    if sb and p.air1 > 20 then                             -- I am off the ground: only air moves land
      sb.jump_in = 6; sb.jump_up_kick = 6
      for _, n in ipairs(names) do
        if n == "sweep" or n == "uppercut" or n == "throw" or n == "walk_in" or n == "walk_back" then sb[n] = -12 end
      end
    end
    if sb and p.touch then                                 -- we are pressed together
      sb.throw = 8; sb.uppercut = 6; sb.walk_in = -6; sb.jump_in = -6
    end
    if sb and p.clock <= 10 and p.bar1 < p.bar2 then       -- behind with the clock running out
      for _, n in ipairs(names) do if AGGRESSIVE[n] or n:sub(1, 3) == "sp_" then sb[n] = (sb[n] or 0) + 6 end end
    end
    if sb and frame - SENSE.startle < 20 then              -- the flash or the quake just startled it
      sb.block = (sb.block or 0) + 8; sb.duck_block = (sb.duck_block or 0) + 6
    end
    -- WHAT THE WIRING WANTS, from the two descending neurons the net now carries: DNg100
    -- says walk in, pIP10 says kick. Scaled down to a nudge - the learner still decides,
    -- which is the difference from driving the buttons off them directly.
    -- FB_DN_NUDGE=0 turns this off, for the A/B asking whether it is what costs the 768-cell
    -- net: that net carries DNg100/pIP10 and the 64-cell one has neither, and seg104's brain
    -- scored 48.7% on it against 58.5% on the 64-cell net, same build (2026-09-28).
    if sb and os.getenv("FB_DN_NUDGE") ~= "0" then
      local adv = (fam.advance or 0) // 32
      if adv > 0 then sb.walk_in = (sb.walk_in or 0) + adv; sb.jump_in = (sb.jump_in or 0) + adv // 2 end
      local kck = (fam.kick or 0) // 32
      if kck > 0 then
        for _, n in ipairs(names) do
          if n == "high_kick" or n == "low_kick" or n == "roundhouse" or n == "sweep" then
            sb[n] = (sb[n] or 0) + kck
          end
        end
      end
    end
    -- POKED COMMAND NEURONS win the choice. The wiring's own nudge is fam//32 (at most +8),
    -- which a trained learner's weights (up to 120) outvote - walk-in, kick and octopamine
    -- pokes changed nothing visible in the first test. Show mode only, and never learned from.
    if STIM.left > 0 then
      local push = {}
      if STIM.what == "charge" then push = { walk_in = 150, jump_in = 60 }
      elseif STIM.what == "kick" then
        -- a kick at every range: up close the standing kicks; mid-range the jumping kick; far
        -- away jump_in, which is a flying HK. Without the jumping two it had no kick to pick
        -- from beyond arm's reach and threw fireballs instead.
        push = { high_kick = 150, low_kick = 150, roundhouse = 150, sweep = 90, jump_up_kick = 150, jump_in = 150 }
      elseif STIM.what == "octopamine" then
        for _, n in ipairs(names) do if AGGRESSIVE[n] or n:sub(1, 3) == "sp_" then push[n] = 80 end end
      elseif STIM.what == "moonwalk" then
        push = { walk_back = 150, wait = 20 }
      elseif STIM.what == "aipg" then
        -- close in, then hit: the standing strikes and the throw, and walking in from range
        push = { walk_in = 150, jump_in = 40, jab = 150, low_punch = 120, uppercut = 150,
                 high_kick = 120, low_kick = 100, throw = 150 }
      elseif STIM.what == "pc1" then
        -- aroused rather than commanded: a steadier lean toward pressing, over a longer poke
        for _, n in ipairs(names) do if AGGRESSIVE[n] or n == "walk_in" then push[n] = 50 end end
      end
      sb = sb or {}
      for n, v in pairs(push) do sb[n] = (sb[n] or 0) + v end
    end
    local choice = pick(fly_char, ctx, names, sb, cpu_char)
    if OUTC.pattern then
      -- walk the ring until one of the pattern's options is legal HERE; if none is, leave the
      -- learner's pick alone rather than force something the range does not allow, so the
      -- pattern never turns into a different move and quietly gets credited as itself
      for _ = 1, #OUTC.pattern do
        OUTC.pat_i = OUTC.pat_i % #OUTC.pattern + 1
        local want = OUTC.pattern[OUTC.pat_i]
        for _, n in ipairs(names) do
          if n == want then choice = n; break end
        end
        if choice == want then break end
      end
    end
    -- MOONWALKER POKED: like the giant fiber, MDN is a command neuron - drive it in a real fly
    -- and it walks backwards essentially every time. A +150 lean lost to a trained special
    -- (Liu Kang threw his super 8 times out of 8), and at far range walking back is not even
    -- on the list, so the poke decides outright. Show mode only, never learned from.
    if STIM.left > 0 and STIM.what == "moonwalk" then
      choice = "walk_back"; bym.walk_back = bym.walk_back or BASIC.walk_back.m
    end
    if OUTC.eps > 0 and STIM.left == 0 and math.random() < OUTC.eps then
      if OUTC.probe then
        -- only the probe moves that are LEGAL here: the list is per range, and a kicks_only
        -- round has had the punches taken out of it already
        local cand = nil
        for _, n in ipairs(names) do
          if OUTC.probe[n] then cand = cand or {}; cand[#cand + 1] = n end
        end
        choice = cand and cand[math.random(#cand)] or choice
      else
        choice = names[math.random(#names)]
      end
    end
    OUTC.begin(frame, "decide", fly_char, cpu_char, r16(sym.diff), r16(sym.curback), ctx, dist,
               OUTC.pattern and ("pat_" .. choice) or choice)
    vis_move, vis_ctx = choice, ctx
    start_macro(bym[choice], ctx)
    mv_begin(choice)
    if STIM.left > 0 then log("STIM %s: chose %s (frame %d)", STIM.what, choice, frame) end
    if STIM.left == 0 then
      recent[#recent + 1] = { frame = frame, char = fly_char, ctx = ctx, opt = choice, opp = cpu_char }
    end
    rs.decisions = rs.decisions + 1
  end
  while #recent > 40 do table.remove(recent, 1) end

  -- 3. drive the stick
  drive(press, toward, away)
end

-- ------------------------------------------------------------------ DMA guard
-- dmasagl / dmasagh (SYSEQU.ASM, bit addresses). A SAG is a bit address into the
-- 12MB video ROM, so anything with sag >= 0x06000000 reads past it.
local DMA_SAGL, DMA_SAGH = 0x01a80020, 0x01a80030
local dma_taps, dma_bad, dma_last_log = {}, 0, -1000
local dma_lo = 0
local function dma_report(hi)
  dma_bad = dma_bad + 1
  if frame - dma_last_log < 30 then return end
  dma_last_log = frame
  local function act(procsym)
    local q = r32(sym[procsym]); return q ~= 0 and r16(q + 0x1f0) or 0xffff
  end
  local objs, o, n = {}, r32(sym.objlst), 0
  while o ~= 0 and n < 60 do
    objs[#objs + 1] = string.format("%x:%08x", r16(o + O.oid), r32(o + 0x1a0))
    o = r32(o + O.next); n = n + 1
  end
  log("DMA GUARD: SAG %04x%04x past the video ROM (count %d) frame=%d gstate=%d battle=%d round=%d "
      .. "fly=%s cpu=%s diff=%d p1_act=%04x p2_act=%04x p1_oimg=%08x p2_oimg=%08x",
      hi, dma_lo, dma_bad, frame, r16(sym.gstate), r16(sym.battle_num), r16(sym.round_num),
      CHAR_NAME[r16(sym.p1_char)] or r16(sym.p1_char), CHAR_NAME[r16(sym.p2_char)] or r16(sym.p2_char), r16(sym.diff),
      act("p1_proc"), act("p2_proc"),
      r32(sym.p1_obj) ~= 0 and r32(r32(sym.p1_obj) + 0x1a0) or 0, r32(sym.p2_obj) ~= 0 and r32(r32(sym.p2_obj) + 0x1a0) or 0)
  log("  objects oid:oimg %s", table.concat(objs, " "))
  if screen then pcall(function() screen:snapshot() end) end
end
-- FB_DMA_RING=1: remember every DMA register write and log each blit at GO - the
-- PC that started it, sag, position, size, scale, control, window - in a ring
-- dumped with the crash recorder. A blit bigger than the screen is logged at once.
DMA_RING_ON = os.getenv("FB_DMA_RING") == "1"
local DMA_RING_FROM = tonumber(os.getenv("FB_DMA_RING_FROM") or "")   -- or switch it on at this frame
local DMA_NAMES = { [0x01a80000] = "off", [0x01a80010] = "ctl", [0x01a80020] = "sagl", [0x01a80030] = "sagh",
  [0x01a80040] = "x", [0x01a80050] = "y", [0x01a80060] = "w", [0x01a80070] = "h", [0x01a80080] = "cmap",
  [0x01a800a0] = "xscl", [0x01a800b0] = "yscl", [0x01a800c0] = "win", [0x01a800d0] = "win2", [0x01a800f0] = "cfg" }
local dma_reg, dma_blits, dma_bi, dma_big_logged = {}, {}, 0, 0
local DMA_RING_N = 600
function dma_ring_write(b, data)
  local name = DMA_NAMES[b]
  if not name then return end
  dma_reg[name] = data & 0xffff
  if name == "ctl" and (data & 0x8000) ~= 0 then
    local pc = 0
    pcall(function() pc = cpu.state["PC"].value end)
    local r = dma_reg
    local e = string.format("f=%d pc=%08x sag=%04x%04x x=%d y=%d w=%d h=%d ctl=%04x xscl=%04x yscl=%04x win=%04x cmap=%04x",
      frame, pc, r.sagh or 0, r.sagl or 0, s16(r.x or 0), s16(r.y or 0), r.w or 0, r.h or 0, data & 0xffff,
      r.xscl or 0, r.yscl or 0, r.win or 0, r.cmap or 0)
    dma_bi = dma_bi % DMA_RING_N + 1
    dma_blits[dma_bi] = e
    if ((r.w or 0) > 512 or (r.h or 0) > 512) and dma_big_logged < 20 then
      dma_big_logged = dma_big_logged + 1
      log("DMA BIG BLIT: %s", e)
    end
  end
end
function dma_ring_dump(fh)
  fh:write("-- last DMA blits (oldest first)\n")
  for k = 1, DMA_RING_N do
    local line = dma_blits[(dma_bi + k - 1) % DMA_RING_N + 1]
    if line then fh:write(line, "\n") end
  end
end

-- HEARING (a fly hears with its antennae - Johnston's organ). Every sound the game plays is
-- written to one hardware address (`sound`, SYSEQU.ASM 1d01030h): hits, blocks, whooshes,
-- speech, the announcer. A person in front of the cabinet hears all of it, so the fly may.
-- It is not told WHICH move made a sound - only that it heard one, and how loud a moment
-- has been (how many in the last half second), which is what an ear gives an insect.
function SENSE.install_ear()
  local function on_write(offset, data, mask)
    SENSE.heard = frame
    SENSE.heard_n = (SENSE.heard_n or 0) + 1
    return data
  end
  -- the handles are KEPT: an unreferenced tap is garbage-collected, and the ear went deaf
  -- after the first round until they were
  SENSE.ear_taps = {}
  for _, rg in ipairs({ { 0x01d01030, 0x01d0103f }, { 0x01d01030 // 8, 0x01d0103f // 8 } }) do
    local ok, h = pcall(function() return space:install_write_tap(rg[1], rg[2], "fly_ear_" .. rg[1], on_write) end)
    if ok and h then SENSE.ear_taps[#SENSE.ear_taps + 1] = h end
  end
end

local function install_dma_guard()
  local scale = nil
  local function on_write(offset, data, mask)
    if scale == nil then
      if offset == DMA_SAGL or offset == DMA_SAGH then scale = 1
      elseif offset * 8 == DMA_SAGL or offset * 8 == DMA_SAGH then scale = 8 end
    end
    if scale == nil then return data end
    local b = offset * scale
    if DMA_RING_ON then dma_ring_write(b, data) end
    if b == DMA_SAGL then dma_lo = data & 0xffff
    elseif b == DMA_SAGH then
      local hi = data & 0xffff
      if hi >= 0x0600 then
        pcall(dma_report, hi)
        return data & ~0xffff    -- keep the emulator alive: draw from ROM start instead
      end
    end
    return data
  end
  for _, rg in ipairs({ { 0x01a80000, 0x01a800ff }, { 0x01a80000 // 8, 0x01a800ff // 8 } }) do
    local ok, h = pcall(function() return space:install_write_tap(rg[1], rg[2], "fly_dma_guard_" .. rg[1], on_write) end)
    if ok and h then dma_taps[#dma_taps + 1] = h end
  end
  log("DMA guard: %d tap(s) installed", #dma_taps)
end

-- ------------------------------------------------------------------ flight recorder
-- The Kintaro crash is the GAME dying (RAM reads garbage by the time a bad SAG
-- reaches the DMA), so keep the last few seconds of both fighters and the CPU's
-- PC, and dump them the first frame the game state stops making sense.
local RING_N = 180
local ring, ring_i, crashed, seen_fight = {}, 0, false, false
local function cpu_pc()
  for _, n in ipairs({ "PC", "CURPC" }) do
    local ok, it = pcall(function() return cpu.state[n] end)
    if ok and it then return it.value end
  end
  return 0
end
local function record_frame(gs)
  local function proc_act(ps) local q = r32(sym[ps]); return q ~= 0 and r16(q + 0x1f0) or 0xffff end
  local function obj(os_, off) local q = r32(sym[os_]); return q ~= 0 and r32(q + off) or 0 end
  -- oxpos (090h) is SIXTEEN bits - the integer half of the 32-bit oxval at 080h.  The
  -- ring used to read it as obj(...,0x090) >> 16, which is the correct oxval idiom
  -- applied to the wrong offset: a 32-bit read at 090h returns oxpos in its LOW half and
  -- the bottom of oyval in its high half, so the shift threw the x away and printed part
  -- of y.  Read the 16-bit field directly.
  local function obj16(os_, off) local q = r32(sym[os_]); return q ~= 0 and r16(q + off) or 0 end
  ring_i = ring_i % RING_N + 1
  ring[ring_i] = string.format("f=%d gs=%d pc=%08x rnd=%d ws=%d p1=%d/%04x img=%08x x=%d bar=%d  p2=%d/%04x img=%08x x=%d bar=%d  sp=%08x",
    frame, gs, cpu_pc(), r16(sym.round_num), r16(sym.winner_status),
    r16(sym.p1_char), proc_act("p1_proc"), obj("p1_obj", 0x1a0), s16(obj16("p1_obj", 0x090)), r16(sym.p1_bar),
    r16(sym.p2_char), proc_act("p2_proc"), obj("p2_obj", 0x1a0), s16(obj16("p2_obj", 0x090)), r16(sym.p2_bar),
    (function() local ok, it = pcall(function() return cpu.state["SP"] end); return ok and it and it.value or 0 end)())
end
local function dump_ring(why)
  local fh = io.open(OUT .. string.format("/crash_%d.txt", frame), "w")
  fh:write(string.format("%s at frame %d\n", why, frame))
  for k = 1, RING_N do
    local line = ring[(ring_i + k - 1) % RING_N + 1]
    if line then fh:write(line, "\n") end
  end
  if DMA_RING_ON then dma_ring_dump(fh) end
  fh:close()
  log("CRASH RECORDER: %s - last %d frames in crash_%d.txt", why, RING_N, frame)
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    screen = manager.machine.screens[":screen"]
    if DMA_GUARD then install_dma_guard() end
    if os.getenv("FB_EAR") ~= "0" then SENSE.install_ear() end
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, f in pairs(port.fields) do fields[f.name] = f end
    end
    if BODY.n > 0 then
      log("BODY: %d ascending cells report to the brain - front legs %d, mid %d, hind %d, abdomen %d",
          BODY.n, #BODY.T1, #BODY.T2, #BODY.T3, #BODY.A)
    end
    if #OA.idx > 0 then
      log("OCTOPAMINE: %d cells, mood %s", #OA.idx, OA.use and "read from them" or "shadow (hand-tuned decides)")
    end
    if STIM.on then log("STIM: show mode on - polling %s", SENSE.dash and ((SENSE.dash:gsub("%.json$", "")) .. ".stim.json") or "(no dashboard file)") end
    log("flybrain_play: net %d nodes %d edges gain %d seed %d chars %s games %d", N, #NET.edges, GAIN_SHIFT, SEED,
        table.concat(CHARS, ","), GAMES)
    -- SAY WHICH ARM THIS IS.  An A/B whose two arms differ only by an environment variable is
    -- one typo away from measuring nothing at all, and the two logs look identical when it
    -- happens - so each run states its own settings and the arms can be told apart afterwards
    -- from the logs alone, not from what the launcher meant to set.
    -- eps is in here because flybrain_exploits.py is only honest with it: with no exploration
    -- the fly samples its favourites and the CPU-weakness map cannot see a hole in anything
    -- else.  Measured 2026-09-27 over 186k decisions with eps 0 (every run to date, the
    -- "measuring" ones included - nothing ever set it): sweep 40,651 tries against jab 48,
    -- low_punch 58, throw 82.  Split by CPU and range those never reach the tool's minimum
    -- tries, so they are absent from the report rather than reported as safe.
    log("SETTINGS: blame=%s learning=%s difficulty=%s eps=%s rounds=%s", BLAME.recovery and "recovery" or "fixed",
        LEARNING and "on" or "FROZEN", FORCE_DIFF and tostring(FORCE_DIFF) or "ladder",
        (OUTC.eps or 0) > 0 and string.format("%.3f", OUTC.eps) or "0 (favourites only)",
        OUTC.force_normal and "normal only" or "normal+kicks_only")
    log("SETTINGS: senses lc4_full=%g lplc2_gate=%g loom_size=%g dn_nudge=%s circuit_shift=%s react_min=%d whiff=%s decay=%s sharp=%s",
        S.lc4_full, S.lplc2_gate, S.loom_size, os.getenv("FB_DN_NUDGE") == "0" and "OFF" or "on",
        SIGNED_SHIFT and "SIGNED (fixed)" or "logical (old, latches)", REACT_MIN,
        SENSE.whiff and "on" or "off", tostring(DECAY), tostring(SHARP))
    if OUTC.pattern then
      log("SETTINGS: SCRIPTED ADVERSARY - every decision takes the next legal option of: %s"
          .. " (an instrument, not the fly; measuring runs only)", table.concat(OUTC.pattern, ", "))
    end
    if OUTC.probe then
      local t = {}
      for n in pairs(OUTC.probe) do t[#t + 1] = n end
      table.sort(t)
      log("SETTINGS: exploration is spent on %s (the rest of the time it plays normally)",
          table.concat(t, ", "))
    end
    -- say outright whether the ani2 guard counter is being read: a silent 0 otherwise
    -- means either "healthy" or "not looking", and those are not the same report
    if sym.ani2_clip_shape then log("ani2 guard counter + context latch present (0 = no runaway list refused)")
    elseif sym.ani2_clip then log("ani2 guard counter present, no context latch - older fix build")
    else log("ani2 guard counter absent - this is a pre-fix ROM/map") end
  end
  if READY and frame == 120 then local r = io.open(READY, "w"); if r then r:write("ok"); r:close() end end
  if #missing > 0 then manager.machine:exit(); return end

  local press = {}
  local gs = r16(sym.gstate)
  if gs == GS.fighting then seen_fight = true end
  clip_check()
  if seen_fight and not crashed and last_progress > 0 and frame - last_progress > NOPROG_FRAMES then
    -- state the OBSERVATION only: gstate says where it is stuck, and guessing why in the
    -- message (it fires mid-fight too) would plant a false lead in the log
    log("NO PROGRESS: %d frames with no round start or end (gstate=%d battle=%d round=%d bars %d/%d)",
        frame - last_progress, gs, r16(sym.battle_num), r16(sym.round_num), r16(sym.p1_bar), r16(sym.p2_bar))
    dump_ring(string.format("no progress for %d frames in gstate %d", frame - last_progress, gs))
    if screen then pcall(function() screen:snapshot() end) end
    last_progress = frame   -- report once per window rather than every frame
    if os.getenv("FB_EXIT_ON_CRASH") == "1" then crashed = true; manager.machine:exit(); return end
  end
  -- STALL DETECTOR: a frozen game whose state still LOOKS valid (seen at the start
  -- of a round, pre-fight setup gstate 6) is invisible to the crash recorder, and a
  -- trainer would wait on it forever. If nothing that a running game changes has
  -- changed for STALL_FRAMES (30 emulated seconds; FINISH HIM pauses the clock for
  -- 8), dump the recorder and exit so the trainer restarts from the saved brain.
  if seen_fight and not crashed and (gs == GS.fighting or gs == GS.pfsetup or gs == GS.round_intro) then
    local p1o, p2o = r32(sym.p1_obj), r32(sym.p2_obj)
    local sig = string.format("%d/%d/%d/%d/%d/%d/%d/%d/%d", gs, r16(sym.round_num), r16(sym.battle_num),
      r16(sym.p1_bar), r16(sym.p2_bar), sym.clk_ones and r16(sym.clk_ones) or 0, sym.clk_tens and r16(sym.clk_tens) or 0,
      p1o ~= 0 and r16(p1o + O.oxpos) or 0, p2o ~= 0 and r16(p2o + O.oxpos) or 0)
    if sig == stall_sig then stall_n = (stall_n or 0) + 1 else stall_sig, stall_n = sig, 0 end
    if stall_n >= STALL_FRAMES then
      crashed = true
      dump_ring(string.format("HANG DETECTOR: game stalled %d frames (gstate=%d state %s)", stall_n, gs, sig))
      log("HANG DETECTOR: nothing changed for %d frames in gstate %d (%s)", stall_n, gs, sig)
      if screen then pcall(function() screen:snapshot() end) end
      if os.getenv("FB_EXIT_ON_CRASH") == "1" then manager.machine:exit(); return end
    end
  else
    stall_sig, stall_n = nil, 0
  end
  if DMA_RING_FROM and frame == DMA_RING_FROM then DMA_RING_ON = true; log("DMA ring armed at frame %d", frame) end
  -- FB_HANG_PC=lo-hi (hex): if the PC sits in that range for 3 frames running, dump
  -- every CPU register and the multipart piece under A9, then exit. Built for the
  -- shadf wait loop (shf8) the Kintaro crash parks in.
  local hang = os.getenv("FB_HANG_PC")
  if hang and not crashed then
    local lo, hi = hang:match("(%x+)%-(%x+)")
    lo, hi = tonumber(lo, 16), tonumber(hi, 16)
    local pc = cpu_pc()
    if pc >= lo and pc <= hi then hang_frames = (hang_frames or 0) + 1 else hang_frames = 0 end
    if hang_frames == 3 then
      crashed = true
      local regs = {}
      for name, entry in pairs(cpu.state) do
        local ok, val = pcall(function() return entry.value end)
        if ok then regs[#regs + 1] = string.format("%s=%x", name, val) end
      end
      table.sort(regs)
      local fh = io.open(OUT .. string.format("/hang_%d.txt", frame), "w")
      fh:write(string.format("PC parked in %x-%x for 3 frames at frame %d\n", lo, hi, frame))
      fh:write(table.concat(regs, " "), "\n")
      local a9 = cpu.state["A9"] and cpu.state["A9"].value or 0
      for k = -2, 3 do
        local p = a9 + k * 112
        local ok, s = pcall(function()
          return string.format("piece %+d @%08x: sag=%08x sizex=%d sizey=%d control=%04x anix=%d aniy=%d", k, p,
            r32(p), r16(p + 32), r16(p + 48), r16(p + 64), s16(r16(p + 80)), s16(r16(p + 96)))
        end)
        fh:write((ok and s or ("piece read failed " .. tostring(s))), "\n")
      end
      for _, pl in ipairs({ "p1_obj", "p2_obj" }) do
        local q = r32(sym[pl])
        fh:write(string.format("%s=%08x oimg=%08x oflags=%04x ochar=%d\n", pl, q, q ~= 0 and r32(q + 0x1a0) or 0,
          q ~= 0 and r16(q + 0xf0) or 0, q ~= 0 and r16(q + 0x1b0) or 0))
      end
      for k = 1, RING_N do
        local line = ring[(ring_i + k - 1) % RING_N + 1]
        if line then fh:write(line, "\n") end
      end
      fh:close()
      log("HANG DETECTOR: PC parked at %x - registers and pieces in hang_%d.txt", pc, frame)
      if screen then pcall(function() screen:snapshot() end) end
      manager.machine:exit(); return
    end
  end
  -- FB_TRACE_FROM=<frame>: full CPU trace from that frame until the recorder fires
  -- (MAME must run with -debug; the run is deterministic for a given seed + brain)
  -- FB_DBG_AT=<frame> + FB_DBG_CMDS="cmd~~~cmd": run debugger commands at that frame
  -- (breakpoints with printf actions land in debug.log when MAME has -debuglog)
  local dbg_at = tonumber(os.getenv("FB_DBG_AT") or "")
  if dbg_at and frame == dbg_at then
    local ok, d = pcall(function() return manager.machine.debugger end)
    if ok and d then
      for c in ((os.getenv("FB_DBG_CMDS") or "") .. "~~~"):gmatch("(.-)~~~") do
        if c:match("%S") then d:command(c); log("DEBUG CMD at %d: %s", frame, c) end
      end
    else
      log("FB_DBG_AT set but the debugger is not available (run MAME with -debug)")
    end
  end
  local trace_from = tonumber(os.getenv("FB_TRACE_FROM") or "")
  if trace_from and frame == trace_from then
    local ok, d = pcall(function() return manager.machine.debugger end)
    if ok and d then
      d:command(string.format("trace %s/cpu_trace.txt,maincpu", OUT))
      log("TRACE started at frame %d", frame)
    else
      log("TRACE requested but the debugger is not available (run MAME with -debug)")
    end
  end
  if not crashed and seen_fight then
    -- 19 = ft_rain, the last fighter (MAINEQU.ASM). This said 18 until Rain joined the roster on
    -- 2026-09-22, and every game the fly played as Rain was "invalid" - the session ended there.
    if gs > 0x20 or (gs == GS.fighting and (r16(sym.p1_char) > 19 or r16(sym.round_num) > 20)) then
      crashed = true
      dump_ring(string.format("game state invalid (gstate=%x p1_char=%d round=%d)", gs, r16(sym.p1_char), r16(sym.round_num)))
      if screen then pcall(function() screen:snapshot() end) end
      pcall(function() manager.machine.debugger:command("trace off") end)
      if os.getenv("FB_EXIT_ON_CRASH") == "1" then manager.machine:exit(); return end
    elseif gs == GS.fighting then
      record_frame(gs)
    end
  end
  if gs ~= last_gs then
    -- every transition, because the one that mattered (whatever the game did at 21:22)
    -- was in none of the three states this block used to name
    -- battle and opponent go in the transition line because the pre-fight window is where
    -- both are decided, and knowing WHEN they change is what any pre-fight write depends on
    if last_gs ~= -1 then
      log("gstate %d -> %d (frame %d) battle=%d cpu=%d", last_gs, gs, frame, r16(sym.battle_num), r16(sym.p2_char))
    end
    -- BOSS GIVE-UP (FB_BOSS_TRIES=N, the stream's default 3): continues kept a stream on
    -- Kintaro for 425 of 486 rounds on 2026-09-21 (2 won) - hours of the same lost fight.
    -- Count the continue screens reached by losing to Kintaro (12) or Shao Kahn (13) in a
    -- row; at N, decline the continue and let the game end, so a new game starts a fresh
    -- climb with the next fighter. Viewers still see the bosses, just not on a loop.
    if gs == GS.buyin and BOSSQ.tries > 0 then
      local opp = r16(sym.p2_char)
      BOSSQ.losses = (opp == 12 or opp == 13) and BOSSQ.losses + 1 or 0
      if BOSSQ.losses >= BOSSQ.tries then
        BOSSQ.quit = true
        log("BOSS GIVE-UP: lost to %s %d times running - letting the game end for a fresh climb",
            CHAR_NAME[opp] or opp, BOSSQ.losses)
      end
    end
    if gs == GS.psel then
      sel_frame = frame
      local new_game = last_gs == GS.amode or last_gs == GS.gameover or last_gs == -1 or last_gs == GS.initials
      if new_game then BOSSQ.losses, BOSSQ.quit = 0, false end
      if new_game then game = game + 1 end
      if new_game and KAHN.every > 0 then
        KAHN.game = (game % KAHN.every) == 0
        if KAHN.game and KAHN.rungs then KAHN.rung = KAHN.rungs[((game // KAHN.every) % #KAHN.rungs) + 1] end
        if KAHN.game then log("game %d: SHAO KAHN training - starting on his rung", game) end
      end
      if new_game or ROTATE == "psel" then
        selections = selections + 1
        sel_random = false
        if PICK == "gamerandom" or (PICK == "mix" and math.random() < 0.25) then
          -- the game's own random select (Up + Start on the starting square): the fighter
          -- is only known once the game has picked it, when select ends
          sel_random = true
          log("%s %d: the fly uses the game's random select", new_game and "game" or "continue", game)
        else
          if PICK == "random" or PICK == "mix" then
            local choice
            repeat choice = CHARS[math.random(#CHARS)] until #CHARS == 1 or choice ~= fly_char
            fly_char = choice
          else
            fly_char = CHARS[((selections - 1) % #CHARS) + 1]
          end
          log("%s %d: the fly plays %s", new_game and "game" or "continue", game, CHAR_NAME[fly_char] or fly_char)
        end
      end
    end
    if last_gs == GS.psel and sel_random then
      local got = r16(sym.p1_char)
      if CHAR_NAME[got] then fly_char = got end
      sel_random = false
      log("random select gave the fly %s", CHAR_NAME[fly_char] or fly_char)
    end
    if gs == GS.gameover or (gs == GS.amode and last_gs ~= -1 and game > 0 and last_gs ~= GS.amode) then
      if last_gs ~= GS.gameover then
        games_over = games_over + 1
        log("GAME OVER %d (game %d, battle %d)", games_over, game, r16(sym.battle_num))
        if GAMES > 0 and games_over >= GAMES then
          dump_weights("final"); rounds:close(); manager.machine:exit(); return
        end
      end
    end
    last_gs = gs
  end

  -- one frame of perception delay: the fight logic reads percept_prev
  percept_prev = percept_now
  percept_now = (gs == GS.fighting) and perceive() or nil

  -- OUTSIDE the gs if/elseif chain: these two were first written just after the select
  -- branch's confirm press, which put them INSIDE it - legal Lua, and dead, because the
  -- states they test can never hold while the select screen is up. Nothing errored; the
  -- opponent simply never changed.
  -- only in the two states between the handoff and the fight: writing it during the bonus
  -- state would rewrite the PREVIOUS battle's loser while his victory text is still up
  if SECRET_OPP_EVERY > 0 and (gs == GS.pfsetup or gs == GS.round_intro) then
    local b = r16(sym.battle_num)
    if b > 0 and (b % SECRET_OPP_EVERY) == 0 then
      local want = SECRET_OPPS[((b // SECRET_OPP_EVERY - 1) % #SECRET_OPPS) + 1]
      if r16(sym.p2_char) ~= want then w16(sym.p2_char, want) end
      -- A Smoke fight is the WAFFLE HOUSE's one natural appearance in a one-player game
      -- (bmdif, MAIN.ASM), and Noob's is OUTER HAVEN. The Waffle House is paused for now,
      -- so send Smoke to the ordinary ladder arenas instead; Noob keeps Outer Haven, which
      -- is a stage the tower shows anyway. FB_STAGE=17 asks for it back deliberately.
      if NO_WAFFLE and r16(sym.curback) == 0x17 and STAGE ~= 0x17 then w16(sym.curback, b % 11) end
    end
  end
  if STAGE and STAGE_EVERY > 0 and gs ~= GS.fighting then
    local b = r16(sym.battle_num)
    if b > 0 and (b % STAGE_EVERY) == 0 and not STAGE_KEEP[r16(sym.p2_char)] and r16(sym.curback) ~= STAGE then
      w16(sym.curback, STAGE)
    end
  end
  -- BOSS CAP (training only - on whenever the curriculum is, FB_BOSS_CAP=0 turns it off).
  -- Kintaro and Shao Kahn were most of every training hour: continues kept the fly retrying
  -- them, it won 3-8% of those rounds, and they taught it little it can use on the twelve
  -- regular fighters. So once the ladder points at a boss, point it back at the rung this
  -- game started on - the same write FB_FORCE_RUNG makes. It is made BEFORE the next match
  -- is set up (set_drone_ochar reads map_position then, and boss_minumum_diff keys on the
  -- opponent it picks), and never during a live fight, so a boss that did slip through is
  -- played out, not swapped mid-round. Exams run without the curriculum, so they still
  -- climb the whole tower and measure the real thing.
  if BOSS_CAP and not KAHN.game and sym.map_start then
    if gs == GS.fighting and r16(sym.battle_num) == 1 and not cap_first then cap_first = r16(sym.map_position) end
    local ms, pos = r32(sym.map_start), r16(sym.map_position)
    -- EARLY: the fly has just won its match on the last regular rung. The game advances
    -- the ladder (adv_winner_map) and picks the next opponent (set_drone_ochar) in one
    -- breath, with no frame in between for a write, so a boss found AFTER the advance has
    -- already been booked. Step the ladder back to just below the start instead, and the
    -- game's own +1 lands it on the first rung.
    if ms ~= 0 and gs == GS.fighting and r16(sym.p1_matchw) >= 2 and pos >= (cap_first or 1)
       and CURR_BOSS[r16(ms + (pos + 1) * 16)] then
      w16(sym.map_position, (cap_first or 1) - 1)
      cap_resets = cap_resets + 1
      log("BOSS CAP: won rung %d, next is %s - ladder restarts at rung %d (%d so far)", pos,
        CHAR_NAME[r16(ms + (pos + 1) * 16)] or "?", cap_first or 1, cap_resets)
      pos = (cap_first or 1) - 1
    end
    -- LATE backstop: anything that still points the ladder at a boss outside a live fight
    if not (gs == GS.fighting and r16(sym.winner_status) == 0) then
      if ms ~= 0 and pos > (cap_first or 1) then
        local opp = r16(ms + pos * 16)
        if CURR_BOSS[opp] then
          w16(sym.map_position, cap_first or 1)
          cap_resets = cap_resets + 1
          log("BOSS CAP: rung %d is %s - back to rung %d (%d so far)", pos, CHAR_NAME[opp] or opp, cap_first or 1, cap_resets)
        end
      end
    end
    if gs == GS.gameover or gs == GS.amode then cap_first = nil end
  end
  if gs == GS.psel then
    w16(sym.fly_player, 1)
    -- Jade and Ermac cannot be selected by writing p1_char - every forced route fails
    -- (memory reference-secret-fighter-unreachable-by-force). They arrive only through the
    -- select-screen unlock, so raise the same pending flag the cheat raises and let the
    -- GAME apply it: jade/ermac_select_cheat_apply (MAIN.ASM) swaps the fighter in after
    -- select, and psel_apply_hidden_char does the art/anitab/palette setup on confirm.
    -- WHICH SQUARE each hidden fighter sits on is READ OFF THE MAP, never assumed: all
    -- three moved onto morph_table squares (MKSEL.ASM) and a hardcoded row silently picks
    -- the BASE fighter instead - the fly then drives Scorpion's body with Rain's move table
    -- and brain for the whole round.  <name>_pos is the morph's box-frame variable and only
    -- exists in a build that carries that square, so an older frozen pair still takes its
    -- own route.  Rain is the one that bites: rain_select_enable is 0 now, so Block x5 on
    -- Scorpion is an ORDINARY CONFIRM and gives Scorpion with no error anywhere.
    local SECRET = {
      [16] = sym.jade_pos  and { base = 4,  flag = "f_jade_cheat1",  how = "jade" }     -- KITANA, tap Start
                           or  { base = 5,  flag = "f_jade_cheat1",  how = "jade" },    -- was Mileena, LK x5
      [17] = sym.ermac_pos and { base = 10, flag = "f_ermac_cheat1", how = "ermac" }    -- SCORPION, tap Start
                           or  { base = 9,  flag = "f_ermac_cheat1", how = "ermac" },   -- was Reptile
      [19] = sym.rain_pos  and { base = 8,  flag = "f_rain_cheat1",  how = "ermac" }    -- SUB-ZERO, tap Start
                           or  { base = 10, flag = "f_rain_cheat1",  how = "rain" },    -- was Scorpion, Block x5
      -- NOOB: Sub-Zero + Block x5 (check_noob_blk_cheat, noob_select_enable 1) - the "rain"
      -- branch's five Blocks, on Sub-Zero's square
      [15] = sym.f_noob_cheat1 and { base = 8, flag = "f_noob_cheat1", how = "rain" } or nil }
    local sec = SECRET[fly_char]
    if SEL_MAGIC then
      if r16(sym.p1_char) == fly_char then
        -- already the fighter we want. For Jade/Ermac that means the GAME has applied the
        -- unlock (psel_hidden_pick on confirm) - and writing the base fighter again, as this
        -- first did every frame, put Mileena/Reptile straight back over them, silently.
      elseif sec and sym[sec.flag] then
        w16(sym.p1_char, sec.base); w16(sym[sec.flag], 1)
      else
        w16(sym.p1_char, fly_char)
      end
      press["P1 High Punch"] = (frame - sel_frame) > 90 and ((frame - sel_frame) % 40) < 4
    else
      sel_hold_tick(press)
      if sel_random then sel_cursor(press, 1, "gamerandom")
      else sel_cursor(press, sec and sec.base or fly_char, sec and sec.how) end
    end
    if FORCE_P2_LEGACY then
      w16(sym.p2_state, 0); w16(sym.p2_char, FORCE_P2_LEGACY)
      if FORCE_P2_LEGACY == 12 then w16(sym.curback, 5); w16(sym.map_position, 13) end
    end

  elseif gs == 0x0d and (FORCE_RUNG or KAHN.game or KAHN.opp) then
    -- post-select: the tower is built now, so put the fly on the requested rung
    local want = KAHN.game and KAHN.rung or FORCE_RUNG
    if want and r16(sym.map_position) < want then w16(sym.map_position, want) end
    if KAHN.opp and sym.map_start and r32(sym.map_start) ~= 0 then
      -- the tower can be a ROM table (Lua cannot write it), so STEER to his rung instead
      for q = 1, 15 do
        if r16(r32(sym.map_start) + q * 16) == KAHN.opp then w16(sym.map_position, q); break end
      end
    end
  elseif gs == GS.fighting then
    w16(sym.fly_player, 1)
    -- FB_FORCE_OPP: the dynamic tower is built on the mountain screen (init_map_start_ladder),
    -- AFTER the post-select write above - so the rungs ahead are rewritten during the fight
    -- too, which is before set_drone_ochar reads the next one
    if KAHN.opp and sym.map_start and r32(sym.map_start) ~= 0 and r16(sym.p1_matchw) >= 2 then
      -- the match is won: step back one rung so the game's own +1 lands on him again (the
      -- BOSS CAP's EARLY write, aimed the other way)
      for q = 1, 15 do
        if r16(r32(sym.map_start) + q * 16) == KAHN.opp then
          if r16(sym.map_position) ~= q - 1 then w16(sym.map_position, q - 1) end
          break
        end
      end
    end
    if FORCE_DIFF then w16(sym.diff, FORCE_DIFF) end
    -- FB_SHADFAST=0/1/2: force the stage's shadow blitter mode every fight frame
    -- (A/B for the Kintaro hang, which parks in shadf's DMA wait)
    local sf = tonumber(os.getenv("FB_SHADFAST") or "")
    if sf and sym.shad_fast then w16(sym.shad_fast, sf) end
    -- FB_POKE="sym=val,sym=val": 16-bit writes every fight frame (A/B switches such as
    -- f_skyrows_off=1 for Kahn's Arena haze). Unknown symbols are reported once.
    for name, val in (os.getenv("FB_POKE") or ""):gmatch("([%w_]+)=(%-?%w+)") do
      if sym[name] then w16(sym[name], tonumber(val) or 0)
      elseif not poke_warned then poke_warned = true; log("FB_POKE: unknown symbol %s", name) end
    end
    -- FB_FORCE_DIFF WINS over the curriculum. An A/B wants the curriculum's BOSS CAP (a
    -- ladder that restarts instead of grinding Kintaro) at ONE pinned difficulty; without
    -- this the curriculum's write below overwrote the pin every frame and each arm drifted
    -- to its own difficulty. Found 2026-09-20 in the octopamine A/B: raw win rate said
    -- nothing because one arm was stuck 0/26 on Kintaro and the other 4/19 on Reptile.
    if curr and not FORCE_DIFF then
      -- TRAIN WHERE IT PLAYS. A real one-player run is at difficulty 5-8 by the fourth
      -- battle; the curriculum alone kept the fly at 2-3, so it never met that CPU. Half
      -- the rounds are now a random 5-8 (FB_STRETCH, 0 = curriculum only). Only rounds at
      -- the curriculum's own level vote on moving it.
      local rkey = r16(sym.battle_num) * 100 + r16(sym.round_num)
      if curr.rkey ~= rkey then
        curr.rkey = rkey
        local stretch = tonumber(os.getenv("FB_STRETCH") or "0.5")
        curr.round_d = (math.random() < stretch) and math.random(5, 8) or curr.d
      end
      w16(sym.diff, curr.round_d or curr.d)
    end
    if not FLY.checked then
      FLY.checked = true
      local rom_n = sym.fly_scom_count and r16(sym.fly_scom_count) or -1
      FLY.on = FLY.cat ~= nil and sym.fly_invoke ~= nil and rom_n == FLY.cat.count and os.getenv("FB_INVOKE") ~= "0"
      log("INNATE MOVES: %s (ROM table %d, list %s)", FLY.on and "on - the fly asks, the ROM runs the handler"
          or "off - input-queue specials", rom_n, FLY.cat and FLY.cat.count or "missing")
    end
    do local o = r32(sym.p1_obj); FLY.body = o ~= 0 and r16(o + 0x1f0) or nil end
    FLY.now = frame
    local ok, err = pcall(STIM.poll, frame)
    if not ok and not STIM.err then STIM.err = true; log("STIM poll failed: %s", tostring(err)) end
    pcall(SENSE.dash_write)
    mv_tick()
    fight_tick(press)
  else
    if round_open and rs then round_end() end
    percept_prev = nil
    macro, armed_at = nil, nil
    if gs == GS.amode or (gs == GS.buyin and CONTINUE and not BOSSQ.quit) or gs == GS.gameover or gs == GS.initials then
      press["Coin 1"] = (frame % 90) < 10
      press["1 Player Start"] = (frame % 90) >= 45 and (frame % 90) < 55
      if gs == GS.initials then press["P1 High Punch"] = (frame % 30) < 4 end
    end
  end

  for _, n in ipairs(ALLKEYS) do
    if fields[n] then fields[n]:set_value(press[n] and 1 or 0) end
  end
  if frame > MAXMIN * 60 * 55 then log("backstop: %d minutes of emulation", MAXMIN); dump_weights("backstop"); manager.machine:exit() end
end)
