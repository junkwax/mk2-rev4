$ErrorActionPreference = "Stop"
$Mame = "C:\MAME\mame.exe"
$Tools = "C:\Users\you\Workplace\mk2-main\tools"
$env:PROBE_LOG = Join-Path $Tools "switch_probe.log"
Remove-Item -LiteralPath $env:PROBE_LOG -Force -ErrorAction SilentlyContinue
Push-Location (Split-Path -Parent $Mame)
try {
  & $Mame -rompath "C:\Users\you\Workplace\mk2-main\rom" mk2 -window -nomaximize -resolution 640x480 `
      -video gdi -keyboardprovider win32 -skip_gameinfo -sound none `
      -autoboot_script (Join-Path $Tools "switch_probe.lua") -seconds_to_run 40 *> (Join-Path $Tools "switch_probe_mame_out.log")
} finally { Pop-Location; Remove-Item Env:\PROBE_LOG -ErrorAction SilentlyContinue }
Get-Content (Join-Path $Tools "switch_probe.log")
