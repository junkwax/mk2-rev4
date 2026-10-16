-- slicehat_test.lua - KUNG LAO'S HAT BANKS INTO THE ANGLE IT IS FLYING AT
--
-- WHAT THIS MEASURES IS THE SAG THE DMA WAS HANDED, against the hat's own
-- oyvel, on the same tick.  Not a screenshot and not "the sprite changed":
-- the assertion is the WIRING - for every sampled tick, the frame drawn is
-- the one that tick's velocity calls for, by the same thresholds hat_proc
-- uses.  A rig that only watched the sprite change would pass on a table
-- wired backwards, and inverting the arms is the likely regression here.
--
-- ONE TICK OF LAG IS REAL AND IS NOT SLOP.  hat_proc draws the frame from the
-- oyvel it starts the tick with, THEN steers, THEN sleeps.  So the frame on
-- screen belongs to the PREVIOUS sample's velocity, and that is what the
-- check compares against.  Comparing against the current one fails by exactly
-- one bucket for the whole of every steered trial.
--
-- Trials, each thrown from the same spot:
--
--   flat   no stick     -> oyvel stays 0, SLICEHAT1 and nothing else
--   up     Up held      -> oyvel goes NEGATIVE, the frames walk DOWN the
--                          table toward SLICEHAT6, and |oyvel| stops at
--                          slhat_ymax when slhatcap is on
--   down   Down held    -> oyvel goes POSITIVE, frames walk UP toward
--                          SLICEHAT16
--
-- The hat is found BY ITS ART - walking objlst/2/3 for an object whose
-- multipart RAM carries one of the ten SLICEHAT SAGs.  p_slave looks like the
-- handle (get_proj_obj_m does set it) and is not dependable, the same reason
-- the rope and cloud probes walk the lists.
--
-- Expectations come from tools/slicehat_expect.lua, regenerated from the
-- build on every run: a rebuild moves every SAG in the pack.
--
--   SLH_LOG  log path       SLH_MAP  a map to read instead of src/mk2.map
--   SLH_SNAP 1 = snapshot the steered trials

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("SLH_LOG") or (ROOT .. "/tools/slicehat_test.log")
local SNAP = os.getenv("SLH_SNAP") == "1"
-- per-tick object/process trace; off by default because it is 200 lines a trial
local TRACE = os.getenv("SLH_TRACE") == "1"

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[slh] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local EXPECT = dofile(ROOT .. "/tools/slicehat_expect.lua")
if EXPECT.slicehat == 0 then
    log("slicehat is 0 in MAINEQU - nothing to test"); logfh:close()
    manager.machine:exit(); return
end

local symbols = {}
do
    local fh = assert(io.open(os.getenv("SLH_MAP") or (ROOT .. "/src/mk2.map"), "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local A, missing = {}, false
-- OPTIONAL: getfpal's failure counter (PALL.ASM).  The hat's flight art needs
-- a colour map of its own (swpal to SHAT3_P), so an exhausted foreground pool
-- makes hat_proc fall back to retail's HATFLY loop and this rig report "never
-- found the hat on SLICEHAT art" - true, but it names the symptom and not the
-- cause.  Reading the counter turns that into a diagnosis.  Absent in a build
-- from before it was added, so it is looked up but never required.
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar",
                     "p1_obj", "p2_obj", "p1_proc", "objlst", "objlst2", "objlst3",
                     "active", "worldtlx" }) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
end
-- OPTIONAL: where strike_check stamped the contact point (hitpoint,
-- MAINEQU.ASM).  A p1:p2 pair of LONGS, each a packed [y,x] off that man's
-- own origin with x in facing space.  Absent in a build from before it, so it
-- is looked up and the three hit trials skip their contact check rather than
-- failing a ROM that never had the feature.
-- OPTIONAL: training mode's clock freeze (MAIN.ASM).  See the note at the
-- fight latch below - without it the round ends under the last trials.
A.f_freeze_timer = symbols["f_freeze_timer"]
A.hit_pt = symbols["hit_pt"]
if not A.hit_pt then log("note: hit_pt not in this build - contact point will not be checked") end
A.fpal_fail = symbols["fpal_fail"]
if not A.fpal_fail then log("note: fpal_fail not in this build - pool failures will not be reported") end

-- DISPEQU.ASM object block, in BIT offsets
local OLINK, OXVAL, OXPOS, OYPOS, OYVEL, OIMG = 0, 0x80, 0x90, 0xb0, 0x60, 0x1a0
local MP_SAG, MP_CONTROL = 0, 64   -- DISPEQU.ASM, bit offsets in the 112-bit node
local OFLAGS = 0xf0
local M_FLIPH = 0x10               -- oflags AND the piece control word
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_HATHEAD, FT_JAX, MAX_HP = 0, 11, 0xa1

-- side = which way Kung Lao throws.  THE LEFT THROWS ARE NOT OPTIONAL: the
-- leftward records (SLICEHAT12-16) are drawn art of their own and nothing
-- else in the rig would ever put them on screen.
local TRIALS = {
    { label = "flat",  stick = nil,       want = "level", side = 1 },
    { label = "up",    stick = "P1 Up",   want = "climb", side = 1 },
    { label = "down",  stick = "P1 Down", want = "dive",  side = 1 },
    { label = "Lflat", stick = nil,       want = "level", side = -1 },
    { label = "Lup",   stick = "P1 Up",   want = "climb", side = -1 },
    { label = "Ldown", stick = "P1 Down", want = "dive",  side = -1 },
    -- THE BOOMERANG.  Hold High Punch and the hat turns around once it is off
    -- the screen, and the return leg draws the OTHER direction's art - which
    -- is the only thing that keeps the motion trail behind it.
    -- STEERED, so the twin mapping is exercised at the extremes: thrown flat
    -- the bucket is 5 both sides and N -> 10-N is trivially satisfied.
    { label = "boom",  stick = "P1 Up",   want = "boom", side = 1,  hp = true },
    { label = "Lboom", stick = "P1 Down", want = "boom", side = -1, hp = true },
    -- A HAT THAT CONNECTS KEEPS THE BANK IT HIT WITH.  Every other trial parks
    -- the victim out of the way, so none of them ever exercised the hit path -
    -- which used to hand the palette back and drop the sprite to retail's flat
    -- HATFLY blur on the frame of contact.
    { label = "hit",   stick = nil, want = "hit",  side = 1, victim = true },
    -- ...AND THE BLOOD COMES OUT WHERE IT CAUGHT HIM (hitpoint, MAINEQU.ASM).
    -- The hat's whole point is that it crosses at whatever height it is flying
    -- at, so the stamped contact point has to MOVE with it.  A single hit
    -- cannot show that - any constant would pass - so the same hit is taken
    -- three times at three heights and the stamp must follow.
    --
    -- The height is SEEDED, not steered.  Over the ~12 ticks this flight
    -- lasts the steer only accumulates a few pixels, far inside the noise;
    -- writing oyvel once puts the hat 30-odd pixels up or down by contact,
    -- which is a difference worth asserting.  Nothing fights it on the
    -- outward leg: slhat_recenter_a1 returns 0 there by design.
    --
    -- ...and they stand FURTHER APART than the plain hit does.  The hat is
    -- already two ticks from him when find_hat first sees it at 150px, so a
    -- seeded 3 px/tick had moved it six pixels by contact - inside the noise.
    -- At 300 there are a dozen ticks of flight left to seed over.
    { label = "hiup",  stick = nil, want = "hit",  side = 1, victim = true,
      hatyv = -0x30000, vdist = 300 },
    { label = "hidwn", stick = nil, want = "hit",  side = 1, victim = true,
      hatyv =  0x30000, vdist = 300 },
    -- THE DRONE'S BUDGET.  A human holds the button; a drone commits to a
    -- number of ticks up front and spends it down.  Driving a real CPU throw
    -- is not something this harness can do (the drone sits in act_stance -
    -- see run_smoke_spear_test.ps1), so the spend path is isolated instead:
    -- clear the thrower's pb_joy so slhat_hp_held takes the drone branch,
    -- seed the budget, and require the hat to come back with NO HP held.
    { label = "dboom", stick = nil, want = "boom", side = 1, drone = true },
}

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end
local function hold(n, on) held[n] = on and true or false end

-- the same arithmetic slhat_frame does, on the same equates
local function want_index(yv)
    local m = (yv < 0) and -yv or yv
    local mag = 0
    for i = 1, 5 do if m >= EXPECT.edges[i] then mag = i end end
    if yv < 0 then return 5 - mag end
    return 5 + mag          -- both halves reach five banks now
end

-- leg: p_store7.  Under slhatdark the OUTWARD leg (0) wears the leftward set
-- whichever way it flies, so the name depends on the leg as well as the facing.
local function frame_name(i, objflip, leg)
    local useleft = objflip
    if (EXPECT.dark or 0) ~= 0 and leg ~= nil then useleft = (leg == 0) end
    for _, f in ipairs(EXPECT.frames) do
        if f.idx == i then return useleft and f.lname or f.rname end
    end
    return "?"
end

-- every SAG the hat can legally be wearing, either phase.  bysag alone is
-- phase A only, and the flight spends half its ticks on phase B.
local ANY = EXPECT.any

-- the hat's own flight proc: pa8 is the hat and p_store2 carries the thrower
local P_STORE2, P_STORE5, P_FLAGS, PA8, P_ACTION = 0x250, 0x2b0, 0x210, 0xc0, 0x1f0
local function hat_proc_of(obj)
    local pr, g = r32(A.active), 0
    while pr ~= 0 and g < 200 do
        if r32(pr + PA8) == obj and r32(pr + P_STORE2) ~= 0 then return pr end
        pr = r32(pr); g = g + 1
    end
    return 0
end

local function find_hat()
    for _, head in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        local o, guard = r32(head), 0
        while o ~= 0 and guard < 300 do
            local mp = r32(o + OIMG)
            if mp ~= 0 then
                local sag = r32(mp + MP_SAG)
                if ANY[sag] then return o, mp, sag end
            end
            o = r32(o + OLINK); guard = guard + 1
        end
    end
    return 0, 0, 0
end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local trial, phase, t0, cur = 0, "idle", 0, nil
local results = {}
local TRIAL_EVERY = 320

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 Low Punch"]=1, ["P2 Low Punch"]=1, ["P1 Left"]=1, ["P1 Right"]=1,
                   ["P1 Up"]=1, ["P1 Down"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + OXPOS, x); w32(obj + OXVAL, (x << 16) & 0xffffffff)
end

local function finish()
    done = true
    log("---- results (ymax 0x%x = %.2f px/tick, slhatcap=%d) ----",
        EXPECT.ymax, EXPECT.ymax / 65536, EXPECT.slhatcap)
    local fails = 0
    for _, x in ipairs(results) do
        local ok, why
        local pool = (x.fpal1 or 0) - (x.fpal0 or 0)
        if not x.saw then
            ok = false
            why = "NEVER FOUND THE HAT ON SLICEHAT ART - measured nothing"
            if pool > 0 then
                why = why .. string.format("; getfpal failed %d times during this trial, so "
                    .. "swpal could not claim SHAT3_P and hat_proc fell back to HATFLY - "
                    .. "this is a COLOUR MAP POOL failure, not a frame-table one", pool)
            end
        else
            local span = {}
            for i in pairs(x.idxseen) do span[#span+1] = i end
            table.sort(span)
            local lo, hi = span[1], span[#span]
            local names = {}
            for _, i in ipairs(x.order) do names[#names+1] = (x.names and x.names[i]) or frame_name(i, x.side < 0) end
            if x.want == "hit" then
                ok = (x.hitat ~= nil) and x.aftr >= 5 and x.mismatch == 0 and x.flipbad == 0
                why = string.format("connected at +%s, %d SLICEHAT frames drawn AFTER it",
                    tostring(x.hitat), x.aftr)
                if x.hitat == nil then
                    why = why .. " - NEVER CONNECTED, so this trial measured nothing"
                elseif x.aftr < 5 then
                    why = why .. " - it reverted to HATFLY on contact"
                end
                -- ...and the contact point was stamped SOMEWHERE ON HIM.  A
                -- standing fighter's origin is his sprite top, so anything
                -- outside 0..0b0h is not on his body at all - which is what a
                -- stamp taken off the wrong object, or never taken, looks like.
                if A.hit_pt then
                    local onhim = (x.hpty ~= nil) and x.hpty >= 0 and x.hpty <= 0xb0
                    ok = ok and onhim
                    why = why .. string.format("; CONTACT [y=%s x=%s]",
                        tostring(x.hpty), tostring(x.hptx))
                    if x.hpty == nil then
                        why = why .. " - NOTHING WAS STAMPED"
                    elseif not onhim then
                        why = why .. " - that is not on his body"
                    end
                end
            elseif x.want == "boom" then
                local both = x.tables["L"] and x.tables["R"]
                -- bucket N must become 10-N: that IS the twin pairing
                -- THE BANK REVERSES.  Asserting the exact bucket is wrong while
                -- the stick is still held: the steer runs the same tick and pulls
                -- oyvel straight back, so the bucket lands NEAR 10-N and not on
                -- it.  What must hold exactly is the SIGN change - that is what
                -- turns bucket N into 10-N and so lands the return on the twin.
                local twin = (x.yvprev ~= nil and x.yvturn ~= nil)
                             and (x.yvprev ~= 0) and ((x.yvprev < 0) ~= (x.yvturn < 0))
                -- ...and a flat throw has no sign to change, so it passes on the
                -- bucket staying put instead
                if x.yvprev == 0 then twin = (x.bturn == x.bprev) end
                -- the loop: x must slow through the turn, not jump sign
                -- NOT "does |oxvel| pass through near zero" any more.  That
                -- belonged to a VISIBLE loop; this one is deliberately short
                -- and hidden, so the rotation is partial and the exit state is
                -- snapped.  What must hold is that the turn took real ticks
                -- rather than being an instant sign flip, and that every one of
                -- them was out of sight.
                local curled = x.curlseen and x.curlticksseen >= 2
                local hidden = (x.curlvis == 0)
                -- and it must settle back to straight once left alone
                local settled = (x.homeyv0 ~= nil) and
                                (x.homeyv0 == 0 or (x.homeflat and x.homeyvmin == 0))
                -- ...ON THE LINE IT WAS THROWN ON.  The stamp must be the
                -- throw height (within what the steer moves it before the rig
                -- first sees it), and the hat must leave on that height.
                local stampok = (x.ystamp ~= nil and x.ysight ~= nil)
                                and math.abs(x.ystamp - x.ysight) <= 8
                local online = (x.yhome ~= nil and x.ystamp ~= nil)
                               and math.abs(x.yhome - x.ystamp) <= 3
                ok = x.reversed and x.flipped and both and twin and curled and hidden
                     and settled and stampok and online
                     and x.mismatch == 0 and x.flipbad == 0
                local why_line = string.format("; THROW LINE stamp %s (sighted %s)=%s, home %s=%s",
                    tostring(x.ystamp), tostring(x.ysight), tostring(stampok),
                    tostring(x.yhome), tostring(online))
                why = string.format("reversed=%s, facing flipped=%s, drew BOTH sets=%s, "
                    .. "twin %s->%s (bucket %s->%s, oyvel %s->%s)=%s",
                    tostring(x.reversed), tostring(x.flipped), tostring(both),
                    x.fprev or "?", x.fturn or "?", tostring(x.bprev), tostring(x.bturn),
                    tostring(x.yvprev), tostring(x.yvturn), tostring(twin))
                why = why .. string.format("; turn took %d ticks (|oxvel| %s -> min %s)=%s"
                    .. "; FLIP HIDDEN=%s",
                    x.curlticksseen, tostring(x.xabs0), tostring(x.xabsmin),
                    tostring(curled), tostring(hidden))
                why = why .. string.format("; RECENTRED |oyvel| %s -> %s=%s",
                    tostring(x.homeyv0), tostring(x.homeyvmin), tostring(settled))
                why = why .. why_line
                if not online then
                    why = why .. " - it came home OFF the line it was thrown on"
                end
                if not curled then
                    why = why .. " - it SNAPPED round in a single tick"
                end
                if not settled then
                    why = why .. " - it came home still banked and never levelled out"
                end
                if not hidden then
                    why = why .. string.format(" - *** %d CURL TICKS WERE ON SCREEN:"
                        .. " the player watches it pivot ***", x.curlvis)
                end
                if x.drone then
                    local spent = (x.budget0 ~= nil and x.budget1 ~= nil)
                                  and (x.budget1 < x.budget0)
                    ok = ok and spent
                    why = why .. string.format("; drone budget %s -> %s, spent=%s",
                        tostring(x.budget0), tostring(x.budget1), tostring(spent))
                end
                if not x.reversed then
                    why = why .. " - the hat never came back"
                elseif not x.flipped then
                    why = why .. " - it came back WITHOUT turning its art round,"
                        .. " so the trail leads on the way home"
                end
            elseif x.want == "level" then
                ok = (lo == 5 and hi == 5) and x.mismatch == 0
                why = string.format("stayed on %s, oyvel %d..%d",
                                    table.concat(names, ","), x.ymin, x.ymax)
            elseif x.want == "climb" then
                ok = (x.ymin < 0) and (lo <= 1) and (hi == 5)
                     and (x.ymin >= -EXPECT.ymax) and x.mismatch == 0
                why = string.format("frames %s, oyvel fell to %d (%.2f px/tick)%s",
                    table.concat(names, ","), x.ymin, x.ymin / 65536,
                    x.ymin >= -EXPECT.ymax and "" or "  *** OVER THE CAP ***")
            else
                ok = (x.ymax > 0) and (hi >= 9) and (lo == 5)
                     and (x.ymax <= EXPECT.ymax) and x.mismatch == 0
                why = string.format("frames %s, oyvel rose to %d (%.2f px/tick)%s",
                    table.concat(names, ","), x.ymax, x.ymax / 65536,
                    x.ymax <= EXPECT.ymax and "" or "  *** OVER THE CAP ***")
            end
            ok = ok and x.flipbad == 0
            if pool > 0 then
                why = why .. string.format("; NOTE %d getfpal failures during this trial", pool)
            end
            why = why .. string.format("; %d/%d frames agreed, %d trail-backwards",
                x.agree, x.agree + x.mismatch + x.flipbad, x.flipbad)
        end
        if not ok then fails = fails + 1 end
        log("  %-5s %s  %s", x.label, why, ok and "OK" or "FAIL")
    end
    if #results < #TRIALS then
        log("  NO VERDICT: %d of %d trials produced a result", #results, #TRIALS)
        fails = fails + (#TRIALS - #results)
    end
    -- THE CONTACT POINT FOLLOWS THE HAT.  Three identical hits at three
    -- heights: the stamp has to move with them, and in the right direction.
    -- Without this the per-trial check above passes on any constant that
    -- happens to land on his chest - which is exactly the behaviour being
    -- replaced.
    if A.hit_pt then
        local by = {}
        for _, x in ipairs(results) do if x.hpty then by[x.label] = x.hpty end end
        local up, mid, dn = by["hiup"], by["hit"], by["hidwn"]
        if up and mid and dn then
            local SPREAD = 8   -- px; the seeded climb/dive is 30-odd
            local moved = (mid - up >= SPREAD) and (dn - mid >= SPREAD)
            if not moved then fails = fails + 1 end
            log("  A/B    climbing %d < level %d < diving %d  %s",
                up, mid, dn, moved and "OK" or
                "FAIL - the contact point did not follow the hat")
        else
            fails = fails + 1
            log("  A/B    NO VERDICT: a hit trial did not stamp a point")
        end
    end
    log("%s hat banks into its flight angle (failures=%d)",
        fails == 0 and "PASS" or "FAIL", fails)
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
            w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX)
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
        if gs == GS_POST then w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_JAX) end
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            -- STOP THE ROUND CLOCK.  Twelve trials is 72 seconds of fight
            -- against a 99-second round, which is not margin: the round was
            -- ending under the last two, gstate went to 1, the fighter objects
            -- were torn down and every phase froze behind the p1o/p2o guard at
            -- the top of this handler.  That reads as two trials that "never
            -- found the hat" - a NO VERDICT wearing a failure's clothes.
            -- f_freeze_timer is the game's own training-mode flag (MAIN.ASM
            -- skips the decrement on it), so this is not a poke into the
            -- countdown, it is the switch that already exists.
            if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
            log("fight live at %d: p1_char=%d%s", frame, r16(A.p1_char),
                A.f_freeze_timer and " (clock frozen)" or " (NO f_freeze_timer - the clock runs)")
            if r16(A.p1_char) ~= FT_HATHEAD then log("P1 is not Kung Lao"); finish(); return end
        end
        if fight_at == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        -- NOBODY RUNS OUT OF HEALTH EITHER.  Three trials land a real hit and
        -- the victim pin only covered their own fly phase, so the damage was
        -- accumulating across the run.  Neither bar matters to anything being
        -- measured here.
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        local r = frame - fight_at
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        for n in pairs(fields) do hold(n, false) end
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o == 0 or p2o == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        if phase == "idle" and gs == GS_FIGHTING
           and r >= 120 and (r - 120) % TRIAL_EVERY == 0 and trial < #TRIALS then
            trial = trial + 1
            local T = TRIALS[trial]
            cur = { label = T.label, stick = T.stick, want = T.want, side = T.side,
                    hp = T.hp, ymin = 0, ymax = 0, xv0 = nil, reversed = false,
                    flip0 = nil, flipped = false, tables = {},
                    victim = T.victim, hitat = nil, aftr = 0,
                    hatyv = T.hatyv, yvseeded = false, yvseed_at = nil,
                    vdist = T.vdist or 150,
                    hpt = nil, hpty = nil, hptx = nil, haty = nil,
                    drone = T.drone, seeded = false, budget0 = nil, budget1 = nil,
                    bprev = nil, bturn = nil, fprev = nil, fturn = nil,
                    xabs0 = nil, xabsmin = nil, curlticks = 0,
                    homeyv0 = nil, homeyvmin = nil, homeflat = false,
                    ysight = nil, ystamp = nil, yhome = nil,
                    curlvis = 0, curlticksseen = 0,
                    leg = nil, legwas = nil, curlseen = false,
                    idxseen = {}, order = {}, saw = false, agree = 0, mismatch = 0,
                    flipbad = 0, phseen = {}, runs = {}, lastph = nil, phrun = 0, prev_yv = nil,
                    fpal0 = A.fpal_fail and r16(A.fpal_fail) or 0 }
            phase, t0 = "park", frame
            log("trial %d (%s): %s", trial, T.label, T.stick or "no stick")

        elseif phase == "park" then
            -- far apart, so the hat has a long flight to be steered over, and
            -- on the side that makes him throw the way this trial wants
            place(p1o, s16(r16(p2o + OXPOS)) - 170 * cur.side)
            if frame - t0 > 6 then phase, t0 = "cast", frame end

        elseif phase == "cast" then
            -- Back, Forward + Low Punch (scom_hh_throw)
            local d = frame - t0
            -- Back, Forward is relative to his facing, so the stick reverses
            -- with the side
            local back = (cur.side > 0) and "P1 Left" or "P1 Right"
            local fwd  = (cur.side > 0) and "P1 Right" or "P1 Left"
            if d >= 0 and d < 5 then hold(back, true) end
            if d >= 7 and d < 12 then hold(fwd, true) end
            if d >= 12 and d < 17 then hold("P1 Low Punch", true) end
            if d >= 22 then phase, t0 = "fly", frame end

        elseif phase == "fly" then
            local d = frame - t0
            -- RELEASE the stick once it is on its way home: the settle only
            -- happens when nothing is being asked of the hat, so a trial that
            -- held Up the whole flight could never see it.
            if cur.stick and not (cur.hp and cur.leg ~= nil and cur.leg ~= 0) then
                hold(cur.stick, true)
            end
            -- KEEP HOLDING THE THROW BUTTON.  The boomerang is held on LOW
            -- PUNCH - the one scom_hh_throw goes out on - so this is not a
            -- second press, it is simply never letting go.
            if cur.hp then hold("P1 Low Punch", true) end
            -- keep the victim out of the way EVERY tick: a hat that connects
            -- is consumed, and that reads as "never found the hat"
            if cur.victim then
                -- IN FRONT, close enough to be struck: this is the whole point
                -- of this trial, where every other one is keeping him clear
                place(p2o, s16(r16(p1o + OXPOS)) + cur.vdist * cur.side)
                w16(A.p2_bar, MAX_HP)
            else
                place(p2o, s16(r16(p1o + OXPOS)) - 300 * cur.side)
            end
            if not cur.saw and d > 0 and d % 40 == 0 then
                log("    (+%d: still no hat - gstate %d, p1 x=%d p2 x=%d, bars %d/%d)",
                    d, r16(A.gstate), s16(r16(p1o + OXPOS)), s16(r16(p2o + OXPOS)),
                    r16(A.p1_bar), r16(A.p2_bar))
            end
            local hat, mp, sag = find_hat()
            -- LATCH the object: once it is known, keep reading THAT object so
            -- a frame change out of the SLICEHAT set reads as "changed art",
            -- not as "deleted".  Those two look identical through find_hat.
            if hat ~= 0 and cur.obj == nil then cur.obj = hat end
            if TRACE and d <= 110 and cur.obj then
                local mp = r32(cur.obj + OIMG)
                local live = false
                for _, head in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
                    local o, g = r32(head), 0
                    while o ~= 0 and g < 300 do
                        if o == cur.obj then live = true break end
                        o = r32(o + OLINK); g = g + 1
                    end
                end
                -- hat_proc's OWN process, found by pa8 == the hat object, so
                -- the flag slots can be read rather than inferred
                local hp, pr, g = 0, r32(A.active), 0
                while pr ~= 0 and g < 200 do
                    -- hat_proc's p_action is 0 (spawn_proj_proc clears it), so match
                    -- on pa8 and take the one carrying a thrower proc in p_store2
                    if r32(pr + 0xc0) == cur.obj and r32(pr + 0x100 + 0x150) ~= 0 then hp = pr break end
                    pr = r32(pr); g = g + 1
                end
                log("    t+%2d obj=%08x onlist=%s sag=%08x x=%4d y=%4d yv=%8d | proc=%08x s1=%04x s2=%08x s3=%04x s6=%08x",
                    d, cur.obj, tostring(live), mp ~= 0 and r32(mp + MP_SAG) or 0,
                    s16(r16(cur.obj + OXPOS)), s16(r16(cur.obj + 0xb0)),
                    s32(r32(cur.obj + OYVEL)), hp,
                    hp ~= 0 and r16(hp + 0x100 + 0x130) or 0,
                    hp ~= 0 and r32(hp + 0x100 + 0x150) or 0,
                    hp ~= 0 and r16(hp + 0x100 + 0x170) or 0,
                    hp ~= 0 and r32(hp + 0x100 + 0x1d0) or 0)
                if hp ~= 0 then
                    log("         p_action=%04x (0500=act_proj_dead: it HIT something)",
                        r16(hp + 0x1f0))
                end
                -- the steer dereferences the THROWER's p_joyport as a pointer
                -- (joystick_in_a0, JOY.ASM), so log the chain it walks
                if hp ~= 0 then
                    local thr = r32(hp + 0x100 + 0x150)
                    local jp  = thr ~= 0 and r32(thr + 0x100) or 0
                    log("         thrower=%08x (p1_proc=%08x) p_joyport=%08x raw=%08x",
                        thr, r32(A.p1_proc), jp, jp ~= 0 and r32(jp) or 0)
                end
            end
            if hat ~= 0 then
                local yv = s32(r32(hat + OYVEL))
                -- THE BUCKET COMES FROM OYVEL, NOT FROM THE SAG.  bysag holds
                -- phase A only, and a phase-B SAG on the dive half is shared
                -- with its climb twin anyway, so there is no sag -> bucket map
                -- to have.  Indexing idxseen with a nil `idx` threw on every
                -- phase-B tick, and because the throw killed the rest of the
                -- handler the run then reported "NEVER SPUN" - the spin was
                -- working the whole time, in runs of exactly slhat_rate.
                -- no sag -> bucket map exists: the same record serves two
                -- buckets across the two facings.  The bucket comes from
                -- oyvel, and the very first sample (no previous oyvel yet)
                -- is simply reported as level.
                local idx = (cur.prev_yv ~= nil) and want_index(cur.prev_yv)
                            or (EXPECT.level - 1)
                if not cur.saw then
                    cur.saw = true
                    log("  hat found at +%d on %s (oyvel %d)", d,
                        frame_name(idx, (r16(hat + OFLAGS) & M_FLIPH) ~= 0, cur.leg or 0), yv)
                end
                if yv < cur.ymin then cur.ymin = yv end
                if yv > cur.ymax then cur.ymax = yv end
                -- THE TURN, watched on the object rather than inferred: oxvel
                -- must change sign and m_fliph must toggle, because the second
                -- is what makes slhat_frame draw the other direction's art.
                do
                    local xv = s32(r32(hat + 0x40))
                    local fl = (r16(hat + OFLAGS) & M_FLIPH) ~= 0
                    if cur.xv0 == nil then cur.xv0, cur.flip0 = xv, fl end
                    -- A LOOP PASSES THROUGH NEAR-ZERO X; a sign flip jumps
                    -- straight from +X to -X and never does.  That is the only
                    -- thing that tells a curl from a snap from out here.
                    local ax = (xv < 0) and -xv or xv
                    if cur.xabs0 == nil then cur.xabs0 = ax end
                    if cur.xabsmin == nil or ax < cur.xabsmin then cur.xabsmin = ax end
                    if cur.xabs0 > 0 and ax < (cur.xabs0 // 2) then
                        cur.curlticks = cur.curlticks + 1
                    end
                    if not cur.reversed and cur.xv0 ~= 0 and xv ~= 0
                       and ((cur.xv0 < 0) ~= (xv < 0)) then
                        cur.reversed = true
                        cur.flipped = (fl ~= cur.flip0)
                        cur.bturn, cur.fturn = nil, nil   -- filled on the NEXT sample
                        log("    TURNED at +%d: oxvel %d -> %d, facing %s -> %s",
                            d, cur.xv0, xv, cur.flip0 and "LEFT" or "RIGHT",
                            fl and "LEFT" or "RIGHT")
                    end
                    cur.tables[fl and "L" or "R"] = true
                end
                do
                    local hp2 = hat_proc_of(hat)
                    cur.legwas = cur.leg
                    cur.leg = (hp2 ~= 0) and r32(hp2 + 0x2f0) or nil   -- p_store7 = pdata+1f0h
                    -- THE THROW LINE.  hat_proc stamps the hat's oypos at the
                    -- top of the flight into slhat_home_y (p_store6+16 =
                    -- pdata+1e0h) and the homeward leg steers back onto it
                    -- when the stick is left alone.  Recorded three ways: the
                    -- rig's own first sighting (so the stamp is checked
                    -- against something the ROM did not write), the stamp,
                    -- and the last homeward sample.
                    if cur.leg == 0 and cur.ysight == nil then
                        cur.ysight = s16(r16(hat + OYPOS))
                        cur.ystamp = s16(r16(hp2 + 0x2e0))
                    end
                    if cur.leg == 1 or cur.leg == 2 then
                        cur.yhome = s16(r16(hat + OYPOS))
                    end
                    -- LEG 3 ONLY.  Leg 4 is the coast - ordinary flight, just
                    -- off the edge, with nothing unusual being drawn - and
                    -- counting it here checked the wrong ticks: the coast is
                    -- marginally clear BY DESIGN (that is what it exists to
                    -- widen), so it reported the rotation as visible when the
                    -- rotation had not started.
                    -- the settle, watched on the homeward legs only
                    if cur.leg == 1 or cur.leg == 2 then
                        local hy = s32(r32(hat + OYVEL))
                        local ay = (hy < 0) and -hy or hy
                        if cur.homeyv0 == nil then cur.homeyv0 = ay end
                        if cur.homeyvmin == nil or ay < cur.homeyvmin then
                            cur.homeyvmin = ay
                        end
                        if ay == 0 then cur.homeflat = true end
                    end
                    if cur.leg == 3 then
                        cur.curlseen = true
                        cur.curlticksseen = cur.curlticksseen + 1
                        -- *** THE ONE THAT MATTERS FOR KUNG LAO. ***  The
                        -- rotation has to happen OUT OF SIGHT: the hat leaves
                        -- one side and comes back already travelling the other
                        -- way, so the change of art reads as flush instead of
                        -- as a pivot the player watched.  Any tick of the curl
                        -- spent on screen is the whole point lost, so it is
                        -- counted and it must be zero.
                        local wx = s16(r16(A.worldtlx + 16))
                        local hx = s16(r16(hat + OXPOS))
                        -- the hat spans about anchor-28 .. anchor+26, so 32
                        -- either side of the anchor is its real extent.  64 was
                        -- too generous and called a hat 36px CLEAR of the edge
                        -- "on screen".
                        if hx + 32 > wx and hx - 32 < wx + 399 then
                            cur.curlvis = cur.curlvis + 1
                            if cur.curlvis <= 3 then
                                log("    CURL SEEN ON SCREEN +%d: hat x=%d, window %d..%d",
                                    d, hx, wx, wx + 399)
                            end
                        end
                    end
                    -- THE TWIN IS READ WHEN THE CURL ENDS, not when oxvel
                    -- crosses zero.  That crossing is the MIDDLE of the loop -
                    -- ninety degrees through, where the velocity is almost all
                    -- vertical and oyvel is at its largest with the sign it
                    -- started with.  The sign flip that lands bucket N on 10-N
                    -- only exists after the full half turn.
                    if cur.legwas == 3 and cur.leg ~= 3 and cur.yvturn == nil then
                        cur.yvturn = s32(r32(hat + OYVEL))
                        cur.bturn = want_index(cur.yvturn)
                        cur.fturn = frame_name(cur.bturn, (r16(hat + OFLAGS) & M_FLIPH) ~= 0, cur.leg)
                        log("    OUT OF THE CURL at +%d: bucket %s (%s) -> %s (%s)",
                            d, tostring(cur.bprev), cur.fprev or "?",
                            tostring(cur.bturn), cur.fturn or "?")
                    end
                end
                -- SEED THE HEIGHT ONCE, on the first tick the hat exists.
                if cur.hatyv and not cur.yvseeded then
                    w32(hat + OYVEL, cur.hatyv & 0xffffffff)
                    cur.yvseeded = true
                    cur.yvseed_at = d
                    log("    seeded oyvel %d (%.2f px/tick) for the contact-height A/B",
                        cur.hatyv, cur.hatyv / 65536)
                end
                if cur.drone and not cur.seeded then
                    local hp2 = hat_proc_of(hat)
                    if hp2 ~= 0 then
                        local thr = r32(hp2 + P_STORE2)
                        if thr ~= 0 then
                            -- make the thrower look like a drone to slhat_hp_held
                            w16(thr + P_FLAGS, r16(thr + P_FLAGS) & 0xfffe)
                            w16(hp2 + P_STORE5, 40)
                            cur.budget0 = 40
                            cur.seeded = true
                            log("    seeded drone budget 40 on proc %08x (thrower %08x)", hp2, thr)
                        end
                    end
                end
                if cur.drone and cur.seeded then
                    local hp2 = hat_proc_of(hat)
                    if hp2 ~= 0 then cur.budget1 = r16(hp2 + P_STORE5) end
                end
                -- act_proj_dead (0500h) is the engine-wide "spent" marker
                -- dead_projectile stamps on contact.  Every SLICEHAT frame
                -- seen AFTER it is the hat keeping the art it hit with; a
                -- revert would drop it out of find_hat entirely.
                do
                    local hp2, pr, g = 0, r32(A.active), 0
                    while pr ~= 0 and g < 200 do
                        if r32(pr + 0xc0) == hat and r32(pr + 0x100 + 0x150) ~= 0 then hp2 = pr break end
                        pr = r32(pr); g = g + 1
                    end
                    if hp2 ~= 0 and r16(hp2 + 0x1f0) == 0x500 then
                        if cur.hitat == nil then
                            cur.hitat = d
                            log("    HIT at +%d - hat is spent; watching what it draws now", d)
                            -- WHERE HE WAS HIT.  The victim is P2 here, so the
                            -- second long of the pair.  Read on the tick the
                            -- hat is marked spent, which is the tick after
                            -- strike_check stamped it and before anything else
                            -- can hit him.
                            if A.hit_pt then
                                local v = r32(A.hit_pt + 32)
                                cur.hpt  = v
                                cur.hpty = s16((v >> 16) & 0xffff)
                                cur.hptx = s16(v & 0xffff)
                                cur.haty = s16(r16(hat + OYPOS))
                                log("    CONTACT POINT [y=%d x=%d] off his origin"
                                    .. " (his top y=%d, the hat at y=%d)",
                                    cur.hpty, cur.hptx, s16(r16(p2o + OYPOS)), cur.haty)
                            end
                        end
                        cur.aftr = cur.aftr + 1
                    end
                end
                if not cur.idxseen[idx] then
                    cur.idxseen[idx] = true
                    cur.order[#cur.order+1] = idx
                    local nm = frame_name(idx, (r16(hat + OFLAGS) & M_FLIPH) ~= 0, cur.leg)
                    cur.names = cur.names or {}
                    cur.names[idx] = nm
                    log("    +%2d  %-11s idx=%d  oyvel=%8d (%6.2f px/tick, %5.1f deg)",
                        d, nm, idx, yv, yv / 65536,
                        math.deg(math.atan(yv / 65536 / 12.0)))
                end
                -- THE TURN TICK IS EXEMPT FROM THE LAG MODEL.  Every other tick
                -- draws from the oyvel it STARTED with, so the frame on screen
                -- belongs to the previous sample - but slhat_reverse negates
                -- oyvel and calls slhat_frame in the same breath, so on that one
                -- tick the frame is already the post-turn one.  Measured: the
                -- ROM drew bucket 10-N there while this expected N, which is the
                -- twin pairing working, not failing.
                -- THE CURL IS EXEMPT FROM THE LAG MODEL.  In steady flight the
                -- steer runs after the frame, so the frame belongs to the
                -- previous sample's oyvel.  Through the curl the rotation runs
                -- at the top of the tick instead, so the frame can belong to
                -- either side of it - and oyvel moves far enough per tick that
                -- the two are different buckets.  Accept whichever matches; the
                -- loop has its own assertions (it passes through near-zero x,
                -- the facing flips, and the bank reverses across it).
                local incurl = (cur.leg == 3) or (cur.legwas == 3)
                local turning = cur.reversed and cur.bturn == nil and cur.bprev ~= nil
                -- THE SEEDING TICK IS EXEMPT, for the turn's own reason: the
                -- frame on screen was picked from the oyvel this tick began
                -- with, and the rig has just written a different one.
                if cur.yvseed_at ~= nil and d <= cur.yvseed_at + 1 then turning = true end
                -- the frame on screen was chosen from the PREVIOUS tick's oyvel
                if cur.prev_yv ~= nil and not turning then
                    local wi = want_index(cur.prev_yv)
                    local F = EXPECT.frames[wi + 1]
                    -- THE HAT'S OWN FACING PICKS THE SET, and the flip mask
                    -- says whether that bucket is drawn mirrored on top of it.
                    -- Checking the frame alone would pass on a hat flying
                    -- trail-first; checking one facing only would never draw
                    -- SLICEHAT12-16 at all.
                    local objflip = (r16(hat + OFLAGS) & M_FLIPH) ~= 0
                    -- slhatdark: the OUTWARD leg draws the leftward set
                    -- whichever way it flies (leg 0, or a hat that connected
                    -- outward and kept its bank)
                    -- (outward = leftward/darker set, home = rightward/lighter)
                    local useleft = objflip
                    if (EXPECT.dark or 0) ~= 0 and cur.leg ~= nil then useleft = (cur.leg == 0) end
                    local wantsag = useleft and F.lsag or F.rsag
                    local wantnm  = useleft and F.lname or F.rname
                    local from    = useleft and EXPECT.flipfrom_l or EXPECT.flipfrom_r
                    local xflip   = wi >= from
                    -- the piece's control word is the record's XOR the object's
                    -- flip as it stood when ani2 laid it, so this is a plain
                    -- boolean XOR.  Written as `xflip and (not objflip) or
                    -- objflip' it collapses to `objflip' whenever the middle
                    -- term is false - Lua's and/or trap - and then agreed with
                    -- a build that never flipped at all.
                    local need = (objflip ~= xflip)
                    local got = (r16(mp + MP_CONTROL) & M_FLIPH) ~= 0
                    if incurl then
                        -- either side of the rotation is acceptable here
                        local alt = EXPECT.frames[want_index(yv) + 1]
                        local altsag = useleft and alt.lsag or alt.rsag
                        if sag == wantsag or sag == altsag then
                            cur.agree = cur.agree + 1
                        else
                            cur.mismatch = cur.mismatch + 1
                            if cur.mismatch <= 4 then
                                log("    MISMATCH +%d (curl): drew %08x, wanted %s or %s",
                                    d, sag, wantnm, alt and (useleft and alt.lname or alt.rname) or "?")
                            end
                        end
                    elseif sag ~= wantsag then
                        cur.mismatch = cur.mismatch + 1
                        if cur.mismatch <= 4 then
                            log("    MISMATCH +%d: drew sag %08x, oyvel %d wanted bucket %d (%s, facing %s)",
                                d, sag, cur.prev_yv, wi, wantnm, objflip and "LEFT" or "RIGHT")
                        end
                    elseif got ~= need then
                        cur.flipbad = cur.flipbad + 1
                        if cur.flipbad <= 4 then
                            log("    TRAIL BACKWARDS +%d: %s drawn flip=%s, want %s (obj flip=%s)",
                                d, wantnm, tostring(got), tostring(need), tostring(objflip))
                        end
                    else
                        cur.agree = cur.agree + 1
                    end
                end
                -- THE TWIN CHECK.  The turn negates oyvel as well as oxvel, so
                -- bucket N must become bucket 10-N - which is what lands the
                -- return on the hand-drawn opposite (1<->12, 6<->7) instead of
                -- a mirrored sprite.  Recorded either side of the reversal.
                -- the CURRENT yv, every pre-curl sample: the curl can begin on
                -- the second tick the hat is visible, and waiting for prev_yv
                -- left nothing recorded at all on a steered throw
                if cur.leg ~= 3 and not cur.curlseen then
                    cur.bprev = want_index(yv)
                    cur.yvprev = yv
                    cur.fprev = frame_name(cur.bprev, (r16(hat + OFLAGS) & M_FLIPH) ~= 0, cur.leg)
                end
                cur.prev_yv = yv
                if SNAP and d >= 10 and d <= 27 then
                    manager.machine.video:snapshot()
                end
            end
            if d >= 110 then
                cur.fpal1 = A.fpal_fail and r16(A.fpal_fail) or 0
                results[#results+1] = cur
                phase, t0 = "cool", frame
            end

        elseif phase == "cool" then
            if frame - t0 > 60 then phase = "idle" end
        end

        if trial >= #TRIALS and phase == "idle" then finish(); return end
        if r > 5200 then log("ran out of time"); finish(); return end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 14000 and not done then log("timeout"); finish() end
end)

emu.register_stop(function() if logfh then pcall(function() logfh:flush(); logfh:close() end) end end)
