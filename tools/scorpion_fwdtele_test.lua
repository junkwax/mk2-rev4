-- scorpion_fwdtele_test.lua
--
-- SCORPION'S FORWARD TELEPORT PUNCH, Down,Forward + LOW PUNCH
-- (scfwdtele, MAINEQU.ASM; do_fwd_decoy, MKPROP.ASM).
--
-- The move is do_decoy with the direction mirrored, so the rig's whole job is
-- to prove the three things that differ and that NOTHING else did:
--
--   the FLAG      f_fwdtele is 1 for the forward flight and 0 for retail's.
--                 Reading it is what tells a working fork from a coincidence:
--                 a hard-coded sign gives the right velocity on one side of
--                 the screen, and a stale facing bit looks like a kept one.
--   the VELOCITY  oxvel points TOWARDS the other man rather than away, and
--                 |oxvel| is STILL 0c0000h - the magnitude is shared, only
--                 the sign moved.
--   the FACING    m_fliph is UNCHANGED across takeoff, where retail's
--                 flip_multi inverts it.  A rig watching direction alone would
--                 miss this, and it is the half of the change that decides
--                 whether he lands facing the fight or with his back to it.
--
-- ...and then the thing none of those proves: THE WARP STILL HAPPENS, at the
-- edge he was flying toward.  cos_edge picks that edge off the SIGN of oxvel
-- rather than off the facing flag, which is the whole reason the shared code
-- needed no change - so the warp is the test of that reasoning, not a bonus.
--
-- TRIALS
--   fwd       P1 left of P2, D,F+HP   -> flag 1, oxvel POSITIVE, no flip,
--                                        warp at the RIGHT edge
--   back      same spot, D,B+HP       -> flag 0, oxvel NEGATIVE, FLIPPED,
--                                        warp at the LEFT edge   (the CONTROL)
--   fwdleft   P1 RIGHT of P2, D,F+HP  -> flag 1, oxvel NEGATIVE, no flip,
--                                        warp at the LEFT edge
--   cool      D,F+HP with l_decoy stamped NOW -> refused, no act_decoy
--   coolback  D,B+HP with l_decoy stamped NOW -> refused.  This is what proves
--             the two teleports SHARE the cooldown word: the backward one is
--             refused by a timer only a forward cast could have set.
--
-- fwdleft is not padding.  A hard-coded sign passes `fwd` on one side of the
-- screen and fails on the other, which is exactly the bug class towards_x_vel
-- exists to avoid - it resolves the direction off is_he_right every cast.
--
-- WHY THE VICTIM IS TELEPORTED OUT OF THE WAY ON THE TAKEOFF FRAME:
-- crossover_scan strike-checks from tick one and the box reaches 076h, so a
-- forward teleport aimed at a man standing there CONNECTS - decoy_hit freezes
-- the flight and there is no warp left to measure.  That is the move working
-- correctly, so the rig moves him opposite the travel on the first act_decoy
-- frame, AFTER reading the launch velocity - which dec_takeoff has already
-- written by then, because do_decoy runs entry -> velocity in ONE process turn
-- with no sleep.  So the frame Lua first sees act_decoy on already has oxvel.
--
--   env: SFT_LOG  log path      SFT_MAP  a map to read instead of src/mk2.map

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("[\\]", "/")
local LOG  = os.getenv("SFT_LOG") or (ROOT .. "/tools/scorpion_fwdtele_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[sft] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

-- ---------------------------------------------------------------- source read
-- Every number below is READ OUT OF THE BUILD, never typed here: a rig holding
-- its own copy of scrrgt or act_decoy passes against a tree that moved them.
local function scan(path, pats)
    local out = {}
    local fh = assert(io.open(ROOT .. path, "r"))
    for line in fh:lines() do
        for key, pat in pairs(pats) do
            if out[key] == nil then
                local v = line:match(pat)
                if v then out[key] = v end
            end
        end
    end
    fh:close()
    return out
end

local d = scan("/src/DISPEQU.ASM", {
    scrrgt = "^scrrgt%s+%.set%s+(%d+)",
    fliph  = "^m_fliph%s+%.set%s+0?(%x+)h",
    oxvel  = "^oxvel%s+%.set%s+0?(%x+)h",
    oxpos  = "^oxpos%s+%.set%s+0?(%x+)h",
    oxval  = "^oxval%s+%.set%s+0?(%x+)h",
    oflags = "^oflags%s+%.set%s+0?(%x+)h",
})
local m = scan("/src/MAINEQU.ASM", {
    on        = "^scfwdtele%s+%.set%s+(%d+)",
    act_decoy = "^act_decoy%s+%.set%s+0?(%x+)h",
    act_fk_sd = "^act_fk_sd%s+%.set%s+0?(%x+)h",
    p_action  = "^p_action%s+%.set%s+pdata%+0?(%x+)h",
})

-- A constant that could not be read must STOP the run, never quietly fall back
-- to a default: a rig testing against a number it invented reports a confident
-- wrong answer, which is worse than no answer at all.
local fatal = false
local function need(v, what, base)
    if v == nil then
        log("FATAL: could not read %s out of the source", what)
        fatal = true
        return 0
    end
    return tonumber(v, base)
end

local SCRRGT    = need(d.scrrgt, "scrrgt (DISPEQU.ASM)")
local M_FLIPH   = need(d.fliph,  "m_fliph (DISPEQU.ASM)", 16)
local O_OXVEL   = need(d.oxvel,  "oxvel (DISPEQU.ASM)",  16)
local O_OXPOS   = need(d.oxpos,  "oxpos (DISPEQU.ASM)",  16)
local O_OXVAL   = need(d.oxval,  "oxval (DISPEQU.ASM)",  16)
local O_OFLAGS  = need(d.oflags, "oflags (DISPEQU.ASM)", 16)
local ACT_DECOY = need(m.act_decoy, "act_decoy (MAINEQU.ASM)", 16)
local P_ACTION  = 0x100 + need(m.p_action, "p_action (MAINEQU.ASM)", 16)  -- pdata is 100h
local SCFWDTELE = need(m.on, "scfwdtele (MAINEQU.ASM)")
local ACT_FK_SD = need(m.act_fk_sd, "act_fk_sd (MAINEQU.ASM)", 16)

-- The cooldown gate, lifted out of sc_lp_fwdtele itself rather than retyped.
local COOL
do
    local fh = assert(io.open(ROOT .. "/src/MOVES.ASM", "r"))
    local inblock = false
    for line in fh:lines() do
        if line:match("^sc_hp_fwdtele") then inblock = true end
        if inblock then
            local v = line:match("^%s*cmpi%s+0?(%x+)h,a1")
            if v then COOL = tonumber(v, 16); break end
            if line:match("airborn_xfer") then break end
        end
    end
    fh:close()
end
COOL = need(COOL and string.format("%x", COOL) or nil,
            "the cooldown cmpi inside sc_hp_fwdtele (MOVES.ASM)", 16)

-- The launch speed, so |oxvel| is checked against the source and not a memory.
--
-- ANCHORED ON dec_takeoff, deliberately.  MKPROP has an EARLIER
-- `calla away_x_vel` (do_reptile_superk's), so a scan from the top of the file
-- reads another move's velocity; and the `.if scfwdtele` block now sits between
-- the `movi` and the call, so "the line before away_x_vel" is `.endif`.  Both
-- failures are silent - they hand back a plausible number - which is why this
-- walks the takeoff block and keeps the LAST movi into a0 before the call.
local XVEL, XVEL_FWD
do
    local fh = assert(io.open(ROOT .. "/src/MKPROP.ASM", "r"))
    local inblock, lastmovi = false, nil
    for line in fh:lines() do
        if line:match("^dec_takeoff") then inblock = true end
        if inblock then
            local v = line:match("^%s*movi%s+0?(%x+)h,a0")
            if v then lastmovi = v end
            if line:match("calla%s+away_x_vel") and not XVEL then XVEL = lastmovi end
            -- the forward teleport carries its own speed (retail's 080000h)
            if line:match("calla%s+towards_x_vel") then XVEL_FWD = lastmovi; break end
        end
    end
    fh:close()
end
XVEL = need(XVEL, "do_decoy's launch velocity (the movi before away_x_vel in "
                  .. "dec_takeoff, MKPROP.ASM)", 16)
XVEL_FWD = need(XVEL_FWD, "the forward launch velocity (the movi before towards_x_vel)", 16)

log("build: scfwdtele=%d act_decoy=%04x scrrgt=%d m_fliph=%02x cooldown=%02xh xvel=%05xh "
    .. "(%.1f px/tick)", SCFWDTELE, ACT_DECOY, SCRRGT, M_FLIPH, COOL, XVEL, XVEL / 65536)
if SCFWDTELE == 0 then
    log("scfwdtele is 0 - the move is COMPILED OUT, so every forward trial must be REFUSED")
end

-- ------------------------------------------------------------------- symbols
-- A MISSING MAP IS A REFUSAL, not a traceback.  Several sessions build in this
-- tree and a failed assembly DELETES mk2.out and mk2.map, so "the map is not
-- there" is this rig's most likely real failure - it means somebody's build is
-- mid-flight or just broke, which is nothing to do with the move under test.
local symbols = {}
do
    local mappath = os.getenv("SFT_MAP") or (ROOT .. "/src/mk2.map")
    local fh = io.open(mappath, "r")
    if not fh then
        log("FATAL: no map at %s - a build is mid-flight or just failed "
            .. "(a failed assembly deletes mk2.out and mk2.map).  NOT a verdict "
            .. "about the teleport.", mappath)
        fatal = true
    else
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local A, missing = {}, fatal
if not fatal then
    for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar",
                         "p1_obj", "p2_obj", "p1_proc", "tick", "l_decoy", "f_fwdtele",
                         "worldtlx" }) do
        A[n] = symbols[n]
        if not A[n] then log("FATAL: '%s' not in the map", n); missing = true end
    end
end

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION, FT_JAX, MAX_HP = 10, 11, 0xa1
local ACT_STANCE = 0x0303

-- Gap between the pair while a trial is set up.  Wide enough that a REFUSED
-- cast's ordinary punch whiffs instead of starting a string that would carry
-- into the next trial.
local GAP = 150
local CLEAR = 260       -- how far the victim is moved out of the flight path
local MIDX = 200        -- both fighters parked either side of here

local TRIALS = {
    { label = "fwd",      side = "left",  button = "P1 High Punch",  motion = "fwd",
      stamp = false, want = { flag = 1, dir = 1,  flip = false, warp =  0 } },
    { label = "back",     side = "left",  button = "P1 High Punch", motion = "back",
      stamp = false, want = { flag = 0, dir = -1, flip = true,  warp =  1 } },
    { label = "fwdleft",  side = "right", button = "P1 High Punch",  motion = "fwd",
      stamp = false, want = { flag = 1, dir = -1, flip = false, warp =  0 } },
    { label = "cool",     side = "left",  button = "P1 High Punch",  motion = "fwd",
      stamp = true,  want = { refused = true } },
    { label = "coolback", side = "left",  button = "P1 High Punch", motion = "back",
      stamp = true,  want = { refused = true } },
    -- FLIP KICK ON A STANDING MAN, then the teleport.  The forward one must be
    -- refused (no flip kick -> forward teleport juggle, the user's rule
    -- 2026-10-12); the backward one must still come out; and a plain jump
    -- (no kick) must still allow the forward one - "it can be done in the air".
    { label = "fkfwd",    side = "left",  button = "P1 High Punch", motion = "fwd",
      jump = "kick", stamp = false, want = { refused = true, contact = true } },
    { label = "fkback",   side = "left",  button = "P1 High Punch", motion = "back",
      jump = "kick", stamp = false, want = { allowed = true, contact = true } },
    { label = "airfwd",   side = "left",  button = "P1 High Punch", motion = "fwd",
      jump = "plain", stamp = false, want = { allowed = true } },
}
local ONLY = os.getenv("SFT_ONLY")
if ONLY then
    local keep = {}
    for _, T in ipairs(TRIALS) do if ONLY:find(T.label, 1, true) then keep[#keep+1] = T end end
    TRIALS = keep
end
local FK_GAP   = tonumber(os.getenv("SFT_FKGAP") or "210")
local FK_PRESS = tonumber(os.getenv("SFT_FKPRESS") or "22")

-- THE NEGATIVE CONTROL.  Swapping the two directions is the likely regression,
-- so the control crosses exactly that: `fwd` is given retail's expectation and
-- `back` is given the forward one, and every crossed trial must FAIL.  The two
-- cooldown trials are a control of a different kind and are left alone, so they
-- are not counted either way in a negative run.
local NEGATIVE = (os.getenv("SFT_NEGATIVE") == "1")
if NEGATIVE then
    TRIALS[1].want, TRIALS[2].want = TRIALS[2].want, TRIALS[1].want
    TRIALS[3].want = TRIALS[1].want         -- the wrong side as well
    log("NEGATIVE: fwd/back expectations crossed - every crossed trial must FAIL")
end

local space, fields, held = nil, {}, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function s32(v) return v >= 0x80000000 and v - 0x100000000 or v end
local function hold(n, on) held[n] = on and true or false end

local frame, psel, confirm, fight_at, done = 0, 0, 0, 0, false
local trial, phase, t0, cur = 0, "idle", 0, nil
local results = {}

-- "UI Select" is NOT in this list, though other rigs in the tree ask for it.
-- It is a MAME UI input, not an ioport field, so the lookup below never finds
-- it and holding it does nothing: the red ROM-warning screen is answered from
-- OUTSIDE, by tools/mame_dismiss_warning.ps1, which the wrapper starts as its
-- own process (a poker inside the launching shell can never win the
-- foreground - see that script's header).
local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1,
                   ["P1 Left"]=1, ["P1 Right"]=1, ["P1 Down"]=1,
                   ["P1 Low Punch"]=1, ["P1 High Punch"]=1, ["P2 Low Punch"]=1,
                   ["P1 Up"]=1, ["P1 High Kick"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x)
    w16(obj + O_OXPOS, x & 0xffff); w32(obj + O_OXVAL, (x << 16) & 0xffffffff)
end
local function flipped(obj) return (r16(obj + O_OFLAGS) & M_FLIPH) ~= 0 end
local function p1act()
    local pp = r32(A.p1_proc)
    return pp ~= 0 and r16(pp + P_ACTION) or 0xffff
end

local function finish()
    done = true
    log("---- results ----")
    local fails = 0
    for _, x in ipairs(results) do
        local ok, why
        if x.want.contact and not x.contact then
            ok, why = false, "flip kick NEVER CONNECTED on the standing man - this trial measured NOTHING"
        elseif x.want.allowed then
            ok = x.saw
            why = x.saw and "act_decoy came out (allowed, as it must be)"
                        or "act_decoy NEVER came out - it was refused"
        elseif x.want.refused then
            ok = not x.saw
            why = string.format("act_decoy %s (cooldown %02xh, get_tsl reads %d)",
                x.saw and "CAME OUT - the cooldown did not refuse it" or "never appeared",
                COOL, x.tsl or -1)
        elseif not x.saw then
            ok, why = false, "NEVER REACHED act_decoy - this trial measured NOTHING"
        else
            local dir_ok  = (x.xvel > 0 and x.want.dir > 0) or (x.xvel < 0 and x.want.dir < 0)
            local wantv   = (x.want.flag == 1) and XVEL_FWD or XVEL
            local mag_ok  = math.abs(x.xvel) == wantv
            local flip_ok = (x.flip_changed == x.want.flip)
            local warp_ok = (x.warp == x.want.warp)
            local flag_ok = (x.flag == x.want.flag)
            ok = dir_ok and mag_ok and flip_ok and warp_ok and flag_ok
            why = string.format(
                "f_fwdtele=%d(want %d)%s oxvel=%+d (%.1f px/tick)%s facing %s(want %s)%s "
                .. "warp %s(want %s edge)%s",
                x.flag, x.want.flag, flag_ok and "" or " <BAD>",
                x.xvel, x.xvel / 65536, dir_ok and "" or " <WRONG WAY>",
                x.flip_changed and "FLIPPED" or "kept",
                x.want.flip and "FLIPPED" or "kept", flip_ok and "" or " <BAD>",
                x.warp == -1 and "RIGHT edge" or (x.warp == 1 and "LEFT edge" or "NONE"),
                x.want.warp == -1 and "RIGHT" or (x.want.warp == 1 and "LEFT" or "NO"), warp_ok and "" or " <BAD>")
            if not mag_ok then
                why = why .. string.format(" <MAGNITUDE %x != %x>", math.abs(x.xvel), wantv)
            end
        end
        x.ok = ok
        if not ok then fails = fails + 1 end
        log("  %-9s %s  %s", x.label, why, ok and "OK" or "FAIL")
    end
    if #results == 0 then
        fails = 1
        log("  NO TRIALS RAN - an empty run is a FAILURE, not a pass")
    end
    if NEGATIVE then
        -- Only the three crossed trials count.  A crossed trial that still
        -- passes means the rig is not discriminating, which is the thing a
        -- negative run exists to catch.
        local crossed, crossed_failed = 0, 0
        for _, x in ipairs(results) do
            if not x.want.refused and not x.want.allowed then
                crossed = crossed + 1
                if not x.ok then crossed_failed = crossed_failed + 1 end
            end
        end
        local good = (crossed > 0) and (crossed_failed == crossed)
        log("%s NEGATIVE: %d/%d crossed trials FAILED as they must",
            good and "PASS" or "FAIL", crossed_failed, crossed)
        logfh:flush(); logfh:close()
        manager.machine:exit()
        return
    end
    local passed = #results - fails
    if passed < 0 then passed = 0 end
    log("%s forward teleport: %d/%d trials (failures=%d)",
        fails == 0 and "PASS" or "FAIL", passed, #results, fails)
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
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start" }) do
            hold(n, false)
        end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 3000
                                and (frame % 80) >= 45 and (frame % 80) < 70)
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
        -- setup_players reads @p1_char/@p2_char in the ROUND INTRO, so the pair
        -- is pinned until the fight is actually running.
        if gs == GS_POST then w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX) end
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame,
                r16(A.p1_char), r16(A.p2_char))
            if r16(A.p1_char) ~= FT_SCORPION then
                log("P1 is not Scorpion - NO VERDICT"); finish(); return
            end
        end
        if fight_at == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        local r = frame - fight_at
        -- Pin BOTH bars every frame: one pinned bar lets the other empty and
        -- the round ends in the middle of a sweep.
        if cur and cur.T.jump == "kick" and (phase == "cast" or phase == "fkwait")
           and r16(A.p2_bar) < MAX_HP and not cur.contact then
            cur.contact = true
            cur.contact_act = p1act()
            log("  CONTACT at +%d: p2_bar %d, p1 act=%04x", frame - t0, r16(A.p2_bar), cur.contact_act)
        end
        w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        for n in pairs(fields) do hold(n, false) end
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o == 0 or p2o == 0 then
            for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
            return
        end

        if phase == "idle" then
            if r >= 100 and trial < #TRIALS then
                trial = trial + 1
                local T = TRIALS[trial]
                cur = { label = T.label, want = T.want, T = T,
                        saw = false, warp = 0, flag = -1, xvel = 0 }
                phase, t0 = "park", frame
                log("trial %d (%s): %s + %s, l_decoy %s", trial, T.label, T.motion,
                    T.button, T.stamp and "STAMPED NOW (must refuse)" or "aged out")
            end

        elseif phase == "park" then
            -- Mid-screen, so there is room to reach an edge either way.
            -- RELATIVE TO THE CAMERA: the forward teleport flies at retail's
            -- 8 px/tick now and from mid-screen it lands ~150px on without
            -- reaching an edge, so it no longer warps home and the camera is
            -- not where the last trial left it.  worldtlx is 16.16; its whole
            -- part is the high word.
            local mid = s16(r16(A.worldtlx + 16)) + MIDX
            local gap = cur.T.jump and FK_GAP or GAP
            if cur.T.side == "left" then
                place(p1o, mid - gap // 2); place(p2o, mid + gap // 2)
            else
                place(p1o, mid + gap // 2); place(p2o, mid - gap // 2)
            end
            -- l_decoy is a p1/p2 PAIR of words and p1's is the first.  Writing
            -- it is how the cooldown gets tested deterministically, instead of
            -- by racing the previous trial's landing (run_rain_halfdmg_probe
            -- seeds rh_cdmg for the same reason).
            if cur.T.stamp then
                w16(A.l_decoy, r16(A.tick))                       -- elapsed 0 -> refuse
            else
                w16(A.l_decoy, (r16(A.tick) - 0x200) & 0xffff)    -- long ago -> allow
            end
            if frame - t0 > 10 and p1act() == ACT_STANCE then
                cur.pre_flip = flipped(p1o)
                cur.tsl = (r16(A.tick) - r16(A.l_decoy)) & 0xffff
                phase, t0 = "cast", frame
                log("  parked: p1x=%d p2x=%d facing=%s tsl=%d",
                    s16(r16(p1o + O_OXPOS)), s16(r16(p2o + O_OXPOS)),
                    cur.pre_flip and "left" or "right", cur.tsl)
            elseif frame - t0 > 120 then
                log("  never settled into act_stance (act=%04x) - NO VERDICT", p1act())
                phase, t0 = "cool", frame
            end

        elseif phase == "cast" then
            -- Down, RELEASE, then the direction, then the button.  Holding the
            -- two together never matches: the release is what puts two separate
            -- entries in the stick queue for combo_look_lr to find.
            local dd = frame - t0
            if cur.T.jump and not cur.jumped then
                local tow = (cur.T.side == "left") and "P1 Right" or "P1 Left"
                if dd < 4 then hold("P1 Up", true); hold(tow, true) end
                if cur.T.jump == "kick" and dd >= FK_PRESS and dd < FK_PRESS + 3 then
                    hold("P1 High Kick", true)
                end
                if dd % 3 == 0 then
                    log("    j+%2d act=%04x p1x=%d p1y=%d p2x=%d p2y=%d", dd, p1act(),
                        s16(r16(p1o + O_OXPOS)), s16(r16(p1o + O_OXPOS + 0x20)),
                        s16(r16(p2o + O_OXPOS)), s16(r16(p2o + O_OXPOS + 0x20)))
                end
                local ready = (cur.T.jump == "kick") and cur.contact or (cur.T.jump == "plain" and dd >= 10)
                if ready then cur.jumped = true; t0 = frame; dd = 0
                    log("  jump ready: p1 act=%04x (act_fk_sd=%04x)", p1act(), ACT_FK_SD)
                elseif dd > 90 then
                    log("  jump trial: no contact by +90 (act=%04x)", p1act())
                    results[#results+1] = cur; phase, t0 = "cool", frame
                end
                for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
                return
            end
            local dirkey
            if cur.T.motion == "fwd" then
                dirkey = (cur.T.side == "left") and "P1 Right" or "P1 Left"
            else
                dirkey = (cur.T.side == "left") and "P1 Left" or "P1 Right"
            end
            if dd >= 0 and dd < 3 then hold("P1 Down", true) end
            if dd >= 5 and dd < 8 then hold(dirkey, true) end
            if dd >= 10 and dd < 14 then hold(cur.T.button, true) end
            if dd >= 14 then
                if cur.T.jump then log("  teleport pressed; p1 act=%04x", p1act()) end
                phase, t0 = "fly", frame
            end

        elseif phase == "fly" then
            local dd = frame - t0
            local act = p1act()
            local x = s16(r16(p1o + O_OXPOS))
            if act == ACT_DECOY and not cur.saw then
                -- Takeoff.  oxvel is ALREADY written this turn, so it is read
                -- before the victim is moved.
                cur.saw = true
                cur.xvel = s32(r32(p1o + O_OXVEL))
                cur.flag = r16(A.f_fwdtele)
                cur.flip_changed = (flipped(p1o) ~= cur.pre_flip)
                cur.x0 = x
                cur.stamped = r16(A.l_decoy)
                log("  takeoff +%d: oxvel=%+d (%.1f px/tick) f_fwdtele=%d facing %s->%s "
                    .. "l_decoy=%d tick=%d", dd, cur.xvel, cur.xvel / 65536, cur.flag,
                    cur.pre_flip and "left" or "right",
                    flipped(p1o) and "left" or "right", cur.stamped, r16(A.tick))
            end
            if cur.saw and not cur.T.jump then
                -- Keep the victim OUT OF THE FLIGHT PATH every tick: the strike
                -- box is live from tick one, and a teleport that CONNECTS
                -- freezes in the air with no warp left to measure.
                local behind = (cur.xvel > 0) and (x - CLEAR) or (x + CLEAR)
                place(p2o, behind)
                if cur.lastx then
                    local dx = x - cur.lastx
                    -- cross_warp moves him by a whole screen in one tick.
                    if dx < -(SCRRGT // 2) then cur.warp = -1        -- at the RIGHT edge
                    elseif dx > (SCRRGT // 2) then cur.warp = 1 end  -- ...or the LEFT one
                end
                cur.lastx = x
            end
            if os.getenv("SFT_TRACE") and dd <= 24 then
                log("    t%2d act=%04x x=%d oxvel=%.1f p2x=%d p2bar=%d", dd, act, x, s32(r32(p1o + O_OXVEL)) / 65536,
                    s16(r16(p2o + O_OXPOS)), r16(A.p2_bar or 0))
            end
            if dd % 8 == 0 and dd <= 96 then
                log("    +%2d act=%04x x=%d flag=%d", dd, act, x, r16(A.f_fwdtele))
            end
            if dd >= 110 or (cur.saw and act ~= ACT_DECOY and dd > 20)
               or (cur.T.jump and (cur.saw or dd >= 80)) then
                results[#results+1] = cur
                log("  %s: saw=%s warp=%d", cur.label, tostring(cur.saw), cur.warp)
                phase, t0 = "cool", frame
            end

        elseif phase == "cool" then
            if frame - t0 > 70 then phase = "idle" end
        end

        if trial >= #TRIALS and phase == "idle" then finish(); return end
        if r > 6000 then log("ran out of time"); finish(); return end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 20000 and not done then log("timeout"); finish() end
end)

local function on_stop()
    if logfh then pcall(function() logfh:flush(); logfh:close() end) end
end
-- emu.register_stop is deprecated in current MAME and prints a [LUA] notice;
-- the notifier is the replacement.  Both are kept because other rigs in this
-- tree still run on the older call.
if emu.add_machine_stop_notifier then
    emu.add_machine_stop_notifier(on_stop)
else
    emu.register_stop(on_stop)
end
