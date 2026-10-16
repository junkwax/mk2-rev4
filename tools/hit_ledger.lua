-- hit_ledger.lua - per-move hit-registration ledger.
--
-- "The move would count before but now it didn't register, and WHICH move."
--
-- Answers that by observing, not by driving inputs: every time a fighter
-- enters a move's active window, note which strike record it is using
-- (p_stk), then watch whether the opponent loses HP before the window ends.
-- Accumulate per (character, strike index) across a whole sweep and write a
-- file that can be DIFFED between two builds.  A move whose connect count
-- collapses between runs is the regression, and the file names it.
--
-- Passive on purpose.  Every rig in this session that drove inputs ended up
-- measuring the rig instead of the game - "swipe never fired" on most rows of
-- a range map.  The drone fights on its own; let it.
--
-- Usage: rename to sweep_addon.lua, run the sweep, then diff the two
--   tools/hit_ledger_<tag>.txt files.  Tag comes from tools/ledger_tag.txt.

local ROOT = "C:/Users/you/Workplace/mk2-main"

local TAG = "run"
do
    local fh = io.open(ROOT .. "/tools/ledger_tag.txt", "r")
    if fh then TAG = (fh:read("*l") or "run"):gsub("%s+$", ""); fh:close() end
end
local OUT = ROOT .. "/tools/hit_ledger_" .. TAG .. ".txt"

local logfh = io.open(ROOT .. "/tools/sweep_addon.log", "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[ledger] " .. l); if logfh then logfh:write(l, "\n"); logfh:flush() end
end

-- ---- symbols -----------------------------------------------------------
local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a,16) end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate = S("gstate")
local p1_obj, p2_obj   = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar   = S("p1_bar"), S("p2_bar")
if not (gstate and p1_proc and p1_bar) then log("ledger: symbols missing"); return end

-- pdata is 0x100: p_action is `pdata+0f0h` and 0x1f0 is the value that
-- demonstrably works, so p_stk (`pdata+250h`) is 0x350 - NOT 0x250.  Using the
-- raw equate offset keyed every move as index 0.
local P = { stk = 0x350, action = 0x1f0 }
local O = { ochar = 0x1f0 }

-- ---- index -> record name, parsed straight out of MKSTK.ASM ------------
-- The per-character lists are `.long stk_foo ; <hex index>`.  The comments are
-- HEXADECIMAL, which has already caused one wrong-move bug this session, so
-- count the entries rather than trusting them.
local CHAR_LIST = {
    [0]="hh_strikes",[1]="lk_strikes",[2]="jc_strikes",[3]="sa_strikes",
    [4]="fn_strikes",[5]="fn_strikes",[6]="st_strikes",[7]="rd_strikes",
    [8]="nj_strikes",[9]="nj_strikes",[10]="nj_strikes",[11]="jx_strikes",
    [12]="go_strikes",[13]="sk_strikes",[14]="nj_strikes",[15]="nj_strikes",
    [16]="fn_strikes",
}
local names = {}     -- names[listname][index] = "stk_foo"
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
    local list = CHAR_LIST[ochar]
    if list and names[list] and names[list][stk] then return names[list][stk] end
    return string.format("char%d_idx%02xh", ochar, stk)
end

-- ---- drive some attacks -------------------------------------------------
-- Purely passive does not work here: the sweep's battles wander without
-- connecting, so the ledger counted 181 windows and ZERO hits.  Drive P1 with
-- simple single-button attacks (no motion inputs - those are what kept
-- "never fired" appearing) and let the drone supply the rest.
local fields = {}
local ATTACK_PERIOD = 34

-- ---- state -------------------------------------------------------------
local space, frame, closed = nil, 0, false
local ledger = {}          -- key -> {windows, hits}
local watch  = {}          -- per fighter: an open window

local function bump(key, field)
    local e = ledger[key]
    if not e then e = { windows = 0, hits = 0 }; ledger[key] = e end
    e[field] = e[field] + 1
end

local function side(objaddr, procaddr, myhp, theirhp, tag)
    local obj  = space:read_u32(objaddr)
    local proc = space:read_u32(procaddr)
    if obj == 0 or proc == 0 then return end
    local act = space:read_u16(proc + P.action)
    local stk = space:read_u16(proc + P.stk)
    local ochar = space:read_u16(obj + O.ochar)
    local w = watch[tag]

    -- an "attack window" = p_action in the attack range and a strike index set
    local attacking = (act >= 0x0100 and act < 0x0700)

    if attacking and not w then
        watch[tag] = { key = move_name(ochar, stk), hp = space:read_u16(theirhp),
                       age = 0, scored = false }
        bump(watch[tag].key, "windows")
    elseif w then
        w.age = w.age + 1
        if not w.scored and space:read_u16(theirhp) < w.hp then
            bump(w.key, "hits"); w.scored = true
        end
        -- close it a few frames after the action ends, so a hit that lands on
        -- the last active frame still counts
        if not attacking and w.age > 6 then watch[tag] = nil end
        if w.age > 240 then watch[tag] = nil end
    end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
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

    -- close the distance once, then cycle the four basic attacks
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 ~= 0 and o2 ~= 0 then
        if not closed and frame > 240 then
            local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
            local x = s16(space:read_u16(o2 + 0x090)) - 80
            space:write_u32(o1 + 0x080, (x << 16) & 0xffffffff)
            space:write_u16(o1 + 0x090, x)
            closed = true
        end
        if closed then
            local ph = frame % ATTACK_PERIOD
            local which = math.floor(frame / ATTACK_PERIOD) % 4
            local pick = ({"P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick"})[which+1]
            for n, fd in pairs(fields) do
                fd:set_value((n == pick and ph >= 3 and ph < 10) and 1 or 0)
            end
        end
    end

    side(p1_obj, p1_proc, p1_bar, p2_bar, "p1")
    side(p2_obj, p2_proc, p2_bar, p1_bar, "p2")
end)

emu.register_stop(function()
    -- append: the sweep runs one MAME per battle, so the ledger accumulates
    -- across the whole sweep into one file
    local fh = io.open(OUT, "a")
    if not fh then return end
    local keys = {}
    for k in pairs(ledger) do keys[#keys+1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local e = ledger[k]
        fh:write(string.format("%-28s windows=%-5d hits=%-5d\n", k, e.windows, e.hits))
    end
    fh:close()
end)
