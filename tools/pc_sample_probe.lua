-- pc_sample_probe.lua
--
-- "The game stopped reaching a fight" says nothing about WHERE it stopped.
-- This samples the program counter on a timer and prints it, so a wedge can be
-- resolved to a symbol instead of guessed at:
--
--     python sym_resolve.py <pc>
--
-- A trap lands in the lockup handlers and crash_probe.lua already covers that.
-- This one exists for the other kind: an ordinary infinite loop, which runs at
-- 100% emulated speed and looks exactly like "nothing happened".
--
-- Also prints gstate each sample, because a game sitting happily in attract
-- mode and a game wedged before the select screen are indistinguishable from
-- the outside and are completely different bugs.
--
-- Env: PCS_LOG, PCS_EVERY (frames between samples), PCS_FRAMES (stop after)

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG = os.getenv("PCS_LOG") or (ROOT .. "/tools/pc_sample_probe.log")
local EVERY = tonumber(os.getenv("PCS_EVERY") or "120")
local STOP = tonumber(os.getenv("PCS_FRAMES") or "9000")

local fh = io.open(LOG, "w")
local function log(f, ...)
    local l = "[pcs] " .. string.format(f, ...)
    print(l); if fh then fh:write(l, "\n"); fh:flush() end
end

local sym = {}
do
    local m = io.open(ROOT .. "/src/MK2.MAP", "r")
    if m then
        for line in m:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
        end
        m:close()
    end
end
local function S(n) return sym[n] or 0 end

-- nearest preceding symbol, so a raw PC reads as "name+offset"
local names = {}
for n, a in pairs(sym) do names[#names + 1] = { n = n, a = a } end
table.sort(names, function(x, y) return x.a < y.a end)
local function near(pc)
    local best
    for _, e in ipairs(names) do
        if e.a <= pc then best = e else break end
    end
    if not best then return "?" end
    return string.format("%s+0x%x", best.n, pc - best.a)
end

local A = { gstate = S("gstate"), p1_char = S("p1_char"), map_start = S("map_start"),
            dyn_map = S("dyn_map"), illegal = S("illegal_opcode"),
            debug1 = S("debug1") }

local frame, space, cpu, done, trapped = 0, nil, nil, false, false
local fields = {}
local seen = {}

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cpu = manager.machine.devices[":maincpu"]
        local want = { ["Coin 1"] = true, ["1 Player Start"] = true }
        for _, p in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("sampling PC every %d frames; dyn_map=0x%x map_start=0x%x", EVERY, A.dyn_map, A.map_start)
    end
    -- coin + start, same pattern every harness here uses
    for n, f in pairs(fields) do
        local on = false
        if n == "Coin 1" then on = frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if n == "1 Player Start" then on = frame >= 1000 and frame < 1080 end
        f:set_value(on and 1 or 0)
    end
    if not space or done then return end

    -- The moment the PC lands in a trap handler, the faulting address is
    -- sitting on the system stack. Dump it ONCE, with the registers, so the
    -- culprit can be resolved instead of guessed at:
    --     python sym_resolve.py --stack <w0> <w1> ...
    if not trapped and A.illegal ~= 0 then
        local pc = cpu.state["PC"].value
        if pc >= A.illegal and pc < A.illegal + 0x200 then
            trapped = true
            log("TRAP at frame %d: PC=0x%08x is inside illegal_opcode", frame, pc)
            if A.debug1 ~= 0 then
                log("  build_dynamic_map stage breadcrumb (@debug1) = %d", space:read_u16(A.debug1))
            end
            if A.dyn_map ~= 0 then
                local out = {}
                for i = 0, 15 do
                    out[#out + 1] = string.format("%d", space:read_u16(A.dyn_map + i * 16))
                end
                log("  dyn_map = [%s]", table.concat(out, " "))
            end
            local sp = cpu.state["SP"].value
            -- BIT addressing: every address in these probes comes from
            -- MK2.MAP and is fed to space:read_* unmodified, so consecutive
            -- 32-bit stack words are 32 APART, not 4. Dividing by 8 here read
            -- an empty patch of RAM and printed eight convincing zeroes.
            log("  SP=0x%08x  top of system stack:", sp)
            for i = 0, 7 do
                local w = space:read_u32(sp + i * 32)
                log("    sp+%-2d = 0x%08x", i, w)
            end
            local r = {}
            for i = 0, 14 do
                r[#r + 1] = string.format("a%d=0x%08x", i, cpu.state["A" .. i].value)
            end
            log("  %s", table.concat(r, " "))
        end
    end

    if (frame % EVERY) == 0 then
        local pc = cpu.state["PC"].value
        local gs = space:read_u16(A.gstate)
        local ms = space:read_u32(A.map_start)
        log("f=%-6d gstate=%d PC=0x%08x  %-34s map_start=0x%x", frame, gs, pc, near(pc // 8), ms)
        seen[#seen + 1] = pc
    end
    if frame >= STOP then
        done = true
        -- If every sample sat in the same place, say so outright: that is the
        -- difference between "wedged" and "running but idle".
        local same = true
        for _, p in ipairs(seen) do if p ~= seen[1] then same = false break end end
        log(same and "WEDGED: every sample at the same PC" or "PC moved between samples")
        if fh then fh:close(); fh = nil end
        manager.machine:exit()
    end
end)
emu.register_stop(function() if fh then fh:close(); fh = nil end end)
