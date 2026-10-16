# run_perpiece_cost.ps1 - what does per-piece collision cost in frame time?
#
# Section 3.2 of doc/TOURNAMENT_READINESS.md: `perpiece` is built, documented
# and switched off, and what is missing is not code but a NUMBER. The f_colbox
# bit-4 overlay is known to take peak_overload from 4 to 35, but that is the
# DRAWING. This measures the collision.
#
# Both passes in one run, same session, same battles, overlay off in both
# (STRESS_COLBOX=0) - so the only difference between the two logs is the
# switch. Restores perpiece=0 and releases the lock whatever happens.
param(
    [int]$Observe = 900,
    [int]$Backstop = 120,
    [string]$Only = ""
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if (Test-Path tmp\BUILD.LOCK) {
    Write-Host "BUILD.LOCK held by:"; Get-Content tmp\BUILD.LOCK; exit 1
}
"mk2-main-db (perpiece cost A/B)" | Set-Content tmp\BUILD.LOCK

function Set-Perpiece([int]$v) {
    python -c @"
import io
p = 'src/MAINEQU.ASM'
raw = open(p, 'rb').read()
for old in (b'perpiece\t.set\t0', b'perpiece\t.set\t1'):
    raw = raw.replace(old, b'perpiece\t.set\t$v')
open(p, 'wb').write(raw)
"@
}

function Build-Rom {
    python build.py --asm-only 2>&1 | Select-Object -Last 1
    Start-Sleep -Milliseconds 1500
    python makerom.py 2>&1 | Select-Object -Last 1
    python mamerom.py --source-video 2>&1 | Select-Object -Last 1
}

Copy-Item tools\sweep_addon_stress.lua tools\sweep_addon.lua -Force
Remove-Item tools\perpiece_off.txt, tools\perpiece_on.txt -Force -ErrorAction SilentlyContinue
$env:STRESS_COLBOX = "0"

try {
    foreach ($p in @(0, 1)) {
        Write-Host "`n========== perpiece = $p =========="
        Set-Perpiece $p
        Select-String -Path src\MAINEQU.ASM -Pattern "^perpiece" | ForEach-Object { Write-Host $_.Line }
        Build-Rom
        Remove-Item tools\stress_load.txt -Force -ErrorAction SilentlyContinue
        $args = @{ Observe = $Observe; Backstop = $Backstop }
        if ($Only) { $args.Only = $Only }
        & .\tools\run_battle_stability_sweep.ps1 @args *> "tools\perpiece_sweep_$p.log"
        if (Test-Path tools\stress_load.txt) {
            Copy-Item tools\stress_load.txt ("tools\perpiece_" + $(if ($p) {"on"} else {"off"}) + ".txt") -Force
        }
    }
} finally {
    $env:STRESS_COLBOX = $null
    Set-Perpiece 0
    Select-String -Path src\MAINEQU.ASM -Pattern "^perpiece" | ForEach-Object { Write-Host "restored: $($_.Line)" }
    Build-Rom | Out-Null
    Remove-Item tools\sweep_addon.lua, tmp\BUILD.LOCK -Force -ErrorAction SilentlyContinue
}

Write-Host "`n========== FRAME TIME =========="
foreach ($t in @("off", "on")) {
    $f = "tools\perpiece_$t.txt"
    if (-not (Test-Path $f)) { Write-Host "perpiece $t : NO OUTPUT"; continue }
    $lost = Select-String -Path $f -Pattern "lost_ticks=(\d+)/(\d+)" -AllMatches
    $tot = 0; $n = 0
    foreach ($m in $lost.Matches) { $tot += [int]$m.Groups[1].Value; $n += [int]$m.Groups[2].Value }
    $worst = (Select-String -Path $f -Pattern "worst=(\d+)" -AllMatches).Matches |
             ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum
    Write-Host ("perpiece {0,-3}  lost ticks {1}/{2}  worst overload {3}" -f $t, $tot, $n, $worst.Maximum)
}
Write-Host "`nPer-battle detail: tools\perpiece_off.txt / tools\perpiece_on.txt"
