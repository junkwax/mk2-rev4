param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    # kang = fireball (should come back and hurt him)
    # scorpion = spear (should NOT come back - it drops off the screen)
    [string]$Char = "kang",
    [int]$Gap = 250,
    [switch]$NoSnap,
    # Control run: P1 throws, Kahn never claps.  Shows the projectile's
    # ordinary flight for comparison.
    [switch]$NoClap,
    # AI run: no puppet, no pinning, no scripted clap.  P1 throws on a loop
    # and the real Shao Kahn AI decides whether to clap them back.
    [switch]$Ai,
    # Clap BEFORE the throw, so the projectile lands on Kahn while the wave
    # is still sweeping - the spent-projectile case.
    [switch]$ClapFirst,
    # Control for the steering test: don't touch the stick after the deflect.
    [switch]$NoSteer
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kahn_clap_deflect_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $ToolsDir "kahn_clap_deflect_$Char.log"
$SnapshotDir = Join-Path $ToolsDir "screens\kahn_clap_deflect\$Char\$RunId"
$OutputDir = Join-Path $ToolsDir "kahn_clap_deflect_out\$Char\$RunId"

New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# Fresh CMOS: leftover credits desync the scripted coin/start schedule.
Remove-Item -Recurse -Force (Join-Path (Split-Path -Parent $Mame) "nvram\mk2") -ErrorAction SilentlyContinue

$env:MK2_DEFLECT_ROOT = $Root
$env:MK2_DEFLECT_LOG = $Log
$env:MK2_DEFLECT_CHAR = $Char
$env:MK2_DEFLECT_GAP = [string]$Gap
$env:MK2_DEFLECT_SNAP = if ($NoSnap) { "0" } else { "1" }
$env:MK2_DEFLECT_NOCLAP = if ($NoClap) { "1" } else { "0" }
$env:MK2_DEFLECT_AI = if ($Ai) { "1" } else { "0" }
$env:MK2_DEFLECT_CLAPFIRST = if ($ClapFirst) { "1" } else { "0" }
$env:MK2_DEFLECT_NOSTEER = if ($NoSteer) { "1" } else { "0" }

$runArgs = @{
    Mame = $Mame
    RomPath = $RomPath
    Machine = "mk2"
    Resolution = $Resolution
    Script = $LuaScript
    SnapshotDirectory = $SnapshotDir
    OutputDirectory = $OutputDir
    Video = "gdi"
    Wait = $true
    NoSound = $true
    # Must be non-zero: this source-built set trips MAME's ROM-warning screen,
    # and with 0 the lua never loads at all.
    WarningDismissCount = 1
    ReadyFile = $Log
}

Write-Host "[dfl] clapping $Char's projectile at ${Gap}px..."
& (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs

Remove-Item Env:\MK2_DEFLECT_ROOT, Env:\MK2_DEFLECT_LOG, Env:\MK2_DEFLECT_CHAR, Env:\MK2_DEFLECT_GAP, Env:\MK2_DEFLECT_SNAP -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $Log)) { throw "[dfl] no log at $Log" }
Write-Host ""
Get-Content -LiteralPath $Log | Where-Object { $_ -match "THROWN|DEFLECT|CAME BACK|PASS|FAIL|ERROR|gone|clapped" }
Write-Host ""
Write-Host "[dfl] log:       $Log"
Write-Host "[dfl] snapshots: $SnapshotDir"
