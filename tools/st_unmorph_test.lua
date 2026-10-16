-- st_unmorph_test.lua
--
-- Shang Tsung's manual unmorph: BLOCK + UP + HIGH KICK returns him to his
-- own form out of any morph (shang_unmorph_check, MOVES.ASM).
--
-- What it proves, per form, in order:
--   1. The retail morph input still works and p1_obj->ochar becomes the
--      target fighter.
--   2. Block+Up+HK held together puts ochar back to ft_st (6) within a few
--      dozen frames - far too soon to be back_to_shang_check's 0200h-tick
--      auto-revert, which is what would otherwise do it eventually.
--   3. The machine is still running afterwards and the next morph works, so
--      the transfer left the switch process and the proc stack sane.
--
-- Plus a negative control up front: the same gesture while he is ALREADY
-- Shang must do nothing at all.
--
-- P2 is a second human who never presses anything, so no drone interferes.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("ST_UNMORPH_LOG") or (ROOT .. "/tools/st_unmorph_test.log")
local STAGE_ID = getenv_int("ST_UNMORPH_STAGE", 5)      -- Armory
local P2_CHAR  = getenv_int("ST_UNMORPH_P2_CHAR", 11)   -- Jax

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[st-unmorph] " .. msg)
end
local function hx(v)
    if v == nil then return "na" end
    return string.format("0x%08x", v & 0xffffffff)
end

local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if not fh then map_path = ROOT .. "/src/MK2.MAP"; fh = io.open(map_path, "r") end
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
        log("loaded symbols from %s", map_path)
    else
        log("WARN no linker map; using fallbacks")
    end
end
local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s; fallback=%s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    gstate        = sym("gstate"),
    p1_state      = sym("p1_state"),
    p2_state      = sym("p2_state"),
    p1_char       = sym("p1_char"),
    p2_char       = sym("p2_char"),
    p1_obj        = sym("p1_obj"),
    p2_obj        = sym("p2_obj"),
    p1_proc       = sym("p1_proc"),
    p1_bar        = sym("p1_bar"),
    p2_bar        = sym("p2_bar"),
    curback       = sym("curback"),
    winner_status = sym("winner_status"),
    pf_ram        = sym("pf_ram"),
    system_lockup = sym("system_lockup"),
    tvbp          = sym("TVBP"),
    tick          = sym("tick"),
    l_morph       = sym("l_morph"),
}
local O = { oxval = 0x080, oxpos = 0x090, ochar = 0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_ST = 6
local MAX_HP = 0xa1

-- The retail morph inputs, transcribed from the header comment in MOVES.ASM.
-- P1 is pinned on the LEFT of P2 for every trial, so away=Left, towards=Right.
-- Each step is {press_at, release_at, input}, in frames from the window start.
local TRIALS = {
    { name = "baraka",   ochar =  3, script = { {0,5,"P1 Down"}, {9,14,"P1 Down"}, {16,22,"P1 Low Kick"} } },
    { name = "reptile",  ochar =  9, script = { {0,3,"P1 Up"}, {4,8,"P1 Down"}, {10,16,"P1 High Punch"} } },
    { name = "scorpion", ochar = 10, script = { {0,2,"P1 Up"}, {3,6,"P1 Up"} } },
    { name = "kitana",   ochar =  4, script = { {0,4,"P1 Block"}, {7,11,"P1 Block"}, {14,18,"P1 Block"} } },
    { name = "cage",     ochar =  2, script = { {0,5,"P1 Left"}, {9,14,"P1 Left"}, {18,23,"P1 Down"}, {25,31,"P1 Low Punch"} } },
    { name = "kunglao",  ochar =  0, script = { {0,5,"P1 Left"}, {9,14,"P1 Down"}, {18,23,"P1 Left"}, {25,31,"P1 High Kick"} } },
    { name = "jax",      ochar = 11, script = { {0,5,"P1 Down"}, {9,14,"P1 Right"}, {18,23,"P1 Left"}, {25,31,"P1 High Kick"} } },
    { name = "subzero",  ochar =  8, script = { {0,5,"P1 Right"}, {9,14,"P1 Down"}, {18,23,"P1 Right"}, {25,31,"P1 High Punch"} } },
    { name = "raiden",   ochar =  7, script = { {0,5,"P1 Down"}, {9,14,"P1 Left"}, {18,23,"P1 Right"}, {25,31,"P1 Low Kick"} } },
    { name = "liukang",  ochar =  1, script = { {0,5,"P1 Left"}, {9,14,"P1 Right"}, {18,23,"P1 Right"}, {25,31,"P1 Block"} } },
    -- Mileena is the hold-and-release one; st_hp_open wants 030h ticks held.
    { name = "mileena",  ochar =  5, script = { {0,52,"P1 High Punch"} } },
}

-- BLOCK + UP + HIGH KICK.  Block goes down first - it is what stops Up from
-- becoming a jump - Up joins it, and HK lands last, so bj_hi_kick is the
-- entry that fires with the other two already held.
local UNMORPH_SCRIPT = { {0,34,"P1 Block"}, {6,34,"P1 Up"}, {14,22,"P1 High Kick"} }

-- The morph animation runs well past the last button: shang_morph plays a
-- whole mframew lane before it writes ochar, ~40 frames after the input ends.
-- Mileena's is a 52-frame hold on top of that, so the read has to be late.
local MORPH_WINDOW  = 100   -- input + settle before reading ochar
local UNMORPH_START = 125   -- gesture begins this far into the trial
local TRIAL_LEN     = UNMORPH_START + 70

local cpu, space = nil, nil
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local last_gstate = -1
local p1_confirm_start = 0
local did_direct_select = false
local control_start, control_done = 0, false
local trial_index, trial_frame0 = 0, 0
local morphed_ochar, unmorph_delay = nil, nil
local early_revert, synthetic = false, false
local results = {}
local finished, did_error = false, false
local last_status_frame = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Low Punch"] = true, ["P1 Block"] = true,
        ["P1 High Kick"] = true, ["P1 Low Kick"] = true,
        ["P1 Up"] = true, ["P1 Down"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local missing = {}
    for name in pairs(wanted) do
        if not fields[name] then missing[#missing + 1] = name end
    end
    if #missing > 0 then log("MISSING inputs: %s", table.concat(missing, ", ")) end
    return #missing == 0
end

local function p1_ochar()
    local o = r32(A.p1_obj)
    if o == 0 then return -1 end
    return r16(o + O.ochar)
end

-- Keep them apart and healthy: nothing in this test is about contact, and a
-- stray hit puts the player in pm_reacting, which restricted_xfer refuses.
local function pin_positions()
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    local x = r16(p2 + O.oxpos) - 130
    w16(p1 + O.oxpos, x)
    w32(p1 + O.oxval, (x << 16) & 0xffffffff)
    if A.p1_bar ~= 0 then w16(A.p1_bar, MAX_HP) end
    if A.p2_bar ~= 0 then w16(A.p2_bar, MAX_HP) end
end

local function force_select()
    w16(A.p1_char, FT_ST)
    w16(A.p2_char, P2_CHAR)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    if not did_direct_select then
        did_direct_select = true
        log("direct_select P1=ShangTsung(%d) P2=char(%d) stage=%d", FT_ST, P2_CHAR, STAGE_ID)
    end
end

local function script_wants(script, base, name)
    if base == 0 then return false end
    local rel = frame - base
    for _, step in ipairs(script) do
        if name == step[3] and rel >= step[1] and rel < step[2] then return true end
    end
    return false
end

local function current_trial()
    if trial_index < 1 or trial_index > #TRIALS then return nil end
    return TRIALS[trial_index]
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
        return false
    end
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
        return false
    end
    if control_start > 0 and not control_done then
        return script_wants(UNMORPH_SCRIPT, control_start, name)
    end
    local trial = current_trial()
    if trial and trial_frame0 > 0 and frame >= trial_frame0 then
        local rel = frame - trial_frame0
        if rel < MORPH_WINDOW then
            return script_wants(trial.script, trial_frame0, name)
        end
        if rel >= UNMORPH_START then
            return script_wants(UNMORPH_SCRIPT, trial_frame0 + UNMORPH_START, name)
        end
    end
    return false
end

local function cpu_pc()
    if not cpu then return nil end
    for _, n in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, item = pcall(function() return cpu.state[n] end)
        if ok and item then
            local okv, v = pcall(function() return item.value end)
            if okv then return v end
        end
    end
    return nil
end

local function check_lockup()
    local pc = cpu_pc()
    if pc and A.system_lockup ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
        log("ERROR lockup pc=%s pf=%s", hx(pc), hx(r32(A.pf_ram)))
        did_error = true
        return true
    end
    return false
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- results ----")
    local pass, fail = 0, 0
    for _, r in ipairs(results) do
        log("%-9s morph=%-9s unmorph=%-5s (ochar=%s after %s frames)%s",
            r.name,
            r.synthetic and "SYNTHETIC" or tostring(r.morph_ok),
            tostring(r.unmorph_ok), tostring(r.final_ochar), tostring(r.unmorph_delay),
            r.early and "  EARLY-REVERT" or "")
        if r.unmorph_ok then pass = pass + 1 else fail = fail + 1 end
    end
    log("%s reason=%s trials_pass=%d trials_fail=%d",
        (ok and fail == 0 and not did_error) and "PASS" or "FAIL", reason, pass, fail)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function step_state()
    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d", frame)
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        force_select()
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_ST and r16(A.p2_char) == P2_CHAR then
            p1_confirm_start = frame + 25
            log("confirm_start=%d", p1_confirm_start)
        end
        if frame > 8000 then finish(false, "never_reached_fight") end
        return
    end

    if check_lockup() then finish(false, "lockup"); return end
    pin_positions()

    if frame - last_status_frame >= 240 then
        last_status_frame = frame
        log("status frame=%d gs=%d ochar=%d trial=%d", frame, gs, p1_ochar(), trial_index)
    end

    -- settle, then the negative control, then the trials
    if control_start == 0 then
        if frame - fighting_frame > 150 then
            control_start = frame
            log("negative_control_start frame=%d ochar=%d", frame, p1_ochar())
        end
        return
    end

    if not control_done then
        if frame - control_start >= 70 then
            control_done = true
            local oc = p1_ochar()
            local ok = (oc == FT_ST)
            log("negative_control ochar=%d want=%d %s", oc, FT_ST,
                ok and "OK - gesture is inert when he is already Shang" or "FAIL")
            if not ok then did_error = true end
            trial_index = 1
            trial_frame0 = frame + 25
            log("trial 1/%d %s begins frame=%d", #TRIALS, TRIALS[1].name, trial_frame0)
        end
        return
    end

    local trial = current_trial()
    if not trial then finish(true, "all_trials_done"); return end
    if frame < trial_frame0 then return end
    local rel = frame - trial_frame0
    local oc = p1_ochar()

    if rel == MORPH_WINDOW then
        morphed_ochar = oc
        log("%-9s morph_read frame=%d ochar=%d want=%d %s", trial.name, frame, oc,
            trial.ochar, oc == trial.ochar and "OK" or "MISS")
        -- The gesture does not branch on which form he is wearing, so a form
        -- the rig cannot INPUT is still worth testing the revert out of.
        -- Stamp ochar the way do_kintaro_fatal stamps its own and carry on,
        -- flagged SYNTHETIC so the report never claims a real morph happened.
        if oc ~= trial.ochar then
            local o = r32(A.p1_obj)
            if o ~= 0 then
                w16(o + O.ochar, trial.ochar)
                -- Stamp l_morph too.  back_to_shang_check reverts once
                -- get_tsl(l_morph) passes 0200h, and a stamp that was never
                -- written reads as "ages ago", so a bare ochar poke is
                -- auto-reverted within a couple of frames and the gesture
                -- never gets its turn.  This is p1's half of the pair.
                if A.l_morph ~= 0 and A.tick ~= 0 then
                    w16(A.l_morph, r16(A.tick))
                end
                synthetic = true
                morphed_ochar = trial.ochar
                log("%-9s morph input did not take; ochar stamped to %d (SYNTHETIC)",
                    trial.name, trial.ochar)
            end
        end
    end
    if rel > MORPH_WINDOW and rel < UNMORPH_START and morphed_ochar ~= nil
        and morphed_ochar ~= FT_ST and oc == FT_ST and not early_revert then
        early_revert = true
        log("%-9s WARN reverted at rel=%d, before the gesture", trial.name, rel)
    end
    if rel >= UNMORPH_START and unmorph_delay == nil and morphed_ochar ~= nil
        and morphed_ochar ~= FT_ST and oc == FT_ST and not early_revert then
        unmorph_delay = rel - UNMORPH_START
        log("%-9s unmorphed frame=%d, %d frames after the gesture began",
            trial.name, frame, unmorph_delay)
    end

    if rel >= TRIAL_LEN then
        local final = p1_ochar()
        local morph_ok = (morphed_ochar == trial.ochar)
        results[#results + 1] = {
            name = trial.name, want = trial.ochar,
            morph_ok = morph_ok and not synthetic, morph_ochar = morphed_ochar,
            unmorph_ok = morph_ok and final == FT_ST and unmorph_delay ~= nil,
            final_ochar = final, unmorph_delay = unmorph_delay, early = early_revert,
            synthetic = synthetic,
        }
        -- Never carry a form into the next trial: if the gesture failed, put
        -- him back by hand so one failure does not cascade into ten.
        if final ~= FT_ST then
            local o = r32(A.p1_obj)
            if o ~= 0 then w16(o + O.ochar, FT_ST) end
            log("%-9s forced back to ft_st for the next trial", trial.name)
        end
        trial_index = trial_index + 1
        trial_frame0 = frame + 35
            morphed_ochar, unmorph_delay = nil, nil
        early_revert, synthetic = false, false
        local nxt = current_trial()
        if nxt then
            log("trial %d/%d %s begins frame=%d", trial_index, #TRIALS, nxt.name, trial_frame0)
        end
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "required_input_missing"); return end
        log("P1 Shang Tsung vs P2 char=%d stage=%d; gesture = Block+Up+HighKick",
            P2_CHAR, STAGE_ID)
    end
    if not space or finished then return end

    step_state()

    if frame > 20000 then finish(false, "global_timeout") end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)

emu.register_stop(function()
    if logfh then logfh:close(); logfh = nil end
end)
