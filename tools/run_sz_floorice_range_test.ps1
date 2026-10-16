param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200
)
# Measures how far Sub-Zero's ground freeze actually reaches. See the header
# of sz_floorice_range_test.lua for why (the stk_floor_ice box drift).
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "sz_floorice_range_test.lua"
$Log = Join-Path $ToolsDir "sz_floorice_range_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:ICE_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[ice] sweeping ground-freeze range ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "sz_floorice_range_mame.log") } finally { Pop-Location }
Remove-Item "Env:\ICE_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== GROUND FREEZE RANGE ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "MISSING|ERROR|fight start|RESULT|reach|PASS |FAIL |FROZE" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
