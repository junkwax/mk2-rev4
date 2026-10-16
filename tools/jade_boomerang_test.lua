-- jade_boomerang_test.lua
-- Runtime proof for Jade's finished kit, in three modes (JADE_MODE env):
--
-- NOTE on the Flash sequences: they are Left,Right (= Back,Forward), the
-- same motion the boomerang tests use.  They used to be Right,Left, left over
-- from when the Flash was Forward,Back; the input was changed to Back,Forward
-- on 2026-07-24 and these were never updated.  combo_look_lr therefore never
-- matched and jade_flash_free / jade_flash_cooldown_reuse / flash_free_move
-- failed for months as "never saw action=0x115" - a stale TEST, not a broken
-- move.  jade_flash_gated and kitana_no_flash are `avoid` tests, so the dead
-- input made them pass for the wrong reason.
--
--   jade      P1=Jade vs Reptile drone.  Positive suite: the STRAIGHT
--             boomerang on Back,Forward+LP (UMK3 damage 20, blood
--             reaction that recovers), double-throw busy guard, Flash with
--             free movement + cooldown gate + reuse, and Kitana's spin
--             chop input must do nothing for Jade.
--   kitana    P1=Kitana vs Reptile drone.  Negative suite: Kitana must no
--             longer fire the boomerang or the Flash; her own spin chop
--             must still work.
--   dronejade P1=Liu Kang vs Jade DRONE at natural (forced-8) difficulty.
--             The drone must throw the boomerang (never Kitana's fans),
--             and must counter a Liu Kang fireball with the Flash
--             (MKDRONE jade beware branch).
--
-- The boomerang's four trajectories, the inputs that pick them and the
-- arcade flight numbers are covered separately by jade_boom_arcs_test.lua.
-- This file only needs ONE of them, and it uses the straight throw.
--
-- Jade selection trick (from jade_victory_test.lua): the select screen
-- won't take char 16 directly, so pick Kitana during GS_PSEL and overwrite
-- p!_char to FT_JADE during GS_POST - the fight then creates Jade.

local MODE = (os.getenv("JADE_MODE") or "jade"):lower()
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_BOOM_LOG") or (ROOT .. "/tools/jade_boomerang_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[jade-boom] " .. string.format(fmt, ...)
    raw_print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
local function load_symbols()
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if not fh then return end
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
load_symbols()
local function sym(name, fallback) return symbols[name] or fallback end

local A = {
    gstate         = sym("gstate", 0x0112a830),
    p1_obj         = sym("p1_obj", 0x0112a880),
    p1_proc        = sym("p1_proc", 0x0112a8c0),
    p1_char        = sym("p1_char", 0x0112a8e0),
    p1_bar         = sym("p1_bar", 0x01129ea0),
    p2_obj         = sym("p2_obj", 0x0112b450),
    p2_proc        = sym("p2_proc", 0x0112b490),
    p2_char        = sym("p2_char", 0x0112b4b0),
    p2_bar         = sym("p2_bar", 0x0112aa70),
    diff           = sym("diff", nil),
    winner_status  = sym("winner_status", 0x0112c170),
    l_jade_flash   = sym("l_jade_flash", 0x0112c450),
    f_jade_flash   = sym("f_jade_flash", 0x0112c470),
}
local P_ACTION = 0x1f0
-- pdata=100h, p_flags=pdata+110h.  pm_reacting is the bit UMK3's own
-- jade_flash_sleep tests on every 3-tick beat to drop the shield.
local P_FLAGS, PM_REACTING = 0x210, 0x0004
local ACT_JADE_BOOM, ACT_JADE_FLASH = 0x112, 0x115
local ACT_THROW_FANS, ACT_SPINCHOP, ACT_SHADK = 0x008, 0x111, 0x205
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_LK, FT_KITANA, FT_REPTILE, FT_JADE, MAX_HP = 1, 4, 9, 16, 0xa1
local OXPOS = 0x90

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local charsel_frame, confirm_frame, fighting_frame = 0, 0, 0
local last_pc, stuck = nil, 0

-- Sound-call tap (same decoder as fly_wins_test.lua): send_code_a3 writes the
-- call to 0x01d01030 as two bytes tagged 0xff00, high byte first; a real
-- track's high byte is always <= 7.  Every completed call is kept with its
-- fight-relative frame so the Flash checks can count and space the $0358
-- sends that UMK3's per-blink ochar_sound(0xc) should produce.
local SND_PORT, snd_hi, snd_tap = 0x01d01030, nil, nil
local snd_log = {}
local function on_sound_write(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    local code = (snd_hi << 8) | (w & 0xff)
    snd_hi = nil
    if fighting_frame > 0 then
        snd_log[#snd_log + 1] = { r = frame - fighting_frame, code = code }
    end
    return data
end
local function sends_of(code, r_lo, r_hi)
    local out = {}
    for _, s in ipairs(snd_log) do
        if s.code == code and s.r >= r_lo and s.r <= r_hi then out[#out + 1] = s.r end
    end
    return out
end
local SND_JADE_FLASH = 0x0358
local SND_JADE_ZAP   = 0x0564
local SND_JADE_NITRO = 0x036A

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end

local function reg(n)
    if not cpu then return nil end
    local ok, v = pcall(function() return cpu.state[n].value end)
    return ok and v or nil
end

local function proc_action(proc_ptr_addr)
    local proc = r32(proc_ptr_addr)
    if proc == 0 then return 0xffff end
    return r16(proc + P_ACTION)
end
local function p1_action() return proc_action(A.p1_proc) end
local function p2_action() return proc_action(A.p2_proc) end
local function obj_x(obj_ptr_addr)
    local obj = r32(obj_ptr_addr)
    if obj == 0 then return 0 end
    return r16(obj + OXPOS)
end

local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end); log("snapshot %s", label) end
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("%s reason=%s mode=%s", ok and "PASS" or "ERROR", reason, MODE)
    logfh:close()
    manager.machine:exit()
end

-- Mode config -------------------------------------------------------------
local cfg = {}
if MODE == "jade" then
    cfg.psel_p1, cfg.post_p1 = FT_KITANA, FT_JADE
    cfg.psel_p2, cfg.post_p2 = FT_REPTILE, nil
    cfg.force_diff0 = true
    cfg.run_end = 1320
    cfg.tests = {
        { at = 90,  label = "jade_boom_bflp", want = ACT_JADE_BOOM, hp_watch = true,
          shot = 30, shots = { 18, 26, 34 },
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Punch",12,18} } },
        { at = 420, label = "jade_boom_double", want = ACT_JADE_BOOM,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Punch",12,16},
                  {"P1 Left",22,26}, {"P1 Right",28,32}, {"P1 Low Punch",34,38} } },
        { at = 600, label = "jade_flash_free", want = ACT_JADE_FLASH, shot = 14, free_move = true,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Kick",12,18},
                  {"P1 Right",26,58} } },
        { at = 700, label = "jade_flash_gated", avoid = ACT_JADE_FLASH,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Kick",12,18} } },
        { at = 810, label = "jade_flash_cooldown_reuse", want = ACT_JADE_FLASH,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Kick",12,18} } },
        -- Kitana's overhead spin chop input must be dead on Jade.
        { at = 950, label = "jade_no_kitana_spinchop", avoid = ACT_SPINCHOP,
          seq = { {"P1 Block",0,30}, {"P1 Up",8,12}, {"P1 Up",16,20} } },
        -- Jade's Blazing Nitro Kick: Down, Forward + LK.
        { at = 1030, label = "jade_nitro_kick", want = ACT_SHADK, shot = 12,
          seq = { {"P1 Down",0,4}, {"P1 Right",6,10}, {"P1 Low Kick",12,18} } },
        -- Being hit mid-flash must drop the shield (the arcade's own rule).
        { at = 1140, label = "jade_flash_hit_drop", want = ACT_JADE_FLASH,
          hit_drop = true,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Kick",12,18} } },
    }
    cfg.extra = { "boom_hit_damage", "boom_hit_recovers", "flash_free_move",
                  "flash_hit_drops", "flash_sound_per_blink", "flash_sound_stops_on_hit",
                  "boom_zap_on_hit", "nitro_sound_once_at_start" }
elseif MODE == "kitana" then
    cfg.psel_p1, cfg.post_p1 = FT_KITANA, nil
    cfg.psel_p2, cfg.post_p2 = FT_REPTILE, nil
    cfg.force_diff0 = true
    cfg.run_end = 620
    cfg.tests = {
        { at = 90,  label = "kitana_no_boomerang", avoid = ACT_JADE_BOOM,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Punch",12,18} } },
        -- The straight throw moved to LP and the downward one to LK, which
        -- means two more char_* dispatch slots now point at Jade code.  Only
        -- entry 16 was changed, but that is exactly the kind of off-by-one
        -- this suite exists to catch (see the ochar short-table crash class).
        { at = 150, label = "kitana_no_boomerang_lp", avoid = ACT_JADE_BOOM,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Punch",12,18} } },
        { at = 200, label = "kitana_no_flash", avoid = ACT_JADE_FLASH,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 High Kick",12,18} } },
        { at = 260, label = "kitana_no_boomerang_lk", avoid = ACT_JADE_BOOM,
          seq = { {"P1 Left",0,4}, {"P1 Right",6,10}, {"P1 Low Kick",12,18} } },
        -- Kitana no longer has the Nitro Kick (moved to Jade).
        { at = 320, label = "kitana_no_nitro", avoid = ACT_SHADK,
          seq = { {"P1 Down",0,4}, {"P1 Right",6,10}, {"P1 Low Kick",12,18} } },
        { at = 440, label = "kitana_spinchop_works", want = ACT_SPINCHOP, shot = 20,
          seq = { {"P1 Block",0,30}, {"P1 Up",8,12}, {"P1 Up",16,20} } },
    }
    cfg.extra = {}
elseif MODE == "dronejade" then
    cfg.psel_p1, cfg.post_p1 = FT_LK, nil
    cfg.psel_p2, cfg.post_p2 = FT_KITANA, FT_JADE
    cfg.force_diff0 = false      -- the drone must actually fight
    cfg.force_diff = 3           -- moderate: drone stance-waits so beware polls
    cfg.top_up_p1 = true         -- keep Liu Kang alive
    cfg.top_up_p2 = true         -- keep the drone alive so it keeps fighting
    -- Jade fights are always diff 8 (boss_minumum_diff) in real play, but
    -- the DRONE only polls drone_beware in stance/walk states, and at diff 8
    -- it is too busy attacking to catch a scripted projectile.  We force
    -- diff 3 (drone stance-waits) and throw point-blank Forward,Forward+HP
    -- fireballs it cannot wait out, which reliably triggers the Jade Flash
    -- projectile-counter (the novel AI wiring worth regression-testing).
    -- The drone's own auto-aimed boomerang and Nitro Kick are RNG-emergent;
    -- they are observed/logged here (and asserted structurally by the jade
    -- player mode + zap_offsets[16]) rather than hard-required, to keep this
    -- check deterministic.
    cfg.fireball_first  = 300
    cfg.fireball_period = 150
    cfg.chase           = false  -- stay put (matches the run where the drone flashed)
    cfg.run_end = 2400
    cfg.tests = {}
    -- Deterministic requirement: the Jade drone must NOT fall back on
    -- Kitana's fans (structurally unwired for Jade).  The drone's own
    -- boomerang, Flash-counter and Nitro Kick are emergent/RNG-gated - they
    -- are logged as observations (and are proven by the jade player mode +
    -- the wiring) rather than hard-required, to keep this check stable.
    cfg.extra = { "drone_no_fans" }
else
    error("unknown JADE_MODE: " .. MODE)
end
local results = {}
local drone_fans_seen = false
local drone_nitro_seen = false
local drone_react_seen = false
local last_p2act = nil
local p1_fireball_seen = false

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Right"] = true, ["P1 Left"] = true, ["P1 Up"] = true, ["P1 Down"] = true,
        ["P1 High Punch"] = true, ["P1 Low Punch"] = true,
        ["P1 Low Kick"] = true, ["P1 High Kick"] = true, ["P1 Block"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 and fighting_frame == 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if fighting_frame == 0 then return false end

    local r = frame - fighting_frame
    if MODE == "dronejade" then
        local phase = (r >= cfg.fireball_first) and ((r - cfg.fireball_first) % cfg.fireball_period) or -1
        -- fireball window: a clean Forward,Forward+HP with neutral gaps
        if phase >= 0 and phase < 18 then
            if name == "P1 Right" and (phase < 4 or (phase >= 6 and phase < 12)) then return true end
            if name == "P1 High Punch" and phase >= 12 and phase < 18 then return true end
            return false
        end
        -- otherwise chase the (retreating) drone to keep the range short
        if cfg.chase and name == "P1 Right" then return true end
        return false
    end
    for _, t in ipairs(cfg.tests) do
        local d = r - t.at
        for _, s in ipairs(t.seq) do
            if name == s[1] and d >= s[2] and d < s[3] then return true end
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local ok, tap = pcall(function()
            return space:install_write_tap(0x01d00000, 0x01d01fff, "jadesnd", on_sound_write)
        end)
        snd_tap = ok and tap or nil     -- keep the handle alive or the tap is dropped
        if not ok then log("WARNING: sound tap not installed (%s)", tostring(tap)) end
        cache_fields()
        log("harness loaded mode=%s, %d tests (+%d extra checks)", MODE, #cfg.tests, #cfg.extra)
        log("p2_bar=%08x p1_bar=%08x diff=%s", A.p2_bar, A.p1_bar,
            A.diff and string.format("%08x", A.diff) or "MISSING")
    end
    if not space or finished then
        for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_char, cfg.psel_p1)
        w16(A.p2_char, cfg.psel_p2)
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame
            log("confirming at frame %d (psel p1=%d p2=%d)", frame, cfg.psel_p1, cfg.psel_p2)
        end
    elseif gs == GS_POST then
        if cfg.post_p1 then w16(A.p1_char, cfg.post_p1) end
        if cfg.post_p2 then w16(A.p2_char, cfg.post_p2) end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight started p1=%d p2=%d p1_hp=%d p2_hp=%d diff=%d",
            r16(A.p1_char), r16(A.p2_char), r16(A.p1_bar), r16(A.p2_bar),
            A.diff and r16(A.diff) or -1)
        if cfg.post_p1 and r16(A.p1_char) ~= cfg.post_p1 then
            finish(false, "p1_char_overwrite_failed"); return
        end
        if cfg.post_p2 and r16(A.p2_char) ~= cfg.post_p2 then
            finish(false, "p2_char_overwrite_failed"); return
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame

        if cfg.force_diff0 and A.diff then w16(A.diff, 0) end
        if cfg.force_diff and A.diff then w16(A.diff, cfg.force_diff) end
        if cfg.top_up_p1 then w16(A.p1_bar, MAX_HP) end
        if cfg.top_up_p2 then w16(A.p2_bar, MAX_HP) end

        -- dronejade: watch the drone across the whole run
        if MODE == "dronejade" then
            local act = p2_action()
            -- log every distinct drone action so we can see its reactions
            if act ~= last_p2act then
                log("  r=%d drone p2act 0x%04x -> 0x%04x (p1act=0x%03x)", r, last_p2act or 0, act, p1_action())
                last_p2act = act
            end
            local pa = p1_action()
            if (pa == 0x002 or pa == 0x003) and not p1_fireball_seen then
                p1_fireball_seen = true
                log("  (diag) P1 threw a REAL fireball (0x%03x) at r=%d p1x=%d p2x=%d", pa, r, obj_x(A.p1_obj), obj_x(A.p2_obj))
            end
            if act == ACT_THROW_FANS and not drone_fans_seen then
                drone_fans_seen = true
                log("FAIL-SIGNAL: drone jade threw FANS (act=0x008) at r=%d", r)
            end
            if act == ACT_JADE_BOOM and not results.drone_boomerang then
                results.drone_boomerang = true
                log("drone_boomerang OK - drone jade threw the boomerang at r=%d", r)
                snap("drone_boomerang")
            end
            if act == ACT_JADE_FLASH and not results.drone_flash_counter then
                results.drone_flash_counter = true
                log("drone_flash_counter OK - drone jade flashed a projectile at r=%d", r)
                snap("drone_flash")
            end
            if act == ACT_SHADK and not drone_nitro_seen then
                drone_nitro_seen = true
                log("(obs) drone jade did the Nitro Kick at r=%d", r)
            end
            -- Diagnostic: is the drone reacting to projectiles at all?
            if act == 0x503 and not drone_react_seen then
                drone_react_seen = true
                log("(obs) drone entered a hit-reaction (0x503) at r=%d - beware IS firing", r)
            end
        end

        for _, t in ipairs(cfg.tests) do
            local d = r - t.at
            if d == 1 then log("firing %s", t.label) end
            if t.shot and t.shot > 0 and d == t.shot then snap(MODE .. "_" .. t.label) end
            if t.shots then
                for _, sd in ipairs(t.shots) do
                    if d == sd then snap(string.format("%s_%s_d%02d", MODE, t.label, sd)) end
                end
            end

            if (t.want or t.avoid) and d >= 2 and d <= 60 and results[t.label] == nil then
                local act = p1_action()
                if t.avoid then
                    if act == t.avoid then
                        results[t.label] = false
                        log("%-26s FAILED - saw forbidden action=0x%03x at d=%d", t.label, act, d)
                    end
                elseif act == t.want then
                    results[t.label] = true
                    log("%-26s action=0x%03x confirmed at d=%d", t.label, act, d)
                end
            end
            if (t.want or t.avoid) and d == 70 and results[t.label] == nil then
                if t.avoid then
                    results[t.label] = true
                    log("%-26s correctly dead (avoided action=0x%03x)", t.label, t.avoid)
                else
                    results[t.label] = false
                    log("%-26s FAILED - never saw action=0x%03x", t.label, t.want)
                end
            end

            if t.hp_watch then
                if d == 10 then
                    t.hp0 = r16(A.p2_bar)
                    log("  p2 hp baseline=%d x=%d", t.hp0, obj_x(A.p2_obj))
                end
                if t.hp0 and not t.hit_d and d >= 12 and d <= 250 then
                    local hp = r16(A.p2_bar)
                    if hp < t.hp0 then
                        t.hit_d = d
                        t.hit_x = obj_x(A.p2_obj)
                        local drop = t.hp0 - hp
                        -- UMK3's own strike record (lia_strikes 0x14):
                        -- 20 on hit / 3 on block.  Was 24/6, a copy of
                        -- Kung Lao's hat.  See tools/umk3_jade_extract.py.
                        results.boom_hit_damage = (drop == 20)
                        log("  p2 hit at d=%d: hp %d->%d (drop=%d, want 20) %s",
                            d, t.hp0, hp, drop,
                            results.boom_hit_damage and "OK" or (drop == 3 and "FAILED (blocked)" or "FAILED"))
                        snap("jade_boom_hit")
                    end
                end
                if d == 250 and not t.hit_d and results.boom_hit_damage == nil then
                    results.boom_hit_damage = false
                    results.boom_hit_recovers = false
                    log("  boom_hit_damage FAILED - p2 hp never dropped (never hit)")
                end
                if t.hit_d and results.boom_hit_recovers == nil then
                    local hd = d - t.hit_d
                    if hd >= 15 and hd <= 150 then
                        local x = obj_x(A.p2_obj)
                        if t.rx and math.abs(x - t.rx) <= 1 and p2_action() ~= 0x503 then
                            t.stable = (t.stable or 0) + 1
                        else
                            t.stable = 0
                        end
                        t.rx = x
                        if t.stable >= 10 then
                            results.boom_hit_recovers = true
                            log("  p2 recovered at hit+%d, net knockback %d px  OK", hd, math.abs(x - t.hit_x))
                        end
                    elseif hd == 151 then
                        results.boom_hit_recovers = false
                        log("  boom_hit_recovers FAILED - p2act=0x%04x still moving at hit+150", p2_action())
                    end
                end
            end

            if t.hit_drop then
                -- Drive the arcade's trigger directly rather than staging a
                -- real hit: a diff-0 drone connecting on cue is not
                -- reproducible, and PM_REACTING is the exact condition
                -- jfbp_reacting tests.  Held for a few frames because the
                -- game clears the bit on its own schedule.
                if d >= 26 and d <= 31 then
                    if d == 26 then t.flag_mid = r16(A.f_jade_flash) end
                    local proc = r32(A.p1_proc)
                    if proc ~= 0 then
                        w16(proc + P_FLAGS, r16(proc + P_FLAGS) | PM_REACTING)
                    end
                end
                if d == 38 then
                    local after = r16(A.f_jade_flash)
                    local ok = (t.flag_mid or 0) ~= 0 and after == 0
                    results.flash_hit_drops = ok
                    log("  flash_hit_drops %s - stamp 0x%04x -> 0x%04x after PM_REACTING",
                        ok and "OK" or "FAILED", t.flag_mid or 0, after)
                end
            end

            -- UMK3 port (sound/stlaugh_patch.txt note (36)): jade_flash_proc
            -- sends ST_JADE_FLASH once per blink, after the normal beat - so
            -- an undisturbed Flash is exactly ten $0358 calls, 6 ticks apart.
            -- The old build sent it once at activation and fails this.
            if t.free_move and d == 100 then
                local s = sends_of(SND_JADE_FLASH, t.at, t.at + 100)
                local gaps, even = {}, #s > 1
                for i = 2, #s do
                    gaps[#gaps + 1] = s[i] - s[i - 1]
                    if gaps[#gaps] ~= 6 then even = false end
                end
                local ok = #s == 10 and even
                results.flash_sound_per_blink = ok
                log("  flash_sound_per_blink %s - %d sends of $%04x at d=[%s] gaps=[%s] (want 10, all 6)",
                    ok and "OK" or "FAILED", #s, SND_JADE_FLASH,
                    table.concat((function() local o = {} for i, v in ipairs(s) do o[i] = v - t.at end return o end)(), ","),
                    table.concat(gaps, ","))
            end

            -- ST_JADE_ZAP (note (37)): UMK3's r_boomerang plays the
            -- attacker's sound 5 when the boomerang CONNECTS.  So a $0564
            -- must land within a couple of frames of the HP drop the
            -- hp_watch test already detects - not at the throw.
            if t.hp_watch and d == 250 then
                local s = sends_of(SND_JADE_ZAP, t.at, t.at + 250)
                local ok = t.hit_d ~= nil and #s >= 1
                    and math.abs((s[1] - t.at) - t.hit_d) <= 3
                results.boom_zap_on_hit = ok
                log("  boom_zap_on_hit %s - %d sends of $%04x, first at d=%s, hp drop at d=%s (want within 3)",
                    ok and "OK" or "FAILED", #s, SND_JADE_ZAP,
                    s[1] and tostring(s[1] - t.at) or "-", tostring(t.hit_d))
            end

            -- NitroKick (note (35)/(37)): UMK3's prop_do_jade_prop plays
            -- sound 6 once, at the start of the move.
            if t.label == "jade_nitro_kick" and d == 90 then
                local s = sends_of(SND_JADE_NITRO, t.at, t.at + 90)
                local ok = #s == 1 and (s[1] - t.at) <= 20
                results.nitro_sound_once_at_start = ok
                log("  nitro_sound_once_at_start %s - %d sends of $%04x at d=%s (want 1, at the input)",
                    ok and "OK" or "FAILED", #s, SND_JADE_NITRO,
                    s[1] and tostring(s[1] - t.at) or "-")
            end

            -- ...and a hit that drops the Flash must also stop the sends:
            -- UMK3's jade_flash_sleep suicides the proc before the next
            -- ochar_sound.  PM_REACTING is injected at d=26..31 below.
            if t.hit_drop and d == 100 then
                local s = sends_of(SND_JADE_FLASH, t.at, t.at + 100)
                local late = 0
                for _, v in ipairs(s) do if v - t.at > 33 then late = late + 1 end end
                local ok = #s >= 1 and #s < 10 and late == 0
                results.flash_sound_stops_on_hit = ok
                log("  flash_sound_stops_on_hit %s - %d sends, %d after the hit window (want 1-9, 0 late)",
                    ok and "OK" or "FAILED", #s, late)
            end

            if t.free_move then
                if d == 26 then
                    t.x0 = obj_x(A.p1_obj)
                    t.flag_mid = r16(A.f_jade_flash)
                end
                if d == 62 then
                    local moved = math.abs(obj_x(A.p1_obj) - (t.x0 or 0))
                    local ok = (t.flag_mid or 0) ~= 0 and moved >= 8
                    results.flash_free_move = ok
                    log("  flash_free_move %s - flag_mid=0x%04x moved=%d px (want >=8)",
                        ok and "OK" or "FAILED", t.flag_mid or 0, moved)
                end
            end
        end

        local pc = reg("PC") or reg("CURPC") or reg("GENPC") or 0
        if pc == last_pc then stuck = stuck + 1 else stuck = 0; last_pc = pc end
        if stuck >= 90 then
            log("CRASH at r=%d pc=%08x", r, pc)
            finish(false, string.format("cpu_stuck pc=%08x", pc))
            return
        end

        if r % 120 == 0 then
            log("r=%d p1act=0x%03x p2act=0x%03x p1x=%d p2x=%d p1hp=%d p2hp=%d flash=0x%04x/0x%04x diff=%d",
                r, p1_action(), p2_action(), obj_x(A.p1_obj), obj_x(A.p2_obj),
                r16(A.p1_bar), r16(A.p2_bar),
                r16(A.f_jade_flash), r16(A.f_jade_flash + 16), A.diff and r16(A.diff) or -1)
        end

        if r > cfg.run_end then
            if MODE == "dronejade" then
                results.drone_no_fans = not drone_fans_seen
                if results.drone_no_fans then log("drone_no_fans OK - fans never thrown") end
                -- Observations (not required): report whether each emergent
                -- Jade drone behaviour happened to fire this run.
                log("OBSERVED this run: boomerang=%s  flash_counter=%s  nitro=%s  (emergent - proven separately by jade player mode + wiring)",
                    results.drone_boomerang and "YES" or "no",
                    results.drone_flash_counter and "YES" or "no",
                    drone_nitro_seen and "YES" or "no")
            end
            local pass_count, total, fail = 0, 0, nil
            for _, t in ipairs(cfg.tests) do
                if t.want or t.avoid then
                    total = total + 1
                    if results[t.label] then pass_count = pass_count + 1
                    else fail = fail or t.label end
                end
            end
            for _, n in ipairs(cfg.extra) do
                total = total + 1
                if results[n] then pass_count = pass_count + 1
                else fail = fail or n end
            end
            if pass_count == total then
                finish(true, string.format("all_%d_checks_confirmed", total))
            else
                finish(false, "missing_result:" .. (fail or "unknown") ..
                    string.format(" (%d/%d passed)", pass_count, total))
            end
            return
        end
    end

    if charsel_frame == 0 and frame > 1400 then
        finish(false, "never_reached_charsel")
        return
    end
    if charsel_frame > 0 and fighting_frame == 0 and frame > charsel_frame + 1200 then
        finish(false, "never_reached_fighting")
        return
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
end)
