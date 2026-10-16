-- fx_showcase.lua - each runtime-off graphics prototype, armed in a real
-- fight with parameters a producer would plausibly use, and captured.
--
-- This is a DEMONSTRATION rig, not a validation one: the proofs live in each
-- prototype's own doc and rig.  Here every effect is pointed at something it
-- could actually be used for, so the pictures show intent rather than a test
-- pattern.
--
--   FX_MODE=palrect   a 32x32 recoloured box on the far fighter (spot tint)
--   FX_MODE=mosaic    the far fighter pixelated in 8 px blocks (dissolve)
--   FX_MODE=stipple   a 50% checkerboard pen over him (ghosting / fade)
--   FX_MODE=strips    the far plane waving in 8 bands (heat haze) - needs a
--                     stage whose dlist names strip_layer, i.e. FX_STAGE=2
--   FX_MODE=reflect   both fighters mirrored into the floor
--   FX_MODE=spans     a shockwave ring growing from the near fighter's feet
--   FX_MODE=rowrep    an 8-frame vertical squash of the whole screen (impact)
--   FX_MODE=off       the same scene with nothing armed (the baseline)
--
-- env: FX_MODE, FX_STAGE (curback), FX_LOG, MK2_ROOT
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("FX_MODE") or "off"
local STAGE = tonumber(os.getenv("FX_STAGE") or "0")
local LOG = os.getenv("FX_LOG") or (ROOT .. "/tools/fx_showcase.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[fx] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end
local function opt(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), worldtlx = sym("worldtlx"), ground_y = opt("ground_y"),
    -- the prototypes' runtime controls
    pr_count = opt("pr_count"), pr_xy = opt("pr_xy"), pr_hw = opt("pr_hw"), pr_map = opt("pr_map"),
    pr_ran = opt("pr_ran"), pr_refused = opt("pr_refused"),
    cp_count = opt("cp_count"), cp_mode = opt("cp_mode"), cp_xy = opt("cp_xy"), cp_hw = opt("cp_hw"),
    cp_arg = opt("cp_arg"), cp_map = opt("cp_map"), cp_ran = opt("cp_ran"), cp_refused = opt("cp_refused"),
    f_strip = opt("f_strip"), strip_n = opt("strip_n"), strip_top = opt("strip_top"),
    strip_h = opt("strip_h"), strip_off = opt("strip_off"), strip_ran = opt("strip_ran"),
    f_reflect = opt("f_reflect"), refl_parm = opt("refl_parm"),
    sp_ticks = opt("sp_ticks"), sp_cx = opt("sp_cx"), sp_cy = opt("sp_cy"), sp_r = opt("sp_r"),
    sp_thick = opt("sp_thick"), sp_grow = opt("sp_grow"), sp_col = opt("sp_col"), sp_spans = opt("sp_spans"),
    f_rowrep = opt("f_rowrep"),
}
local OPAL, OXPOS = 0x140, 0x090
local GS_PSEL, GS_FIGHTING, MAXBAR = 4, 2, 0xa1
local ARM_AT, SHOTS, GAP = 150, 7, 4

local frame, space, fields = 0, nil, {}
local charsel, fighting, confirm, armed_at, snaps = 0, 0, 0, 0, 0
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function screen_x(objptr)
    local o = r32(objptr); if o == 0 then return nil end
    return s16(r16(o + OXPOS)) - (s16(r32(A.worldtlx) >> 16))
end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting == 0 then
        return (name == "P1 High Punch" or name == "P2 High Punch") and confirm > 0
               and frame >= confirm and frame < confirm + 40
    end
    return false
end

-- one-time setup when the effect is armed
local function arm()
    local p2x = screen_x(A.p2_obj) or 260
    local p1x = screen_x(A.p1_obj) or 120
    if MODE == "palrect" and A.pr_map then
        -- every selector in the box mapped to the near fighter's palette slot:
        -- the rectangle keeps its shapes and takes his colours
        local o = r32(A.p1_obj)
        local slot = o ~= 0 and (r16(o + OPAL) & 0xff) or 0
        for i = 0, 255 do w16(A.pr_map + i * 16, slot) end
        log("palrect map -> slot %d", slot)
    elseif MODE == "reflect" and A.f_reflect then
        w16(A.f_reflect, 1)
        log("reflect on, refl_parm=%08x", A.refl_parm and r32(A.refl_parm) or 0)
    elseif MODE == "strips" and A.f_strip then
        -- the banded plane on this stage sits at rows ~100-136; a producer picks
        -- its own offsets, so this demo writes a wave of its own (f_strip = 1)
        w16(A.strip_n, 8); w16(A.strip_top, 100); w16(A.strip_h, 5)
        local wave = { 0, 5, 9, 5, 0, -5, -9, -5 }
        for i, off in ipairs(wave) do w16(A.strip_off + (i - 1) * 16, off & 0xffff) end
        w16(A.f_strip, 1)
        log("strips on: 8 bands from row 100, 5 rows each, offsets as written")
    elseif MODE == "spans" and A.sp_ticks then
        w16(A.sp_cx, (p1x + 20) & 0xffff); w16(A.sp_cy, 196)
        w16(A.sp_r, 8); w16(A.sp_thick, 7); w16(A.sp_grow, 4)
        w32(A.sp_col, 0x000b000b); w16(A.sp_ticks, 48)
        log("spans: ring at screen x=%d y=196, growing 4 px/frame", p1x + 20)
    elseif MODE == "rowrep" and A.f_rowrep then
        w16(A.f_rowrep, 1)
        log("rowrep: 1 (each row drawn twice) for 8 frames")
    end
    log("ARMED %s frame=%d p1x=%d p2x=%d", MODE, frame, p1x, p2x)
end

-- effects that must be re-armed every frame (their count words are consumed)
local function per_frame(rel)
    local p2x = screen_x(A.p2_obj) or 260
    local box_x = ((p2x - 26) // 2) * 2
    if box_x < 0 then box_x = 0 end
    if MODE == "palrect" and A.pr_count then
        -- pal_rect caps the rectangle at 1024 px (MKDISP prc_bad): 32x32 is the
        -- cap exactly, and its own doc times a 32x32 box at ~10% of a frame
        w32(A.pr_xy, ((168 & 0xffff) << 16) | (box_x & 0xffff))
        w32(A.pr_hw, ((32 & 0xffff) << 16) | 32)
        w16(A.pr_count, 1)
    elseif (MODE == "mosaic" or MODE == "stipple") and A.cp_count then
        w16(A.cp_mode, MODE == "mosaic" and 1 or 2)
        w32(A.cp_xy, ((150 & 0xffff) << 16) | (box_x & 0xffff))
        if MODE == "mosaic" then
            w32(A.cp_hw, ((64 & 0xffff) << 16) | 48); w16(A.cp_arg, 8)
        else
            w32(A.cp_hw, ((32 & 0xffff) << 16) | 48); w16(A.cp_arg, 0x0b)
            w16(A.cp_map, 0)
        end
        w16(A.cp_count, 1)
    elseif MODE == "rowrep" and A.f_rowrep and rel == 8 then
        w16(A.f_rowrep, 0)                      -- the squash is a pulse
    end
end

local function sentinels()
    local bits = {}
    if A.pr_ran then bits[#bits + 1] = string.format("pr_ran=%d refused=%d", r16(A.pr_ran), r16(A.pr_refused)) end
    if A.cp_ran then bits[#bits + 1] = string.format("cp_ran=%d refused=%d", r16(A.cp_ran), r16(A.cp_refused)) end
    if A.strip_ran then bits[#bits + 1] = string.format("strip_ran=%d", r16(A.strip_ran)) end
    if A.sp_spans then bits[#bits + 1] = string.format("sp_spans=%d", r16(A.sp_spans)) end
    return table.concat(bits, " ")
end

local function finish()
    if finished then return end
    finished = true
    log("RESULT mode=%s snaps=%d %s", MODE, snaps, sentinels())
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("start mode=%s stage=%d", MODE, STAGE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space or finished then return end
    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel == 0 then charsel = frame end
    if charsel > 0 and fighting == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 8); w16(A.p2_char, 10)          -- Sub-Zero vs Scorpion
        w16(A.curback, STAGE); w16(A.map_position, 0); w16(A.battle_num, 1)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fighting == 0 then
        fighting = frame
        log("PREARM frame=%d p1x=%s p2x=%s", frame, tostring(screen_x(A.p1_obj)), tostring(screen_x(A.p2_obj)))
    end
    if fighting == 0 then
        if frame > 7000 then log("ERROR never reached fight"); finish() end
        return
    end
    w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
    w16(A.p1_bar_view, MAXBAR); w16(A.p2_bar_view, MAXBAR)
    w16(A.winner_status, 0)

    local rel = frame - fighting
    if rel == ARM_AT - 6 then
        manager.machine.video:snapshot(); snaps = snaps + 1     -- the scene, before
        log("SNAP baseline rel=%d", rel)
    end
    if rel == ARM_AT then armed_at = frame; arm() end
    if armed_at > 0 then
        local arel = frame - armed_at
        per_frame(arel)
        if arel % GAP == 0 and snaps <= SHOTS then
            manager.machine.video:snapshot(); snaps = snaps + 1
            log("SNAP %s arel=%d %s", MODE, arel, sentinels())
        end
        if arel > GAP * SHOTS + 8 then finish() end
    elseif rel > ARM_AT + 400 then
        finish()
    end
end)

emu.register_stop(function() if logfh then logfh:close() end end)
