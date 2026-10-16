param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "sz_airice_flight_probe.lua"
$Log = Join-Path $ToolsDir "sz_airice_flight_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $Mame)) { $Mame = "C:\MAME\mame.exe" }

$env:AIRICEF_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[flight] tracking the ice projectile ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "sz_airice_flight_mame.log") } finally { Pop-Location }
Remove-Item "Env:\AIRICEF_LOG" -ErrorAction SilentlyContinue
Write-Host "Full log: $Log"
