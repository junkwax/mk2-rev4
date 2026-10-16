param(
    # NOT mame_mk2test.exe: that name exists so automated sweeps do not kill
    # each other. This is an interactive session, so use the normal binary.
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\MAME\roms",
    [string]$Resolution = "1280x800",
    [int]$Max = 9000,           # ~2.7 min at 54.7Hz; roughly 450 MB of PNGs
    [int]$Start = 1,
    [switch]$KeepOldShots
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua  = Join-Path $Tools "umk3_observe.lua"
$Log  = Join-Path $Tools "umk3_observe.log"
$Snap = "C:\MAME\snap\umk3"

if (-not $KeepOldShots) {
    Remove-Item "$Snap\*.png" -Force -ErrorAction SilentlyContinue
    Write-Host "[obs] cleared $Snap so numbering starts at 0000"
}
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:U3_LOG = $Log; $env:U3_MAX = [string]$Max; $env:U3_START = [string]$Start

Write-Host ""
Write-Host "  UMK3 - passive capture. Nothing is driven for you, and there is"
Write-Host "  NO trigger key: it records from the moment it starts."
Write-Host ""
Write-Host "  1. Coin up and start, pick ERMAC (row 2, third tile)."
Write-Host "  2. Do Back, Down, Back + High Kick two or three times."
Write-Host "  3. Close MAME."
Write-Host ""
Write-Host "  It will feel sluggish - that is PNG encoding 55x a second, and it"
Write-Host "  does NOT affect the capture, which stays frame-exact."
Write-Host ""

Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame -rompath $RomPath umk3 -window -nomaximize -resolution $Resolution `
        -keyboardprovider win32 -skip_gameinfo -autoboot_script $Lua
} finally {
    Pop-Location
    Remove-Item Env:\U3_LOG,Env:\U3_MAX,Env:\U3_START -ErrorAction SilentlyContinue
}

$f = Get-ChildItem "$Snap\*.png" -ErrorAction SilentlyContinue
$mb = if ($f) { [math]::Round(($f | Measure-Object Length -Sum).Sum / 1MB, 1) } else { 0 }
Write-Host ""
Write-Host "[obs] $($f.Count) frames captured in $Snap ($mb MB)"
if (Test-Path $Log) { Get-Content $Log | Select-Object -Last 4 }
