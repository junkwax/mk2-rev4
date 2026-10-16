-- sweep_addon_frozenspit.lua - does Reptile keep his FACE when he is frozen
--                              in the middle of the acid spit?
--
-- The spit draws his face on a SEPARATE object (its own palette, REPHED_P,
-- 5bpp/32 entries against the body's 6bpp/64), re-anchored to the body every
-- tick by match_ani_points inside face_sleep.  Every reaction deletes the
-- victim's slaves, and r_ice is the one reaction that does not animate
-- afterwards - so freezing him mid-spit used to hold a headless Reptile for
-- 080h ticks.  r_ice now rescues that object before chores can take it and
-- hands it to freeze_spit_face, which recolours it to REPFFRZ_P and starts
-- frozen_face_proc (pid 011ah) to keep it on his head.
--
-- WHY IT DOES NOT TRY TO TIME THE FREEZE.  freeze_lock_reset_test.lua says it
-- plainly - scripting a real freeze on input timing "has burned whole runs
-- before".  So neither side is timed here: Reptile spams F,F+HP and Sub-Zero
-- spams D,F+LP, and over a few thousand frames an iceball lands during a spit
-- on its own.  The rig scores the state it finds, not the input it sent.
--
-- What it records, and why each is the right signal:
--
--   prev      the action Reptile was in on the tick BEFORE act_frozen.  This
--             is what makes the run mean anything: a freeze from act_spit
--             (012h) or act_air_spit (016h) is the case under test, and a
--             freeze from anything else is just an ordinary freeze and is
--             reported separately rather than scored.
--   proc      pid_frzface (011ah) in the active list.  The first design ran
--             the anchor from its own process and that is what LOCKED THE
--             GAME UP - so this is now scored INVERTED: it must be absent.
--             r_ice owns the face itself and no such process should exist.
--   opal      the face object's palette, sampled before the freeze and during
--             it.  It must CHANGE - that is the REPFFRZ_P swap - and the
--             object must still be on objlst, which is the "his face did not
--             disappear" claim stated as a number.
--   after     once he thaws, the face object must be GONE.  A face that
--             outlives the freeze is the failure this design is most at risk
--             of, and it is the one that was actually reported: "the face
--             stays on screen after the freeze is done and the body
--             disappears".
--
-- FSPIT_BREAK=1 tests the exit that caused that.  freeze_wakeup is NOT the
-- only way out of r_ice - being HIT while frozen transfers the process to
-- another reaction and r_ice's own cleanup never runs at all.  So in break
-- mode Sub-Zero walks in and punches the frozen Reptile instead of letting
-- the ice expire, and the rig then insists the face is gone anyway.  It is
-- covered by re-registering the face in p_slave, which every reaction's
-- reaction_start_chores deletes.
--
-- Env: FSPIT_LOG, FSPIT_FRAMES
-- Driven by run_reptile_frozen_spit_test.ps1 (P1=Reptile, P2=Sub-Zero human).

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("FSPIT_LOG") or (ROOT .. "/tools/frozen_spit.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

local gstate  = sym.gstate
local p1_proc = sym.p1_proc
local active  = sym.active
local objlst  = sym.objlst

local P_ACTION = 0x1f0          -- pdata(100h) + 0f0h
local P_SLAVE  = 0x190          -- pdata(100h) + 090h
local P_STORE1 = 0x230          -- pdata(100h) + 130h
local PROCID   = 0x020
local PROC_PA8 = 0x0c0
local OBJ_NEXT = 0x000
local OPAL     = 0x140

local p1_obj  = sym.p1_obj
local p2_obj  = sym.p2_obj
local p2_proc = sym.p2_proc
local OXPOS   = 0x090
local palram  = sym.palram
local PALRSIZ = 0x40
local PALCNT  = 0x20
local WATCH   = {7, 9, 11}      -- face normal / body / face frozen

local BREAK = os.getenv("FSPIT_BREAK") == "1"

local ACT_SPIT     = 0x0012
local ACT_AIR_SPIT = 0x0016
local ACT_FROZEN   = 0x0401
local PID_FRZFACE  = 0x011a

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[fspit] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

-- Both sticks belong to this rig for the whole fight.  Without claiming them
-- the harness keeps walking P1 and the two fighters end up in different
-- states - the trap sweep_addon documents at ADDON_OWNS.
for _, n in ipairs({
    "P1 Left", "P1 Right", "P1 Up", "P1 Down",
    "P1 High Punch", "P1 Low Punch", "P1 High Kick", "P1 Low Kick",
    "P2 Left", "P2 Right", "P2 Up", "P2 Down",
    "P2 High Punch", "P2 Low Punch", "P2 High Kick", "P2 Low Kick",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local prev_act, prev_opal = nil, nil
local frozen_at, frozen_prev = nil, nil
local saw_case, saw_plain = 0, 0
local checked_after = true
local face_at_freeze = nil
local last_key = nil
local after_at, lingered = nil, false
local frozen_opal = nil
local slave_checked = false
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local results = {}

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if ADDON_OWNS[f.name] then fields[f.name] = f end
        end
    end
end

local function press(n, on)
    local f = fields[n]
    if f then f:set_value(on and 1 or 0) end
end

-- Is a process with this id on the active list?
local function proc_with_id(id)
    local p = space:read_u32(active)
    local guard = 0
    while p ~= 0 and guard < 400 do
        if (space:read_u16(p + PROCID) & 0xffff) == id then return p end
        p = space:read_u32(p + 0)
        guard = guard + 1
    end
    return nil
end

local function obj_on_list(want)
    if not want or want == 0 then return false end
    local o = space:read_u32(objlst)
    local guard = 0
    while o ~= 0 and guard < 400 do
        if o == want then return true end
        o = space:read_u32(o + OBJ_NEXT)
        guard = guard + 1
    end
    return false
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then pcall(function() s:snapshot() end) end
    log("SNAP %s frame=%d", label, frame)
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        cache_fields()
        log("=== frozen spit === Reptile spams F,F+HP; Sub-Zero spams D,F+LP  BREAK=%s",
            tostring(BREAK))
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    local pr = space:read_u32(p1_proc)
    if pr == 0 then return end
    local act = space:read_u16(pr + P_ACTION) & 0xffff

    -- The face object while he is spitting: p_slave until r_ice detaches it,
    -- p_store1 from then on.  Sampling both is how the rig follows the same
    -- object across the hand-off.
    local face = space:read_u32(pr + P_SLAVE)
    if face == 0 then face = space:read_u32(pr + P_STORE1) end
    local opal = (face ~= 0 and obj_on_list(face)) and space:read_u16(face + OPAL) or nil

    -- Palette bookkeeping around the freeze.  freepal lockups on a negative
    -- palcnt ("negative palette count, oh shit !!"), so a slot that reaches 0
    -- while an object still points at it is the crash waiting to happen.
    local body = space:read_u32(p1_obj)
    local bpal = body ~= 0 and space:read_u16(body + OPAL) or 0
    local cnt = {}
    for i, n in ipairs(WATCH) do
        cnt[i] = space:read_u16(palram + n * PALRSIZ + PALCNT) & 0xffff
    end
    local key = string.format("%04x|%04x|%d,%d,%d", bpal, opal or 0, cnt[1], cnt[2], cnt[3])
    if key ~= last_key then
        last_key = key
        log("  t=%4d act=%04x body_opal=%04x face_opal=%s  palcnt[7]=%d [9]=%d [11]=%d",
            t, act, bpal, opal and string.format("%04x", opal) or "----",
            cnt[1], cnt[2], cnt[3])
    end

    if act == ACT_FROZEN and frozen_at == nil then
        frozen_at, frozen_prev = frame, prev_act
        face_at_freeze = face
        local pid = proc_with_id(PID_FRZFACE)
        local onlist = obj_on_list(face)
        if prev_act == ACT_SPIT or prev_act == ACT_AIR_SPIT then
            saw_case = saw_case + 1
            log("FROZEN MID-SPIT  t=%d prev=%04x  face=%08x onlist=%s  opal %s -> %s  frzface_proc=%s",
                t, prev_act or 0, face or 0, tostring(onlist),
                prev_opal and string.format("%04x", prev_opal) or "-",
                opal and string.format("%04x", opal) or "-",
                pid and string.format("%08x", pid) or "NONE")
            results[#results + 1] = {
                onlist = onlist, noproc = (pid == nil),
                changed = (prev_opal ~= nil and opal ~= nil and opal ~= prev_opal),
            }
            frozen_opal = opal
            snap("frozen_mid_spit")
            checked_after = false
        else
            saw_plain = saw_plain + 1
            if saw_plain <= 3 then
                log("frozen (not mid-spit) t=%d prev=%04x frzface_proc=%s",
                    t, prev_act or 0, pid and "PRESENT(!)" or "none")
            end
            -- A plain freeze must NOT start the face proc.
            if pid then
                results[#results + 1] = {spurious = true}
                log("UNEXPECTED frzface proc on a non-spit freeze")
            end
        end
    end

    -- While he is frozen: is the face registered in p_slave?  That is the
    -- whole safety property.  reaction_start_chores deletes p_slave on EVERY
    -- reaction, so a face parked there is reaped by any exit r_ice does not
    -- control - being hit, shattered or finished.  Checking the registration
    -- is stronger than trying to catch one particular exit.
    if act == ACT_FROZEN and frozen_at and not slave_checked then
        slave_checked = true
        local sl = space:read_u32(pr + P_SLAVE)
        log("REGISTERED p_slave=%08x face=%08x  match=%s",
            sl, face_at_freeze or 0, tostring(sl == face_at_freeze and sl ~= 0))
        results[#results + 1] = {registered = (sl == face_at_freeze and sl ~= 0)}
    end

    if BREAK and act == ACT_FROZEN and frozen_at and (frame - frozen_at) % 40 == 0 then
        local p2p = space:read_u32(p2_proc)
        local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
        local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
        local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
        log("  break t=%d p2_act=%04x dist=%d", t,
            p2p ~= 0 and space:read_u16(p2p + P_ACTION) or 0xffff, x2 - x1)
    end

    if frozen_at and act ~= ACT_FROZEN then
        if not checked_after then
            checked_after = true
            after_at = frame
            log("LEFT THE ICE t=%d act=%04x (%s)", t, act,
                (t < 200) and "hit out of it - r_ice's own cleanup never runs"
                           or "ice expired normally")
            snap("left_the_ice")
        end
        frozen_at = nil
    end

    -- The verdict sample, four ticks after he leaves.  NOT on the transition
    -- tick: the reaction that takes him over deletes p_slave inside its own
    -- chores, and whether that has happened yet on the very tick the action
    -- changes is a matter of dispatch order within the frame, not of whether
    -- the face is leaked.
    if after_at and frame - after_at == 4 then
        local pid = proc_with_id(PID_FRZFACE)
        local stale = obj_on_list(face_at_freeze)
            and (space:read_u16(face_at_freeze + OPAL) & 0xffff) == frozen_opal
        log("AFTER +4  frzface_proc=%s  frozen_face_still_there=%s",
            pid and "STILL THERE(!)" or "gone", tostring(stale))
        results[#results + 1] = {after_proc = pid ~= nil, after_obj = stale}
    end

    -- ...and keep looking for a while.  A face that lingers is the whole
    -- point, so one sample on the exit tick is not enough.
    -- Identity by PALETTE, not by address alone.  Object slots come from a
    -- pool and his NEXT spit reuses the very same one - the first version of
    -- this check called that a lingering face six ticks after the thaw, when
    -- it was a brand new face on REPHED_P.  A face that really outlived the
    -- freeze is still on REPFFRZ_P (0b0b).
    if after_at and frame - after_at > 0 and frame - after_at <= 240 then
        local stale = obj_on_list(face_at_freeze)
            and (space:read_u16(face_at_freeze + OPAL) & 0xffff) == frozen_opal
        if stale then
            if not lingered then
                lingered = true
                log("LINGERING FACE t=%d (%d ticks after leaving the ice)",
                    t, frame - after_at)
                results[#results + 1] = {after_obj = true}
                snap("lingering_face")
            end
        end
    end

    if act ~= ACT_FROZEN then
        prev_act = act
        if opal then prev_opal = opal end
    end

    -- Reptile: Forward, Forward + HP on a 40-tick cycle.  P1 is on the left,
    -- so forward is Right.
    local c = t % 40
    press("P1 Right", c == 2 or c == 3 or c == 8 or c == 9)
    press("P1 High Punch", c == 10 or c == 11)

    -- Sub-Zero: Down, Forward + LP.  P2 is on the right, so forward is Left.
    --
    -- He STOPS once the case has been caught.  Left spamming, the next iceball
    -- re-freezes Reptile before the first freeze expires and act_frozen never
    -- clears - so the thaw, which is where a stuck face would show up, is
    -- never observed.  One freeze, then silence, is what makes the after-check
    -- reachable.
    if saw_case == 0 then
        local d = (t + 17) % 34
        press("P2 Down", d == 2 or d == 3)
        press("P2 Left", d == 5 or d == 6)
        press("P2 Low Punch", d == 7 or d == 8)
    elseif BREAK and frozen_at ~= nil then
        -- Break him OUT of the ice rather than waiting for it to expire, so
        -- the process is taken over by another reaction and r_ice's own
        -- freeze_wakeup cleanup never runs.
        -- Walk toward him by SIGN, not by a fixed direction.  "P2 Left" is
        -- not reliably forward here - the first attempt held Left and the
        -- distance grew 190 -> 254, so he backed off for the whole freeze and
        -- the punch never landed.
        press("P2 Down", false); press("P2 Low Punch", false)
        local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
        local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
        local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
        local far = math.abs(x2 - x1) > 70
        local b = (frame - frozen_at) % 10
        press("P2 Left",  far and x2 > x1)
        press("P2 Right", far and x2 < x1)
        press("P2 High Punch", (not far) and (b == 8 or b == 9))
    else
        press("P2 Down", false); press("P2 Left", false)
        press("P2 Low Punch", false); press("P2 High Punch", false)
    end
end)

emu.register_stop(function()
    local mid, ok_proc, ok_obj, ok_pal, bad, reg = 0, 0, 0, 0, 0, 0
    for _, r in ipairs(results) do
        if r.spurious or r.after_proc or r.after_obj then bad = bad + 1 end
        if r.registered == false then bad = bad + 1 end
        if r.registered then reg = reg + 1 end
        if r.onlist ~= nil then
            mid = mid + 1
            if r.noproc then ok_proc = ok_proc + 1 end
            if r.onlist then ok_obj = ok_obj + 1 end
            if r.changed then ok_pal = ok_pal + 1 end
        end
    end
    log("SUMMARY mid_spit_freezes=%d  face_survived=%d  no_stray_proc=%d  palette_changed=%d  p_slave_registered=%d  plain_freezes=%d  problems=%d",
        mid, ok_obj, ok_proc, ok_pal, reg, saw_plain, bad)
    if mid == 0 then
        log("VERDICT NO-CASE (never froze him mid-spit - run it longer)")
    elseif bad == 0 and ok_obj == mid and ok_proc == mid and ok_pal == mid then
        log("VERDICT PASS")
    else
        log("VERDICT FAIL")
    end
end)
