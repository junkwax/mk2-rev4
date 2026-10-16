# run_perpiece_behaviour.ps1 - does per-piece collision change WHAT CONNECTS?
#
# The other half of section 3.2. run_perpiece_cost.ps1 answers "what does it
# cost"; this answers "what does it change", which is the balance question and
# the one that actually decides whether it can be switched on.
#
# Uses the two range-map rigs that are known good - both verify the move fired
# on every trial, and both have a measured baseline on this build:
#
#   swipe     tools/sweep_addon_swipe.lua    connects 20..108 px (41/41 fired)
#   uppercut  tools/sweep_addon_behind.lua   connects 16..84 px (28/28 fired)
#
# A band that moves is a balance change; a band that does not is evidence the
# switch is safe for that move. Two moves is not the whole game and the output
# says so.
param(
    [int]$Backstop = 240
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if (Test-Path tmp\BUILD.LOCK) {
    Write-Host "BUILD.LOCK held by:"; Get-Content tmp\BUILD.LOCK; exit 1
}
"mk2-main-db (perpiece behaviour A/B)" | Set-Content tmp\BUILD.LOCK

function Set-Perpiece([int]$v) {
    python -c @"
p = 'src/MAINEQU.ASM'
raw = open(p, 'rb').read()
for old in (b'perpiece\t.set\t0', b'perpiece\t.set\t1'):
    raw = raw.replace(old, b'perpiece\t.set\t$v')
open(p, 'wb').write(raw)
"@
}

Remove-Item tools\swipe_range.txt, tools\behind_uppercut.txt -Force -ErrorAction SilentlyContinue

try {
    foreach ($p in @(0, 1)) {
        Write-Host "`n========== perpiece = $p =========="
        Set-Perpiece $p
        python build.py --asm-only 2>&1 | Select-Object -Last 1
        Start-Sleep -Milliseconds 1500
        python makerom.py 2>&1 | Select-Object -Last 1
        python mamerom.py --source-video 2>&1 | Select-Object -Last 1

        Copy-Item tools\sweep_addon_swipe.lua tools\sweep_addon.lua -Force
        & .\tools\run_battle_stability_sweep.ps1 -Only baraka_scorpion_swipe `
            -Observe 3200 -Backstop $Backstop -P2Human *> "tools\pp_swipe_$p.log"

        Copy-Item tools\sweep_addon_behind.lua tools\sweep_addon.lua -Force
        $env:BEHIND_FACING = "away"
        & .\tools\run_battle_stability_sweep.ps1 -Only mirror_baraka `
            -Observe 5200 -Backstop 280 -P2Human *> "tools\pp_upper_$p.log"
        Remove-Item Env:\BEHIND_FACING -ErrorAction SilentlyContinue
    }
} finally {
    Set-Perpiece 0
    python build.py --asm-only 2>&1 | Select-Object -Last 1
    Start-Sleep -Milliseconds 1500
    python makerom.py 2>&1 | Select-Object -Last 1
    python mamerom.py --source-video 2>&1 | Select-Object -Last 1
    Select-String -Path src\MAINEQU.ASM -Pattern "^perpiece" | ForEach-Object { Write-Host "restored: $($_.Line)" }
    Remove-Item tools\sweep_addon.lua, tmp\BUILD.LOCK -Force -ErrorAction SilentlyContinue
}

Write-Host "`n========== CONNECT BANDS =========="
Write-Host "(both files accumulate: first block is perpiece=0, second is perpiece=1)"
foreach ($f in @("tools\swipe_range.txt", "tools\behind_uppercut.txt")) {
    if (-not (Test-Path $f)) { Write-Host "$f : NO OUTPUT"; continue }
    Write-Host "`n--- $f ---"
    Select-String -Path $f -Pattern "VERDICT|never produced" | ForEach-Object { Write-Host $_.Line }
}
