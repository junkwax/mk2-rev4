param(
    [int]$Diff = 9,
    [int]$Observe = 40000,
    [int]$Backstop = 420,
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\test",
    [int]$Stage = 5,
    [string]$Tag = "run",
    # Suppress the 0200h auto-revert so a CHOSEN revert is observable.  See
    # MORPH_HOLD in sweep_addon_morphchoice.lua - it changes no decision logic.
    [switch]$HoldForm
)
# What a CPU Shang picks out of do_random_morph, and specifically whether he
# ever picks HIS OWN FORM (drone_unmorph, MAINEQU.ASM).
#
# Reuses battle_stability_sweep.lua for character select and the fight - P1
# human, P2 the drone, forced to Shang - and installs
# sweep_addon_morphchoice.lua as that harness's addon to do the measuring.
# The addon is removed again on the way out.
#
# A/B: flip drone_unmorph in src/MAINEQU.ASM, rebuild, run again with a new
# -Tag.  With it OFF the CHOSEN REVERT count must be 0: the roll cannot
# produce Shang at all, so the only route back is the 0200h timer.

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Source = Join-Path $ToolsDir "sweep_addon_morphchoice.lua"
$LogPath = Join-Path $ToolsDir "drone_morph_choice_$Tag.log"
$SweepLog = Join-Path $ToolsDir "drone_morph_choice_sweep_$Tag.log"
$SnapDir = Join-Path $ToolsDir "screens\drone_morph_choice"

Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item $LogPath, $SweepLog -Force -ErrorAction SilentlyContinue
if (Test-Path $Addon) { Copy-Item $Addon "$Addon.bak" -Force }
Copy-Item $Source $Addon -Force

$saved = @{}
foreach ($n in @("MK2_ROOT","MORPH_LOG","MORPH_DIFF","MORPH_HOLD","SWEEP_P1","SWEEP_P2","SWEEP_STAGE",
                 "SWEEP_OBSERVE","SWEEP_LABEL","SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN")) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
}
$env:MK2_ROOT = $Root
$env:MORPH_LOG = $LogPath
$env:MORPH_DIFF = [string]$Diff
$env:MORPH_HOLD = $(if ($HoldForm) { "1" } else { "0" })
# Raiden as the opponent on purpose: matchup_odds gives Shang-as-Shang his
# best column there (13), so "become myself" is at its most likely - 14.2%%
# per decision by tools/morph_pick_odds.py.  Picking a matchup where the
# event is rare would only measure the rig's patience.
$env:SWEEP_P1 = "7"           # Raiden, P1, human - the harness walks him about
$env:SWEEP_P2 = "6"           # Shang Tsung, P2, the drone
$env:SWEEP_STAGE = [string]$Stage
$env:SWEEP_OBSERVE = [string]$Observe
$env:SWEEP_LABEL = "shang_drone_morphchoice"
$env:SWEEP_LOG = $SweepLog
$env:SWEEP_P2_HUMAN = "0"
$env:SWEEP_NO_HP_PIN = "0"

try {
    Write-Host "[morph] CPU Shang morph-choice probe (diff $Diff, $Observe frames, stage $Stage)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") `
        -RomPath $RomPath -Machine "mk2" -Resolution "640x480" -Video "gdi" `
        -Script (Join-Path $ToolsDir "battle_stability_sweep.lua") `
        -SnapshotDirectory $SnapDir -AutoCloseSeconds $Backstop -NoSound -NoThrottle -Wait
}
finally {
    Remove-Item $Addon -Force -ErrorAction SilentlyContinue
    if (Test-Path "$Addon.bak") { Move-Item "$Addon.bak" $Addon -Force }
    foreach ($n in $saved.Keys) {
        if ($null -eq $saved[$n]) { Remove-Item "Env:\$n" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$n" $saved[$n] }
    }
}

if (Test-Path $LogPath) { Write-Host ""; Get-Content $LogPath }
else { Write-Host "[morph] no log written - did the fight start? see $SweepLog" }
