-- wolf_sindel_specials.lua - UMK3 SINDEL's specials on the Wolf build (ochar 21).
--
-- 2-player game, P1 forced to ochar 21 at the select screen, v an idle Jax.
-- Each special is thrown SS_TRIALS times, the pair reset to a set gap first:
--   FIREBALL  Forward, Forward + LP      P1 act_throw_fans (0008h), Jax's bar drops
--   SCREAM    Forward, Forward, Fwd + HP P1 act_sonic (012ch); Jax is HELD
--             (act_reacting 0503h) for 60-200 frames - and LET GO - and loses NO health
--   AIRZAP    jump, then Down, Fwd + LK  P1 0008h while off the floor, bar drops
--   FLY       Back, Back, Forward + HK   she is 40+ px up for 120+ frames, then
--             Block brings her down inside 90
-- illop_count must never move.  Snapshots of each trial's middle go to snap/.
-- Env: WB_LOG, WS_MAP, SS_TRIALS (2), SS_ONLY=NAME,..., SS_TRACE=NAME.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
                    "curback", "illop_count", "p1_bar", "p2_bar", "worldtlx", "ground_y", "f_freeze_timer"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, ochar = 0x1f0 }
local TRIALS = tonumber(os.getenv("SS_TRIALS") or "2")
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 Block", "P1 Down", "P1 Left", "P1 Right", "P1 Up", "P1 High Kick", "P1 Low Kick", "P2 Block"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local R = "P1 Right"
local SPECIALS = {
    { name = "FIREBALL", gap = 200, watch = 150,
      seq = { {4, {R}}, {3, {}}, {4, {R}}, {4, {"P1 Low Punch"}} } },
    { name = "SCREAM", gap = 120, watch = 280,
      seq = { {4, {R}}, {3, {}}, {4, {R}}, {3, {}}, {4, {R}}, {4, {"P1 High Punch"}} } },
    { name = "AIRZAP", gap = 150, watch = 200,
      seq = { {6, {"P1 Up"}}, {16, {}}, {4, {"P1 Down"}}, {3, {"P1 Down", R}}, {3, {R}}, {4, {"P1 Low Kick"}} } },
    -- the same from a FORWARD jump, at a human's pace
    { name = "AIRZAPF", gap = 260, watch = 200,
      seq = { {6, {"P1 Up", R}}, {12, {}}, {5, {"P1 Down"}}, {4, {"P1 Down", R}}, {4, {R}}, {5, {"P1 Low Kick"}} } },
    -- the same by hand at the edges of a jump: straight off the floor, and late
    { name = "AIRZAPE", gap = 260, watch = 200,
      seq = { {5, {"P1 Up", R}}, {2, {}}, {4, {"P1 Down"}}, {4, {R}}, {5, {"P1 Low Kick"}} } },
    { name = "AIRZAPL", gap = 260, watch = 200,
      seq = { {5, {"P1 Up", R}}, {24, {}}, {4, {"P1 Down"}}, {4, {R}}, {5, {"P1 Low Kick"}} } },
    -- CONTROL: the motion on the floor must not throw it (a low kick comes out)
    { name = "GNDZAP", gap = 260, watch = 120, nohit = 1,
      seq = { {4, {"P1 Down"}}, {3, {}}, {4, {R}}, {5, {"P1 Low Kick"}} } },
    { name = "FLY", gap = 200, watch = 330,
      seq = { {4, {"P1 Left"}}, {3, {}}, {4, {"P1 Left"}}, {3, {}}, {4, {R}}, {4, {"P1 High Kick"}} } },
    -- her close normals, on the lanes UMK3 lays out for dial-a-combos: each must
    -- hit and she must be back in her stance inside 90 frames
    { name = "SCREAMFAR", gap = 260, watch = 200, nohit = 1,
      seq = { {4, {R}}, {3, {}}, {4, {R}}, {3, {}}, {4, {R}}, {4, {"P1 High Punch"}} } },
    { name = "SCREAMBLK", gap = 120, watch = 200, nohit = 1, p2block = 1,
      seq = { {4, {R}}, {3, {}}, {4, {R}}, {3, {}}, {4, {R}}, {4, {"P1 High Punch"}} } },
    -- Block tapped three times must do NOTHING but block
    { name = "BLOCK3", gap = 200, watch = 120, nohit = 1, quiet = 1,
      seq = { {5, {"P1 Block"}}, {5, {}}, {5, {"P1 Block"}}, {5, {}}, {5, {"P1 Block"}}, {5, {}} } },
    -- the air fireball thrown WHILE LEVITATING
    { name = "FLYZAP", gap = 220, watch = 260,
      seq = { {4, {"P1 Left"}}, {3, {}}, {4, {"P1 Left"}}, {3, {}}, {4, {R}}, {4, {"P1 High Kick"}}, {90, {}},
              {5, {"P1 Down"}}, {4, {"P1 Down", R}}, {4, {R}}, {5, {"P1 Low Kick"}} } },
    { name = "KNEE", gap = 52, watch = 160, seq = { {5, {"P1 High Kick"}} } },
    { name = "ELBOW", gap = 52, watch = 160, seq = { {5, {"P1 High Punch"}} } },
    { name = "KNEEMISS", gap = 52, watch = 160, far = 1, seq = { {5, {"P1 High Kick"}} } },
}
if os.getenv("SS_ONLY") then
    local keep = {}
    for _, sp in ipairs(SPECIALS) do
        if (","..os.getenv("SS_ONLY")..","):find(","..sp.name..",", 1, true) then keep[#keep + 1] = sp end
    end
    SPECIALS = keep
end
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local phase, t0, sp_i, trial, seq_i, seq_t = "reset", 0, 1, 1, 1, 0
local res = {}
local m = {}

local function place(gap)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local cam = s16(r16(A.worldtlx + 16))
    local x1 = cam + 100
    w16(p1o + O.oxpos, x1); w32(p1o + O.oxval, (x1 << 16) & 0xffffffff)
    w16(p2o + O.oxpos, x1 + gap); w32(p2o + O.oxval, ((x1 + gap) << 16) & 0xffffffff)
end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 21); w16(A.p2_char, 11); w16(A.curback, 0)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); t0 = frame + 100; log("fight at %d", frame) end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    if r16(A.illop_count) ~= ill0 then
        log("FAIL illop_count moved (a reboot): illop_pc %08X, %s act %04X", S.illop_pc and r32(S.illop_pc) or 0,
            SPECIALS[sp_i] and SPECIALS[sp_i].name or "?", r16(r32(A.p1_proc) + 0x1f0))
        f:close(); manager.machine:exit(); return
    end
    w16(A.f_freeze_timer, 1)                   -- the round clock must not end the run
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 or frame < t0 then return end
    if r16(p1o + O.ochar) ~= 21 then log("FAIL P1 is ochar %d", r16(p1o + O.ochar)); f:close(); manager.machine:exit(); return end
    local act = r16(r32(A.p1_proc) + 0x1f0)
    local act2 = r16(r32(A.p2_proc) + 0x1f0)
    w16(A.p1_bar, 0xa1)
    local rel = frame - t0
    local sp = SPECIALS[sp_i]
    if sp.p2block then F["P2 Block"]:set_value(1) end
    local up = s16(r16(A.ground_y)) - s16(r16(p1o + O.oypos))      -- distance_from_ground
    if phase == "reset" then
        -- a trial that left her LEVITATING (she hovers until told): Block to land
        if act == 0x030B and rel < 60 and rel % 12 < 6 then F["P1 Block"]:set_value(1) end
        place(sp.gap)
        w16(A.p2_bar, 0xa1)
        if rel >= 110 then
            phase = "input"; t0 = frame; seq_i, seq_t = 1, 0
            m = { saw = false, hit = 0, bar0 = 0xa1, held = 0, air = false, high = 0, stand = up, landed = nil }
        end
        return
    end
    if phase == "input" then
        m.acts = m.acts or {}
        if m.acts[#m.acts - 1] ~= act then m.acts[#m.acts + 1] = act; m.acts[#m.acts + 1] = -(#m.acts) end
        if act == 0x0008 then m.saw = true; if up > m.stand + 20 then m.air = true end end
        if os.getenv("SS_FILM") and trial == 1 and rel % 3 == 0 then manager.machine.video:snapshot() end
        local st = sp.seq[seq_i]
        for _, n in ipairs(st[2]) do F[n]:set_value(1) end
        seq_t = seq_t + 1
        if seq_t >= st[1] then seq_i = seq_i + 1; seq_t = 0 end
        if seq_i > #sp.seq then phase = "watch"; t0 = frame end
        return
    end
    -- watch
    if os.getenv("SS_TRACE") == sp.name and rel % 3 == 0 then
        log("  %s+%d p1 %04X up %d  p2 %04X bar %d gap %d", sp.name, rel, act, up, act2, r16(A.p2_bar),
            s16(r16(p2o + O.oxpos)) - s16(r16(p1o + O.oxpos)))
    end
    if sp.far and rel == 3 then                -- he steps out: the move whiffs
        local x = s16(r16(p2o + O.oxpos)) + 120
        w16(p2o + O.oxpos, x); w32(p2o + O.oxval, (x << 16) & 0xffffffff)
    end
    if act ~= 0x0303 and act ~= 0 then m.busy = rel end
    m.acts = m.acts or {}
    if m.acts[#m.acts] ~= act then m.acts[#m.acts + 1] = act; m.acts[#m.acts + 1] = rel end
    local want = (sp.name:sub(1, 6) == "SCREAM") and 0x012c or 0x0008
    if act == want then m.saw = true; if up > m.stand + 20 then m.air = true end end
    if act2 == 0x0503 then m.held = m.held + 1 end
    if up > m.stand + 40 then m.high = m.high + 1 end
    local b = r16(A.p2_bar)
    if b < m.bar0 then m.hit = m.bar0 - b end
    if sp.name == "FLY" then
        if rel >= 200 and rel < 215 then F["P1 Block"]:set_value(1) end
        if rel >= 215 and not m.landed and up <= m.stand + 4 then m.landed = rel - 215 end
    end
    if os.getenv("SS_FILM") then
        if trial == 1 and rel % 3 == 0 and rel <= tonumber(os.getenv("SS_FILM")) then manager.machine.video:snapshot() end
    elseif rel == 16 or rel == 40 or (sp.name == "FLY" and rel == 120) then manager.machine.video:snapshot() end
    if rel >= sp.watch then
        local ok, what
        if sp.name == "FIREBALL" then
            ok = m.saw and m.hit > 0; what = string.format("thrown %s, Jax took %d", tostring(m.saw), m.hit)
        elseif sp.name == "SCREAM" then
            ok = m.saw and m.held >= 60 and m.held <= 200 and m.hit == 0
            what = string.format("screamed %s, Jax held %d frames, took %d", tostring(m.saw), m.held, m.hit)
        elseif sp.name == "AIRZAPE" or sp.name == "AIRZAPL" then
            ok = m.saw
            what = string.format("thrown %s (off the floor %s), Jax took %d", tostring(m.saw), tostring(m.air), m.hit)
        elseif sp.name == "GNDZAP" then
            ok = not m.saw
            what = string.format("thrown %s - must be false on the floor", tostring(m.saw))
        elseif sp.name == "AIRZAP" or sp.name == "AIRZAPF" then
            ok = m.saw and m.air and m.hit > 0
            what = string.format("thrown %s in the air %s, Jax took %d", tostring(m.saw), tostring(m.air), m.hit)
        elseif sp.name == "FLYZAP" then
            local t, last = {}, nil
            for i = 1, #m.acts, 2 do
                if m.acts[i] ~= last then t[#t + 1] = string.format("%04X@%d", m.acts[i], m.acts[i + 1]); last = m.acts[i] end
            end
            ok = m.saw and m.air
            what = string.format("thrown %s in the air %s, Jax took %d: %s", tostring(m.saw), tostring(m.air), m.hit, table.concat(t, " "))
        elseif sp.quiet then
            local t, last, badact = {}, nil, false
            for i = 1, #m.acts, 2 do
                local a = m.acts[i]
                if a ~= last then t[#t + 1] = string.format("%04X@%d", a, m.acts[i + 1]); last = a end
                if a ~= 0x0303 and a ~= 0 and a ~= 0x0700 then badact = true end
            end
            ok = not badact
            what = "actions: " .. table.concat(t, " ")
        elseif sp.nohit then
            local t, last = {}, nil
            for i = 1, #m.acts, 2 do
                if m.acts[i] ~= last then t[#t + 1] = string.format("%04X@%d", m.acts[i], m.acts[i + 1]); last = m.acts[i] end
            end
            ok = m.saw and (m.busy or 0) <= 150
            what = string.format("screamed %s, busy until +%d: %s", tostring(m.saw), m.busy or 0, table.concat(t, " "))
        elseif sp.name == "KNEE" or sp.name == "ELBOW" or sp.name == "KNEEMISS" then
            local t = {}
            for i = 1, #m.acts, 2 do t[#t + 1] = string.format("%04X@%d", m.acts[i], m.acts[i + 1]) end
            ok = (sp.far or m.hit > 0) and (m.busy or 0) <= 90
            what = string.format("Jax took %d, busy until +%d: %s", m.hit, m.busy or 0, table.concat(t, " "))
        else
            ok = m.high >= 120 and m.landed ~= nil and m.landed <= 90
            what = string.format("aloft %d frames, landed %s after Block", m.high, tostring(m.landed))
        end
        log("%s trial %d: %s - %s", sp.name, trial, what, ok and "ok" or "BAD")
        res[#res + 1] = ok
        trial = trial + 1
        if trial > TRIALS then trial = 1; sp_i = sp_i + 1 end
        if sp_i > #SPECIALS then
            local n = 0
            for _, r in ipairs(res) do if r then n = n + 1 end end
            log("%d of %d trials good", n, #res)
            log(n == #res and "PASS" or "FAIL")
            f:close(); manager.machine:exit(); return
        end
        phase = "reset"; t0 = frame
    end
end)
