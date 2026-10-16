-- Dead Pool hanging body drop probe.
-- Uses TMS34010 bit addresses from src/MK2.MAP after the 2026-05-29 build.
-- This forces winner_status=3 briefly so production builds with
-- hanger_debug_autodrop=0 still exercise hp_drop_begin.

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/tmp/dp/codex_drop_probe.log"
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

local function i16(v)
  return v >= 0x8000 and v - 0x10000 or v
end

local B = {
  gstate = 0x01129DC0,
  curback = 0x0112B6C0,
  winner_status = 0x0112B700,
  hp_body_ptr = 0x01131E30,
  hp_splash_x = 0x01131E50,
  hp_autodrop_ctr = 0x01131E60,
  pc_chain_obj = 0x01131E70,
  pc_hook_obj = 0x01131EB0,
  acidbones1 = 0xFFBF4FC0,
  acidbones2 = 0xFFBF5050,
  acidbones3 = 0xFFBF50E0,
  acidbones4 = 0xFFBF5170,
}

local FORCE_FINISH_START = 360
local FORCE_FINISH_END = 420

local O = {
  oxpos = 0x90,
  oypos = 0xB0,
  ozpos = 0xD0,
  oflags = 0xF0,
  oflags2 = 0x160,
  oimg = 0x1A0,
  oid = 0x1C0,
}

local function img_name(v)
  if v == B.acidbones1 then return "ACIDBONES1" end
  if v == B.acidbones2 then return "ACIDBONES2" end
  if v == B.acidbones3 then return "ACIDBONES3" end
  if v == B.acidbones4 then return "ACIDBONES4" end
  return string.format("0x%08X", v)
end

local function obj_line(label, ptr)
  if ptr == 0 then return label .. "=null" end
  local ox = i16(sp:read_u16(ptr + O.oxpos))
  local oy = i16(sp:read_u16(ptr + O.oypos))
  local oz = i16(sp:read_u16(ptr + O.ozpos))
  local fl = sp:read_u16(ptr + O.oflags)
  local fl2 = sp:read_u16(ptr + O.oflags2)
  local oid = sp:read_u16(ptr + O.oid)
  local img = sp:read_u32(ptr + O.oimg)
  return string.format(
    "%s=0x%08X x=%d y=%d z=%d oid=0x%04X fl=0x%04X fl2=0x%04X img=%s",
    label, ptr, ox, oy, oz, oid, fl, fl2, img_name(img))
end

local frame = 0
emu.register_frame_done(function()
  frame = frame + 1
  if not sp then return end
  if frame % 30 ~= 0 then return end

  local gs = sp:read_u16(B.gstate)
  local cb = sp:read_u16(B.curback)
  local win = sp:read_u16(B.winner_status)
  if frame >= FORCE_FINISH_START and frame < FORCE_FINISH_END then
    sp:write_u16(B.winner_status, 3)
    win = 3
  end
  local body = sp:read_u32(B.hp_body_ptr)
  local splash_x = sp:read_u16(B.hp_splash_x)
  local ctr = sp:read_u16(B.hp_autodrop_ctr)
  local chain = sp:read_u32(B.pc_chain_obj)
  local hook = sp:read_u32(B.pc_hook_obj)

  local line = string.format(
    "f=%04d gs=%d cb=%d win=%d ctr=%d splash_x=%d %s %s %s",
    frame, gs, cb, win, ctr, splash_x,
    obj_line("body_slot", body),
    obj_line("p1_chain", chain),
    obj_line("p1_hook", hook))
  log(line)
end)

log("codex drop probe loaded")
