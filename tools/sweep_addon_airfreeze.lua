-- sweep_addon_airfreeze.lua - what arms ANTI-AIR around Sub-Zero's AIR
--                             freeze?
--
-- Report: "anti air should not use sub zeros air freeze attack registering".
--
-- Reading the classifier says it cannot happen: hc_frzchk drops any hit whose
-- strike-routine row is 13h or 15h, and air_ice_proc publishes 013h/014h -
-- both stk_ice1/stk_ice2, both routine word 1313h. So either the row is not
-- what reaches a11 on the projectile path, or the word is arming on the
-- FOLLOW-UP: a man frozen in mid-air is 04xx, not 05xx, so the next hit on
-- him passes hc_air's "already reacting" test and reads as an anti-air.
--
-- Either way the way to tell is to watch every arming with both actions
-- beside it. P1 is Sub-Zero, jumping and throwing the air freeze; P2 is human
-- and jumps into it, so there is an airborne victim to freeze.
--
-- Logs, per arming: the word, WHOSE it is, and both actions. No filtering and
-- no verdict - this rig is for finding the culprit, not for scoring a fix.
--
-- Env: FZP_LOG
-- Driven by run_airfreeze_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("FZP_LOG") or (ROOT .. "/tools/freezepun.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local cal_word, cal_arms = sym.cal_word, sym.cal_arms
local cal_first = sym.cal_first

-- every word the classifier can arm, by address
local WORDS = {}
for _, n in ipairs({"hc_kounter_s","hc_punish","hc_reversal","hc_blockpun",
                    "hc_whiffpun","hc_antiair","hc_firsthit","hc_flawblk"}) do
    if sym[n] then WORDS[sym[n]] = n:gsub("^hc_", ""):upper() end
end

local P_ACTION = 0x1f0
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local OYPOS, OXPOS, OXVAL = 0x0b0, 0x090, 0x080
local GROUND = 197            -- the floor oypos every rig in here uses
local MAX_HP = 0xA1

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[fzp] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
    "P2 Left","P2 Right","P2 Up","P2 Down",
    "P2 High Punch","P2 Low Punch","P2 High Kick","P2 Low Kick","P2 Block",
}) do ADDON_OWNS[n] = true end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local prev_arms = {[0] = 0, [1] = 0}
local hist = {[0] = {}, [1] = {}}     -- last few actions per player
local counts = {}
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== air freeze === Sub-Zero jumps and throws; P2 jumps into it")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    local pr = {space:read_u32(p1_proc), space:read_u32(p2_proc)}
    local act = {}
    for i = 0, 1 do
        act[i] = pr[i + 1] ~= 0 and (space:read_u16(pr[i + 1] + P_ACTION) & 0xffff) or 0
    end

    for i = 0, 1 do
        -- cal_arms counts every arming, including a word re-arming as itself
        local n = space:read_u16(cal_arms + i * 16) & 0xffff
        if n ~= prev_arms[i] then
            local w = space:read_u32(cal_word + i * 32)
            local name = WORDS[w] or string.format("?%08x", w)
            local v = 1 - i                      -- the victim is the other one
            -- the action BEFORE this frame is what the classifier read: by now
            -- the victim is already in his reaction
            counts[name] = (counts[name] or 0) + 1
            local vo = space:read_u32(v == 0 and p1_obj or p2_obj)
            -- SIGNED.  oypos is head-anchored and goes NEGATIVE at the top
            -- of a jump, so an unsigned read prints 65518 and gets labelled
            -- "ground" - the exact opposite of where he is.
            local vy = 0
            if vo ~= 0 then
                vy = space:read_u16(vo + OYPOS) & 0xffff
                if vy >= 0x8000 then vy = vy - 0x10000 end
            end
            log("  %-12s p%d  t=%-5d victim(p%d) act %04x (was %04x, %04x) " ..
                "y=%d %s  attacker act %04x",
                name, i + 1, t, v + 1, act[v], hist[v][1] or 0,
                hist[v][2] or 0, vy, vy < GROUND - 8 and "AIRBORNE" or "ground",
                act[i])
            prev_arms[i] = n
        end
    end
    for i = 0, 1 do
        table.insert(hist[i], 1, act[i])
        if #hist[i] > 3 then table.remove(hist[i]) end
    end

    -- P1 Sub-Zero: jump, then D,F + LP while he is up there.  Two cycles in
    -- one: the AIR throw needs him airborne when the command completes, and
    -- a ground throw in between gives the ordinary freeze for comparison.
    -- FIRST HIT, pre-spent.  That rung sits ABOVE the freeze gate on purpose,
    -- so an opening freeze takes the word and every rung under it - the one
    -- being tested - never runs.  Landing a jab first is the honest way and
    -- it kept missing; setting the flag the round already sets is the same
    -- state without the choreography.
    space:write_u16(cal_first, 1)
    -- Pinned in jab range, and P1 keeps jabbing: the case the report is
    -- most likely describing is not the freeze itself (measured: it arms
    -- nothing once FIRST HIT is spent) but the FOLLOW-UP - a man frozen in
    -- mid-air is 04xx, so he sails past hc_air's "already reacting" test and
    -- the hit that lands on him reads as an anti-air.
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 ~= 0 and o2 ~= 0 then
        local x1 = space:read_u16(o1 + OXPOS) & 0xffff
        local x2 = space:read_u16(o2 + OXPOS) & 0xffff
        local tx = (x1 < x2) and (x1 + 62) or (x1 - 62)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end

    local c = t % 96
    press("P1 Up",        c >= 0 and c <= 2)
    press("P1 Down",      c == 10 or c == 11 or c == 60 or c == 61)
    press("P1 Right",     c == 13 or c == 14 or c == 63 or c == 64)
    press("P1 Low Punch", c == 15 or c == 16 or c == 65 or c == 66)
    press("P1 High Punch", c == 30 or c == 31 or c == 40 or c == 41
                        or c == 80 or c == 81 or c == 90 or c == 91)

    -- P2 jumps on his own clock, so he is in the air for some of them and
    -- on the floor for others
    local d = t % 61
    press("P2 Up", d >= 0 and d <= 2)
end)

emu.register_stop(function()
    for k, v in pairs(counts) do log("RESULT %-12s x%d", k, v) end
end)
