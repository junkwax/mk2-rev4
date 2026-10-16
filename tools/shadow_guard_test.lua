-- shadow_guard_test.lua
--
-- Deterministically reproduces the shadow_p1p2 line-count underflow that hung
-- the machine during Baraka's World View dive, and proves whether the build
-- under test survives it.
--
-- THE FAULT.  shad2 (MKDISP.ASM) walks the player's multipart chain with only
-- a zero mp_sag as a terminator, and takes the line count from mp_sizey/4.
-- shadow_p1p2 runs from the DMA INTERRUPT, so it can preempt ani2 (MKUTIL.ASM)
-- rebuilding that same p1_ram in place -- and ani2 writes each node's SAG
-- BEFORE its sizes.  A node caught in that window has a live SAG and a height
-- of 0, `dsjs b5' underflows to 0ffffffffh, and the CPU pins in shad5's "wait
-- for dma while busy" spin for ~4.29 billion scanlines.
--
-- Rather than wait on that race, this rig WRITES that exact state: a valid SAG
-- with mp_sizey = 0, appended to the live chain every frame.  A build without
-- the guard hangs within a frame or two of the first shadow pass.
--
-- Detection is the pinned PC, the same detector the heli rig uses: SHADORG is
-- ff8006f0..ff800ee0, and nothing else in the game lives there.
--
-- Addresses come out of src/mk2.map at load and are used RAW (no >>3) -- see
-- reference_mame_lua_bit_addresses.  .bss layout is identical either side of
-- the fix, so the same map serves both ROMs; the rig validates the chain it
-- finds before poking and says ADDRESS MISMATCH rather than lying.

local REPO = "C:/Users/you/Workplace/mk2-main"
local TAG  = os.getenv("MK2_SHADOW_TAG") or "run"
-- MODE height : live SAG + mp_sizey 0 appended to the chain (the real fault)
-- MODE cap    : chain with NO terminator, all heights valid (exercises SHAD_MAX)
-- MODE none   : observe only, and snapshot - shadows must still render
local MODE = os.getenv("MK2_SHADOW_MODE") or "height"
local LOG  = REPO .. "/tools/shadow_guard_test." .. TAG .. ".log"

local logfh = io.open(LOG, "w")
local raw_print = print
print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end
    local line = table.concat(p, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local SYM = {}
do
    local fh = assert(io.open(REPO .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_]+)") do
            if SYM[n] == nil then SYM[n] = tonumber(a, 16) end
        end
    end
    fh:close()
end
local function sym(n) return assert(SYM[n], "not in mk2.map: " .. n) end

local F_SHADOWS = sym("f_shadows")
local P1_OBJ    = sym("p1_obj")
local P1_RAM    = sym("p1_ram")
local GSTATE    = sym("gstate")

local MP_LEN, MP_SAG, MP_SIZEX, MP_SIZEY = 112, 0, 32, 48
local OFLAGS2, M_SHADOW = 0x160, 0x0010
local SHAD_LO, SHAD_HI  = 0xff8006f0, 0xff800ee0
local MAX_NODES = 11                       -- p1_ram is 32*40 bits = 11 nodes

local frame, space, maincpu = 0, nil, nil
local armed, node, seed_sag = false, nil, nil
local stuck, pokes, done = 0, 0, false
local sags, nsags, live = {}, 0, 0
local waited = 0

local function rd32(a) return space:read_u16(a) | (space:read_u16(a + 16) << 16) end
local function wr32(a, v)
    space:write_u16(a, v & 0xffff)
    space:write_u16(a + 16, (v >> 16) & 0xffff)
end

local function finish(verdict, why)
    if done then return end
    done = true
    print("")
    print("================ RESULT ================")
    print(string.format("verdict     : %s", verdict))
    print(string.format("why         : %s", why))
    print(string.format("frame       : %d", frame))
    print(string.format("pokes       : %d  (node index %s)", pokes, tostring(node)))
    print(string.format("distinct    : %d animation frames seen while poking", nsags))
    print(string.format("last PC     : %08x", live))
    print("========================================")
    manager.machine:exit()
end

local function tick()
    if done then return end
    frame = frame + 1
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        maincpu = cpu
        space = cpu.spaces["program"]
    end

    local ok, pc = pcall(function() return maincpu.state["PC"].value end)
    if ok and pc then live = pc end

    if not armed then
        waited = waited + 1
        local o1 = space:read_u32(P1_OBJ)
        if space:read_u16(F_SHADOWS) == 0 or (o1 >> 24) ~= 0x01 then
            if waited % 600 == 0 then
                print(string.format("[%5d] waiting for a fight: f_shadows=%d p1_obj=%08x gstate=%d",
                      frame, space:read_u16(F_SHADOWS), o1, space:read_u16(GSTATE)))
            end
            if frame > 9000 then finish("NO-VERDICT", "never reached a fight with shadows on") end
            return
        end
        if (space:read_u16(o1 + OFLAGS2) & M_SHADOW) == 0 then return end

        -- Validate we are really looking at a multipart chain before touching it.
        local s0 = rd32(P1_RAM + MP_SAG)
        local y0 = space:read_u16(P1_RAM + MP_SIZEY)
        local x0 = space:read_u16(P1_RAM + MP_SIZEX)
        if s0 == 0 or y0 < 8 or y0 > 250 or x0 < 4 or x0 > 300 then
            if frame > 9000 then
                finish("NO-VERDICT", string.format(
                    "p1_ram does not look like a chain (sag=%08x %dx%d) - ADDRESS MISMATCH", s0, x0, y0))
            end
            return
        end

        node = 0
        while node < MAX_NODES and rd32(P1_RAM + node * MP_LEN + MP_SAG) ~= 0 do
            node = node + 1
        end
        seed_sag = s0
        armed = true
        print(string.format("[%5d] armed: chain is %d pieces, node0 = sag %08x %dx%d",
              frame, node, s0, x0, y0))
        if MODE == "height" then
            print(string.format("[%5d] poking node %d with a LIVE sag and mp_sizey = 0 every frame",
                  frame, node))
        elseif MODE == "cap" then
            print(string.format("[%5d] filling nodes %d..%d - NO terminator, all heights legal",
                  frame, node, MAX_NODES - 1))
        else
            print(string.format("[%5d] control run: observing only, nothing is poked", frame))
        end
        return
    end

    if MODE == "height" then
        -- The torn node, rewritten every frame because ani2 keeps rebuilding over it.
        wr32(P1_RAM + node * MP_LEN + MP_SAG, seed_sag)
        space:write_u16(P1_RAM + node * MP_LEN + MP_SIZEX, 32)
        space:write_u16(P1_RAM + node * MP_LEN + MP_SIZEY, 0)
        wr32(P1_RAM + (node + 1) * MP_LEN + MP_SAG, 0)  -- keep the chain terminated:
                                                        --   tests the height guard,
                                                        --   not the SHAD_MAX cap.
    elseif MODE == "cap" then
        -- No terminator anywhere in the buffer, and every height legal, so the
        -- ONLY thing that can stop the walk is SHAD_MAX.
        for n = node, MAX_NODES - 1 do
            wr32(P1_RAM + n * MP_LEN + MP_SAG, seed_sag)
            space:write_u16(P1_RAM + n * MP_LEN + MP_SIZEX, 32)
            space:write_u16(P1_RAM + n * MP_LEN + MP_SIZEY, 32)
        end
    end
    pokes = pokes + 1
    local s = rd32(P1_RAM + MP_SAG)
    if s ~= 0 and not sags[s] then sags[s] = true; nsags = nsags + 1 end

    if live >= SHAD_LO and live <= SHAD_HI then
        stuck = stuck + 1
        if stuck >= 12 then
            finish("HANG", string.format(
                "PC pinned inside SHADORG (%08x) for %d consecutive frames", live, stuck))
        end
    else
        stuck = 0
    end

    if MODE == "none" and pokes == 300 then
        local scr = manager.machine.screens[":screen"]
        if scr then pcall(function() scr:snapshot() end) end
        print(string.format("[%5d] snapshot taken (no poking in this mode)", frame))
    end
    if pokes % 120 == 0 then
        print(string.format("[%5d] alive: %d pokes, %d distinct anim frames, PC %08x",
              frame, pokes, nsags, live))
    end

    if pokes >= 900 then
        if nsags < 3 then
            finish("NO-VERDICT", "game never animated while poking - it may be wedged elsewhere")
        else
            local what = (MODE == "height" and "a live-SAG/zero-height node")
                      or (MODE == "cap" and "an UNTERMINATED chain, all heights legal")
                      or "no poking at all (control run)"
            finish("SURVIVED", string.format(
                "%d frames of %s, game still animating", pokes, what))
        end
    end
end

emu.register_frame_done(tick)
print("[shadow_guard] loaded; map gives p1_ram=" .. string.format("%08x", P1_RAM))
