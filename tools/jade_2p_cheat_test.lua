-- jade_2p_cheat_test.lua
-- Runtime trace of the P2 Jade unlock: at the 2P select screen, force P2 to
-- hover Mileena and pulse P2 Low Kick 5x; watch c_jade_cheat2 / f_jade_cheat2
-- advance, then confirm and check p2_char becomes ft_jade after select.
-- The P1/P2 code paths look identical on inspection, so this pins down whether
-- the P2 counter is actually reached at runtime.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local P = tonumber(os.getenv("JADE2P_PLAYER") or "2")   -- which player runs the cheat
local OTHER = (P == 1) and 2 or 1
local LOG = os.getenv("JADE2P_LOG") or (ROOT .. "/tools/jade_2p_cheat_test.log")
local logfh = io.open(LOG, "w")
local frame = 0
local raw = print
print = function(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end
  local l=table.concat(t,"\t"); raw(l); if logfh then logfh:write(l,"\n"); logfh:flush() end end
local function log(f,...) print("[jade2p] "..(select("#",...)>0 and string.format(f,...) or tostring(f))) end

local symbols = {}
do local fh=io.open(ROOT.."/src/mk2.map","r")
  if fh then for line in fh:lines() do for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n]=tonumber(a,16) end end fh:close() end end
local function sym(n,fb) local v=symbols[n]; if v then return v end; log("WARN missing %s",n); return fb end

local A = {
  gstate     = sym("gstate", 0),
  my_char    = sym("p"..P.."_char", 0),
  c_cheat    = sym("c_jade_cheat"..P, 0),
  f_cheat    = sym("f_jade_cheat"..P, 0),
  f_lk_held  = sym("f_jade_lk_held"..P, 0),
}
local LK_FIELD = "P"..P.." Low Kick"
local LP_FIELD = "P"..P.." Low Punch"
local OTHER_LP = "P"..OTHER.." Low Punch"
log("TESTING PLAYER %d (cheat), confirming player %d", P, OTHER)
local GS_PSEL = 4
local FT_FN2, FT_JADE = 5, 16

local cpu, space, fields = nil, nil, {}
local last_gs = -1
local psel_frame = 0
local pulse_start = 0
local pulses_done = 0
local last_count = -1
local phase = "boot"
local result_logged = false
local left_psel_frame = 0
local last_mc, last_fc = -1, -1

local function r16(a) return space:read_u16(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end

local function cache_fields()
  local want = { ["Coin 1"]=1,["Coin 2"]=1,["2 Players Start"]=1,
    [LK_FIELD]=1,[LP_FIELD]=1,[OTHER_LP]=1 }
  for _,port in pairs(manager.machine.ioport.ports) do
    for _,f in pairs(port.fields) do if want[f.name] then fields[f.name]=f end end end
  for n in pairs(want) do log("input %-18s %s", n, fields[n] and "ok" or "MISSING") end
end

local pressed = {}
local function hold(name, on) pressed[name] = on and true or false end

emu.register_frame(function()
  frame = frame + 1
  if frame == 1 then
    cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
    cache_fields()
    log("symbols c_cheat=0x%08x f_cheat=0x%08x p%d_char=0x%08x", A.c_cheat, A.f_cheat, P, A.my_char)
  end
  if not space then return end

  local gs = r16(A.gstate)
  if gs ~= last_gs then log("gstate %d->%d frame=%d", last_gs, gs, frame); last_gs = gs
    if gs == GS_PSEL and psel_frame == 0 then psel_frame = frame; log("select reached frame=%d", frame) end
  end

  -- boot: coin both + 2P start until select
  if psel_frame == 0 then
    hold("Coin 1", frame>=200 and frame<3000 and (frame%80)<20)
    hold("Coin 2", frame>=240 and frame<3000 and (frame%80)>=20 and (frame%80)<40)
    hold("2 Players Start", frame>=300 and frame<3000 and (frame%80)>=45 and (frame%80)<70)
  else
    -- at select: give it a moment, then run the P2 LK cheat
    local rel = frame - psel_frame
    if rel == 60 then
      pulse_start = frame; phase = "pulsing"
      log("begin P%d LK cheat: forcing hover Mileena, pulsing %s 5x", P, LK_FIELD)
    end
    if phase == "pulsing" then
      -- keep the tested player hovering Mileena so check_jade_lk_cheat sees ft_fn2
      w16(A.my_char, FT_FN2)
      local p = frame - pulse_start
      local cyc = p % 10
      local idx = p // 10
      if idx < 5 then
        hold(LK_FIELD, cyc < 5)
      else
        hold(LK_FIELD, false)
        if phase ~= "done_pulsing" then
          phase = "done_pulsing"
          log("pulses complete: c_cheat=%d f_cheat=%d f_lk_held=%d",
            r16(A.c_cheat), r16(A.f_cheat), r16(A.f_lk_held))
        end
      end
      local c = r16(A.c_cheat)
      if c ~= last_count then log("  c_cheat=%d (frame=%d)", c, frame); last_count = c end
    end
    -- after pulsing, confirm the OTHER player so select can finish; watch my_char
    if phase == "done_pulsing" and (frame - pulse_start) > 70 then
      hold(LP_FIELD, ((frame)%20) < 8)
      hold(OTHER_LP, ((frame)%20) < 8)
    end
  end

  -- once we leave select, poll for the apply (jade_select_cheat_apply runs a
  -- few frames after player_select returns, which may be after gs leaves psel)
  if psel_frame > 0 and phase == "done_pulsing" and gs ~= GS_PSEL then
    if left_psel_frame == 0 then
      left_psel_frame = frame
      log("left select frame=%d gs=%d; polling for apply...", frame, gs)
    end
    local mc = r16(A.my_char)
    local fc = r16(A.f_cheat)
    if mc ~= last_mc or fc ~= last_fc then
      log("  poll rel=%d p%d_char=%d f_cheat=%d gs=%d", frame-left_psel_frame, P, mc, fc, gs)
      last_mc, last_fc = mc, fc
    end
    if mc == FT_JADE and not result_logged then
      result_logged = true
      log("PASS jade_cheat_p%d: player %d became Jade at rel=%d", P, P, frame-left_psel_frame)
      log("finished"); manager.machine:exit()
    elseif frame - left_psel_frame > 200 and not result_logged then
      result_logged = true
      log("FAIL jade_cheat_p%d: player %d stayed %d (f_cheat=%d) 200f after select", P, P, mc, fc)
      log("finished"); manager.machine:exit()
    end
  end

  for name,f in pairs(fields) do f:set_value(pressed[name] and 1 or 0) end

  if frame > 6000 then log("FAIL timeout phase=%s psel=%d c=%d", phase, psel_frame, r16(A.c_cheat)); log("finished"); manager.machine:exit() end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
