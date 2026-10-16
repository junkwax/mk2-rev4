# Runs tools/hud_pixblt_test.lua: the PIXBLT B,XY HUD text pass
# (doc/UNUSED_GRAPHICS_PRIMITIVES.md S3).
param(
    [int]$TimeoutSec = 300,
    [switch]$KeepLog
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $PSScriptRoot "hud_pixblt_test.log"
$snap = Join-Path $root "tmp\hud_pixblt_snaps"

if (-not $KeepLog -and (Test-Path $log)) { Remove-Item $log -Force }
New-Item -ItemType Directory -Force -Path $snap | Out-Null

$env:HUD_LOG = ($log -replace '\\', '/')

& (Join-Path $PSScriptRoot "run_mame_small.ps1") `
    -Script (Join-Path $PSScriptRoot "hud_pixblt_test.lua") `
    -SnapshotDirectory $snap `
    -OutputDirectory (Join-Path $root "tmp") `
    -NoSound -NoThrottle -Wait -AutoCloseSeconds $TimeoutSec

Write-Host ""
if (Test-Path $log) {
    Get-Content $log
} else {
    Write-Warning "no log at $log - MAME never reached the script"
}
Write-Host ""
Write-Host "snapshots: $snap"
