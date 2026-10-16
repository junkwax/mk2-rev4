# run_ab_bands.ps1 - measure connect bands for five moves on BOTH builds.
#
# The factual backbone for any public claim about what the collision work
# changed: same rig, same seed, same pinned distances, only the source state
# differs.  A move whose band does not move did not change.
#
# Leaves the tree in the AFTER state and the lock released, even on failure.
param(
    # 5 moves x 27 distances x 110 frames = 14850, plus ~1200 to boot and
    # select.  Must stay under the harness's 20000-frame global timeout or the
    # run is killed mid-measurement.
    [int]$Observe = 15500,
    [int]$Backstop = 340
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if (Test-Path tmp\BUILD.LOCK) {
    Write-Host "BUILD.LOCK held by:"; Get-Content tmp\BUILD.LOCK; exit 1
}
"mk2-main-db (A/B move bands)" | Set-Content tmp\BUILD.LOCK

Copy-Item tools\sweep_addon_bands.lua tools\sweep_addon.lua -Force
Remove-Item tools\move_bands_before.txt, tools\move_bands_after.txt `
    -Force -ErrorAction SilentlyContinue

try {
    foreach ($state in @("before", "after")) {
        Write-Host "`n===== $($state.ToUpper()) ====="
        python tools\ab_build.py $state
        python build.py --asm-only 2>&1 | Select-Object -Last 1
        Start-Sleep -Milliseconds 1500
        python makerom.py 2>&1 | Select-Object -Last 1
        python mamerom.py --source-video 2>&1 | Select-Object -Last 1
        $env:BANDS_TAG = $state
        & .\tools\run_battle_stability_sweep.ps1 -Only baraka_scorpion_swipe `
            -Observe $Observe -Backstop $Backstop -P2Human *> "tools\ab_bands_$state.log"
        Remove-Item Env:\BANDS_TAG -ErrorAction SilentlyContinue
    }
} finally {
    # always land back on the shipping state, whatever happened above
    python tools\ab_build.py after | Out-Null
    python tools\ab_build.py status | Select-Object -Last 2
    Remove-Item tools\sweep_addon.lua, tmp\BUILD.LOCK -Force -ErrorAction SilentlyContinue
}

Write-Host "`n===== BANDS ====="
foreach ($state in @("before", "after")) {
    $f = "tools\move_bands_$state.txt"
    if (Test-Path $f) { Get-Content $f | Where-Object { $_ -match "band |MISFIRED|^---" } |
        ForEach-Object { Write-Host "$state  $_" } }
    else { Write-Host "$state  NO OUTPUT" }
}
