-- rain_air_super_test.lua
--
-- RAIN's roundhouse IS the super (user's call 2026-09-22, MK Trilogy's own
-- wiring): BACK + HIGH KICK, on the ground or against a man in the air, and
-- no second button.  This rig proves the AIR case - the one the user asked
-- about - by making Jax jump and swinging at him: rain_roundhouse must run
-- (l_roundh re-stamped, act_rhouse) whether or not the low kick is also
-- pressed.
--
-- 2-player game so the rig can make Jax jump: P1 = Rain (his base, Scorpion,
-- picked at the select screen and overwritten at GS_POST), P2 = Jax.  Each
-- trial parks them `gap` apart, P2 jumps straight up (P2 Up), and at `at`
-- frames into the jump P1 plays his input.  The super is taken when l_roundh
-- (P1's word) is re-stamped - rain_roundhouse's update_tsl - and his action is
-- act_rhouse.
--
--   airhk    Back+HK, Jax mid-jump    -> the super (stamped)
--   ground   Back+HK, Jax standing     -> the super (stamped)
--   air      Back+HK+LK, Jax mid-jump  -> the low kick may win the scan and
--            give the sweep, so this one is not judged on the stamp
--
-- Trials are 200 frames apart, past rain_rh_cool (80), so the cooldown never
-- refuses one.
--
--   RAS_LOG   log path     RAS_MAP   a map to read instead of src/mk2.map

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("RAS_LOG") or (ROOT .. "/tools/rain_air_super_test.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[ras] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("RAS_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local A, missing = {}, false
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_obj", "p2_obj",
                     "p1_proc", "p2_proc", "l_roundh", "tick", "ground_y" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end

local O_OXPOS, O_OXVAL, O_OYPOS = 0x090, 0x080, 0x0b0
local P_ACTION = 0x1f0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_RAIN, FT_JAX, MAX_HP = 10, 19, 11, 0xa1
local ACT_RHOUSE = 0x105

-- start = frames after the fight goes live; gap = px between them;
-- jump = does P2 jump; at = frames into the trial P1 starts his input;
-- lk = press LK with the HK; want = must the super be taken
local TRIALS = {
    { start = 150, label = "air",    gap = 90, jump = true,  at = 16, lk = true,  want = nil },
    { start = 350, label = "airhk",  gap = 90, jump = true,  at = 16, lk = false, want = true },
    { start = 550, label = "ground", gap = 90, jump = false, at = 16, lk = false, want = true },
}
local WIN = 90

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local st, results, failures = {}, {}, 0

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Left"]=1, ["P1 Right"]=1,
                   ["P1 High Kick"]=1, ["P1 Low Kick"]=1, ["P2 Up"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

local function action(procsym)
    local p = r32(A[procsym]); if p == 0 then return 0 end
    return r16(p + P_ACTION)
end

local function finish()
    done = true
    log("---- results ----")
    for _, t in ipairs(TRIALS) do log("%-7s %s", t.label, results[t.label] or "NOT REACHED") end
    log("%s Back+HK is the super, in the air too (failures=%d)", failures == 0 and "PASS" or "FAIL", failures)
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
            w16(A.p1_char, FT_SCORPION)
            w16(A.p2_char, FT_JAX)
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and rel > 60 then
            confirm = frame
            for n in pairs(fields) do hold(n, false) end
        end
    else
        if gs == GS_POST then
            w16(A.p1_char, FT_RAIN)
            w16(A.p2_char, FT_JAX)
        end
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= FT_RAIN then log("P1 is not Rain"); failures = failures + 1; finish(); return end
        end
        if fight_at > 0 then
            local r = frame - fight_at
            w16(A.p1_bar, MAX_HP)
            local measuring = false
            for _, t in ipairs(TRIALS) do
                local d = r - t.start
                if d >= 0 and d <= WIN then measuring = true end
            end
            if not measuring then w16(A.p2_bar, MAX_HP) end
            for n in pairs(fields) do hold(n, false) end
            for _, t in ipairs(TRIALS) do
                local d = r - t.start
                if d >= -30 and d < 0 then
                    -- park them, P1 on the left
                    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
                    if p1o ~= 0 and p2o ~= 0 then
                        local x2 = r16(p2o + O_OXPOS)
                        place(p1o, x2 - t.gap)
                    end
                elseif d == 0 then
                    st[t.label] = { stamp0 = r16(A.l_roundh), sawrh = false, top = 999,
                                    bar0 = r16(A.p2_bar), minbar = r16(A.p2_bar), acts = {} }
                    log("%-7s start: p1 x=%d p2 x=%d", t.label, s16(r16(r32(A.p1_obj) + O_OXPOS)),
                        s16(r16(r32(A.p2_obj) + O_OXPOS)))
                elseif d > 0 and d <= WIN then
                    local s = st[t.label]
                    if t.jump and d >= 1 and d < 5 then hold("P2 Up", true) end
                    local a = t.at
                    if d >= a - 3 and d < a + 8 then hold("P1 Left", true) end      -- Back
                    if d >= a and d < a + 4 then
                        hold("P1 High Kick", true)
                        if t.lk then hold("P1 Low Kick", true) end
                    end
                    local p2o = r32(A.p2_obj)
                    local y = p2o ~= 0 and s16(r16(p2o + O_OYPOS)) or 0
                    if y < s.top then s.top = y end
                    if d == a then s.y_at_input = y; s.p2act_at_input = action("p2_proc") end
                    if action("p1_proc") == ACT_RHOUSE then s.sawrh = true end
                    local b = r16(A.p2_bar); if b < s.minbar then s.minbar = b end
                    if d > a then
                        local pa = string.format("%04x", action("p2_proc"))
                        if s.acts[#s.acts] ~= pa then s.acts[#s.acts+1] = pa end
                    end
                    if d == WIN then
                        local stamped = r16(A.l_roundh) ~= s.stamp0
                        -- stock MK2: two kicks on one tick reach ONE handler,
                        -- so this is a roundhouse or a sweep depending on which
                        -- the scan took.  The only requirement is that it is
                        -- never the super.
                        -- want = nil: either handler is stock behaviour
                        local ok = (t.want == nil) or (stamped == t.want)
                        local line = string.format(
                            "%s roundhouse=%s super=%s (want %s)  p2 y at input=%d (top %d) p2 action=%04x | dmg=%d p2 then: %s",
                            ok and "OK  " or "FAIL", tostring(s.sawrh), tostring(stamped), tostring(t.want),
                            s.y_at_input or -1, s.top, s.p2act_at_input or 0, s.bar0 - s.minbar,
                            table.concat(s.acts, ">"))
                        results[t.label] = line
                        if not ok then failures = failures + 1 end
                        log("%-7s %s", t.label, line)
                    end
                end
            end
            if r > 700 then finish(); return end
        end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 12000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
