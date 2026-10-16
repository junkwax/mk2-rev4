param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 90,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would otherwise be promoted
# to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "jade_boom_arcs_test.lua"
$LogPath = Join-Path $ToolsDir "jade_boom_arcs_test.log"
$MameOutLog = Join-Path $ToolsDir "jade_boom_arcs_mame_out.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\jade_boom_arcs\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the jade_boomerang launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:JADE_ARCS_LOG = $LogPath

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

Push-Location (Split-Path -Parent $Mame)
try {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs *> $MameOutLog
    $ErrorActionPreference = $prevEap
} finally {
    Pop-Location
}

Remove-Item Env:JADE_ARCS_LOG -ErrorAction SilentlyContinue

Write-Host "[boom-arc] snapshots: $RunSnapshots"
if (Test-Path $LogPath) {
    Get-Content -Path $LogPath -Tail 40
    if (Select-String -Path $LogPath -Pattern "\[boom-arc\] PASS" -Quiet) {
        Write-Host "[boom-arc] PASSED" -ForegroundColor Green
        exit 0
    }
}
Write-Host "[boom-arc] FAILED" -ForegroundColor Red
exit 1
