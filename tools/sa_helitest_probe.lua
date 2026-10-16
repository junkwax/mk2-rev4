-- sa_helitest_probe.lua
-- Boots the test-mode ROM (P1 Baraka, P2 Jax human, Dead Pool), taps P1 Low
-- Punch once the fight is live, and logs Baraka's object every frame so the
-- World View dive lane (a_sa_helitest / do_sa_helitest) can be checked without
-- eyeballing it: which image record is on screen, where the object sits, which
-- flip bits are set, and whether he ever gets back to a normal action.

local LOG = "C:/Users/you/Workplace/mk2-main/tools/sa_helitest_probe.log"
local logfh = io.open(LOG, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- NOTE: these are BSS bit-addresses out of src/mk2.map and they MOVE
-- whenever a .bss line is added to or removed from src/RAM.ASM.
-- Refresh with: python sym_resolve.py --dump | grep <symbol>
local GSTATE  = 0x010ed800
local P1_OBJ  = 0x010ed850
local P2_OBJ  = 0x010ee420
local P1_CHAR = 0x010ed8b0
local WORLDTLX = 0x010ea440

local OBJ_OXPOS  = 0x090
local OBJ_OYPOS  = 0x0b0
local OBJ_OFLAGS = 0x0f0
local OBJ_OIMG   = 0x1a0
local OBJ_OSHAPE = 0x1d0
local OBJ_OCHAR  = 0x1f0

local M_FLIPH = 0x0010
local M_FLIPV = 0x0020

-- SAG -> pose, straight out of src/SAHELI.TBL and src/SAHELI2.TBL.  The lane
-- is the only thing in the ROM that draws these, so a SAG here is proof of
-- which row is live.
local POSE = {
    -- Stock multipart wrappers: the probe reads the FIRST strip's SAG out
    -- of oimg, so these are the *A records from MKSA/MKSA2/MKST.TBL.
    -- They move whenever those libraries are rebuilt - regenerate rather
    -- than trusting them after an art change.
    [0x0111c14a] = "UGVICTORY1",
    [0x01122c98] = "UGVICTORY2",
    -- SAHELI sidecar blade/body strips (SPIN?A is the first piece, so it
    -- is what the probe reads out of oimg).  a_sa_windup draws these;
    -- a_sa_helitest and a_sa_spin still draw the UGSPIN wrappers below,
    -- so BOTH sets have to be here or half the move logs as unknown.
    [0x03c50000] = "SAHSPIN1",
    [0x03c573f6] = "SAHSPIN2",
    [0x03c5cb1e] = "SAHSPIN3",
    [0x03c60e34] = "SAHSPIN4",
    [0x03c67378] = "SAHSPIN5",
    [0x011921ba] = "UGSPIN1",
    [0x0119aeea] = "UGSPIN2",
    [0x011a0dd4] = "UGSPIN3",
    [0x011a5216] = "UGSPIN4",
    [0x011ad09e] = "UGSPIN5",
    [0x00e8f8c8] = "UGHIKICK3",
    [0x00eb4fc6] = "UGROUNDKIK2",
    [0x01072b02] = "UGFLIPPED2",
    [0x01000000] = "UGKNOCKDOWN2",
    [0x00ffaa16] = "UGKNOCKDOWN1",
    [0x0102ca9a] = "UGGETUP4",
    -- Landing run of the BARAKADOWNSMALL dive.  A pose the table does not
    -- know is not logged at all, so it drops out of the y range too - which
    -- is why an unnamed entry reads as if the lane never got there.
    [0x00ef5608]  = "UGSWEEPKICK7",
    [0x010056ca]  = "UGKNOCKDOWN3",
    -- Earlier landing runs, kept so an older ROM still reads.  Without these the last four
    -- entries log as unknown SAGs and the tail of the move reads as a gap.
    [0x00eba7fe] = "UGROUNDKIK3",
    [0x00f38056] = "UGJUMPFLIP1",
    [0x00d5d48a] = "UGSTANCE1",
    [0x00f16f80] = "UGJUMP1",
    [0x00f1da62] = "UGJUMP2",   -- windup entry 1; without this the four
                                --   ticks it holds log as an unknown SAG
                                --   and read as a gap in the lane
    [0x00da3230] = "UGTURN1",
    [0x00d63af8] = "UGSTANCE2",
    [0x017205c4] = "STSTANCE1",
    [0x0194f490] = "STSTUMBLE1",
    [0x01954d54] = "STSTUMBLE2",
    [0x0195a3d8] = "STSTUMBLE3",
    [0x0195edac] = "STSTUMBLE4",
    [0x0196357e] = "STSTUMBLE5",
    [0x01998484] = "STKNOCKDOWN1",
    [0x0199e3ba] = "STKNOCKDOWN2",
    [0x019a400c] = "STKNOCKDOWN3",
    [0x019aa118] = "STKNOCKDOWN4",
    [0x019aef74] = "STKNOCKDOWN5",
    [0x019b2f14] = "STKNOCKDOWN6",
    [0x019b76f2] = "STKNOCKDOWN7",
}

local frame       = 0
local space       = nil
local fields      = {}
local fight_frame = 0
local fired       = 0
local lp_down     = 0
local snap_due    = 0
local snaps       = 0
local pctrace     = {}
local maincpu     = nil
local seen        = {}       -- pose -> tick count
local order       = {}       -- pose sequence, collapsed
local minY, maxY  = nil, nil
local startX, startXp2 = nil, nil
local done        = false

local function s16(v)
    v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if f.name == "P1 Up"       then fields.up = f end
            if f.name == "P1 Low Kick" then fields.lk = f end
            if f.name == "P1 Block"    then fields.bl = f end
        end
    end
    print("[probe] P1 Up input:       " .. (fields.up and "ok" or "MISSING"))
    print("[probe] P1 Low Kick input: " .. (fields.lk and "ok" or "MISSING"))
    print("[probe] P1 Block input:    " .. (fields.bl and "ok" or "MISSING"))
end

local function tick()
    frame = frame + 1
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        maincpu = cpu
        space = cpu.spaces["program"]
        cache_fields()
        return
    end

    -- Ring buffer of the CPU PC. If emulation stops dead (a spin with
    -- interrupts off, e.g. MK2's ermac trap) the last entries say where.
    if fired > 0 then
        local ok, pc = pcall(function()
            local st = maincpu.state["PC"] or maincpu.state["pc"]
            return st and st.value or nil
        end)
        if not ok then pc = nil end
        if pc then
            pctrace[#pctrace + 1] = string.format("%d:%08x", frame, pc)
            if #pctrace > 24 then table.remove(pctrace, 1) end
            local fh = io.open("C:/Users/you/Workplace/mk2-main/tools/pctrace.txt", "w")
            if fh then fh:write(table.concat(pctrace, " | ")); fh:close() end
        end
    end
    -- unconditional snapshots: if the lane never runs, these show WHY
    if frame == 400 or frame == 1000 or frame == 1800 then
        local scr = manager.machine.screens[":screen"]
        if scr then pcall(function() scr:snapshot() end) end
        print(string.format("[probe] DIAG SNAP frame=%d", frame))
    end
    local gs   = space:read_u16(GSTATE)
    local obj  = space:read_u32(P1_OBJ)
    local obj2 = space:read_u32(P2_OBJ)
    if gs ~= 2 or obj == 0 then
        if frame % 120 == 0 then
            print(string.format("[probe] frame=%d waiting gs=%d obj=0x%08x", frame, gs, obj))
        end
        return
    end

    if fight_frame == 0 then
        fight_frame = frame
        print(string.format("[probe] frame=%d FIGHT LIVE p1char=%d",
            frame, space:read_u16(P1_CHAR)))
    end

    -- BLOCK IS HELD THROUGH THE WHOLE INPUT, and the move does not fire
    -- without it.  do_sa_helitest is gated ground-only (SAHT_GROUND_BAND in
    -- MOVES.ASM refuses it more than 40px above p_ganiy), and a bare Up,Up
    -- IS a jump: up_vel -10.0 px/tick puts him ~92px up by the time LK lands
    -- on this cadence, so the gate correctly throws it away.  Holding Block
    -- suppresses the jump, the taps stay on the floor, and the move fires.
    -- A run that logs only UGJUMP2 -> UGJUMP1 -> UGSTANCE2 with y pinned at
    -- p_ganiy is this input being refused, not the lane being broken.
    --
    -- Up, Up + LK.  Each step is held 4 frames and released for 4 so the
    -- combo detector sees two distinct taps rather than one long hold.
    local since = frame - fight_frame
    if fields.up and fields.lk and fired == 0 and since >= 90 then
        if lp_down == 0 then
            lp_down  = frame
            startX   = s16(space:read_u16(obj + OBJ_OXPOS))
            startXp2 = obj2 ~= 0 and s16(space:read_u16(obj2 + OBJ_OXPOS)) or 0
            print(string.format("[probe] frame=%d INPUT START  p1x=%d p2x=%d",
                frame, startX, startXp2))
        end
        local t = frame - lp_down
        -- Block covers the two Up taps only, and is RELEASED before LK:
        -- held through the kick it eats the button and nothing fires.
        if fields.bl and t >= 0 and t < 14 then fields.bl:set_value(1) end
        if fields.bl and t == 14 then fields.bl:clear_value() end
        if     t == 0  then fields.up:set_value(1)
        elseif t == 4  then fields.up:clear_value()
        elseif t == 8  then fields.up:set_value(1)
        elseif t == 12 then fields.up:clear_value()
        elseif t == 16 then fields.lk:set_value(1)
        elseif t == 20 then
            fields.lk:clear_value()
            print(string.format("[probe] frame=%d Block+Up,Up, release, LK sent", frame))
            fired = frame
        end
    end

    if fired > 0 and not done then
        local x     = s16(space:read_u16(obj + OBJ_OXPOS))
        local y     = s16(space:read_u16(obj + OBJ_OYPOS))
        local fl    = space:read_u16(obj + OBJ_OFLAGS)
        local img   = space:read_u32(obj + OBJ_OIMG)
        local shape = space:read_u32(obj + OBJ_OSHAPE)
        local sag   = img ~= 0 and space:read_u32(img) or 0
        local pose  = POSE[sag]

        if pose then
            seen[pose] = (seen[pose] or 0) + 1
            if order[#order] ~= pose then
                order[#order+1] = pose
            end
            -- At sleep 1 a pose lasts ONE frame, so "snapshot N frames into a
            -- pose" never lands.  Just grab every frame the lane is on screen.
            if snaps < 200 and frame % 4 == 0 then
                snaps = snaps + 1
                local scr = manager.machine.screens[":screen"]
                if scr then pcall(function() scr:snapshot() end) end
                print(string.format("[probe] SNAP %03d %s", snaps, pose))
            end
            if minY == nil or y < minY then minY = y end
            if maxY == nil or y > maxY then maxY = y end
            -- watch the VICTIM too: his reaction runs on his own process, so
            -- his shape and his knockback are independent evidence.
            local p2s, p2x, p2y = 0, 0, 0
            if obj2 ~= 0 then
                p2s = space:read_u32(obj2 + OBJ_OSHAPE)
                p2x = s16(space:read_u16(obj2 + OBJ_OXPOS))
                p2y = s16(space:read_u16(obj2 + OBJ_OYPOS))
            end
            local wtlx = s16(space:read_u16(WORLDTLX + 0x10))
            local x2   = obj2 ~= 0 and s16(space:read_u16(obj2 + OBJ_OXPOS)) or 0
            print(string.format(
                "[probe] f=%-5d %-12s x=%-5d y=%-5d fliph=%d flipv=%d " ..
                "gap=%-4d | p2 shape=0x%08x x=%-5d y=%-4d",
                frame, pose, x, y,
                (fl & M_FLIPH) ~= 0 and 1 or 0,
                (fl & M_FLIPV) ~= 0 and 1 or 0,
                x - x2, p2s, p2x, p2y))
        end

        if frame - fired > 420 then
            done = true
            print("")
            print("[probe] ===== RESULT =====")
            print("[probe] pose order: " .. table.concat(order, " -> "))
            local total = 0
            for _, p in ipairs(order) do total = total + (seen[p] or 0) end
            print(string.format("[probe] distinct poses drawn: %d   frames in lane: %d",
                #order, total))
            for _, p in ipairs(order) do
                print(string.format("[probe]   %-12s %d frames", p, seen[p]))
            end
            print(string.format("[probe] object y range: %s..%s", tostring(minY), tostring(maxY)))
            local x  = s16(space:read_u16(obj + OBJ_OXPOS))
            local x2 = obj2 ~= 0 and s16(space:read_u16(obj2 + OBJ_OXPOS)) or 0
            print(string.format("[probe] start: p1x=%d p2x=%d  (p1 was %s of p2)",
                startX, startXp2, startX < startXp2 and "LEFT" or "RIGHT"))
            print(string.format("[probe] end:   p1x=%d p2x=%d  (p1 is %s of p2)",
                x, x2, x < x2 and "LEFT" or "RIGHT"))
            print("[probe] ==================")
            manager.machine:exit()
        end
    end
end

emu.register_frame_done(tick)
print("[probe] loaded")
