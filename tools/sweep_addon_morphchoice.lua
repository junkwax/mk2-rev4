-- sweep_addon_morphchoice.lua - what a CPU Shang picks, and whether "myself"
--                               is ever the answer.
--
-- Rides the battle_stability_sweep harness (P1 = human, P2 = the drone).  Set
-- SWEEP_P2=6 so the drone is Shang.
--
-- The measurement is one word and one object field:
--
--   l_drone_morph (p2 half, +16)  far7 stamps this the instant it commits to
--                                 a morph DECISION, before dispatch.
--   p2_obj->ochar                 what he actually turned into, which lands
--                                 ~40 frames later when the animation ends.
--
-- Pair them and the three outcomes separate cleanly:
--
--   became <X>   stamp, then ochar changes to something that is not Shang
--   REVERTED     stamp, then ochar changes to 6 - a CHOSEN return to his own
--                form.  Impossible with drone_unmorph off: the roll could not
--                produce 6 at all, so this count is the A/B.
--   declined     stamp, no ochar change, and he was already Shang - he looked
--                and stayed
--
-- A change to 6 with NO recent stamp is the 0200h-tick auto-revert in
-- back_to_shang_check, which exists in both builds and is counted separately.
-- Confusing the two is the whole trap here: the baseline DOES return to Shang,
-- just never on purpose.
--
-- Both fighters are pinned far apart and at full health: morphs are rolled at
-- far range only (far7), and the point is the distribution of the choice, not
-- how often the drone chooses to walk.
--
-- Env: MORPH_LOG, MORPH_DIFF (default 9).

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local OUT  = os.getenv("MORPH_LOG") or (ROOT .. "/tools/drone_morph_choice.log")
local DIFF = tonumber(os.getenv("MORPH_DIFF") or "9")
-- MORPH_HOLD=1 keeps re-stamping l_morph so back_to_shang_check's 0200h
-- auto-revert never fires.  It changes NO decision logic - the roll, the
-- chart and the cadence are untouched - it only stops the timer from
-- reverting him first, which is what makes a CHOSEN revert observable at all.
--
-- Measured without it (19k frames, diff 9, vs Raiden): 8 decisions, 10 timer
-- reverts, and 7 of the 8 decisions were taken while he was ALREADY Shang -
-- so the branch under test was almost never reached.  That is a true fact
-- about the shipped drone and it is why this switch exists; it is not the
-- default, and a run with it on measures the choice, not the game.
local HOLD = (os.getenv("MORPH_HOLD") == "1")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

local fh = io.open(OUT, "w")
local function say(f, ...)
    local l = "[morph] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))
    print(l)
    if fh then fh:write(l, "\n"); fh:flush() end
end

local A = {
    gstate        = sym["gstate"],
    diff          = sym["diff"],
    tick          = sym["tick"],
    p1_obj        = sym["p1_obj"],
    p2_obj        = sym["p2_obj"],
    p1_bar        = sym["p1_bar"],
    p2_bar        = sym["p2_bar"],
    l_drone_morph = sym["l_drone_morph"],
    l_morph       = sym["l_morph"],
    winner_status = sym["winner_status"],
    f_freeze_timer = sym["f_freeze_timer"],
}
local O = { oxval = 0x080, oxpos = 0x090, ochar = 0x1f0 }
local FT_ST, MAX_HP, GS_FIGHTING = 6, 0xa1, 2
local NAMES = { [0]="lao", "liu", "cage", "baraka", "kitana", "mileena",
                "SHANG", "raiden", "subzero", "reptile", "scorpion", "jax" }

-- A stamp and the ochar change it caused are ~40 frames apart (shang_morph
-- plays a whole mframew lane before it writes ochar, and back_to_shang_form
-- three frames at sleep 4).  Anything past this is not the same event.
local STAMP_WINDOW = 90

local space, frame = nil, 0
local last_ochar, last_stamp = nil, nil
local stamp_frame = -9999
local counts = { became = {}, reverted = 0, declined = 0, timer = 0, decisions = 0 }
local started = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

-- The harness walks P1 to the stage edges; this runs after it and overrides,
-- because the drone only rolls a morph from far range and a rig that lets the
-- distance wander is measuring the walk, not the choice.
local function pin()
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    local p2x = r16(p2 + O.oxpos)
    local x = p2x - 210
    w16(p1 + O.oxpos, x)
    w32(p1 + O.oxval, (x << 16) & 0xffffffff)
    if A.p1_bar ~= 0 then w16(A.p1_bar, MAX_HP) end
    if A.p2_bar ~= 0 then w16(A.p2_bar, MAX_HP) end
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    -- The round CLOCK is the real limit on this rig: morph decisions come
    -- roughly every 0140h ticks at diff 9 and only from far range, so a
    -- 90-second round yields one or two of them and the distribution cannot
    -- be read off that.  f_freeze_timer is the game's own training-mode
    -- switch (RAM.ASM) and stops the clock decrementing.
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    if HOLD and A.l_morph ~= 0 and A.tick ~= 0 then
        w16(A.l_morph + 16, r16(A.tick))   -- p2's half; see MORPH_HOLD above
    end
end

local function report()
    say("---- CPU Shang morph choices, diff %d ----", DIFF)
    say("decisions (l_drone_morph stamps) : %d", counts.decisions)
    local total = 0
    for i = 0, 11 do
        local n = counts.became[i] or 0
        if n > 0 then
            say("  became %-8s : %d", NAMES[i] or tostring(i), n)
            total = total + n
        end
    end
    say("  CHOSEN REVERT to Shang : %d", counts.reverted)
    say("  declined (already Shang, stayed) : %d", counts.declined)
    say("  timer reverts (0200h, not a choice) : %d%s", counts.timer,
        HOLD and "   [MORPH_HOLD on - the timer was suppressed]" or "")
    say("forms entered by choice: %d", total + counts.reverted)
    say("VERDICT chosen_reverts=%d %s", counts.reverted,
        counts.reverted > 0 and "- the CPU uses its own form"
                            or "- never picked itself (expected with drone_unmorph off)")
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
        say("watching l_drone_morph=%08x p2 half=+16", A.l_drone_morph or 0)
    end
    if r16(A.gstate) ~= GS_FIGHTING then return end
    if started == 0 then started = frame end

    if A.diff ~= 0 then w16(A.diff, DIFF) end
    pin()

    local p2 = r32(A.p2_obj)
    if p2 == 0 then return end
    local oc = r16(p2 + O.ochar)
    local stamp = r16(A.l_drone_morph + 16)

    if last_stamp == nil then last_stamp, last_ochar = stamp, oc; return end

    if stamp ~= last_stamp then
        counts.decisions = counts.decisions + 1
        stamp_frame = frame
        say("decision frame=%d tick=%04x wearing=%s",
            frame, stamp, NAMES[oc] or tostring(oc))
        last_stamp = stamp
    end

    if oc ~= last_ochar then
        local chosen = (frame - stamp_frame) <= STAMP_WINDOW
        if oc == FT_ST then
            if chosen then
                counts.reverted = counts.reverted + 1
                say("frame=%d %s -> SHANG  (CHOSEN REVERT, %d frames after the stamp)",
                    frame, NAMES[last_ochar] or tostring(last_ochar), frame - stamp_frame)
            else
                counts.timer = counts.timer + 1
                say("frame=%d %s -> SHANG  (timer, no recent decision)",
                    frame, NAMES[last_ochar] or tostring(last_ochar))
            end
        else
            counts.became[oc] = (counts.became[oc] or 0) + 1
            say("frame=%d %s -> %s%s", frame, NAMES[last_ochar] or tostring(last_ochar),
                NAMES[oc] or tostring(oc), chosen and "" or "  (no recent stamp?)")
        end
        last_ochar = oc
        stamp_frame = -9999
    elseif stamp_frame > 0 and frame - stamp_frame == STAMP_WINDOW and oc == FT_ST then
        -- stamped, window elapsed, still himself: smorph_stay took it
        counts.declined = counts.declined + 1
        say("frame=%d decision produced no change - declined (stayed Shang)", frame)
        stamp_frame = -9999
    end
end)

emu.register_stop(function()
    report()
    if fh then fh:flush(); fh:close(); fh = nil end
end)
