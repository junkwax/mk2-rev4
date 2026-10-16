param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [switch]$Debug,
    [string]$DebugScript = "",
    [switch]$Sound,
    [string]$AutoMoves = "",
    [int]$AutoCloseSeconds = 0,
    [switch]$PortalFatality,
    # Re-pin both fighters' x every frame at a fixed 72px spacing, so neither
    # one walks. Kahn's own AI is already suppressed in this mode (the lua
    # writes the puppet gate to debug2), but suppressing his move PICKS does
    # not stop him strolling toward you - this does. Pins x only, so jumps
    # still work, and it pins P1 too.
    [switch]$PinPlayers,
    # Pin KAHN only and leave P1 free to walk. This is the one you want for
    # firing his moves at a standing target: the puppet gate already stops him
    # picking moves, this stops him strolling, and Liu Kang still moves.
    [switch]$PinKahn,
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kahn_boss_moves_test.lua"
$LogDir = Join-Path $ToolsDir "kahn_boss_moves_test_logs"
$SnapshotDir = Join-Path $ToolsDir "screens\kahn_boss_live"
$OutputDir = Join-Path $ToolsDir "kahn_boss_live_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunOutput = Join-Path $OutputDir "run_$RunId"
$RunSnapshots = Join-Path $SnapshotDir "run_$RunId"
$LogPath = Join-Path $LogDir "live_hold.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null

$env:KAHN_TEST_ROOT = $Root
$env:KAHN_TEST_LOG = $LogPath
$env:KAHN_LIVE_HOLD = "1"
$env:KAHN_UNLIMITED_HEALTH = "1"
if ($PinKahn) {
    $env:KAHN_PIN_KAHN = "1"
} else {
    Remove-Item Env:\KAHN_PIN_KAHN -ErrorAction SilentlyContinue
}
if ($PinPlayers) {
    $env:KAHN_PIN_PLAYERS = "1"
} else {
    Remove-Item Env:\KAHN_PIN_PLAYERS -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PIN_KAHN -ErrorAction SilentlyContinue
}
if ($PortalFatality) {
    $env:KAHN_ALLOW_P1_DAMAGE = "1"
    $env:KAHN_PORTAL_FATALITY = "1"
} else {
    Remove-Item Env:\KAHN_ALLOW_P1_DAMAGE -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PORTAL_FATALITY -ErrorAction SilentlyContinue
}
Remove-Item Env:\KAHN_TEST_CODE -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_TEST_CODES -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_NORMAL_MATCH -ErrorAction SilentlyContinue
if ($AutoMoves) {
    $env:KAHN_TEST_CODES = $AutoMoves
}

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
        AutoCloseSeconds = $AutoCloseSeconds
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }
    if (-not $NoWait) {
        $runArgs.Wait = $true
    }
    if ($Debug) {
        $runArgs.Debug = $true
    }
    if ($DebugScript) {
        $runArgs.DebugScript = $DebugScript
    }

    Write-Host "[kahn-live] Launching live hold harness..."
    if ($AutoMoves) {
        Write-Host "[kahn-live] Auto moves: $AutoMoves"
    }
    if ($PortalFatality) {
        Write-Host "[kahn-live] Portal fatality health seed enabled."
    }
    Write-Host "[kahn-live] Hotkeys: 1=big_power 2=slam 3=sonic 4=portal 5=nupower Insert=jump Del=fly PgUp=snapshot Home=clear latch"
    if ($Debug) {
        Write-Host "[kahn-live] Debugger enabled."
    }
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    Remove-Item Env:\KAHN_TEST_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_LIVE_HOLD -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_UNLIMITED_HEALTH -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_ALLOW_P1_DAMAGE -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PORTAL_FATALITY -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_TEST_CODE -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_TEST_CODES -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_NORMAL_MATCH -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PIN_PLAYERS -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PIN_KAHN -ErrorAction SilentlyContinue
}

Write-Host "[kahn-live] Lua log: $LogPath"
Write-Host "[kahn-live] Screenshots: $RunSnapshots"
Write-Host "[kahn-live] MAME output: $RunOutput"
