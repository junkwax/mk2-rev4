-- wolf_boot_probe.lua - does the Wolf build (rom/wolf/umk3.zip) boot?
-- Logs PC / gstate / tick every 60 frames, snapshots on a schedule, and can
-- insert a coin and press start.  Driven by tools/run_wolf_boot_probe.ps1.
-- Env: WB_LOG (log path), WB_GSTATE / WB_TICK (raw bit addresses from the
-- WOLF map), WB_FRAMES (run length), WB_COIN (1 = two coins + 1P start at 1500).
local LOG = os.getenv("WB_LOG")
local GSTATE = tonumber(os.getenv("WB_GSTATE") or "0", 16)
local TICK = tonumber(os.getenv("WB_TICK") or "0", 16)
local FRAMES = tonumber(os.getenv("WB_FRAMES") or "3600")
local COIN = os.getenv("WB_COIN") == "1"
local INPUTS = os.getenv("WB_INPUTS") == "1"
local GSW = tonumber(os.getenv("WB_GSW") or "0", 16)
local GSW2 = tonumber(os.getenv("WB_GSW2") or "0", 16)
local P1PROC = tonumber(os.getenv("WB_P1PROC") or "0", 16)

-- -Inputs: each button must clear exactly its T-UNIT bit in the gsw / gsw2
-- mirrors (wolf_inputs, MKINIT.ASM).  Active low, so pressed = bit goes 0.
local CHECKS = {
  {":IN0", "P1 High Punch",   "gsw",  4}, {":IN0", "P1 Block",       "gsw",  5},
  {":IN0", "P1 High Kick",    "gsw",  6}, {":IN0", "P1 Up",          "gsw",  0},
  {":IN0", "P2 High Punch",   "gsw", 12}, {":IN0", "P2 Block",       "gsw", 13},
  {":IN0", "P2 High Kick",    "gsw", 14},
  {":IN1", "P1 Low Punch",    "gsw2", 0}, {":IN1", "P1 Low Kick",    "gsw2", 1},
  {":IN1", "P2 Low Punch",    "gsw2", 4}, {":IN1", "P2 Low Kick",    "gsw2", 5},
  {":IN2", "1 Player Start",  "gsw", 18}, {":IN2", "2 Players Start", "gsw", 21},
}
-- WB_PEEK="name=hexaddr,..." : log those 16-bit words every 600 frames (raw bit addresses)
local PEEK = {}
for name, addr in string.gmatch(os.getenv("WB_PEEK") or "", "([%w_]+)=(%x+)") do PEEK[#PEEK + 1] = { name, tonumber(addr, 16) } end
-- WB_POKE="name=hexaddr=value,..." : 16-bit writes every frame while gstate is 2 (fighting)
local POKE = {}
for name, addr, v in string.gmatch(os.getenv("WB_POKE") or "", "([%w_]+)=(%x+)=(%w+)") do POKE[#POKE + 1] = { tonumber(addr, 16), tonumber(v) } end
-- WB_POKEGS="4,7" : the gstates WB_POKE writes in (default 2, fighting)
local POKE_GS = {}
for n in string.gmatch(os.getenv("WB_POKEGS") or "2", "%d+") do POKE_GS[tonumber(n)] = true end
local pass, fail = 0, 0
local fight = { frame = nil, step = 0 }
local SHOTS = { [240]=1, [600]=1, [900]=1, [1200]=1, [1500]=1, [1800]=1, [2100]=1,
                [2400]=1, [2700]=1, [3000]=1, [3300]=1, [3590]=1 }
-- WB_SHOTS="f1,f2,..." replaces that schedule
if (os.getenv("WB_SHOTS") or "") ~= "" then
    SHOTS = {}
    for n in string.gmatch(os.getenv("WB_SHOTS"), "%d+") do SHOTS[tonumber(n)] = 1 end
end
-- WB_PRESS="frame:Field Name:hold;..." - press an input by name (any port) for hold frames
local PRESS = {}
for fr, name, hold in string.gmatch(os.getenv("WB_PRESS") or "", "(%d+):([^:;]+):(%d+)") do
    PRESS[#PRESS + 1] = { tonumber(fr), name, tonumber(hold) }
end

-- The log is opened on the FIRST EMULATED FRAME, never at load: the launcher's
-- warning dismisser (mame_dismiss_warning.ps1) stops as soon as this file
-- exists, and the script loads before MAME shows its red ROM-warning box.
-- Opened at load, the dismisser quit at once and left the box for a human.
local f = nil
local function log(s)
    if not f then f = io.open(LOG, "w"); f:write("wolf_boot_probe start\n") end
    f:write(s .. "\n"); f:flush()
end

local frame, cpu, space = 0, nil, nil
local held = {}

-- by NAME, on whichever port carries it: the two drivers tag them differently
-- (umk3 has coins/start on :IN2 and LP/LK on :IN1, mk2 the other way round)
local function field(port, name)
    local p = manager.machine.ioport.ports[port]
    if p and p.fields[name] then return p.fields[name] end
    for _, q in pairs(manager.machine.ioport.ports) do
        if q.fields[name] then return q.fields[name] end
    end
end
local function press(port, name, on)
    local fl = field(port, name)
    if fl then fl:set_value(on and 1 or 0) else if on then log("no field " .. port .. " / " .. name) end end
end

-- WB_DIP="Field Name=value;..." : set DIP fields (user_value) on the first frame
-- and soft-reset ONCE, so the game boots reading them (power-up test etc).
-- MAME re-runs this script on soft_reset; _G.WB_DIP_DONE stops a second pass.
local DIPS = {}
for name, v in string.gmatch(os.getenv("WB_DIP") or "", "([^=;]+)=(%d+)") do DIPS[#DIPS + 1] = { name, tonumber(v) } end
if #DIPS > 0 and not _G.WB_DIP_DONE then
    local fired = false
    emu.register_frame(function()
        if fired then return end
        fired = true
        for _, d in ipairs(DIPS) do
            for _, port in pairs(manager.machine.ioport.ports) do
                local fl = port.fields[d[1]]
                if fl then fl.user_value = d[2] end
            end
        end
        _G.WB_DIP_DONE = true
        manager.machine:soft_reset()
    end)
    return
end
local started = false
emu.register_frame(function()
    -- held at the warning box, the machine does not run: wait for emulated
    -- time to move before counting a frame or creating the log
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
    end
    frame = frame + 1
    if not cpu then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local names = {}
        for tag, port in pairs(manager.machine.ioport.ports) do
            for name, _ in pairs(port.fields) do names[#names + 1] = tag .. " : " .. name end
        end
        table.sort(names)
        log("ports: " .. table.concat(names, " | "))
    end
    if frame % 60 == 0 then
        local gs = GSTATE ~= 0 and space:read_u16(GSTATE) or -1
        local tk = TICK ~= 0 and space:read_u16(TICK) or -1
        log(string.format("f=%d pc=%08X gstate=%d tick=%d", frame, cpu.state["PC"].value, gs, tk))
    end
    if INPUTS and frame >= 300 and frame < 300 + #CHECKS * 12 then
        local k = math.floor((frame - 300) / 12) + 1
        local t = (frame - 300) % 12
        local c = CHECKS[k]
        if t == 0 then c.base = { space:read_u32(GSW), space:read_u32(GSW2) } press(c[1], c[2], true) end
        if t == 4 then
            local now = { space:read_u32(GSW), space:read_u32(GSW2) }
            local i = (c[3] == "gsw") and 1 or 2
            local want = 1 << c[4]
            local d1, d2 = c.base[1] ~ now[1], c.base[2] ~ now[2]
            local got = (i == 1) and d1 or d2
            local other = (i == 1) and d2 or d1
            local ok = (got == want) and (other == 0) and ((now[i] & want) == 0)
            if ok then pass = pass + 1 else fail = fail + 1 end
            log(string.format("INPUT %-16s -> %s bit %2d  changed gsw %08X gsw2 %08X  %s",
                c[2], c[3], c[4], d1, d2, ok and "PASS" or "FAIL"))
            press(c[1], c[2], false)
        end
    end
    if INPUTS and frame == 300 + #CHECKS * 12 then
        log(string.format("INPUT MIRRORS: %d pass, %d fail", pass, fail))
    end
    -- in the first fight: P1 Low Punch then Low Kick must reach the fighter
    if INPUTS and P1PROC ~= 0 and space:read_u16(GSTATE) == 2 then
        fight.frame = fight.frame or frame
        local proc = space:read_u32(P1PROC)
        local act = proc ~= 0 and space:read_u16(proc + 0x1f0) or -1
        local rel = frame - fight.frame
        local plan = { {120, "P1 Low Punch", 0x0102}, {240, "P1 Low Kick", 0x0104} }
        for _, p in ipairs(plan) do
            if rel == p[1] then press(":IN1", p[2], true); p.seen = false end
            if rel == p[1] + 4 then press(":IN1", p[2], false) end
            if rel > p[1] and rel <= p[1] + 40 and act == p[3] and not fight[p[2]] then
                fight[p[2]] = true
                log(string.format("FIGHT %s -> p_action %04X at +%d  PASS", p[2], act, rel - p[1]))
            end
            if rel == p[1] + 41 and not fight[p[2]] then
                log(string.format("FIGHT %s -> never saw %04X  FAIL", p[2], p[3]))
            end
        end
    end
    for _, p in ipairs(PRESS) do
        if frame == p[1] then press("", p[2], true); log(string.format("press %s f=%d", p[2], frame)) end
        if frame == p[1] + p[3] then press("", p[2], false) end
    end
    if COIN then
        if frame == 1500 or frame == 1530 then press(":IN2", "Coin 1", true) end
        if frame == 1506 or frame == 1536 then press(":IN2", "Coin 1", false) end
        if frame == 1600 then press(":IN2", "1 Player Start", true) end
        if frame == 1606 then press(":IN2", "1 Player Start", false) end
    end
    if #POKE > 0 and POKE_GS[space:read_u16(GSTATE)] then
        for _, p in ipairs(POKE) do space:write_u16(p[1], p[2]) end
    end
    if frame % 600 == 0 and #PEEK > 0 then
        local t = {}
        for _, p in ipairs(PEEK) do t[#t + 1] = string.format("%s=%04X", p[1], space:read_u16(p[2])) end
        log("PEEK " .. table.concat(t, " "))
    end
    if SHOTS[frame] then
        manager.machine.video:snapshot()
        log("snap f=" .. frame)
    end
    if frame >= FRAMES then log("done"); f:close(); manager.machine:exit() end
end)
