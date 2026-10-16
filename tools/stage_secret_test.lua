-- stage_secret_test.lua
-- WAFFLE HOUSE is off the VS stage cycle and off match_stage_cycle; the only
-- way onto it is the auto-select code: let the two-second stage timer run out
-- on THE DEAD POOL with BOTH players holding Down.
--
-- STAGE_MODE:
--   secret - hold both Down at the timeout on Dead Pool -> curback must be 017h
--   none   - hold nothing                               -> curback must stay 0
--   pong   - force curback=016h, hold both Up           -> Pong must still run
--            (regression on the Outer Haven code, which moved behind a branch)
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local MODE = os.getenv("STAGE_MODE") or "secret"
local LOG  = os.getenv("STAGE_LOG") or (ROOT .. "/tools/stage_secret_test.log")
local SHOT = os.getenv("STAGE_SHOT")

local logfh = io.open(LOG, "w")
local raw = print
print = function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
  local l = table.concat(t, "\t"); raw(l)
  if logfh then logfh:write(l, "\n"); logfh:flush() end
end
local function log(f, ...) print("[stage] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f))) end

local symbols = {}
do
  local fh = io.open(ROOT .. "/src/mk2.map", "r")
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
  end
end
local A = { gstate = symbols["gstate"], curback = symbols["curback"],
            p1_char = symbols["p1_char"], p2_char = symbols["p2_char"],
            p1_state = symbols["p1_state"], p2_state = symbols["p2_state"] }
local SWITCH, SWITCH2 = 0x01600000, 0x01600020

local GS_PSEL, GS_FIGHTING, GS_PFSETUP, GS_ROUND_INTRO = 4, 2, 6, 7
local WAFFLE, OUTER_HAVEN = 0x17, 0x16

local space, fields = nil, {}
local held = {}
local frame, psel, vs, done = 0, 0, 0, false
local fight = 0
local last_gs, last_cb = -1, -1
local saw_waffle = false

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function hold(n, on) held[n] = on and true or false end

local function cache()
  local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                 ["P1 Low Punch"]=1, ["P2 Low Punch"]=1,
                 ["P1 Down"]=1, ["P2 Down"]=1, ["P1 Up"]=1, ["P2 Up"]=1 }
  for _, p in pairs(manager.machine.ioport.ports) do
    for _, fld in pairs(p.fields) do if want[fld.name] then fields[fld.name] = fld end end
  end
  for n in pairs(want) do log("input %-18s %s", n, fields[n] and "ok" or "MISSING") end
end

local function snap()
  if not SHOT then return end
  local ok, err = pcall(function() manager.machine.video:snapshot() end)
  log("snapshot %s", ok and "taken" or ("failed: " .. tostring(err)))
end

local function finish(verdict, f, ...)
  if done then return end
  done = true
  snap()
  log("%s %s", verdict, select("#", ...) > 0 and string.format(f, ...) or tostring(f))
  log("finished")
  manager.machine:exit()
end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    space = manager.machine.devices[":maincpu"].spaces["program"]
    cache()
    log("MODE=%s curback=0x%08x gstate=0x%08x", MODE, A.curback or 0, A.gstate or 0)
  end
  if not space or done then return end

  local gs = r16(A.gstate)
  local cb = r16(A.curback)
  if gs ~= last_gs then log("frame=%-6d gstate=%d curback=%d", frame, gs, cb); last_gs = gs end
  if cb ~= last_cb then
    log("frame=%-6d curback=%d (gstate=%d switch=%08x p1_state=%d p2_state=%d)",
        frame, cb, gs, (~space:read_u32(SWITCH)) & 0xffffffff,
        r16(A.p1_state), r16(A.p2_state))
    last_cb = cb
  end
  if cb == WAFFLE then saw_waffle = true end

  if gs == GS_PSEL and psel == 0 then psel = frame; log("player select reached frame=%d", frame) end

  if psel == 0 then
    -- boot: coin both sides, 2P start
    hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
    hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
    hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
    hold("UI Select", frame >= 5 and frame < 35)
  elseif vs == 0 then
    -- player select: park both on Liu Kang and confirm with Low Punch
    w16(A.p1_char, 1); w16(A.p2_char, 1)
    local rel = frame - psel
    if rel > 40 then
      hold("P1 Low Punch", (frame % 20) < 8)
      hold("P2 Low Punch", (frame % 20) < 8)
    end
    if rel > 40 and gs ~= GS_PSEL then
      vs = frame
      -- release EVERYTHING: a coin or start left held from the boot schedule
      -- sits in @switch all the way through the stage select and moves the
      -- cursor off the arena the code is keyed to.
      for n in pairs(held) do held[n] = false end
      log("left player select frame=%d gstate=%d curback=%d p1_state=%d p2_state=%d -> VS screen",
          frame, gs, cb, r16(A.p1_state), r16(A.p2_state))
    end
    if rel > 1200 then finish("NO-VERDICT", "never left player select (gstate=%d)", gs) end
  else
    -- VS screen: run the code for this mode
    local rel = frame - vs
    if MODE == "secret" then
      hold("P1 Down", true); hold("P2 Down", true)
      if saw_waffle and (gs == GS_PFSETUP or gs == GS_ROUND_INTRO or gs == GS_FIGHTING) then
        if cb ~= WAFFLE then
          finish("FAIL", "curback was reset to %d after the secret (gstate=%d)", cb, gs)
        elseif gs == GS_FIGHTING then
          -- let the round intro clear so the snapshot is the arena itself
          if fight == 0 then fight = frame end
          if frame - fight > 150 then
            finish("PASS", "secret took: curback=%d (WAFFLE HOUSE) fighting at rel=%d", cb, rel)
          end
        end
      end
      if rel > 1200 then
        finish("FAIL", "timeout rel=%d curback=%d gstate=%d saw_waffle=%s",
               rel, cb, gs, tostring(saw_waffle))
      end
    elseif MODE == "none" then
      if gs == GS_PFSETUP or gs == GS_ROUND_INTRO or gs == GS_FIGHTING then
        if cb == 0 then finish("PASS", "no code held: curback stayed %d into gstate=%d at rel=%d", cb, gs, rel)
        else finish("FAIL", "curback drifted to %d with nothing held (gstate=%d)", cb, gs) end
      end
      if rel > 900 then finish("NO-VERDICT", "timeout rel=%d curback=%d gstate=%d", rel, cb, gs) end
    elseif MODE == "pong" then
      if rel < 30 then w16(A.curback, OUTER_HAVEN) end
      hold("P1 Up", true); hold("P2 Up", true)
      -- Pong parks at pong_wait_start until a button is pressed, so the fight
      -- must NOT start.  The control for this is MODE=none, which does.
      if gs == GS_PFSETUP or gs == GS_ROUND_INTRO or gs == GS_FIGHTING then
        finish("FAIL", "fight started at rel=%d (gstate=%d) - Pong did not run", rel, gs)
      end
      if rel > 600 then
        finish("PASS", "still on the VS screen at rel=%d (gstate=%d curback=%d) - parked in Pong", rel, gs, cb)
      end
    else
      finish("NO-VERDICT", "unknown STAGE_MODE=%s", MODE)
    end
  end

  for n, fld in pairs(fields) do fld:set_value(held[n] and 1 or 0) end
end)
