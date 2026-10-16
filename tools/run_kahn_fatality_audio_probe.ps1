# run_kahn_fatality_audio_probe.ps1
#
# Boots Liu Kang vs Shao Kahn, forces the hammer fatality, and traces every
# DCS track the game sends over the ending - see tools/kahn_fatality_audio_probe.lua.
#
#   .\tools\run_kahn_fatality_audio_probe.ps1              # trace only (silent, fast)
#   .\tools\run_kahn_fatality_audio_probe.ps1 -Wav         # trace + record the mix to .wav
#
# The wav is what settles "is it clipping" without asking anybody to listen.

param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [switch]$Wav,
    # -Listen: for JUDGING THE AUDIO BY EAR.  The tracing run writes a PNG every
    # 3 frames from the moment the hammer connects (~300 of them, continuing
    # into the next round) and blits through -video gdi; that is enough to drop
    # emulation under 100%, which starves the host sound device and puts small
    # repetitive blanks in EVERYTHING from the hammer hit onwards.  Those blanks
    # are the harness, not the ROM - -wavwrite taps the emulated mix and stays
    # clean right through them.  This switch turns the snapshot flood off and
    # uses a hardware backend so what you hear is what the ROM plays.
    [switch]$Listen,
    [int]$Attempts = 2
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kahn_fatality_audio_probe.lua"
$OutDir = Join-Path $ToolsDir "kahn_fatality_audio_logs"
$SnapDir = Join-Path $ToolsDir "screens\kahn_fatality_audio"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null

$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $OutDir "hammer_fatality_$RunId.log"
$WavPath = Join-Path $OutDir "hammer_fatality_$RunId.wav"

# Same environment the scripted hammer run uses: -PortalFatality is what pins
# round_num to 3 and seeds the victim at 0x20 HP, which is the only way
# kahn_hammer_try_fatal's gate opens.
$env:KAHN_TEST_ROOT = $Root
$env:KAHN_TEST_LOG = $LogPath
$env:KAHN_TEST_CODE = "16"
$env:KAHN_PORTAL_FATALITY = "1"
$env:KAHN_ALLOW_P1_DAMAGE = "1"
foreach ($stale in @("KAHN_TEST_CODES", "KAHN_NORMAL_MATCH", "KAHN_P2_PAD",
                     "KAHN_COLBOX", "KAHN_PIN_PLAYERS", "KAHN_PIN_KAHN",
                     "KAHN_UNLIMITED_HEALTH", "KAHN_LIVE_HOLD")) {
    Remove-Item "Env:\$stale" -ErrorAction SilentlyContinue
}

if ($Listen) {
    # snap() fires on (pulp_frames % SNAP_EVERY) == 1, so a huge stride leaves
    # exactly one snapshot instead of ~300
    $env:KAHN_SNAP_EVERY = "1000000"
} else {
    Remove-Item Env:\KAHN_SNAP_EVERY -ErrorAction SilentlyContinue
}

for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

    # Leftover credits desync the scripted coin/start schedule.
    $MameDir = Split-Path -Parent $Mame
    Remove-Item -Recurse -Force (Join-Path $MameDir "nvram\mk2") -ErrorAction SilentlyContinue

    $runArgs = @{
        Mame = $Mame
        RomPath = $RomPath
        Machine = "mk2"
        Resolution = $Resolution
        Script = $LuaScript
        SnapshotDirectory = (Join-Path $SnapDir "run_$RunId")
        OutputDirectory = (Join-Path $OutDir "mame_$RunId")
        Video = $(if ($Listen) { "d3d" } else { "gdi" })
        Wait = $true
        WarningDismissCount = 1
        ReadyFile = $LogPath
    }

    if ($Wav -or $Listen) {
        # -wavwrite needs a live sound system, so no -sound none on this path.
        if ($Wav) { $runArgs.ExtraArgs = @("-wavwrite", $WavPath) }
    } else {
        $runArgs.NoSound = $true
    }

    Write-Host "[fat-audio] hammer fatality trace, attempt $attempt/$Attempts..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs

    if ((Test-Path -LiteralPath $LogPath) -and
        (Select-String -LiteralPath $LogPath -Pattern "ack move=hammer" -Quiet)) {
        break
    }
    Write-Warning "[fat-audio] attempt $attempt never reached the hammer; retrying if attempts remain."
}

foreach ($stale in @("KAHN_TEST_ROOT", "KAHN_TEST_LOG", "KAHN_TEST_CODE",
                     "KAHN_PORTAL_FATALITY", "KAHN_ALLOW_P1_DAMAGE")) {
    Remove-Item "Env:\$stale" -ErrorAction SilentlyContinue
}

Write-Host "[fat-audio] log: $LogPath"
if ($Wav) { Write-Host "[fat-audio] wav: $WavPath" }
