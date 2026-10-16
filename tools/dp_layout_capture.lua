-- Capture the current fixed Dead Pool hanger layout and first drop/rise.
-- Uses raw TMS34010 bit addresses for this MAME Lua provider.

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/tmp/dp/layout_capture.log"
local logf = io.open(LOG_PATH, "w")

local function log(s)
  print(s)
  if logf then
    logf:write(s .. "\n")
    logf:flush()
  end
end

local sp
pcall(function()
  sp = manager.machine.devices[":maincpu"].spaces["program"]
end)

local function map_symbol(name, fallback)
  local f = io.open("C:/Users/you/Workplace/mk2-main/src/mk2.map", "r")
  if not f then return fallback end
  for line in f:lines() do
    for addr, sym in line:gmatch("([0-9A-Fa-f]+)%s+([_%w]+)") do
      if sym == name then
        f:close()
        return tonumber(addr, 16)
      end
    end
  end
  f:close()
  return fallback
end

local NHANGERS = 9
local A = {
  gstate = map_symbol("gstate", 0x01129DC0),
  curback = map_symbol("curback", 0x0112B6C0),
  winner_status = map_symbol("winner_status", 0x0112B700),
  hanger_coords = map_symbol("hanger_coords", 0x01131E10),
}
A.hp_body_ptr = A.hanger_coords + (NHANGERS * 32)
A.hp_autodrop_ctr = A.hanger_coords + (NHANGERS * 32) + (NHANGERS * 32)
  + (NHANGERS * 16) + (NHANGERS * 16) + (NHANGERS * 16)
  + (NHANGERS * 16) + (NHANGERS * 32) + (NHANGERS * 16)
A.hp_dropped = A.hp_autodrop_ctr + (NHANGERS * 16)

local O = {
  oxpos = 0x90,
  oypos = 0xB0,
  ozpos = 0xD0,
  oimg = 0x1A0,
}

local function i16(v)
  return v >= 0x8000 and v - 0x10000 or v
end

local snap_at = {
  [120] = "layout_init",
  [720] = "first_drop_ready",
  [780] = "first_body_hidden",
  [960] = "first_skeleton_break",
  [1080] = "first_skeleton_mid",
  [1260] = "first_skeleton_home_second_drop",
  [1500] = "second_skeleton_break",
  [1680] = "second_skeleton_home",
  [1980] = "third_skeleton_break",
  [2220] = "third_skeleton_home_fourth_drop",
}

local frame = 0
emu.register_frame_done(function()
  frame = frame + 1
  if not sp then return end

  local tag = snap_at[frame]
  if not tag then return end

  local parts = {}
  for i = 0, NHANGERS - 1 do
    local ptr = sp:read_u32(A.hp_body_ptr + (i * 32))
    local ctr = sp:read_u16(A.hp_autodrop_ctr + (i * 16))
    local dropped = sp:read_u16(A.hp_dropped + (i * 16))
    if ptr ~= 0 then
      parts[#parts + 1] = string.format(
        "s%d ctr=%d drop=%d x=%d y=%d z=%d img=0x%08X",
        i,
        ctr,
        dropped,
        i16(sp:read_u16(ptr + O.oxpos)),
        i16(sp:read_u16(ptr + O.oypos)),
        i16(sp:read_u16(ptr + O.ozpos)),
        sp:read_u32(ptr + O.oimg))
    else
      parts[#parts + 1] = string.format("s%d ctr=%d drop=%d null", i, ctr, dropped)
    end
  end

  log(string.format(
    "snapshot frame=%d tag=%s gs=%d cb=%d win=%d %s",
    frame,
    tag,
    sp:read_u16(A.gstate),
    sp:read_u16(A.curback),
    sp:read_u16(A.winner_status),
    table.concat(parts, " | ")))
  manager.machine.video:snapshot()
end)

log("layout capture loaded")
