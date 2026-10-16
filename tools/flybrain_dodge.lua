-- flybrain_dodge.lua - does the fly's looming circuit time a dodge better than
-- a shuffled circuit or a hand-written rule?
--
-- The three-way ladder comparison showed the real wiring does not win more
-- FIGHTS than shuffled wiring - but in that player the circuit only decided when
-- to defend, inside a policy whose wins come from offence. This rig gives the
-- circuit its one job and nothing else, so its contribution can be measured.
--
-- Setup: a TWO-PLAYER game (both joystick ports, so no drone wedge). Player 2 is
-- a scripted attacker; player 1 (the defender) stands still and only ever jumps.
-- Each trial:
--   position  P2 walks to the trial's distance, P1 recentres, both settle in stance
--   attack    P2 throws its projectile or jumps in with a kick
--   defend    the trial's CONTROLLER watches the screen (one frame late) and, once
--             it decides to move, the jump starts after the stock drone's reaction
--             delay - the same no-advantage rule as the player
--   score     dodged = P1 took no damage; invalid = the attack never came out
-- The ACTION is fixed per threat so only TIMING differs: jump straight up against
-- projectiles, jump back against jump-ins.
--
-- Controllers are assigned at random per trial, so every one sees the same fights:
--   none      never moves (the baseline hit rate)
--   real      the MaleCNS looming circuit (out/flynet.lua), gain 4..7
--   shufN     degree-preserving rewirings of it (seeds 7, 11, 13), same gains
--   rule      fire when a threat is within D px and closing (D 60..210)
--
-- Env: DG_MAP DG_OUT DG_READY DG_P2 (attacker char, default 1) DG_TRIALS (400)
--      DG_SEED DG_DIFF (reaction-delay row, default 5) DG_NETDIR (C:/tmp/flybrain/out)
local function genv(k, d) local v = os.getenv(k); if v == nil or v == "" then return d end; return v end
local MAP = genv("DG_MAP", "C:/tmp/flybrain/rom4/mk2.map"):gsub("\\", "/")
local OUT = genv("DG_OUT", "C:/tmp/flybrain/dodge"):gsub("\\", "/")
local READY = genv("DG_READY", nil)
local P2CHAR = tonumber(genv("DG_P2", "1"))
local P1CHAR = 1
local TRIALS = tonumber(genv("DG_TRIALS", "400"))
local SEED = tonumber(genv("DG_SEED", "4242"))
local DIFF = tonumber(genv("DG_DIFF", "5"))
local NETDIR = genv("DG_NETDIR", "C:/tmp/flybrain/out"):gsub("\\", "/")
local STAGE = 5
math.randomseed(SEED + P2CHAR * 1000)

local CHAR_NAME = { [0] = "KungLao", "LiuKang", "Cage", "Baraka", "Kitana", "Mileena", "Shang", "Raiden",
  "SubZero", "Reptile", "Scorpion", "Jax" }
local logfh = io.open(OUT .. "/dodge.log", "w")
local function log(f, ...)
  local l = select("#", ...) > 0 and string.format(f, ...) or f
  print("[dodge] " .. l); logfh:write(l, "\n"); logfh:flush()
end
local csv = io.open(OUT .. "/trials.csv", "w")
csv:write("trial,p2,threat,dist,action,family,param,valid,hit,damage,fire_rel,act_rel,threat_seen_rel\n")

local sym = {}
for line in io.lines(MAP) do for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end end
for _, n in ipairs({ "gstate", "p1_state", "p2_state", "p1_char", "p2_char", "curback", "p1_obj", "p2_obj", "p1_proc",
  "p2_proc", "p1_bar", "p2_bar", "winner_status", "objlst", "worldtlx", "clk_ones", "clk_tens" }) do
  if not sym[n] then log("ERROR missing symbol %s", n) end
end

local O = { next = 0x000, oxvel = 0x040, oxpos = 0x090, oypos = 0x0b0 }
local ACT_STANCE = 0x0303
local REACT = ({ 6, 6, 5, 5, 4, 4, 4, 3, 3, 3 })[DIFF + 1] + 1   -- drone_react_delay + 1 frame of perception lag

-- ------------------------------------------------------------------ circuits
local function load_net(path)
  local NET = dofile(path)
  local C, S = NET.constants, NET.sensory
  local net = { NET = NET, C = C, S = S, N = #NET.names, fam = {}, sense = {} }
  for i, n in ipairs(NET.names) do
    local base, side = n:match("^(.-)_([LR])$")
    base = base or n
    if base == "DNp01" or base == "DNp02" or base == "DNp04" or base == "DNp11" then net.fam[#net.fam + 1] = i end
    if NET.group[i] == "sense" then net.sense[base .. "_" .. (side or "")] = i end
  end
  return net
end
local NETS = { real = load_net(NETDIR .. "/flynet.lua") }
for _, s in ipairs({ 7, 11, 13 }) do NETS["shuf" .. s] = load_net(string.format("%s/flynet_shuffled%d.lua", NETDIR, s)) end

local function circuit_reset(net)
  net.v, net.a, net.prev = {}, {}, {}
  for i = 1, net.N do net.v[i] = 0; net.a[i] = 0 end
end
-- one tick; objs = { {key, rel_x, half_w} }; returns the strongest escape-family activity
local function circuit_step(net, objs, gain)
  local C, S, NET = net.C, net.S, net.NET
  local drive = { LC4_L = 0, LC4_R = 0, LPLC2_L = 0, LPLC2_R = 0 }
  local now = {}
  for _, o in ipairs(objs) do
    local side = o[2] >= 0 and "R" or "L"
    local d = math.max(math.abs(o[2]) - S.body_gap, 4.0)
    local th = math.deg(2.0 * math.atan(o[3] / d))
    now[o[1]] = th
    local dth = th - (net.prev[o[1]] or th)
    local lc4 = math.floor(255 * math.min(math.max(dth, 0.0) / S.lc4_full, 1.0))
    local lp = 0
    if dth > 0.05 then lp = math.floor(255 * math.exp(-((th - S.lplc2_peak) / S.lplc2_sigma) ^ 2)) end
    drive["LC4_" .. side] = math.min(255, drive["LC4_" .. side] + lc4)
    drive["LPLC2_" .. side] = math.min(255, drive["LPLC2_" .. side] + lp)
  end
  net.prev = now
  local v, a = net.v, net.a
  for k, i in pairs(net.sense) do a[i] = drive[k] or 0 end
  local peak = 0
  for _ = 1, C.substeps do
    local inp = {}
    for i = 1, net.N do inp[i] = 0 end
    for _, e in ipairs(NET.edges) do
      local ap = a[e[2]]
      if ap ~= 0 then inp[e[1]] = inp[e[1]] + e[3] * ap end
    end
    for i = 1, net.N do
      if NET.group[i] ~= "sense" then
        -- SIGNED shift. Lua 5.4's >> is LOGICAL (-32 >> 5 = 576460752303423487), so an
        -- inhibited cell got ~5.7e17 and fired at 255 - inhibition became maximal excitation
        -- and one looming burst latched escape on for good. Floor division is the arithmetic
        -- shift flybrain_sim.py (Python) always used. Same fix as flybrain_play.lua ac851134.
        local vi = v[i] + inp[i] // (1 << gain) - v[i] // (1 << C.leak_shift)
        if vi > C.vmax then vi = C.vmax elseif vi < -C.vmax then vi = -C.vmax end
        v[i] = vi
        local ai = vi - C.theta
        if ai < 0 then ai = 0 elseif ai > 255 then ai = 255 end
        a[i] = ai
      end
    end
    for _, i in ipairs(net.fam) do if a[i] > peak then peak = a[i] end end
  end
  return peak >= C.fire
end

-- ------------------------------------------------------------------ attacks (player 2)
local function hold(n, ...) return { n = n, keys = { ... } } end
local function special(dirs, buttons)
  local m = {}
  for _, d in ipairs(dirs) do m[#m + 1] = hold(3, d); m[#m + 1] = hold(2) end
  m[#m + 1] = hold(4, table.unpack(buttons)); m[#m + 1] = hold(90)
  return m
end
local PROJ = {
  [1] = special({ "F", "F" }, { "HP" }),          -- Liu Kang fireball
  [8] = special({ "D", "F" }, { "LP" }),          -- Sub-Zero ice ball
  [7] = special({ "D", "F" }, { "LP" }),          -- Raiden lightning
  [10] = special({ "B", "B" }, { "LP" }),         -- Scorpion spear
  [6] = special({ "B", "B" }, { "HP" }),          -- Shang skull
  [11] = special({ "F", "D", "B" }, { "HK" }),    -- Jax ground wave
  [9] = special({ "F", "F" }, { "HP" }),          -- Reptile acid
  [2] = special({ "D", "F" }, { "LP" }),          -- Cage bolt
  [0] = special({ "B", "F" }, { "LP" }),          -- Kung Lao hat
  [3] = special({ "D", "B" }, { "HP" }),          -- Baraka spark
}
-- jump-in: angled jump, kick early or late in the arc
local function jumpin(kick_at) return { hold(4, "U", "F"), hold(kick_at - 4), hold(4, "HK"), hold(60) } end
-- Each threat carries the ONE action every controller uses against it, so only the
-- TIMING differs between controllers. Projectiles are tried with three actions,
-- because which of them can dodge at all is part of what the `fixed` controller
-- measures.
local THREATS = {}
if PROJ[P2CHAR] then
  for _, d in ipairs({ 150, 210, 270 }) do
    for _, act in ipairs({ "up", "over", "duck" }) do
      THREATS[#THREATS + 1] = { kind = "proj", dist = d, macro = PROJ[P2CHAR], action = act }
    end
  end
end
for _, d in ipairs({ 90, 120 }) do
  THREATS[#THREATS + 1] = { kind = "jumpin", dist = d, macro = jumpin(12), kick = 12, action = "back" }
end

-- ------------------------------------------------------------------ controllers
local FAMILIES = {
  { name = "none", params = { 0 } },
  { name = "real", params = { 4, 5, 6, 7 } },
  { name = "shuf7", params = { 4, 5, 6, 7 } },
  { name = "shuf11", params = { 4, 5, 6, 7 } },
  { name = "shuf13", params = { 4, 5, 6, 7 } },
  { name = "rule", params = { 60, 90, 120, 150, 180, 210 } },
  -- calibration: act at a FIXED frame after the attack starts, whatever happens.
  -- Maps each threat's dodge window, so the others can be judged against it.
  { name = "fixed", params = { 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60 } },
}

-- ------------------------------------------------------------------ runtime
local space, fields, screen, frame = nil, {}, nil, 0
local function r16(x) return space:read_u16(x) end
local function r32(x) return space:read_u32(x) end
local function w16(x, v) space:write_u16(x, v & 0xffff) end
local function s16(x) x = x & 0xffff; if x >= 0x8000 then return x - 0x10000 end; return x end
local function s32(x) x = x & 0xffffffff; if x >= 0x80000000 then return x - 0x100000000 end; return x end

local charsel, confirm, fight, away = 0, 0, 0, 0
local trial_n, valid_n = 0, 0
local T = nil                  -- current trial
local prev_p = nil             -- perception one frame late
local stats = {}

local function perceive()
  local p1, p2 = r32(sym.p1_obj), r32(sym.p2_obj)
  if p1 == 0 or p2 == 0 then return nil end
  local p = { x1 = s16(r16(p1 + O.oxpos)), x2 = s16(r16(p2 + O.oxpos)), y2 = s16(r16(p2 + O.oypos)),
              bar1 = r16(sym.p1_bar), proj = {},
              act1 = (function() local q = r32(sym.p1_proc); return q ~= 0 and r16(q + 0x1f0) or 0 end)(),
              act2 = (function() local q = r32(sym.p2_proc); return q ~= 0 and r16(q + 0x1f0) or 0 end)() }
  local o, n = r32(sym.objlst), 0
  while o ~= 0 and n < 200 do
    if o ~= p1 and o ~= p2 then
      local vx = s32(r32(o + O.oxvel)) / 65536.0
      if math.abs(vx) >= 1.5 then
        local x = s16(r16(o + O.oxpos))
        if (x - p.x1) * vx < 0 then p.proj[#p.proj + 1] = x end   -- coming at P1
      end
    end
    o = r32(o + O.next); n = n + 1
  end
  return p
end

-- DG_FAMILIES="none,fixed" limits the controllers (stage 1: calibration);
-- DG_SETUPS="proj/150/over,jumpin/90/back" limits the threats (stage 2: only the
-- setups calibration proved dodgeable).
do
  local want = genv("DG_FAMILIES", nil)
  if want then
    local keep = {}
    for _, f in ipairs(FAMILIES) do if ("," .. want .. ","):find("," .. f.name .. ",", 1, true) then keep[#keep + 1] = f end end
    FAMILIES = keep
  end
  local setups = genv("DG_SETUPS", nil)
  if setups then
    local keep = {}
    for _, t in ipairs(THREATS) do
      if ("," .. setups .. ","):find(string.format(",%s/%d/%s,", t.kind, t.dist, t.action), 1, true) then keep[#keep + 1] = t end
    end
    THREATS = keep
  end
end

local function new_trial()
  trial_n = trial_n + 1
  local fam = FAMILIES[math.random(#FAMILIES)]
  T = { n = trial_n, threat = THREATS[math.random(#THREATS)], family = fam.name,
        param = fam.params[math.random(#fam.params)], phase = "position", t = 0, still = 0 }
end

local function finish_trial(valid, hit, damage)
  local th = T.threat
  csv:write(string.format("%d,%s,%s,%d,%s,%s,%s,%d,%d,%d,%s,%s,%s\n", T.n, CHAR_NAME[P2CHAR] or P2CHAR, th.kind, th.dist,
    tostring(th.action or ""), T.family, tostring(T.param), valid and 1 or 0, hit and 1 or 0, damage, tostring(T.fire_rel or ""),
    tostring(T.act_rel or ""), tostring(T.seen_rel or "")))
  csv:flush()
  if valid then
    valid_n = valid_n + 1
    local k = th.kind .. "/" .. T.family
    stats[k] = stats[k] or { n = 0, dodged = 0 }
    stats[k].n = stats[k].n + 1
    if not hit then stats[k].dodged = stats[k].dodged + 1 end
  end
  if valid_n % 25 == 0 and valid then
    local keys = {}
    for k in pairs(stats) do keys[#keys + 1] = k end
    table.sort(keys)
    local s = {}
    for _, k in ipairs(keys) do s[#s + 1] = string.format("%s %d/%d", k, stats[k].dodged, stats[k].n) end
    log("valid %d / trials %d :: %s", valid_n, trial_n, table.concat(s, "  "))
  end
  T = nil
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    screen = manager.machine.screens[":screen"]
    for _, port in pairs(manager.machine.ioport.ports) do for _, f in pairs(port.fields) do fields[f.name] = f end end
    log("dodge rig: P1 %s defends, P2 %s attacks, threats %d, reaction %d frames, trials %d",
      CHAR_NAME[P1CHAR], CHAR_NAME[P2CHAR] or P2CHAR, #THREATS, REACT, TRIALS)
  end
  if READY and frame == 120 then local r = io.open(READY, "w"); r:write("ok"); r:close() end

  local press = {}
  local gs = r16(sym.gstate)
  if frame % 1000 == 0 and fight > 0 then
    local q1, q2 = r32(sym.p1_proc), r32(sym.p2_proc)
    local o1, o2 = r32(sym.p1_obj), r32(sym.p2_obj)
    log("status f=%d gs=%d trial=%s phase=%s t=%s still=%s placed=%s act1=%04x act2=%04x x1=%d x2=%d bars=%d/%d ws=%d",
      frame, gs, T and T.n or "-", T and T.phase or "-", T and T.t or "-", T and T.still or "-", T and tostring(T.placed) or "-",
      q1 ~= 0 and r16(q1 + 0x1f0) or 0, q2 ~= 0 and r16(q2 + 0x1f0) or 0,
      o1 ~= 0 and s16(r16(o1 + O.oxpos)) or 0, o2 ~= 0 and s16(r16(o2 + O.oxpos)) or 0,
      r16(sym.p1_bar), r16(sym.p2_bar), r16(sym.winner_status))
  end
  if gs == 4 and charsel == 0 then charsel = frame end
  if fight > 0 and gs ~= 2 and gs ~= 5 and gs ~= 6 and gs ~= 7 then
    away = (away or 0) + 1
    if away > 300 then
      log("left the fight (gstate %d) - dropping trial %s and starting a new game", gs, T and T.n or "-")
      if T then finish_trial(false, false, 0) end
      charsel, confirm, fight, away, prev_p = 0, 0, 0, 0, nil
    end
  else
    away = 0
  end
  if gs == 2 and fight == 0 then fight = frame; log("fight at frame %d", frame) end

  if charsel == 0 then
    press["UI Select"] = frame >= 5 and frame < 35
    press["Coin 1"] = frame >= 200 and (frame % 80) < 20
    press["Coin 2"] = frame >= 200 and (frame % 80) < 20
    press["1 Player Start"] = frame >= 1000 and (frame % 120) < 20
    press["2 Players Start"] = frame >= 1000 and (frame % 120) >= 60 and (frame % 120) < 80
    if gs == 2 and fight == 0 then press["1 Player Start"] = false; press["2 Players Start"] = false end
  elseif fight == 0 then
    w16(sym.p1_state, 1); w16(sym.p2_state, 1)
    w16(sym.p1_char, P1CHAR); w16(sym.p2_char, P2CHAR); w16(sym.curback, STAGE)
    if confirm == 0 and frame - charsel > 90 then confirm = frame end
    local c = confirm > 0 and frame >= confirm and frame < confirm + 45
    press["P1 High Punch"] = c; press["P2 High Punch"] = c
    press["2 Players Start"] = (frame - charsel) % 60 < 10
  end

  if fight > 0 and gs == 2 then
    -- keep the round alive forever: nobody wins, the clock never runs out
    w16(sym.winner_status, 0); w16(sym.clk_tens, 9); w16(sym.clk_ones, 9)
    local p_now = perceive()
    local p = prev_p            -- ONE FRAME LATE
    prev_p = p_now
    if p and p_now then
      if not T and frame - fight > 120 then new_trial() end
      if T then
        T.t = T.t + 1
        local rel = p.x2 - p.x1
        local dist = math.abs(rel)
        local p1_fwd = rel >= 0 and "P1 Right" or "P1 Left"
        local p1_back = rel >= 0 and "P1 Left" or "P1 Right"
        local p2_fwd = rel >= 0 and "P2 Left" or "P2 Right"
        local p2_back = rel >= 0 and "P2 Right" or "P2 Left"
        local wx = s16(r32(sym.worldtlx) >> 16)
        local sx1 = p.x1 - wx

        if T.phase == "position" then
          w16(sym.p1_bar, 0xa1); w16(sym.p2_bar, 0xa1)
          -- both standing still: PLACE them at the trial distance, centred on screen
          -- (walking there took minutes a trial). oxval is the 16.16 position; its
          -- integer half is oxpos, so writing oxval moves both.
          if p.act1 == ACT_STANCE and p.act2 == ACT_STANCE then T.still = T.still + 1 else T.still = 0 end
          if T.still == 10 and not T.placed then
            local centre = wx + 200
            local left = p.x1 <= p.x2
            local x1 = centre + (left and -1 or 1) * (T.threat.dist // 2)
            local x2 = centre + (left and 1 or -1) * (T.threat.dist - T.threat.dist // 2)
            space:write_u32(r32(sym.p1_obj) + 0x080, (x1 & 0xffff) << 16)
            space:write_u32(r32(sym.p2_obj) + 0x080, (x2 & 0xffff) << 16)
            T.placed, T.still = true, 0
          end
          if T.placed and T.still >= 12 and math.abs(dist - T.threat.dist) > 12 then
            T.placed, T.still = false, 0          -- a push moved them: place again
          end
          if T.placed and T.still >= 12 then
            T.phase, T.t, T.m, T.ms, T.ml = "attack", 0, T.threat.macro, 1, T.threat.macro[1].n
            T.bar0 = p_now.bar1
            if NETS[T.family] then circuit_reset(NETS[T.family]) end
          elseif T.t > 600 then
            finish_trial(false, false, 0)          -- could not get into position
          end
        end

        if T and T.phase == "attack" then
          -- player 2's macro
          if T.m then
            local st = T.m[T.ms]
            for _, k in ipairs(st.keys) do
              if k == "F" then press[p2_fwd] = true elseif k == "B" then press[p2_back] = true
              elseif k == "U" then press["P2 Up"] = true elseif k == "D" then press["P2 Down"] = true
              elseif k == "HP" then press["P2 High Punch"] = true elseif k == "LP" then press["P2 Low Punch"] = true
              elseif k == "HK" then press["P2 High Kick"] = true elseif k == "LK" then press["P2 Low Kick"] = true end
            end
            T.ml = T.ml - 1
            if T.ml <= 0 then T.ms = T.ms + 1; if T.ms > #T.m then T.m = nil else T.ml = T.m[T.ms].n end end
          end
          -- did the threat come out?
          if not T.seen_rel then
            if T.threat.kind == "proj" and #p.proj > 0 then T.seen_rel = T.t end
            if T.threat.kind == "jumpin" and (T.y2ground or p.y2) - p.y2 > 20 then T.seen_rel = T.t end
          end
          T.y2ground = T.y2ground and math.max(T.y2ground, p.y2) or p.y2
          -- the controller decides when to move
          if not T.fire_rel and T.family ~= "none" then
            local fire = false
            if T.family == "fixed" then
              -- no perception at all; the jump starts exactly at `param` (REACT is not added)
              if T.t >= T.param then T.fire_rel = T.t; T.act_at = T.t end
            elseif T.family == "rule" then
              local closing = T.lastdist and (T.lastdist - dist) or 0
              local nearest = math.huge
              for _, x in ipairs(p.proj) do nearest = math.min(nearest, math.abs(x - p.x1)) end
              if closing >= 2 then nearest = math.min(nearest, dist) end
              fire = nearest <= T.param
            else
              local objs = { { "opp", rel, NETS[T.family].S.fighter_half_w } }
              for k, x in ipairs(p.proj) do objs[#objs + 1] = { "p" .. k, x - p.x1, NETS[T.family].S.proj_half_w } end
              fire = circuit_step(NETS[T.family], objs, T.param)
            end
            if fire and not T.fire_rel then T.fire_rel = T.t; T.act_at = T.t + REACT end
          elseif T.family ~= "none" and T.family ~= "rule" then
            -- keep stepping so the circuit's state stays honest after firing
          end
          T.lastdist = dist
          -- player 1's one fixed action, once
          if T.act_at and T.t >= T.act_at then
            local a = T.threat.action
            if a == "duck" then
              if T.t < T.act_at + 40 then press["P1 Down"] = true end   -- hold the crouch through the pass
            elseif T.t < T.act_at + 4 then
              press["P1 Up"] = true
              if a == "back" then press[p1_back] = true elseif a == "over" then press[p1_fwd] = true end
            end
            T.act_rel = T.act_rel or T.t
          end
          -- outcome
          -- refill every frame: damage is the sum of per-frame drops, and nobody can
          -- ever be KO'd (a KO ended the match and dropped the rig into attract mode)
          local drop1 = 0xa1 - p_now.bar1
          if drop1 > 0 then T.dmg = (T.dmg or 0) + drop1 end
          w16(sym.p1_bar, 0xa1); w16(sym.p2_bar, 0xa1)
          local damage = T.dmg or 0
          local ended = T.t >= 110 or (damage > 0 and T.t > (T.dmg_at or T.t) + 20)
          if damage > 0 and not T.dmg_at then T.dmg_at = T.t end
          if T.threat.kind == "proj" and T.seen_rel and #p.proj == 0 and T.t > T.seen_rel + 40 then ended = true end
          if ended then
            finish_trial(T.seen_rel ~= nil or damage > 0, damage > 0, damage)
            w16(sym.p1_bar, 0xa1); w16(sym.p2_bar, 0xa1)
          end
        end
      end
    end
    if valid_n >= TRIALS then
      log("DONE %d valid trials of %d", valid_n, trial_n); csv:close(); manager.machine:exit(); return
    end
  end

  for _, n in ipairs({ "UI Select", "Coin 1", "Coin 2", "1 Player Start", "2 Players Start", "P1 Up", "P1 Left", "P1 Right",
    "P1 High Punch", "P1 Down", "P2 Up", "P2 Down", "P2 Left", "P2 Right", "P2 High Punch", "P2 Low Punch", "P2 High Kick",
    "P2 Low Kick" }) do
    if fields[n] then fields[n]:set_value(press[n] and 1 or 0) end
  end
  if frame > 55 * 60 * 180 then log("backstop"); csv:close(); manager.machine:exit() end
end)
