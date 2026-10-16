-- sweep_addon_tie.lua - what actually happens when a round is a tie?
--
-- Section 5.1 of doc/TOURNAMENT_READINESS.md: `its_a_tie` (MAIN.ASM) is a bare
-- `retp` - no round to either side - and the match loop is `jrne play1`, which
-- only exits when somebody reaches TWO match wins. Nothing counts rounds
-- against a cap. So a tie burns a round and advances nothing.
--
-- That is a reading of the source. This is the test.
--
-- An equal-bar TIMEOUT is the reachable tie: `clock_ran_out` walks back into
-- `round_is_over`, which compares the two bars FIRST and takes `round_tied`
-- before it ever looks at the timeout flag. So: hold both bars equal, run the
-- clock down, and watch what the round awards.
--
-- Needs run_battle_stability_sweep.ps1 -NoHpPin, or the harness pins P1's bar
-- and clears winner_status and no round can finish at all.
--
-- Output: tools/tie_test.txt

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/tie_test.txt"
local TAG = os.getenv("TIE_TAG") or "run"

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
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
local p1_matchw, p2_matchw = S("p1_matchw"), S("p2_matchw")
local round_num, winner_status = S("round_num"), S("winner_status")
local clk_ones, clk_tens = S("clk_ones"), S("clk_tens")
if not (gstate and p1_bar and p1_matchw and clk_ones) then
    print("[tie] symbols missing - addon disabled"); return
end

local EQUAL_HP = 80

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[tie] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local forced, seen = 0, {}
local last = {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    local gs = space:read_u16(gstate)

    -- record every transition of the things a bracket cares about
    -- The change KEY deliberately excludes HP. Including it filled the whole
    -- log with the pre-fight health-bar fill animation - forty entries of
    -- "hp=4:4, hp=6:6, hp=8:8" - and the run ended before anything about the
    -- round outcome was recorded. HP is still printed; it just does not decide
    -- whether a line is worth keeping.
    local key = string.format("gs=%d r=%d w=%d m=%d:%d",
        gs, space:read_u16(round_num), space:read_u16(winner_status),
        space:read_u16(p1_matchw), space:read_u16(p2_matchw))
    if key ~= last.key then
        last.key = key
        if #seen < 60 then
            seen[#seen + 1] = string.format("f=%-6d %s hp=%d:%d", frame, key,
                space:read_u16(p1_bar), space:read_u16(p2_bar))
        end
    end

    if gs ~= 2 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== tie test (%s): equal bars, clock forced out ===", TAG)
    end
    local rel = frame - fight0
    if rel < 90 then return end

    -- hold the bars dead level so round_is_over takes round_tied, and run the
    -- clock down to the last unit so the timeout arrives in seconds not a
    -- minute
    space:write_u16(p1_bar, EQUAL_HP)
    space:write_u16(p2_bar, EQUAL_HP)
    if forced < 3 and space:read_u16(clk_tens) ~= 0 then
        space:write_u16(clk_tens, 0)
        space:write_u16(clk_ones, 1)
        forced = forced + 1
        log("forced the clock to 01 (pass %d) at rel=%d", forced, rel)
    end
end)

emu.register_stop(function()
    log("--- state transitions ---")
    for _, l in ipairs(seen) do log("  %s", l) end
    log("final: round_num=%d  match wins %d:%d  winner_status=%d",
        space and space:read_u16(round_num) or -1,
        space and space:read_u16(p1_matchw) or -1,
        space and space:read_u16(p2_matchw) or -1,
        space and space:read_u16(winner_status) or -1)
    local mw = (space and (space:read_u16(p1_matchw) + space:read_u16(p2_matchw))) or -1
    local rn = space and space:read_u16(round_num) or -1
    if rn > 1 and mw == 0 then
        log("VERDICT: %d rounds played, ZERO match wins awarded - a tie burns "
            .. "a round and the match loop is unbounded", rn)
    elseif mw > 0 then
        log("VERDICT: a round WAS awarded (%d total) - the tie path was not "
            .. "the one taken", mw)
    else
        log("VERDICT: inconclusive - round_num=%d wins=%d", rn, mw)
    end
end)
