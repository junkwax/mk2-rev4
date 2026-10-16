-- flypong.lua - TWO FRUIT FLIES PLAY ED BOON'S PONG, first to 99, for ever.
--
-- Needs the Pong-only ROM (pong_only .set 1, MKAMODE.ASM) - the game boots straight into
-- PONG.ASM's play_pong and loops it. Each paddle is one fly. Run it with
-- tools/run_flypong.ps1.
--
-- EACH FLY IS THE SAME CIRCUIT THE FIGHTING FLY USES (FB_NET, flynet_oa.lua by default:
-- 768 cells out of the fly's connectome), with its own membrane potentials, and it SEES the
-- court the way it sees a fighter:
--   * the ball coming at it LOOMS - LC4 answers to how fast its angular size grows, LPLC2/
--     LPLC1 to how big it is - and LC11 tracks it as a small moving object. The fly faces
--     across the court, so "above my paddle" is its LEFT eye and "below" its RIGHT eye;
--   * the ball sliding up or down the court is wide-field FLOW (HS/H2 to the side it is
--     sliding toward, VS for any vertical slide);
--   * the paddle's blip when anyone hits the ball reaches the ear (JO-B/D).
-- The circuit's two steering descending neurons, DNa01/DNa02 (left/right turning), LEAN it
-- toward up or down. The wiring argues; it does not command.
--
-- WHAT LEARNS is a table, exactly the fighting fly's shape: a situation key (is the ball
-- coming or going, where it is against my paddle, which way it drifts, how far) and three
-- options (UP, HOLD, DOWN). It picks in proportion to weight^SHARP. Every choice goes into a
-- trace; when the ball comes off MY paddle the recent choices are rewarded, when the other
-- fly scores they are punished, each by how recently it was made.
--
-- FAIR BY CONSTRUCTION: both flies see the court PONG_REACT frames late (a human's visual
-- reaction), decide every PONG_THINK frames, and move the paddle only through the joystick,
-- at the ROM's own 3 px a tick. They start blank and learn by playing each other.
--
-- Env: FP_MAP (mk2.map of the Pong ROM)  FB_NET  FP_OUT (dir)  FP_DASH (json, "0" = off)
--      FP_WEIGHTS_IN / FP_WEIGHTS_OUT  FP_LEARN (1)  FP_SEED  FP_MAXMIN
--      FP_REACT (8)  FP_THINK (3)  FP_SHARP (2)  FP_LR (0.25)  FP_LEAN (0.35)
local function envp(k, d) local v = os.getenv(k); if v == nil or v == "" then return d end return v end
local OUT = envp("FP_OUT", "C:/tmp/flybrain/pong"):gsub("\\", "/")
local MAP = envp("FP_MAP", "C:/tmp/flybrain/pong_rom/mk2.map")
local NETF = envp("FB_NET", "C:/tmp/flybrain/out/flynet_oa.lua")
local DASH = envp("FP_DASH", OUT .. "/pong.json"); if DASH == "0" then DASH = nil end
local W_IN, W_OUT = envp("FP_WEIGHTS_IN", nil), envp("FP_WEIGHTS_OUT", OUT .. "/brains.lua")
local LEARN = envp("FP_LEARN", "1") ~= "0"
local REACT = tonumber(envp("FP_REACT", "8"))
local THINK = tonumber(envp("FP_THINK", "3"))
local SHARP = tonumber(envp("FP_SHARP", "2"))
local LR = tonumber(envp("FP_LR", "0.25"))
local LEAN = tonumber(envp("FP_LEAN", "0.35"))
-- FP_AIM=1: while the ball is coming, the fly judges WHERE IT WILL ARRIVE at its paddle line,
-- not where it is now - the read a player makes. Worked out from what it already sees (the
-- late picture: position and velocity), wall bounces folded in, so it is the same delayed
-- information both flies always had, only put together. 0 = the original "where is it now".
-- ON BY DEFAULT since 2026-10-05: an hour from blank on two seeds each, aim reached 83-87%
-- returns with rallies averaging 5-7 hits (best 38); "now" 76-79% and 3-4 (best 32).
local AIM = envp("FP_AIM", "1") == "1"
local BALL_TOP, BALL_BOT = 9, 241        -- move_ball (PONG.ASM) reflects the ball's TOP here
local CLAMP = envp("FP_CLAMP", "0") == "1"   -- the old per-option weight clamp (see reward)
local TRACE_T = 90                       -- frames: how far back a reward reaches (e-folding)
local MAXMIN = tonumber(envp("FP_MAXMIN", "0"))
math.randomseed(tonumber(envp("FP_SEED", tostring(os.time()))))

local space = manager.machine.devices[":maincpu"].spaces["program"]
local LOG = io.open(OUT .. "/pong.log", "a")
local function log(fmt, ...)
  local s = string.format(fmt, ...)
  LOG:write(os.date("%H:%M:%S "), s, "\n"); LOG:flush(); print("[flypong] " .. s)
end

-- RAM. Only pong_win is exported; the rest of PONG.ASM's .bss is declared straight after it
-- in a fixed order, and .bss is packed at BIT granularity, so nothing here is word-aligned
-- (pong_win itself sits 8 bits into a word). Every read goes through rbits.
local PW
do
  local mh = assert(io.open(MAP), "no map " .. MAP)
  for line in mh:lines() do
    local a = line:match("(%x+)%s+pong_win%s*$") or line:match("(%x+)%s+pong_win%s")
    if a then PW = tonumber(a, 16); break end
  end
  mh:close()
end
assert(PW, "pong_win is not in " .. MAP .. " - is this the Pong-only ROM's map?")
local A = { s1 = PW - 32, s2 = PW - 16, win = PW, ball = PW + 16, bxv = PW + 48, byv = PW + 80,
            play1 = PW + 112, play2 = PW + 144 }
local function rbits(a, n)
  local base = a & ~15; local sh = a - base; local v = 0
  for i = 0, 3 do v = v | (space:read_u16(base + 16 * i) << (16 * i)) end
  return (v >> sh) & ((1 << n) - 1)
end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end
local function objok(o) return o >= 0x01000000 and o < 0x01200000 end
local OXPOS, OYPOS = 0x90, 0xb0
local PAD_H, BALL_H = 39, 6
local P1X, P2X = 21, 373

-- THE CIRCUIT ------------------------------------------------------------------------
local NET = dofile(NETF)
local N = #NET.names
local C = NET.constants
local GAIN = tonumber(envp("FB_GAIN", "5"))
local gdiv, ldiv = 1 << GAIN, 1 << C.leak_shift
local SENSE, MOTOR = {}, {}               -- base name -> { {i, side}, ... }
local clamp = {}
for i, n in ipairs(NET.names) do
  local base, side = n:match("^(.-)_([LR])$"); base = base or n
  local g = NET.group[i]
  if g == "sense" then SENSE[base] = SENSE[base] or {}; table.insert(SENSE[base], { i = i, side = side }) end
  if g == "motor" then MOTOR[base] = MOTOR[base] or {}; table.insert(MOTOR[base], { i = i, side = side }) end
  clamp[i] = (g == "sense") or (g and g:match("^body_") ~= nil)
end
local function grp(pred)
  local out = {}
  for base, list in pairs(SENSE) do if pred(base) then for _, e in ipairs(list) do out[#out + 1] = e end end end
  return out
end
local G = {
  loom = grp(function(b) return b == "LC4" or b == "LC6" end),
  size = grp(function(b) return b == "LPLC2" or b == "LPLC1" end),
  small = grp(function(b) return b == "LC11" or b == "LC10a" end),
  flowh = grp(function(b) return b:match("^HS") or b == "H2" end),
  flowv = grp(function(b) return b == "VS" end),
  ear = grp(function(b) return b:match("^JO%-[BD]") end),
}
local STEER = { L = {}, R = {} }          -- DNa01/DNa02: the fly's turning neurons
for _, b in ipairs({ "DNa01", "DNa02" }) do
  for _, e in ipairs(MOTOR[b] or {}) do if e.side then table.insert(STEER[e.side], e.i) end end
end

local function new_fly(name, side)
  local f = { name = name, side = side, v = {}, a = {}, w = {}, trace = {},
              hits = 0, misses = 0, recent = {}, act = "HOLD", key = "", prev_th = nil,
              lean = 0, sense = {}, firing = 0, points = 0, matches = 0, decisions = 0 }
  for i = 1, N do f.v[i] = 0; f.a[i] = 0 end
  return f
end
local FLY = { new_fly("FROSTY", 1), new_fly("TOASTY", 2) }   -- left paddle, right paddle

local function drive_set(f, list, val, side_pref, contra)
  for _, e in ipairs(list) do
    local v = val
    if side_pref and e.side and e.side ~= side_pref then v = contra or (val // 3) end
    f.a[e.i] = math.max(f.a[e.i], math.floor(math.max(0, math.min(255, v))))
  end
end

-- one circuit tick for one fly. p: what it perceives (already PONG_REACT frames late)
local function circuit(f, p, blip)
  for i = 1, N do if clamp[i] then f.a[i] = 0 end end
  local side = p.rel < 0 and "L" or "R"            -- above my paddle = left eye
  local d = math.max(p.dist, 4)
  local th = math.deg(2 * math.atan((BALL_H * 2) / d))
  local dth = th - (f.prev_th or th); f.prev_th = th
  local loom = p.coming and math.floor(255 * math.min(math.max(dth, 0) / 1.5, 1)) or 0
  local size = math.floor(255 * math.min(th / 30, 1))
  local cross = math.max(0, 1 - math.abs(p.rel) / 60) * 0.5   -- near level: both eyes share it
  local ipsi = math.floor(loom * (1 - cross)); local con = loom - ipsi
  drive_set(f, G.loom, ipsi, side, con)
  local si = math.floor(size * (1 - cross)); drive_set(f, G.size, si, side, size - si)
  drive_set(f, G.small, 200, side, 60)
  local fl = math.floor(math.min(255, math.abs(p.vy) * 60))
  drive_set(f, G.flowh, fl, p.vy < 0 and "L" or "R")
  drive_set(f, G.flowv, fl)
  if blip > 0 then drive_set(f, G.ear, blip) end
  f.sense = { loom = loom, size = size, flow = fl, ear = blip, eye = side }
  local a, v = f.a, f.v
  local peak = f.peak or {}; f.peak = peak
  for i = 1, N do peak[i] = a[i] end
  for _ = 1, C.substeps do
    local inp = {}
    for i = 1, N do inp[i] = 0 end
    for _, e in ipairs(NET.edges) do
      local ap = a[e[2]]
      if ap ~= 0 then inp[e[1]] = inp[e[1]] + e[3] * ap end
    end
    for i = 1, N do
      if not clamp[i] then
        local vi = v[i] + inp[i] // gdiv - v[i] // ldiv
        if vi > C.vmax then vi = C.vmax elseif vi < -C.vmax then vi = -C.vmax end
        v[i] = vi
        local ai = vi - C.theta
        if ai < 0 then ai = 0 elseif ai > 255 then ai = 255 end
        a[i] = ai
        if ai > peak[i] then peak[i] = ai end
      end
    end
  end
  local n = 0
  for i = 1, N do if a[i] > 6 then n = n + 1 end end
  f.firing = n
  local l, r = 0, 0
  for _, i in ipairs(STEER.L) do l = l + a[i] end
  for _, i in ipairs(STEER.R) do r = r + a[i] end
  local tot = l + r
  f.lean = tot > 0 and (l - r) / tot or 0          -- +1 = turn left = UP, -1 = DOWN
  f.steer = { l = l, r = r }
end

-- THE LEARNER ------------------------------------------------------------------------
local OPTS = { "UP", "HOLD", "DOWN" }
local function bucket(rel)
  if rel < -40 then return "A" elseif rel < -20 then return "B" elseif rel < -8 then return "C"
  elseif rel <= 8 then return "D" elseif rel <= 20 then return "E" elseif rel <= 40 then return "F" end
  return "G"
end
-- where the ball's centre will be, against my paddle's centre, when it reaches my line
local function arrival(p)
  local vx = math.abs(p.vx)
  if vx < 0.5 then return p.rel end
  local y = p.by + p.vy * (p.dist / vx)
  local span = BALL_BOT - BALL_TOP
  local m = (y - BALL_TOP) % (2 * span)            -- unfold the bounces off top and bottom
  if m > span then m = 2 * span - m end
  return (BALL_TOP + m + BALL_H // 2) - p.py
end
local function situation(p)
  local r = (AIM and p.coming) and arrival(p) or p.rel
  p.aim = r
  return (p.coming and "c" or "g") .. bucket(r) .. (p.vy < -0.3 and "u" or p.vy > 0.3 and "d" or "s")
         .. (p.dist < 100 and "n" or p.dist < 220 and "m" or "f")
end
local function weights(f, key)
  local w = f.w[key]
  if not w then w = { UP = 1, HOLD = 1, DOWN = 1 }; f.w[key] = w end
  return w
end
local function choose(f, key, frame)
  local w = weights(f, key)
  local lean = { UP = 1 + LEAN * math.max(f.lean, 0), DOWN = 1 + LEAN * math.max(-f.lean, 0), HOLD = 1 }
  local s, pr = 0, {}
  for _, o in ipairs(OPTS) do pr[o] = (w[o] ^ SHARP) * lean[o]; s = s + pr[o] end
  local r, pick = math.random() * s, "HOLD"
  for _, o in ipairs(OPTS) do r = r - pr[o]; if r <= 0 then pick = o; break end end
  for _, o in ipairs(OPTS) do pr[o] = pr[o] / s end
  f.probs = pr
  f.act, f.key = pick, key
  f.decisions = f.decisions + 1
  local t = f.trace; t[#t + 1] = { key, pick, frame }
  if #t > 120 then table.remove(t, 1) end
end
-- r: +1 a hit. A MISS carries where the ball went past: miss < 0 = it passed ABOVE the paddle,
-- > 0 = below. That is what a player sees when he misses, so it is what the fly learns from:
-- moving toward the side it went past was right, away from it was wrong, standing still was
-- a little wrong. Without it a miss punished every choice in the trace alike, and the fly that
-- was losing punished its good moves as hard as its bad ones and got WORSE (measured: hit
-- rate 38% -> 6% over three matches against a fly that had pulled ahead).
local function reward(f, r, frame, miss)
  if not LEARN then f.trace = {}; return end
  local toward = miss and (miss < 0 and "UP" or "DOWN")
  for _, e in ipairs(f.trace) do
    local age = frame - e[3]
    local el = math.exp(-age / TRACE_T)
    if el > 0.02 then
      local w = weights(f, e[1])
      local rr = r
      if miss then rr = (e[2] == toward) and 1 or (e[2] == "HOLD") and -0.5 or -1 end
      w[e[2]] = math.max(0.02, w[e[2]] * math.exp(LR * rr * el))
      -- THE CEILING SCALES THE WHOLE SITUATION, NOT ONE OPTION. A per-option clamp at 50
      -- let every option that kept being rewarded pile up against it, and once two sat at
      -- 50 the fly could no longer tell them apart (seen live: UP 50 / DOWN 50 for a ball
      -- far above). Dividing all three by the same factor keeps what was learned - the
      -- ratios - and still bounds the numbers. FP_CLAMP=1 is the old per-option clamp.
      if CLAMP then
        w[e[2]] = math.min(50, w[e[2]])
      else
        local m = math.max(w.UP, w.HOLD, w.DOWN)
        if m > 50 then
          local k = 50 / m
          w.UP, w.HOLD, w.DOWN = math.max(0.02, w.UP * k), math.max(0.02, w.HOLD * k), math.max(0.02, w.DOWN * k)
        end
      end
    end
  end
  f.trace = {}
end
local function record(f, hit)
  local rc = f.recent; rc[#rc + 1] = hit and 1 or 0
  if #rc > 50 then table.remove(rc, 1) end
end
local function rate(f)
  local s = 0; for _, x in ipairs(f.recent) do s = s + x end
  return #f.recent > 0 and s / #f.recent or 0
end

-- SAVE / LOAD the two tables ---------------------------------------------------------
-- EVENTS: the moments the stream calls out - a record rally, rally milestones, match point,
-- a match won. Numbered so the page shows each one once however often it polls.
local EV = { n = 0, list = {} }
local function event(kind, text, who)
  EV.n = EV.n + 1
  EV.list[#EV.list + 1] = { id = EV.n, kind = kind, text = text, who = who or 0 }
  if #EV.list > 12 then table.remove(EV.list, 1) end
end
local LOADED = W_IN ~= nil
local G2 = { match = 1, points = 0, rally = 0, best = 0, rallies = {}, curve = {}, wins = { 0, 0 },
             started = os.time(), lastscore = { 0, 0 }, pointframe = 0 }
local function save()
  if not W_OUT then return end
  local fh = io.open(W_OUT .. ".tmp", "w"); if not fh then return end
  fh:write("return {\n")
  for k, f in ipairs(FLY) do
    fh:write(string.format("  [%d] = { hits = %d, misses = %d, w = {\n", k, f.hits, f.misses))
    local keys = {}; for key in pairs(f.w) do keys[#keys + 1] = key end; table.sort(keys)
    for _, key in ipairs(keys) do
      local w = f.w[key]
      fh:write(string.format("    [%q] = { UP = %.4f, HOLD = %.4f, DOWN = %.4f },\n", key, w.UP, w.HOLD, w.DOWN))
    end
    fh:write("  } },\n")
  end
  fh:write(string.format("  match = %d, wins = { %d, %d }, points = %d, best = %d,\n}\n",
    G2.match, G2.wins[1], G2.wins[2], G2.points, G2.best))
  fh:close(); os.remove(W_OUT); os.rename(W_OUT .. ".tmp", W_OUT)
end
if W_IN then
  local ok, t = pcall(dofile, W_IN)
  if ok and t then
    for k = 1, 2 do if t[k] then FLY[k].w = t[k].w or {}; FLY[k].hits = t[k].hits or 0; FLY[k].misses = t[k].misses or 0 end end
    G2.match = t.match or 1; G2.wins = t.wins or { 0, 0 }; G2.points = t.points or 0; G2.best = t.best or 0
    log("brains loaded from %s (match %d)", W_IN, G2.match)
  else log("could not load %s - starting blank", tostring(W_IN)) end
end

-- THE DASHBOARD FILE -----------------------------------------------------------------
local function jnum(x) return string.format("%.3f", x or 0) end
local function dash_net(path)
  local fh = io.open(path, "w"); if not fh then return end
  local p = { '{"nodes":[' }
  for i = 1, N do p[#p + 1] = string.format('%s[%q,%q]', i > 1 and "," or "", NET.names[i], NET.group[i] or "inter") end
  p[#p + 1] = '],"edges":['
  for k, e in ipairs(NET.edges) do p[#p + 1] = string.format('%s[%d,%d,%d]', k > 1 and "," or "", e[1], e[2], e[3] or 0) end
  p[#p + 1] = "]}"
  fh:write(table.concat(p)); fh:close()
end
-- the loudest cells of one fly: [index, level] pairs for the brain view, names for its labels
local function fire_json(f)
  local top, pk = {}, f.peak or {}
  for i = 1, N do if (pk[i] or 0) > 6 then top[#top + 1] = i end end
  table.sort(top, function(x, y) return pk[x] > pk[y] end)
  local fr, nm = {}, {}
  for k = 1, math.min(#top, 200) do fr[k] = string.format("[%d,%d]", top[k], pk[top[k]]) end
  for k = 1, math.min(#top, 6) do nm[k] = string.format("%q", NET.names[top[k]]) end
  return '"fire":[' .. table.concat(fr, ",") .. '],"top":[' .. table.concat(nm, ",") .. ']'
end
local NET_DONE = false
local function dash(st)
  if not DASH then return end
  if not NET_DONE then NET_DONE = true; pcall(dash_net, (DASH:gsub("%.json$", "")) .. ".net.json") end
  local parts = { "{" }
  local function add(s) parts[#parts + 1] = s end
  add(string.format('"frame":%d,"loaded":%s,', st.frame, LOADED and "true" or "false"))
  add(string.format('"t":%d,"match":%d,"wins":[%d,%d],"score":[%d,%d],"target":%d,"rally":%d,"best":%d,"points":%d,',
    os.time(), G2.match, G2.wins[1], G2.wins[2], st.s1, st.s2, st.win, G2.rally, G2.best, G2.points))
  add(string.format('"ball":[%d,%d,%s,%s],"pad":[%d,%d],"react":%d,"think":%d,"sharp":%s,"learn":%s,',
    st.bx, st.by, jnum(st.vx), jnum(st.vy), st.p1y, st.p2y, REACT, THINK, jnum(SHARP), LEARN and "true" or "false"))
  local rl = {}; for i = math.max(1, #G2.rallies - 59), #G2.rallies do rl[#rl + 1] = G2.rallies[i] end
  add('"rallies":[' .. table.concat(rl, ",") .. '],')
  local ev = {}
  for _, e in ipairs(EV.list) do ev[#ev + 1] = string.format('{"id":%d,"kind":%q,"text":%q,"who":%d}', e.id, e.kind, e.text, e.who) end
  add('"events":[' .. table.concat(ev, ",") .. '],')
  local cv = {}
  for i = math.max(1, #G2.curve - 199), #G2.curve do
    local c = G2.curve[i]; cv[#cv + 1] = string.format("[%s,%s,%s]", jnum(c[1]), jnum(c[2]), jnum(c[3]))
  end
  add('"curve":[' .. table.concat(cv, ",") .. '],"flies":[')
  for k, f in ipairs(FLY) do
    local w = weights(f, f.key ~= "" and f.key or "gDsf")
    local pr = f.probs or { UP = 1 / 3, HOLD = 1 / 3, DOWN = 1 / 3 }
    local nk = 0; for _ in pairs(f.w) do nk = nk + 1 end
    local se = f.sense or {}
    add(string.format('%s{"name":%q,"act":%q,"key":%q,"w":[%s,%s,%s],"p":[%s,%s,%s],"lean":%s,"steer":[%d,%d],'
      .. '"firing":%d,"cells":%d,"hits":%d,"misses":%d,"rate":%s,"known":%d,"decisions":%d,'
      .. '"sense":{"loom":%d,"size":%d,"flow":%d,"ear":%d,"eye":%q},"rel":%d,"coming":%s,"lastmiss":%d,"pb":[%d,%d],%s}',
      k > 1 and "," or "", f.name, f.act, f.key, jnum(w.UP), jnum(w.HOLD), jnum(w.DOWN),
      jnum(pr.UP), jnum(pr.HOLD), jnum(pr.DOWN), jnum(f.lean), f.steer and f.steer.l or 0, f.steer and f.steer.r or 0,
      f.firing, N, f.hits, f.misses, jnum(rate(f)), nk, f.decisions,
      se.loom or 0, se.size or 0, se.flow or 0, se.ear or 0, se.eye or "L", math.floor(f.prel or 0),
      f.coming and "true" or "false", f.lastmiss or 0, f.pbx or 0, f.pby or 0, fire_json(f)))
  end
  add("]}")
  local fh = io.open(DASH .. ".tmp", "w")
  if fh then fh:write(table.concat(parts)); fh:close(); os.remove(DASH); os.rename(DASH .. ".tmp", DASH) end
end

-- THE LOOP ---------------------------------------------------------------------------
local fields = {}
for _, port in pairs(manager.machine.ioport.ports) do
  for _, fl in pairs(port.fields) do fields[fl.name] = fl end
end
local KEYS = { { UP = "P1 Up", DOWN = "P1 Down" }, { UP = "P2 Up", DOWN = "P2 Down" } }
for k = 1, 2 do for _, n in pairs(KEYS[k]) do assert(fields[n], "no input field " .. n) end end

local hist, frame, prev_vx, blip = {}, 0, 0, 0
local last_live = 0
log("start: net %s (%d cells, %d edges), react %d, think %d, sharp %s, lr %s, lean %s, learn %s, aim %s, clamp %s",
  NETF, N, #NET.edges, REACT, THINK, tostring(SHARP), tostring(LR), tostring(LEAN), tostring(LEARN), tostring(AIM), tostring(CLAMP))

FLYPONG = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local b, p1, p2 = rbits(A.ball, 32), rbits(A.play1, 32), rbits(A.play2, 32)
  local st = { s1 = rbits(A.s1, 16), s2 = rbits(A.s2, 16), win = rbits(A.win, 16), bx = 0, by = 0, vx = 0, vy = 0,
               p1y = 0, p2y = 0 }
  local live = objok(b) and objok(p1) and objok(p2)
  if live then
    st.bx, st.by = space:read_i16(b + OXPOS), space:read_i16(b + OYPOS)
    st.vx, st.vy = s32(rbits(A.bxv, 32)) / 65536, s32(rbits(A.byv, 32)) / 65536
    st.p1y, st.p2y = space:read_i16(p1 + OYPOS), space:read_i16(p2 + OYPOS)
  end
  hist[frame] = st; hist[frame - REACT - 2] = nil

  -- SCORING. A point is a miss for the fly it went past, and the end of a rally.
  local ls = G2.lastscore
  if st.s1 < ls[1] or st.s2 < ls[2] then
    -- scores went back to 0: a new match started (play_pong clears them)
    G2.lastscore = { st.s1, st.s2 }; ls = G2.lastscore
  end
  for k = 1, 2 do
    local now = k == 1 and st.s1 or st.s2
    if now > ls[k] then
      local loser = FLY[3 - k]
      loser.misses = loser.misses + 1; record(loser, false); reward(loser, -1, frame, loser.cross or 0)
      loser.lastmiss = math.floor(loser.cross or 0)
      FLY[k].trace = {}
      FLY[k].points = FLY[k].points + 1
      G2.points = G2.points + 1
      G2.rallies[#G2.rallies + 1] = G2.rally
      if #G2.rallies > 500 then table.remove(G2.rallies, 1) end
      if G2.rally > G2.best then
        G2.best = G2.rally; log("longest rally so far: %d hits", G2.best)
        if G2.best >= 5 then event("record", string.format("NEW RECORD RALLY - %d HITS", G2.best)) end
      end
      G2.curve[#G2.curve + 1] = { rate(FLY[1]), rate(FLY[2]), G2.rally }
      if #G2.curve > 2000 then table.remove(G2.curve, 1) end
      G2.rally = 0
      G2.pointframe = frame
      if now >= st.win and st.win > 0 then
        G2.wins[k] = G2.wins[k] + 1
        event("match", string.format("%s WINS MATCH %d  %d-%d", FLY[k].name, G2.match, st.s1, st.s2), k)
        G2.mpoint = nil
        log("MATCH %d: %s wins %d-%d  (left %d / right %d matches; hit rate L %.0f%% R %.0f%%; best rally %d)",
          G2.match, FLY[k].name, st.s1, st.s2, G2.wins[1], G2.wins[2], 100 * rate(FLY[1]), 100 * rate(FLY[2]), G2.best)
        G2.match = G2.match + 1
        save()
      elseif G2.points % 10 == 0 then
        log("match %d  %d-%d  hit rate L %.0f%% R %.0f%%  rally avg(last 20) %.1f  situations L %d R %d",
          G2.match, st.s1, st.s2, 100 * rate(FLY[1]), 100 * rate(FLY[2]),
          (function() local s, n = 0, 0; for i = math.max(1, #G2.rallies - 19), #G2.rallies do s = s + G2.rallies[i]; n = n + 1 end
            return n > 0 and s / n or 0 end)(),
          (function() local n = 0; for _ in pairs(FLY[1].w) do n = n + 1 end return n end)(),
          (function() local n = 0; for _ in pairs(FLY[2].w) do n = n + 1 end return n end)())
        if G2.points % 50 == 0 then
          save()
          for _, f in ipairs(FLY) do
            local ls = f.leanstat or { au = 0, an = 1, bu = 0, bn = 1 }
            log("  %s circuit lean: ball above %+.2f (n %d), ball below %+.2f (n %d)  [+ = up]", f.name,
              ls.au / math.max(ls.an, 1), ls.an, ls.bu / math.max(ls.bn, 1), ls.bn)
            f.leanstat = nil
          end
        end
      end
    end
  end
  if st.win > 0 and not G2.mpoint and (st.s1 == st.win - 1 or st.s2 == st.win - 1) then
    G2.mpoint = true
    local k = st.s1 == st.win - 1 and 1 or 2
    event("matchpoint", string.format("MATCH POINT - %s", FLY[k].name), k)
  end
  if st.s1 == 0 and st.s2 == 0 then G2.mpoint = nil end
  G2.lastscore = { st.s1, st.s2 }

  -- HITS. The ball's x velocity flips sign off a paddle; the side it flipped on says whose.
  -- A serve can flip it too, so nothing counts for 40 frames after a point, and only near a paddle.
  if live and prev_vx ~= 0 and st.vx ~= 0 and (prev_vx < 0) ~= (st.vx < 0) and frame - G2.pointframe > 40 then
    local k = (st.vx > 0 and st.bx < 90) and 1 or (st.vx < 0 and st.bx > 310) and 2 or nil
    if k then
      local f = FLY[k]
      f.hits = f.hits + 1; record(f, true); reward(f, 1, frame)
      G2.rally = G2.rally + 1; blip = 255
      if G2.rally >= 20 and G2.rally % 10 == 0 then event("rally", string.format("RALLY %d!", G2.rally)) end
      if G2.best >= 5 and G2.rally == G2.best + 1 then event("record", "RECORD BROKEN - STILL GOING") end
    end
  end
  if live then prev_vx = st.vx end
  -- where the ball was against each paddle as it reached that paddle's line (true positions,
  -- read after the fact, only to say which side a miss went past)
  if live then
    if st.vx < 0 and st.bx <= P1X + 8 and st.bx > P1X - 30 then FLY[1].cross = (st.by + BALL_H // 2) - (st.p1y + PAD_H // 2) end
    if st.vx > 0 and st.bx >= P2X - 8 and st.bx < P2X + 30 then FLY[2].cross = (st.by + BALL_H // 2) - (st.p2y + PAD_H // 2) end
  end

  -- PERCEIVE (late) AND DECIDE
  local seen = hist[frame - REACT]
  for k, f in ipairs(FLY) do
    local press = { UP = false, DOWN = false }
    if live and seen and seen.bx ~= 0 then
      local py = (k == 1 and seen.p1y or seen.p2y) + PAD_H // 2
      local px = k == 1 and P1X or P2X
      local p = { rel = (seen.by + BALL_H // 2) - py, dist = math.abs(seen.bx - px), vy = seen.vy,
                  vx = seen.vx, by = seen.by, py = py,
                  coming = (k == 1 and seen.vx < 0) or (k == 2 and seen.vx > 0) }
      f.prel, f.coming = p.rel, p.coming
      f.pbx, f.pby = seen.bx, seen.by
      circuit(f, p, blip)
      local ls = f.leanstat or { au = 0, an = 0, bu = 0, bn = 0 }; f.leanstat = ls
      if p.rel < -10 then ls.au = ls.au + f.lean; ls.an = ls.an + 1 elseif p.rel > 10 then ls.bu = ls.bu + f.lean; ls.bn = ls.bn + 1 end
      if frame % THINK == k % THINK then choose(f, situation(p), frame) end
      press[f.act] = true
    end
    fields[KEYS[k].UP]:set_value(press.UP and 1 or 0)
    fields[KEYS[k].DOWN]:set_value(press.DOWN and 1 or 0)
  end
  blip = math.floor(blip * 0.8)

  st.frame = frame
  if frame % 3 == 0 then
    local ok, err = pcall(dash, st)
    if not ok and not DASH_ERR then DASH_ERR = true; log("dashboard write failed: %s", tostring(err)) end
  end
  if os.getenv("FP_DEBUG") == "1" and frame % 20 == 0 then
    log("dbg f%d live=%s ball=%d,%d v=%.2f,%.2f pads=%d,%d s=%d:%d act=%s/%s sw=%04x",
      frame, tostring(live), st.bx, st.by, st.vx, st.vy, st.p1y, st.p2y, st.s1, st.s2, FLY[1].act, FLY[2].act,
      space:read_u16(0x01600000 * 8 // 8))
  end
  if MAXMIN > 0 and os.time() - G2.started > MAXMIN * 60 then
    save(); log("time limit (%d min) - stopping", MAXMIN); manager.machine:exit()
  end
end)
