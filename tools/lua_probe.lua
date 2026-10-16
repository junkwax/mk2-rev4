-- Read live body object coords + flags (BIT addresses).
local logf = io.open("C:/Users/you/Workplace/mk2-main/tmp/dp/probe.log","w")
local function lg(s) print(s); if logf then logf:write(s.."\n"); logf:flush() end end
local sp
pcall(function() sp = manager.machine.devices[":maincpu"].spaces["program"] end)
local function i16(v) return v>=0x8000 and v-0x10000 or v end
local frame=0
emu.register_frame_done(function()
  frame=frame+1
  if frame % 60 ~= 0 then return end
  if not sp then return end
  local body = sp:read_u32(0x01131E30)   -- hp_body_ptr[0] (obj bit addr)
  local ctr  = sp:read_u16(0x01131E60)   -- autodrop counter
  local line = string.format("f=%d ctr=%d body=0x%08X", frame, ctr, body)
  if body ~= 0 then
    local ox = i16(sp:read_u16(body + 0x90))   -- oxpos
    local oy = i16(sp:read_u16(body + 0xB0))   -- oypos
    local oz = i16(sp:read_u16(body + 0xD0))   -- ozpos
    local fl = sp:read_u16(body + 0xF0)        -- oflags
    line = line .. string.format(" ox=%d oy=%d oz=%d flags=0x%04X", ox, oy, oz, fl)
  end
  lg(line)
end)
lg("probe3 loaded")
