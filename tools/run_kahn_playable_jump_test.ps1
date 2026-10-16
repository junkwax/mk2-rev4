param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tests = "up,forward,back",
    [int]$YLimit = 360,
    [switch]$Debug,
    [string]$DebugScript = "",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kahn_playable_jump_test.lua"
$LogDir = Join-Path $ToolsDir "kahn_playable_jump_test_logs"
$SnapshotDir = Join-Path $ToolsDir "screens\kahn_playable_jump"
$OutputDir = Join-Path $ToolsDir "kahn_playable_jump_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunOutput = Join-Path $OutputDir "run_$RunId"
$RunSnapshots = Join-Path $SnapshotDir "run_$RunId"
$LogPath = Join-Path $LogDir "playable_jump.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$env:KAHN_PLAYABLE_ROOT = $Root
$env:KAHN_PLAYABLE_LOG = $LogPath
$env:KAHN_PLAYABLE_TESTS = $Tests
$env:KAHN_PLAYABLE_Y_LIMIT = [string]$YLimit

if ($Debug -and -not $DebugScript) {
    $DefaultDebugScript = Join-Path $Root "mame_autoresume.ds"
    if (Test-Path -LiteralPath $DefaultDebugScript) {
        $DebugScript = $DefaultDebugScript
    }
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
        Wait = $true
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }
    if ($Debug) {
        $runArgs.Debug = $true
    }
    if ($DebugScript) {
        $runArgs.DebugScript = $DebugScript
    }

    Write-Host "[kahn-play] Launching playable Shao jump probe..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    Remove-Item Env:\KAHN_PLAYABLE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PLAYABLE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PLAYABLE_TESTS -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PLAYABLE_Y_LIMIT -ErrorAction SilentlyContinue
}

Write-Host "[kahn-play] Lua log: $LogPath"
Write-Host "[kahn-play] Screenshots: $RunSnapshots"
Write-Host "[kahn-play] MAME output: $RunOutput"

$ok = $false
if (Test-Path -LiteralPath $LogPath) {
    $text = Get-Content -LiteralPath $LogPath -Raw
    $ok = ($text -match "\[kahn-play\] finished" -and $text -notmatch "\[kahn-play\] ERROR")
}

if (-not $ok) {
    throw "[kahn-play] playable jump probe failed; see $LogPath"
}
