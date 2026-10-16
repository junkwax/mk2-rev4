-- coin_freeplay_probe.lua
--
-- Proves the two halves of the coin/free-play change:
--
--   MODE=coin      P1 START on an empty machine must NOT start a game.
--                  Four coins in, then START, must start one.
--   MODE=netplay   f_netplay poked to 1 must make START work with ZERO
--                  credits (that is what an online session gets).
--
-- gstate: 1 = amode, 2 = fighting, 4 = player select.
-- p1_state: 0 = not in game, 1 = active, 3 = player select.
--
-- Env: COIN_LOG, COIN_MODE
-- Usage: tools\run_coin_freeplay_probe.ps1

local LOGP = os.getenv("COIN_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/coin_freeplay_probe.log"
local MODE = (os.getenv("COIN_MODE") or "coin"):lower()

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[coin] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate    = sym("gstate"),
    p1_state  = sym("p1_state"),
    p2_state  = sym("p2_state"),
    f_netplay = sym("f_netplay"),
}

local space, fields = nil, {}
local frame = 0
local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v) end

-- the fields we drive; names come from MAME's mk2 ioport definitions
local want = { ["Coin 1"] = true, ["1 Player Start"] = true, ["P1 Start"] = true,
               ["Start 1"] = true }
local held = {}

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    local names = {}
    for n in pairs(fields) do names[#names + 1] = n end
    table.sort(names)
    log("driving fields: %s", table.concat(names, ", "))
end

local START_NAME = nil
local function press(name, frames)
    held[name] = frame + frames
end

-- scenario state machine -------------------------------------------------
local st        = "boot"
local mark      = 0
local coins_in  = 0
local result    = {}
local function note(k, v) result[#result + 1] = string.format("%s=%s", k, tostring(v)) end

local function started()
    return r16(A.gstate) == 4 or r16(A.p1_state) ~= 0
end

local function step()
    local gs = r16(A.gstate)

    if st == "boot" then
        if gs == 1 then
            log("frame %d: attract reached (gstate=1)", frame)
            if MODE == "netplay" then
                w16(A.f_netplay, 1)
                log("poked f_netplay=1 at %08x", A.f_netplay)
            end
            st, mark = "settle", frame + 120
        end

    elseif st == "settle" then
        if frame >= mark then
            log("frame %d: pressing START with 0 credits (gstate=%d p1_state=%d)",
                frame, gs, r16(A.p1_state))
            press(START_NAME, 6)
            st, mark = "start_empty", frame + 180
        end

    elseif st == "start_empty" then
        if started() then
            note("empty_start", "STARTED")
            log("frame %d: game STARTED on an empty machine (gstate=%d p1_state=%d)",
                frame, gs, r16(A.p1_state))
            st = "done"
        elseif frame >= mark then
            note("empty_start", "refused")
            log("frame %d: START refused with 0 credits (gstate=%d)", frame, gs)
            if MODE == "netplay" then
                st = "done"
            else
                st, mark = "coining", frame + 20
            end
        end

    elseif st == "coining" then
        if frame >= mark then
            if coins_in < 4 then
                coins_in = coins_in + 1
                press("Coin 1", 5)
                log("frame %d: coin %d", frame, coins_in)
                mark = frame + 30
            else
                st, mark = "start_paid", frame + 60
            end
        end

    elseif st == "start_paid" then
        if frame >= mark then
            log("frame %d: pressing START with 4 coins in (gstate=%d)", frame, gs)
            press(START_NAME, 6)
            st, mark = "wait_paid", frame + 240
        end

    elseif st == "wait_paid" then
        if started() then
            note("paid_start", "STARTED")
            log("frame %d: game STARTED after coins (gstate=%d p1_state=%d)",
                frame, gs, r16(A.p1_state))
            st = "done"
        elseif frame >= mark then
            note("paid_start", "REFUSED")
            log("frame %d: START still refused after 4 coins (gstate=%d)", frame, gs)
            st = "done"
        end

    elseif st == "done" then
        log("VERDICT mode=%s %s", MODE, table.concat(result, " "))
        if logfh then logfh:close(); logfh = nil end
        manager.machine:exit()
        st = "exited"
    end
end

emu.register_frame_done(function()
    frame = frame + 1
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        for _, n in ipairs({ "1 Player Start", "P1 Start", "Start 1" }) do
            if fields[n] then START_NAME = n break end
        end
        if not START_NAME then log("FATAL: no P1 start field found") end
        log("mode=%s gstate@%08x f_netplay@%08x start=%s",
            MODE, A.gstate, A.f_netplay, tostring(START_NAME))
    end
    for n, f in pairs(fields) do
        f:set_value((held[n] and frame <= held[n]) and 1 or 0)
    end
    if st ~= "exited" then step() end
end)
