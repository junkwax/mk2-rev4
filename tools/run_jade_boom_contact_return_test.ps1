param(
    # A dedicated copy of the emulator: two MAME processes with the same exe
    # name fight over the same ini/cfg and one of them dies mid-run, which
    # reads exactly like a crash in the ROM.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 60,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would otherwise be promoted
# to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "jade_boom_contact_return_test.lua"
$LogPath = Join-Path $ToolsDir "jade_boom_contact_return_test.log"
$MameOutLog = Join-Path $ToolsDir "jade_boom_contact_return_mame_out.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\jade_boom_contact_return\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the jade_boomerang launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:JADE_RET_LOG = $LogPath

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-cfg_directory", "C:\MAME\cfg",
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

Remove-Item Env:JADE_RET_LOG -ErrorAction SilentlyContinue

Write-Host "[boom-ret] snapshots: $RunSnapshots"
if (Test-Path $LogPath) {
    Get-Content -Path $LogPath -Tail 40
    if (Select-String -Path $LogPath -Pattern "\[boom-ret\] PASS" -Quiet) {
        Write-Host "[boom-ret] PASSED" -ForegroundColor Green
        exit 0
    }
}
Write-Host "[boom-ret] FAILED" -ForegroundColor Red
exit 1
