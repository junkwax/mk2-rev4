param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$TimeoutSeconds = 240,
    [ValidateSet("left", "right")]
    [string]$Side = "left",
    # C:\MAME\ui.ini normally has skip_warnings=1, but MAME does sometimes park
    # on the bad-checksum warning screen anyway - and when it does the autoboot
    # script never runs at all: no lua log, zero bytes of stdout, nothing in
    # stderr past "WARNING: the machine might not run correctly."  If a run
    # produces no log, re-run with -WarningDismissCount 4.
    [int]$WarningDismissCount = 0,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "scorpion_scortch_mk1_test.lua"
$LogDir = Join-Path $ToolsDir "scorpion_scortch_mk1_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\scorpion_scortch_mk1"
$OutputRoot = Join-Path $ToolsDir "scorpion_scortch_mk1_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "scorpion_scortch_mk1_$Side.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:SCORTCH_LOG
$oldStage = $env:SCORTCH_STAGE
$oldSide = $env:SCORTCH_SIDE
$env:MK2_ROOT = $Root
$env:SCORTCH_LOG = $LogPath
$env:SCORTCH_STAGE = [string]$Stage
$env:SCORTCH_SIDE = $Side

try {
    $runArgs = @{
        Mame = $Mame
        RomPath = $RomPath
        Machine = "mk2"
        Resolution = $Resolution
        Script = $LuaScript
        SnapshotDirectory = $RunSnapshots
        OutputDirectory = $RunOutput
        Video = "gdi"
        AutoCloseSeconds = $TimeoutSeconds
        WarningDismissCount = $WarningDismissCount
        Wait = $true
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }

    Write-Host "[scortch] Launching Scorpion MK1 scortch fatality test (Up,Up+HP), Scorpion on the $Side..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) {
        Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MK2_ROOT = $oldRoot
    }
    if ($null -eq $oldLog) {
        Remove-Item Env:\SCORTCH_LOG -ErrorAction SilentlyContinue
    } else {
        $env:SCORTCH_LOG = $oldLog
    }
    if ($null -eq $oldStage) {
        Remove-Item Env:\SCORTCH_STAGE -ErrorAction SilentlyContinue
    } else {
        $env:SCORTCH_STAGE = $oldStage
    }
    if ($null -eq $oldSide) {
        Remove-Item Env:\SCORTCH_SIDE -ErrorAction SilentlyContinue
    } else {
        $env:SCORTCH_SIDE = $oldSide
    }
}

Write-Host "[scortch] Lua log: $LogPath"
Write-Host "[scortch] Screenshots: $RunSnapshots"
Write-Host "[scortch] MAME output: $RunOutput"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[scortch] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 60
}
