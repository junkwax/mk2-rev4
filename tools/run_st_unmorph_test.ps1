param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\test",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$P2Char = 11,
    [int]$TimeoutSeconds = 420,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

# STRAY-PROCESS GUARD.  run_mame_small leaves a background warning-dismisser
# job behind, and a leftover one posts keys into whatever MAME window appears
# next: this rig silently died one frame after fight_start that way, which
# reads exactly like the feature crashing.  Same trap as the battle sweep's.
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "st_unmorph_test.lua"
$LogDir = Join-Path $ToolsDir "st_unmorph_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\st_unmorph"
$OutputRoot = Join-Path $ToolsDir "st_unmorph_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "st_unmorph.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:ST_UNMORPH_LOG
$oldStage = $env:ST_UNMORPH_STAGE
$oldP2 = $env:ST_UNMORPH_P2_CHAR
$env:MK2_ROOT = $Root
$env:ST_UNMORPH_LOG = $LogPath
$env:ST_UNMORPH_STAGE = [string]$Stage
$env:ST_UNMORPH_P2_CHAR = [string]$P2Char

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
    if (-not $Sound) { $runArgs.NoSound = $true }

    Write-Host "[st-unmorph] Shang Tsung unmorph gesture test (Block+Up+HighKick; P2 char $P2Char, stage $Stage)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) { Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue } else { $env:MK2_ROOT = $oldRoot }
    if ($null -eq $oldLog) { Remove-Item Env:\ST_UNMORPH_LOG -ErrorAction SilentlyContinue } else { $env:ST_UNMORPH_LOG = $oldLog }
    if ($null -eq $oldStage) { Remove-Item Env:\ST_UNMORPH_STAGE -ErrorAction SilentlyContinue } else { $env:ST_UNMORPH_STAGE = $oldStage }
    if ($null -eq $oldP2) { Remove-Item Env:\ST_UNMORPH_P2_CHAR -ErrorAction SilentlyContinue } else { $env:ST_UNMORPH_P2_CHAR = $oldP2 }
}

if (Test-Path $LogPath) {
    Write-Host ""
    Get-Content $LogPath | Select-String -Pattern "morph_read|unmorphed|negative_control|PASS|FAIL|results|WARN|ERROR|^\[st-unmorph\] [a-z]+ +morph=" | ForEach-Object { $_.Line }
}
