-- hitbox_overlay_test.lua
--
-- Exercises the CPU-drawn hit/hurt box overlay (box_pass, MKDISP.ASM).
--
-- What it proves, in order of how easy each is to get wrong:
--   1. box_pass is reached at all             -> geo_ran / geo_drew climb
--   2. it actually appends segments            -> geo_count > 0 the tick before
--                                                 geo_pass consumes it
--   3. the boxes land where the code says      -> screenshots on active frames
--   4. it does not wedge or crash the machine  -> the fight runs to a finish
--      with the overlay on for every frame
--
-- The overlay is off unless f_colbox is non-zero, so the rig pokes the mask
-- and holds it there.  f_colbox is a BITMASK now:
--     1 strike box   2 hurt boxes   4 compared victim box   8 anchors
-- HITBOX_MASK selects; default 15 = everything.
--
-- Env knobs:
--   HITBOX_MASK=N       f_colbox value to hold (default 15)
--   HITBOX_RANGE=N      px to snap P1 behind P2 before attacking (default 95)
--   HITBOX_FRAMES=N     frames to run after the fight starts (default 900)
--   HITBOX_SYNTH=1      park a synthetic box each frame as a draw-path control
--   HITBOX_LOG=path     override log path

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end

local LOG_PATH = os.getenv("HITBOX_LOG") or (ROOT .. "/tools/hitbox_overlay_test.log")
local MASK = getenv_int("HITBOX_MASK", 15)
local SNAP_X = getenv_int("HITBOX_RANGE", 95)
local RUN_FRAMES = getenv_int("HITBOX_FRAMES", 900)
local SYNTH = os.getenv("HITBOX_SYNTH") == "1"

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local function log(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    line = string.format("[%06d] %s", frame, line)
    if logfh then logfh:write(line .. "\n"); logfh:flush() end
    io.write("[hitbox] " .. line .. "\n")
end

local function hx(v) return string.format("0x%x", v or 0) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

-- symbols straight out of the linker map; these are RAW map addresses, which
-- is what space:read/write take (see reference_mame_lua_bit_addresses).
local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(name)
    local v = symbols[name]
    if v == nil then log("WARN missing symbol %s", name); return 0 end
    return v
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
    worldtlx      = sym("worldtlx"),
    worldtly      = sym("worldtly"),
    ground_y      = sym("ground_y"),
    f_colbox      = sym("f_colbox"),
    geo_count     = sym("geo_count"),
    geo_ran       = sym("geo_ran"),
    geo_drew      = sym("geo_drew"),
    geo_lastxy    = sym("geo_lastxy"),
    peak_overload = sym("peak_overload"),
}

-- bx_list and bx_wr are exported now.  They used to be derived from the
-- symbols either side of them in .bss, which broke the moment that block
-- gained a word - resolve them instead.
A.tick = sym("tick")
local BX_LIST = sym("bx_list")
local BX_WR = sym("bx_wr")
local BX_MAX, BX_REC = 8, 128

local O = { oxpos = 0x090, oypos = 0x0b0, oflags = 0x0f0, oimg = 0x1a0, ochar = 0x1f0 }
local P = { action = 0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KANG, FT_JAX = 1, 11
local STAGE_ID = 5

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame = 0, 0
local p1_confirm_start = 0
local snap_index = 0
local finished = false
local attack_start = 0
local shots_taken = 0
local max_geo_count = 0
local geo_ran_at_fight, geo_drew_at_fight = 0, 0
local seen_nonzero_count = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function cache_fields()
    local wanted = {
        ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 High Kick"] = true, ["P1 Low Kick"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Up"] = true, ["P1 Down"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    local ok = true
    for name in pairs(wanted) do
        if not fields[name] then log("input %-16s MISSING", name); ok = false end
    end
    return ok
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d label=%s ok=%s", snap_index, label, tostring(ok))
    snap_index = snap_index + 1
end

local function p1_action()
    local p = r32(A.p1_proc)
    if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state_line(tag)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1o ~= 0 then p1x, p1y = s16(r16(p1o + O.oxpos)), s16(r16(p1o + O.oypos)) end
    if p2o ~= 0 then p2x, p2y = s16(r16(p2o + O.oxpos)), s16(r16(p2o + O.oypos)) end
    return string.format(
        "%s gs=%d ws=%d act=%s hp=%d/%d p1=(%d,%d) p2=(%d,%d) tlx=%d gnd=%d " ..
        "colbox=%d geo(count=%d ran=%d drew=%d last=%s) peak=%d",
        tag, r16(A.gstate), r16(A.winner_status), hx(p1_action()),
        r16(A.p1_bar), r16(A.p2_bar), p1x, p1y, p2x, p2y,
        r32(A.worldtlx) >> 16, s16(r16(A.ground_y)),
        r16(A.f_colbox), r16(A.geo_count), r16(A.geo_ran), r16(A.geo_drew),
        hx(r32(A.geo_lastxy)), r16(A.peak_overload))
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    local ran = r16(A.geo_ran) - geo_ran_at_fight
    local drew = r16(A.geo_drew) - geo_drew_at_fight
    log("RESULT mask=%d frames_in_fight=%d geo_ran=+%d geo_drew=+%d max_geo_count=%d segments_seen=%s",
        MASK, (fighting_frame > 0) and (frame - fighting_frame) or 0,
        ran, drew, max_geo_count, tostring(seen_nonzero_count))
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", reason, state_line("end"))
    snap(ok and "final_ok" or ("final_" .. reason))
    log("[hitbox] finished")
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_JAX)
    w16(A.curback, STAGE_ID)
    if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
    if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
end

local function fighters_ok()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return false end
    return r16(p1o + O.ochar) == FT_KANG and r16(p2o + O.ochar) == FT_JAX
end

local function snap_range()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local p2x = s16(r16(p2o + O.oxpos))
    local x = p2x - SNAP_X
    w32(p1o + 0x080, (x << 16) & 0xffffffff)   -- oxval
    w16(p1o + O.oxpos, x)
end

-- One attack every ATTACK_PERIOD frames, cycling HP / HK / LK so the rig
-- walks several different strike-table records rather than one.
local ATTACK_PERIOD = 70
local function attack_press(name, rel)
    local which = ((frame - attack_start) // ATTACK_PERIOD) % 3
    if rel >= 4 and rel < 12 then
        if which == 0 and name == "P1 High Punch" then return true end
        if which == 1 and name == "P1 High Kick" then return true end
        if which == 2 and name == "P1 Low Kick" then return true end
    end
    return false
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    if attack_start > 0 then
        return attack_press(name, (frame - attack_start) % ATTACK_PERIOD)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("loaded mask=%d range=%d run_frames=%d f_colbox=%s geo_count=%s",
            MASK, SNAP_X, RUN_FRAMES, hx(A.f_colbox), hx(A.geo_count))
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        -- log EVERY transition: a rig that only reports fight_start cannot
        -- tell "still booting" from "parked in the service menu", and
        -- gs_diag(8) is exactly where a stray keypress on the volume switch
        -- leaves the machine.
        log("gstate %d -> %d%s", last_gstate, gs,
            (gs == 8) and "  <-- gs_diag, SERVICE MENU (stray key?)" or "")
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            geo_ran_at_fight = r16(A.geo_ran)
            geo_drew_at_fight = r16(A.geo_drew)
            log("fight_start | %s", state_line("fs"))
        end
        last_gstate = gs
    end

    -- heartbeat while not fighting, so a stall is visible in the log
    if fighting_frame == 0 and frame % 600 == 0 then
        log("still booting: gstate=%d p1_char=%d p2_char=%d charsel=%d",
            gs, r16(A.p1_char), r16(A.p2_char), charsel_frame)
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0
        and frame > charsel_frame + 90
        and r16(A.p1_char) == FT_KANG and r16(A.p2_char) == FT_JAX then
        p1_confirm_start = frame + 25
    end

    -- Hold the overlay on for EVERY frame of the fight.  A crash that only
    -- happens while the overlay is up is the whole risk of a CPU draw pass,
    -- so it never gets switched off mid-run.
    if fighting_frame > 0 and A.f_colbox ~= 0 then
        if r16(A.f_colbox) ~= MASK then w16(A.f_colbox, MASK) end
    end

    -- Sampled BEFORE geo_pass consumes the list on most frames; whichever
    -- side of the display interrupt we land on, a non-zero reading proves
    -- the producer ran.
    if fighting_frame > 0 then
        local c = r16(A.geo_count)
        if c > max_geo_count then max_geo_count = c end
        if c > 0 then seen_nonzero_count = true end
    end

    if fighting_frame > 0 and attack_start == 0 and fighters_ok()
        and frame - fighting_frame > 100 then
        snap_range()
        attack_start = frame
        log("attacking from range=%d | %s", SNAP_X, state_line("atk"))
    end

    -- Control experiment (HITBOX_SYNTH=1): park a synthetic box in the LAST
    -- slot every frame, at a fixed world position with a current stamp.  If
    -- that one draws and strike_check's do not, the fault is in the
    -- producer's timing; if none of them draw, it is the drain loop.  That is
    -- exactly the split it was written to settle - the strike box looked
    -- missing when the capture was simply landing between strikes.
    if SYNTH and fighting_frame > 0 then
        local base = BX_LIST + (BX_MAX - 1) * BX_REC
        local wx = r32(A.worldtlx) >> 16
        w16(base + 0,  (wx + 40) & 0xffff)   -- left
        w16(base + 16, 40)                    -- top
        w16(base + 32, (wx + 120) & 0xffff)  -- right
        w16(base + 48, 80)                    -- bottom
        w16(base + 64, 0x0c)                  -- bpal_yellow, distinct from the rest
        w16(base + 80, r16(A.tick))           -- stamp LAST, same as box_add
    end

    -- Screenshots on the frames where a strike box is live: read the list and
    -- shoot the frame a fresh strike box (colour 0dh) is actually parked, so
    -- the capture cannot miss the few ticks the box exists for.
    if attack_start > 0 and shots_taken < 12 then
        local tick = r16(A.tick)
        local fresh = nil
        for i = 0, BX_MAX - 2 do
            local base = BX_LIST + i * BX_REC
            local st = r16(base + 80)
            if st ~= 0 and ((tick - st) & 0xffff) <= 1 and r16(base + 64) == 0x0d then
                fresh = string.format("s%d[%d,%d..%d,%d]", i,
                    s16(r16(base)), s16(r16(base + 16)),
                    s16(r16(base + 32)), s16(r16(base + 48)))
                break
            end
        end
        if fresh then
            snap(string.format("strike_%02d", shots_taken))
            log("strike box live %s | %s", fresh, state_line("shot"))
            shots_taken = shots_taken + 1
        end
    end

    if fighting_frame > 0 and (frame - fighting_frame) > RUN_FRAMES then
        local ran = r16(A.geo_ran) - geo_ran_at_fight
        local drew = r16(A.geo_drew) - geo_drew_at_fight
        -- geo_drew only advances on frames where geo_count was non-zero when
        -- geo_pass ran, so "drew on nearly every frame" IS the proof that the
        -- overlay emitted.  geo_count itself is cleared inside the display
        -- interrupt, so sampling it from a Lua frame hook reads 0 almost
        -- always - that was a bad criterion, not a bad overlay.
        if ran <= 0 then finish(false, "box_pass_never_ran")
        elseif drew < (ran * 3) // 4 then finish(false, "few_frames_drew")
        else finish(true, "ran_clean") end
        return
    end

    if frame > 12000 then finish(false, "timeout_no_fight") end
end)

emu.register_periodic(function()
    if not space or finished then return end
    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
