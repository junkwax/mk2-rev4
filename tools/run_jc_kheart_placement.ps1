param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "960x720",
    [int]$Stage = 5,
    [int]$MaxRel = 250,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "jc_kheart_placement.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunRoot = Join-Path $ToolsDir "jc_kheart_placement\run_$RunId"
$LogDir = Join-Path $ToolsDir "jc_kheart_placement_logs"
$OutputRoot = Join-Path $ToolsDir "jc_kheart_placement_out\run_$RunId"
$SnapshotRoot = Join-Path $ToolsDir "screens\jc_kheart_placement\run_$RunId"
$LogPath = Join-Path $LogDir "jc_kheart_placement.log"
$ReadoutCsv = Join-Path $RunRoot "jc_headhole_anim_readout.csv"
$ReadoutTxt = Join-Path $RunRoot "jc_headhole_anim_readout.txt"
$PlacementCsv = Join-Path $RunRoot "jc_kheart_placement.csv"
$PlacementTxt = Join-Path $RunRoot "jc_kheart_placement.txt"
$StateRoot = Join-Path $RunRoot "states"

New-Item -ItemType Directory -Force -Path $RunRoot,$LogDir,$OutputRoot,$SnapshotRoot,$StateRoot | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$saved = @{}
$names = @(
    "MK2_ROOT", "JC_HEADHOLE_FATALITY_LOG", "JC_HEADHOLE_STAGE",
    "JC_HEADHOLE_READOUT", "JC_HEADHOLE_READOUT_DIR",
    "JC_HEADHOLE_READOUT_CSV", "JC_HEADHOLE_READOUT_TXT",
    "JC_KHEART_PLACEMENT", "JC_KHEART_PLACEMENT_CSV",
    "JC_KHEART_PLACEMENT_TXT", "JC_KHEART_PLACEMENT_MAX_REL",
    "JC_KHEART_PLACEMENT_STATE_DIR", "JC_KHEART_PLACEMENT_AUTOTEST"
)
foreach ($name in $names) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$env:MK2_ROOT = $Root
$env:JC_HEADHOLE_FATALITY_LOG = $LogPath
$env:JC_HEADHOLE_STAGE = [string]$Stage
$env:JC_HEADHOLE_READOUT = "1"
$env:JC_HEADHOLE_READOUT_DIR = $RunRoot
$env:JC_HEADHOLE_READOUT_CSV = $ReadoutCsv
$env:JC_HEADHOLE_READOUT_TXT = $ReadoutTxt
$env:JC_KHEART_PLACEMENT = "1"
$env:JC_KHEART_PLACEMENT_CSV = $PlacementCsv
$env:JC_KHEART_PLACEMENT_TXT = $PlacementTxt
$env:JC_KHEART_PLACEMENT_MAX_REL = [string]$MaxRel
$env:JC_KHEART_PLACEMENT_STATE_DIR = $StateRoot
$env:JC_KHEART_PLACEMENT_AUTOTEST = "0"

try {
    $runArgs = @{
        Mame = $Mame
        RomPath = $RomPath
        Machine = "mk2"
        Resolution = $Resolution
        Script = $LuaScript
        SnapshotDirectory = $SnapshotRoot
        OutputDirectory = $OutputRoot
        Video = "gdi"
        WarningDismissCount = 3
        Wait = $true
    }
    if (-not $Sound) { $runArgs.NoSound = $true }

    Write-Host "[kheart-placement] Booting to round 2 Finish Him..."
    Write-Host "[kheart-placement] SPACE starts; arrows move KHEART; A back; S/SPACE forward; Esc exits."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
    }
}

Write-Host "[kheart-placement] Log: $LogPath"
Write-Host "[kheart-placement] Placement CSV: $PlacementCsv"
Write-Host "[kheart-placement] Placement TXT: $PlacementTxt"
Write-Host "[kheart-placement] Screenshots: $SnapshotRoot"

if (-not (Test-Path -LiteralPath $PlacementCsv)) {
    throw "[kheart-placement] Placement CSV was not created; see $LogPath"
}
if (-not (Test-Path -LiteralPath $PlacementTxt)) {
    throw "[kheart-placement] Placement TXT was not created; see $LogPath"
}

$rows = @(Import-Csv -LiteralPath $PlacementCsv)
Write-Host "[kheart-placement] Recorded scene rows: $($rows.Count)"
