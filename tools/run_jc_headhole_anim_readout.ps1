param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$Stage = 5,
    [int]$AttackerSide = 1,
    [int]$Step = 1,
    [string]$SnapshotRels = "",
    [int]$TimeoutSeconds = 180,
    [switch]$Sound,
    [switch]$TargetedSnapshotsOnly
)

$ErrorActionPreference = "Stop"

if ($AttackerSide -notin 1, 2) {
    throw "[jcheadhole-readout] AttackerSide must be 1 or 2"
}

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "jc_headhole_anim_readout.lua"
$LogDir = Join-Path $ToolsDir "jc_headhole_anim_readout_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\jc_headhole_anim_readout"
$OutputRoot = Join-Path $ToolsDir "jc_headhole_anim_readout_out"
$ReadoutRoot = Join-Path $ToolsDir "jc_headhole_anim_readout"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$RunReadout = Join-Path $ReadoutRoot "run_$RunId"
$LogPath = Join-Path $LogDir "jc_headhole_anim_readout.log"
$CsvPath = Join-Path $RunReadout "jc_headhole_anim_readout.csv"
$TxtPath = Join-Path $RunReadout "jc_headhole_anim_readout.txt"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
New-Item -ItemType Directory -Force -Path $RunReadout | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $CsvPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TxtPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:JC_HEADHOLE_FATALITY_LOG
$oldStage = $env:JC_HEADHOLE_STAGE
$oldReadout = $env:JC_HEADHOLE_READOUT
$oldReadoutDir = $env:JC_HEADHOLE_READOUT_DIR
$oldReadoutCsv = $env:JC_HEADHOLE_READOUT_CSV
$oldReadoutTxt = $env:JC_HEADHOLE_READOUT_TXT
$oldReadoutStep = $env:JC_HEADHOLE_READOUT_STEP
$oldSnapshotRels = $env:JC_HEADHOLE_SNAPSHOT_RELS
$oldTargetedSnapshotsOnly = $env:JC_HEADHOLE_TARGETED_SNAPSHOTS_ONLY
$oldHud = $env:JC_HEADHOLE_HUD
$oldAttackerSide = $env:JC_HEADHOLE_ATTACKER_SIDE

$env:MK2_ROOT = $Root
$env:JC_HEADHOLE_FATALITY_LOG = $LogPath
$env:JC_HEADHOLE_STAGE = [string]$Stage
$env:JC_HEADHOLE_READOUT = "1"
$env:JC_HEADHOLE_READOUT_DIR = $RunReadout
$env:JC_HEADHOLE_READOUT_CSV = $CsvPath
$env:JC_HEADHOLE_READOUT_TXT = $TxtPath
$env:JC_HEADHOLE_READOUT_STEP = [string]$Step
$env:JC_HEADHOLE_HUD = "1"
$env:JC_HEADHOLE_ATTACKER_SIDE = [string]$AttackerSide
if ($TargetedSnapshotsOnly) {
    $env:JC_HEADHOLE_TARGETED_SNAPSHOTS_ONLY = "1"
} else {
    Remove-Item Env:\JC_HEADHOLE_TARGETED_SNAPSHOTS_ONLY -ErrorAction SilentlyContinue
}
if ([string]::IsNullOrWhiteSpace($SnapshotRels)) {
    Remove-Item Env:\JC_HEADHOLE_SNAPSHOT_RELS -ErrorAction SilentlyContinue
} else {
    $env:JC_HEADHOLE_SNAPSHOT_RELS = $SnapshotRels
}

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
        Wait = $true
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }

    Write-Host "[jcheadhole-readout] Launching Cage headhole fatality readout (P$AttackerSide Cage, HUD on)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) {
        Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MK2_ROOT = $oldRoot
    }
    if ($null -eq $oldLog) {
        Remove-Item Env:\JC_HEADHOLE_FATALITY_LOG -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_FATALITY_LOG = $oldLog
    }
    if ($null -eq $oldStage) {
        Remove-Item Env:\JC_HEADHOLE_STAGE -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_STAGE = $oldStage
    }
    if ($null -eq $oldReadout) {
        Remove-Item Env:\JC_HEADHOLE_READOUT -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_READOUT = $oldReadout
    }
    if ($null -eq $oldReadoutDir) {
        Remove-Item Env:\JC_HEADHOLE_READOUT_DIR -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_READOUT_DIR = $oldReadoutDir
    }
    if ($null -eq $oldReadoutCsv) {
        Remove-Item Env:\JC_HEADHOLE_READOUT_CSV -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_READOUT_CSV = $oldReadoutCsv
    }
    if ($null -eq $oldReadoutTxt) {
        Remove-Item Env:\JC_HEADHOLE_READOUT_TXT -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_READOUT_TXT = $oldReadoutTxt
    }
    if ($null -eq $oldReadoutStep) {
        Remove-Item Env:\JC_HEADHOLE_READOUT_STEP -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_READOUT_STEP = $oldReadoutStep
    }
    if ($null -eq $oldSnapshotRels) {
        Remove-Item Env:\JC_HEADHOLE_SNAPSHOT_RELS -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_SNAPSHOT_RELS = $oldSnapshotRels
    }
    if ($null -eq $oldTargetedSnapshotsOnly) {
        Remove-Item Env:\JC_HEADHOLE_TARGETED_SNAPSHOTS_ONLY -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_TARGETED_SNAPSHOTS_ONLY = $oldTargetedSnapshotsOnly
    }
    if ($null -eq $oldHud) {
        Remove-Item Env:\JC_HEADHOLE_HUD -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_HUD = $oldHud
    }
    if ($null -eq $oldAttackerSide) {
        Remove-Item Env:\JC_HEADHOLE_ATTACKER_SIDE -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_ATTACKER_SIDE = $oldAttackerSide
    }
}

Write-Host "[jcheadhole-readout] Lua log: $LogPath"
Write-Host "[jcheadhole-readout] Screenshots: $RunSnapshots"
Write-Host "[jcheadhole-readout] MAME output: $RunOutput"
Write-Host "[jcheadhole-readout] CSV: $CsvPath"
Write-Host "[jcheadhole-readout] TXT: $TxtPath"

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "[jcheadhole-readout] Lua log was not created"
}
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "[jcheadhole-readout] CSV readout was not created"
}
if (-not (Test-Path -LiteralPath $TxtPath)) {
    throw "[jcheadhole-readout] TXT readout was not created"
}

$text = Get-Content -LiteralPath $LogPath -Raw
$ok = ($text -match "\[jcheadhole\] PASS" -and $text -notmatch "\[jcheadhole\] ERROR")
if (-not $ok) {
    Write-Host "[jcheadhole-readout] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 120
    throw "[jcheadhole-readout] Cage headhole fatality readout failed; see $LogPath"
}

$rows = @(Import-Csv -LiteralPath $CsvPath)
Write-Host "[jcheadhole-readout] PASS rows=$($rows.Count)"
Write-Host "[jcheadhole-readout] Readout preview:"
Get-Content -LiteralPath $TxtPath -First 8
Write-Host "[jcheadhole-readout] Readout tail:"
Get-Content -LiteralPath $TxtPath -Tail 8
