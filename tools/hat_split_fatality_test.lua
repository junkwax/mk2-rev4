-- hat_split_fatality_test.lua
--
-- Kung Lao's FLYING HAT fatality, aimed.  Retail has one window: the hat has
-- to cross the victim's NECK (068h-076h above ground_y, r_hhhat in
-- MKREACT.ASM) or the fatality is cancelled and the hat is just a hat.  This
-- build adds a second window at the WAIST (hat_split_lo..hat_split_hi,
-- MAINEQU.ASM), which cuts him in half instead - the stock Reptile-invisible
-- torso rip, r_second_swipe.
--
-- The aim is the STICK.  hat_proc (MKZAP.ASM) adds 0a000h to the hat's y
-- velocity for every tick Down is held and never damps it, so the hat is
-- steered by a short press early in the flight and then coasts.  This rig
-- holds Down for HSF_DOWN ticks starting 20 ticks after the fatality begins,
-- which is when do_hat_decap -> do_throw_hat has actually let go of the hat.
--
-- ONE attempt per run.  FINISH HIM is only ~110 ticks wide and hh_lp_open
-- wants LP held for 030h of them, so a second try does not fit - the runner
-- sweeps the hold across separate runs instead.
--
-- Outcome per attempt, with no pictures needed:
--   f_death == 0ffffh    a window was hit (death_blow_complete)
--   victim RISES         r_second_swipe threw the torso - the WAIST split
--   victim stays down    decap_fall - the retail NECK decapitation
--
--   HSF_VICTIM   kitana | subzero            (default subzero)
--   HSF_DOWN     stick hold, in ticks: >0 Down (the waist), <0 Up (the neck),
--                0 no steering at all (default)
--
-- MEASURED: an un-steered hat flies level at 92 px above ground_y (Sub-Zero,
-- 0110h apart) - the chest, between the two windows.  So 0 is a CANCEL even
-- in retail; the neck needs a tap of Up and the waist a tap of Down.
--   HSF_LOG      log path

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("HSF_VICTIM") or "subzero"):lower()
local DOWN   = tonumber(os.getenv("HSF_DOWN") or "0") or 0
local LOG    = os.getenv("HSF_LOG") or
               (ROOT .. "/tools/hat_split_fatality_" .. VICTIM .. "_d" .. DOWN .. ".log")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[hsf/" .. VICTIM .. "/d" .. DOWN .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    raw(line); logfh:write(line, "\n"); logfh:flush()
end

-- ------------------------------------------------------------------ symbols
local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "p1_obj", "p2_obj", "f_death", "ground_y", "objlst" }
local A = {}
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end

-- DISPEQU.ASM object offsets, in bits - MAME's program space is bit-addressed.
local O_OXVEL, O_OXVAL, O_OXPOS, O_OYPOS = 0x040, 0x080, 0x090, 0x0b0
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_HATHEAD, FT_FN1, FT_SUBZERO = 0, 4, 8

-- hh_lo_punch (MOVES.ASM) refuses under 0100h between them, so stand well back.
local FATAL_DIST = 0x110

-- HOLD LP, Back, Forward, RELEASE LP.  hh_lp_open (MOVES.ASM) is a button
-- RELEASE handler and wants get_tsl(l_lp) >= 030h, so the hold is what the
-- 58 ticks below are for; the two taps only have to be inside scom_hh_db2's
-- 018h window when the release runs the check.  P1 is the left fighter, so
-- Back is Left.
local SEQ = { { "P1 Low Punch", 0, 58 }, { "P1 Left", 40, 45 }, { "P1 Right", 50, 55 } }

-- do_hat_decap spends 6 ticks winding up and do_throw_hat another 14 before
-- spawn_proj_proc exists, so the stick means nothing until then.
local STEER_AT = 20

local VICTIMS = {
    kitana  = { hover = FT_FN1,     want = FT_FN1     },
    subzero = { hover = FT_SUBZERO, want = FT_SUBZERO },
    -- Raiden: his head roll (a_head, MKRD.ASM) draws two frames as mirrored
    -- aliases, so the neck decap (HSF_DOWN=-2) is the flip-reuse A/B scene.
    raiden  = { hover = 7,          want = 7          },
}

-- HSF_SNAP_EVERY=N: after the hit, snapshot every N frames through rel 260 and
-- log every loose object the size of a head frame (HEAD lines), so two ROMs
-- can be compared capture by capture and by the head's osag/oflags/position.
local SNAP_EVERY = tonumber(os.getenv("HSF_SNAP_EVERY") or "0") or 0
local O_OFLAGS, O_OSAG, O_OSIZE = 0x0f0, 0x100, 0x120
local HEAD_SIZES = { ["28x26"]=1, ["32x24"]=1, ["26x28"]=1, ["24x32"]=1, ["28x27"]=1, ["24x31"]=1 }
local V = VICTIMS[VICTIM]
if not V then log("FATAL: unknown HSF_VICTIM '%s'", VICTIM); V = VICTIMS.subzero end

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, combo_at, done = 0, 0, 0, false
local phase, last_ws, snaps = "boot", -1, 0
local fatal_at = 0
local hit_at, hit_kind, victim_y0, victim_rise = 0, nil, 0, 0
local results = {}

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1,
                   ["P1 Right"]=1, ["P1 Left"]=1, ["P1 Down"]=1, ["P1 Up"]=1,
                   ["P2 Low Punch"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

local function snap_to(dist)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local x1, x2 = r16(p1o + O_OXPOS), r16(p2o + O_OXPOS)
    local mid = (x1 + x2) // 2
    place(p1o, mid - dist // 2)
    place(p2o, mid + dist - dist // 2)
end

local function gap()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return -1 end
    return r16(p2o + O_OXPOS) - r16(p1o + O_OXPOS)
end

-- How far the victim's anchor is above the floor.  r_second_swipe throws the
-- torso with flight(); decap_fall leaves him on his feet and drops him to his
-- knees, so the sign of this over the beat after the hit tells the two apart.
local function victim_height()
    local p2o = r32(A.p2_obj)
    if p2o == 0 then return 0 end
    return s16(r16(A.ground_y)) - s16(r16(p2o + O_OYPOS))
end

-- The hat: walk objlst (olink at 0) for the one object flying at hat_proc's
-- 0c0000h, either direction.  Returns its height above ground_y, or nil.
local function hat_height()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local o, n = r32(A.objlst), 0
    while o ~= 0 and n < 200 do
        if o ~= p1o and o ~= p2o then
            local v = r32(o + O_OXVEL)
            if v == 0xc0000 or v == 0xfff40000 then
                return s16(r16(A.ground_y)) - s16(r16(o + O_OYPOS)), r16(o + O_OXPOS)
            end
        end
        o = r32(o); n = n + 1
    end
    return nil
end

local function snap()
    snaps = snaps + 1
    manager.machine.video:snapshot()
end

local function head_witness(rel)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local o, n = r32(A.objlst), 0
    while o ~= 0 and n < 200 do
        if o ~= p1o and o ~= p2o then
            local w, h = r16(o + O_OSIZE), r16(o + O_OSIZE + 0x10)
            if HEAD_SIZES[w .. "x" .. h] then
                log("HEAD rel=%d osag=%08x ofl=%04x x=%d y=%d size=%dx%d",
                    rel, r32(o + O_OSAG), r16(o + O_OFLAGS),
                    s16(r16(o + O_OXPOS)), s16(r16(o + O_OYPOS)), w, h)
            end
        end
        o = r32(o); n = n + 1
    end
end

local function verdict()
    local ok, why = true, {}
    log("p1_char=%d (want %d)  p2_char=%d (want %d)",
        r16(A.p1_char), FT_HATHEAD, r16(A.p2_char), V.want)
    if r16(A.p1_char) ~= FT_HATHEAD then ok = false; why[#why+1] = "P1 is not Kung Lao" end
    if r16(A.p2_char) ~= V.want then ok = false; why[#why+1] = "P2 is not the requested victim" end
    if finish_at == 0 then ok = false; why[#why+1] = "no FINISH HIM window" end
    if #results == 0 then
        ok = false; why[#why+1] = "the fatality never started"
    else
        local r = results[1]
        log("RESULT down=%d -> %s (victim rose %d px)", r.down, r.kind, r.rise)
        local want = (DOWN == 0) and "cancelled" or (DOWN < 0 and "NECK decap" or "WAIST split")
        if r.kind ~= want then
            ok = false
            why[#why+1] = string.format("wanted %s, got %s", want, r.kind)
        end
    end
    log("%d snapshot(s) written", snaps)
    log("%s hat split on %s%s", ok and "PASS" or "FAIL", VICTIM,
        ok and "" or ("  -- " .. table.concat(why, "; ")))
end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
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
            w16(A.p1_char, FT_HATHEAD)
            w16(A.p2_char, V.hover)
        end
        if rel == 60 and phase == "boot" then phase = "post" end
        if phase == "post" and rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and phase == "post" then
            confirm = frame
            log("select done at frame %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            for n in pairs(fields) do hold(n, false) end
        end

    else
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
        end

        if fight_at > 0 and armed_at == 0 and frame - fight_at == 60 then
            armed_at = frame
            w16(A.p1_matchw, 1)
            w16(A.p2_bar, 1)
            log("armed: p1_matchw=1 p2_bar=1")
        end

        if armed_at > 0 and ko_at == 0 then
            snap_to(60)
            hold("P1 High Punch", (frame % 12) < 5)
            if r16(A.p2_bar) == 0 then
                ko_at = frame
                hold("P1 High Punch", false)
                log("KO at frame %d", frame)
            end
        end

        if ko_at > 0 then
            local ws = r16(A.winner_status)
            if ws ~= last_ws then log("  +%3d winner_status=%d gstate=%d", frame - ko_at, ws, gs); last_ws = ws end
            if ws == 3 and finish_at == 0 then
                finish_at = frame
                log("FINISH HIM at frame %d", frame)
            end
        end

        if finish_at > 0 and hit_at == 0 then
            -- Hold the range open the whole time: a cancelled attempt knocks
            -- the victim back and the next one would be inside hh_lo_punch's
            -- 0100h minimum.  The hat carries its own position once thrown, so
            -- re-snapping during the flight does not move what it is aimed at.
            snap_to(FATAL_DIST)

            if combo_at == 0 and frame - finish_at >= 4 then
                combo_at = frame
                log("hold LP / Back,Forward / release, then Down for %d tick(s)", DOWN)
            end

            if combo_at > 0 then
                local c = frame - combo_at
                if fatal_at == 0 then
                    local want = {}
                    for _, step in ipairs(SEQ) do
                        if c >= step[2] and c < step[3] then want[step[1]] = true end
                    end
                    for _, step in ipairs(SEQ) do hold(step[1], want[step[1]] == true) end
                end

                if fatal_at == 0 and r16(A.f_death) ~= 0 then
                    fatal_at = frame
                    log("  fatality started at +%d (f_death=%04x), gap=%d",
                        c, r16(A.f_death), gap())
                    for _, step in ipairs(SEQ) do hold(step[1], false) end
                end

                -- Steer.  Down for down_hold ticks once the hat is in the air.
                if fatal_at > 0 then
                    local s = frame - fatal_at - STEER_AT
                    hold("P1 Down", s >= 0 and s < DOWN)
                    hold("P1 Up", s >= 0 and s < -DOWN)
                    local hh, hx = hat_height()
                    if hh then
                        local p2o = r32(A.p2_obj)
                        log("    +%3d hat h=%d x=%d  victim x=%d", frame - fatal_at, hh, hx,
                            p2o ~= 0 and r16(p2o + O_OXPOS) or -1)
                    end
                end

                if r16(A.f_death) == 0xffff then
                    hit_at = frame
                    victim_y0 = victim_height()
                    for n in pairs(fields) do hold(n, false) end
                    log("  WINDOW HIT at +%d (victim anchor %d px above the floor)",
                        frame - fatal_at, victim_y0)
                    snap()
                elseif fatal_at > 0 and frame - fatal_at > 160 then
                    results[#results + 1] = { down = DOWN, kind = "cancelled", rise = 0 }
                    for n in pairs(fields) do hold(n, false) end
                    snap(); done = true
                    log("  down=%2d -> CANCELLED - the hat crossed neither window", DOWN)
                    verdict(); manager.machine:exit()
                end
            end
        end

        if hit_at > 0 then
            local rel = frame - hit_at
            local h = victim_height()
            if h - victim_y0 > victim_rise then victim_rise = h - victim_y0 end
            if SNAP_EVERY > 0 then
                if rel <= 260 then
                    head_witness(rel)
                    if rel % SNAP_EVERY == 0 then snap() end
                end
            elseif rel == 20 or rel == 45 or rel == 80 or rel == 140 or rel == 220 then
                snap()
            end
            if rel == 90 then
                hit_kind = victim_rise > 24 and "WAIST split" or "NECK decap"
                results[#results + 1] = { down = DOWN, kind = hit_kind, rise = victim_rise }
                log("  down=%2d -> %s (victim rose %d px)", DOWN, hit_kind, victim_rise)
            end
            if rel > 400 then
                done = true; verdict(); manager.machine:exit()
            end
        end

        if finish_at > 0 and hit_at == 0 and frame - finish_at > 2400 then
            snap(); done = true
            log("FINISH HIM window closed with no window hit")
            verdict(); manager.machine:exit()
        end
        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then
            done = true; log("never landed a KO"); verdict(); manager.machine:exit()
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end

    if frame > 14000 and not done then
        done = true
        log("timeout phase=%s psel=%d confirm=%d fight=%d ko=%d finish=%d",
            phase, psel, confirm, fight_at, ko_at, finish_at)
        verdict(); manager.machine:exit()
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
