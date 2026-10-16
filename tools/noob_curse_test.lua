-- noob_curse_test.lua
-- PROVE Noob's two MK TRILOGY moves match the PC/PSX build (MKTRIL.EXE):
--
-- THE GHOST BALL'S CURSE (nb_cursed, RAM.ASM; NGR_CURSE, MKZAP.ASM): while the
-- ring is on a man he CANNOT HIT, CANNOT BLOCK and CANNOT THROW.  Each rule is
-- run twice - a CONTROL with no ring, then the same thing under a REAL ring
-- put on Jax by a real ghost ball:
--   hit    Jax elbows an idle Noob.        control: Noob hurt.  cursed: not.
--   block  Jax holds Block, Noob elbows.   control: guarded.    cursed: hit.
--   throw  Jax Low Punches in range.       control: throws.     cursed: no.
-- ...and the ball itself:
--   dmg       a full-health Jax loses exactly NBG_DAMAGE (3) to the ball.
--   cap       a Jax on 2 is left on 1 - the ball never KOs.
--   len       the ring holds the curse for 160 ticks (16 x 5 white + 5 black).
--   backfire  a SECOND ball on the cursed Jax frees him and puts the curse on
--             NOOB.
--
-- THE TELEPORT SLAM (do_noob_slam, MKPROP.ASM):
--   rise       he re-enters SUNK and comes up through the floor on the climb
--              frame (NJREPVIC3); the throw reach (NJFLIP1) appears only once
--              his top is within 16px of p_ganiy - never below that line.
--   (rise also requires the catch to leave Jax on QUARTER damage, rh_half 2)
--   cut        the shared cut itself: Noob elbows Jax with rh_half seeded
--              0/1/2 -> 24/12/6.
--   slamblock  Jax guards it: Noob goes to a SITTING DUCK (act_decoy_sd),
--              forward-flips off him (NJJUMPFLIP*), and Jax punishes it.
--
-- Every trial must prove the attempt HAPPENED, or it is NO VERDICT - never a
-- pass.  2-PLAYER, both human (P1 Noob via the Scorpion select swap, P2 Jax).
--
-- NC_NEG=1 IS THE CONTROL OF THE RIG: nb_cursed is zeroed every frame.  The
-- cursed and backfire trials must then FAIL.  NC_ONLY=kind,kind narrows it.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("NC_LOG") or (ROOT .. "/tools/noob_curse_test.log")
local NEG = (os.getenv("NC_NEG") or "0") ~= "0"
local ONLY = os.getenv("NC_ONLY")
if ONLY == "" then ONLY = nil end

local logfh = io.open(LOG, "w")
local function log(f, ...)
  local l = "[nc] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
  print(l); if logfh then logfh:write(l, "\n"); logfh:flush() end
end

local symbols = {}
do local fh = io.open(os.getenv("NC_MAP") or (ROOT .. "/src/mk2.map"), "r")
  if fh then for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
    fh:close() end end

local NEED = {"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
              "p1_bar", "p2_bar", "f_freeze_timer", "nb_cursed", "nb_ring_on", "winner_status", "rh_half"}
local A, missing = {}, {}
for _, n in ipairs(NEED) do A[n] = symbols[n]; if not A[n] then missing[#missing+1] = n end end

-- SAG -> piece label, from the build's own table (a rebuild moves every SAG)
local sag_name, nsag = {}, 0
do local fh = io.open(ROOT .. "/src/MKNJ.TBL", "r")
  if fh then local label
    for line in fh:lines() do
      local l = line:match("^%s*(%u[%u%d_]*):"); if l then label = l end
      local sag = label and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
      if sag then sag_name[tonumber(sag, 16) & 0x00ffffff] = label; nsag = nsag + 1; label = nil end
    end fh:close() end end

local P_ACTION, P_GANIY = 0x1f0, 0x200
local O = { xvel = 0x040, yvel = 0x060, xval = 0x080, xpos = 0x090, ypos = 0x0b0, img = 0x1a0 }
local MP_LEN = 0x70
local ACT = { elbow = 0x0114, hipunch = 0x0101, lopunch = 0x0102, reacting = 0x0503, bodyslam = 0x0507,
              blockhi = 0x0700, slam = 0x0212, decoy_sd = 0x0607 }
local FULL = 0xa1
local GS_PSEL, GS_FIGHTING, GS_POST = 4, 2, 0x0d
local FT_SCORPION, FT_NOOB, FT_JAX = 10, 15, 11
local BALL_SEP, SLAM_SEP = 160, 140
local CLOSE = { hit = 62, block = 62, throw = 56, cut = 62 }
local WINDOW = 70
local RING_TICKS, RING_SLACK = 160, 15

local ALL = {
  { kind = "hit",   cursed = false }, { kind = "hit",   cursed = true },
  { kind = "block", cursed = false }, { kind = "block", cursed = true },
  { kind = "throw", cursed = false }, { kind = "throw", cursed = true },
  { kind = "dmg",   ball = true }, { kind = "cap", ball = true },
  { kind = "len",   ball = true }, { kind = "backfire", ball = true },
  { kind = "rise" }, { kind = "slamblock" },
  { kind = "cut", seed = 0 }, { kind = "cut", seed = 1 }, { kind = "cut", seed = 2 },
}
local TRIALS = {}
for _, t in ipairs(ALL) do
  local keep = true
  if ONLY then keep = false; for k in ONLY:gmatch("[^,]+") do if k == t.kind then keep = true end end end
  if keep then TRIALS[#TRIALS+1] = t end
end
local function needs_ball(t) return t.cursed or t.ball end
local CUT_WANT = { [0] = 24, [1] = 12, [2] = 6 }   -- Noob's elbow (24) >> seed

local space, fields, held = nil, {}, {}
local function hold(n, on) held[n] = on and true or false end
local function release_all() for n in pairs(fields) do held[n] = false end end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function action(slot) local q = r32(A[slot]); return q ~= 0 and r16(q + P_ACTION) or 0xffff end
local function frame_of(obj)
  local img = r32(obj + O.img); if img == 0 then return "?" end
  for i = 0, 7 do
    local sag = r32(img + i * MP_LEN) & 0x00ffffff
    if sag == 0 then break end
    if sag_name[sag] then return sag_name[sag] end
  end
  return "?"
end

local function cache()
  local need = {"Coin 1", "Coin 2", "2 Players Start",
                "P1 Down", "P1 Up", "P1 Right", "P1 Low Punch", "P1 High Punch",
                "P2 Low Punch", "P2 High Punch", "P2 Block", "P2 Down"}
  local want = { ["UI Select"] = true }
  for _, n in ipairs(need) do want[n] = true end
  for _, p in pairs(manager.machine.ioport.ports) do
    for _, fld in pairs(p.fields) do if want[fld.name] then fields[fld.name] = fld end end end
  local miss = {}
  for _, n in ipairs(need) do if not fields[n] then miss[#miss+1] = n end end
  return miss
end

local finished = false
local function finish() if not finished then finished = true; log("finished"); manager.machine:exit() end end
local function refuse(why) log("NO VERDICT noob_curse: %s", why); finish() end

local frame, psel, fight = 0, 0, 0
local ti, phase, t0 = 1, "settle", 0
local x0
local S
local results = {}
local function new_phase(p) phase = p; t0 = frame end

local function place(sep)
  local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
  w32(p1o + O.xval, x0 << 16); w32(p1o + O.xvel, 0)
  w32(p2o + O.xval, (x0 + sep) << 16); w32(p2o + O.xvel, 0)
end

local function record(t, v, d)
  results[#results+1] = v
  log("trial %d %s%s: %s -> %s", ti, t.kind, t.cursed and " CURSED" or (t.cursed == false and " control" or ""), d, v)
  ti = ti + 1
  if ti > #TRIALS then
    local p, f, n = 0, 0, 0
    for _, r in ipairs(results) do if r == "PASS" then p = p + 1 elseif r == "FAIL" then f = f + 1 else n = n + 1 end end
    log("SUMMARY %d pass %d fail %d no-verdict (of %d)", p, f, n, #results)
    if f > 0 then log("FAIL noob_curse") elseif n > 0 then log("NO VERDICT noob_curse") else log("PASS noob_curse") end
    finish(); return
  end
  new_phase("settle")
end

local function acts(set) local o = {} for k in pairs(set or {}) do o[#o+1] = string.format("%04x", k) end table.sort(o) return table.concat(o, ",") end

local function judge_rule(t)
  local s = S
  if t.kind == "hit" then
    if not s.jax_hp then return "NO VERDICT", "Jax's punch never came out" end
    if t.cursed then return (s.noob_drop == 0) and "PASS" or "FAIL", string.format("noob_drop=%d (want 0)", s.noob_drop) end
    return (s.noob_drop > 0) and "PASS" or "FAIL", string.format("noob_drop=%d (want >0)", s.noob_drop)
  elseif t.kind == "block" then
    if not s.noob_hp then return "NO VERDICT", "Noob's punch never came out" end
    if not s.jax_block then return "NO VERDICT", "Jax never stood in his guard" end
    if t.cursed then return s.jax_react and "PASS" or "FAIL", string.format("jax_reacting=%s jax_drop=%d (want hit through the guard)", tostring(s.jax_react), s.jax_drop) end
    return (not s.jax_react) and "PASS" or "FAIL", string.format("jax_reacting=%s jax_drop=%d (want guarded)", tostring(s.jax_react), s.jax_drop)
  else
    if not (s.jax_lp or s.jax_slam) then return "NO VERDICT", "Jax's Low Punch never registered" end
    if t.cursed then return ((not s.jax_slam) and s.noob_drop == 0) and "PASS" or "FAIL",
      string.format("act_bodyslam=%s noob_drop=%d (want no throw, no damage)", tostring(s.jax_slam), s.noob_drop) end
    return s.jax_slam and "PASS" or "FAIL", string.format("act_bodyslam=%s noob_drop=%d (want a throw)", tostring(s.jax_slam), s.noob_drop)
  end
end

emu.register_frame(function()
  frame = frame + 1
  if finished then return end
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    if #missing > 0 then return refuse("missing symbols: " .. table.concat(missing, ",")) end
    if nsag == 0 then return refuse("no SAGs read from src/MKNJ.TBL") end
    local miss = cache()
    if #miss > 0 then return refuse("missing inputs: " .. table.concat(miss, ",")) end
    log("mode=%s trials=%d nb_cursed=%08x sags=%d", NEG and "NEGATIVE (nb_cursed zeroed - cursed/backfire must FAIL)" or "positive", #TRIALS, A.nb_cursed, nsag)
  end
  if NEG then w32(A.nb_cursed, 0) end
  local gs = r16(A.gstate)

  -- ---------------------------------------------------------- boot + select
  if psel == 0 and gs == GS_PSEL then psel = frame; log("select at frame %d", frame); release_all() end
  if psel == 0 then
    hold("Coin 1", frame >= 200 and (frame % 80) < 20)
    hold("Coin 2", frame >= 240 and (frame % 80) >= 20 and (frame % 80) < 40)
    hold("2 Players Start", frame >= 300 and (frame % 80) >= 45 and (frame % 80) < 70)
    hold("UI Select", frame >= 5 and frame < 35)
  elseif fight == 0 then
    local rel = frame - psel
    if gs == GS_PSEL then
      w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
      hold("2 Players Start", rel < 60 and (frame % 20) < 8)
      if rel > 130 then hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8) end
    elseif gs == GS_POST then
      w16(A.p1_char, FT_NOOB); w16(A.p2_char, FT_JAX)
      release_all()
    elseif gs == GS_FIGHTING then
      fight = frame
      release_all()
      log("fight at frame %d (p1=%d p2=%d)", frame, r16(A.p1_char), r16(A.p2_char))
      if r16(A.p1_char) ~= FT_NOOB or r16(A.p2_char) ~= FT_JAX then
        return refuse(string.format("wrong pair p1=%d p2=%d - wanted Noob v Jax", r16(A.p1_char), r16(A.p2_char)))
      end
      new_phase("settle")
    end
    if frame > 6000 then return refuse("never reached a fight") end
  end

  -- ---------------------------------------------------------------- fight
  if fight > 0 and gs == GS_FIGHTING then
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    if not x0 then x0 = s16(r16(p1o + O.xpos)) end
    local t = TRIALS[ti]
    local rel = frame - t0
    local cur = r32(A.nb_cursed)
    local pa, ja = action("p1_proc"), action("p2_proc")

    -- read the drops BEFORE re-pinning the bars
    local nb, jb = r16(A.p1_bar), r16(A.p2_bar)
    if S and phase == "act" then
      S.noob_drop = math.max(S.noob_drop, FULL - nb); S.jax_drop = math.max(S.jax_drop, FULL - jb)
    end
    local pin_jax = not (t.kind == "cap" and (phase == "ball" or phase == "capcheck"))
    w16(A.p1_bar, FULL); if pin_jax then w16(A.p2_bar, FULL) end
    w16(A.f_freeze_timer, 1)

    if phase == "settle" then
      release_all()
      place(needs_ball(t) and BALL_SEP or (CLOSE[t.kind] or SLAM_SEP))
      local idle = (pa == 0x0303 or pa == 0) and (ja == 0x0303 or ja == 0)
      if rel >= 60 and idle and r16(A.nb_ring_on) == 0 and (NEG or cur == 0) then
        S = { noob_drop = 0, jax_drop = 0, pacts = {}, jacts = {} }
        log("trial %d: %s%s", ti, t.kind, t.cursed and " CURSED" or "")
        if t.kind == "cap" then w16(A.p2_bar, 2) end
        if needs_ball(t) then S.jax_bar0 = r16(A.p2_bar); new_phase("ball")
        elseif t.kind == "rise" or t.kind == "slamblock" then
          S.ganiy = s16(r16(r32(A.p1_proc) + P_GANIY)); new_phase("slam")
        else new_phase("setup") end
      elseif rel > 700 then return refuse("the last ring/move never settled") end

    -- ------------------------------------------------------------ ghost ball
    elseif phase == "ball" then
      local r = rel % 60
      hold("P1 Down", r < 4); hold("P1 Right", r >= 6 and r < 10); hold("P1 Low Punch", r >= 12 and r < 18)
      if rel < 20 then place(BALL_SEP) end
      if t.kind ~= "cap" then S.ball_drop = math.max(S.ball_drop or 0, FULL - jb) end
      if r16(A.nb_ring_on) ~= 0 then
        release_all()
        S.ring_at = frame
        S.curse_ok = NEG or (cur == p2o)
        log("  ring up at +%d: nb_cursed=%08x jax_obj=%08x -> %s", rel, cur, p2o,
            (cur == p2o) and "names Jax" or (NEG and "zeroed (negative)" or "WRONG"))
        if t.kind == "dmg" then new_phase("dmgcheck")
        elseif t.kind == "cap" then new_phase("capcheck")
        elseif t.kind == "len" then new_phase("lencheck")
        elseif t.kind == "backfire" then new_phase("bf_wait")
        else new_phase("recover") end
      elseif rel > 360 then return record(t, "NO VERDICT", "the ghost ball never put a ring on Jax") end

    elseif phase == "dmgcheck" then
      S.ball_drop = math.max(S.ball_drop or 0, FULL - jb)
      if rel >= 10 then
        return record(t, (S.ball_drop == 3) and "PASS" or "FAIL", string.format("ball took %d off a full bar (want 3)", S.ball_drop))
      end

    elseif phase == "capcheck" then
      if rel >= 20 then
        local bar = r16(A.p2_bar); local ws = r16(A.winner_status)
        w16(A.p2_bar, FULL)
        return record(t, (bar == 1 and ws == 0) and "PASS" or "FAIL",
          string.format("Jax on %d before, %d after, winner_status=%d (want 1 and 0 - no KO)", S.jax_bar0, bar, ws))
      end

    elseif phase == "lencheck" then
      if cur ~= p2o and not S.lift_at then S.lift_at = frame end
      if S.lift_at or rel > 400 then
        local held_for = (S.lift_at or frame) - S.ring_at
        local ok = (not NEG) and math.abs(held_for - RING_TICKS) <= RING_SLACK
        return record(t, ok and "PASS" or "FAIL", string.format("curse held %d ticks (want %d +-%d)", held_for, RING_TICKS, RING_SLACK))
      end

    elseif phase == "bf_wait" then
      local r = rel % 40
      hold("P1 Down", r < 4); hold("P1 Right", r >= 6 and r < 10); hold("P1 Low Punch", r >= 12 and r < 18)
      if rel < 10 then place(BALL_SEP) end
      if cur == p1o then
        release_all()
        log("  curse moved to Noob %d ticks into the first ring", frame - S.ring_at)
        S.bf_moved = true; new_phase("bf_check")
      elseif r16(A.nb_ring_on) == 0 and rel > 20 then
        return record(t, NEG and "FAIL" or "NO VERDICT", "the first ring ended before a second ball moved the curse")
      elseif rel > 220 then
        return record(t, "FAIL", "second ball never moved the curse onto Noob")
      end

    elseif phase == "bf_check" then
      if rel >= 8 then
        local ok = S.bf_moved and cur == p1o
        return record(t, ok and "PASS" or "FAIL", string.format("nb_cursed=%08x noob_obj=%08x (want Noob)", cur, p1o))
      end

    elseif phase == "recover" then
      release_all()
      if rel >= 10 and (ja == 0x0303 or ja == 0) and (pa == 0x0303 or pa == 0) then new_phase("setup")
      elseif rel > 150 then new_phase("setup") end

    elseif phase == "setup" then
      release_all()
      place(CLOSE[t.kind])
      if t.kind == "block" then hold("P2 Block", true) end
      if rel >= 6 then
        if t.cursed and not NEG and cur ~= p2o then
          return record(t, "NO VERDICT", "the curse had already lifted before the window opened")
        end
        S.noob_drop, S.jax_drop = 0, 0
        new_phase("act")
      end

    elseif phase == "act" then
      S.pacts[pa] = true; S.jacts[ja] = true
      if t.kind == "hit" then
        hold("P2 High Punch", rel >= 2 and rel < 7)
        if ja == ACT.hipunch or ja == ACT.elbow then S.jax_hp = true end
      elseif t.kind == "block" then
        hold("P2 Block", true)
        hold("P1 High Punch", rel >= 4 and rel < 9)
        if pa == ACT.hipunch or pa == ACT.elbow then S.noob_hp = true end
        if ja == ACT.blockhi then S.jax_block = true end
        if ja == ACT.reacting then S.jax_react = true end
      elseif t.kind == "cut" then
        if not S.jax_hit then w16(A.rh_half + 16, t.seed) end   -- Jax's slot
        hold("P1 High Punch", rel >= 4 and rel < 9)
        if pa == ACT.hipunch or pa == ACT.elbow then S.noob_hp = true end
        if ja == ACT.reacting or ja == 0x0610 then S.jax_hit = true end
      else
        hold("P2 Low Punch", rel >= 2 and rel < 7)
        if ja == ACT.lopunch then S.jax_lp = true end
        if ja == ACT.bodyslam then S.jax_slam = true end
      end
      if rel >= WINDOW and t.kind == "cut" then
        release_all()
        if not S.noob_hp then return record(t, "NO VERDICT", "Noob's elbow never came out") end
        local want = CUT_WANT[t.seed]
        return record(t, (S.jax_drop == want) and "PASS" or "FAIL",
          string.format("rh_half=%d: elbow took %d (want %d)", t.seed, S.jax_drop, want))
      end
      if rel >= WINDOW then
        release_all()
        local v, d = judge_rule(t)
        if t.cursed and S.curse_ok == false and v ~= "NO VERDICT" then v = "FAIL"; d = d .. " [ring did not name Jax]" end
        d = d .. string.format("  [noob acts %s | jax acts %s]", acts(S.pacts), acts(S.jacts))
        return record(t, v, d)
      end

    -- ---------------------------------------------------------- teleport slam
    elseif phase == "slam" then
      if not S.fired then
        local r = rel % 50
        hold("P1 Down", r < 4); hold("P1 Up", r >= 6 and r < 10)
        if rel < 10 then place(SLAM_SEP) end
        if t.kind == "slamblock" then hold("P2 Block", true) end
        if pa == ACT.slam then S.fired = frame; hold("P1 Down", false); hold("P1 Up", false) end
        if rel > 300 then return record(t, "NO VERDICT", "the teleport slam never fired") end
      else
        if t.kind == "slamblock" then hold("P2 Block", not S.sd_at) end
        S.q_seen = math.max(S.q_seen or 0, r16(A.rh_half + 16))
        local nf = frame_of(p1o)
        local oy = s16(r16(p1o + O.ypos))
        if nf:sub(1, 9) == "NJREPVIC3" and oy > S.ganiy then S.sunk_climb = (S.sunk_climb or 0) + 1 end
        if nf:sub(1, 7) == "NJFLIP1" and not S.reach_at then S.reach_at = frame; S.reach_oy = oy end
        if nf:sub(1, 7) == "NJFLIP1" and pa == ACT.slam and (oy - 16) > S.ganiy then S.reach_early = (S.reach_early or 0) + 1 end
        -- the throw pose belongs to the CATCH: never while he is still act_noob_slam
        if nf:sub(1, 6) == "NJFLIP" and pa == ACT.slam then S.throw_in_slam = (S.throw_in_slam or 0) + 1 end
        -- which side of Jax he came up on (sunk = after the teleport), and
        -- which side the blocked flip is on
        local dx = s16(r16(p1o + O.xpos)) - s16(r16(p2o + O.xpos))
        if pa == ACT.slam and oy > S.ganiy and dx ~= 0 then S.up_side = dx > 0 and 1 or -1 end
        if pa == ACT.decoy_sd and dx ~= 0 and S.up_side then
          if (dx > 0 and 1 or -1) ~= S.up_side then S.wrong_side = (S.wrong_side or 0) + 1 end
        end
        if pa == ACT.decoy_sd and not S.sd_at then S.sd_at = frame; S.noob_drop = 0 end
        if nf:sub(1, 10) == "NJJUMPFLIP" then S.flipped = (S.flipped or 0) + 1 end
        S.pacts[pa] = true
        if t.kind == "slamblock" and S.sd_at then
          -- punish: Jax uppercuts (Down + HP) through the hop and the landing
          local k = frame - S.sd_at
          hold("P2 Down", k < 60); hold("P2 High Punch", (k % 8) < 3 and k < 60)
          S.noob_drop = math.max(S.noob_drop, FULL - nb)
        end
        if frame - S.fired >= 150 then
          release_all()
          if t.kind == "rise" then
            local ok = (S.sunk_climb or 0) > 0 and S.reach_at ~= nil and (S.throw_in_slam or 0) == 0 and S.q_seen == 2
            return record(t, ok and "PASS" or "FAIL", string.format(
              "climb-frame ticks while sunk=%d, throw pose first at oypos %s (ganiy %d), throw-pose ticks BEFORE the catch=%d (want 0), Jax's rh_half after the catch=%d (want 2 = quarter)  [noob acts %s]",
              S.sunk_climb or 0, tostring(S.reach_oy), S.ganiy, S.throw_in_slam or 0, S.q_seen or 0, acts(S.pacts)))
          else
            if not S.sd_at and not S.reach_at then return record(t, "NO VERDICT", "the slam never reached him") end
            local ok = S.sd_at ~= nil and (S.flipped or 0) > 0 and S.up_side ~= nil
                       and (S.wrong_side or 0) == 0 and (S.throw_in_slam or 0) == 0
            return record(t, ok and "PASS" or "FAIL", string.format(
              "act_decoy_sd=%s flip frames=%d, came up on side %s, sitting-duck ticks on the OTHER side=%d (want 0), throw-pose ticks before the block=%d (want 0), Jax's punish took %d off Noob  [noob acts %s]",
              tostring(S.sd_at ~= nil), S.flipped or 0, tostring(S.up_side), S.wrong_side or 0, S.throw_in_slam or 0, S.noob_drop or 0, acts(S.pacts)))
          end
        end
      end
    end
  end

  for n, fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
  if frame > 40000 then refuse("global timeout") end
end)
