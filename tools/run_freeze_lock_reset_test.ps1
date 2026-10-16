param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "freeze_lock_reset_test.lua"
$Log = Join-Path $ToolsDir "freeze_lock_reset_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:FLOCK_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[flock] does touching the ground reset Sub-Zero's air-freeze lock ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "freeze_lock_reset_mame.log") } finally { Pop-Location }
Remove-Item "Env:\FLOCK_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== AIR-FREEZE LOCK RESET ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "fight start|RESULT |PASS |FAIL |poisoned|landed|cleared while|never left|MISSING|ERROR" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
