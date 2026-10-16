# run_behaviour_check.ps1 - measure the canonical interactions, compare to the lock.
#
# Section 8.2 of doc/TOURNAMENT_READINESS.md.  This is the third lock and the
# only one that needs the emulator, so it lives beside the stability sweep
# rather than in Phase D: balance.lock and hurtbox.lock guard the inputs to a
# move, this guards what the move actually does.
#
#   .\tools\run_behaviour_check.ps1            run and compare
#   .\tools\run_behaviour_check.ps1 -Freeze    run and re-freeze the lock
#
# The measurement is deterministic - two consecutive runs are byte-identical -
# so a diff is a real change, not noise.
param(
    [switch]$Freeze,
    [string]$Battle = "mirror_baraka"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$addon = Join-Path $root "tools\sweep_addon.lua"
$had = Test-Path $addon
if ($had) { Copy-Item $addon "$addon.behaviourbak" -Force }

try {
    Copy-Item (Join-Path $root "tools\sweep_addon_assert.lua") $addon -Force
    Remove-Item (Join-Path $root "tools\behaviour_run.txt") -Force -ErrorAction SilentlyContinue

    # P2Human so the dummy stands still instead of fighting back; NoHpPin so
    # damage is visible at all (the harness otherwise pins P1's bar full and
    # clears the winner, which silently zeroed two rigs before this one).
    & (Join-Path $root "tools\run_battle_stability_sweep.ps1") `
        -Only $Battle -Observe 1300 -Backstop 150 -P2Human -NoHpPin `
        *> (Join-Path $root "tools\behaviour_sweep.log")
}
finally {
    Remove-Item $addon -Force -ErrorAction SilentlyContinue
    if ($had) { Move-Item "$addon.behaviourbak" $addon -Force }
}

if ($Freeze) {
    python (Join-Path $root "tools\behaviour_lock.py")
} else {
    python (Join-Path $root "tools\behaviour_lock.py") --check
    exit $LASTEXITCODE
}
