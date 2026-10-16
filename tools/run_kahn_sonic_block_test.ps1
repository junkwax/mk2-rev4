param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    # sonic = the clap wave (b_kahn_sonic).  punch = Kahn's heavy punch
    # (b_kahn_punch), the control the clap used to share.
    [string]$Move = "sonic",
    [int]$Gap = 110,
    # Fire the move this many times in one round.  The RNG is reseeded at
    # every round start, so a single shot always rolls the same burst count.
    [int]$Shots = 1,
    # Control run: don't hold block, so the move should land as a normal hit.
    [switch]$NoGuard,
    [switch]$Sound,
    # -Wav: capture the EMULATED mix to a .wav and suppress the snapshot
    # flood.  Per the harness notes, a snapshot-heavy run starves the host
    # sound device and puts blanks in everything - which sounds exactly like
    # the feature under test having broken the audio.  -wavwrite taps the
    # emulated mix instead, so it stays clean regardless of host speed.
    [switch]$Wav
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kahn_sonic_block_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$Tag = if ($NoGuard) { "${Move}_noguard" } else { $Move }
$Log = Join-Path $ToolsDir "kahn_sonic_block_${Tag}.log"
$SnapshotDir = Join-Path $ToolsDir "screens\kahn_sonic_block\$Move\$RunId"
$OutputDir = Join-Path $ToolsDir "kahn_sonic_block_out\$Move\$RunId"

New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# Fresh CMOS: leftover credits desync the scripted coin/start schedule.
Remove-Item -Recurse -Force (Join-Path (Split-Path -Parent $Mame) "nvram\mk2") -ErrorAction SilentlyContinue

$env:MK2_BLOCK_ROOT = $Root
$env:MK2_BLOCK_LOG = $Log
$env:MK2_BLOCK_MOVE = $Move
$env:MK2_BLOCK_GAP = [string]$Gap
$env:MK2_BLOCK_GUARD = if ($NoGuard) { "0" } else { "1" }
$env:MK2_BLOCK_SNAP = if ($Wav) { "0" } else { "1" }
$env:MK2_BLOCK_SHOTS = [string]$Shots
$WavPath = Join-Path $OutputDir "$Tag.wav"

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
    # Must be non-zero: this source-built set DOES trip MAME's ROM-warning
    # screen, and with 0 the lua never loads at all (no log file whatsoever).
    # The cost is that the keypress can occasionally land in the running game
    # instead, which shows up as MAME self-exiting a few seconds in - retry.
    WarningDismissCount = 1
    ReadyFile = $Log
}
if (-not $Sound -and -not $Wav) { $runArgs.NoSound = $true }
if ($Wav) { $runArgs.ExtraArgs = @("-wavwrite", $WavPath) }

Write-Host "[blk] blocking Kahn's '$Move' at ${Gap}px..."
& (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs

Remove-Item Env:\MK2_BLOCK_ROOT, Env:\MK2_BLOCK_LOG, Env:\MK2_BLOCK_MOVE, Env:\MK2_BLOCK_GAP, Env:\MK2_BLOCK_GUARD -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $Log)) { throw "[blk] no log at $Log" }
$text = Get-Content -LiteralPath $Log -Raw
Write-Host ""
Get-Content -LiteralPath $Log | Where-Object { $_ -match "RESULT|PASS|FAIL|ERROR|CONTACT" }
Write-Host ""
Write-Host "[blk] log:       $Log"
Write-Host "[blk] snapshots: $SnapshotDir"
if ($Wav -and (Test-Path -LiteralPath $WavPath)) {
    Write-Host "[blk] wav:       $WavPath ($((Get-Item $WavPath).Length) bytes)"
}
if ($text -notmatch "\[blk\] PASS") { Write-Warning "[blk] $Move did not PASS" }
