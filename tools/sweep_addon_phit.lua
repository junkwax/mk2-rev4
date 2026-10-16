-- sweep_addon_phit.lua - how high does the combo counter actually get?
--
-- Damage scaling is only worth building if there is something to scale. MK2's
-- `p_hit` is incremented by reaction_start_chores on every hit that produces a
-- reaction, and cleared when the victim touches the ground (gravani,
-- MKUTIL.ASM) or blocks (block_exit) - so it counts consecutive hits taken
-- without landing, i.e. a juggle.
--
-- A corner-roundhouse test earlier measured it never exceeding 1, because a
-- knockdown resets it. If that is the whole game, scaling would almost never
-- fire and the feature is cosmetic. If real fights routinely reach 3-5, it is
-- the mechanic that decides how much a juggle is worth.
--
-- So: histogram p_hit for BOTH fighters, every frame, across whatever battles
-- the sweep runs. No inputs are driven - the drone plays, and what it does is
-- the sample. Driving attacks here would measure the rig's cadence, which is
-- exactly the mistake that has cost this project several afternoons.
--
-- Output: tools/phit_hist.txt (appended, one block per battle)

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/phit_hist.txt"
local LABEL = os.getenv("SWEEP_LABEL") or "battle"

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                sym[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate = S("gstate")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
if not (gstate and p1_proc) then
    print("[phit] symbols missing - addon disabled"); return
end

-- p_hit is pdata+270h and is an 8-BIT field (`movb` in inc_p_hit), so read a
-- byte, not a word - a word read picks up whatever shares the cell.
local P_HIT = 0x370

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[phit] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame = nil, 0
local peak = {}            -- fighter -> peak within the current string
local hist = {}            -- string length -> how many strings ended there
local best = 0
-- Damage per string, so the dmgscale switch can be A/B'd on the number that
-- matters. P1 is the one measured, because the DRONE is P2 - so P1 is the
-- fighter being hit. That needs run_battle_stability_sweep.ps1 -NoHpPin: the
-- harness normally holds p1_bar at full to keep a battle running its whole
-- window, and with it on this rig measured a flat zero.
-- hp_acc is NOT reset while no string is open, on purpose. The opening hit's
-- damage is applied BEFORE inc_p_hit runs, so on that frame p_hit is still 0 -
-- resetting there threw away the first hit of every string and the damage
-- column came out empty.
local dmg = {}             -- string length -> total HP taken across strings
local hp_prev, hp_acc, hp_total = nil, 0, 0

local function readhit(proc)
    local ok, v = pcall(function() return space:read_u8(proc + P_HIT) end)
    if ok then return v & 0xff end
    return space:read_u16(proc + P_HIT) & 0xff
end

local function track(tag, proc)
    local h = readhit(proc)
    local p = peak[tag] or 0
    if h > 0 then
        if h > p then peak[tag] = h end
    elseif p > 0 then
        hist[p] = (hist[p] or 0) + 1
        if p > best then best = p end
        peak[tag] = 0
        if tag == "p1" then
            dmg[p] = (dmg[p] or 0) + hp_acc
            hp_acc = 0
        end
    end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if r1 == 0 or r2 == 0 then return end
    -- accumulate P2's losses before the string is closed out
    if p1_bar then
        local hp = space:read_u16(p1_bar)
        if hp_prev and hp < hp_prev then
            hp_acc = hp_acc + (hp_prev - hp)
            hp_total = hp_total + (hp_prev - hp)
        end
        hp_prev = hp
    end
    track("p1", r1)
    track("p2", r2)
end)

emu.register_stop(function()
    local n, tot = 0, 0
    for k, v in pairs(hist) do
        n = n + v
        tot = tot + k * v
    end
    if n == 0 then
        log("%-22s no strings recorded", LABEL)
        return
    end
    local parts = {}
    for k = 1, best do
        if hist[k] then parts[#parts + 1] = string.format("%d:%d", k, hist[k]) end
    end
    log("%-22s strings=%-4d longest=%-2d avg=%.2f   %s",
        LABEL, n, best, tot / n, table.concat(parts, " "))
    local dparts = {}
    for k = 1, best do
        if dmg[k] and hist[k] then
            dparts[#dparts + 1] = string.format("%dhit=%.0f", k, dmg[k] / hist[k])
        end
    end
    log("%-22s P1 total HP lost = %d", LABEL, hp_total)
    if #dparts > 0 then
        log("%-22s P1 avg HP lost per string:  %s", LABEL, table.concat(dparts, "  "))
    end
end)
