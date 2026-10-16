-- rain_halfdmg_probe.lua
--
-- COMBO DAMAGE PROTECTION (rhhalf, MAINEQU.ASM) - MK2's equivalent of MK
-- Trilogy's M_HALF_DAMAGE, which `r_rain_roundhouse` (MKREACT.C:2782) arms
-- once a string has taken more than 30% of a bar:
--
--     ta10 = p_damage*100/FULL_STRENGTH;  if (ta10>30) set_half_damage(pa8);
--
-- Here: `rh_cdmg` is the damage the victim has taken this string, `rh_half`
-- the flag, `rh_half_dmg` the threshold (48 = 30% of 0a1h, so 49 arms it).
--
-- A real string that takes 49+ off a bar is hard to drive from a rig and
-- would prove the COMBO rather than the protection, so this SEEDS rh_cdmg
-- instead - the flag's whole input - and then plays one real roundhouse:
--
--   arm     rh_cdmg = 60 (over the threshold): the hit must ARM rh_half
--   noarm   rh_cdmg = 10 (under it):           rh_half must stay 0
--   edge    rh_cdmg = 48 (exactly 30%):        must NOT arm - Trilogy needs
--                                              strictly more than 30%
--   clear   armed, then let him return to neutral: back_to_normal must put
--           rh_half AND rh_cdmg back to 0
--
-- The halving itself is measured as an A/B, not against a modelled number:
-- the same second kick at the same delay is thrown in `arm` and in `noarm`,
-- and armed damage must be half of unarmed (bar_reducer floors it at 1).
-- That way dmgscale's own 3/4 cannot be mistaken for this.
--
-- 2P game: P1 = Rain (base Scorpion, p1_char overwritten at GS_POST),
-- P2 = Jax, idle.
--
--   RH_LOG  log path        RH_MAP  a map to read instead of src/mk2.map

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("RH_LOG") or (ROOT .. "/tools/rain_halfdmg_probe.log")
local GAP  = tonumber(os.getenv("RH_GAP") or "80") or 80

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rh] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("RH_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local A, missing = {}, false
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj",
                     "p1_proc", "p2_proc", "rh_cdmg", "rh_half" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end
-- player 2 is the second 16-bit half of each pair, as get_tsl indexes l_roundh
local P2 = 16

local O_OXPOS, O_OXVAL = 0x090, 0x080
local P_ACTION = 0x1f0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_RAIN, FT_JAX, MAX_HP = 10, 19, 11, 0xa1
local THRESH = 48                       -- rh_half_dmg: 30% of 0a1h

-- seed = what rh_cdmg is set to just before the first kick lands;
-- want_arm = must rh_half come up?
local TRIALS = {
    { label = "arm",   seed = 60, want_arm = true,  second = true },
    { label = "noarm", seed = 10, want_arm = false, second = true },
    { label = "edge",  seed = 48, want_arm = false, second = false },
    { label = "clear", seed = 60, want_arm = true,  second = false, check_clear = true },
}

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function hold(n, on) held[n] = on and true or false end

local function cdmg() return r16(A.rh_cdmg + P2) end
local function half() return r16(A.rh_half + P2) end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local trial, phase, t0, cur = 0, "idle", 0, nil
local results = {}
local TRIAL_EVERY = 320

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Left"]=1, ["P1 Right"]=1,
                   ["P1 High Kick"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x); w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end
local function park()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    place(p1o, s16(r16(p2o + O_OXPOS)) - GAP)
end
local function action(sym)
    local p = r32(A[sym]); if p == 0 then return 0 end
    return r16(p + P_ACTION)
end

local function finish()
    done = true
    log("---- results (threshold rh_half_dmg = %d, arms above it) ----", THRESH)
    local fails, by = 0, {}
    for _, x in ipairs(results) do
        by[x.label] = x
        local ok = (x.armed == x.want_arm)
        local why = string.format("seeded %2d -> rh_half=%d (want %s)", x.seed, x.armed and 1 or 0,
            tostring(x.want_arm))
        if x.check_clear then
            local cleared = (x.after_half == 0 and x.after_cdmg == 0)
            ok = ok and cleared
            why = why .. string.format("; after he stood up: rh_half=%d rh_cdmg=%d (want 0/0)",
                x.after_half or -1, x.after_cdmg or -1)
        end
        if not ok then fails = fails + 1 end
        log("  %-6s %s  dmg1=%d%s  %s", x.label, why, x.dmg1 or 0,
            x.dmg2 and string.format(" dmg2=%d", x.dmg2) or "", ok and "OK" or "FAIL")
    end
    -- the halving itself, as an A/B of the same second kick
    local a, n = by["arm"], by["noarm"]
    if a and n and a.dmg2 and n.dmg2 and n.dmg2 > 0 then
        local want = n.dmg2 >> 1
        if want == 0 then want = 1 end
        local ok = (a.dmg2 == want)
        if not ok then fails = fails + 1 end
        log("  HALVING: armed 2nd hit %d vs unarmed %d (want %d = half of unarmed) %s",
            a.dmg2, n.dmg2, want, ok and "OK" or "FAIL")
    else
        fails = fails + 1
        log("  HALVING: NO VERDICT - one of the two second hits never landed "
            .. "(arm=%s noarm=%s), so the halving was not measured",
            a and tostring(a.dmg2) or "?", n and tostring(n.dmg2) or "?")
    end
    log("%s combo damage protection (failures=%d)", fails == 0 and "PASS" or "FAIL", fails)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        if missing then finish(); return end
    end
    frame = frame + 1
    local gs = r16(A.gstate)

    if psel == 0 and gs == GS_PSEL then
        psel = frame
        log("select screen at frame %d", frame)
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)
    elseif confirm == 0 then
        local rel = frame - psel
        if gs == GS_PSEL then
            w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8); hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and rel > 60 then
            confirm = frame
            for n in pairs(fields) do hold(n, false) end
        end
    else
        if gs == GS_POST then w16(A.p1_char, FT_RAIN); w16(A.p2_char, FT_JAX) end
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= FT_RAIN then log("P1 is not Rain"); finish(); return end
        end
        if fight_at == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        local r = frame - fight_at
        w16(A.p1_bar, MAX_HP)
        for n in pairs(fields) do hold(n, false) end
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o == 0 or p2o == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        if phase == "idle" and r >= 120 and (r - 120) % TRIAL_EVERY == 0 and trial < #TRIALS then
            trial = trial + 1
            local T = TRIALS[trial]
            w16(A.p2_bar, MAX_HP)
            w16(A.rh_half + P2, 0)
            cur = { label = T.label, seed = T.seed, want_arm = T.want_arm,
                    second = T.second, check_clear = T.check_clear, armed = false }
            phase, t0 = "park", frame
            log("trial %d (%s): seeding rh_cdmg = %d", trial, T.label, T.seed)

        elseif phase == "park" then
            park()
            if frame - t0 > 6 then
                cur.bar0 = r16(A.p2_bar)
                phase, t0 = "kick1", frame
            end

        elseif phase == "kick1" then
            local d = frame - t0
            -- hold the seed every tick until the hit lands: bar_reducer adds
            -- to rh_cdmg on the way through, so a one-shot write before the
            -- swing would be topped up by the hit itself and change the test
            if not cur.hit1 then w16(A.rh_cdmg + P2, cur.seed) end
            if d < 12 then hold("P1 Left", true) end
            if d >= 3 and d < 7 then hold("P1 High Kick", true) end
            local b = r16(A.p2_bar)
            if b < cur.bar0 and not cur.hit1 then
                cur.hit1 = true; cur.hit1_at = frame
                cur.dmg1 = cur.bar0 - b
                cur.bar1 = b
            end
            if cur.hit1 and frame - cur.hit1_at >= 3 then
                -- the reaction has had its tick: is the flag up?
                cur.armed = (half() ~= 0)
                log("  hit for %d, rh_cdmg=%d rh_half=%d", cur.dmg1, cdmg(), half())
                if cur.second then
                    phase, t0 = "hunt", frame
                elseif cur.check_clear then
                    phase, t0 = "neutral", frame
                else
                    results[#results+1] = cur; phase, t0 = "cool", frame
                end
            elseif d > 90 then
                log("  trial %s: the roundhouse never landed", cur.label)
                results[#results+1] = cur; phase, t0 = "cool", frame
            end

        elseif phase == "hunt" then
            -- one more kick, same timing in both trials, so armed vs unarmed
            -- is a like-for-like comparison
            local d = frame - t0
            park()
            local c = d % 14
            if c < 12 then hold("P1 Left", true) end
            if c >= 1 and c < 5 then hold("P1 High Kick", true) end
            local b = r16(A.p2_bar)
            if b < cur.bar1 and not cur.hit2 then
                cur.hit2 = true
                cur.dmg2 = cur.bar1 - b
                cur.gap_ticks = frame - cur.hit1_at
                log("  2nd landed %d ticks later for %d (rh_half=%d)", cur.gap_ticks,
                    cur.dmg2, half())
            end
            if cur.hit2 or d > 150 then
                if not cur.hit2 then log("  no second hit inside 150 ticks") end
                results[#results+1] = cur; phase, t0 = "cool", frame
            end

        elseif phase == "neutral" then
            -- let him get up: back_to_normal must clear both words
            local a = action("p2_proc")
            if (a == 0 or a == 0x303) and frame - t0 > 60 then
                cur.after_half = half()
                cur.after_cdmg = cdmg()
                log("  back on his feet (act=%04x): rh_half=%d rh_cdmg=%d", a,
                    cur.after_half, cur.after_cdmg)
                results[#results+1] = cur; phase, t0 = "cool", frame
            elseif frame - t0 > 260 then
                cur.after_half, cur.after_cdmg = half(), cdmg()
                log("  he never returned to neutral (act=%04x)", a)
                results[#results+1] = cur; phase, t0 = "cool", frame
            end

        elseif phase == "cool" then
            w16(A.p2_bar, MAX_HP)
            if frame - t0 > 70 then phase = "idle" end
        end

        if trial >= #TRIALS and phase == "idle" then finish(); return end
        if r > 4000 then log("ran out of time"); finish(); return end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 14000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
