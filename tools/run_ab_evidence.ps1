# run_ab_evidence.ps1 - collect before/after evidence for a public write-up.
#
# Two builds, three measurements each, all deterministic:
#
#   column/sweep   the exact rectangle the hit compare used, victim mid-sweep
#   column/swipe   same, victim mid-blade-swipe
#   shots/swipe    screenshots of Baraka's Back+HP with the box overlay on
#
# The column runs read bx_list out of RAM rather than counting hits, so they
# need no trial cadence and cannot be defeated by a move's recovery - which is
# what sank the five-move band rig.
#
# Leaves the tree in the AFTER state and the lock released, whatever happens.
param(
    [int]$Observe = 1400,
    [int]$Backstop = 90
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if (Test-Path tmp\BUILD.LOCK) {
    Write-Host "BUILD.LOCK held by:"; Get-Content tmp\BUILD.LOCK; exit 1
}
"mk2-main-db (A/B evidence capture)" | Set-Content tmp\BUILD.LOCK
Remove-Item tools\column_*.txt, tools\shots_*.txt -Force -ErrorAction SilentlyContinue
$snapMap = @{}

try {
    foreach ($state in @("before", "after")) {
        Write-Host "`n========== $($state.ToUpper()) =========="
        python tools\ab_build.py $state
        python build.py --asm-only 2>&1 | Select-Object -Last 1
        Start-Sleep -Milliseconds 1500
        python makerom.py 2>&1 | Select-Object -Last 1
        python mamerom.py --source-video 2>&1 | Select-Object -Last 1

        foreach ($pose in @("sweep", "swipe")) {
            Copy-Item tools\sweep_addon_column.lua tools\sweep_addon.lua -Force
            $env:COLUMN_TAG = $state; $env:COLUMN_POSE = $pose
            & .\tools\run_battle_stability_sweep.ps1 -Only baraka_scorpion_swipe `
                -Observe $Observe -Backstop $Backstop -P2Human `
                *> "tools\ab_col_${state}_$pose.log"
            Remove-Item Env:\COLUMN_TAG, Env:\COLUMN_POSE -ErrorAction SilentlyContinue
        }

        Copy-Item tools\sweep_addon_shots.lua tools\sweep_addon.lua -Force
        $env:SHOTS_TAG = $state; $env:SHOTS_MODE = "swipe"; $env:SHOTS_MASK = "7"
        & .\tools\run_battle_stability_sweep.ps1 -Only baraka_scorpion_swipe `
            -Observe $Observe -Backstop $Backstop -P2Human `
            *> "tools\ab_shots_$state.log"
        Remove-Item Env:\SHOTS_TAG, Env:\SHOTS_MODE, Env:\SHOTS_MASK -ErrorAction SilentlyContinue
        $line = Select-String -Path "tools\ab_shots_$state.log" -Pattern "^Snapshots: " |
                Select-Object -Last 1
        if ($line) { $snapMap[$state] = ($line.Line -replace "^Snapshots: ", "").Trim() }
    }
} finally {
    python tools\ab_build.py after | Out-Null
    python tools\ab_build.py status | Select-Object -Last 2
    Remove-Item tools\sweep_addon.lua, tmp\BUILD.LOCK -Force -ErrorAction SilentlyContinue
}

Write-Host "`n========== HIT COLUMN =========="
foreach ($state in @("before", "after")) {
    foreach ($pose in @("sweep", "swipe")) {
        $f = "tools\column_${state}_$pose.txt"
        if (Test-Path $f) {
            Write-Host "`n--- $state / $pose ---"
            Get-Content $f | Where-Object { $_ -notmatch "^===" } | ForEach-Object { Write-Host $_ }
        } else { Write-Host "`n--- $state / $pose --- NO OUTPUT" }
    }
}

Write-Host "`n========== SNAPSHOT DIRS =========="
foreach ($k in $snapMap.Keys) {
    Write-Host ("{0,-7} {1}" -f $k, $snapMap[$k])
    $n = (Get-ChildItem -Recurse -Filter *.png $snapMap[$k] -ErrorAction SilentlyContinue).Count
    Write-Host ("        {0} png" -f $n)
}
