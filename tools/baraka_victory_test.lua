-- baraka_victory_test.lua
--
-- Baraka's victory: do the blade sparks play, and does the game SURVIVE them?
--
-- The sparks (UGGLEAM1-6, from UGMO9.IMG) lived in a_sa_victory_gleam, which
-- was defined as ani2 index 5 and invoked by nothing -- so they never played.
-- Playing them inline then crashed shortly AFTER they appeared, because
-- sa_victory ends in local_wait_forever and the gleam frames carry seven
-- multipart pieces against UGVICTORY8's five: ending on one held the two
-- extra spark lanes live forever.
--
-- So a test that only checks "did the sparks appear" would have gone green on
-- the crashing build. This one watches the sparks AND then keeps running well
-- past them, because the failure is in the hold, not the animation.
--
-- Env: BARAKA_VICTORY_LOG, BARAKA_HOLD_FRAMES
-- Usage: tools\run_baraka_victory_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = os.getenv("BARAKA_VICTORY_LOG") or (ROOT .. "/tools/baraka_victory_test.log")
-- How long to sit on the finished victory. The reported crash came in "after"
-- the sparks, so the hold is the actual test surface -- it must be long, and
-- longer than the animation itself.
local HOLD_FRAMES = tonumber(os.getenv("BARAKA_HOLD_FRAMES") or "1200")

local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local line = "[baraka] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), objlst = sym("objlst"),
    round_num = sym("round_num"),
}

local OIMG, MP_LEN = 0x1a0, 0x70
-- oflags2 (DISPEQU.ASM) and its invisible bit. MKDISP tests b_inviso inside
-- the multipart branch, so this bit is exactly what decides whether the spark
-- object still draws -- the multipart SAGs stay put either way, which is why
-- counting gleam SAGs alone cannot see the sparks leave.
local OFLAGS2, M_INVISO = 0x160, 0x0020
local OZVAL, ONEXT = 0xc0, 0x00
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_SA, FT_JAX, MAX_HP = 3, 11, 0x00a1
local PS_ACTIVE, PS_INACTIVE = 1, 0

-- SAG -> which lane it belongs to, parsed from the promoted table. Never
-- hardcode these: they move whenever the art is rebuilt.
local gleam_sag, leg_sag, vic7_sag = {}, {}, {}
local n_gleam, n_leg, n_vic7 = 0, 0, 0
do
    local fh = assert(io.open(ROOT .. "/src/MKSA2.TBL", "r"), "missing MKSA2.TBL")
    local target
    for line in fh:lines() do
        if line:match("^%s*UGGLEAM%d+[AB]?:") then target = "g"
        elseif line:match("^%s*UGVICTORYLEG%d+[AB]?:") then target = "l"
        elseif line:match("^%s*UGVICTORY7[A-C]?:") then target = "v"
        elseif line:match("^%s*%u[%w_]*:") then target = nil end
        local sag = target and line:match("%.long%s+0([0-9a-fA-F]+)[Hh]")
        if sag then
            local v = tonumber(sag, 16) & 0x00ffffff
            if target == "g" then gleam_sag[v] = true; n_gleam = n_gleam + 1
            elseif target == "l" then leg_sag[v] = true; n_leg = n_leg + 1
            else vic7_sag[v] = true; n_vic7 = n_vic7 + 1 end
            target = nil
        end
    end
    fh:close()
end

local frame, space, finished = 0, nil, false
local fields, charsel_frame, confirm_frame, fighting_frame = {}, 0, 0, 0
local forced_win, victory_seen, hold_start = 0, 0, 0
local gleam_frames, max_pieces, last_gstate = 0, 0, -1
local vic7_over_legs, vic7_seen = nil, 0
local bad_gstate, obj_lost = 0, 0
-- THE REAL PASS CONDITION, in the player's words: "if it goes to the next
-- match then it works". The previous version sat watching a parked victory
-- screen and called that healthy -- it returned PASS on the build that
-- actually crashes, byte-identical, because a hung game and a held pose look
-- the same to a sampler. Advancing to the next round is something a crashed
-- game cannot fake.
local round_at_win, advanced, gs_log = nil, 0, 0
local spark_z, body_z = nil, nil
-- THE SECOND HALF OF THE ANIMATION: the sparks have to STOP. Reported as
-- "stops at the last frame and stays on his blade" -- the object held
-- UGGLEAM6 for the whole rest of the victory. gleam_frames cannot catch that
-- (the SAGs never leave multipart RAM), so track the DRAWN frames separately
-- and the frame the object goes invisible.
local spark_obj, spark_drawn_frames, spark_hidden_at = nil, 0, 0
-- 6 rows x 6 ticks = 36 ticks of gleam. Anything past that plus slack is the
-- spark parked on the blade.
local SPARK_TICKS, SPARK_SLACK = 36, 30

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("sparks: %d frame(s) showed a UGGLEAM piece (markers g=%d l=%d v7=%d)",
        gleam_frames, n_gleam, n_leg, n_vic7)
    log("max multipart pieces held by BARAKA = %d (7 = the lane-growth bug)", max_pieces)
    if spark_z and body_z then
        log("spark object z=%d vs Baraka z=%d -> in front = %s",
            spark_z, body_z, tostring(spark_z > body_z))
    end
    if vic7_seen > 0 then
        log("UGVICTORY7 seen %d frame(s); blade queued AFTER legs = %s",
            vic7_seen, tostring(vic7_over_legs))
    else
        log("UGVICTORY7 never observed (it is one frame - may be missed by sampling)")
    end
    log("post-victory: bad_gstate=%d obj_lost=%d gstate_changes=%d advanced=%s",
        bad_gstate, obj_lost, gs_log, advanced > 0 and ("frame " .. advanced) or "NO")
    log("sparks DRAWN for %d frame(s) (budget %d+%d); hidden at %s",
        spark_drawn_frames, SPARK_TICKS, SPARK_SLACK,
        spark_hidden_at > 0 and ("frame " .. spark_hidden_at) or "NEVER (parked on the blade)")
    log("%s reason=%s", ok and "PASS" or "FAIL", reason)
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and name == "P1 High Punch" and confirm_frame > 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    return false
end

-- Walk Baraka's multipart list. Returns piece count, whether a gleam piece is
-- present, and (for the z-order question) whether UGVICTORY7 is queued after
-- the legs. First piece queued draws FIRST and sits at the BOTTOM, so "after
-- the legs" is what puts the blade on top.
local function scan_pieces(obj)
    if obj == 0 then return 0, false, nil end
    local image = r32(obj + OIMG); if image == 0 then return 0, false, nil end
    local n, has_gleam, leg_at, v7_at = 0, false, nil, nil
    for i = 0, 9 do
        local sag = r32(image + i * MP_LEN) & 0x00ffffff
        if sag == 0 then break end
        n = i + 1
        if gleam_sag[sag] then has_gleam = true end
        if leg_sag[sag] and not leg_at then leg_at = i end
        if vic7_sag[sag] and not v7_at then v7_at = i end
    end
    local order = nil
    if leg_at and v7_at then order = (v7_at > leg_at) end
    return n, has_gleam, order
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- Baraka victory: sparks + survive the hold ----")
        log("markers gleam=%d legs=%d vic7=%d  hold=%d frames", n_gleam, n_leg, n_vic7, HOLD_FRAMES)
        if n_gleam == 0 then log("FATAL: no UGGLEAM SAGs parsed - the test cannot see sparks") end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_SA)                 -- Baraka wins, so Baraka is P1
        w16(A.p2_char, FT_JAX)
        w16(A.curback, 0)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then finish(false, "never reached the fight") end
        return
    end

    -- Force the win once, then never touch the bars again: the victory and
    -- everything after it has to run on its own.
    if forced_win == 0 and frame > fighting_frame + 120 and A.round_num ~= 0 then
        round_at_win = r16(A.round_num)
    end
    if forced_win == 0 and frame > fighting_frame + 120 then
        w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
        w16(A.p2_bar, 0); w16(A.p2_bar_view, 0)
        forced_win = frame
        log("forced the win at frame=%d", frame)
    end
    if forced_win == 0 then return end

    if gs ~= last_gstate then
        gs_log = gs_log + 1
        log("gstate %d -> %d at frame=%d (round_num=%d)", last_gstate, gs, frame,
            A.round_num ~= 0 and r16(A.round_num) or -1)
        last_gstate = gs
    end
    -- Advanced = the round counter moved on, or we are fighting again after
    -- the victory played. Either one means the game got past the hold.
    if victory_seen > 0 and advanced == 0 then
        local rn = (A.round_num ~= 0) and r16(A.round_num) or nil
        if (rn and round_at_win and rn ~= round_at_win) or (gs == GS_FIGHTING and frame > victory_seen + 60) then
            advanced = frame
            log("ADVANCED to the next match at frame=%d (+%d after the sparks)",
                frame, frame - victory_seen)
        end
    end

    -- The sparks ride their OWN object now (Jade-staff pattern), so scanning
    -- Baraka's multipart finds nothing -- this read 0 sparks against a build
    -- that was drawing them fine. Walk objlst like the Jade harness does.
    local n, has_gleam, order = scan_pieces(r32(A.p1_obj))
    if not has_gleam and A.objlst ~= 0 then
        local obj, guard = r32(A.objlst), 0
        while obj ~= 0 and guard < 256 do
            local _, g = scan_pieces(obj)
            if g then
                has_gleam = true
                spark_obj = obj
                if spark_z == nil then
                    spark_z = r32(obj + OZVAL)
                    body_z = r32(r32(A.p1_obj) + OZVAL)
                end
                break
            end
            obj = r32(obj + ONEXT); guard = guard + 1
        end
    end
    if n > max_pieces then max_pieces = n end
    if has_gleam then
        gleam_frames = gleam_frames + 1
        if victory_seen == 0 then
            victory_seen = frame
            log("SPARKS on screen at frame=%d (+%d after the win)", frame, frame - forced_win)
        end
    end

    -- Is the spark object still being DRAWN? Ask oflags2, not the SAG list.
    if spark_obj and spark_obj ~= 0 then
        local inviso = (r16(spark_obj + OFLAGS2) & M_INVISO) ~= 0
        if inviso then
            if spark_hidden_at == 0 then
                spark_hidden_at = frame
                log("sparks HIDDEN at frame=%d (+%d after they appeared, drawn %d frame(s))",
                    frame, frame - victory_seen, spark_drawn_frames)
            end
        else
            spark_drawn_frames = spark_drawn_frames + 1
        end
    end
    if order ~= nil then
        vic7_seen = vic7_seen + 1
        if vic7_over_legs == nil then
            vic7_over_legs = order
            log("UGVICTORY7 vs legs: blade queued after legs = %s", tostring(order))
        end
    end

    -- THE ACTUAL TEST. Once the sparks have played, sit here and make sure the
    -- machine stays healthy -- this is where the reported crash happened.
    if victory_seen > 0 then
        if hold_start == 0 then hold_start = frame end
        if gs == 0xffff or gs > 0x20 then
            bad_gstate = bad_gstate + 1
            if bad_gstate == 1 then log("BAD gstate=0x%x at frame=%d", gs, frame) end
        end
        if r32(A.p1_obj) == 0 then
            obj_lost = obj_lost + 1
            if obj_lost == 1 then log("p1_obj went NULL at frame=%d", frame) end
        end
        if frame % 300 == 0 then
            log("  .. hold +%d  gstate=%d pieces=%d", frame - hold_start, gs, n)
        end
        -- Overstayed. This is the reported bug: the last gleam row never
        -- goes away and rides Baraka's blade through the rest of the victory.
        if spark_hidden_at == 0 and spark_drawn_frames > SPARK_TICKS + SPARK_SLACK then
            finish(false, "sparks never disappeared - last frame parked on the blade")
        end
        if advanced > 0 then
            if spark_hidden_at == 0 then
                finish(false, "game advanced but the sparks were still drawn")
            else
                finish(true, "sparks played, cleared the blade, and the game reached the next match")
            end
        end
        if frame - hold_start > HOLD_FRAMES then
            if bad_gstate > 0 or obj_lost > 0 then
                finish(false, "victory played but the game broke")
            elseif gleam_frames == 0 then
                finish(false, "no sparks")
            else
                finish(false, "STUCK: sparks played but the game never reached the next match")
            end
        end
    elseif frame - forced_win > 1800 then
        finish(false, "victory never produced a spark frame")
    end

    if frame > 30000 then finish(false, "global timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
