--- raiden_pose_bolt_test.lua - does the ambient crackle land ON Raiden in
--- poses other than the stance?
---
--- The RN*BOLT art (RADBOLT1.IMG) is painted against his STANDING silhouette:
--- each group crawls over one fixed band of it, measured as an offset below
--- his oypos anchor - RN1BOLT the hat at +16..+25, RN6BOLT the shins at
--- +98..+125, and so on.  Standing he draws +5..+146, so the authored
--- anipoints are exact.  An angle-jump curl draws 50 px tall instead of 141
--- and a deep duck 76, so an unfitted bolt fires into open air below his feet
--- or above his head.  That is why `lightning` (MKGUYS.ASM) used to refuse to
--- flash at all unless he was standing still.
---
--- lgt_fit_bolt now measures the body he is actually drawing and maps the
--- standing band onto it.  This harness proves that, by measurement rather
--- than by eye:
---
---   * it drives Raiden through jumps, angle jumps, ducks and walks,
---   * every frame it walks HIS multipart RAM for the box he really draws,
---     and each ambient bolt object's multipart RAM for where its pieces
---     really sit,
---   * and it reports, per pose class, how far any bolt piece's CENTRE falls
---     outside his body box.
---
--- The centre is the thing the fit actually places: a 60 px piece on a 50 px
--- curl must overhang, but its centre belongs on him.  Unfitted, an RN6BOLT
--- centre sits ~111 px below the anchor against a body that ends at +50.
---
--- PASS needs flashes seen while AIRBORNE and while DUCKING (the states the
--- old code refused outright), and every sampled bolt centre inside the body
--- box within RDPOSE_TOL.
---
--- Env: RDPOSE_LOG, RDPOSE_FRAMES (default 3000), RDPOSE_TOL (default 8)

local ROOT = "C:/Users/you/Workplace/mk2-main"

local LOG_PATH = os.getenv("RDPOSE_LOG") or (ROOT .. "/tools/raiden_pose_bolt_test.log")
local RUN_FRAMES = tonumber(os.getenv("RDPOSE_FRAMES") or "") or 3000
local TOL = tonumber(os.getenv("RDPOSE_TOL") or "") or 8
-- Control mode: same fight, same pose loop, but P1 is Jax - so no `lightning`
-- process exists at all.  It exists to attribute peak_overload: the number is
-- meaningless without a run of the same shape that carries no bolts.
local CONTROL = (os.getenv("RDPOSE_CONTROL") or "") ~= ""
-- Which behaviour to assert.  "stance" is MK1's rule (lgtstance 1): he
-- crackles only in act_stance with oyvel 0, so bolts belong in the idle
-- stretch and NOWHERE else.  "everywhere" is lgtstance 0.
local MODE = os.getenv("RDPOSE_MODE") or "stance"

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
    print("[rdpose] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end

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
local function sym(n)
    if symbols[n] == nil then log("WARN missing symbol %s", n) end
    return symbols[n] or 0
end

local A = {
    gstate = sym("gstate"), winner_status = sym("winner_status"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p1_proc = sym("p1_proc"),
    prcstr = sym("prcstr"),
    curback = sym("curback"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
    -- latched from power-on, so one read at the end covers the whole run
    peak_overload = sym("peak_overload"), dmaq_late = sym("dmaq_late"),
    dmaq_lost = sym("dmaq_lost"),
}
-- object fields (DISPEQU.ASM), as BIT offsets
local O = { next = 0x000, oyvel = 0x060, oxpos = 0x090, oypos = 0x0b0,
            osag = 0x100, oimg = 0x1a0 }
-- one multipart shape record: sag(32) sizex(16) sizey(16) ctrl(16) anix(16) aniy(16)
local M = { sag = 0, sizex = 32, sizey = 48, ctrl = 64, anix = 80, aniy = 96, stride = 112 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_RAIDEN, FT_JAX = 7, 11
local STAGE_ID = 5
local FULL_HP = 0xa1

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm_start = 0, 0, 0
local finished = false

-- Lua space:read_* take the RAW bit address and read_u16 aligns DOWN to a
-- 16-bit boundary.  A shape record is 112 bits = 7 words, so odd records are
-- 16-bit but NOT 32-bit aligned - read the sag as two words, never read_u32.
local function r16(a) return space:read_u16(a) end
local function s16(a) local v = space:read_u16(a); return v >= 0x8000 and v - 0x10000 or v end
local function r32(a) return space:read_u32(a) end
local function rec32(a) return r16(a) | (r16(a + 16) << 16) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local ambient_sags = {}
do
    local n, current = 0, nil
    local fh = io.open(ROOT .. "/src/MKBOLTS.TBL", "r")
    if fh then
        for line in fh:lines() do
            local label = line:match("^(RN%dBOLT[%w]+):")
            if label then current = label end
            if current then
                local raw = line:match("%.long%s+0?([%x]+)[Hh]")
                if raw then
                    ambient_sags[tonumber(raw, 16) & 0x00ffffff] = current
                    current = nil; n = n + 1
                end
            end
        end
        fh:close()
    end
    log("loaded %d ambient RN*BOLT SAGs", n)
end

-- Walk an object's multipart RAM and return the box its pieces really draw,
-- plus the per-piece centres.  A piece's top is oypos - aniy (MKDISP dclipl
-- does subxy on the packed y:x anipoint), so a LARGER aniy lifts the art.
local function shape_of(obj)
    local img = r32(obj + O.oimg)
    if img == 0 then return nil end
    local oy = s16(obj + O.oypos)
    local top, bot, centres, n = 1e9, -1e9, {}, 0
    local a = img
    while n < 13 do
        if rec32(a + M.sag) == 0 then break end
        local h = r16(a + M.sizey)
        local ay = s16(a + M.aniy)
        local t = oy - ay
        local b = t + h
        if t < top then top = t end
        if b > bot then bot = b end
        centres[#centres + 1] = (t + b) // 2
        a = a + M.stride
        n = n + 1
    end
    if n == 0 then return nil end
    return { top = top, bot = bot, h = bot - top, centres = centres, pieces = n }
end

local function walk(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if list ~= 0 then
            local obj, guard, seen = r32(list), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then break end
                seen[obj] = true
                fn(obj)
                obj = r32(obj + O.next)
                guard = guard + 1
            end
        end
    end
end

local function ambient_objects()
    local out = {}
    walk(function(obj)
        local sag1 = r32(obj + O.osag) & 0x00ffffff
        local img = r32(obj + O.oimg)
        local sag2 = img ~= 0 and (rec32(img) & 0x00ffffff) or 0
        local label = ambient_sags[sag1] or ambient_sags[sag2]
        if label then out[#out + 1] = { obj = obj, label = label } end
    end)
    return out
end

local ACT_STANCE = 0x0303
local P_ACTION = 0x100 + 0xf0      -- pdata + p_action offset (MAINEQU.ASM)

-- Process pool walk, to see what the lightning proc is REALLY holding.
-- prcstr is nproc*prcsiz; fields from MAINEQU.ASM (pdata 100h, prcsiz 6f0h).
local PRCSIZ, NPROC = 0x6f0, 168
local P_BUTPORT, P_OTHERGUY, P_SLAVE = 0x120, 0x140, 0x190
local dbg_done = 0
local function dump_lightning()
    if A.prcstr == 0 then log("DBG no prcstr symbol"); return end
    local p1p, p1o = r32(A.p1_proc), r32(A.p1_obj)
    log("DBG p1_proc=%08x p1_obj=%08x p_action(via p1_proc)=%04x",
        p1p, p1o, p1p ~= 0 and r16(p1p + P_ACTION) or 0)
    local found = 0
    for i = 0, NPROC - 1 do
        local base = A.prcstr + i * PRCSIZ
        local bp = r32(base + P_BUTPORT)
        local og = r32(base + P_OTHERGUY)
        if og == p1o and p1o ~= 0 then
            found = found + 1
            log("DBG proc#%d @%08x p_butport=%08x (p1_proc? %s) p_otherguy=%08x p_slave=%08x"
                .. " action_via_butport=%s",
                i, base, bp, tostring(bp == p1p), og, r32(base + P_SLAVE),
                (bp ~= 0 and bp > 0x1000000) and string.format("%04x", r16(bp + P_ACTION)) or "n/a")
        end
    end
    log("DBG procs holding p1_obj in p_otherguy: %d", found)
end

-- pose classes, by what he is actually drawing
local CLASSES = { "stand", "walk", "duck", "air" }
local stats = {}
for _, c in ipairs(CLASSES) do
    stats[c] = { frames = 0, bolt_frames = 0, pieces = 0, worst = 0, worst_at = "",
                 minh = 1e9, maxh = 0 }
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local snap_index = 0
local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s", snap_index, frame, label, tostring(ok))
    snap_index = snap_index + 1
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("---- cost (latched from power-on) ----")
    log("peak_overload=%d dmaq_late=%d dmaq_lost=%d",
        r16(A.peak_overload), r16(A.dmaq_late), r16(A.dmaq_lost))
    log("---- per-pose results ----")
    for _, c in ipairs(CLASSES) do
        local s = stats[c]
        log("%-6s frames=%-5d withbolt=%-5d pieces=%-5d bodyh=%d..%d worstcentreout=%d %s",
            c, s.frames, s.bolt_frames, s.pieces,
            s.minh == 1e9 and -1 or s.minh, s.maxh, s.worst, s.worst_at)
    end
    log("%s reason=%s", ok and "PASS" or "FAIL", reason)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                     ["P1 High Punch"] = true, ["P2 High Punch"] = true,
                     ["P1 Up"] = true, ["P1 Down"] = true,
                     ["P1 Left"] = true, ["P1 Right"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %s MISSING", name); return false end
    end
    return true
end

-- A 220-frame loop through every pose class the old code refused.
-- 520-frame cycle: 300 frames of GENUINE IDLE (so act_stance actually holds
-- long enough for a flash to start and finish - the wait is 16-47 ticks and
-- the flash ~30 more), then a 220-frame pose loop.
local IDLE_LEN, CYCLE = 300, 520
local function cyc() return (frame - fighting_frame) % CYCLE end
local function idle_now() return cyc() < IDLE_LEN end
local function drive(name)
    if fighting_frame == 0 or finished then return false end
    local c = cyc()
    if c < IDLE_LEN then return false end
    local d = c - IDLE_LEN
    if name == "P1 Up" then
        -- straight jump, then two angle jumps
        return (d >= 20 and d < 26) or (d >= 100 and d < 106) or (d >= 150 and d < 156)
    elseif name == "P1 Right" then
        return (d >= 95 and d < 120) or (d >= 175 and d < 200)
    elseif name == "P1 Left" then
        return (d >= 145 and d < 170)
    elseif name == "P1 Down" then
        return d >= 40 and d < 90
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("pose-fit probe; frames=%d tol=%d mode=%s control=%s", RUN_FRAMES, TOL, MODE, tostring(CONTROL))
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d", frame)
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, CONTROL and FT_JAX or FT_RAIDEN)
        w16(A.p2_char, FT_JAX)
        w16(A.curback, STAGE_ID)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    else
        -- Pin BOTH bars: a decided round takes the process and ends the run
        -- long before the pose loop has covered everything.
        w16(A.p1_bar, FULL_HP)
        w16(A.p2_bar, FULL_HP)

        local rd = r32(A.p1_obj)
        if rd ~= 0 then
            local body = shape_of(rd)
            local bolts = ambient_objects()
            if body then
                local yvel = r32(rd + O.oyvel)
                local proc = A.p1_proc ~= 0 and r32(A.p1_proc) or 0
                local act = proc ~= 0 and r16(proc + P_ACTION) or -1
                local cls
                if yvel ~= 0 then cls = "air"
                elseif act == ACT_STANCE then cls = "stand"
                elseif body.h < 125 then cls = "duck"
                else cls = "walk" end

                if dbg_done < 3 and idle_now() and (frame - fighting_frame) % 520 == 200 then
                    dbg_done = dbg_done + 1
                    dump_lightning()
                end
                local s = stats[cls]
                s.frames = s.frames + 1
                if body.h < s.minh then s.minh = body.h end
                if body.h > s.maxh then s.maxh = body.h end

                if #bolts > 0 then
                    s.bolt_frames = s.bolt_frames + 1
                    for _, b in ipairs(bolts) do
                        local bs = shape_of(b.obj)
                        if bs then
                            for _, c in ipairs(bs.centres) do
                                s.pieces = s.pieces + 1
                                local out = 0
                                if c < body.top then out = body.top - c end
                                if c > body.bot then out = c - body.bot end
                                if out > s.worst then
                                    s.worst = out
                                    s.worst_at = string.format(
                                        "(%s centre=%d body=%d..%d h=%d f=%d)",
                                        b.label, c, body.top, body.bot, body.h, frame)
                                end
                            end
                        end
                    end
                    if frame % 97 == 0 then
                        log("f=%-5d %-5s bodyh=%-4d body=%d..%d bolts=%d first=%s",
                            frame, cls, body.h, body.top, body.bot, #bolts, bolts[1].label)
                    end
                    if snap_index < 6 and (cls == "air" or cls == "duck")
                        and frame % 53 == 0 then
                        snap(string.format("%s_h%d", cls, body.h))
                    end
                end
            end
        end
    end

    if frame > RUN_FRAMES then
        local air, duck = stats.air, stats.duck
        local worst, where = 0, ""
        for _, c in ipairs(CLASSES) do
            if stats[c].worst > worst then worst = stats[c].worst; where = stats[c].worst_at end
        end
        local stand = stats.stand
        if CONTROL then
            finish(true, "control_run_cost_only")
        elseif MODE == "stance" then
            -- MK1's rule: crackle in act_stance, and nowhere else at all.
            if stand.bolt_frames == 0 then
                finish(false, "no_ambient_bolt_in_the_stance")
            elseif air.bolt_frames > 0 then
                finish(false, "bolt_while_airborne_" .. air.bolt_frames .. "_frames")
            elseif duck.bolt_frames > 0 then
                finish(false, "bolt_while_ducking_" .. duck.bolt_frames .. "_frames")
            elseif stats.walk.bolt_frames > 0 then
                finish(false, "bolt_while_walking_" .. stats.walk.bolt_frames .. "_frames")
            elseif worst > TOL then
                finish(false, string.format("bolt_centre_%dpx_off_body_%s", worst, where))
            else
                finish(true, string.format("stance_only: stand=%d air=0 duck=0 walk=0",
                    stand.bolt_frames))
            end
        elseif air.bolt_frames == 0 then
            finish(false, "no_ambient_bolt_while_airborne")
        elseif duck.bolt_frames == 0 then
            finish(false, "no_ambient_bolt_while_ducking")
        elseif worst > TOL then
            finish(false, string.format("bolt_centre_%dpx_off_body_%s", worst, where))
        else
            finish(true, string.format("air=%d duck=%d frames_with_bolts, worst_centre_out=%d",
                air.bolt_frames, duck.bolt_frames, worst))
        end
        return
    end
    if frame > 6000 and fighting_frame == 0 then
        finish(false, "never_reached_fight")
        return
    end

    for name, field in pairs(fields) do
        local v = 0
        if fighting_frame == 0 then
            if charsel_frame == 0 then
                if name == "Coin 1" or name == "Coin 2" then
                    v = (frame >= 220 and frame < 6000 and (frame % 80) < 20) and 1 or 0
                elseif name == "2 Players Start" then
                    v = (frame >= 260 and frame < 6000
                         and (frame % 80) >= 30 and (frame % 80) < 55) and 1 or 0
                end
            elseif p1_confirm_start > 0 then
                if name == "P1 High Punch" then
                    v = (frame >= p1_confirm_start and frame < p1_confirm_start + 40) and 1 or 0
                elseif name == "P2 High Punch" then
                    v = (frame >= p1_confirm_start + 80
                         and frame < p1_confirm_start + 120) and 1 or 0
                end
            end
        else
            v = drive(name) and 1 or 0
        end
        field:set_value(v)
    end
end)
