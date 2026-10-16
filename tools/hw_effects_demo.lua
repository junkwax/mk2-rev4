-- hw_effects_demo.lua - live demo of the untapped T-unit hardware effects
-- catalogued in doc/UNUSED_HARDWARE_EFFECTS.md.
--
--   mame.exe mk2 -lua tools/hw_effects_demo.lua
--
-- Best run against rom/mk2_test.zip, which boots straight into a fight - every
-- object-level demo needs a live P1 object to point at.
--
-- Everything here is done by poking the SAME fields the game itself feeds to
-- the blitter every frame (oflags / oconst / oscale on the object block, and
-- the 34010 display registers).  Nothing is emulator-side trickery: if an
-- effect shows up on screen, the hardware really does it and ROM code could
-- drive it the same way.
--
-- ADDRESSING: this MAME Lua provider takes RAW TMS34010 BIT addresses.
-- mk2.map values and DISPEQU.ASM field offsets go in unmodified - no /8.
-- The script verifies that at startup against rom/mk2_flat.bin and says so.
--
-- WHAT EACH DEMO PROVES (and what it does not)
--
--   Vertical flip   the m_flipv bit reaches the DMA.  On a MULTIPART fighter
--                   every piece flips *in place*, so you get a scrambled body,
--                   not an inverted one - that is the honest result of setting
--                   the bit alone.  A real in-game upside-down pose needs
--                   ani_flip_vert, which re-lays the piece anipoints too.
--                   Watch a single-part object (a projectile, a blood drop) in
--                   scene mode to see a clean flip.
--
--   Constant colour the whole sprite collapses to one palette index, exactly
--                   like the player shadows.  This is the big one: silhouettes,
--                   hit flashes and freeze tints for zero video ROM.
--                   Its inverse, m_conzer (fill the TRANSPARENT area), is a
--                   no-op on MK2's art: every fighter frame is zero-compressed
--                   (control word 6580h, bit 7), so the blitter skips
--                   transparent runs and there are no zero pixels to replace.
--                   The demo says so rather than pretending.
--
--   Scale           oscale is [yscale:xscale], two independent 8.8 values.
--                   0x100 = 1:1, SMALLER = magnified.  Retail only ever wrote
--                   square scales; these presets are deliberately non-square.
--
--   dpytap          WORKS: whole screen slides horizontally, no redraw, no DMA
--                   cost.  Written once at init, so a poke sticks.
--
--   dpystrt         Reachable, but a Lua poke CANNOT be demonstrated: the page
--                   flip rewrites dpystrt every single frame and always wins
--                   (the demo proves it - "write STOMPED, wrote X, next frame
--                   reads Y").  The feature is real; driving it means adding
--                   the offset inside the flip itself (MKINIT.ASM:1321-1322),
--                   not layering a write on top from outside.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("HWFX_LOG") or (ROOT .. "/tools/hw_effects_demo.log")

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
local function log(fmt, ...)
    local line = "[hwfx] " .. string.format(fmt, ...)
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- ============================================================
-- SYMBOLS - parsed from mk2.map at load time so this never goes stale
-- ============================================================
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
local function sym(n) return symbols[n] end

local A = {
    gstate  = sym("gstate"),
    p1_obj  = sym("p1_obj"),
    p2_obj  = sym("p2_obj"),
    objlst  = sym("objlst"),
    objlst2 = sym("objlst2"),
    objlst3 = sym("objlst3"),
}

-- Object block field offsets, DISPEQU.ASM bit units, used raw.
local OLINK, OFLAGS, OPAL, OCONST = 0x00, 0xf0, 0x140, 0x150
local OFLAGS2, OSCALE, OXPOS      = 0x160, 0x180, 0x90
local OIMG = 0x1a0                             -- -> multipart RAM
-- multipart node layout (DISPEQU.ASM:86-92), bit offsets
local MP_CONTROL = 32 + 32
local DMACMP = 0x0080                          -- control word bit 7: zero compression

-- oflags bits (DISPEQU.ASM:99-105)
local M_WRZERO, M_WRNONZ = 0x01, 0x02
local M_CONZER, M_CONNON = 0x04, 0x08
local M_FLIPH,  M_FLIPV  = 0x10, 0x20
local M_CONST_BITS = M_CONZER | M_CONNON
local OURS = M_CONZER | M_CONNON | M_FLIPV     -- bits this script freely owns

-- m_conzer only does anything if the DMA is also told to WRITE zero pixels.
-- Fighters blit write-non-zero-only (that is what makes them transparent), so
-- the fill-transparent demo has to add m_wrzero as well - and must put it back
-- exactly where it found it, because opaque objects rely on it.  Tracked here
-- per object rather than blanket-cleared.
local wz_touched = {}

-- oflags2 bits
local M_MULTIPART = 0x0002

local SCALE_1_1 = 0x01000100                   -- getobj's default, MKDISP.ASM:1234

-- 34010 display registers (SYSEQU.ASM:323-341, MKINIT.ASM:1213-1230)
local R_DPYSTRT = 0xc0000090
local R_DPYTAP  = 0xc00001b0
local DPYSTRT_0, DPYSTRT_1 = 0xfffc, 0xeffc    -- DISPEQU.ASM:13-14, line 0 / line 256
local DPYSTRT_PER_LINE = 0x10                  -- (0xfffc - 0xeffc) / 256
local DPYTAP_INIT = 56 // 2                    -- MKINIT.ASM:1230, "adjust for the curse"

local GS_FIGHTING = 2
local SCRATCH_LO, SCRATCH_HI = 0x01000000, 0x02000000

-- ============================================================
-- MEMORY
-- ============================================================
local space
local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function w32(a, v) if space then space:write_u32(a, v & 0xffffffff) end end

-- ============================================================
-- STARTUP PROBES - prove the addressing before demoing anything
-- ============================================================
local probe = { addressing = false, dpystrt = false, dpytap = false }

local function probe_addressing()
    -- rom/mk2_flat.bin is the linked program ROM; word 0 lives at 0xff800000.
    local fh = io.open(ROOT .. "/rom/mk2_flat.bin", "rb")
    if not fh then
        log("PROBE addressing: rom/mk2_flat.bin missing - assuming raw bit addresses")
        probe.addressing = true
        return
    end
    local b = fh:read(4); fh:close()
    if not b or #b < 4 then probe.addressing = true; return end
    local want = string.byte(b, 1) | (string.byte(b, 2) << 8)
        | (string.byte(b, 3) << 16) | (string.byte(b, 4) << 24)
    local as_bit  = r32(0xff800000)
    local as_byte = r32(0xff800000 // 8)
    if as_bit == want then
        probe.addressing = true
        log("PROBE addressing: OK - raw BIT addresses (rom word0 %08x)", want)
    elseif as_byte == want then
        log("PROBE addressing: FAILED - this MAME wants BYTE addresses (bit/8).")
        log("  Every address in this script would need //8.  Refusing to poke memory.")
    else
        log("PROBE addressing: inconclusive (want %08x, bit=%08x byte=%08x)",
            want, as_bit, as_byte)
        log("  Continuing with raw bit addresses - watch for nonsense readings.")
        probe.addressing = true
    end
end

local function probe_display_regs()
    local tap = r16(R_DPYTAP)
    if tap == DPYTAP_INIT then
        probe.dpytap = true
        log("PROBE dpytap:  OK - reads %d, the value MKINIT.ASM:1230 installs", tap)
    else
        log("PROBE dpytap:  unreachable (reads %04x, expected %02x) - demo 9 disabled",
            tap, DPYTAP_INIT)
    end
    local ds = r16(R_DPYSTRT)
    if ds == DPYSTRT_0 or ds == DPYSTRT_1 then
        probe.dpystrt = true
        log("PROBE dpystrt: OK - reads %04x (%s)", ds,
            ds == DPYSTRT_0 and "page 0" or "page 1")
    else
        log("PROBE dpystrt: unreachable (reads %04x, expected %04x/%04x) - demo 8 disabled",
            ds, DPYSTRT_0, DPYSTRT_1)
    end
end

-- ============================================================
-- TARGETS
-- ============================================================
local TARGETS = { "p1", "p2", "fighters", "scene" }
local target_ix = 1

local function valid_obj(p)
    return p ~= 0 and p >= SCRATCH_LO and p < SCRATCH_HI
end

local function walk_list(head, out)
    local p, guard = r32(head), 0
    while valid_obj(p) and guard < 512 do
        out[#out + 1] = p
        p = r32(p + OLINK)
        guard = guard + 1
    end
end

-- Returns the list of object base addresses the current target resolves to.
local function targets()
    local t, mode = {}, TARGETS[target_ix]
    if mode == "p1" or mode == "fighters" then
        local p = r32(A.p1_obj); if valid_obj(p) then t[#t + 1] = p end
    end
    if mode == "p2" or mode == "fighters" then
        local p = r32(A.p2_obj); if valid_obj(p) then t[#t + 1] = p end
    end
    if mode == "scene" then
        walk_list(A.objlst, t); walk_list(A.objlst2, t); walk_list(A.objlst3, t)
    end
    return t
end

-- ============================================================
-- EFFECT STATE
-- ============================================================
local fx = {
    flipv    = false,
    silhou   = false,   -- m_connon: replace non-zero pixels with oconst
    fillzero = false,   -- m_conzer: replace zero (transparent) pixels
    strobe   = false,   -- MKZAP spear idiom: alternate normal / const flags
    -- Colour index within the object's OWN colour map, so what 0x0f looks
    -- like depends on the fighter's palette (it is black only in palette 0,
    -- which is what shadow_p1p2 uses - MAINEQU.ASM:1082 bpal_black = 0f0fh).
    -- Cycle with 4_PAD to find the shade you want.
    const_ix = 0x0f,
    scale_ix = 1,
    shake    = false,
    tap_ix   = 1,
}

-- oscale presets: {name, xscale, yscale}.  SMALLER value = MAGNIFIED.
local SCALES = {
    { "1:1 (retail default)",      0x100, 0x100 },
    { "squat - 2x wide, 1/2 tall", 0x080, 0x200 },
    { "lanky - 1/2 wide, 2x tall", 0x200, 0x080 },
    { "giant - 2x both",           0x080, 0x080 },
    { "mini  - 1/2 both",          0x200, 0x200 },
    { "pulse - animated squash",   nil,   nil   },
}

local TAPS = { 0, 8, 16, -8, -16 }

local frame = 0
local STEP_SECONDS = tonumber(os.getenv("HWFX_STEP_SECONDS") or "")
local STEP_FRAMES = STEP_SECONDS and math.floor(STEP_SECONDS * 60)
    or (((os.getenv("HWFX_AUTO") or "") ~= "") and 90 or 240)

-- oconst is the 8-bit colour index REPLICATED across 16 bits.
-- MKZAP.ASM:3260 writes 0e0eh; bpal_black is 0f0fh (MAINEQU.ASM:1082).
local function const_word(ix) return ((ix & 0xff) * 0x0101) & 0xffff end

local function want_flags_mask()
    local m = 0
    if fx.flipv then m = m | M_FLIPV end
    if fx.silhou then m = m | M_CONNON end
    if fx.fillzero then m = m | M_CONZER end
    return m
end

-- Re-asserted every frame: ani() rebuilds oflags on each frame change, and it
-- only PRESERVES bits 0-3 plus the flips (MKDISP.ASM:1571) - it does not know
-- we want them, so we keep writing them.
local function apply_objects()
    local mask = want_flags_mask()
    local strobe_off = fx.strobe and ((frame // 3) % 2 == 1)
    if strobe_off then mask = mask & ~M_CONST_BITS end

    local scale = nil
    local sc = SCALES[fx.scale_ix]
    if fx.scale_ix ~= 1 then
        if sc[2] then
            scale = ((sc[3] & 0xffff) << 16) | (sc[2] & 0xffff)
        else
            -- animated squash/stretch, volume roughly preserved
            local t = (frame % 60) / 60 * math.pi * 2
            local x = math.floor(0x100 - math.sin(t) * 0x60)
            local y = math.floor(0x100 + math.sin(t) * 0x60)
            scale = ((y & 0xffff) << 16) | (x & 0xffff)
        end
    end

    local any_fx = (mask ~= 0) or fx.strobe
    if not any_fx and scale == nil then return end

    for _, o in ipairs(targets()) do
        if mask ~= 0 or fx.strobe then
            local f = r16(o + OFLAGS)
            f = (f & ~OURS) | mask
            if (mask & M_CONZER) ~= 0 then
                if (f & M_WRZERO) == 0 then wz_touched[o] = true end
                f = f | M_WRZERO
            end
            w16(o + OFLAGS, f)
            if (mask & M_CONST_BITS) ~= 0 then
                w16(o + OCONST, const_word(fx.const_ix))
            end
        end
        if scale then w32(o + OSCALE, scale) end
    end
end

-- Restore by CLEARING the bits we own and writing oscale's documented default,
-- never by replaying a snapshot: object blocks get recycled by getobj, so a
-- stale snapshot could land on a completely different sprite.
local function restore_objects(list)
    for _, o in ipairs(list or targets()) do
        local f = r16(o + OFLAGS) & ~OURS
        if wz_touched[o] then f = f & ~M_WRZERO; wz_touched[o] = nil end
        w16(o + OFLAGS, f)
        w32(o + OSCALE, SCALE_1_1)
    end
end

-- ============================================================
-- DISPLAY REGISTERS  (experimental - see header)
-- ============================================================
local SHAKE_LINES = tonumber(os.getenv("HWFX_SHAKE_LINES") or "") or 3
local shake_report = { done = false, wrote = 0, readback = 0, next_frame = 0 }

local function apply_display()
    if not (fx.shake and probe.dpystrt) then return end
    -- Before anything else: did LAST frame's write survive, or did the game's
    -- page flip stomp it?  This is the whole question for this demo.
    if shake_report.next_frame == frame and not shake_report.done then
        shake_report.readback = r16(R_DPYSTRT)
        shake_report.done = true
        if shake_report.readback == shake_report.wrote then
            log("dpystrt: write SURVIVED a frame (%04x still there)", shake_report.wrote)
        else
            log("dpystrt: write STOMPED - wrote %04x, next frame reads %04x",
                shake_report.wrote, shake_report.readback)
            log("  the page flip rewrites it every frame; a real shake belongs in")
            log("  ROM code at the flip, not here.")
        end
    end

    -- dpystrt DECREASES as the start line rises.
    local lines = ((frame // 5) % 2 == 0) and SHAKE_LINES or -SHAKE_LINES
    local cur = r16(R_DPYSTRT)
    if cur == DPYSTRT_0 or cur == DPYSTRT_1 then
        local v = (cur - lines * DPYSTRT_PER_LINE) & 0xffff
        w16(R_DPYSTRT, v)
        if shake_report.wrote == 0 then
            shake_report.wrote = v
            shake_report.next_frame = frame + 1
        end
    end
end

local function apply_tap()
    if not probe.dpytap then return end
    w16(R_DPYTAP, (DPYTAP_INIT + TAPS[fx.tap_ix]) & 0xffff)
end

local function restore_display()
    if probe.dpytap then w16(R_DPYTAP, DPYTAP_INIT) end
    -- dpystrt repairs itself on the next page flip; nothing to undo.
end

-- ============================================================
-- ACTIONS
-- ============================================================
local function say(what, look_for)
    log("%-34s | look for: %s", what, look_for)
end

local function act_target()
    restore_objects()
    target_ix = target_ix % #TARGETS + 1
    local n = #targets()
    log("target -> %s (%d object%s)", TARGETS[target_ix], n, n == 1 and "" or "s")
    if TARGETS[target_ix] == "scene" then
        log("  NOTE scene mode also clears const bits on HUD/text objects that")
        log("  legitimately use them; they repair on their next redraw.")
    end
end

local function act_flipv()
    fx.flipv = not fx.flipv
    if not fx.flipv then restore_objects() end
    if fx.flipv then
        say("vertical flip ON (m_flipv)",
            "multipart pieces flip in place - see header note")
    else
        log("vertical flip OFF")
    end
end

local function act_silhouette()
    fx.silhou = not fx.silhou
    if not fx.silhou then restore_objects() end
    if fx.silhou then
        say(string.format("silhouette ON (m_connon, idx %02x)", fx.const_ix),
            "sprite collapses to one flat colour, like a shadow")
    else
        log("silhouette OFF")
    end
end

local function act_const_colour()
    fx.const_ix = (fx.const_ix + 1) % 64          -- 6bpp fighters = 64 entries
    log("const colour index -> %02x (oconst = %04x)",
        fx.const_ix, const_word(fx.const_ix))
    if not (fx.silhou or fx.fillzero) then
        log("  (no visible change until silhouette or fill-transparent is on)")
    end
end

-- The frame's own control word decides bpp and compression; it is re-merged
-- into the DMA control every frame (MKDISP.ASM:98-100 / :1571).
local function frame_control(o)
    if (r16(o + OFLAGS2) & M_MULTIPART) == 0 then return nil end
    local mp = r32(o + OIMG)
    if not valid_obj(mp) then return nil end
    return r16(mp + MP_CONTROL)
end

-- ...unless the art is zero-compressed, in which case there are no literal
-- zero pixels for the DMA to substitute and nothing happens.  Say so rather
-- than showing a blank result.
function report_compression()
    for _, o in ipairs(targets()) do
        local c = frame_control(o)
        if c and (c & DMACMP) ~= 0 then
            log("  NOTE obj %08x art is ZERO-COMPRESSED (control %04x, bit 7 set):",
                o, c)
            log("  the blitter SKIPS transparent runs instead of emitting zeros,")
            log("  so m_conzer/m_wrzero have nothing to act on. Expect NO change.")
            log("  m_conzer is only usable on uncompressed art.")
            return true
        end
    end
    return false
end

local function act_fillzero()
    fx.fillzero = not fx.fillzero
    if not fx.fillzero then restore_objects() end
    if fx.fillzero then
        say("fill-transparent ON (m_conzer + m_wrzero)",
            "a solid rectangle fills the sprite's bounding box behind it")
        report_compression()
    else
        log("fill-transparent OFF")
    end
end

local function act_strobe()
    fx.strobe = not fx.strobe
    if fx.strobe then
        fx.silhou = true
        say("strobe ON (MKZAP spear-block idiom)",
            "sprite alternates normal / flat colour every 3 frames")
    else
        fx.silhou = false
        restore_objects()
        log("strobe OFF")
    end
end

local function act_scale()
    fx.scale_ix = fx.scale_ix % #SCALES + 1
    local sc = SCALES[fx.scale_ix]
    if fx.scale_ix == 1 then
        restore_objects()
        log("scale -> %s", sc[1])
    else
        say(string.format("scale -> %s", sc[1]),
            "non-square scaling; retail only ever wrote square values")
    end
end

local function act_shake()
    if not probe.dpystrt then
        log("dpystrt shake unavailable - see startup probe")
        return
    end
    fx.shake = not fx.shake
    if fx.shake then
        say("dpystrt shake ON (EXPERIMENTAL)",
            "WHOLE screen judders vertically - HUD included, zero redraw")
    else
        log("dpystrt shake OFF")
    end
end

local function act_tap()
    if not probe.dpytap then
        log("dpytap shift unavailable - see startup probe")
        return
    end
    fx.tap_ix = fx.tap_ix % #TAPS + 1
    apply_tap()
    say(string.format("dpytap shift -> %+d units (%+d px)",
        TAPS[fx.tap_ix], TAPS[fx.tap_ix] * 2),
        "whole screen slides horizontally, no redraw")
end

local showcase = nil

local function act_restore()
    showcase = nil
    fx.flipv, fx.silhou, fx.fillzero, fx.strobe = false, false, false, false
    fx.scale_ix, fx.tap_ix, fx.shake = 1, 1, false
    -- clear every list, not just the current target, in case it was changed
    local all = {}
    walk_list(A.objlst, all); walk_list(A.objlst2, all); walk_list(A.objlst3, all)
    local p = r32(A.p1_obj); if valid_obj(p) then all[#all + 1] = p end
    p = r32(A.p2_obj); if valid_obj(p) then all[#all + 1] = p end
    restore_objects(all)
    restore_display()
    log("ALL EFFECTS CLEARED")
end

-- ============================================================
-- SHOWCASE - hands-off tour, ~4s per effect
-- ============================================================
local SHOWCASE = {
    { "silhouette (m_connon)", function() fx.silhou, fx.const_ix = true, 0x0f end,
      item = "2", look = "P1 collapses to ONE flat colour, shape intact" },

    { "silhouette, cycling colours", function() fx.silhou = true end, cycle = true,
      item = "2", look = "same blit, different oconst index each beat" },

    { "strobe (spear-block idiom)", function() fx.silhou, fx.strobe = true, true end,
      item = "2", look = "alternates normal / flat colour - a hit flash" },

    { "fill transparent (m_conzer)", function()
        fx.fillzero, fx.const_ix = true, 0x0f
        report_compression() end,
      item = "2b", look = "nothing - and that is the finding",
      verdict = "NO-OP: art is zero-compressed, no zero pixels to replace" },

    { "vertical flip (m_flipv)", function() fx.flipv = true end,
      item = "1", look = "art flips; multipart pieces scatter (needs ani_flip_vert)" },

    { "scale: squat", function() fx.scale_ix = 2 end,
      item = "3", look = "2x wide, half height - shadow scales too" },

    { "scale: lanky", function() fx.scale_ix = 3 end,
      item = "3", look = "half wide, 2x tall" },

    { "scale: animated squash/stretch", function() fx.scale_ix = 6 end,
      item = "3", look = "oscale driven per frame, X and Y independent" },

    { "dpytap horizontal shift", function() fx.tap_ix = 3; apply_tap() end,
      item = "5", look = "WHOLE screen slides sideways - HUD included, no redraw" },

    { "dpystrt vertical shake", function() fx.shake = true end,
      item = "4", look = "watch the log, not the screen",
      verdict = "STOMPED: the page flip rewrites dpystrt every frame" },
}

local function showcase_start()
    if showcase then showcase = nil; act_restore(); log("showcase cancelled"); return end
    act_restore()
    showcase = { step = 0, timer = 0 }
    log("=== SHOWCASE START (%d steps, %.1fs each = %.0fs total) - press + to cancel ===",
        #SHOWCASE, STEP_FRAMES / 60, #SHOWCASE * STEP_FRAMES / 60)
end

local function showcase_tick()
    if not showcase then return end
    if showcase.timer > 0 then
        showcase.timer = showcase.timer - 1
        local s = SHOWCASE[showcase.step]
        if s and s.cycle and frame % 12 == 0 then
            fx.const_ix = (fx.const_ix + 5) % 64
        end
        return
    end
    -- clear the previous step without tearing down the whole showcase
    fx.flipv, fx.silhou, fx.fillzero, fx.strobe = false, false, false, false
    fx.scale_ix, fx.shake = 1, false
    restore_objects()
    restore_display()

    showcase.step = showcase.step + 1
    local s = SHOWCASE[showcase.step]
    if not s then
        showcase = nil
        log("=== SHOWCASE DONE ===")
        act_restore()
        return
    end
    log("showcase %d/%d: %s", showcase.step, #SHOWCASE, s[1])
    s[2]()
    showcase.timer = STEP_FRAMES
end

-- ============================================================
-- ON-SCREEN READOUT
-- The whole point of a demo is that you can see what is being demonstrated
-- without reading a log, so every active effect names itself on screen.
-- ============================================================
local hud_on = true

local function hud_lines()
    local L = {}
    if showcase and showcase.step > 0 then
        local sc = SHOWCASE[showcase.step]
        if sc then
            L[#L + 1] = string.format("MK2 UNUSED HARDWARE  [%d/%d]",
                showcase.step, #SHOWCASE)
            L[#L + 1] = string.format("doc item %s: %s", sc.item or "?", sc[1])
            if sc.look then L[#L + 1] = "look for: " .. sc.look end
            if sc.verdict then L[#L + 1] = "** " .. sc.verdict end
        end
    else
        local on = {}
        if fx.flipv then on[#on + 1] = "flipv" end
        if fx.silhou then on[#on + 1] = "silhouette" end
        if fx.fillzero then on[#on + 1] = "fill-zero" end
        if fx.strobe then on[#on + 1] = "strobe" end
        if fx.scale_ix ~= 1 then on[#on + 1] = "scale:" .. SCALES[fx.scale_ix][1]:match("^%S+") end
        if fx.shake then on[#on + 1] = "dpystrt-shake" end
        if fx.tap_ix ~= 1 then on[#on + 1] = "dpytap" .. string.format("%+d", TAPS[fx.tap_ix]) end
        L[#L + 1] = "MK2 UNUSED HARDWARE EFFECTS"
        if #on == 0 then
            L[#L + 1] = "no effect active - numpad 2..9, + = tour"
        else
            L[#L + 1] = table.concat(on, "  |  ")
        end
    end
    L[#L + 1] = string.format("target: %s   oconst: %04x   oscale: %s",
        TARGETS[target_ix], const_word(fx.const_ix),
        fx.scale_ix == 1 and "1:1" or SCALES[fx.scale_ix][1]:match("^%S+"))
    return L
end

local function draw_hud()
    if not hud_on then return end
    local scr
    for _, s2 in pairs(manager.machine.screens) do scr = s2 break end
    if not scr then return end
    local lines = hud_lines()
    -- Bottom of the playfield: the top of the screen is the life bars, and
    -- covering them makes the recording harder to read, not easier.
    local h = 254
    local ok, sh = pcall(function() return scr.height end)
    if ok and sh and sh > 0 then h = sh end
    local y = h - (#lines * 9) - 3
    for i = 1, #lines do
        -- yellow on translucent black, same recipe as tools/kahn_spar.lua
        scr:draw_text(2, y, lines[i], 0xffffff00, 0xc0000000)
        y = y + 9
    end
end

local function act_hud()
    hud_on = not hud_on
    log("on-screen readout: %s", hud_on and "ON" or "OFF")
end

-- ============================================================
-- DIAGNOSTICS
-- ============================================================
local function act_dump()
    log("--- diagnostics ---")
    log("addressing=%s dpystrt=%s dpytap=%s",
        tostring(probe.addressing), tostring(probe.dpystrt), tostring(probe.dpytap))
    log("gstate=%d target=%s", r16(A.gstate), TARGETS[target_ix])
    local t = targets()
    log("%d target object%s", #t, #t == 1 and "" or "s")
    for i, o in ipairs(t) do
        if i > 6 then log("  ... %d more", #t - 6); break end
        local f2 = r16(o + OFLAGS2)
        local c = frame_control(o)
        log("  obj %08x flags=%04x%s pal=%04x const=%04x scale=%08x x=%d ctrl=%s%s",
            o, r16(o + OFLAGS),
            ((f2 & M_MULTIPART) ~= 0) and " [multipart]" or " [single]",
            r16(o + OPAL), r16(o + OCONST), r32(o + OSCALE),
            r16(o + OXPOS),
            c and string.format("%04x", c) or "n/a",
            (c and (c & DMACMP) ~= 0) and " [zero-compressed]" or "")
    end
    log("dpystrt=%04x dpytap=%04x", r16(R_DPYSTRT), r16(R_DPYTAP))
    log("---")
end

-- ============================================================
-- HOTKEYS  (numpad: MAME's own UI owns the F-keys)
-- ============================================================
local HOTKEYS = {
    { "KEYCODE_1_PAD",     act_target,     "cycle target (p1/p2/fighters/scene)" },
    { "KEYCODE_2_PAD",     act_flipv,      "vertical flip (m_flipv)" },
    { "KEYCODE_3_PAD",     act_silhouette, "constant-colour silhouette (m_connon)" },
    { "KEYCODE_4_PAD",     act_const_colour, "cycle constant colour index" },
    { "KEYCODE_5_PAD",     act_fillzero,   "fill transparent area (m_conzer)" },
    { "KEYCODE_6_PAD",     act_strobe,     "strobe - the MKZAP spear-block idiom" },
    { "KEYCODE_7_PAD",     act_scale,      "cycle oscale preset (non-square)" },
    { "KEYCODE_8_PAD",     act_shake,      "dpystrt vertical shake (experimental)" },
    { "KEYCODE_9_PAD",     act_tap,        "dpytap horizontal shift (experimental)" },
    { "KEYCODE_0_PAD",     act_restore,    "clear everything" },
    { "KEYCODE_MINUS_PAD", act_dump,       "dump diagnostics" },
    { "KEYCODE_PLUS_PAD",  showcase_start, "run the hands-off showcase" },
    { "KEYCODE_SLASH_PAD", act_hud,        "toggle the on-screen readout" },
}

local input_sys, debounce = nil, {}

local function hotkeys()
    for _, hk in ipairs(HOTKEYS) do
        local ok, code = pcall(function() return input_sys:code_from_token(hk[1]) end)
        if ok and code then
            local ok2, down = pcall(function() return input_sys:code_pressed(code) end)
            if ok2 then
                if down and not debounce[hk[1]] then hk[2]() end
                debounce[hk[1]] = down
            end
        end
    end
end

local function print_keymap()
    log("--- keys (numpad) ---")
    for _, hk in ipairs(HOTKEYS) do
        log("  %-18s %s", hk[1]:gsub("KEYCODE_", ""), hk[3])
    end
    log("---")
end

-- ============================================================
-- AUTO-CAPTURE  (set HWFX_AUTO=1)
-- Boots itself into a fight, runs the showcase, snapshots every step, exits.
-- This is how the script is regression-checked: the PNGs in MAME's snapshot
-- directory are the proof each effect actually reaches the screen.
-- ============================================================
local AUTO = (os.getenv("HWFX_AUTO") or "") ~= ""
local HOLD = (os.getenv("HWFX_HOLD") or "") ~= ""
local auto_state = { fields = {}, fighting = 0, psel = 0, p1c = 0, p2c = 0, snapped = {} }

local function port_list()
    local ok, p = pcall(function() return manager.machine.ioport.ports end)
    if ok and p then return p end
    ok, p = pcall(function() return manager.machine.ioports.ports end)
    if ok and p then return p end
    return {}
end

local function auto_cache_fields()
    local want = {
        ["UI Select"] = true, ["Coin 1"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
    }
    local found, all = {}, 0
    for _, port in pairs(port_list()) do
        for _, f in pairs(port.fields) do
            all = all + 1
            if want[f.name] then
                auto_state.fields[f.name] = f
                found[#found + 1] = f.name
            end
        end
    end
    table.sort(found)
    log("AUTO: %d ports fields seen, %d usable: %s",
        all, #found, #found > 0 and table.concat(found, " | ") or "NONE")
    if #found == 0 then
        log("AUTO: cannot drive the game - dumping every field name:")
        for tag, port in pairs(port_list()) do
            local names = {}
            for _, f in pairs(port.fields) do names[#names + 1] = f.name end
            table.sort(names)
            if #names > 0 then log("  [%s] %s", tostring(tag), table.concat(names, " | ")) end
        end
    end
end

local function auto_pressed(name)
    local a = auto_state
    if a.fighting > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and a.p1c > 0 then
        return frame >= a.p1c and frame < a.p1c + 45
    end
    if name == "P2 High Punch" and a.p2c > 0 then
        return frame >= a.p2c and frame < a.p2c + 45
    end
    return false
end

local function snap(label)
    local ok, scr = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not scr then return end
    local ok2 = pcall(function() scr:snapshot() end)
    log("SNAP %s (%s)", label, ok2 and "ok" or "failed")
end

local function auto_tick()
    if not AUTO then return end
    local a = auto_state
    local gs = r16(A.gstate)
    if gs ~= a.last_gs then
        log("AUTO: frame=%d gstate %s -> %d", frame, tostring(a.last_gs), gs)
        a.last_gs = gs
    end

    if gs == 4 and a.psel == 0 then a.psel = frame end
    if a.psel > 0 and a.p1c == 0 and frame - a.psel > 90 then a.p1c = frame end
    if a.psel > 0 and a.p2c == 0 and frame - a.psel > 150 then a.p2c = frame end

    if gs == GS_FIGHTING and a.fighting == 0 then
        a.fighting = frame
        log("AUTO: fight reached at frame %d - starting showcase in 2s", frame)
    end

    if a.fighting > 0 and frame - a.fighting == 120 and not showcase then
        showcase_start()
    end

    -- snapshot mid-way through each showcase step, once
    if showcase and showcase.step > 0 then
        local elapsed = STEP_FRAMES - showcase.timer
        if elapsed == math.floor(STEP_FRAMES * 0.6) and not a.snapped[showcase.step] then
            a.snapped[showcase.step] = true
            snap(string.format("%02d_%s", showcase.step,
                (SHOWCASE[showcase.step][1]):gsub("[^%w]+", "_")))
        end
    end

    if a.fighting > 0 and not showcase and frame - a.fighting > 200
       and a.snapped[#SHOWCASE] then
        if HOLD then
            if not a.held then
                a.held = true
                log("AUTO: tour finished - holding (HWFX_HOLD set); close MAME when done")
            end
        else
            log("AUTO: done")
            manager.machine:exit()
            return
        end
    end
    if frame % 600 == 0 then
        log("AUTO: heartbeat frame=%d gstate=%d p1obj=%08x", frame, gs, r32(A.p1_obj))
    end
    if frame > 6000 and not (HOLD or STEP_SECONDS) then
        log("AUTO: TIMEOUT at frame %d (gstate=%d)", frame, gs)
        manager.machine:exit()
        return
    end

    for name, f in pairs(a.fields) do
        if auto_pressed(name) then f:set_value(1) else f:clear_value() end
    end
end

-- ============================================================
-- FRAME
-- ============================================================
local started = false

local function on_frame()
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]
        if not space then return end
    end
    if not started then
        started = true
        input_sys = manager.machine.input
        log("=== hw_effects_demo.lua ===")
        log("companion to doc/UNUSED_HARDWARE_EFFECTS.md")
        probe_addressing()
        probe_display_regs()
        print_keymap()
        if not probe.addressing then
            log("ABORTING all memory pokes - fix the addressing first.")
        end
        if AUTO then
            auto_cache_fields()
            log("AUTO capture mode: booting to a fight, then running the showcase.")
        else
            log("Get into a fight, then press a numpad key. + runs the full tour.")
        end
    end
    if not probe.addressing then return end

    frame = frame + 1
    hotkeys()
    auto_tick()

    if r16(A.gstate) ~= GS_FIGHTING and not fx.shake and fx.tap_ix == 1 then
        -- outside a round there is no fighter object worth poking; let the
        -- game own its own display regs too.
        return
    end

    showcase_tick()
    apply_objects()
    apply_display()
end

emu.register_frame_done(on_frame)

-- Drawn from its own callback so the readout stays up even when on_frame
-- bails early (attract mode, between rounds).
if emu.register_frame_done then
    emu.register_frame_done(function() pcall(draw_hud) end)
elseif emu.add_machine_frame_notifier then
    emu.add_machine_frame_notifier(function() pcall(draw_hud) end)
end
