param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 260
)
# Regression net for "the CPU holds one frame while it keeps sliding", and
# for the difficulty-dependent animation rate that caused it. See the header
# of drone_walk_fluidity_test.lua.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_walk_fluidity_test.lua"
$Log = Join-Path $ToolsDir "drone_walk_fluidity_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:FLUIDITY_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[fluid] measuring drone walk animation holds at diff 0 and diff 9 ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_walk_fluidity_mame.log") } finally { Pop-Location }
Remove-Item "Env:\FLUIDITY_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== DRONE WALK FLUIDITY ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "MISSING|ERROR|fight start|done:|RESULT|PASS |FAIL |  " |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
