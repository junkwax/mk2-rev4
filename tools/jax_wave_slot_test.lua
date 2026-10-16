-- jax_wave_slot_test.lua
-- PROVE jaxzappid (MAINEQU.ASM): a PLAYER-2 Jax's energy wave goes in player
-- 2's projectile slot, not player 1's.
--
-- Retail spawned the wave with `create pid_proj1,jax_zap_proc` whoever threw
-- it.  Two things key off the slot class, and this rig measures both:
--
--   A. THE SLOT ITSELF.  On the tick the wave exists, walk the active process
--      list and read its procid.  Fixed: class 0800h.  Retail: 0700h.  Then run
--      get_his_proj_proc's own test - procid & 0ff00h == 0800h - for a P1
--      scanner, which is exactly what a P1 CPU does to see the wave coming.
--      This half is deterministic; it is the verdict.
--
--   B. THE CONSEQUENCE.  While the wave is in flight, P1 JADE throws her
--      boomerang.  Her guard (jz3b1, MKZAP.ASM) refuses while her OWN exact
--      slot is live, so on retail a P2 wave sitting in 0700h locks her out.
--      Fixed: she throws (act_jade_boom).  Retail: refused.  A trial only
--      counts if the wave is verifiably STILL ALIVE when her Low Punch lands
--      - a wave that already hit her or left the screen proves nothing, and
--      that trial is NO VERDICT, never a pass.
--
-- THE FIX MUST BE IN THE ROM TO PASS.  The rig finds jax_zap_spawn's own
-- instruction sequence in the :maincpu region - movi 0700h,a0 / movi 0800h,a1
-- / calla p1p2_pick, the "MY projectile" order (MKDRONE's three "HIS
-- projectile" sites have the immediates the other way round) - and requires
-- exactly one hit whose calla resolves to p1p2_pick in THIS build's map.  A
-- jaxzappid 0 ROM has no such sequence and is refused before a frame of play.
--
-- JWS_NEG=1 IS THE CONTROL: it rewrites that one 0800h immediate to 0700h in
-- memory - retail's behaviour, P2's wave in P1's slot - and keeps the SAME
-- expectations, so the run must FAIL.  That proves the rig can see the bug
-- without a second build in a tree other sessions are linking in.
--
-- 2-PLAYER, both human, so no drone decision moves anybody.  Jade is a hidden
-- fighter and cannot be confirmed at select, so P1 hovers Kitana through
-- GS_PSEL and p1_char is overwritten in GS_POST (jade_boom_prezap_test.lua's
-- trick).  Both bars are pinned and the round clock frozen, because a rig
-- that outlives the round clock reads as trials that never happened.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG = os.getenv("JWS_LOG") or (ROOT .. "/tools/jax_wave_slot_test.log")
local NEG = (os.getenv("JWS_NEG") or "0") ~= "0"
local TRIALS = tonumber(os.getenv("JWS_TRIALS") or "4")
local TRACE = (os.getenv("JWS_TRACE") or "0") ~= "0"
-- JWS_AIR=1: Jax jumps straight up and throws in the air (do_jax_airzap, the
-- project's own move).  Same spawn helper, so the same two verdicts - plus
-- WHERE it flies: jax_zap_proc launches the wave from wherever he is and flies
-- it FLAT (set_proj_vel, no y velocity), so its height is his release height.
-- Logged per trial: how high he was, the wave's top y against Jade's, and
-- whether it hit her.  Reported, not asserted - that is how the move behaves,
-- not what the fix changes.
local AIR = (os.getenv("JWS_AIR") or "0") ~= "0"
-- JWS_DELAY shifts the whole air motion + High Kick later by N ticks, which
-- moves the release point down the jump arc.  The motion moves with the kick
-- because the combo window (scom_jax_zap, 018h) is counted from the motion's
-- first entry - shifting the kick alone would just let the window expire.
local DELAY = tonumber(os.getenv("JWS_DELAY") or "0")

local logfh = io.open(LOG, "w")
local raw = print
print = function(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
  local l = table.concat(t, "\t"); raw(l); if logfh then logfh:write(l, "\n"); logfh:flush() end end
local function log(f, ...) print("[jws] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))) end

local symbols = {}
do local fh = io.open(os.getenv("JWS_MAP") or (ROOT .. "/src/mk2.map"), "r")
  if fh then for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
    fh:close() end end

-- A missing symbol is a REFUSAL, not a default.
local NEED = {"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
              "p1_bar", "p2_bar", "active", "p1p2_pick", "f_freeze_timer"}
local A, missing = {}, {}
for _, n in ipairs(NEED) do A[n] = symbols[n]; if not A[n] then missing[#missing+1] = n end end

-- process block: plink 0, procid 20h (MAINEQU.ASM); p_action = pdata+0f0h
local PLINK, PROCID, P_ACTION = 0x000, 0x020, 0x1f0
local PA8 = 0x0c0   -- a8 saved in the process block while it sleeps (MAINEQU pa8)
-- object block (DISPEQU.ASM).  oypos is the sprite's TOP, not its anchor.
local O = { xvel = 0x040, yvel = 0x060, xval = 0x080, xpos = 0x090, ypos = 0x0b0 }
local ACT_JAX_ZAP, ACT_JADE_BOOM = 0x014, 0x112
local CLASS_P1, CLASS_P2 = 0x0700, 0x0800
local FULL_STRENGTH = 0xa1
local GS_PSEL, GS_FIGHTING, GS_POST = 4, 2, 0x0d
local FT_KITANA, FT_JAX, FT_JADE = 4, 11, 16
local SEPARATION = 230   -- px between them: the wave's flight is what B has to fit in

local space, fields = nil, {}
local held = {}
local function hold(n, on) held[n] = on and true or false end
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function action(slot) local q = r32(A[slot]); return q ~= 0 and r16(q + P_ACTION) or 0xffff end

-- Every live process in the 07xx/08xx projectile classes, as {ptr, procid}.
local function projectiles()
  local out, p, guard = {}, r32(A.active + PLINK), 0
  while p ~= 0 and guard < 512 do
    local id = r16(p + PROCID)
    local cls = id & 0xff00
    if cls == CLASS_P1 or cls == CLASS_P2 then out[#out+1] = { ptr = p, id = id } end
    p = r32(p + PLINK); guard = guard + 1
  end
  return out
end
local function alive(ptr, id)
  for _, q in ipairs(projectiles()) do if q.ptr == ptr and q.id == id then return true end end
  return false
end

-- get_his_proj_proc, MKDRONE.ASM, for a PLAYER-1 scanner: P1 looks for P2's
-- class.  Reimplemented, not approximated - it is a masked compare.
local function p1_cpu_would_see_a_p2_projectile()
  for _, q in ipairs(projectiles()) do if (q.id & 0xff00) == CLASS_P2 then return true end end
  return false
end


-- UI Select only dismisses the boot warning and is not a game port in every
-- MAME build, so it is optional; every input the trials depend on is not.
local function cache()
  local need = {"Coin 1", "Coin 2", "2 Players Start",
                "P1 Left", "P1 Right", "P1 Low Punch",
                "P2 Left", "P2 Right", "P2 Down", "P2 Low Punch", "P2 High Kick"}
  if AIR then need[#need+1] = "P2 Up" end
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
local function refuse(why) log("FAIL jax_wave_slot: %s", why); finish() end

-- THE PATCH SITE.  Positive mode requires it (the fix is in this ROM);
-- negative mode rewrites it.  Either way exactly one hit, calla -> p1p2_pick.
local PAT = {0xC0, 0x09, 0x00, 0x07, 0xC1, 0x09, 0x00, 0x08, 0x5F, 0x0D}
local function locate_site()
  local reg = manager.machine.memory.regions[":maincpu"]
  if not reg then return nil, "no :maincpu region" end
  local hits = {}
  for i = 0, reg.size - #PAT - 4 do
    if reg:read_u8(i) == 0xC0 then
      local ok = true
      for k = 2, #PAT do if reg:read_u8(i + k - 1) ~= PAT[k] then ok = false; break end end
      if ok then hits[#hits+1] = i end
    end
  end
  if #hits ~= 1 then
    return nil, string.format("jax_zap_spawn's sequence found %d times, expected exactly 1"
      .. " - a jaxzappid 0 ROM has none; refusing rather than measuring the wrong code", #hits)
  end
  local off = hits[1]
  local tgt = reg:read_u8(off+10) | (reg:read_u8(off+11) << 8)
            | (reg:read_u8(off+12) << 16) | (reg:read_u8(off+13) << 24)
  if tgt ~= A.p1p2_pick then
    return nil, string.format("the calla at %x targets %08x, not p1p2_pick %08x - map and ROM"
      .. " are from different links", off, tgt, A.p1p2_pick)
  end
  return reg, off
end

-- trial state
local frame, psel, confirm, fight = 0, 0, 0, 0
local trial, phase, t0 = 0, "settle", 0
local wave, jade_seq_at, lp_at, wave_alive_at_lp, boom_seen, jax_fired = nil, nil, nil, nil, false, false
local A_pass, A_fail, B_pass, B_fail, B_nov = 0, 0, 0, 0, 0
local pin1
local p2_ground_y, release_h, jade_top = nil
-- the wave's own flight, followed every tick (see track_wave)
local wave_obj, wy_first, wy_min, wy_max, wy_last, wyvel, wave_ticks = nil, nil, nil, nil, nil, nil, 0
local hit_amt, stray_amt, wave_dead_at = nil, nil, nil
local air_trials, air_hits = 0, 0
local start_h

local function new_phase(p) phase = p; t0 = frame end

local function release_all() for n in pairs(fields) do held[n] = false end end

-- FOLLOW THE WAVE'S OWN OBJECT, every tick it lives.  It is a8 in
-- jax_zap_proc, which the process block holds in pa8 - BUT ONLY ONCE THAT
-- PROCESS HAS RUN AND SLEPT.  A freshly created process's pa8 is its
-- CREATOR's a8, i.e. Jax's own object, so reading it on the spawn tick
-- reports Jax's head as "the wave".  This rig did exactly that at first and
-- every wave height it printed was 77 - his lift.  So: ignore pa8 while it
-- is either fighter, and re-read it every tick rather than trusting one
-- sample to describe a whole flight.
local function track_wave(p1o, p2o)
  if not wave or not alive(wave.ptr, wave.id) then return end
  local o = r32(wave.ptr + PA8)
  if o == 0 or o == p1o or o == p2o then return end
  if wave_obj and o ~= wave_obj then return end   -- recycled slot; keep the first
  wave_obj = o
  local y = s16(r16(o + O.ypos))
  if not wy_first then
    wy_first = y
    local v = r32(o + O.yvel); if v >= 0x80000000 then v = v - 0x100000000 end
    wyvel = v
    if p1o ~= 0 then jade_top = s16(r16(p1o + O.ypos)) end
  end
  wy_min = wy_min and math.min(wy_min, y) or y
  wy_max = wy_max and math.max(wy_max, y) or y
  wy_last = y
  wave_ticks = wave_ticks + 1
end

emu.register_frame(function()
  frame = frame + 1
  if finished then return end
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    if #missing > 0 then return refuse("missing symbols: " .. table.concat(missing, ",")) end
    local miss = cache()
    if #miss > 0 then return refuse("missing inputs: " .. table.concat(miss, ",")) end
    local reg, off = locate_site()
    if not reg then return refuse(off) end
    if NEG then
      reg:write_u8(off + 7, 0x07)   -- movi 0800h,a1 -> movi 0700h,a1: retail
      log("NEGATIVE: patched jax_zap_spawn at :maincpu+%x to pick 0700h for P2 too", off)
    else
      log("fix present: jax_zap_spawn at :maincpu+%x, calla -> p1p2_pick", off)
    end
    log("mode=%s%s trials=%d separation=%d delay=%d", AIR and "AIR " or "", NEG and "NEGATIVE" or "positive", TRIALS, SEPARATION, DELAY)
  end
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
      w16(A.p1_char, FT_KITANA); w16(A.p2_char, FT_JAX)
      hold("2 Players Start", rel < 60 and (frame % 20) < 8)
      if rel > 130 then hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8) end
    elseif gs == GS_POST then
      w16(A.p1_char, FT_JADE); w16(A.p2_char, FT_JAX)
      release_all()
    elseif gs == GS_FIGHTING then
      fight = frame
      release_all()
      log("fight at frame %d (p1=%d p2=%d)", frame, r16(A.p1_char), r16(A.p2_char))
      if r16(A.p1_char) ~= FT_JADE or r16(A.p2_char) ~= FT_JAX then
        return refuse(string.format("wrong pair p1=%d p2=%d - wanted Jade v Jax",
                                    r16(A.p1_char), r16(A.p2_char)))
      end
      trial = 1; new_phase("settle")
    end
    if frame > 6000 then return refuse("never reached a fight") end
  end

  -- ---------------------------------------------------------------- fight
  if fight > 0 and gs == GS_FIGHTING then
    -- Read Jade's bar BEFORE re-pinning it, and keep the AMOUNT.  A drop is
    -- only the wave's if it lands while the wave is alive (or within 2 ticks
    -- of it dying), and the amount says what hit her: stk_jxzap is 18 clean,
    -- 13 after Jade's 3/4 hidden-fighter scaling.  "Her bar went down"
    -- without both checks is how the CPU air-zap rig credits a follow-up
    -- jab to the projectile.
    if (phase == "jade" or phase == "track") and wave then
      local drop = FULL_STRENGTH - r16(A.p1_bar)
      if drop > 0 then
        local live = alive(wave.ptr, wave.id) or (wave_dead_at and frame - wave_dead_at <= 2)
        if live then hit_amt = math.max(hit_amt or 0, drop) else stray_amt = math.max(stray_amt or 0, drop) end
      end
    end
    w16(A.p1_bar, FULL_STRENGTH); w16(A.p2_bar, FULL_STRENGTH)
    w16(A.f_freeze_timer, 1)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o ~= 0 and p2o ~= 0 then
      if not pin1 then pin1 = s16(r16(p1o + O.xpos)) end
      w32(p1o + O.xval, (pin1 << 16)); w32(p1o + O.xvel, 0)
      w32(p2o + O.xval, ((pin1 + SEPARATION) << 16)); w32(p2o + O.xvel, 0)
    end
    local rel = frame - t0

    if phase == "settle" then
      release_all()
      -- start a trial only once nothing is in the air from the last one
      if rel >= 60 and #projectiles() == 0 then
        wave, jade_seq_at, lp_at, wave_alive_at_lp, boom_seen, jax_fired = nil, nil, nil, nil, false, false
        p2_ground_y = p2o ~= 0 and s16(r16(p2o + O.ypos)) or nil
        release_h, jade_top, start_h = nil, nil, nil
        wave_obj, wy_first, wy_min, wy_max, wy_last, wyvel, wave_ticks = nil, nil, nil, nil, nil, nil, 0
        hit_amt, stray_amt, wave_dead_at = nil, nil, nil
        log("trial %d", trial); new_phase("jax")
      elseif rel > 400 then return refuse("projectiles never cleared between trials") end

    elseif phase == "jax" then
      -- P2 stands on the right facing LEFT: Forward = Left, Back = Right.
      if AIR then
        -- Straight up, then the whole motion on the way up so the HK lands
        -- airborne.  Up is released before Down so it is not read as a
        -- second jump command.
        local d = rel - DELAY
        hold("P2 Up", rel < 3)
        hold("P2 Left", d >= 6 and d < 9)
        hold("P2 Down", d >= 11 and d < 14)
        hold("P2 Right", d >= 16 and d < 19)
        hold("P2 High Kick", d >= 21 and d < 26)
      else
        hold("P2 Left", rel < 4)
        hold("P2 Down", rel >= 5 and rel < 9)
        hold("P2 Right", rel >= 10 and rel < 14)
        hold("P2 High Kick", rel >= 15 and rel < 20)
      end
      if action("p2_proc") == ACT_JAX_ZAP and not jax_fired then
        jax_fired = true
        -- AIR OR GROUND IS DECIDED HERE, by which move started, not by a
        -- height threshold at the release.  (Measured: he does NOT fall
        -- during the throw - start and release height match every trial -
        -- but a 20px release cut-off still discarded genuine low air throws,
        -- which is the band that matters.)
        if p2_ground_y and p2o ~= 0 then start_h = p2_ground_y - s16(r16(p2o + O.ypos)) end
      end
      -- Jade starts her motion as soon as Jax is committed, so her Low Punch
      -- can land on the first tick the wave exists rather than ~14 after it.
      if jax_fired and not jade_seq_at then jade_seq_at = frame end
      if jade_seq_at then
        local j = frame - jade_seq_at
        hold("P1 Left", j < 5)          -- P1 faces RIGHT: Back = Left
        hold("P1 Right", j >= 7 and j < 12)
      end
      local ps = projectiles()
      if #ps > 0 then
        wave = ps[1]
        local cls = wave.id & 0xff00
        local want = CLASS_P2
        local seen = p1_cpu_would_see_a_p2_projectile()
        local okA = (cls == want) and seen
        -- How high was he when it left?  Ground y minus his y now (oypos is
        -- the sprite top, so the DIFFERENCE is his lift whatever the pose).
        if p2_ground_y and p2o ~= 0 then release_h = p2_ground_y - s16(r16(p2o + O.ypos)) end
        if AIR and not (start_h and start_h > 8) then
          -- Counted as NOTHING: a ground wave scoring as an air pass is the
          -- false green this mode exists to avoid.
          log("trial %d: NO VERDICT - NOT AN AIR THROW, Jax was %s px up when the special"
              .. " started (%s at the release)", trial, tostring(start_h), tostring(release_h))
          B_nov = B_nov + 1; release_all(); trial = trial + 1; new_phase("settle")
        else
          if okA then A_pass = A_pass + 1 else A_fail = A_fail + 1 end
          log("trial %d A: wave procid=%04x class=%04x (want %04x) p1_cpu_scan_finds_it=%s"
              .. "%s -> %s", trial, wave.id, cls, want, tostring(seen),
              release_h and string.format(" released %dpx up", release_h) or "",
              okA and "PASS" or "FAIL")
          new_phase("jade")
        end
      elseif rel > 120 then
        log("trial %d: NO VERDICT - the wave never spawned (jax_fired=%s)", trial, tostring(jax_fired))
        B_nov = B_nov + 1; trial = trial + 1; new_phase("settle")
      end

    elseif phase == "jade" then
      -- If Jax's action stamp was missed she has not started her motion; start
      -- it now rather than throw a bare Low Punch and score a false FAIL.
      if not jade_seq_at then jade_seq_at = frame end
      local j = frame - jade_seq_at
      hold("P1 Left", j < 5)
      hold("P1 Right", j >= 7 and j < 12)
      -- Low Punch once the motion is done; it is the press the guard runs on.
      local lp_ready = j >= 13
      if lp_ready and not lp_at then
        lp_at = frame
        wave_alive_at_lp = alive(wave.ptr, wave.id)
      end
      hold("P1 Low Punch", lp_at ~= nil and (frame - lp_at) < 6)
      if lp_at and (frame - lp_at) <= 6 and not alive(wave.ptr, wave.id) then
        wave_alive_at_lp = false   -- died inside the window the guard could run in
      end
      if action("p1_proc") == ACT_JADE_BOOM then boom_seen = true end
      track_wave(p1o, p2o)
      if TRACE then log("  t%d j=%d p1act=%04x p2act=%04x wave_alive=%s", frame - t0, j,
                        action("p1_proc"), action("p2_proc"), tostring(alive(wave.ptr, wave.id))) end
      if lp_at and (frame - lp_at) >= 30 then
        if not wave_alive_at_lp then
          B_nov = B_nov + 1
          log("trial %d B: NO VERDICT - the wave was gone before her Low Punch could be judged", trial)
        else
          local okB = boom_seen
          if okB then B_pass = B_pass + 1 else B_fail = B_fail + 1 end
          log("trial %d B: wave alive at her Low Punch, act_jade_boom seen=%s -> %s",
              trial, tostring(boom_seen), okB and "PASS" or "FAIL")
        end
        -- B is decided; keep following the wave until it is gone, so a hit
        -- that lands late in its flight is not cut off by B's window.
        release_all(); new_phase("track")
      end

    elseif phase == "track" then
      track_wave(p1o, p2o)
      if not alive(wave.ptr, wave.id) and not wave_dead_at then wave_dead_at = frame end
      if (wave_dead_at and frame - wave_dead_at > 3) or rel > 150 then
        air_trials = air_trials + 1
        local hit = hit_amt ~= nil
        if hit then air_hits = air_hits + 1 end
        log("trial %d FLIGHT: started %spx up; wave obj %s, y first/min/max/last = %s/%s/%s/%s,"
            .. " yvel=%s, followed %d ticks; Jade top y=%s; hit by wave=%s%s%s",
            trial, tostring(start_h), wave_obj and string.format("%08x", wave_obj) or "NEVER FOUND",
            tostring(wy_first), tostring(wy_min), tostring(wy_max), tostring(wy_last),
            wyvel and string.format("%.2f", wyvel / 65536) or "?", wave_ticks, tostring(jade_top),
            tostring(hit), hit and string.format(" (for %d)", hit_amt) or "",
            stray_amt and string.format("  [unrelated drop of %d - not the wave]", stray_amt) or "")
        trial = trial + 1; new_phase("settle")
      end
    end

    if trial > TRIALS then
      log("SUMMARY %s  A(slot): %d pass %d fail   B(Jade lockout): %d pass %d fail %d no-verdict"
          .. "   wave hit Jade %d of %d", AIR and "AIR" or "GROUND",
          A_pass, A_fail, B_pass, B_fail, B_nov, air_hits, air_trials)
      local verdict
      if A_fail > 0 or B_fail > 0 then verdict = "FAIL"
      elseif A_pass >= 2 and B_pass >= 2 then verdict = "PASS"
      else verdict = "NO VERDICT" end
      if NEG then
        log("%s jax_wave_slot (NEGATIVE control: retail behaviour patched in - FAIL is the"
            .. " expected result)", verdict)
      else
        log("%s jax_wave_slot", verdict)
      end
      return finish()
    end
  end

  for n, fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
end)
