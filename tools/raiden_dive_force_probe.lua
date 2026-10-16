-- raiden_dive_force_probe.lua - fire Raiden's torpedo on purpose and watch
-- which of the two yells the ROM actually sends.
--
-- do_raiden_dive (MKPROP.ASM) calls raiden_dive_random_yell, which picks at
-- random between two entries of triple_sndtab - $79 and $7B.  The table is
-- source; what the running game puts on the sound latch is evidence.  The
-- drone will not settle it: two sweep runs, 12,000 frames of a CPU Raiden,
-- sent 647 codes and never once chose the torpedo.  So this drives the input.
--
-- WATCH THE TRACK, NOT THE INDEX.  Measured here, not assumed: on every dive
-- this rig forced, the code on the latch was $02B4 - the DCS TRACK.  The
-- source sends a triple_sndtab index ($79/$7B, raiden_dive_random_yell,
-- MKPROP.ASM) and triple_sound resolves it to the track before it reaches the
-- port, so the index never appears on the wire.  A run watching 79,7b sees
-- nothing while the dive is plainly yelling.
--
-- Two-player game, P1 Raiden vs an idle P2 Jax, both bars pinned, on
-- RDF_STAGE.  Each trial pins the pair RDF_GAP apart and drives scom_rd_dive:
-- Up to leave the ground, then Back, Back, Forward on the stick alone -
-- rd_left_right takes no button, it only refuses one (Block).  It
-- keeps going until it has seen BOTH codes or RDF_TRIALS is used up, so the
-- two-take random pick gets a chance to show itself.
--
-- PASS: both takes ($02AE and $02B4) observed, each during a dive.
--
-- env: RDF_TRIALS (default 24), RDF_GAP (380), RDF_STAGE (0), RDF_LOG, MK2_ROOT
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local TRIALS = tonumber(os.getenv("RDF_TRIALS") or "24")
local GAP = tonumber(os.getenv("RDF_GAP") or "380")
local STAGE = tonumber(os.getenv("RDF_STAGE") or "0")
local LOG = os.getenv("RDF_LOG") or (ROOT .. "/tools/raiden_dive_force_probe.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rdf] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"), p1_proc = sym("p1_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
}
local OXVAL, OXPOS, OYPOS, PROC_ACTION = 0x080, 0x090, 0x0b0, 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAXBAR = 0xa1
local FT_RAIDEN, FT_JAX = 7, 11
local ACT_DIVE = 0x0209          -- act_dive (MAINEQU.ASM); logged, not required
local SND_PORT = 0x01d01030
local SND_TAP_LO, SND_TAP_HI = 0x01d00000, 0x01d01fff
local YELL = { [0x2ae] = true, [0x2b4] = true }

local space, frame, charsel_frame, fighting_frame, confirm = nil, 0, 0, 0, 0
local trial, phase_at, fields = 0, 0, {}
local seen, sends, finished, dived = {}, 0, false, false
local snd_hi, tap = nil, nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function objx(ptr) local o = r32(ptr); if o == 0 then return nil end; return s16(r16(o + OXPOS)) end
local function objy(ptr) local o = r32(ptr); if o == 0 then return nil end; return s16(r16(o + OYPOS)) end
local function pin(ptr, x)
    local o = r32(ptr); if o == 0 then return end
    w32(o + OXVAL, (x & 0xffff) << 16); w16(o + OXPOS, x)
end
local function p1_action() local p = r32(A.p1_proc); return p ~= 0 and r16(p + PROC_ACTION) or 0xffff end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true, ["P1 Low Kick"] = true,
                   ["P1 Up"] = true, ["P1 Left"] = true, ["P1 Right"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input %s", n) end end
end

-- The gesture, in ticks from the start of a trial.  Same shape and the same
-- reasoning as bike_ghost_test.lua's dive trial (that rig is dead on this
-- build - it reads gh_src, and the ghost trails were removed from the ROM).
-- P2 is pinned to P1's right, so Back is Left.
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return (name == "P1 High Punch" or name == "P2 High Punch")
            and confirm > 0 and frame >= confirm and frame < confirm + 40
    end
    if trial == 0 then return false end
    local rel = frame - phase_at
    if name == "P1 Up" then return rel >= 20 and rel < 25 end
    -- Back, Back, Forward inside the 32-tick window, all of it while he is off
    -- the ground: the gesture is STICK ONLY.  rd_left_right (MOVES.ASM) masks
    -- f1b2/f2b2 - Block - and takes no attack button at all, so the Low Kick
    -- press this rig started with was never part of it.
    if name == "P1 Left" then return (rel >= 28 and rel < 32) or (rel >= 35 and rel < 39) end
    if name == "P1 Right" then return rel >= 42 and rel < 47 end
    return false
end

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
    sends = sends + 1
    -- everything that goes out while a trial's gesture is live, so a yell that
    -- is not one of the two watched codes still shows itself
    if trial > 0 and frame - phase_at >= 20 and frame - phase_at <= 95 then
        log("snd trial=%d rel=%d $%04x action=%04x", trial, frame - phase_at, code, p1_action())
    end
    if YELL[code] then
        seen[code] = (seen[code] or 0) + 1
        log("YELL $%04x trial=%d rel=%d action=%04x y=%s   <-- torpedo", code, trial,
            frame - phase_at, p1_action(), tostring(objy(A.p1_obj)))
    end
    return data
end

local function finish(why)
    if finished then return end
    finished = true
    local a, b = seen[0x2ae] or 0, seen[0x2b4] or 0
    local ok = a > 0 and b > 0
    log("RESULT %s $02AE x%d  $02B4 x%d  act_dive_seen=%s trials=%d sends=%d (%s)",
        ok and "PASS" or "FAIL", a, b, tostring(dived), trial, sends, why)
    logfh:close()
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        local ok, err = pcall(function()
            tap = space:install_write_tap(SND_TAP_LO, SND_TAP_HI, "rdf_snd", on_sound_write)
        end)
        log("start stage=%d gap=%d trials=%d tap=%s", STAGE, GAP, TRIALS,
            (ok and tap) and "installed" or ("FAILED: " .. tostring(err)))
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX)
        w16(A.curback, STAGE); w16(A.map_position, 0); w16(A.battle_num, 1)
        if confirm == 0 and frame - charsel_frame > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        trial, phase_at = 1, frame
        log("fight at frame=%d p1x=%s p2x=%s", frame, tostring(objx(A.p1_obj)), tostring(objx(A.p2_obj)))
    end
    if fighting_frame == 0 then
        if frame > 7000 then finish("never reached the fight") end
        return
    end

    -- nobody wins, nobody dies: this runs for as many dives as it takes
    w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
    w16(A.p1_bar_view, MAXBAR); w16(A.p2_bar_view, MAXBAR)
    w16(A.winner_status, 0)

    if p1_action() == ACT_DIVE then dived = true end
    local rel = frame - phase_at
    if rel < 20 then          -- place them while he is still on the floor
        local x1 = objx(A.p1_obj) or 300
        pin(A.p1_obj, x1); pin(A.p2_obj, x1 + GAP)
    end
    if rel == 90 then
        log("trial=%d done action=%04x%s y=%s seen=%d/%d", trial, p1_action(),
            p1_action() == ACT_DIVE and " (act_dive)" or "",
            tostring(objy(A.p1_obj)), seen[0x2ae] or 0, seen[0x2b4] or 0)
    end
    if rel >= 110 then
        if (seen[0x2ae] or 0) > 0 and (seen[0x2b4] or 0) > 0 then finish("both takes seen") return end
        trial = trial + 1
        phase_at = frame
        if trial > TRIALS then finish("trials used up") end
    end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:close() end) end end)
