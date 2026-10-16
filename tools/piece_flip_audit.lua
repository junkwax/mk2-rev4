-- piece_flip_audit.lua - does every multipart piece carry its object's flip?
--
-- Since the mirrored-alias work (doc/graphics_opportunities/FLIPREUSE_PROTOTYPE.md)
-- a piece's flip comes ONLY from its own control word: ani2 builds it as
-- object flip XOR the header's, and dclipl no longer ORs the object's flip
-- back in.  Stock ORed it, which hid any code that flips an object's oflags
-- and draws before ani2 re-lays the pieces.  On the new ROM such code shows a
-- piece facing the old way.  This finds it: every frame, every multipart
-- object on every list from baklst8 to last_objlst, every piece - does the
-- piece's flip equal the object's?  Only objlst/objlst2 are walked: that is
-- where fighters and their projectiles (Kitana's fan) live, and walking every
-- background block list each frame took four parallel boots past 700 s.
-- (No alias header appears in these
-- scenarios, so equal is the rule.)
--
--   PF_MODE=kitana   1P game, CPU Kitana (her fans turn in flight: a drone
--                    spends a hold budget), P1 idle with both bars pinned
--   PF_MODE=attract  no input at all: the attract loop's demo fights
--
-- env: PF_MODE, PF_FRAMES, PF_LOG, MK2_ROOT (map dir)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("PF_MODE") or "kitana"
local FRAMES = tonumber(os.getenv("PF_FRAMES") or "6000")
local LOG = os.getenv("PF_LOG") or (ROOT .. "/tools/piece_flip_audit.log")
-- PF_LISTS=drawn walks exactly the lists the live @dlists table names - what
-- the display walker (disp2..disp4, MKDISP.ASM) draws this frame.  That is the
-- real gate: PF_LISTS=all also walks stale private heads (a stage zeroes its own
-- only when it builds), whose chains run through freed and reused objects - it
-- found a live player "on" THE TOWER's twr_bwall_lst during attract.
-- PF_LISTS=all walks EVERY display list head from baklst8 to last_objlst (stage
-- and attract art lives there too, and dclipl draws it the same way), sampled
-- every PF_EVERY frames to stay affordable - the mismatches found that way run
-- for 8..635 frames, so sampling cannot miss them.  PF_LISTS=obj (default)
-- walks objlst/objlst2 every frame.
local LISTS = os.getenv("PF_LISTS") or "obj"
local EVERY = tonumber(os.getenv("PF_EVERY") or (LISTS == "all" and "4" or "1"))
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[pf] " .. string.format(fmt, ...)
    logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    objlst = sym("objlst"), objlst2 = symbols["objlst2"],
    lists_lo = sym("baklst8"), lists_hi = sym("last_objlst"),
    dlists = symbols["dlists"], strip_layer = symbols["strip_layer"],
    f_freeze_timer = symbols["f_freeze_timer"],
}
local OFLAGS, OFLAGS2, OIMG, OID, OCHAR = 0x0f0, 0x160, 0x1a0, 0x1c0, 0x1f0
local M_MULTIPART, M_INVISO = 0x02, 0x20
local MP_LEN, MP_CONTROL = 112, 64
local FT_KITANA, FT_CAGE, MAX_HP = 4, 2, 0xa1
local GS_PSEL, GS_FIGHTING = 4, 2

local frame, space, fields = 0, nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm = 0
local checked_pieces, checked_frames = 0, 0
local seen, mism, run_now, run_max, vis = {}, {}, {}, {}, {}
local fan_flip_changes, last_fan_flip = 0, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true, ["P1 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if MODE ~= "kitana" or fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    return false
end

local function audit()
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    local mismatched_this_frame, visible_this_frame = {}, {}
    local heads = { A.objlst, A.objlst2 or A.objlst }
    if LISTS == "all" then
        heads = {}
        local h = A.lists_lo
        while h < A.lists_hi do heads[#heads + 1] = h; h = h + 32 end
    elseif LISTS == "drawn" then
        -- walk @dlists the way disp2 does: 0 ends it, -2 is the shadow marker,
        -- -1 is followed by a routine (strip_layer carries two inline longs),
        -- anything else is a list head followed by its worldtlx word
        heads = {}
        local t = A.dlists and r32(A.dlists) or 0
        local guard = 0
        while t ~= 0 and guard < 64 do
            guard = guard + 1
            local e = r32(t)
            if e == 0 then break
            elseif e == 0xfffffffe then t = t + 32
            elseif e == 0xffffffff then
                local routine = r32(t + 32)
                t = t + 64
                if A.strip_layer and routine == A.strip_layer then
                    heads[#heads + 1] = r32(t)      -- the banded list is drawn too
                    t = t + 64
                end
            else
                heads[#heads + 1] = e
                t = t + 64
            end
        end
    end
    for _, head in ipairs(heads) do
        local o, n = r32(head), 0
        while o ~= 0 and n < 400 do
            n = n + 1
            local fl2 = r32(o + OFLAGS2)
            if fl2 & M_MULTIPART ~= 0 and fl2 & M_INVISO == 0 then
                local ram = r32(o + OIMG)
                local oflip = (r16(o + OFLAGS) >> 4) & 3
                local key = string.format("ochar=%d oid=%04x%s list=%08x", r16(o + OCHAR), r16(o + OID),
                                          (o == p1 or o == p2) and " player" or "", head)
                seen[key] = (seen[key] or 0) + 1
                if r16(o + OCHAR) == FT_KITANA and o ~= p1 and o ~= p2 then
                    if last_fan_flip[o] ~= nil and last_fan_flip[o] ~= oflip then fan_flip_changes = fan_flip_changes + 1 end
                    last_fan_flip[o] = oflip
                end
                if ram ~= 0 then
                    local p, k = ram, 0
                    while k < 13 and r32(p) ~= 0 do
                        checked_pieces = checked_pieces + 1
                        local ctrl = r16(p + MP_CONTROL)
                        local pflip = (ctrl >> 4) & 3
                        -- stock drew (object | piece); the new dclipl draws the piece
                        -- alone.  They differ only where the OBJECT has a flip bit the
                        -- piece lacks - a "visible" mismatch.  A piece with extra flip
                        -- bits draws the same both ways - "harmless".
                        if (oflip & ~pflip) & 3 ~= 0 then visible_this_frame[o] = true end
                        if pflip ~= oflip and not mismatched_this_frame[o] then
                            -- identify it: the piece's SAG maps back to a table label
                            mismatched_this_frame[o] = string.format("%s oflags=%04x piece=%d sag=%08x ctrl=%04x oshape=%08x",
                                key, r16(o + OFLAGS), k, r32(p), ctrl, r32(o + 0x1d0))
                        end
                        p = p + MP_LEN; k = k + 1
                    end
                end
            end
            o = r32(o)
        end
    end
    for o, detail in pairs(mismatched_this_frame) do
        local key = detail:match("^(ochar=%d+ oid=%x+[%a ]* list=%x+)")
        mism[key] = (mism[key] or 0) + 1
        run_now[o] = (run_now[o] or 0) + 1
        if run_now[o] > (run_max[key] or 0) then run_max[key] = run_now[o] end
        if visible_this_frame[o] then
            vis[key] = (vis[key] or 0) + 1
            if vis[key] <= 6 then log("VISIBLE frame=%d %s", frame, detail) end
        elseif (mism[key] or 0) <= 3 then
            log("HARMLESS frame=%d %s", frame, detail)
        end
    end
    for o, _ in pairs(run_now) do
        if not mismatched_this_frame[o] then run_now[o] = nil end
    end
    checked_frames = checked_frames + 1
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("mode=%s frames=%d lists=%s every=%d objlst=%08x objlst2=%s", MODE, FRAMES, LISTS, EVERY, A.objlst,
            A.objlst2 and string.format("%08x", A.objlst2) or "none")
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame; log("FIGHT frame=%d", frame) end
        last_gstate = gs
    end
    if MODE == "kitana" then
        if charsel_frame > 0 and fighting_frame == 0 then
            w16(A.p1_char, FT_CAGE); w16(A.p2_char, FT_KITANA)
            if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        end
        if fighting_frame > 0 then
            if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
            w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
        end
    end

    if frame > 60 and frame % EVERY == 0 then audit() end

    local done = (MODE == "kitana" and fighting_frame > 0 and frame - fighting_frame >= FRAMES)
              or (MODE == "attract" and frame >= FRAMES)
              or (MODE == "kitana" and fighting_frame == 0 and frame > 9000)
    if done then
        for key, n in pairs(seen) do log("SEEN %s frames=%d", key, n) end
        local total, vtotal = 0, 0
        for key, n in pairs(mism) do
            total = total + n
            vtotal = vtotal + (vis[key] or 0)
            log("MISMATCHED %s frames=%d visible=%d longest_run=%d", key, n, vis[key] or 0, run_max[key] or 0)
        end
        log("RESULT mode=%s fight=%d frames=%d pieces_checked=%d mismatch_frames=%d visible_frames=%d fan_flip_changes=%d",
            MODE, fighting_frame > 0 and 1 or 0, checked_frames, checked_pieces, total, vtotal, fan_flip_changes)
        logfh:close()
        manager.machine:exit()
        return
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:set_value(0) end
    end
end)
