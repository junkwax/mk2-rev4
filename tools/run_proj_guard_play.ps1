<#
  run_proj_guard_play.ps1 - PLAY one arm of the f6448e95 A/B and log what your
  projectiles do to the CPU's guard.

  This is a PLAYABLE session, not a rig: you are player 1, the CPU is player 2, and
  tools/drone_proj_guard_log.lua rides along writing one CSV row per projectile you
  throw. Nothing drives your inputs.

  WHY YOU AND NOT THE FLY. The fix only shows itself when a projectile is thrown while
  the drone is already sitting in a block or a duck. That is an ordinary human pattern -
  poke, they block, fireball - but the fly's catalogue only offers projectiles at range
  bands 2 and 3, so it almost never throws one at a drone that is busy guarding. The
  same limitation left the backbreaker A/B at zero samples in both arms.

  IT DOES NOT KILL OTHER MAME INSTANCES. Every run_*.ps1 in this tree opens by killing
  every mame.exe; this one does not, because trainers and streams are usually live. It
  uses its own rompath, cfg, nvram and snapshot directories, so it cannot disturb them
  and they cannot disturb it.

  HOW TO USE IT. Play a few matches on each arm, throwing fireballs at a CPU that is
  blocking or ducking - poke first, then throw. Then:

      .\tools\run_proj_guard_play.ps1 -Arm before
      .\tools\run_proj_guard_play.ps1 -Arm after
      python tools\drone_proj_guard_report.py `
          C:\tmp\flybrain\pgplay_after\drone_proj_guard.csv `
          --before C:\tmp\flybrain\pgplay_before\drone_proj_guard.csv

  Play the arms in whatever order you like, but play them the SAME WAY - this compares
  rates, and a different game plan on each side is a different experiment.
#>
param(
    [ValidateSet("before", "after")] [string]$Arm = "after",
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$Out = "",
    [string]$Resolution = "800x600",
    [switch]$Maximize,
    [switch]$NoSound,
    [int]$Window = 150          # frames to watch each throw out before calling it NOCONTACT
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$RomPath = "C:\tmp\flybrain\pg_$Arm"
if (-not $Out) { $Out = "C:\tmp\flybrain\pgplay_$Arm" }

# ---- the pair must be intact -------------------------------------------------------
# A zip paired with another build's map reads every symbol at the wrong address and
# reports nothing wrong, so the map travels with the zip and both are hash-checked.
foreach ($f in @("mk2.zip", "mk2.map", "PAIR.txt")) {
    if (-not (Test-Path (Join-Path $RomPath $f))) { throw "missing $f in $RomPath" }
}
$rec = @{}
foreach ($line in Get-Content (Join-Path $RomPath "PAIR.txt")) {
    if ($line -match '^(zip|map)=([0-9a-fA-F]{64})$') { $rec[$Matches[1]] = $Matches[2].ToUpper() }
}
foreach ($k in @("zip", "map")) {
    $h = (Get-FileHash (Join-Path $RomPath "mk2.$k") -Algorithm SHA256).Hash
    if ($rec[$k] -and $rec[$k] -ne $h) {
        throw "$k in $RomPath does not match PAIR.txt - the pair was broken, refusing to measure"
    }
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$env:FB_MAP = "$RomPath\mk2.map"
$env:FB_OUT = $Out
$env:PG_WINDOW = "$Window"

$mameArgs = @("-rompath", $RomPath, "mk2", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", "$Out\snap", "-nvram_directory", "$Out\nvram",
    "-cfg_directory", "$Out\cfg",
    "-autoboot_script", (Join-Path $Tools "drone_proj_guard_log.lua"),
    "-window")
if ($Maximize) { $mameArgs += "-maximize" } else { $mameArgs += @("-nomaximize", "-resolution", $Resolution) }
if ($NoSound) { $mameArgs += @("-sound", "none") }

Write-Host "[projguard] arm   : $Arm  ($RomPath)"
Write-Host "[projguard] csv   : $Out\drone_proj_guard.csv"
Write-Host "[projguard] pair  : zip/map hashes match PAIR.txt"
Write-Host ""
Write-Host "  Poke first, let the CPU block or duck, THEN throw - that is the case the"
Write-Host "  fix changes. A throw at a CPU doing nothing is the control and should not"
Write-Host "  move between arms."
Write-Host ""
& $Mame @mameArgs
Write-Host ""
if (Test-Path "$Out\drone_proj_guard.csv") {
    $n = (Get-Content "$Out\drone_proj_guard.csv" | Measure-Object -Line).Lines - 1
    Write-Host "[projguard] $n throws logged to $Out\drone_proj_guard.csv"
} else {
    Write-Host "[projguard] NO CSV WRITTEN - the addon did not load; check MAME's console output."
}
