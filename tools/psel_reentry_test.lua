-- psel_reentry_test.lua - directed test for the character-select hang.
--
-- Hypothesis: start_a_game (MAIN.ASM:300) has its "player already active ->
-- exit" guard COMMENTED OUT, so a START press by a player who is already in
-- the select screen still falls through to join_in_during_psel.  That forces
-- his p?_state back to ps_psel and create_cursor_procs then create_if_gone's
-- a FRESH cursor process for a player who has already confirmed - while his
-- pending hidden-fighter flag is still up and @p?_char may still hold the
-- committed ft_*.  cmove9 then indexes ochar_to_menu (12 entries) with it.
--
-- Drives: 2P select -> arm Rain for P1 -> P1 confirms -> P1 mashes START ->
-- P1 confirms again.  Logs every p?_char write with the writer's PC and fires
-- if the CPU parks in cmovea's dsjs loop.
--
--   cd C:\MAME ; mame_mk2test.exe -rompath <repo>\rom mk2 -window -video gdi \
--     -keyboardprovider win32 -skip_gameinfo -sound none -seconds_to_run 240 \
--     -autoboot_script <repo>\tools\psel_reentry_test.lua

local ROOT = "C:/Users/you/Workplace/mk2-main"
local out = assert(io.open(ROOT.."/tools/psel_reentry_test.log", "w"))
local function log(f, ...) local s = string.format(f, ...)
  print("[reentry] "..s); out:write(s, "\n"); out:flush() end

local syms = {}
local m = assert(io.open(ROOT.."/src/mk2.map", "r"))
for l in m:lines() do for a, n in l:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
  syms[n] = tonumber(a, 16) end end
m:close()
local function s(n) assert(syms[n], n); return syms[n] end

local A = { gstate=s("gstate"), p1_char=s("p1_char"), p2_char=s("p2_char"),
            p1_state=s("p1_state"), p2_state=s("p2_state"),
            rain1=s("f_rain_cheat1"), rain2=s("f_rain_cheat2") }
local GS_PSEL = 4
local cpu, space, frame, psel0, done = nil, nil, 0, 0, false
local last = {gs=-1, p1s=-1, p2s=-1}
local pcmin, pcmax, pcrun = nil, nil, 0
local fields, held = {}, {}
local WANT = {"Coin 1","Coin 2","1 Player Start","2 Players Start",
              "P1 High Punch","P2 High Punch","P1 Right","P2 Left"}

local function r16(a) return space:read_u16(a) end
local function st() return string.format("gs=%d p1s=%d p2s=%d p1c=%d p2c=%d rain=%d/%d",
  r16(A.gstate), r16(A.p1_state), r16(A.p2_state), r16(A.p1_char), r16(A.p2_char),
  r16(A.rain1), r16(A.rain2)) end
local function hold(n, on) local f = fields[n]; if not f then return end
  if held[n] ~= on then f:set_value(on and 1 or 0); held[n] = on end end

-- The master's select timeout is `movi 040h*5,a11` decremented once per
-- `sleep 3` (MKSEL.ASM psel6/psel5) = 320*3 = 960 ticks after the select
-- screen appears.  psel9 then force_psel_choice's EVERY still-existing
-- pid_p?sel proc into cmove9 -- with no check that the proc is still at
-- psel_cursor_loop.  A proc that has already confirmed is in cmove9's ~24-tick
-- flash loop (pwake = i_am_flashing) and has ALREADY run
-- psel_apply_hidden_char, so @p?_char is the hidden ft_*.  Re-entering cmove9
-- then hands that ft_* to ochar_to_menu.
--
-- So: confirm P1 just before tick 960 and let the timeout land on his flash.
local TIMEOUT = tonumber(os.getenv("PSEL_TIMEOUT") or "960")
local CONFIRM = tonumber(os.getenv("PSEL_CONFIRM") or "950")
local SCHED = {
  {  20,  35, "2 Players Start"},              -- P2 joins mid-select (join_in_during_psel)
  { CONFIRM, CONFIRM + 14, "P1 High Punch"},  -- P1 confirms into the timeout
}

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    for _, port in pairs(manager.machine.ioport.ports) do
      for _, f in pairs(port.fields) do
        for _, n in ipairs(WANT) do if f.name == n then fields[n] = f end end end end
    for _, n in ipairs(WANT) do if not fields[n] then log("MISSING INPUT %s", n) end end
    for _, n in ipairs({"p1_char", "p2_char"}) do
      _G["tap_"..n] = space:install_write_tap(A[n], A[n]+15, "re_"..n,
        function(off, data) log("%6d  %s <= %-5d pc=%08X  %s", frame, n,
          data & 0xffff, cpu.state["PC"].value, st()) end)
    end
    log("reentry test loaded"); return
  end
  if not space or done then return end
  local gs = r16(A.gstate)
  if gs ~= last.gs then log("%6d  gstate %d -> %d   %s", frame, last.gs, gs, st()); last.gs = gs end
  local p1s, p2s = r16(A.p1_state), r16(A.p2_state)
  if p1s ~= last.p1s or p2s ~= last.p2s then
    log("%6d  pstate p1 %d->%d p2 %d->%d   %s", frame, last.p1s, p1s, last.p2s, p2s, st())
    last.p1s, last.p2s = p1s, p2s end

  if gs ~= GS_PSEL and psel0 == 0 then
    -- boot: coin both players up, then start a TWO player game
    hold("Coin 1", frame > 120 and frame < 460 and frame % 30 < 8)
    hold("Coin 2", frame > 120 and frame < 460 and frame % 30 >= 15 and frame % 30 < 23)
    hold("1 Player Start", frame >= 500 and frame < 515)
    hold("2 Players Start", frame >= 540 and frame < 555)
    return
  end
  if psel0 == 0 and gs == GS_PSEL then
    psel0 = frame; log("%6d  SELECT reached  %s", frame, st())
    for _, n in ipairs(WANT) do hold(n, false) end
    log("%6d  timeout expected at r=%d, P1 confirms at r=%d", frame, TIMEOUT, CONFIRM)
  end
  if psel0 > 0 then
    local r = frame - psel0
    -- player_select nulls the chars and every cheat flag on entry, so arm the
    -- pending Rain pick only once that has happened
    if r == CONFIRM - 50 then space:write_u16(A.rain1, 1)
      log("%6d  armed f_rain_cheat1 = 1 (r=%d)", frame, r) end
    for _, n in ipairs(WANT) do hold(n, false) end
    for _, e in ipairs(SCHED) do if r >= e[1] and r < e[2] then hold(e[3], true) end end
  end

  local pc = cpu.state["PC"].value
  if pcmin and pc >= pcmin - 0x40 and pc <= pcmax + 0x40 then
    if pc < pcmin then pcmin = pc end; if pc > pcmax then pcmax = pc end
    pcrun = pcrun + 1
  else pcmin, pcmax, pcrun = pc, pc, 1 end
  if pcrun >= 90 then
    done = true
    log("")
    log("*** HANG: pc parked in %08X..%08X for %d frames", pcmin, pcmax, pcrun)
    log("    %s", st())
    log("    A0=%08X A1=%08X A2=%08X A8=%08X A13=%08X", cpu.state["A0"].value,
        cpu.state["A1"].value, cpu.state["A2"].value, cpu.state["A8"].value,
        cpu.state["A13"].value)
  end
end)
