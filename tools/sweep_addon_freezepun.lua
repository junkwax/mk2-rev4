-- sweep_addon_freezepun.lua - which state is calling PUNISH around Sub-Zero's
--                             freeze?
--
-- Report: "when an opponent hit sub zero when sub does a freeze its counting
-- as a punish where it shouldnt because the opponent is frozen".
--
-- Reading the classifier does not settle it. A frozen victim is act_frozen
-- (0401h), category 4, which never reaches hc_pun's `cmpi 6` gate at all - so
-- whatever is arming PUNISH is some other state in the exchange, and the only
-- way to name it is to watch every arming with BOTH fighters' actions beside
-- it.
--
-- P1 is Sub-Zero throwing freezes (D,F + LP); P2 is human and mashes, so hits
-- land in both directions and every rung of the classifier gets exercised.
--
-- Logs, per arming: the word, WHOSE it is, and both actions. No filtering and
-- no verdict - this rig is for finding the culprit, not for scoring a fix.
--
-- Env: FZP_LOG
-- Driven by run_freezepun_test.ps1.

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

-- every word the classifier can arm, by address
local WORDS = {}
for _, n in ipairs({"hc_kounter_s","hc_punish","hc_reversal","hc_blockpun",
                    "hc_whiffpun","hc_antiair","hc_firsthit","hc_flawblk"}) do
    if sym[n] then WORDS[sym[n]] = n:gsub("^hc_", ""):upper() end
end

local P_ACTION = 0x1f0
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
        log("=== freeze punish === Sub-Zero spams D,F+LP; P2 mashes")
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
            log("  %-12s p%d  t=%-5d victim(p%d) act %04x (was %04x)  attacker act %04x",
                name, i + 1, t, v + 1, act[v], hist[v][1] or 0, act[i])
            prev_arms[i] = n
        end
    end
    for i = 0, 1 do
        table.insert(hist[i], 1, act[i])
        if #hist[i] > 3 then table.remove(hist[i]) end
    end

    -- P1 Sub-Zero: D,F + LP on a cycle.  P2 mashes HP and sometimes blocks.
    local c = t % 40
    press("P1 Down", c >= 0 and c <= 2)
    press("P1 Right", c >= 4 and c <= 6)
    press("P1 Low Punch", c == 6 or c == 7)

    local d = t % 26
    press("P2 Block", d < 8)
    press("P2 High Punch", d == 16 or d == 17)
    press("P2 Low Kick", d == 22 or d == 23)
end)

emu.register_stop(function()
    for k, v in pairs(counts) do log("RESULT %-12s x%d", k, v) end
end)
