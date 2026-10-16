-- st_decap_lineup_test.lua
--
-- LINE-UP harness for Shang Tsung's Old-Shang blade decapitation
-- (do_st_decap / stdc_lineup, MKDEATH.ASM).  One victim per run.
--
-- It does not judge a screenshot.  tools/st_decap_lineup.py measures, off the
-- art, how far in front of Shang each body has to stand for the blade to be in
-- its neck, and writes tools/st_decap_lineup_expect.lua; this reads the LIVE
-- objects and asserts the same numbers:
--
--   WINDUP   until the cut frame he stands where he was, SWAYING (>= 2 dizzy
--            poses) - he must not move on any windup tick
--   ON CUE   he is moved on exactly the tick Shang's STLAUGHFAT13 first shows
--   SPACING  from that tick to well past the cut, his anchor is exactly d px in
--            front of Shang's (the way Shang faces) - on every tick
--   FACING   at the cut the two face each other
--   BLADE    at the cut, with the anchors where the game REALLY has them
--            (oypos, not the ochar_ground_offsets arithmetic the generator
--            used), the blade point sits `resid` px under the top of his
--            wound - within 1 px of what the art predicted
--   FRAMES   the cut is the picture that was measured: Shang on STLAUGHFAT13,
--            the victim on stage 1 of his decap legs
--
-- Reaches FINISH HIM the way st_decap_fatality_test.lua does (forced
-- winner_status + dizzy_dude) and then plays the REAL input: Back, Back,
-- Forward, Up + LP.
--
--   STL_VICTIM  victim ochar (default 11, Jax)
--   STL_SIDE    left | right - which side of the victim Shang stands (left)
--   STL_DIST    how far apart they are snapped before the input (72)
--   STL_WALL    1 = park the victim against the left wall with Shang too
--               close: his spot is past the wall, so Shang must give ground
--   STL_NEG     1 = cross the expectation (d + 9): the run must FAIL

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local function envi(n, d) local v = os.getenv(n); return (v and v ~= "" and tonumber(v)) or d end

local LOG_PATH = os.getenv("STL_LOG") or (ROOT .. "/tmp/st_decap_lineup/lineup.log")
local MAP_PATH = os.getenv("STL_MAP") or (ROOT .. "/src/mk2.map")
local VICTIM   = envi("STL_VICTIM", 11)
local SIDE     = os.getenv("STL_SIDE") or "left"
local DIST     = envi("STL_DIST", 72)
local WALL     = envi("STL_WALL", 0) == 1
local NEG      = envi("STL_NEG", 0) == 1
local STAGE_ID = envi("STL_STAGE", 5)       -- Armory: no stage-fatality route

local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local s = "[st-lineup] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s)
    if logfh then logfh:write(s, "\n"); logfh:flush() end
end

local EXPECT = dofile(ROOT .. "/tools/st_decap_lineup_expect.lua")
local E = EXPECT.victim[VICTIM]

local symbols = {}
do
    local fh = io.open(MAP_PATH, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local missing = {}
local function sym(n)
    if symbols[n] == nil then missing[#missing + 1] = n; return 0 end
    return symbols[n]
end
local A = {}
for _, n in ipairs({ "active", "gstate", "p1_state", "p2_state", "p1_char", "p2_char",
    "p1_obj", "p2_obj", "p1_proc", "p2_proc", "p1_bar", "p2_bar", "curback",
    "winner_status", "f_death", "objlst", "objlst2", "objlst3", "dizzy_dude", "dizzy",
    "left_edge", "right_edge", "f_freeze_timer" }) do A[n] = sym(n) end

local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, oflags = 0x0f0,
            osag = 0x100, oimg = 0x1a0, ochar = 0x1f0 }
local P = { next = 0x000, id = 0x020, wake = 0x0e0, action = 0x1f0, flags = 0x210 }
local GS_PSEL, GS_FIGHTING, PS_ACTIVE, FT_ST = 4, 2, 1, 6
local ACT_STUNNED, PID_HEAD, M_FLIPH = 0x0400, 0x0202, 0x0010
local LEFT_PAD = 0x3a

local cpu, space
local fields = {}
local frame, charsel_frame, fighting_frame, confirm_start = 0, 0, 0, 0
local last_gs = -1
local finish_forced, dizzy_forced, ready_frame, input_start = 0, false, 0, 0
local fatality_frame, cut_rel = 0, nil
local pre, before = nil, nil
local samples, bad_samples, first_bad = 0, 0, nil
local fat13_rel, move_rel, windup, early, vic_sags = nil, nil, 0, 0, {}
local cut = nil
local finished = false
local pending = {}

local function r16(a) return space:read_u16(a) end
local function s16(a) local v = space:read_u16(a); return v >= 0x8000 and v - 0x10000 or v end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

-- frame labels: Shang's cut pose and every body's decap legs, by SAG
local sag_labels = {}
local function load_labels(file, pat)
    local fh = io.open(ROOT .. "/src/" .. file, "r")
    if not fh then return end
    local cur
    for line in fh:lines() do
        local lab = line:match("^([%w_]+):")
        if lab then cur = lab:match(pat)
        elseif cur then
            local raw = line:match("%.long%s+([%x]+)H")
            if raw then sag_labels[tonumber(raw, 16) & 0x00ffffff] = cur; cur = nil end
        end
    end
    fh:close()
end
load_labels("STDECAP.TBL", "^(STLAUGHFAT%d+)$")
-- a module's decap art is not always in its first TBL (Baraka's is MKSA2,
-- Raiden's MKRD2); a missing file is skipped
for _, t in ipairs({ "MKHH", "MKLK", "MKJC", "MKSA", "MKFN", "MKST", "MKRD", "MKNJ", "MKJX",
                     "MKHH2", "MKLK2", "MKJC2", "MKSA2", "MKFN2", "MKST2", "MKRD2", "MKNJ2", "MKJX2" }) do
    load_labels(t .. ".TBL", "^(%u+DEADLEG%d+)")
    load_labels(t .. ".TBL", "^(%u+DECAPLEG%d+)")
    load_labels(t .. ".TBL", "^(%u+DEADTORSO%d+)")
    load_labels(t .. ".TBL", "^(%u+DECAPTORSO%d+)")
end

-- every piece SAG of a (multipart) object: the object's own, then its shape RAM
local function obj_labels(obj)
    local out = {}
    local function add(sag) local l = sag_labels[sag & 0x00ffffff]; if l then out[#out + 1] = l end end
    add(r32(obj + O.osag))
    local img = r32(obj + O.oimg)
    if img ~= 0 then add(r32(img)) end
    return out
end

local function screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    return ok and s or nil
end
local function snap(label) pending[#pending + 1] = label end

local function head_proc()
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 256 do
        if r16(p + P.id) == PID_HEAD then return p end
        p = r32(p + P.next); n = n + 1
    end
    return 0
end

local function state()
    local so, vo = r32(A.p1_obj), r32(A.p2_obj)
    if so == 0 or vo == 0 then return nil end
    local sf = (r16(so + O.oflags) & M_FLIPH) ~= 0
    local vf = (r16(vo + O.oflags) & M_FLIPH) ~= 0
    local sx, vx = s16(so + O.oxpos), s16(vo + O.oxpos)
    return { so = so, vo = vo, sx = sx, vx = vx, sy = s16(so + O.oypos), vy = s16(vo + O.oypos),
             sflip = sf, vflip = vf, fwd = (vx - sx) * (sf and -1 or 1) }
end

local function set_x(obj, x) w16(obj + O.oxpos, x); w32(obj + O.oxval, x << 16) end

local function place()
    local so, vo = r32(A.p1_obj), r32(A.p2_obj)
    local vx = s16(vo + O.oxpos)
    if WALL then
        vx = s16(A.left_edge) + LEFT_PAD + 6
        set_x(vo, vx)
    end
    local sx = (SIDE == "right") and (vx + DIST) or (vx - DIST)
    set_x(so, sx)
    log("placed shang_x=%d victim_x=%d side=%s dist=%d wall=%s", sx, vx, SIDE, DIST, tostring(WALL))
end

-- Back, Back, Forward, Up + LP.  LP lands one tick after Up or he is airborne.
local BACK = (SIDE == "right") and "P1 Right" or "P1 Left"
local FWD  = (SIDE == "right") and "P1 Left" or "P1 Right"
local COMBO = { { 0, 8, BACK }, { 12, 20, BACK }, { 24, 32, FWD }, { 36, 44, "P1 Up" }, { 37, 47, "P1 Low Punch" } }

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 220 and frame < 6000 and (frame % 80) < 20 end
        if name == "2 Players Start" then return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55 end
    end
    if charsel_frame > 0 and fighting_frame == 0 and confirm_start > 0 then
        if name == "P1 High Punch" then return frame >= confirm_start and frame < confirm_start + 40 end
        if name == "P2 High Punch" then return frame >= confirm_start + 80 and frame < confirm_start + 120 end
    end
    if input_start > 0 then
        local rel = frame - input_start
        for _, s in ipairs(COMBO) do
            if name == s[3] and rel >= s[1] and rel < s[2] then return true end
        end
    end
    return false
end

local function finish(verdict, why)
    if finished then return end
    finished = true
    log("%s victim=%d(%s) side=%s wall=%s neg=%s : %s", verdict, VICTIM, E and E.name or "?",
        SIDE, tostring(WALL), tostring(NEG), why)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function judge()
    local want_d = E.d + (NEG and 9 or 0)
    local why = {}
    if samples < 20 then why[#why + 1] = string.format("only %d spacing samples after the cut frame", samples) end
    local poses = 0
    for _ in pairs(vic_sags) do poses = poses + 1 end
    if windup < 60 then why[#why + 1] = string.format("windup only %d ticks", windup) end
    if early > 0 then why[#why + 1] = string.format("he moved before the cut frame on %d of %d windup ticks", early, windup) end
    if poses < 2 then why[#why + 1] = string.format("he was not swaying in the windup (%d dizzy frame)", poses) end
    local need_move = pre and pre.fwd ~= E.d
    if not fat13_rel then why[#why + 1] = "Shang never drew STLAUGHFAT13"
    elseif need_move and move_rel ~= fat13_rel then
        why[#why + 1] = string.format("lined up on tick %s, the cut frame is tick %d", tostring(move_rel), fat13_rel)
    end
    if bad_samples > 0 then
        why[#why + 1] = string.format("spacing off on %d of %d ticks (first: rel %d fwd %d, want %d)",
            bad_samples, samples, first_bad.rel, first_bad.fwd, want_d)
    end
    if not cut then
        why[#why + 1] = "the head never came off"
    else
        if cut.sflip == cut.vflip then why[#why + 1] = "they are not facing each other at the cut" end
        if not cut.shang_ok then why[#why + 1] = "Shang is not on STLAUGHFAT13 at the cut (" .. cut.shang_lab .. ")" end
        if not E.boss then
            if cut.vic_lab == "" then
                finish("NO VERDICT", "the rig cannot name the victim's frame at the cut - his decap TBL is not in its list"); return
            end
            if not cut.vic_ok then why[#why + 1] = "victim is not on decap stage 1 at the cut (" .. cut.vic_lab .. ")" end
            if math.abs(cut.resid - E.resid) > 1 then
                why[#why + 1] = string.format("blade %.1f px under the wound top, art predicted %.1f", cut.resid, E.resid)
            end
            if cut.resid < -1 or cut.resid > EXPECT.max_resid then
                why[#why + 1] = string.format("blade %.1f px off the wound top: outside -1..%d", cut.resid, EXPECT.max_resid)
            end
        end
    end
    if WALL and pre and pre.moved_me == 0 then
        why[#why + 1] = "wall trial: Shang never gave ground, so the clamp was not exercised"
    end
    if #why == 0 then
        finish("PASS", string.format("swaying %d ticks (%d frames) unmoved, lined up ON the cut frame (tick %s); d=%d on %d/%d ticks, resid=%.1f (art %.1f), moved him %+d me %+d",
            windup, poses, tostring(fat13_rel), want_d, samples - bad_samples, samples, cut.resid or 0, E.resid or 0, pre.moved_him, pre.moved_me))
    else
        finish("FAIL", table.concat(why, "; "))
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local want = { ["Coin 1"] = 1, ["2 Players Start"] = 1, ["P1 High Punch"] = 1, ["P2 High Punch"] = 1,
                       ["P1 Low Punch"] = 1, ["P1 Left"] = 1, ["P1 Right"] = 1, ["P1 Up"] = 1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        for n in pairs(want) do if not fields[n] then missing[#missing + 1] = "input:" .. n end end
        if #missing > 0 then finish("NO VERDICT", "missing " .. table.concat(missing, ", ") .. " (map " .. MAP_PATH .. ")"); return end
        if not E then finish("NO VERDICT", "no expectation for ochar " .. VICTIM); return end
        log("victim=%d (%s) d=%d side=%s dist=%d wall=%s neg=%s map=%s", VICTIM, E.name, E.d, SIDE, DIST,
            tostring(WALL), tostring(NEG), MAP_PATH)
    end
    if finished or not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gs then
        log("gstate frame=%d %d->%d", frame, last_gs, gs)
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gs = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, FT_ST); w16(A.p2_char, VICTIM); w16(A.curback, STAGE_ID)
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_ACTIVE)
        if charsel_frame > 0 and confirm_start == 0 and frame > charsel_frame + 90 then
            confirm_start = frame + 25
        end
    end

    -- FINISH HIM, forced mid-round as the fatality rig does
    if fighting_frame > 0 and fatality_frame == 0 and r16(A.f_death) == 0 then
        local so, vo = r32(A.p1_obj), r32(A.p2_obj)
        local rel = frame - fighting_frame
        if so ~= 0 and vo ~= 0 and r16(so + O.ochar) == FT_ST and r16(vo + O.ochar) == VICTIM
            and rel >= 90 and rel <= 720 then
            w16(A.winner_status, 3)
            w16(A.f_freeze_timer, 1)
            local p1, p2 = r32(A.p1_proc), r32(A.p2_proc)
            if p1 ~= 0 then w16(p1 + P.flags, r16(p1 + P.flags) & ~0x001c) end
            if p2 ~= 0 and not dizzy_forced then w32(p2 + P.wake, A.dizzy_dude); dizzy_forced = true end
            if finish_forced == 0 then finish_forced = frame; log("finish_him_forced frame=%d", frame) end
        end
    end
    if finish_forced > 0 and ready_frame == 0 then
        local p2 = r32(A.p2_proc)
        local wake = p2 ~= 0 and r32(p2 + P.wake) or 0
        if wake >= A.dizzy and wake < A.dizzy + 0x120 and r16(p2 + P.action) == ACT_STUNNED then
            ready_frame = frame
            input_start = frame + 30
            place()
        end
    end

    local fd = r16(A.f_death)
    if fatality_frame == 0 and input_start > 0 then
        if fd == 10 then
            -- the lineup runs on the fatality's own first tick, so "before" is
            -- the last frame f_death was still clear
            fatality_frame = frame
            local st = before or state()
            pre = { sx = st.sx, vx = st.vx, fwd = st.fwd, moved_him = 0, moved_me = 0 }
            log("fatality_started frame=%d; before it shang_x=%d victim_x=%d apart=%d (table wants %d)",
                frame, st.sx, st.vx, st.fwd, E.d)
            snap("start")
        elseif fd ~= 0 and fd ~= 0xffff then
            finish("NO VERDICT", "a different fatality started (f_death " .. fd .. ")"); return
        elseif frame - input_start > 300 then
            finish("NO VERDICT", "the fatality never started after the real input"); return
        else
            before = state()
        end
    end

    if fatality_frame > 0 then
        local rel = frame - fatality_frame
        local st = state()
        if not st then finish("NO VERDICT", "fighter objects went away mid-fatality"); return end
        -- COUNT THE TICKS: the frame Shang's cut pose first shows, and the
        -- tick the victim first leaves where he stood.  They must be one tick.
        local on13 = table.concat(obj_labels(st.so), "+"):find("STLAUGHFAT13", 1, true) ~= nil
        if on13 and not fat13_rel then
            fat13_rel = rel
            log("STLAUGHFAT13 first drawn rel=%d", rel)
        end
        if not move_rel and (st.vx ~= pre.vx or st.sx ~= pre.sx) then
            move_rel = rel
            pre.moved_him, pre.moved_me = st.vx - pre.vx, st.sx - pre.sx
            log("lined up rel=%d: shang_x=%d victim_x=%d apart=%d  (moved him %+d, me %+d)",
                rel, st.sx, st.vx, st.fwd, pre.moved_him, pre.moved_me)
            snap("lined_up")
        end
        if not fat13_rel then
            -- the windup: he stands where he was, swaying
            windup = windup + 1
            if st.fwd ~= pre.fwd then early = early + 1 end
            -- a multipart object's osag is a constant (02000000h); its pose is
            -- the first piece's SAG through oimg
            vic_sags[r32(r32(st.vo + O.oimg))] = true
        elseif not cut_rel or rel <= cut_rel + 20 then
            samples = samples + 1
            if st.fwd ~= E.d + (NEG and 9 or 0) then
                bad_samples = bad_samples + 1
                first_bad = first_bad or { rel = rel, fwd = st.fwd }
            end
        end
        if not cut_rel and head_proc() ~= 0 then
            cut_rel = rel
            local sl, vl = table.concat(obj_labels(st.so), "+"), table.concat(obj_labels(st.vo), "+")
            cut = { sflip = st.sflip, vflip = st.vflip, shang_lab = sl, vic_lab = vl,
                    shang_ok = sl:find("STLAUGHFAT13", 1, true) ~= nil,
                    vic_ok = vl:find("LEG1") ~= nil or vl:find("TORSO1") ~= nil, resid = 0 }
            if not E.boss then
                cut.resid = (st.sy + E.by) - (st.vy + E.top)
                -- where the blade point and the wound really are, in world x
                local dir = st.sflip and -1 or 1
                cut.blade_x = st.sx + dir * E.bx
                cut.wound_x = st.vx + (st.vflip and -1 or 1) * E.xc
            end
            log("CUT rel=%d shang=(%d,%d,%s) [%s] victim=(%d,%d,%s) [%s] apart=%d", rel, st.sx, st.sy,
                st.sflip and "L" or "R", sl, st.vx, st.vy, st.vflip and "L" or "R", vl, st.fwd)
            if not E.boss then
                log("BLADE world x=%d  WOUND world x=%d  blade under wound top by %.1f px (art predicted %.1f; rise live %d, art %d)",
                    cut.blade_x, cut.wound_x, cut.resid, E.resid, st.sy - st.vy, E.rise)
            end
            snap("cut")
        end
        if cut_rel and rel == cut_rel + 6 then snap("cut_plus6") end
        if cut_rel and rel >= cut_rel + 24 then judge(); return end
        if rel > 420 then judge(); return end
    end

    for name, f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end
    if fighting_frame == 0 and frame > 8000 then finish("NO VERDICT", "never reached a fight") end
    if fighting_frame > 0 and finish_forced == 0 and frame - fighting_frame > 900 then
        finish("NO VERDICT", "the requested fighters never appeared (p2 wanted ochar " .. VICTIM .. ")")
    end
    if frame > 14000 then finish("NO VERDICT", "global timeout") end
end)

emu.register_frame_done(function()
    if #pending == 0 then return end
    local s = screen()
    for _, label in ipairs(pending) do
        local ok = s and pcall(function() s:snapshot() end)
        log("SNAP %s frame=%d ok=%s", label, frame, tostring(ok))
    end
    pending = {}
end)
