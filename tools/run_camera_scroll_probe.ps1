param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 160
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "camera_scroll_probe.lua"
$Log = Join-Path $ToolsDir "camera_scroll_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:CAMPROBE_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[cam] sweeping a parked fighter through the scroll barrier band ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "camera_scroll_probe_mame.log") } finally { Pop-Location }
Remove-Item "Env:\CAMPROBE_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== Y-SCROLL CONTROLLER RESPONSE ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "fight start|worldtly at rest|== parked|victim oypos|PASS |FAIL |MISSING|ERROR|parking not holding|ceiling_y=|scroll-up limit|settled|HUNTING|verdict|^\[cam\] (victim|oypos)" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
