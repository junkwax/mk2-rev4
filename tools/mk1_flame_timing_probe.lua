-- mk1_flame_timing_probe.lua
--
-- Measure MK1's Scorpion toasty off the screen: how fast the flame animates,
-- where it sits relative to the victim, how long the skeleton holds and
-- collapses, and - if the port can be found - which sound fires when.
--
-- WHY THIS WAY.  Three other routes were tried and rejected:
--   * Static extraction from mk.zip - anchoring on our frame headers finds
--     nothing, because data/MK1SKULL.IMG was RE-CUT: our bounding boxes are
--     not Midway's.  (The method is sound - the same search finds MK1FIRE1 at
--     0x9fe0a in our own ROM.)
--   * Forcing the fatality from a harness - mk has no symbol map, so health,
--     winner_status and dizzy would all have to be found by memory scan.
--   * Hashing the whole screen - TRIED, DOES NOT WORK.  MK1's stages have
--     animated crowds and flags, so the picture changes nearly every frame
--     (measured mean hold 1.03).  A 3-frame sprite hold is invisible under it.
--
-- So it counts the FLAME instead: a big, uniquely orange mass that the crowd
-- and the sky are not.  Its animation frames show up as plateaus in the pixel
-- count, which is how the 3-tick hold was measured.
--
-- HOW TO USE
--   1. tools/run_mk1_flame_timing_probe.ps1
--   2. Coin up, pick SCORPION, win a round.
--   3. FINISH HIM: hold BLOCK at sweep distance, press UP, UP.
--   4. Let the WHOLE thing play out - flame, bones standing, bones falling -
--      then close MAME.
--
-- WHAT IT LOGS
--   F frame flame=N fx fy fbox=l,t,r,b bone=N bx by bbox=l,t,r,b dx dy
--     One line per sampled frame.  Plateaus give the holds; the boxes and
--     dx/dy give the binding.
--   SND frame=... off=... data=...
--     Sound-port writes, if the port is found (see the note by SND_LO).
--   mk is rev 5.0 T-UNIT: 54.7068 Hz, the same tick as MK2, so a hold
--   measured here is a sleep value usable unchanged.
--
-- Env knobs:
--   MK1P_LOG=path     log path
--   MK1P_STEP=N       dense grid step (default 6; lower = finer, slower)
--   MK1P_TRIG=N       sparse pre-scan hits needed to engage (default 12)
--   MK1P_SNAPS=N      snapshots RETAINED (default 200) - the most recent
--   MK1P_SNAPMIN=N    flame pixels before a shot is taken (default 100;
--                     background fire measures 15-70, a real burn >100)
--   MK1P_LINGER=N     frames to keep sampling after the fire dies (default
--                     260) so the skeleton half is captured
--   MK1P_SNDLO/HI     sound-port search window (bit addresses)

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local ROOT     = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("MK1P_LOG") or (ROOT .. "/tools/mk1_flame_timing.log")
local STEP     = getenv_int("MK1P_STEP", 6)
local TRIG     = getenv_int("MK1P_TRIG", 12)
local MAX_SNAP = getenv_int("MK1P_SNAPS", 200)
local SNAP_MIN = getenv_int("MK1P_SNAPMIN", 100)
local LINGER   = getenv_int("MK1P_LINGER", 260)
local SNAP_DIR = os.getenv("MK1P_SNAPDIR")

-- Sound-port search window.  SYSEQU.ASM says the T-Unit port is 1c01030h
-- (1d01030h on T-Unit 2 / MK2), but tapping those exact addresses caught
-- nothing, so the address form MAME wants here is not settled.  send_code_a3
-- ORs every command with 0ff00h|soundbit before writing, so a write whose
-- high byte is FF is almost certainly a sound command - distinctive enough to
-- find the port by sweeping for it.  EXPLORATORY: if it finds nothing, the
-- timing and binding measurements are unaffected.
local SND_LO = getenv_int("MK1P_SNDLO", 0x01c00000)
local SND_HI = getenv_int("MK1P_SNDHI", 0x01e00000)

local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local line = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    print("[mk1p] " .. line)
    if logfh then logfh:write("[mk1p] " .. line, "\n"); logfh:flush() end
end

local frame, scr, W, H = 0, nil, 0, 0
local ok_pixels = true
local snaps, burning, burn_frames, burns, linger = 0, false, 0, 0, 0

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function install_sound_tap()
    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then log("WARN no :maincpu - no sound capture"); return end
    local sp = cpu.spaces and cpu.spaces["program"]
    if not sp then log("WARN no program space - no sound capture"); return end
    local ok, err = pcall(function()
        -- MAME wants the INCLUSIVE end with its low bits set; passing a
        -- round address is rejected outright ("end address has low bits unset").
        sp:install_write_tap(SND_LO, SND_HI | 0xf, "mk1snd", function(offset, data, mask)
            if (data & 0xff00) == 0xff00 then
                log("SND  frame=%-7d off=%08X data=%04X lo=%02X",
                    frame, offset, data & 0xffff, data & 0xff)
            end
            return data
        end)
    end)
    if ok then
        log("sound window tapped %08X..%08X", SND_LO, SND_HI)
    else
        log("WARN sound tap unavailable (%s) - timing/binding only", tostring(err))
    end
end

-- MAME hands back 32-bit pixels; little-endian 0xAARRGGBB means bytes B,G,R,A.
local function rgb(px, i) return px:byte(i + 2), px:byte(i + 1), px:byte(i) end

-- Fire: strongly red-dominant and bright.  Deliberately strict - MK1's sky,
-- the temple and the torches are all warm, and letting them in would put a
-- floor under the count that swamps the flame's own steps.
local function is_flame(r, g, b)
    return r > 190 and b < 100 and (r - b) > 110 and g > 40 and g < 215
end

-- Bone: bright and near-neutral.  This also matches pale stone, which is why
-- snapshots are kept and the binding is checked against them, not trusted blind.
local function is_bone(r, g, b)
    local mx = math.max(r, g, b)
    local mn = math.min(r, g, b)
    return mn > 140 and (mx - mn) < 45
end

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        scr = main_screen()
        if not scr then log("ERROR no screen"); return end
        W, H = scr.width, scr.height
        log("MK1 burn probe. screen=%dx%d step=%d trig=%d keep=%d snapmin=%d linger=%d",
            W, H, STEP, TRIG, MAX_SNAP, SNAP_MIN, LINGER)
        log("mk is rev 5.0 T-Unit: 54.7068 Hz, same tick as MK2 - holds transfer 1:1.")
        log("Coin up, pick SCORPION, win a round, then at FINISH HIM:")
        log("    hold BLOCK at sweep distance, press UP, UP")
        log("Let the WHOLE burn play out (flame, bones standing, bones falling).")
        install_sound_tap()
        return
    end
    if not scr or not ok_pixels then return end

    local px
    if not pcall(function() px = scr:pixels() end) or type(px) ~= "string" or #px == 0 then
        ok_pixels = false
        log("ERROR screen:pixels() unavailable - cannot measure. Close MAME.")
        return
    end

    -- cheap pre-scan every frame: is there fire at all?
    local hits = 0
    for i = 1, #px - 3, 997 do
        local r, g, b = rgb(px, i)
        if r and is_flame(r, g, b) then hits = hits + 1 end
    end

    if hits < TRIG then
        if burning then
            log("BURN END frame=%d  lasted %d frames - lingering %d for the bones",
                frame, burn_frames, LINGER)
            burning, burn_frames = false, 0
            linger = LINGER
        end
        -- The fire going out is NOT the end: the skeleton stands, holds and
        -- collapses afterwards, and that half is what is still guessed on our
        -- side (sleep 90 upright, [sleep 3,7] collapse).  So keep sampling.
        if linger <= 0 then return end
        linger = linger - 1
    else
        if not burning then
            burning, burn_frames, burns = true, 0, burns + 1
            log("BURN START frame=%d  (#%d)", frame, burns)
        end
        burn_frames = burn_frames + 1
    end

    -- Dense grid scan.  Boxes as well as centroids: an anipoint is an offset
    -- to a sprite's edge, so the extents are what compare against our records.
    local fn, fx, fy = 0, 0, 0
    local bn, bx, by = 0, 0, 0
    local fl, fr, ft, fb = 9999, -1, 9999, -1
    local bl, br, bt, bb = 9999, -1, 9999, -1
    for y = 0, H - 1, STEP do
        local row = y * W * 4
        for x = 0, W - 1, STEP do
            local i = row + x * 4 + 1
            local r, g, b = rgb(px, i)
            if r then
                if is_flame(r, g, b) then
                    fn = fn + 1; fx = fx + x; fy = fy + y
                    if x < fl then fl = x end
                    if x > fr then fr = x end
                    if y < ft then ft = y end
                    if y > fb then fb = y end
                elseif y >= 88 and is_bone(r, g, b) then
                    -- y >= 88 keeps the HUD and upper background out; the
                    -- fighters stand well below it.
                    bn = bn + 1; bx = bx + x; by = by + y
                    if x < bl then bl = x end
                    if x > br then br = x end
                    if y < bt then bt = y end
                    if y > bb then bb = y end
                end
            end
        end
    end

    local fcx = (fn > 0) and math.floor(fx / fn) or -1
    local fcy = (fn > 0) and math.floor(fy / fn) or -1
    local bcx = (bn > 0) and math.floor(bx / bn) or -1
    local bcy = (bn > 0) and math.floor(by / bn) or -1
    local dx  = (fn > 0 and bn > 0) and (fcx - bcx) or -9999
    local dy  = (fn > 0 and bn > 0) and (fcy - bcy) or -9999

    log("F %-7d flame=%-5d fx=%-4d fy=%-4d fbox=%d,%d,%d,%d bone=%-5d bx=%-4d by=%-4d bbox=%d,%d,%d,%d dx=%-6d dy=%-6d%s",
        frame, fn, fcx, fcy, fl, ft, fr, fb, bn, bcx, bcy, bl, bt, br, bb, dx, dy,
        (fn >= SNAP_MIN) and "  <== BIG" or "")

    -- Snapshot on a BIG FLAME and nothing else.  Not on bones: "bright and
    -- neutral" also describes MK1's grey menu panels, and gating on that spent
    -- all 240 shots on CHOOSE YOUR FIGHTER before the fight started.
    -- Retention is ROLLING - attract mode has big fire too, so keeping the
    -- FIRST N fills up long before the fatality; the burn is the last thing
    -- that happens, so the tail is what is worth keeping.
    if fn >= SNAP_MIN then
        pcall(function() scr:snapshot() end)
        snaps = snaps + 1
        if SNAP_DIR and snaps > MAX_SNAP then
            os.remove(string.format("%s/mk/%04d.png", SNAP_DIR, snaps - MAX_SNAP - 1))
        end
    end
end

emu.register_frame_done(function()
    local ok, err = pcall(on_frame)
    if not ok then
        log("LUA ERROR frame=%d: %s", frame, tostring(err))
        ok_pixels = false
    end
end)
