-- floor_skip_probe.lua - measure how many floor rows a stage could stop drawing.
--
-- `floor_code` (MKDISP.ASM) draws the skewing ground one 400x1 blit per texture
-- row.  `@skew_skip` is how many rows at the TOP of that band - the BACK of the
-- room - the stage guarantees something else paints over opaquely, so it can
-- stop drawing them.  THE TOWER sets 54; every other stage sets 0.
--
-- Whether another stage could is a COVERAGE question, and the honest way to ask
-- it is to USE THE MECHANISM AS THE INSTRUMENT: park the camera, force
-- @skew_skip to the whole floor height, and photograph the screen.  Every row
-- that changes was a row the player could see; every row that does not was
-- being drawn and thrown away.  No geometry model, no recomposition of the
-- background off disk, and it measures the machine rather than a picture of it.
--
-- Two runs per stage - FSP_SKIP=0 for the baseline and FSP_SKIP=<height> for the
-- probe - snapshotted at the same frames, then diffed by
-- tools/run_floor_skip_probe.py.  The first screen row that differs, minus the
-- top of the floor band, IS the answer.
--
-- THE TOWER is the control: it must come back at 54.
--
-- env: FSP_STAGE  curback index (1 tomb, 2 battle, 3 tower, 4 forest,
--                 5 armory, 8 arena)
--      FSP_SKIP   value to pin into @skew_skip every frame
--      FSP_TAG    label for the log and snapshot lines
--      FSP_LOG    log path

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local STAGE = tonumber(os.getenv("FSP_STAGE") or "3")
local SKIP = tonumber(os.getenv("FSP_SKIP") or "0")
local TAG = os.getenv("FSP_TAG") or "base"
local LOG = os.getenv("FSP_LOG") or (ROOT .. "/tools/floor_skip_probe.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[fsp] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[n] = tonumber(a, 16)
    end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    skew_skip = sym("skew_skip"), skew_y = sym("skew_y"),
    skew_height = sym("skew_height"), worldtly = sym("worldtly"),
    ceiling_y = sym("ceiling_y"), worldtlx = sym("worldtlx"),
    f_freeze_timer = symbols["f_freeze_timer"],
}
local O = { oxval = 0x080, oflags2 = 0x160 }
local M_INVISO = 0x20   -- DISPEQU.ASM m_inviso
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_CAGE = 1, 2

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm, announced = 0, 0, false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true,
                   ["1 Player Start"] = true, ["P1 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then
        pcall(function() s:snapshot() end)
        log("SNAP %s %s frame=%d", TAG, label, frame)
    end
end

-- Park both fighters so the scroller drags the camera to a limit and holds it,
-- and HIDE them.
--
-- Hiding is not cosmetic.  The two runs are separate emulation sessions, and a
-- fighter's idle animation does not land on the same phase in both - a first
-- pass diffed 13-37 columns wide at rows 186-198 on THE TOWER, which is a
-- fighter's torso, not a floor row.  A floor row is a 400x1 blit, so with the
-- fighters gone anything that differs inside the band is the floor or what
-- covers it, which is the only question being asked.
local function park(x)
    for _, h in ipairs({ A.p1_obj, A.p2_obj }) do
        local o = r32(h)
        if o ~= 0 then
            w32(o + O.oxval, (x & 0xffff) << 16)
            w16(o + O.oflags2, r16(o + O.oflags2) | M_INVISO)
        end
    end
end

local HOLD = 320
local STOPS = {
    { name = "left",  x = 40,   at = HOLD },
    { name = "mid",   x = 560,  at = HOLD * 2 },
    { name = "right", x = 1400, at = HOLD * 3 },
}

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("stage=%d skip=%d tag=%s", STAGE, SKIP, TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then
            p1_confirm = frame
        end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then
            p2_confirm = frame
        end
    end
    if fighting_frame == 0 then w16(A.curback, STAGE) end

    if fighting_frame > 0 then
        -- SKIP < 0 means OBSERVE: leave whatever the stage sets itself.  The
        -- baseline has to be the SHIPPED picture, not skew_skip forced to 0 -
        -- THE TOWER sets 54 in tower_backdrop_reflections, and zeroing it draws
        -- 54 rows the real game does not, so the diff then measured the probe
        -- against a stage that does not exist.
        --
        -- Otherwise pin it EVERY frame: setup_floor_info clears skew_skip on
        -- every stage load, and a round transition would take the value with it.
        if SKIP >= 0 then w16(A.skew_skip, SKIP) end
        if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
        if not announced then
            announced = true
            log("floor band: skew_y=%d height=%d ceiling_y=%d worldtly=%d",
                s16(r16(A.skew_y)), s16(r16(A.skew_height)),
                s16(r16(A.ceiling_y)), s16(r32(A.worldtly) >> 16))
        end
        local rel = frame - fighting_frame
        for _, st in ipairs(STOPS) do
            if rel >= st.at - HOLD and rel < st.at then park(st.x) end
            if rel == st.at then
                log("%s worldtlx=%d skew_skip=%d", st.name,
                    s16(r32(A.worldtlx) >> 16), r16(A.skew_skip))
                snap(st.name)
            end
        end
        if rel > STOPS[#STOPS].at + 4 then
            log("done")
            logfh:close()
            manager.machine:exit()
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
