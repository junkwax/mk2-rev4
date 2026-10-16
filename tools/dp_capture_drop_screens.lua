-- Capture Dead Pool hanging-body drop frames from the current ROM.
-- Uses raw TMS34010 bit addresses for this MAME Lua provider.

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/tmp/dp/drop_capture.log"
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

local A = {
  winner_status = 0x0112B700,
  p1_obj = 0x01129E10,
  p2_obj = 0x0112A9E0,
  hanger_coords = 0x01131E10,
}

local NHANGERS = 2

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

A.winner_status = map_symbol("winner_status", A.winner_status)
A.p1_obj = map_symbol("p1_obj", A.p1_obj)
A.p2_obj = map_symbol("p2_obj", A.p2_obj)
A.hanger_coords = map_symbol("hanger_coords", A.hanger_coords)
A.hp_body_ptr = A.hanger_coords + (NHANGERS * 32)

local O = {
  oxval = 0x80,
  oxpos = 0x90,
  oyval = 0xA0,
  oypos = 0xB0,
  ozpos = 0xD0,
  oflags2 = 0x160,
  oimg = 0x1A0,
}

local function i16(v)
  return v >= 0x8000 and v - 0x10000 or v
end

local snap_at = {
  [360] = "trigger",
  [384] = "drip_start",
  [390] = "fall_mid",
  [402] = "drip_mid",
  [420] = "fall_low",
  [450] = "impact",
  [470] = "bubble_one",
  [494] = "bubble_two",
  [518] = "bubble_three",
  [560] = "skeleton_below_acid",
  [590] = "skeleton_first_break",
  [620] = "skeleton_head_out",
  [668] = "skeleton_shoulders",
  [720] = "skeleton_torso",
  [780] = "skeleton_lift_mid",
  [860] = "skeleton_legs_clear",
  [980] = "skeleton_drag",
  [1120] = "skeleton_original_y",
}

local frame = 0
emu.register_frame_done(function()
  frame = frame + 1
  if not sp then return end

  -- Photo-mode placement: keep the hanger centered and slide fighters aside
  -- so the falling body/skeleton is visible in the snapshots.
  if frame >= 90 and frame < 1040 then
    sp:write_u16(A.hanger_coords, 100)
    sp:write_u16(A.hanger_coords + 16, 30)
    sp:write_u16(A.hanger_coords + 32, 214)
    sp:write_u16(A.hanger_coords + 48, 30)

    local p1 = sp:read_u32(A.p1_obj)
    if p1 ~= 0 then
      sp:write_u32(p1 + O.oxval, 25 << 16)
      sp:write_u16(p1 + O.oxpos, 25)
    end

    local p2 = sp:read_u32(A.p2_obj)
    if p2 ~= 0 then
      sp:write_u32(p2 + O.oxval, 380 << 16)
      sp:write_u16(p2 + O.oxpos, 380)
    end
  end

  if frame >= 360 and frame < 420 then
    sp:write_u16(A.winner_status, 3)
  end

  local tag = snap_at[frame]
  if tag then
    local function body_detail(slot)
      local body = sp:read_u32(A.hp_body_ptr + (slot * 32))
      if body == 0 then return string.format("body%d=null", slot) end
      return string.format(
        "body%d=0x%08X x=%d y=%d fl2=0x%04X img=0x%08X",
        slot,
        body,
        i16(sp:read_u16(body + O.oxpos)),
        i16(sp:read_u16(body + O.oypos)),
        sp:read_u16(body + O.oflags2),
        sp:read_u32(body + O.oimg))
    end
    local detail = body_detail(0) .. " " .. body_detail(1)
    log(string.format("snapshot frame=%d tag=%s %s", frame, tag, detail))
    manager.machine.video:snapshot()
  end
end)

log("drop capture loaded")
