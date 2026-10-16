param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,
    [ValidateSet(1, 2)][int]$Side = 1,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would otherwise be promoted
# to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "jade_victory_test.lua"
$SideTag = if ($Side -eq 2) { "_p2" } else { "" }
$LogPath = Join-Path $ToolsDir "jade_victory_test$SideTag.log"
$SnapshotRoot = Join-Path $ToolsDir "screens\jade_victory"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId$SideTag"
$MameOutLog = Join-Path $ToolsDir "jade_victory_mame_out$SideTag.log"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the boomerang/kahn/kitana-nitro launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:JADE_VICTORY_LOG = $LogPath
# Side 2 puts Jade on the right, facing LEFT - the run that proves the staff
# mirrors along with her body.
$env:JADE_VICTORY_SIDE = $Side

# NOTE: direct blocking call, not Start-Process - under pwsh 7 the
# Start-Process path launches MAME with a mangled command line and
# -autoboot_script never loads. The lua exits MAME itself on finish/error;
# -seconds_to_run is a backstop only.
$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[jade-victory] launching Jade victory sequence test (Jade = P$Side)..."
Push-Location (Split-Path -Parent $Mame)
try {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs *> $MameOutLog
    $ErrorActionPreference = $prevEap
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:JADE_VICTORY_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:JADE_VICTORY_SIDE -ErrorAction SilentlyContinue
}

Write-Host "[jade-victory] screenshots: $RunSnapshots"

if (-not (Test-Path $LogPath)) {
    Write-Error "[jade-victory] FAILED (no log created)"
    exit 1
}

Get-Content -Path $LogPath -Tail 25

# The stage counter only proves the ani2 rows advance through the expected
# SAGs - it passed for months while the sidecar held no pixel data at all.
# Always eyeball the snapshots before calling this green.
if (Select-String -Path $LogPath -Pattern "\[jade-victory\] ERROR" -Quiet) {
    Write-Error "[jade-victory] FAILED (lua reported ERROR)"
    exit 1
} elseif (-not (Select-String -Path $LogPath -Pattern "\[jade-victory\] PASS" -Quiet)) {
    Write-Error "[jade-victory] FAILED (no PASS line)"
    exit 1
}

Write-Host "[jade-victory] PASSED (stage order) - now check the snapshots render Jade, not garbage" -ForegroundColor Green
