param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "",
    [string]$Resolution = "640x480",
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
if (-not $RomPath) { $RomPath = Join-Path $Root "rom" }

$SoundTable = Join-Path $Root "src\MKSOUND.ASM"
$Canned = Join-Path $Root "src\MKCANNED.ASM"
$Attract = Join-Path $Root "src\MKAMODE.ASM"
$PatchRecipe = Join-Path $Root "sound\stlaugh_patch.txt"
$AudioSource = Join-Path $Root "sound\NOOBWINS.mp3"

function Assert-NoobWinnerAudioContract {
    $table = Get-Content -LiteralPath $SoundTable -Raw
    if ($table -notmatch '(?im)^\s*\.word\s+sp_bossv1\|164,0046h\s*;\s*5a\s*=\s*Noob Saibot wins') {
        throw "[noob-audio-run] Noob winner table entry must route index 5A to DCS call 0046: $SoundTable"
    }

    $canned = Get-Content -LiteralPath $Canned -Raw
    if ($canned -notmatch '(?im)^\s*\.long\s+generic_victory\s*;\s*f\s*-\s*Noob Saibot') {
        throw "[noob-audio-run] Noob must use generic_victory so MAIN.ASM owns the one winner announcement: $Canned"
    }
    if ($canned -match '(?im)^\s*tsound2\s+05ah\b') {
        throw "[noob-audio-run] A pose-level 05Ah call would duplicate Noob's MAIN.ASM winner speech: $Canned"
    }

    $attract = Get-Content -LiteralPath $Attract -Raw
    if ($attract -notmatch '(?im)^\s*test_mode\s+\.set\s+0\b') {
        throw "[noob-audio-run] Native winner-speech test requires normal arcade flow (test_mode .set 0): $Attract"
    }

    $patch = Get-Content -LiteralPath $PatchRecipe -Raw
    foreach ($required in @(
        'stream NoobWins "NOOBWINS.mp3";',
        'track \$0046 channel 1',
        'track \$0047 channel 2',
        'track \$0048 channel 3',
        'Play\(NoobWins\);'
    )) {
        if ($patch -notmatch $required) {
            throw "[noob-audio-run] Missing NOOBWINS patch component '$required': $PatchRecipe"
        }
    }
    if (-not (Test-Path -LiteralPath $AudioSource)) {
        throw "[noob-audio-run] Missing combined announcement source: $AudioSource"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $RomPath "mk2.zip"))) {
        throw "[noob-audio-run] No MAME set found at $(Join-Path $RomPath 'mk2.zip')"
    }
    Write-Host "[noob-audio-run] Source contract OK: P2 Noob winner index 5A -> patched DCS calls 0046-0048."
}

Assert-NoobWinnerAudioContract

$LuaScript = Join-Path $ToolsDir "noob_winner_audio_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapshotRoot = Join-Path $ToolsDir "screens\noob_winner_audio\run_$RunId"
$OutputRoot = Join-Path $ToolsDir "noob_winner_audio_out\run_$RunId"
$ReadoutRoot = Join-Path $ToolsDir "noob_winner_audio\run_$RunId"
$LogPath = Join-Path $ReadoutRoot "noob_winner_audio_test.log"

New-Item -ItemType Directory -Force -Path $SnapshotRoot,$OutputRoot,$ReadoutRoot | Out-Null

$oldRoot = $env:MK2_ROOT
$oldLog = $env:NOOB_AUDIO_LOG
$env:MK2_ROOT = $Root
$env:NOOB_AUDIO_LOG = $LogPath

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
        AutoCloseSeconds = $TimeoutSeconds
        Wait = $true
    }
    Write-Host "[noob-audio-run] Launching P1 Jax versus P2 Noob with sound enabled..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) { Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue } else { $env:MK2_ROOT = $oldRoot }
    if ($null -eq $oldLog) { Remove-Item Env:\NOOB_AUDIO_LOG -ErrorAction SilentlyContinue } else { $env:NOOB_AUDIO_LOG = $oldLog }
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "[noob-audio-run] Lua log was not created: $LogPath"
}

$log = Get-Content -LiteralPath $LogPath -Raw
if ($log -notmatch '\[noob-audio\] PASS reason=noob_won_audio_window_elapsed_path=native_winner_speech') {
    Get-Content -LiteralPath $LogPath -Tail 100
    throw "[noob-audio-run] Runtime Noob winner review failed; see $LogPath"
}

$pngs = @(Get-ChildItem -LiteralPath (Join-Path $SnapshotRoot "mk2") -Filter '*.png' -ErrorAction SilentlyContinue |
    Sort-Object Name)
if ($pngs.Count -lt 2) {
    throw "[noob-audio-run] Expected start/end screenshots; found $($pngs.Count)"
}

Write-Host "[noob-audio-run] PASS: normal P2 Noob winner speech reached the full audio review window."
Write-Host "[noob-audio-run] Listen in MAME for: Noob Saibot wins."
Write-Host "[noob-audio-run] Screenshots: $SnapshotRoot"
Write-Host "[noob-audio-run] Log: $LogPath"
