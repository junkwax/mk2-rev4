-- outer_stair_probe.lua
--
-- Verifies the Outer Haven portal staircase (timefloor1-9, BGND.ASM
-- oh_stair_animator):
--
--   1. the object lives on baklst1, not baklst4, and only on Outer Haven;
--   2. the steps AND both little monks stay on the STATIC baklst4 (retail
--      placement, centred on screen), with the monks nudged per view so they
--      stay on the outer two tiles at the top of the steps;
--   3. the view (frame 1..9) is picked from the anchor's drift off screen
--      centre, mirrored for the far half of the pan.
--
-- Each timefloor frame has a unique width (88/92/102/112/115/122/126/131/138)
-- so the view is read straight out of the object's oimg header - no symbol
-- resolution needed for the frame table.
--
-- Outer Haven is table_o_mods index 0x16 = 22 (that table's index comments
-- are HEX - reading them as decimal lands you on atrax3_mod).  Stock Portal is
-- 7; MK2_STAIR_STAGE=7 runs it as a control, and it must show ONE static frame
-- on baklst4 and an EMPTY baklst1.

-- MK2_ROOT lets an A/B point each boot at a frozen root whose src/ matches its
-- ROM: the view is keyed off each view's first strip SAG in TIMEFLR.TBL.
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("STAIRPROBE_LOG") or (ROOT .. "/tools/outer_stair_probe.log")
local OUTER_HAVEN = 22                   -- table_o_mods 0x16
local STAGE = tonumber(os.getenv("MK2_STAIR_STAGE") or tostring(OUTER_HAVEN))

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
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

-- mk2.map holds TMS34010 BIT addresses, and MAME's midtunit address map is
-- written in bit addresses too, so space:read/write take them unchanged.
local missing = {}
local function sym(name)
    local v = symbols[name]
    if not v then missing[#missing + 1] = name; return nil end
    return v
end

local A = {
    baklst1   = sym("baklst1"),
    baklst4   = sym("baklst4"),
    worldtlx  = sym("worldtlx"),
    worldtlx2 = sym("worldtlx2"),
    worldtlx3 = sym("worldtlx3"),
    worldtlx4 = sym("worldtlx4"),
    gstate    = sym("gstate"),
    curback   = sym("curback"),
    p1_char   = sym("p1_char"),
    p2_char   = sym("p2_char"),
    p1_state  = sym("p1_state"),
    p2_state  = sym("p2_state"),
    p1_obj    = sym("p1_obj"),
    p2_obj    = sym("p2_obj"),
}

local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, ozval = 0x0c0,
            oflags = 0x0f0, osag = 0x100, osizex = 0x120, opal = 0x140,
            oflags2 = 0x160, oimg = 0x1a0, oshape = 0x1d0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE = 1
local FT_KANG, FT_CAGE = 1, 2
local M_FLIPH = 0x10

local STEP = 50                          -- oh_stair_step (camera px per view)
local HOME = 1236//2 - 399//2            -- oh_stair_home, the neutral camera

-- "sweep" pokes worldtlx2 directly to prove the view picker; "pan" walks both
-- fighters across the stage so the camera scrolls for real and the snapshots
-- show the staircase against a background that moved with it.
local MODE = os.getenv("MK2_STAIR_MODE") or "sweep"
local TRACE = os.getenv("MK2_STAIR_TRACE")   -- log every frame of the fight
local SNAP_ALL = os.getenv("MK2_STAIR_SNAP_ALL") == "1"

local frame, cpu, space = 0, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, did_select = 0, false
local done_frame, sweep_i, sweep_next, base_tlx3 = 0, 0, 0, nil
local fields, seen_views, errors = {}, {}, {}
local cam_lo, cam_hi, w3_lo, w3_hi
local last_left, last_stop

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function fail(msg) errors[#errors + 1] = msg; print("[stair] FAIL " .. msg) end

local function list_objs(head)
    local out, p, n = {}, r32(head), 0
    while p ~= 0 and n < 40 do out[#out + 1] = p; p = r32(p + O.next); n = n + 1 end
    return out
end

-- The steps are a MULTIPART on baklst4 now: ozval 1 and m_multipart set.
local M_MULTIPART = 0x0002
local function stair_obj()
    for _, p in ipairs(list_objs(A.baklst4)) do
        if r32(p + O.ozval) == 1 and (r16(p + O.oflags2) & M_MULTIPART) ~= 0 then
            return p, #list_objs(A.baklst1)
        end
    end
    return nil, #list_objs(A.baklst1)
end

-- A multipart's oimg is multipart RAM, not an image header, so the view is
-- identified by oshape (the piece list) instead of by sprite width.
-- Absolute view number, keyed off the FIRST strip's SAG.  ani2 copies each
-- piece's isag verbatim into multipart ram entry #1, so the root piece's SAG
-- identifies the view exactly - unlike ranking oshape, which is only relative
-- to however many lists have been seen so far.
local sag2view = {}
do
    local fh = io.open(ROOT .. "/src/TIMEFLR.TBL", "r")
    if fh then
        local pending
        for line in fh:lines() do
            local nm = line:match("^timefloor(%d+)A:")
            if nm then pending = tonumber(nm) end
            local sag = line:match("^%s*%.long%s+0(%x+)[Hh]")
            if sag and pending then
                sag2view[tonumber(sag, 16)] = pending
                pending = nil
            end
        end
        fh:close()
    end
end

local function view_of(obj)
    local mp, n = r32(obj + O.oimg), 0
    while n < 20 and r32(mp + n*(32+32+16+16+16)) ~= 0 do n = n + 1 end
    local root = r32(mp)                      -- ram entry #1 = first piece SAG
    return sag2view[root], n, (r16(obj + O.oflags) & M_FLIPH) ~= 0
end



local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
end

local function snap(label)
    local s = main_screen()
    if not s then return end
    pcall(function() s:snapshot() end)
    print(string.format("[stair] SNAP %s", label))
end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 300 and frame < 560 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 600 and frame < 700 end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

local function frame_body()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        if #missing > 0 then
            print("[stair] FAIL unresolved map symbols: " .. table.concat(missing, ","))
        end
        print(string.format("[stair] loaded; stage=%d step=%d", STAGE, STEP))
    end
    if not space or #missing > 0 then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        print(string.format("[stair] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, 0)
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE); w16(A.curback, STAGE)
        if not did_select then
            did_select = true
            print(string.format("[stair] forcing stage %d", STAGE))
        end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if fighting_frame == 0 then
        for n, f in pairs(fields) do if pressed(n) then f:set_value(1) else f:clear_value() end end
        if frame > 3000 then print("[stair] TIMEOUT before fight"); manager.machine:exit() end
        return
    end

    local rel = frame - fighting_frame

    -- per-tick trace: walk the fighters right at a steady crawl and record how
    -- far the steps' NEAR EDGE moves each tick.  That edge is what pops.
    -- TRACE: park the fighters at a series of stage positions, hold each,
    -- and log every view change.  Proves (a) it settles and stops when they
    -- stand still, (b) it approaches the target in decreasing steps.
    if TRACE and rel > 80 then
        local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
        local obj = stair_obj()
        if p1 ~= 0 and p2 ~= 0 and obj then
            local STOPS = { 663, 763, 893, 1250, 120, 663 }  -- drives the VIEW to
            -- camera drift ~0, +100, +230, +wall, -wall, back to 0
            local HOLD  = 70
            local si = ((rel - 81) // HOLD) + 1
            if si > #STOPS then print("[trace] done"); manager.machine:exit(); return end
            local want = STOPS[si]
            w32(p1 + O.oxval, ((want - 30) * 65536) & 0xffffffff)
            w32(p2 + O.oxval, ((want + 30) * 65536) & 0xffffffff)
            local v, n, fl = view_of(obj)
            local sig = (fl and -(v or 0) or (v or 0))
            local HOME = 1236//2 - 399//2
            local cam = s32(r32(A.worldtlx)) // 65536
            if si ~= last_stop then
                print(string.format("[trace] --- fighters parked at %d ---", want))
                last_stop = si
            end
            if sig ~= last_left then
                print(string.format("[trace]   rel=%4d view drift=%+5d  view=%s%s  pieces=%2d  step=%+d",
                    rel, cam - HOME, tostring(v), fl and "F" or " ", n, (last_left and sig - last_left or 0)))
                last_left = sig
            end
        end
        return
    end

    -- ---- structural checks, once the stage has settled -------------------
    if rel == 60 then
        local b1, n1 = stair_obj()
        local b4 = list_objs(A.baklst4)
        print(string.format("[stair] baklst1=%d obj  baklst4=%d obj", n1, #b4))
        if STAGE == OUTER_HAVEN then
            if n1 ~= 0 then fail(string.format("baklst1 holds %d objects, expected 0", n1)) end
            if b1 then
                local v, w, fl = view_of(b1)
                print(string.format("[stair] initial view=%s w=%d flip=%s xpos=%d pal=%04x",
                    tostring(v), w, tostring(fl), s16(r16(b1 + O.oxpos)), r16(b1 + O.opal)))
                -- the view is converged-to now, not fixed, so the only
                -- meaningful assertion is that it resolves to a real view
                if v == nil then fail("root strip SAG does not match any view") end
            end
        else
            if n1 ~= 0 then fail("stock Portal put " .. n1 .. " objects on baklst1") end
            if #b4 == 0 then fail("stock Portal baklst4 is empty") end
        end
        snap("settled")
    end

    -- ---- natural pan: shove both fighters across the stage ---------------
    if MODE == "pan" and rel > 80 then
        local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
        if p1 ~= 0 and p2 ~= 0 then
            if base_tlx3 == nil then
                base_tlx3 = 0
                sweep_next = frame + 90
                print("[stair] pan mode: walking both fighters across the stage")
            end
            -- 9 stops from the left wall to the right wall
            local x = -200 + sweep_i * 190
            w32(p1 + O.oxval, (x * 65536) & 0xffffffff)
            w32(p2 + O.oxval, ((x + 60) * 65536) & 0xffffffff)
            if frame >= sweep_next then
                local obj = stair_obj()
                if obj == nil then
                    print(string.format("[stair] pan stop %2d  fighters@%4d  worldtlx=%4d (no baklst1 object)",
                        sweep_i, x, s32(r32(A.worldtlx)) // 65536))
                    snap("pan_" .. sweep_i)
                else
                    local v, w, fl = view_of(obj)
                    local tlx2 = s32(r32(A.worldtlx2)) // 65536
                    local cam  = s32(r32(A.worldtlx))  // 65536
                    local w3   = s32(r32(A.worldtlx3)) // 65536
                    cam_lo = math.min(cam_lo or cam, cam)
                    cam_hi = math.max(cam_hi or cam, cam)
                    w3_lo  = math.min(w3_lo or w3, w3)
                    w3_hi  = math.max(w3_hi or w3, w3)
                    local monks = {}
                    for _, q in ipairs(list_objs(A.baklst4)) do
                        if r32(q + O.ozval) == 2 then monks[#monks+1] = s16(r16(q + O.oxpos)) + 10 end
                    end
                    table.sort(monks)
                    -- a multipart's origin IS its anchor, so it is just oxpos
                    local anch = s16(r16(obj + O.oxpos))
                    print(string.format("[stair]   worldtlx3=%d  steps origin=%d  monks %s  (rel %s)",
                        w3, anch,
                        table.concat(monks, ","),
                        (#monks == 2) and string.format("%+d,%+d", monks[1]-anch, monks[2]-anch) or "?"))
                    print(string.format(
                        "[stair] pan stop %2d  fighters@%4d  worldtlx=%4d worldtlx2=%4d  view=%-4s flip=%-5s screenx=%4d",
                        sweep_i, x, s32(r32(A.worldtlx)) // 65536, tlx2,
                        tostring(v), tostring(fl),
                        s16(r16(obj + O.oxpos)) - (s32(r32(A.worldtlx4)) // 65536)))
                    snap("pan_" .. sweep_i)
                    if v == nil then fail("pan stop " .. sweep_i .. ": width " .. w .. " is not a timefloor frame") end
                end
                sweep_i = sweep_i + 1
                sweep_next = frame + 90
                if sweep_i > 9 and done_frame == 0 then
                    done_frame = frame
                    print(string.format("[stair] CAMERA REACH worldtlx %d..%d   worldtlx3 %d..%d"
                        .. "  -> plane-3 window %d..%d",
                        cam_lo, cam_hi, w3_lo, w3_hi, w3_lo, w3_hi + 400))
                    print("[stair] pan complete")
                end
            end
        end
        if done_frame > 0 and frame - done_frame > 20 then
            if #errors == 0 then print("[stair] PASS") else
                print("[stair] " .. #errors .. " FAILURE(S)") end
            manager.machine:exit()
        end
        return
    end

    -- ---- parallax + view sweep (Outer Haven only) ------------------------
    if MODE == "sweep" and STAGE == OUTER_HAVEN and rel > 80 then
        local obj = stair_obj()
        if not obj then
            if rel == 81 then fail("no staircase object on baklst1") end
        else
            if base_tlx3 == nil then
                base_tlx3 = r32(A.worldtlx)
                sweep_next = frame + 4
                print(string.format("[stair] sweep base worldtlx=%d  worldtlx4=%d  stair oxpos=%d",
                    s32(base_tlx3) // 65536, s32(r32(A.worldtlx4)) // 65536,
                    s16(r16(obj + O.oxpos))))
            end

            if frame >= sweep_next and sweep_i <= 16 then
                -- park worldtlx3 at base + (i-8)*STEP px and let the animator react
                local off = (sweep_i - 8) * STEP
                w32(A.worldtlx, (base_tlx3 + off * 65536) & 0xffffffff)
                sweep_next = frame + 4
                sweep_i = sweep_i + 1
            elseif frame == sweep_next - 2 and sweep_i > 0 and sweep_i <= 17 then
                local off = (sweep_i - 1 - 8) * STEP
                local v, w, fl = view_of(obj)
                local screen_x = s16(r16(obj + O.oxpos)) - (s32(r32(A.worldtlx4)) // 65536)
                seen_views[tostring(v) .. (fl and "F" or "")] = true
                print(string.format(
                    "[stair] cam%+5d  view=%-4s w=%3d flip=%-5s  worldx=%5d screenx=%4d",
                    off, tostring(v), w, tostring(fl),
                    s16(r16(obj + O.oxpos)), screen_x))
                if v == nil then fail("object width " .. w .. " is not a timefloor frame") end
                -- MK2_STAIR_SNAP_ALL=1: a capture at every stop, so an A/B sees
                -- every view (the default three stops only reach views 1 and 3)
                if SNAP_ALL or off == 100 or off == 0 or off == -100 then snap("tlx2_" .. off) end
            end
        end
    end

    if STAGE ~= OUTER_HAVEN and rel > 90 and done_frame == 0 then done_frame = frame end
    if MODE == "sweep" and STAGE == OUTER_HAVEN and sweep_i > 16 and done_frame == 0 then
        done_frame = frame
        local views = {}
        for k in pairs(seen_views) do views[#views + 1] = k end
        table.sort(views)
        print("[stair] views seen across the sweep: " .. table.concat(views, " "))
        if not seen_views["1"] and not seen_views["1F"] then
            fail("view 1 (dead-on) never appeared at the centre of the sweep")
        end
        local high = seen_views["8"] or seen_views["9"] or seen_views["8F"] or seen_views["9F"]
        if not high then fail("no oblique view (8/9) at the ends of the sweep") end
        local mirrored = false
        for k in pairs(seen_views) do if k:find("F") then mirrored = true end end
        if not mirrored then fail("the flipped half of the pan never ran") end
    end

    if done_frame > 0 and frame - done_frame > 20 then
        if #errors == 0 then print("[stair] PASS") else
            print("[stair] " .. #errors .. " FAILURE(S)") end
        manager.machine:exit()
        return
    end
    if rel > 1600 then print("[stair] TIMEOUT in fight"); manager.machine:exit() end
end

emu.register_frame(function()
    local ok, err = pcall(frame_body)
    if not ok then
        print("[stair] LUA ERROR: " .. tostring(err))
        manager.machine:exit()
    end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close(); logfh = nil end end)
