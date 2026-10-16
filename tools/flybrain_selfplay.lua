-- flybrain_selfplay.lua - fly versus fly.
--
-- Two fruit-fly brains fight each other, one on each joystick, in a normal
-- two-player game. Neither is the CPU, so there is no drone wedge, and the
-- fairness rules that apply to the single-player fly apply to both sides: screen
-- -visible perception read ONE FRAME LATE, no action sooner than the stock drone's
-- reaction delay, and only moves a stick can produce.
--
-- Why: against the CPU the fly plateaus, because a fixed opponent stops teaching
-- it anything. Here its opponent improves as it does.
--
-- Each side carries its own looming circuit (MaleCNS or a rewiring), its own
-- learned values, and its own aggression mood. Both learn from what lands.
--
-- Env: FS_MAP FS_OUT FS_READY FS_NET (circuit) FS_NET_B (B's circuit, default = A's)
--      FS_BRAIN_A FS_BRAIN_B (in/out brain files; omitted = learn from scratch)
--      FS_FREEZE_B=1 (B never learns - a frozen sparring partner)
--      FS_CHARS ("cycle" or "1,9"), FS_SEED, FS_MAXMIN, FS_STAGE, FS_OVERLAY
local function genv(k, d) local v = os.getenv(k); if v == nil or v == "" then return d end; return v end
local MAP = genv("FS_MAP", "C:/tmp/flybrain/rom4/mk2.map"):gsub("\\", "/")
local OUT = genv("FS_OUT", "C:/tmp/flybrain/selfplay"):gsub("\\", "/")
local READY = genv("FS_READY", nil)
local NET_A = genv("FS_NET", "C:/tmp/flybrain/out/flynet.lua"):gsub("\\", "/")
local NET_B = genv("FS_NET_B", NET_A):gsub("\\", "/")
local BRAIN_A, BRAIN_B = genv("FS_BRAIN_A", nil), genv("FS_BRAIN_B", nil)
local FREEZE_B = genv("FS_FREEZE_B", "0") == "1"
local SEED = tonumber(genv("FS_SEED", "31337"))
local MAXMIN = tonumber(genv("FS_MAXMIN", "360"))
-- FS_STAGE: a curback for every match, or "cycle" (default) for the VS stage cycle in turn.
-- The cycle leaves out KAHN'S ARENA (8) - every ani2 runaway latched so far happened there,
-- mid-fight, and a stream should not sit on the one arena known to trip it - and the
-- WAFFLE HOUSE (017h), which is paused.
local STAGE = tonumber(genv("FS_STAGE", "cycle"))
local STAGE_CYCLE = { 0, 1, 2, 3, 4, 5, 6, 7, 9, 0x0a, 0x16, 0x18, 0x19, 0x1a }
local GAIN = tonumber(genv("FS_GAIN", "5"))
local OVERLAY = genv("FS_OVERLAY", "0") == "1"
local CHARS = {}
do
  local s = genv("FS_CHARS", "cycle")
  if s == "cycle" then CHARS = { 1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 16, 17 }   -- 16 Jade, 17 Ermac
  else for n in s:gmatch("%d+") do CHARS[#CHARS + 1] = tonumber(n) end end
end
math.randomseed(SEED)

local CHAR_NAME = { [0] = "KungLao", "LiuKang", "Cage", "Baraka", "Kitana", "Mileena", "Shang", "Raiden",
  "SubZero", "Reptile", "Scorpion", "Jax", "Kintaro", "ShaoKahn", "Smoke", "Noob", "Jade", "Ermac", "Khameleon" }
local logfh = io.open(OUT .. "/selfplay.log", "w")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[vs] " .. l); logfh:write(l, "\n"); logfh:flush()
end
local rounds = io.open(OUT .. "/rounds.csv", "w")
rounds:write("frame,match,round,p1_side,a_char,b_char,winner,p1_bar,p2_bar,frames,a_dealt,b_dealt,a_mood,b_mood\n")

local sym = {}
for line in io.lines(MAP) do for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end end
for _, n in ipairs({ "gstate", "p1_state", "p2_state", "p1_char", "p2_char", "curback", "p1_obj", "p2_obj",
  "p1_bar", "p2_bar", "winner_status", "objlst", "round_num", "diff", "p1_matchw", "p2_matchw" }) do
  if not sym[n] then log("ERROR missing symbol %s", n) end
end
local O = { next = 0x000, oxvel = 0x040, oxpos = 0x090, oypos = 0x0b0 }
local MP = { sag = 0, sizex = 32, sizey = 48, anix = 80, aniy = 96, len = 112 }
local GS = { amode = 1, fighting = 2, buyin = 3, psel = 4 }
local REACT = { 6, 6, 5, 5, 4, 4, 4, 3, 3, 3 }

-- ------------------------------------------------------------------ circuit
local function load_net(path)
  local NET = dofile(path)
  local net = { NET = NET, C = NET.constants, S = NET.sensory, N = #NET.names, fam = {}, sense = {}, v = {}, a = {}, prev = {} }
  for i, n in ipairs(NET.names) do
    local base, side = n:match("^(.-)_([LR])$")
    base = base or n
    if base == "DNp01" or base == "DNp02" or base == "DNp04" or base == "DNp11" then net.fam[#net.fam + 1] = i end
    if NET.group[i] == "sense" then net.sense[base .. "_" .. (side or "")] = i end
  end
  for i = 1, net.N do net.v[i] = 0; net.a[i] = 0 end
  return net
end
local function circuit_step(net, objs)
  local drive = { LC4_L = 0, LC4_R = 0, LPLC2_L = 0, LPLC2_R = 0 }
  local now, S = {}, net.S
  for _, o in ipairs(objs) do
    local side = o[2] >= 0 and "R" or "L"
    local d = math.max(math.abs(o[2]) - S.body_gap, 4.0)
    local th = math.deg(2.0 * math.atan(o[3] / d))
    now[o[1]] = th
    local dth = th - (net.prev[o[1]] or th)
    local lc4 = math.floor(255 * math.min(math.max(dth, 0.0) / S.lc4_full, 1.0))
    local lp = 0
    if dth > 0.05 then lp = math.floor(255 * math.exp(-((th - S.lplc2_peak) / S.lplc2_sigma) ^ 2)) end
    -- binocular overlap, as in flybrain_play.lua: the share that crosses the midline
    -- grows with angular size, the total is conserved, and it stays INTEGER - the model
    -- shifts its inputs and Lua refuses to shift a fraction
    local other = side == "R" and "L" or "R"
    local cross = math.min(th / (S.binoc_span or 40), 1.0) * 0.5
    local lc4_x, lp_x = math.floor(lc4 * cross), math.floor(lp * cross)
    drive["LC4_" .. side] = math.min(255, drive["LC4_" .. side] + (lc4 - lc4_x))
    drive["LC4_" .. other] = math.min(255, drive["LC4_" .. other] + lc4_x)
    drive["LPLC2_" .. side] = math.min(255, drive["LPLC2_" .. side] + (lp - lp_x))
    drive["LPLC2_" .. other] = math.min(255, drive["LPLC2_" .. other] + lp_x)
  end
  net.prev = now
  for k, i in pairs(net.sense) do net.a[i] = drive[k] or 0 end
  local peak, C, v, a = 0, net.C, net.v, net.a
  for _ = 1, C.substeps do
    local inp = {}
    for i = 1, net.N do inp[i] = 0 end
    for _, e in ipairs(net.NET.edges) do
      local ap = a[e[2]]
      if ap ~= 0 then inp[e[1]] = inp[e[1]] + e[3] * ap end
    end
    for i = 1, net.N do
      if net.NET.group[i] ~= "sense" then
        -- SIGNED shift. Lua 5.4's >> is LOGICAL (-32 >> 5 = 576460752303423487), so an
        -- inhibited cell got ~5.7e17 and fired at 255 - inhibition became maximal excitation
        -- and one looming burst latched escape on for good. Floor division is the arithmetic
        -- shift flybrain_sim.py (Python) always used. Same fix as flybrain_play.lua ac851134.
        local vi = v[i] + inp[i] // (1 << GAIN) - v[i] // (1 << C.leak_shift)
        if vi > C.vmax then vi = C.vmax elseif vi < -C.vmax then vi = -C.vmax end
        v[i] = vi
        local ai = vi - C.theta
        if ai < 0 then ai = 0 elseif ai > 255 then ai = 255 end
        a[i] = ai
      end
    end
    for _, i in ipairs(net.fam) do if a[i] > peak then peak = a[i] end end
  end
  return peak >= C.fire, drive, peak
end

-- ------------------------------------------------------------------ moves
local function hold(n, ...) return { n = n, keys = { ... } } end
-- AUTOMATIC SPECIALS, same mechanism as flybrain_play.lua: the motion is written into the
-- player's joystick close queue (p1_jcq / p2_jcq) exactly as switch_queue_a0 would, then the
-- button is pressed, so the game recognises the special on the button alone.
local AUTO_SPECIALS = genv("FS_AUTO_SPECIALS", "1") == "1"
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
    m[#m + 1] = { n = 4, keys = { table.unpack(buttons) }, inject = dirs }; m[#m + 1] = hold(2)
    return m
  end
  for _, d in ipairs(dirs) do m[#m + 1] = hold(3, d); m[#m + 1] = hold(2) end
  m[#m + 1] = hold(4, table.unpack(buttons)); m[#m + 1] = hold(2)
  return m
end
local BASIC = {
  walk_in    = { r = { 2, 3 }, m = { hold(14, "F") } },
  walk_back  = { r = { 1, 2 }, m = { hold(12, "B") } },
  wait       = { r = { 1, 2, 3 }, m = { hold(8) } },
  jump_in    = { r = { 2, 3 }, m = { hold(4, "U", "F"), hold(14), hold(4, "HK"), hold(20) } },
  jab        = { r = { 1 }, m = { hold(3, "HP"), hold(3), hold(3, "HP"), hold(4) } },
  high_kick  = { r = { 1 }, m = { hold(3, "HK"), hold(10) } },
  low_kick   = { r = { 1 }, m = { hold(3, "LK"), hold(8) } },
  sweep      = { r = { 1 }, m = { hold(3, "B", "LK"), hold(14) } },
  uppercut   = { r = { 1 }, m = { hold(4, "D"), hold(3, "D", "HP"), hold(16) } },
  roundhouse = { r = { 1 }, m = { hold(3, "B", "HK"), hold(14) } },
  throw      = { r = { 1 }, m = { hold(3, "F"), hold(3, "F", "LP"), hold(10) } },
  block      = { r = { 1, 2 }, m = { hold(16, "BL") } },
  duck_block = { r = { 1, 2 }, m = { hold(16, "D", "BL") } },
}
-- the main rig's table verbatim, so a per-fighter brain trained there finds every move it
-- learned about here (Jade 16 and Ermac 17 included)
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
  t_air    = { "uppercut", "block", "back_jump", "roundhouse" },
  t_proj   = { "block", "duck_block", "jump_over", "jump_up", "back_jump" },
}
local DEF_MOVES = {
  back_jump = { hold(4, "U", "B"), hold(24) },
  jump_over = { hold(4, "U", "F"), hold(24) },
  jump_up   = { hold(4, "U"), hold(22) },
}

-- ------------------------------------------------------------------ finishers
-- flybrain_play.lua's tables verbatim: every fatality, stage fatality, babality and
-- the single-player fly knows, so both flies finish the way it does

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
-- a macro that presses HP or LP - the game refuses a babality after one
local function uses_punch(m)
  for _, st in ipairs(m) do
    for _, k in ipairs(st.keys) do if k == "HP" or k == "LP" then return true end end
  end
  return false
end
-- KICKS-ONLY ROUNDS. The babality needs a round with no HP/LP at all (bb_check),
-- and every fly punched in every round - uppercuts and throws included - so not
-- one was ever possible. A style decides how often it fights a round on kicks alone: the
-- COUNTER-fighter often (it is setting up the taunt), the BRAWLER rarely.
local function no_punches(list, lookup)
  local out = {}
  for _, n in ipairs(list) do if not uses_punch(lookup(n)) then out[#out + 1] = n end end
  return #out > 0 and out or list
end

local function options_for(char, bucket)
  local list = {}
  for name, o in pairs(BASIC) do
    for _, r in ipairs(o.r) do if r == bucket then list[#list + 1] = { name = name, m = o.m } end end
  end
  for name, sp in pairs(SPECIALS[char] or {}) do
    for _, r in ipairs(sp[3]) do
      if r == bucket then
        local m = #sp[1] == 0 and { hold(4, table.unpack(sp[2])), hold(12) } or special(sp[1], sp[2])
        list[#list + 1] = { name = "sp_" .. name, m = m }
      end
    end
  end
  table.sort(list, function(x, y) return x.name < y.name end)
  return list
end
local function defence_move(n) return DEF_MOVES[n] or BASIC[n].m end

-- ------------------------------------------------------------------ a fighter's brain
local W_INIT, W_MIN, W_MAX, DECAY = 10, 2, 120, 0.01
local MOOD_BASE = 0.45
local AGGRESSIVE = { jab = 1, high_kick = 1, low_kick = 1, sweep = 1, uppercut = 1, roundhouse = 1, throw = 1, jump_in = 1 }
local DEFENSIVE = { walk_back = 1, block = 1, duck_block = 1, wait = 1 }
-- STYLES (FS_STYLE_A / FS_STYLE_B). Two copies of one brain choose the same moves in the same
-- spot - on stream they mirrored each other. A style is a TEMPERAMENT the learning sits on
-- top of: its own mood baseline (the aggression state it relaxes back to) and a standing bias
-- over the move families. The learned values still decide within that, and each side learns
-- separately, so the two drift further apart as they play rather than converging.
local STYLES = {
  aggressive = { name = "BRAWLER", base = 0.70, atk = 14, sp = 10, def = -8, kick_rounds = 0.12,
                 like = { jump_in = 6, throw = 6, walk_in = 8 } },
  counter    = { name = "COUNTER", base = 0.25, atk = -6, sp = -4, def = 12, kick_rounds = 0.55,
                 like = { sweep = 8, uppercut = 10, walk_back = 6, duck_block = 6 } },
  balanced   = { name = "BALANCED", base = MOOD_BASE, atk = 0, sp = 0, def = 0, kick_rounds = 0.25, like = {} },
}

local function new_side(tag, netpath, brainfile, learns, style)
  local s = { tag = tag, net = load_net(netpath), W = {}, brain = brainfile, learns = learns,
              mood = MOOD_BASE, recent = {}, macro = nil, step = 0, left = 0, armed = nil, refract = 0,
              dealt = 0, taken = 0 }
  if brainfile then
    local ok, t = pcall(dofile, brainfile)
    if ok and type(t) == "table" then
      local w = t.w or t
      -- A single-player brain is keyed [fighter][context][option] and is kept exactly
      -- that way - see weights(). An old flat self-play brain ([context][option]) seeds
      -- every fighter instead.
      local per_char = false
      for k, v in pairs(w) do
        if type(k) == "number" and type(v) == "table" then
          for _, vv in pairs(v) do if type(vv) == "table" then per_char = true end break end
        end
        break
      end
      if per_char then
        s.W = w
        log("%s loaded a per-fighter brain from %s", tag, brainfile)
      else
        s.seedflat = w
        log("%s seeded every fighter from a flat brain %s", tag, brainfile)
      end
    end
  end
  s.name = genv("FS_NAME_" .. tag, tag == "A" and "VINEGAR" or "DISH SOAP")
  s.style = STYLES[style] or STYLES.balanced
  s.base = s.style.base
  s.mood = s.base
  log("%s is %s and fights as %s", tag, s.name, s.style.name)
  return s
end
-- PER FIGHTER. The single-player fly learned a separate brain for every fighter it plays;
-- averaging them into one (what this used to do) threw away exactly what it had learned,
-- because a flying kick's value means nothing to Kung Lao. Keyed [fighter][context][option].
local function weights(s, ctx)
  local c = s.char or 0
  local cw = s.W[c]
  if not cw then cw = {}; s.W[c] = cw end
  if not cw[ctx] then
    cw[ctx] = {}
    local seed = s.seedflat and s.seedflat[ctx]
    if seed then for k, v in pairs(seed) do if type(v) == "number" then cw[ctx][k] = v end end end
  end
  return cw[ctx]
end
local function pick(s, ctx, names, bias)
  local w, total = weights(s, ctx), 0
  local k = (s.mood - s.base) * 24
  local st = s.style
  local function val(n)
    local m = (AGGRESSIVE[n] or n:sub(1, 3) == "sp_") and k or (DEFENSIVE[n] and -k or 0)
    local sb = (AGGRESSIVE[n] and st.atk or 0) + (n:sub(1, 3) == "sp_" and st.sp or 0)
               + (DEFENSIVE[n] and st.def or 0) + (st.like[n] or 0)
    return math.max(1, (w[n] or W_INIT) + ((bias and bias[n]) or 0) + m + sb)
  end
  for _, n in ipairs(names) do
    w[n] = w[n] or W_INIT
    if s.learns and DECAY > 0 then w[n] = w[n] + (W_INIT - w[n]) * DECAY end
    total = total + val(n)
  end
  local r = math.random() * total
  for _, n in ipairs(names) do
    r = r - val(n)
    if r <= 0 then return n end
  end
  return names[#names]
end
local function credit(s, frame, amount, window)
  if not s.learns then return end
  for _, d in ipairs(s.recent) do
    local age = frame - d.frame
    if age >= 0 and age <= window then
      local w = weights(s, d.ctx)
      local x = amount * (1.0 - age / (window + 1))
      w[d.opt] = math.max(W_MIN, math.min(W_MAX, (w[d.opt] or W_INIT) + x))
    end
  end
end
local function save_brain(s)
  if not (s.brain and s.learns) then return end
  local fh = io.open(s.brain .. ".tmp", "w")
  -- [fighter][context][option], the single-player brain's own shape, so a self-play brain
  -- loads straight back into flybrain_play.lua and the other way round
  fh:write("return {\n  w = {\n")
  for c, ctxs in pairs(s.W) do
    if type(c) == "number" and type(ctxs) == "table" then
      fh:write(string.format("    [%d] = {\n", c))
      for ctx, ws in pairs(ctxs) do
        if type(ws) == "table" then
          fh:write(string.format("      [%q] = {", ctx))
          for n, x in pairs(ws) do
            if type(x) == "number" then fh:write(string.format(" [%q]=%.3f,", n, x)) end
          end
          fh:write(" },\n")
        end
      end
      fh:write("    },\n")
    end
  end
  fh:write("  },\n}\n")
  fh:close()
  os.remove(s.brain)
  os.rename(s.brain .. ".tmp", s.brain)
end

-- ------------------------------------------------------------------ runtime
local space, fields, screen, frame = nil, {}, nil, 0
local function r16(x) return space:read_u16(x) end
local function r32(x) return space:read_u32(x) end
local function w16(x, v) space:write_u16(x, v & 0xffff) end
local function s16(x) x = x & 0xffff; if x >= 0x8000 then return x - 0x10000 end; return x end
local function s32(x) x = x & 0xffffffff; if x >= 0x80000000 then return x - 0x100000000 end; return x end

local A = new_side("A", NET_A, BRAIN_A, true, genv("FS_STYLE_A", "aggressive"))
local B = new_side("B", NET_B, BRAIN_B, not FREEZE_B, genv("FS_STYLE_B", "counter"))
local charsel, confirm, fight, away = 0, 0, 0, 0
local matches, round_open, rs = 0, false, nil
local settled = 0                -- frames since the fight was last decided
P1SIDE = A                      -- which brain is on the P1 stick this match (they swap)
local prev_p, bars, ground = nil, nil, {}
-- RANDOM picks, not a fixed walk through CHARS: the walk restarted at match 1 on every
-- stream restart, so every part opened on the same pairing and the fighters at the end of
-- the list (Jade and Ermac) almost never came up. The secret fighters get double weight so a
-- viewer actually sees them.
local PICK_WEIGHT = { [16] = 2, [17] = 2 }
local function random_char()
  local total = 0
  for _, c in ipairs(CHARS) do total = total + (PICK_WEIGHT[c] or 1) end
  local r = math.random() * total
  for _, c in ipairs(CHARS) do
    r = r - (PICK_WEIGHT[c] or 1)
    if r <= 0 then return c end
  end
  return CHARS[#CHARS]
end
local sel_a, sel_b = random_char(), random_char()

local function pose_of(obj, facing_left)
  local mp = r32(obj + 0x1a0)
  if mp == 0 then return nil end
  local reach, top, bottom, n = 0, 9999, -9999, 0
  while n < 11 do
    local sag = r32(mp + MP.sag)
    if sag == 0 then break end
    local sx, sy = r16(mp + MP.sizex), r16(mp + MP.sizey)
    local ax, ay = s16(r16(mp + MP.anix)), s16(r16(mp + MP.aniy))
    if sx > 0 and sx < 300 and sy > 0 and sy < 300 then
      local left, right = -ax, -ax + sx
      local far = facing_left and -left or right
      if far > reach then reach = far end
      if -ay < top then top = -ay end
      if -ay + sy > bottom then bottom = -ay + sy end
    end
    mp = mp + MP.len; n = n + 1
  end
  if n == 0 or top > bottom then return nil end
  return { reach = reach, height = bottom - top }
end

local function perceive()
  local o1, o2 = r32(sym.p1_obj), r32(sym.p2_obj)
  if o1 == 0 or o2 == 0 then return nil end
  local p = { x1 = s16(r16(o1 + O.oxpos)), y1 = s16(r16(o1 + O.oypos)),
              x2 = s16(r16(o2 + O.oxpos)), y2 = s16(r16(o2 + O.oypos)),
              bar1 = r16(sym.p1_bar), bar2 = r16(sym.p2_bar), proj = {} }
  p.pose1 = pose_of(o1, p.x2 < p.x1)
  p.pose2 = pose_of(o2, p.x1 < p.x2)
  local o, n = r32(sym.objlst), 0
  while o ~= 0 and n < 200 do
    if o ~= o1 and o ~= o2 then
      local vx = s32(r32(o + O.oxvel)) / 65536.0
      if math.abs(vx) >= 1.5 then p.proj[#p.proj + 1] = { x = s16(r16(o + O.oxpos)), vx = vx } end
    end
    o = r32(o + O.next); n = n + 1
  end
  return p
end

-- one side's tick: sense, decide, drive its stick
-- One queue entry per direction, [switch:16 | tick:16], bit 31 = q_face_left, written the
-- way switch_queue_a0 (MKINIT.ASM) writes it; facing by sq_stamp_facing's strict rule (the
-- other fighter STRICTLY to the right = facing right). 20 slots after a next-pointer.
local function inject_q(qsym, dirs, facing_right, toward_right, spread)
  local base = sym[qsym]
  if not (base and sym.tick) then return end
  local fwd = toward_right and 8 or 7                  -- sw_right / sw_left as pushed
  local back = fwd == 8 and 7 or 8
  local now = r16(sym.tick)
  for i, d in ipairs(dirs) do
    local sw = (d == "F" and fwd) or (d == "B" and back) or (d == "U" and 5) or (d == "D" and 6)
    if sw then
      local age = spread and (spread - math.floor((spread - 2) * (i - 1) / math.max(1, #dirs - 1)))
                  or 2 * (#dirs - i + 1)                -- spread: see flybrain_play.lua inject()
      local e = (sw << 16) | ((now - age) & 0xffff)
      if not facing_right then e = e | 0x80000000 end
      local nxt = r32(base)
      space:write_u32(nxt, e & 0xffffffff)
      nxt = nxt + 32
      if nxt >= base + 21 * 32 then nxt = base + 32 end
      space:write_u32(base, nxt)
    end
  end
end

local function side_tick(s, me_x, me_y, him_x, him_y, him_pose, press, keys, delay)
  local rel = him_x - me_x
  local dist = math.abs(rel)
  local fwd = rel >= 0 and keys.right or keys.left
  local back = rel >= 0 and keys.left or keys.right
  -- what is coming at me: him, plus anything moving my way
  local objs = { { "opp", rel, s.net.S.fighter_half_w } }
  local proj_near = false
  for k, pr in ipairs(s.proj or {}) do
    if (pr.x - me_x) * pr.vx < 0 then
      objs[#objs + 1] = { "p" .. k, pr.x - me_x, s.net.S.proj_half_w }
      proj_near = true
    end
  end
  local fire, drive, peak = circuit_step(s.net, objs)
  s.vis = { drive = drive, peak = peak }                -- for the HUD
  local air = s.ground and (s.ground - him_y) > 14
  if fire and not s.armed and frame >= s.refract then
    s.armed = frame + delay
    s.armed_ctx = proj_near and "t_proj" or (air and "t_air" or "t_ground")
  end
  if s.armed and frame >= s.armed then
    local list = DEFENCE[s.armed_ctx]
    if s.kicks_only then list = no_punches(list, defence_move) end
    local choice = pick(s, s.armed_ctx, list)
    s.vis_move, s.vis_def = choice, true
    s.tally = s.tally or {}; s.tally[choice] = (s.tally[choice] or 0) + 1
    s.macro, s.step, s.left = defence_move(choice), 1, defence_move(choice)[1].n
    s.recent[#s.recent + 1] = { frame = frame, ctx = s.armed_ctx, opt = choice }
    s.armed, s.refract = nil, frame + 30
    s.defences = (s.defences or 0) + 1
  end
  if not s.macro and not s.armed then
    local bucket = dist <= 80 and 1 or (dist <= 160 and 2 or 3)
    local cls = "g"
    if air then cls = "a"
    elseif him_pose then
      if him_pose.reach > 46 then cls = "r"
      elseif s.stand_h and him_pose.height < s.stand_h * 0.72 then cls = "c" end
      if not air and (s.stand_h == nil or him_pose.height > s.stand_h) then s.stand_h = him_pose.height end
    end
    local ctx = string.format("r%d%s", bucket, cls)
    local opts = options_for(s.char, bucket)
    local names, bym = {}, {}
    for _, o in ipairs(opts) do names[#names + 1] = o.name; bym[o.name] = o.m end
    if s.kicks_only then names = no_punches(names, function(n) return bym[n] end) end
    local choice = pick(s, ctx, names)
    s.vis_move, s.vis_def = choice, false
    s.tally = s.tally or {}; s.tally[choice] = (s.tally[choice] or 0) + 1
    s.macro, s.step, s.left = bym[choice], 1, bym[choice][1].n
    s.recent[#s.recent + 1] = { frame = frame, ctx = ctx, opt = choice }
    s.ctx, s.last = ctx, choice
    s.decisions = (s.decisions or 0) + 1
  end
  while #s.recent > 40 do table.remove(s.recent, 1) end
  if s.macro then
    local st = s.macro[s.step]
    -- which queue: judged from the key NAMES, not `keys == K1` - K1 is declared after this
    -- function, so inside it that name is an undefined global and the test is always false
    if st.inject and s.left == st.n then
      inject_q(keys.left == "P1 Left" and "p1_jcq" or "p2_jcq", st.inject, him_x > me_x, rel >= 0, st.spread)
    end
    for _, k in ipairs(st.keys) do
      if k == "F" then press[fwd] = true
      elseif k == "B" then press[back] = true
      else
        press[keys[k]] = true
        if k == "HP" or k == "LP" then s.punched = true end   -- bb_check/fs_check: no punches
      end
    end
    s.left = s.left - 1
    if s.left <= 0 then
      s.step = s.step + 1
      if s.step > #s.macro then s.macro = nil else s.left = s.macro[s.step].n end
    end
  end
end

-- FINISH HIM, fly versus fly. The winner decides how to end it - a fatality, a stage
-- fatality, or a babality if it threw no punch this round (the game's own rule:
-- bb_check refuses it after a HP or LP), or just knock him down - walks to that
-- move's distance, inputs it, and checks f_fatal_lock, which is set the instant a finisher
-- starts. PERSONALITY decides the leaning, the learned values decide within it: the BRAWLER
-- goes for blood, the COUNTER-fighter taunts - and a babality, the most disrespectful ending
-- in the game, is where a counter-fighter's rout goes. Three tries, then it gives up.
snap_until = 0                                          -- FS_SNAP_FINISH burst (global: the frame loop reads it)
local finlog = io.open(OUT .. "/finishers.csv", "w")
finlog:write("frame,match,name,style,char,victim,punched,finisher,try,landed\n")
local function finish_side(s, victim, me_x, him_x, my_bar, keys, press, matchno)
  local rel = him_x - me_x
  local toward_right = rel >= 0
  local fwd = toward_right and keys.right or keys.left
  local back = toward_right and keys.left or keys.right
  local dist = math.abs(rel)
  local f = s.fin
  if not f then f = { phase = "choose", tries = 0, t = 0 }; s.fin = f end
  f.t = f.t + 1
  local function record(landed)
    finlog:write(string.format("%d,%d,%s,%s,%s,%s,%d,%s,%d,%d\n", frame, matchno, s.name, s.style.name,
      CHAR_NAME[s.char] or tostring(s.char), CHAR_NAME[victim.char] or tostring(victim.char),
      s.punched and 1 or 0, f.opt, f.tries + 1, landed))
    finlog:flush()
  end
  if sym.f_fatal_lock and r16(sym.f_fatal_lock) ~= 0 and f.phase ~= "done" then
    if f.opt and f.phase ~= "choose" then
      local w = weights(s, "finish")
      w[f.opt] = math.min(120, (w[f.opt] or 10) + 30)
      record(1)
      log("FINISHER: %s (%s) - %s, try %d", s.name, CHAR_NAME[s.char] or s.char, f.opt, f.tries + 1)
      if os.getenv("FS_SNAP_FINISH") == "1" then snap_until = frame + 240 end   -- test hook: film it
    end
    f.phase = "done"
  end
  if f.phase == "done" then return end

  if f.phase == "choose" then
    local c = s.char
    local names, spec = {}, {}
    for name, fa in pairs(FATAL[c] or {}) do
      names[#names + 1] = "fatal_" .. name
      spec["fatal_" .. name] = { m = finisher_macro(fa[1], fa[2], fa[3]), d = fa[4],
                                 open = fa[3] == "open" and { button = fa[2], dirs = fa[1] } or nil }
    end
    if not s.punched and BABY[c] then
      names[#names + 1] = "babality"; spec.babality = { m = special(BABY[c][1], { BABY[c][2] }) }
    end
    if DTP_STAGES[r16(sym.curback)] and STAGE_FATAL[c] then
      local sf = STAGE_FATAL[c]
      names[#names + 1] = "stage_fatality"; spec.stage_fatality = { m = special(sf[1], { sf[2] }), d = 50 }   -- check_dtp: within 048h
      if sf[3] and spec.stage_fatality.m[1].inject then spec.stage_fatality.m[1].spread = sf[3] end
    end
    -- THE DEAD POOL's stage fatality has no input pattern: an uppercut that lands clean in
    -- FINISH HIM while the attacker holds LP + LK (do_uppercut, ucut2 - see
    -- doc/DEADPOOL_STAGE_FATALITY.md) throws him into the acid. Every fighter has it.
    if r16(sym.curback) == 0 then
      names[#names + 1] = "stage_fatality"
      -- LP + LK are tested when the uppercut CONNECTS (ucut, several frames after the press),
      -- so they stay held through the swing - letting go after the press never slimed anyone
      spec.stage_fatality = { m = { hold(4, "D", "LP", "LK"), hold(3, "D", "HP", "LP", "LK"), hold(24, "LP", "LK") },
                              d = 45, prehold = { "LP", "LK" } }
    end
    names[#names + 1] = "knock_down"
    spec.knock_down = { m = { hold(4, "D"), hold(3, "D", "HP"), hold(20) }, d = 45 }
    table.sort(names)
    local dominant = math.min(1.0, my_bar / 0xa1)       -- how easy the win was, 0..1
    local bias = {}
    if s.style.name == "COUNTER" then
      bias.babality = 20 + math.floor(dominant * 15)
    elseif s.style.name == "BRAWLER" then
      bias.stage_fatality = 14
      for _, n in ipairs(names) do if n:sub(1, 6) == "fatal_" then bias[n] = 12 end end
      bias.babality = math.floor(dominant * 12)          -- even a brawler rubs in a rout
    end
    -- FS_FORCE_FINISH=<option>: test hook - always go for that finisher when it is on offer
    local force = os.getenv("FS_FORCE_FINISH")
    if force and spec[force] then f.opt = force else f.opt = pick(s, "finish", names, bias) end
    f.spec = spec[f.opt]
    log("FINISH HIM: %s (%s, %d health left, %s) goes for %s", s.name, s.style.name, my_bar,
      s.punched and "punched" or "no punches", f.opt)
    s.vis_move, s.vis_def = "finish: " .. f.opt, false
    f.phase, f.t = "approach", 0
  end
  -- A RELEASE-triggered finisher charges its button first, and pressing that button at
  -- point blank is an ordinary low kick / low punch that knocks the dazed man over and ends
  -- FINISH HIM (Kitana 1 of 19, Jax 1 of 28). So do it the way a player does: back off out of
  -- reach, press and HOLD there, walk in still holding, queue the motion, then let go.
  -- buttons that must already be HELD when the move goes in (the Dead Pool's LP + LK):
  -- pressed at point blank they would be a low punch into the dazed man, so press them out
  -- of reach and walk in holding them, then run the move with them still down
  if f.phase == "approach" and f.spec.prehold then
    if f.t < 150 and dist < f.spec.d + 80 then press[back] = true; return end
    f.phase, f.t = "prehold", 0
  end
  if f.phase == "prehold" then
    for _, k in ipairs(f.spec.prehold) do press[keys[k]] = true end
    if dist > f.spec.d + 8 and f.t < 200 then press[fwd] = true; return end
    f.m, f.step, f.left = f.spec.m, 1, f.spec.m[1].n
    f.phase, f.t = "input", 0
    return
  end
  if f.phase == "approach" and f.spec.open and AUTO_SPECIALS then
    if f.t < 150 and dist < f.spec.d + 80 then press[back] = true; return end
    f.phase, f.t, f.held = "charge", 0, 0
  end
  if f.phase == "charge" then
    press[keys[f.spec.open.button]] = true
    f.held = f.held + 1
    if dist > f.spec.d + 8 and f.t < 200 then press[fwd] = true; return end
    if f.held < 72 then return end                       -- charged? (40-64 ticks asked)
    inject_q(keys.left == "P1 Left" and "p1_jcq" or "p2_jcq", f.spec.open.dirs, him_x > me_x, toward_right)
    f.phase, f.t = "release", 0
    return
  end
  if f.phase == "release" then                         -- no keys: letting go IS the input
    if f.t >= 2 then f.phase, f.t = "wait", 0 end
    return
  end
  if f.phase == "approach" then
    local d = f.spec.d
    if d and f.t < 150 and math.abs(dist - d) > 8 then
      press[(dist > d) and fwd or back] = true
      return
    end
    f.m, f.step, f.left = f.spec.m, 1, f.spec.m[1].n
    f.phase, f.t = "input", 0
  end
  if f.phase == "input" then
    local st = f.m[f.step]
    if st.inject and f.left == st.n then
      inject_q(keys.left == "P1 Left" and "p1_jcq" or "p2_jcq", st.inject, him_x > me_x, toward_right, st.spread)
    end
    for _, k in ipairs(st.keys) do
      if k == "F" then press[fwd] = true elseif k == "B" then press[back] = true else press[keys[k]] = true end
    end
    f.left = f.left - 1
    if f.left <= 0 then
      f.step = f.step + 1
      if f.step > #f.m then f.phase, f.t = "wait", 0 else f.left = f.m[f.step].n end
    end
    return
  end
  if f.phase == "wait" and f.t >= 40 then
    if f.opt ~= "knock_down" then
      local w = weights(s, "finish")
      w[f.opt] = math.max(2, (w[f.opt] or 10) - 4)
      record(0)
    end
    f.tries = f.tries + 1
    if f.tries >= 3 or f.opt == "knock_down" then f.phase = "done" else f.phase = "choose" end
  end
end

local K1 = { left = "P1 Left", right = "P1 Right", U = "P1 Up", D = "P1 Down", HP = "P1 High Punch",
  LP = "P1 Low Punch", HK = "P1 High Kick", LK = "P1 Low Kick", BL = "P1 Block" }
local K2 = { left = "P2 Left", right = "P2 Right", U = "P2 Up", D = "P2 Down", HP = "P2 High Punch",
  LP = "P2 Low Punch", HK = "P2 High Kick", LK = "P2 Low Kick", BL = "P2 Block" }
local ALLKEYS = { "UI Select", "Coin 1", "Coin 2", "1 Player Start", "2 Players Start" }
for _, t in ipairs({ K1, K2 }) do for _, v in pairs(t) do ALLKEYS[#ALLKEYS + 1] = v end end

-- Jade and Ermac arrive only through their select-screen unlocks (forcing p?_char fails -
-- memory reference-secret-fighter-unreachable-by-force), so hold the unlock's base fighter
-- and raise that PLAYER's pending flag (..1 for P1, ..2 for P2); the game's own
-- jade/ermac_select_cheat_apply swaps the fighter in after select.
local SECRET_SEL = { [16] = { base = 5, flag = "f_jade_cheat" }, [17] = { base = 9, flag = "f_ermac_cheat" } }
local function sel_write(charsym, n, want)
  -- stop once the game shows the fighter we asked for: for Jade/Ermac that is the unlock
  -- having been applied, and writing the base fighter again would undo it
  if r16(sym[charsym]) == want then return end
  local sec = SECRET_SEL[want]
  if sec and sym[sec.flag .. n] then
    w16(sym[charsym], sec.base); w16(sym[sec.flag .. n], 1)
  else
    w16(sym[charsym], want)
  end
end

local function round_begin(p)
  rs = { start = frame, a0 = p.bar1, b0 = p.bar2 }
  A.dealt, B.dealt, A.defences, B.defences, A.decisions, B.decisions = 0, 0, 0, 0, 0, 0
  A.stand_h, B.stand_h = nil, nil
  A.recent, B.recent = {}, {}
  A.tally, B.tally = {}, {}
  A.punched, B.punched, A.fin, B.fin = false, false, nil, nil
  A.kicks_only = math.random() < (A.style.kick_rounds or 0)
  B.kicks_only = math.random() < (B.style.kick_rounds or 0)
  if os.getenv("FS_KICKS_ONLY") == "1" then A.kicks_only, B.kicks_only = true, true end   -- test hook
  A.mood = A.base + (A.mood - A.base) * 0.5          -- each relaxes toward its OWN temperament
  B.mood = B.base + (B.mood - B.base) * 0.5
  for _, s in ipairs({ A, B }) do
    for i = 1, s.net.N do s.net.v[i] = 0; s.net.a[i] = 0 end
    s.net.prev = {}
    s.macro, s.armed = nil, nil
  end
  ground = { p.y1, p.y2 }
  bars = { p.bar1, p.bar2 }
  round_open = true
  log("round %d: %s vs %s", r16(sym.round_num), CHAR_NAME[A.char] or A.char, CHAR_NAME[B.char] or B.char)
end

-- each side's four most-chosen moves this round - the evidence that the two styles really
-- do fight differently, rather than a guess from watching
local function top_moves(s)
  local t = {}
  for n, c in pairs(s.tally or {}) do t[#t + 1] = { n, c } end
  table.sort(t, function(x, y) return x[2] > y[2] end)
  local out = {}
  for i = 1, math.min(4, #t) do out[#out + 1] = t[i][1] .. " " .. t[i][2] end
  return table.concat(out, ", ")
end
local function round_end()
  local b1, b2 = r16(sym.p1_bar), r16(sym.p2_bar)
  log("  %s (%s) chose: %s", A.name, A.style.name, top_moves(A))
  log("  %s (%s) chose: %s", B.name, B.style.name, top_moves(B))
  if screen then pcall(function() screen:snapshot() end) end   -- a record of every round's end
  local two = P1SIDE == A and B or A
  local winner = b1 > b2 and P1SIDE.tag or (b2 > b1 and two.tag or "DRAW")
  rounds:write(string.format("%d,%d,%d,%s,%s,%s,%s,%d,%d,%d,%d,%d,%.2f,%.2f\n", frame, matches, r16(sym.round_num),
    P1SIDE.tag, CHAR_NAME[A.char] or A.char, CHAR_NAME[B.char] or B.char, winner, b1, b2, frame - rs.start,
    A.dealt, B.dealt, A.mood, B.mood))
  rounds:flush()
  log("  -> %s wins (bars %d/%d, dealt %d/%d, moods %.2f/%.2f, decisions %d/%d)", winner, b1, b2,
    A.dealt, B.dealt, A.mood, B.mood, A.decisions or 0, B.decisions or 0)
  save_brain(A); save_brain(B)
  round_open = false
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    screen = manager.machine.screens[":screen"]
    for _, port in pairs(manager.machine.ioport.ports) do for _, f in pairs(port.fields) do fields[f.name] = f end end
    log("fly vs fly: A net %s, B net %s%s, stage %s", NET_A:match("[^/]+$"), NET_B:match("[^/]+$"),
      FREEZE_B and " (B frozen)" or "", STAGE and string.format("%02x", STAGE) or "cycle")
  end
  if snap_until and frame < snap_until and frame % 6 == 0 and screen then pcall(function() screen:snapshot() end) end
  if READY and frame == 120 then local r = io.open(READY, "w"); r:write("ok"); r:close() end

  local press = {}
  local gs = r16(sym.gstate)
  if gs == GS.psel and charsel == 0 then charsel = frame end
  if gs == GS.fighting and fight == 0 then
    fight = frame
    P1SIDE = (matches % 2 == 0) and A or B
    local two = P1SIDE == A and B or A
    P1SIDE.char, two.char = r16(sym.p1_char), r16(sym.p2_char)
    log("match %d: %s(%s) on P1 vs %s(%s) on P2", matches + 1, P1SIDE.tag, CHAR_NAME[P1SIDE.char] or P1SIDE.char,
      two.tag, CHAR_NAME[two.char] or two.char)
  end
  -- a won round leaves the fight state for the bonus/next-round screens, so close
  -- the round here too or two rounds get logged as one
  if round_open and gs ~= GS.fighting and rs then round_end() end
  -- the game ends itself now and then in a two-player match: start another one
  if fight > 0 and gs ~= GS.fighting and gs ~= 5 and gs ~= 6 and gs ~= 7 then
    away = away + 1
    if away > 300 then
      if round_open then round_end() end
      matches = matches + 1
      sel_a, sel_b = random_char(), random_char()
      charsel, confirm, fight, away, prev_p = 0, 0, 0, 0, nil
    end
  else
    away = 0
  end

  if charsel == 0 then
    press["UI Select"] = frame >= 5 and frame < 35
    press["Coin 1"] = frame >= 200 and (frame % 80) < 20
    press["Coin 2"] = frame >= 200 and (frame % 80) < 20
    press["1 Player Start"] = frame >= 1000 and (frame % 120) < 20
    press["2 Players Start"] = frame >= 1000 and (frame % 120) >= 60 and (frame % 120) < 80
  elseif fight == 0 then
    w16(sym.p1_state, 1); w16(sym.p2_state, 1)
    sel_write("p1_char", "1", sel_a); sel_write("p2_char", "2", sel_b)
    w16(sym.curback, STAGE or STAGE_CYCLE[(matches % #STAGE_CYCLE) + 1])
    if confirm == 0 and frame - charsel > 90 then confirm = frame end
    local c = confirm > 0 and frame >= confirm and frame < confirm + 45
    press["P1 High Punch"] = c; press["P2 High Punch"] = c
    press["2 Players Start"] = (frame - charsel) % 60 < 10
  end

  if fight > 0 and gs == GS.fighting then
    local now = perceive()
    local p = prev_p                      -- ONE FRAME LATE, for both flies
    prev_p = now
    if p and now then
      -- winner_status flickers back to 0 during the knockdown and victory poses, so
      -- a round only OPENS once the fight has been settled for a while and both bars
      -- are back up. Without this the same round is closed and reopened every frame.
      if r16(sym.winner_status) ~= 0 then
        if round_open then round_end() end
        settled = 0
        if r16(sym.winner_status) == 3 then                 -- FINISH HIM: the standing fly finishes
          local one, two = P1SIDE, P1SIDE == A and B or A
          if p.bar1 > 0 and p.bar2 == 0 then finish_side(one, two, p.x1, p.x2, p.bar1, K1, press, matches)
          elseif p.bar2 > 0 and p.bar1 == 0 then finish_side(two, one, p.x2, p.x1, p.bar2, K2, press, matches) end
        end
      else
        settled = (settled or 0) + 1
        if not round_open and settled >= 40 and p.bar1 > 0 and p.bar2 > 0 then round_begin(p) end
      end
      if round_open then
        if p.y1 > ground[1] then ground[1] = p.y1 end
        if p.y2 > ground[2] then ground[2] = p.y2 end
        -- damage: each side learns from what it landed and what it took
        local dealt_a = math.max(0, bars[2] - p.bar2)
        local dealt_b = math.max(0, bars[1] - p.bar1)
        if dealt_a > 0 then
          A.dealt = A.dealt + dealt_a; credit(A, frame, 4 + dealt_a / 3, 60); credit(B, frame, -(3 + dealt_a / 4), 45)
          A.mood = math.min(1, A.mood + 0.012 * dealt_a); B.mood = math.max(0, B.mood - 0.010 * dealt_a)
        end
        if dealt_b > 0 then
          B.dealt = B.dealt + dealt_b; credit(B, frame, 4 + dealt_b / 3, 60); credit(A, frame, -(3 + dealt_b / 4), 45)
          B.mood = math.min(1, B.mood + 0.012 * dealt_b); A.mood = math.max(0, A.mood - 0.010 * dealt_b)
        end
        A.mood = A.mood + (A.base - A.mood) * 0.002
        B.mood = B.mood + (B.base - B.mood) * 0.002
        bars = { p.bar1, p.bar2 }
        local delay = REACT[r16(sym.diff) + 1] or 4
        -- P2 has a real side advantage in this game, so the brains SWAP sticks every
        -- match: whichever is on P1 this match is on P2 the next one.
        local one, two = P1SIDE, P1SIDE == A and B or A
        one.ground, two.ground = ground[2], ground[1]
        one.proj, two.proj = p.proj, p.proj
        side_tick(one, p.x1, p.y1, p.x2, p.y2, p.pose2, press, K1, delay + 1)
        side_tick(two, p.x2, p.y2, p.x1, p.y1, p.pose1, press, K2, delay + 1)
      end
    end
  end

  for _, n in ipairs(ALLKEYS) do
    if fields[n] then fields[n]:set_value(press[n] and 1 or 0) end
  end
  if frame > MAXMIN * 60 * 55 then log("done: %d minutes", MAXMIN); save_brain(A); save_brain(B); manager.machine:exit() end
end)

-- SMALL HUD PER FLY (FS_OVERLAY=1). The brains swap sticks every match, so each panel follows
-- whichever fly is on that side and names it with its style. Tucked under each life bar,
-- clear of the fighters: which fly, its mood, the two eyes, the escape reflex, and the move
-- it just chose ("dodge:" when the reflex picked it).
if OVERLAY then
  local function box(x0, y0, x1, y1, fill, line)
    pcall(function() screen:draw_box(x0, y0, x1, y1, line or fill, fill) end)   -- MAME: line colour first
  end
  local function text(x, y, t, col) pcall(function() screen:draw_text(x, y, t, col or 0xffffffff) end) end
  local function lamp(x, y, r, level, base)
    local l = math.min(255, math.max(0, math.floor(level)))
    local col = 0xff000000 | (((base >> 16 & 0xff) * l // 255) << 16) | (((base >> 8 & 0xff) * l // 255) << 8)
                | ((base & 0xff) * l // 255)
    box(x - r, y - r, x + r, y + r, col, 0xff303030)
  end
  local function bar(x, y, w, level, col)
    box(x, y, x + w, y + 3, 0xff101010, 0xff303030)
    local n = math.floor(w * math.min(math.max(level, 0), 255) / 255)
    if n > 0 then box(x, y, x + n, y + 3, col, col) end
  end
  -- one panel per fly, each in its own top corner right under its life bar: P1 top-left,
  -- P2 mirrored top-right, so a viewer reads each fly's panel next to its own name and bar
  local W, PW = 400, 118
  local function panel(f, x0, y0)
    local d = (f.vis and f.vis.drive) or {}
    box(x0, y0, x0 + PW, y0 + 29, 0xa0000000, 0xff40a040)
    text(x0 + 2, y0 + 1, f.name, 0xff80ff80)
    text(x0 + PW - 44, y0 + 1, f.style.name:lower(), 0xff70a070)
    bar(x0 + 64, y0 + 24, 30, (f.mood or 0.45) * 255, (f.mood or 0) > 0.5 and 0xffff4040 or 0xff4080ff)
    text(x0 + 97, y0 + 21, (f.mood or 0) > 0.5 and "hot" or "cool", 0xff608060)
    lamp(x0 + 6, y0 + 16, 3, math.max(d.LC4_L or 0, d.LPLC2_L or 0), 0xff60a0ff)     -- left eye
    lamp(x0 + 16, y0 + 16, 3, math.max(d.LC4_R or 0, d.LPLC2_R or 0), 0xff60a0ff)    -- right eye
    lamp(x0 + 28, y0 + 16, 3, (f.vis and f.vis.peak) or 0, 0xffff4040)               -- escape reflex
    local mv = f.vis_move and f.vis_move:gsub("^sp_", "") or ""
    text(x0 + 36, y0 + 12, (f.vis_def and "dodge: " or "") .. mv, f.vis_def and 0xffffff40 or 0xffd0d0d0)
    text(x0 + 2, y0 + 21, "eyes  panic", 0xff507050)
  end
  local hud_state = nil
  local ok = pcall(function() emu.register_frame_done(function()
    -- say once which gate is closed, so a missing HUD names its own cause
    local why = (not screen and "no screen") or (not P1SIDE and "no P1SIDE")
                or (r16(sym.gstate) ~= GS.fighting and "not fighting") or "drawing"
    if why ~= hud_state then hud_state = why; log("HUD: %s", why) end
    if why ~= "drawing" then return end
    local two = P1SIDE == A and B or A
    panel(P1SIDE, 3, 41)
    panel(two, W - 3 - PW, 41)
  end) end)
  if not ok then log("overlay: could not register the draw callback") end
end
