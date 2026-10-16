-- hidden_select_victory_test.lua
--
-- Runtime proof for the hidden fighters' SELECT-SCREEN celebration.
--
-- Picking Jade / Smoke / Noob Saibot / Ermac used to leave the preview drone
-- standing there as Mileena / Scorpion / Sub-Zero / Reptile, taking their
-- victory pose and their announced name, because MAIN.ASM only swapped
-- @p?_char after player_select had already returned.  MKSEL.ASM's cmove9 now
-- asks psel_hidden_pick on the confirming press, commits @p?_char there, and
-- fastxfers the drone through psel_hidden_victory (rebuild as the hidden
-- fighter) into victory_animation.
--
-- What this checks, in the window between the confirm and the VS screen:
--   1. the preview object's ochar became the hidden fighter's ft_ id
--   2. its oimg actually advances - a still pose is not a celebration
--   3. the announcer got the HIDDEN name call, not the roster one, read
--      straight off the sound port rather than inferred
--   4. Jade brings her staff: a second object one z-step in front of her
--
-- It is still pointer-level (matching ids/SAGs prove the rows advance, not
-- that pixels were written behind them) - look at the snapshots.
--
--   HSV_NAME    jade | smoke | noob | ermac
--   HSV_NORMAL  set to anything: regression mode.  No cheat - confirm whoever
--               the cursor starts on with a plain Low Punch and require HIS
--               roster name call.  cmove9 took over the ochar -> table
--               arithmetic that select_speech used to do, so every ordinary
--               pick in the game rides on that edit and has to be re-proved.
--   HSV_PLAYER  1 or 2   (2 runs a 2P game and drives player 2)
--   HSV_LOG     log path
--   HSV_SNAP    frames between celebration screenshots (0 = none)
--   HSV_FIGHT   set: don't stop after the celebration - carry on into the
--               match and check nothing was left behind on screen.  Jade's
--               staff is the one to worry about: jade_victory deliberately
--               never deletes it (the held pose owns it) and relies on the
--               scene teardown, which on the SELECT screen is a different
--               teardown than the one it was written for.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local NAME = os.getenv("HSV_NAME") or "jade"
local P = tonumber(os.getenv("HSV_PLAYER") or "1")
local OTHER = (P == 1) and 2 or 1
local TWO_P = (P == 2)
local LOG = os.getenv("HSV_LOG") or (ROOT .. "/tools/hidden_select_victory_" .. NAME .. "_p" .. P .. ".log")
local SNAP = tonumber(os.getenv("HSV_SNAP") or "40")

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[" .. NAME .. "] " ..
        (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    raw(line); logfh:write(line, "\n"); logfh:flush()
end

-- ---------------------------------------------------------------- fighters
-- base    = roster character the cursor sits on
-- expect  = ft_ id the unlock must produce
-- button  = the cheat button, pressed 5 times
-- held    = the .bss edge-detect flag's middle name (jade uses lk, not blk)
-- snd     = triple_sndtab2 index of the hidden NAME call (MKSOUND.ASM $5D-$60)
-- call    = the DCS track that index dispatches (channel 1)
local F = {
    jade  = { base = 5,  expect = 16, button = "Low Kick", held = "lk",  snd = 0x5e, call = 0x0361 },
    smoke = { base = 10, expect = 14, button = "Block",    held = "blk", snd = 0x5d, call = 0x035b },
    noob  = { base = 8,  expect = 15, button = "Block",    held = "blk", snd = 0x5f, call = 0x0352 },
    ermac = { base = 9,  expect = 17, button = "Block",    held = "blk", snd = 0x60, call = 0x036d },
}
local U = assert(F[NAME], "unknown HSV_NAME " .. NAME)
-- The roster name call the cursor's own character would have announced, so a
-- silent regression (hidden fighter shown, roster name spoken) still fails.
-- triple_sndtab2 $1C-$27 (MKSOUND.ASM), indexed by ochar: the roster name
-- calls, i.e. what cmove9 announces for an ordinary pick (ochar + 01Ch).
local ROSTER_CALLS = {
    [0] = 0x045e, [1] = 0x045b, [2] = 0x0461, [3] = 0x0476,
    [4] = 0x046d, [5] = 0x0473, [6] = 0x046a, [7] = 0x047c,
    [8] = 0x0467, [9] = 0x0464, [10] = 0x0479, [11] = 0x0470,
}
-- Regression mode: no cheat at all.  Confirm whoever the cursor starts on
-- with a plain Low Punch and require HIS roster name.  The pick is read off
-- @p?_char rather than forced there: writing that variable moves the pick but
-- NOT the preview drone (only a cursor move re-creates it via getprc), so a
-- forced hover would compare the name against a fighter who was never shown.
local NORMAL = (os.getenv("HSV_NORMAL") or "") ~= ""
if NORMAL then U = { button = "Low Punch" } end
local ROSTER_CALL = nil
if not NORMAL then ROSTER_CALL = ROSTER_CALLS[U.base] end

-- ------------------------------------------------------------------ symbols
local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate  = sym("gstate"),
    my_char = sym("p" .. P .. "_char"),
    my_obj  = sym("p" .. P .. "_obj"),
    objlst  = sym("objlst"),
    c    = sym("c_" .. NAME .. "_cheat" .. P),
    f    = sym("f_" .. NAME .. "_cheat" .. P),
    held = (not NORMAL) and sym("f_" .. NAME .. "_" .. U.held .. "_held" .. P) or nil,
}
local need = NORMAL and { "gstate", "my_char", "my_obj" }
                   or { "gstate", "my_char", "my_obj", "c", "f", "held" }
for _, k in ipairs(need) do
    if not A[k] then log("FATAL: '%s' not in mk2.map", k) end
end

-- All offsets are TMS34010 BIT units (DISPEQU.ASM); MAME's tms34010 program
-- space is bit-addressed, so mk2.map values go in raw.
local ONEXT, OSLINK, OZVAL, OIMG, OID, OCHAR = 0x00, 0x20, 0xc0, 0x1a0, 0x1c0, 0x1f0
local MP_LEN = 0x70
local GS_PSEL, GS_FIGHTING = 4, 2
local SOUND_PORT = 0x1d01030          -- SYSEQU.ASM `sound` (auto strobe)

-- ------------------------------------------------------------------- state
local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

-- A player object's oimg is a CONSTANT pointer to its multipart RAM block
-- (p?_ram, set once by make_player_?_obj), so watching oimg for change proves
-- nothing.  The frame that is actually on screen is the SAG in the first
-- multipart record, which do_next_a9_frame rewrites every animation row.
local function cur_sag(obj)
    local img = r32(obj + OIMG)
    if img == 0 then return 0 end
    return r32(img) & 0x00ffffff
end
local frame, psel, p0, confirm = 0, 0, 0, 0
local phase, done = "boot", false
local snap_next = 4          -- next rel-frame to screenshot at
local calls_at_press = 0
local last_c, last_char = -1, -1
local imgs, img_order = {}, {}        -- distinct oimg values seen, in order
local ochar_seen = -1
local staff_seen, staff_z_ok = false, false
local FIGHT = (os.getenv("HSV_FIGHT") or "") ~= ""
local fight_at, leftovers = 0, 0
local sound_calls, sound_hi = {}, nil
local tap_ok, tap_hits = false, 0


local held = {}
local function hold(n, on) held[n] = on and true or false end

local BTN = "P" .. P .. " " .. U.button
local LP  = "P" .. P .. " Low Punch"
local OLP = "P" .. OTHER .. " Low Punch"

local function cache_inputs()
    local want = { ["Coin 1"] = 1, ["Coin 2"] = 1, ["1 Player Start"] = 1,
                   ["2 Players Start"] = 1, ["UI Select"] = 1,
                   [BTN] = 1, [LP] = 1, [OLP] = 1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, fld in pairs(p.fields) do
            if want[fld.name] then fields[fld.name] = fld end
        end
    end
    for n in pairs(want) do log("input %-18s %s", n, fields[n] and "ok" or "MISSING") end
end

-- Read the announcer call off the wire.  send_code_a3 (MKSOUND.ASM) writes
-- the code as two 16-bit port writes, 0FF00h|high then 0FF00h|low, so the
-- pair reconstructs the track number the sound board is actually told to
-- play.  Inferring it from chan?dur would not separate Smoke from Jade -
-- their clips are the same length and share a duration.
-- The handler MUST be kept alive.  install_write_tap hands back a
-- memory_passthrough_handler; drop the reference and Lua's GC will collect it
-- out from under MAME's tap list, which takes the whole emulator down with no
-- message at all - it looks exactly like the ROM crashing.
local tap_handle = nil
local function install_tap()
    local ok, err = pcall(function()
        tap_handle = space:install_write_tap(SOUND_PORT, SOUND_PORT + 15, "mk2snd",
            function(offset, data, mask)
                local b = data & 0xff
                tap_hits = tap_hits + 1
                if sound_hi == nil then
                    sound_hi = b
                else
                    local code = (sound_hi << 8) | b
                    sound_hi = nil
                    sound_calls[#sound_calls + 1] = { code = code, frame = frame }
                end
                return data
            end)
    end)
    if ok then tap_ok = true; log("sound port tap installed at %08x", SOUND_PORT)
    else log("WARNING: sound port tap unavailable (%s) - call check skipped", tostring(err)) end
end

-- Walk objlst looking for an extra object sitting one z-step in front of the
-- fighter: that is jade_victory's JDVICSTAFF overlay (MKCANNED.ASM), which it
-- puts at ozval+1 so it draws over her gloves.
--
-- The list link is ONEXT (cell 0), NOT oslink - oslink is the "objects in
-- class" side chain and walking it finds nothing here.
-- Only ever follow links that stay inside SCRATCH (mk2.cmd: org 01000000h).
-- A wild link would otherwise walk this reader into the I/O page at
-- 01d0xxxxh, and reads there are not free - MAME took the machine down with
-- no message when an unbounded walk reached it.
local function in_scratch(a) return a >= 0x01000000 and a < 0x01400000 end

local function scan_staff(obj)
    if staff_seen or not A.objlst or obj == 0 then return end
    local jz = r32(obj + OZVAL)
    local jsag = cur_sag(obj)
    local o, guard = r32(A.objlst), 0
    while o ~= 0 and in_scratch(o) and guard < 400 do
        if o ~= obj then
            local z = r32(o + OZVAL)
            local sag = cur_sag(o)
            if sag ~= 0 and sag ~= jsag and z == jz + 1 then
                if not staff_seen then
                    staff_seen, staff_z_ok = true, true
                    log("staff object found: obj=%08x sag=%06x ozval=%d (jade sag=%06x z=%d)",
                        o, sag, z, jsag, jz)
                end
            end
        end
        o = r32(o + ONEXT)
        guard = guard + 1
    end
end

-- Count objects still showing art out of the JADVIC / select-screen sidecar
-- bank once the fight is running.  Anything here is something the celebration
-- allocated and nobody reclaimed.
local function count_bank_objects(mine)
    if not A.objlst then return 0 end
    local n, o, guard = 0, r32(A.objlst), 0
    while o ~= 0 and in_scratch(o) and guard < 400 do
        if o ~= mine then
            local sag = cur_sag(o)
            if sag >= 0xf80000 and sag < 0x1000000 then n = n + 1 end
        end
        o = r32(o + ONEXT)
        guard = guard + 1
    end
    return n
end

local function verdict()
    local ok = true
    local reasons = {}

    if ochar_seen ~= U.expect then
        ok = false
        reasons[#reasons + 1] = string.format("preview ochar=%d, wanted %d", ochar_seen, U.expect)
    end
    if #img_order < (NORMAL and 2 or 3) then
        ok = false
        reasons[#reasons + 1] = string.format("only %d distinct animation frames - the pose never moved", #img_order)
    end
    if tap_ok and U.call then
        -- triple_sound hands the call to whichever of the three channels is
        -- free, adding +1 for channel 2 and +2 for channel 3, so the code on
        -- the wire is the table's base call OR one of its two neighbours.
        -- The mugshot-flash cursor sound usually has channel 1 already.
        local function in_triple(code, base) return base and code >= base and code <= base + 2 end
        local got_hidden, got_roster = false, false
        for _, e in ipairs(sound_calls) do
            if e.frame >= confirm - 4 and in_triple(e.code, U.call) then got_hidden = true end
            if e.frame >= confirm - 4 and in_triple(e.code, ROSTER_CALL) then got_roster = true end
        end
        if not got_hidden then
            ok = false
            reasons[#reasons + 1] = string.format("name call $%04X (+ch) never sent", U.call)
        end
        if got_roster then
            ok = false
            reasons[#reasons + 1] = string.format("roster name call $%04X (+ch) was sent instead", ROSTER_CALL)
        end
    end
    if NAME == "jade" and not NORMAL and not staff_seen then
        ok = false
        reasons[#reasons + 1] = "no staff overlay object in front of her"
    end
    if FIGHT and leftovers > 0 then
        ok = false
        reasons[#reasons + 1] = string.format("%d select-screen object(s) still on the display list in the fight", leftovers)
    end

    local codes = {}
    for _, e in ipairs(sound_calls) do
        if e.frame >= confirm - 10 then
            codes[#codes + 1] = string.format("$%04X@%d", e.code, e.frame - confirm)
        end
    end
    log("sound port writes seen: %d bytes, %d calls total", tap_hits, #sound_calls)
    log("calls around the confirm: %s", #codes > 0 and table.concat(codes, " ") or "(none)")
    log("distinct animation frames during celebration: %d", #img_order)
    if ok then
        log("PASS %s_p%d: ochar=%d, %d animation frames, name call $%04X%s",
            NORMAL and ("roster" .. U.base) or NAME, P, ochar_seen, #img_order, U.call,
            (NAME == "jade" and not NORMAL) and ", staff present" or "")
    else
        log("FAIL %s_p%d: %s", NORMAL and ("roster" .. tostring(U.base)) or NAME, P, table.concat(reasons, "; "))
    end
    log("finished")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        install_tap()
        log("TEST %s P%d (2P=%s) base=%d expect=%d button=%s",
            NAME, P, tostring(TWO_P), U.base, U.expect, U.button)
    end
    if not space then return end

    local gs = r16(A.gstate)

    if gs == GS_PSEL and psel == 0 then
        psel = frame
        log("select reached frame=%d", frame)
        -- Start is one of the confirm bits cmove41 tests BEFORE the hidden
        -- route, so a stuck Start turns every cheat press into a plain
        -- confirm and the counter never moves.
        for _, n in ipairs({ "Coin 1", "Coin 2", "1 Player Start", "2 Players Start", "UI Select" }) do
            hold(n, false)
        end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        if TWO_P then
            hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
            hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        else
            hold("1 Player Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        end
        hold("UI Select", frame >= 5 and frame < 35)
    elseif confirm == 0 then
        local rel = frame - psel
        if rel == 60 then
            p0 = frame; phase = "pulsing"
            calls_at_press = #sound_calls
            if NORMAL then
                U.base = r16(A.my_char); U.expect = U.base
                U.call = ROSTER_CALLS[U.base]
                U.snd = 0x1c + U.base
                log("roster pick: cursor is on char %d, expecting name call $%04X",
                    U.base, U.call or 0)
            else
                log("pulsing %s x5 on char %d", BTN, U.base)
            end
        end
        if phase == "pulsing" then
            -- Park the cursor on the base fighter - but ONLY until the fifth
            -- press raises the pending flag.  cmove9 commits @p?_char to the
            -- hidden id on that very press (psel_apply_hidden_char); forcing
            -- the base id for even one more frame stamps it back out again,
            -- and psel_hidden_victory then rebuilds the preview as the base
            -- fighter.  That is a rig artifact, and it looks exactly like the
            -- feature not working.
            if NORMAL then
                -- nothing to hover: take the cursor's own square
            elseif r16(A.f) == 0 and r16(A.my_char) ~= U.expect then
                w16(A.my_char, U.base)
            end
            local p = frame - p0
            local idx = p // (NORMAL and 10 or 10)
            if idx < (NORMAL and 1 or 5) then
                hold(BTN, (p % 10) < 5)
            else
                hold(BTN, false)
                if phase ~= "post" then
                    phase = "post"
                    if NORMAL then log("press done (roster pick, char %d)", U.base)
                    else log("pulses done c=%d f=%d held=%d", r16(A.c), r16(A.f), r16(A.held)) end
                end
            end
            if not NORMAL then
                local c = r16(A.c)
                if c ~= last_c then log("  c_%s_cheat%d=%d (frame=%d)", NAME, P, c, frame); last_c = c end
            end
        end
        -- The 5th press is itself the confirm; LP is only a fallback in case
        -- the pulse train and the debounce disagree.
        if phase == "post" and (frame - p0) > 70 then
            hold(LP, (frame % 20) < 8)
            if TWO_P then hold(OLP, (frame % 20) < 8) end
        end
        -- @p?_char flipping to the hidden id IS the confirm: cmove9 commits it
        -- (psel_apply_hidden_char) right before it hands the drone over.  Do
        -- NOT wait on f_<name>_cheat here - MAIN.ASM's *_select_cheat_apply
        -- clears that after player_select returns, which is far too late to
        -- catch the celebration.
        local mc = r16(A.my_char)
        if NORMAL then
            -- No @p?_char transition to watch: the pick IS the hovered char.
            -- cmove9 fires its mugshot-flash cursor sound one instruction
            -- before it creates select_speech, so the first NEW call after
            -- the press marks the handover.  (Counting calls from zero would
            -- trip on attract-mode audio and start the window early.)
            if phase == "post" and #sound_calls > calls_at_press then
                confirm = frame
                log("confirmed at frame=%d: roster pick p%d_char=%d", frame, P, mc)
                for n in pairs(fields) do hold(n, false) end
            end
        elseif phase ~= "boot" and mc == U.expect then
            confirm = frame
            log("confirmed at frame=%d: p%d_char=%d (f=%d)", frame, P, mc, r16(A.f))
            for n in pairs(fields) do hold(n, false) end
        end
        if mc ~= last_char then last_char = mc end
    else
        -- Celebration window: watch the preview object rebuild and animate.
        local obj = r32(A.my_obj)
        if obj ~= 0 then
            local oc = r16(obj + OCHAR)
            if oc ~= ochar_seen then
                ochar_seen = oc
                log("  rel=%3d preview ochar=%d obj=%08x", frame - confirm, oc, obj)
            end
            local sag = cur_sag(obj)
            if sag ~= 0 and not imgs[sag] then
                imgs[sag] = true
                img_order[#img_order + 1] = sag
                log("  rel=%3d sag=%06x (#%d)", frame - confirm, sag, #img_order)
            end
            if NAME == "jade" and not NORMAL then scan_staff(obj) end
        end
        -- The celebration is SHORT: player_select returns as soon as the last
        -- select proc dies, so one screenshot 40 frames out lands on the VS
        -- screen and tells you nothing.  Take a burst instead, and only while
        -- the select screen is still up.
        if SNAP > 0 and gs == GS_PSEL then
            local rel = frame - confirm
            if rel >= snap_next then
                manager.machine.video:snapshot()
                log("snapshot at rel=%d", rel)
                snap_next = rel + SNAP
            end
        end
        if FIGHT then
            if gs == GS_FIGHTING then
                if fight_at == 0 then fight_at = frame; log("fight started at rel=%d", frame - confirm) end
                if frame - fight_at == 60 then
                    manager.machine.video:snapshot()
                    leftovers = count_bank_objects(r32(A.my_obj))
                    log("fight snapshot at +60; objects carrying select-screen art: %d", leftovers)
                    done = true; verdict(); manager.machine:exit()
                end
            elseif (frame - confirm) > 1200 then
                done = true; log("never reached the fight (gs=%d)", gs); verdict(); manager.machine:exit()
            end
        elseif (frame - confirm) > 180 and not done then
            done = true; verdict(); manager.machine:exit()
        end
    end

    for n, fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end

    if frame > 6000 and not done then
        done = true
        log("FAIL %s timeout phase=%s psel=%d confirm=%d c=%d", NAME, phase, psel, confirm, r16(A.c))
        log("finished"); manager.machine:exit()
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
