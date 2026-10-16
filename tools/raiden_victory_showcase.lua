--- raiden_victory_showcase.lua - hands-off Raiden victory viewer.
---
--- Drives a 2P match on the Armory as Raiden vs Jax, then drains P2 a few
--- seconds into every round so the victory stance plays over and over.  No
--- snapshots, no auto-exit: it just keeps serving up the pose so it can be
--- watched / recorded.  Close the MAME window (or press Esc) when done.
---
--- What to look for:
---   during the fight   - ambient bolts crackle over Raiden every 16-47 ticks
---   the moment he wins - that crackle stops dead (no bolt on the pose)
---   ~0.7s into the pose - the two RNVICBOLT arm bolts fire, and only those
---   his right armpit   - clean; the loose speck cluster is gone

local ROOT = "C:/Users/you/Workplace/mk2-main"

local frame = 0
local function log(fmt, ...)
    print("[rdshow] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
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
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), winner_status = sym("winner_status"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"), curback = sym("curback"),
}
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_RAIDEN, FT_JAX = 7, 11
local STAGE_ID = 5                 -- Armory

local space, fields = nil, {}
local last_gstate = -1
local charsel_frame, p1_confirm_start = 0, 0
local fight_start, armed_kill = 0, 0
local wins = 0
local KILL_DELAY = 260             -- ~4.3s of fighting (ambient bolts visible) before the win

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                     ["P1 High Punch"] = true, ["P2 High Punch"] = true }
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

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fight_start == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if not cache_fields() then return end
        log("Raiden victory showcase - Raiden vs Jax, Armory. Each round ends")
        log("automatically ~4s in, so the victory stance replays on a loop.")
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_start = frame
            armed_kill = frame + KILL_DELAY
        end
        last_gstate = gs
    end

    -- Character select: lock in Raiden vs Jax on the Armory.
    if charsel_frame > 0 and fight_start == 0 then
        w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX); w16(A.curback, STAGE_ID)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_RAIDEN and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    end

    -- End each round once it has been running a few seconds.
    if armed_kill > 0 and frame >= armed_kill and gs == GS_FIGHTING then
        if r16(A.p2_bar) > 0 then
            w16(A.p2_bar, 0)
            wins = wins + 1
            log("win #%d - victory stance coming up (frame %d)", wins, frame)
        end
        armed_kill = 0
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
