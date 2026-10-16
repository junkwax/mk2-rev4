-- drone_move_census.lua - which moves does the CPU actually USE, per fighter?
--
-- Rides the fly rig as FB_ADDON. Pins the CPU (player 2) to CENSUS_CHAR (an ochar) every
-- round intro, and tallies every action code the drone enters. Writes
-- <FB_OUT>/drone_census.csv (ochar, worn, act, count), rewritten every 600 frames so a
-- killed run still leaves a result.
--
-- WHY. A special is only in the CPU's repertoire if something in MKDRONE calls it -
-- zap_offsets, ochar_duck_special, ochar_punish, ochar_antiair, air_zap_offsets, the
-- juggle scripts - and the secret fighters had nearly nothing there: Noob and Rain threw
-- Scorpion's spear and nothing else, which is exactly what the user saw. Reading the
-- tables says what COULD come out; this says what does.
--
-- KHAMELEON fights as whoever she is WEARING (kd_char_* index every drone table by
-- kham_guise's worn ochar), so her rows are counted per outfit: `worn` is her kham_guise
-- word (0 = her own, 1 Jade, 2 Kitana, 3 Mileena - kham_worn_ochars, MKDRONE.ASM). For
-- everyone else `worn` is -1.
--
-- FORCING THE CPU (tools/costume_test.lua's method, and its traps): write @p2_char AND
-- @p2_state = 0 while not fighting. setup_players reads @p2_char in the ROUND INTRO, so
-- pinning only on the select screen lets the ladder pick its own opponent; and forcing
-- p2_char makes the game think player 2 is present, so without p2_state = 0 he comes up
-- as a human with nobody on the stick.
local MAP = os.getenv("FB_MAP") or "C:/Users/you/Workplace/mk2-main/src/mk2.map"
local OUT = (os.getenv("FB_OUT") or "C:/tmp/flybrain/play") .. "/drone_census.csv"
local TARGET = tonumber(os.getenv("CENSUS_CHAR") or "")
-- CENSUS_FLAG=<global .bss word>: two moves that share ONE action code and differ only in
-- a flag (Scorpion's teleports are both act_decoy; f_fwdtele says which way it flies).
-- Every special entered while that word is non-zero is ALSO counted as act "<code>*".
local FLAG = os.getenv("CENSUS_FLAG")
local GS_FIGHT = 2
local WANT = { [FLAG or "-"]=1, p1_bar=1, p2_proc=1, p2_obj=1, p2_char=1, p2_state=1, gstate=1, kham_guise=1, winner_status=1 }
local sym = {}
do
  local fh = io.open(MAP)
  if fh then
    for line in fh:lines() do
      for a, n in line:gmatch("(%x+)%s+([%w_]+)") do
        if WANT[n] and not sym[n] then sym[n] = tonumber(a, 16) end
      end
    end
    fh:close()
  end
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return a and space:read_u16(a) or 0 end
local function r32(a) return a and space:read_u32(a) or 0 end
local function w16(a, v) if a then space:write_u16(a, v) end end

local count, frames, frame, prev = {}, {}, 0, -1
-- which action each SPECIAL came FROM (prev -> act), for moves that share one action code
-- and differ only in where they start - Noob's shadow slide, kick and dive are all
-- act_noob_shadow, and the dive is the one entered from a jump.
local trans = {}
local flagged = {}      -- ochar:worn:act -> entries made with CENSUS_FLAG set
-- which specials LANDED: the other man's bar (p1_bar - the CPU is player 2) dropped within
-- LAND_WINDOW frames of the CPU entering that action. Written as act "<code>+". A hit from
-- anything else in that window counts too, so read it as an upper bound.
local landed, pend = {}, nil
local LAND_WINDOW = 60
local dur = {}          -- frames spent in each action (ochar:worn:act)
local WAKE = os.getenv("CENSUS_WAKE") == "1"
local wake = {}         -- pwake address -> standing frames spent asleep there
local function special(a) return a ~= 0 and (a >> 8) <= 0x02 end

local function dump()
  local fh = io.open(OUT, "w")
  if not fh then return end
  fh:write("ochar,worn,act,count,fight_frames\n")
  for key, n in pairs(count) do
    local oc, worn, act = key:match("^(%-?%d+):(%-?%d+):(%d+)$")
    fh:write(string.format("%s,%s,%04x,%d,%d\n", oc, worn, tonumber(act), n, frames[oc .. ":" .. worn] or 0))
  end
  for key, n in pairs(trans) do
    local oc, worn, from, to = key:match("^(%-?%d+):(%-?%d+):(%d+)>(%d+)$")
    fh:write(string.format("%s,%s,%04x>%04x,%d,%d\n", oc, worn, tonumber(from), tonumber(to), n,
      frames[oc .. ":" .. worn] or 0))
  end
  for key, n in pairs(landed) do
    local oc, worn, act = key:match("^(%-?%d+):(%-?%d+):(%d+)$")
    fh:write(string.format("%s,%s,%04x+,%d,%d\n", oc, worn, tonumber(act), n, frames[oc .. ":" .. worn] or 0))
  end
  for key, n in pairs(flagged) do
    local oc, worn, act = key:match("^(%-?%d+):(%-?%d+):(%d+)$")
    fh:write(string.format("%s,%s,%04x*,%d,%d\n", oc, worn, tonumber(act), n, frames[oc .. ":" .. worn] or 0))
  end
  fh:close()
  local dh = io.open(OUT:gsub("%.csv$", "_time.csv"), "w")
  if dh then
    dh:write("ochar,worn,act,frames\n")
    for key, n in pairs(dur) do
      local oc, worn, act = key:match("^(%-?%d+):(%-?%d+):(%d+)$")
      dh:write(string.format("%s,%s,%04x,%d\n", oc, worn, tonumber(act), n))
    end
    dh:close()
  end
  if WAKE then
    local wh = io.open(OUT:gsub("%.csv$", "_wake.csv"), "w")
    if wh then
      wh:write("pwake,stacktop,frames\n")
      for k, n in pairs(wake) do
        local a, t = k:match("^(%x+):(%x+)$")
        wh:write(string.format("%s,%s,%d\n", a, t, n))
      end
      wh:close()
    end
  end
end

DRONE_CENSUS_HANDLE = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local gs = r16(sym.gstate)
  if TARGET and gs ~= GS_FIGHT then
    w16(sym.p2_char, TARGET)
    w16(sym.p2_state, 0)
  end
  if gs ~= GS_FIGHT or r16(sym.winner_status) ~= 0 then prev = -1 pend = nil return end
  if pend then
    if r16(sym.p1_bar) < pend.bar then
      landed[pend.key] = (landed[pend.key] or 0) + 1
      pend = nil
    elseif frame - pend.f0 > LAND_WINDOW then pend = nil end
  end
  local dp, dobj = r32(sym.p2_proc), r32(sym.p2_obj)
  if dp == 0 or dobj == 0 then return end
  local oc = r16(dobj + 0x1f0)                    -- ochar (object block)
  local act = r16(dp + 0x1f0)                     -- p_action (process block)
  local worn = -1
  if oc == 18 and sym.kham_guise then worn = r16(sym.kham_guise + 16) end   -- p2's word
  local fk = oc .. ":" .. worn
  frames[fk] = (frames[fk] or 0) + 1
  -- how LONG each action lasts, not just how often it starts: where the CPU's fighting
  -- time goes (standing, walking, attacking, reacting) is what a tempo change must move
  local dk = fk .. ":" .. act
  dur[dk] = (dur[dk] or 0) + 1
  -- CENSUS_WAKE=1: while the drone STANDS (act_stance 0303h), which routine is its process
  -- asleep in? pwake (MAINEQU, 0e0h in the process block) is the resume address, and
  -- tallying it names the code that keeps the CPU idle. Resolve with a label table that
  -- matches THIS build (tools/art_ref_graph.py --assemble builds one) - the stripped map
  -- carries only globals, and most of MKDRONE is local labels.
  if WAKE and act == 0x0303 then
    -- ...and the top of its PROCESS stack (psptr 040h; jsrp pushes pre-decrement), which
    -- is the caller's return address while it sits in a shared helper such as mframew
    -- (mframew pushes its SLEEP TIME first, so its caller is the SECOND word, +32 bits)
    local sp = r32(dp + 0x40)
    local w = string.format("%08x:%08x", r32(dp + 0xe0), r32(sp + 32))
    wake[w] = (wake[w] or 0) + 1
  end
  if act ~= prev then
    local key = fk .. ":" .. act
    count[key] = (count[key] or 0) + 1
    if FLAG and sym[FLAG] and special(act) and r16(sym[FLAG]) ~= 0 then
      flagged[key] = (flagged[key] or 0) + 1
    end
    if special(act) then pend = { key = key, bar = r16(sym.p1_bar), f0 = frame } end
    if special(act) and prev >= 0 then
      local tk = fk .. ":" .. prev .. ">" .. act
      trans[tk] = (trans[tk] or 0) + 1
    end
    prev = act
  end
  if frame % 600 == 0 then dump() end
end)
