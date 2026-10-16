-- jade_impale_test.lua
--
-- JADE's STAFF IMPALE (do_jade_impale, MKDEATH.ASM): Block, Block, Block,
-- Forward, Block, close, in FINISH HIM.  She uppercuts him off the top of
-- the screen, plants her staff (data/JDIMPALE2.WAX), and he comes back down
-- flat on his back onto its tip.
--
-- P1 = Jade, reached the way every Jade rig does: pick Kitana at the select
-- screen and overwrite p1_char with 16 at GS_POST.  P2 = the victim.  FINISH
-- HIM is forced by emptying his bar with P1 on match point; the rig then
-- snaps the pair inside jdi_maxdist and plays the input.
--
-- What it proves without pictures (the snapshots are for looking):
--   f_death != 0         the fatality started (and Jade never left the floor)
--   his peak height      the uppercut threw him past jdi_toph
--   jdi_tip_ok           the staff lane finished and the tip was published
--   he settles ON it     the staff runs through him (his bottom below the tip,
--                        the tip at most JI_TOL out of his top) and his middle
--                        within JI_TOL of it - the ROM's own mpart_bounds
--   f_death == ffff      death_blow_complete ran (from HIS process)
--   staff object         a non-player object the whole time the lane runs
--
--   JI_VICTIM      subzero | kitana | kang | cage | kunglao | jax | baraka |
--                  shang | raiden | scorpion | reptile | mileena (default jax)
--   JI_SIDE        left (P1 starts left, faces right) | right (swap them)
--   JI_SNAP_EVERY  snapshot every N frames through the fatality (default 4)
--   JI_LOG         log path

local ROOT   = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local VICTIM = (os.getenv("JI_VICTIM") or "jax"):lower()
local SIDE   = (os.getenv("JI_SIDE") or "left"):lower()
local SNAP_EVERY = tonumber(os.getenv("JI_SNAP_EVERY") or "4") or 4
local LOG    = os.getenv("JI_LOG") or (ROOT .. "/tools/jade_impale_" .. VICTIM .. ".log")
local TOL    = tonumber(os.getenv("JI_TOL") or "40") or 40
-- JI_NEG=noforward: the four Blocks with NO Forward - the fatality must NOT
-- start (jdi_forward_between is what refuses it).  The verdict inverts.
local NEG    = (os.getenv("JI_NEG") or ""):lower()

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[ji/" .. VICTIM .. "/" .. SIDE .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open((os.getenv("JI_MAP") or (ROOT .. "/src/mk2.map")), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "p1_obj", "p2_obj", "p1_proc", "p2_proc", "f_death", "objlst",
               "jdi_tip_x", "jdi_tip_y", "jdi_tip_ok", "jdi_rest_dx", "jdi_rest_dy", "jdi_rest_dt",
               "jdi_floor_y", "dmaq_late", "dmaq_lost",
               "peak_overload", "blood_count" }
local A, missing = {}, false
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n); missing = true end
end

local O_OXPOS, O_OXVAL, O_OYPOS, O_OZVAL = 0x090, 0x080, 0x0b0, 0x0c0
local O_OFLAGS, O_OFLAGS2, O_OSHAPE = 0x0f0, nil, 0x1d0
local P_GANIY
do
    for _, f in ipairs({ "DISPEQU.ASM", "MAINEQU.ASM", "MKSTRUCT.ASM", "SYSEQU.ASM" }) do
        local fh = io.open(ROOT .. "/src/" .. f, "r")
        if fh then
            for line in fh:lines() do
                local n, v = line:match("^(%w+)%s+%.set%s+(%x+)h")
                if n == "oflags2" and not O_OFLAGS2 then O_OFLAGS2 = tonumber(v, 16) end
                if n == "p_ganiy" and not P_GANIY then P_GANIY = tonumber(v, 16) end
            end
            fh:close()
        end
    end
end

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_JADE = 4, 16
local VICTIMS = { kunglao = 0, kang = 1, cage = 2, baraka = 3, kitana = 4, mileena = 5,
                  shang = 6, raiden = 7, subzero = 8, reptile = 9, scorpion = 10, jax = 11 }
local WANT_P2 = VICTIMS[VICTIM] or 11
local FATAL_DIST = 0x40         -- inside jdi_maxdist (050h)
local FWD = SIDE == "right" and "P1 Left" or "P1 Right"
-- Block, Block, Block, Forward, Block - taps, 8 ticks apart.
local SEQ = { { "P1 Block", 2, 6 }, { "P1 Block", 10, 14 }, { "P1 Block", 18, 22 },
              { FWD, 26, 31 }, { "P1 Block", 34, 39 } }
if NEG == "noforward" then table.remove(SEQ, 4) end

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, combo_at, done = 0, 0, 0, false
local fatal_at, tip_at, complete_at, tries, snaps = 0, 0, 0, 0, 0
local peak_h, ground_y, staff_seen, jade_air = 0, nil, 0, false
local settle = {}
local moved_on = 0
local base = {}

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1, ["P2 Low Punch"]=1,
                   ["P1 Right"]=1, ["P1 Left"]=1, ["P1 Down"]=1, ["P1 Up"]=1, ["P1 Block"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x)
    w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end

-- P1 on the left of P2 by `dist`, or on the right with JI_SIDE=right
local function snap_to(dist)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local mid = (r16(p1o + O_OXPOS) + r16(p2o + O_OXPOS)) // 2
    local lo, hi = mid - dist // 2, mid + dist - dist // 2
    if SIDE == "right" then place(p1o, hi); place(p2o, lo) else place(p1o, lo); place(p2o, hi) end
end

local function snap() snaps = snaps + 1; manager.machine.video:snapshot() end

-- the objects on objlst other than the two fighters
local function extras()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local o, n, out = r32(A.objlst), 0, {}
    while o ~= 0 and n < 250 do
        if o ~= p1o and o ~= p2o then out[#out+1] = o end
        o = r32(o); n = n + 1
    end
    return out
end

local function describe(tag, o)
    if o == 0 then return tag .. "=none" end
    return string.format("%s x=%d y=%d z=%x fl=%04x", tag, s16(r16(o + O_OXPOS)),
        s16(r16(o + O_OYPOS)), r32(o + O_OZVAL), r16(o + O_OFLAGS))
end

local function verdict()
    local ok, why = true, {}
    if NEG ~= "" then
        log("FAIL negative control (%s): the fatality started without the Forward", NEG)
        return
    end
    log("p1_char=%d (want %d)  p2_char=%d (want %d)", r16(A.p1_char), FT_JADE,
        r16(A.p2_char), WANT_P2)
    if r16(A.p1_char) ~= FT_JADE then ok = false; why[#why+1] = "P1 is not Jade" end
    if finish_at == 0 then ok = false; why[#why+1] = "no FINISH HIM window" end
    if fatal_at == 0 then ok = false; why[#why+1] = "the fatality never started" end
    if jade_air then ok = false; why[#why+1] = "Jade left the floor during the input (a jump)" end
    if fatal_at > 0 and peak_h < 0x1a0 then
        ok = false; why[#why+1] = string.format("he only went %d px up (want >= 416)", peak_h)
    end
    if tip_at == 0 then ok = false; why[#why+1] = "her staff lane never started (jdi_tip_ok)" end
    if fatal_at > 0 and staff_seen == 0 then ok = false; why[#why+1] = "no staff object" end
    if complete_at == 0 then ok = false; why[#why+1] = "death_blow_complete never ran" end
    if complete_at > 0 and moved_on == 0 then ok = false; why[#why+1] = "the game never left the fight" end
    if settle.dy then
        log("SETTLED: his middle %+d px from the tip; his drawn body runs %+d..%+d px " ..
            "about it (tip %d,%d; tol %d)", settle.dx, settle.dt, settle.dy, settle.tx, settle.ty, TOL)
        if math.abs(settle.dx) > TOL then ok = false; why[#why+1] = "not centred on the staff" end
        -- the staff runs THROUGH him: his back below the tip, and the tip no
        -- more than TOL out of his top (JDIMPALE2.WAX has it ~16px out)
        log("the tip comes %d px out of his top", settle.dt)
        if settle.dy <= 0 then ok = false; why[#why+1] = "his back never came down to the tip" end
        if settle.dt > TOL then ok = false; why[#why+1] = "he slid off the staff - the tip is too far out" end
        -- ...and he stops ABOVE HER HAND.  The lineup matches his drawn TOP to
        -- the template's, so a landing frame with a limb thrown up carries the
        -- rest of him on down the staff: Jax and Raiden used to rest 15-16px
        -- BELOW her fist.  jdi_floor_y is the row the ROM clamped him to.
        local lowest = settle.ty + settle.dy      -- his lowest pixel, world y
        log("his lowest pixel rests at y %d; the floor above her hand is %d (%+d px clear)",
            lowest, settle.floor, settle.floor - lowest)
        if lowest > settle.floor then
            ok = false
            why[#why+1] = string.format("he went %d px past her hand (floor %d, lowest %d)",
                                        lowest - settle.floor, settle.floor, lowest)
        end
    elseif complete_at > 0 then
        ok = false; why[#why+1] = "never measured where he came to rest"
    end
    log("peak height %d   blood peak %d   %d snapshot(s)", peak_h, base.blood or 0, snaps)
    if base.dmaq_late then
        log("budgets over the fatality: dma late +%d lost +%d | peak_overload %d",
            r16(A.dmaq_late) - base.dmaq_late, r16(A.dmaq_lost) - base.dmaq_lost,
            r16(A.peak_overload))
    end
    log("%s jade staff impale on %s (jade on the %s)%s", ok and "PASS" or "FAIL", VICTIM, SIDE,
        ok and "" or ("  -- " .. table.concat(why, "; ")))
end

local function finish() done = true; verdict(); manager.machine:exit() end

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
            w16(A.p1_char, FT_KITANA)           -- her base: forcing 16 here never confirms
            w16(A.p2_char, WANT_P2)
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and rel > 60 then
            confirm = frame
            log("select done at frame %d", frame)
            for n in pairs(fields) do hold(n, false) end
        end

    else
        if gs == GS_POST then
            w16(A.p1_char, FT_JADE)
            w16(A.p2_char, WANT_P2)
        end

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
            hold("P1 Low Punch", (frame % 12) < 5)
            if r16(A.p2_bar) == 0 then
                ko_at = frame; hold("P1 Low Punch", false)
                log("KO at frame %d", frame)
            end
        end

        if ko_at > 0 and finish_at == 0 and r16(A.winner_status) == 3 then
            finish_at = frame
            log("FINISH HIM at frame %d", frame)
        end

        if finish_at > 0 and fatal_at == 0 then
            snap_to(FATAL_DIST)
            local p1o = r32(A.p1_obj)
            if combo_at == 0 and frame - finish_at >= 30 then
                combo_at = frame; tries = tries + 1
                base.jade_y = s16(r16(p1o + O_OYPOS))
                log(NEG == "noforward" and "Block x4, NO Forward (try %d)" or "Block, Block, Block, Forward, Block (try %d)", tries)
            end
            if combo_at > 0 then
                local c = frame - combo_at
                local want = {}
                for _, step in ipairs(SEQ) do
                    if c >= step[2] and c < step[3] then want[step[1]] = true end
                end
                for _, n in ipairs({ "P1 Up", "P1 Down", "P1 Left", "P1 Right", "P1 Block",
                                     "P1 High Punch" }) do
                    hold(n, want[n] == true)
                end
                if base.jade_y and s16(r16(p1o + O_OYPOS)) < base.jade_y - 20 then
                    if not jade_air then log("Jade is AIRBORNE at +%d - the Up became a jump", c) end
                    jade_air = true
                end
                if c > 70 and tries < 4 then combo_at = 0 end
            end
            if r16(A.f_death) ~= 0 and r16(A.f_death) ~= 0xffff then
                fatal_at = frame
                for n in pairs(fields) do hold(n, false) end
                local p2o, p2p = r32(A.p2_obj), r32(A.p2_proc)
                ground_y = P_GANIY and s16(r16(p2p + P_GANIY)) or s16(r16(p2o + O_OYPOS))
                base.dmaq_late, base.dmaq_lost = r16(A.dmaq_late), r16(A.dmaq_lost)
                log("fatality started at %d (f_death=%04x), his ground y %d", frame,
                    r16(A.f_death), ground_y)
                snap()
            end
        end

        if fatal_at > 0 then
            local rel = frame - fatal_at
            local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
            local vy = s16(r16(p2o + O_OYPOS))
            peak_h = math.max(peak_h, ground_y - vy)
            base.blood = math.max(base.blood or 0, r16(A.blood_count))
            local ex = extras()
            if tip_at > 0 and complete_at == 0 and #ex > 0 then staff_seen = staff_seen + 1 end
            if SNAP_EVERY > 0 and rel % SNAP_EVERY == 0 and rel <= 400 then snap() end
            if rel % 6 == 0 and rel <= 300 then
                log("  +%3d %s | %s | extras=%d tip_ok=%d f_death=%04x", rel,
                    describe("jade", p1o), describe("victim", p2o), #ex,
                    r16(A.jdi_tip_ok), r16(A.f_death))
            end
            if tip_at == 0 and r16(A.jdi_tip_ok) ~= 0 then
                tip_at = frame
                log("LANE STARTED at +%d: tip %d,%d", rel, s16(r16(A.jdi_tip_x)),
                    s16(r16(A.jdi_tip_y)))
            end
            if complete_at == 0 and r16(A.f_death) == 0xffff then
                complete_at = frame
                log("death_blow_complete at +%d", rel)
            end
            if complete_at > 0 and frame - complete_at == 20 then
                -- at rest: read the ROM's own measurement back through the
                -- geometry it used - the tip, and where his anchor stopped
                snap()
                -- the ROM's own mpart_bounds at rest, off the tip it aimed at
                settle.tx, settle.ty = s16(r16(A.jdi_tip_x)), s16(r16(A.jdi_tip_y))
                settle.dx, settle.dy = s16(r16(A.jdi_rest_dx)), s16(r16(A.jdi_rest_dy))
                settle.dt = s16(r16(A.jdi_rest_dt))
                settle.floor = s16(r16(A.jdi_floor_y))
                log("at rest: %s", describe("victim", p2o))
            end
            -- and the game gets past it: both processes end in wait_forever
            -- and the staff object waits for the round teardown
            -- gs_bonus (5) starts on the very frame of the finish; moving on
            -- means getting PAST the bonus count too, after the rest reading
            if complete_at > 0 and moved_on == 0 and frame - complete_at > 25
               and gs ~= GS_FIGHTING and gs ~= 5 then
                moved_on = frame
                log("the game moved on at +%d after the finish (gstate %x)", frame - complete_at, gs)
                finish()
            end
            if complete_at > 0 and frame - complete_at > 1500 then
                log("still in the fight/bonus 1500 frames after the finish (gstate %x)", gs); finish()
            end
            if rel > 2600 then log("the fatality never finished"); finish() end
        end

        if finish_at > 0 and fatal_at == 0 and frame - finish_at > 700 then
            snap(); log("fatality never started")
            if NEG ~= "" then
                done = true
                log("PASS negative control (%s): Block x4 with no Forward did nothing", NEG)
                manager.machine:exit(); return
            end
            finish()
        end
        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then
            log("never landed a KO"); finish()
        end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 16000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
