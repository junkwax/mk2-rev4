-- loop_audit.lua - find long hit strings and repeated-move loops.
--
-- The dynamic half of the balance audit.  Static outliers (balance_audit.py)
-- say a move is unusual; this says a move is being landed over and over on
-- someone who cannot act.
--
-- The signal is the game's OWN counter.  p_hit (pdata+270h) is the consecutive
-- hit count, and MK2's anti-infinite `no_unlimited_airhits` triggers off it at
-- > 3 - so the engine already knows when a string is getting long, and there
-- is no need to reconstruct strings from HP drops.
--
-- Records, per attacking move: how many strings it was part of, and the
-- longest p_hit reached during them.  A move that repeatedly drives p_hit into
-- double figures is the infinite, and the table names it.
--
-- Known case to look for: the corner roundhouse.  Every character's roundhouse
-- shares strike-routine 0d1eh; the anti-infinite fires but `repell_now`
-- discards the separation it asks for, so the string never breaks.

local ROOT = "C:/Users/you/Workplace/mk2-main"

local TAG = "run"
do
    local fh = io.open(ROOT .. "/tools/ledger_tag.txt", "r")
    if fh then TAG = (fh:read("*l") or "run"):gsub("%s+$", ""); fh:close() end
end
local OUT = ROOT .. "/tools/loop_audit_" .. TAG .. ".txt"

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
local p1_obj, p2_obj   = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
if not (gstate and p1_proc) then return end

-- pdata = 0x100, so: p_action 0x1f0, p_stk 0x350, p_hit 0x370
-- p_hitby (pdata+260h -> 0x360) is the ENGINE'S OWN attribution: strike_check
-- writes the attacker's p_action into the victim's p_hitby (JOY.ASM:1639).
-- Use it instead of inferring "the other fighter's current move must have done
-- it" - that inference credited act_stance, i.e. a fighter standing still, and
-- filtering those out then hid the very juggles worth finding.
local P = { action = 0x1f0, hitby = 0x360, stk = 0x350, hit = 0x370 }
local O = { ochar = 0x1f0, oxpos = 0x090 }

-- index -> record name, counted (the list comments are HEX)
local CHAR_LIST = {
    [0]="hh_strikes",[1]="lk_strikes",[2]="jc_strikes",[3]="sa_strikes",
    [4]="fn_strikes",[5]="fn_strikes",[6]="st_strikes",[7]="rd_strikes",
    [8]="nj_strikes",[9]="nj_strikes",[10]="nj_strikes",[11]="jx_strikes",
    [12]="go_strikes",[13]="sk_strikes",[14]="nj_strikes",[15]="nj_strikes",
    [16]="fn_strikes" }
local names = {}
do
    local fh = io.open(ROOT .. "/src/MKSTK.ASM", "r")
    if fh then
        local cur, n = nil, 0
        for line in fh:lines() do
            local lbl = line:match("^([%w_]+_strikes)%s*$")
            if lbl then cur, n = lbl, 0; names[cur] = {} end
            if cur then
                local sy = line:match("^%s*%.long%s+(stk_[%w_]+)")
                if sy then names[cur][n] = sy; n = n + 1
                elseif line:match("^%s*$") and n > 0 then cur = nil end
            end
        end
        fh:close()
    end
end
local function move_name(ochar, stk)
    local l = CHAR_LIST[ochar]
    if l and names[l] and names[l][stk] then return names[l][stk] end
    return string.format("char%d_idx%02xh", ochar, stk)
end

-- p_stk ALONE IS NOT A MOVE KEY.  Index 0 is stk_*hikick and also the
-- uninitialised value, so every move that never writes p_stk lands in it:
-- measured, Jax took 142 hits under stk=00h split across act_hikick AND
-- act_stance.  p_action is set for every move, so key on that and fall back
-- to the record name only for display.
local acts = {}
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+(%x+)h")
            if n and v then acts[tonumber(v, 16)] = n end
        end
        fh:close()
    end
end

-- Only an ATTACK may be credited with a hit.  01xx is the attack range;
-- 03xx is stance/jump and 06xx is recovery, and crediting those was blaming
-- whichever fighter happened to be standing there when a projectile landed.
local function is_attack(act) return act >= 0x0100 and act <= 0x01ff end

local function act_name(act, ochar, stk)
    return (acts[act] or string.format("act_%04xh", act))
           .. " [" .. move_name(ochar, stk) .. "]"
end

local space, frame = nil, 0
local fields, closed = {}, false
local stats = {}          -- move -> {strings, longest}
local cur = {}            -- victim tag -> {peak, mover}

local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function readhit(proc)
    local ok, v = pcall(function() return space:read_u8(proc + P.hit) end)
    if ok then return v & 0xff end
    return space:read_u16(proc + P.hit) & 0xff
end

-- LATCH THE ATTRIBUTION WHEN THE STRING OPENS, then follow p_hit to its peak.
--
-- Requiring the attacker to still be attacking on EVERY frame was wrong the
-- other way: p_hit stays elevated for frames after the move ends, so the
-- string closed instantly and every length came out as 1.  A string is opened
-- only by a real attack (that is what fixes the mis-credit), but once open it
-- is followed until p_hit returns to zero regardless of what either fighter
-- is doing.
local function note(vtag, vproc, hits)
    local c = cur[vtag]
    if c then
        if hits > 0 then
            if hits > c.peak then c.peak = hits end
        else
            local e = stats[c.mover]
            if not e then e = { strings = 0, longest = 0 }; stats[c.mover] = e end
            e.strings = e.strings + 1
            if c.peak > e.longest then e.longest = c.peak end
            cur[vtag] = nil
        end
        return
    end
    if hits > 0 then
        local by = space:read_u16(vproc + P.hitby)
        cur[vtag] = { peak = hits,
                      mover = acts[by] or string.format("act_%04xh", by) }
    end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = { ["P1 High Punch"]=true, ["P1 Low Punch"]=true,
                       ["P1 High Kick"]=true, ["P1 Low Kick"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fields[fd.name] = fd end
            end
        end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end

    -- close in and keep swinging so strings actually happen
    if not closed and frame > 240 then
        local x = s16(space:read_u16(o2 + O.oxpos)) - 80
        space:write_u32(o1 + 0x080, (x << 16) & 0xffffffff)
        space:write_u16(o1 + O.oxpos, x)
        closed = true
    end
    if closed then
        local ph = frame % 30
        local which = math.floor(frame / 30) % 4
        local pick = ({"P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick"})[which+1]
        for n, fd in pairs(fields) do
            fd:set_value((n == pick and ph >= 3 and ph < 9) and 1 or 0)
        end
    end

    -- p_hit on a fighter counts hits taken in the current string, so the
    -- ATTACKER is the other side
    note("p2", r2, readhit(r2))
    note("p1", r1, readhit(r1))
end)

emu.register_stop(function()
    local fh = io.open(OUT, "a")
    if not fh then return end
    for k, e in pairs(stats) do
        fh:write(string.format("%-26s strings=%-4d longest=%d\n",
                               k, e.strings, e.longest))
    end
    fh:close()
end)
