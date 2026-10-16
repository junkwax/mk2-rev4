param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 300
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "sz_airice_freeze_test.lua"
$Log = Join-Path $ToolsDir "sz_airice_freeze_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $Mame)) { $Mame = "C:\MAME\mame.exe" }

$env:AIRICE_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[airice] air ice vs airborne victim ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "sz_airice_freeze_mame.log") } finally { Pop-Location }
Remove-Item "Env:\AIRICE_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== SZ AIR ICE vs AIRBORNE VICTIM ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "RESULT|   air_|   ground_|CAST|HIT|FROZE|---- trial|fight start|MISSING|ERROR" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
