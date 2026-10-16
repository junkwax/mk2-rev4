param(
    # A dedicated copy of the emulator: two MAME processes with the same exe
    # name fight over the same ini/cfg and one of them dies mid-run, which
    # reads exactly like a crash in the ROM.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,
    [switch]$Trace,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would otherwise be promoted
# to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir

# THE ZIP AND THE MAP HAVE TO COME FROM THE SAME BUILD.
#
# The Lua reads symbol addresses out of src/mk2.map and the ROM comes from
# $RomPath, so a zip older than the link is a DIFFERENT ROM from the map beside
# it - every symbol is then read at the wrong address and the rig reports
# confident nonsense rather than failing.  This tree has had nine live sessions
# in it in one evening, any of which can relink under you between your build and
# your run, so the pairing is not something to assume.  Same shape and the same
# 120s slack as tools/run_ani2_guard_test.ps1: the linker runs under DOSBox and
# stamps mk2.out with DOSBox's clock, so a perfectly fresh package routinely
# looks a few seconds older than the link it came from, and a zero-tolerance
# test fails a healthy tree - which is worse than no test.
$zip = Join-Path $RomPath "mk2.zip"
$linkOut = Join-Path $Root "src\mk2.out"
if ((Test-Path $zip) -and (Test-Path $linkOut)) {
    $skew = ((Get-Item $linkOut).LastWriteTime - (Get-Item $zip).LastWriteTime).TotalSeconds
    if ($skew -gt 120) {
        throw ("{0} is {1:n0}s older than src\mk2.out - a peer relinked under you." -f $zip, $skew) +
              " Repackage (python makerom.py; python mamerom.py --source-video --no-install) or pass -RomPath."
    }
}

$LuaScript = Join-Path $ToolsDir "jade_boom_prezap_test.lua"
$LogPath = Join-Path $ToolsDir "jade_boom_prezap_test.log"
$MameOutLog = Join-Path $ToolsDir "jade_boom_prezap_mame_out.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\jade_boom_prezap\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the jade_boomerang launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:JADE_PREZAP_LOG = $LogPath
if ($Trace) { $env:JADE_PREZAP_TRACE = "1" }

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

Remove-Item Env:JADE_PREZAP_LOG -ErrorAction SilentlyContinue
Remove-Item Env:JADE_PREZAP_TRACE -ErrorAction SilentlyContinue

Write-Host "[prezap] snapshots: $RunSnapshots"
if (Test-Path $LogPath) {
    Get-Content -Path $LogPath -Tail 40
    if (Select-String -Path $LogPath -Pattern "\[prezap\] PASS" -Quiet) {
        Write-Host "[prezap] PASSED" -ForegroundColor Green
        exit 0
    }
}
Write-Host "[prezap] FAILED" -ForegroundColor Red
exit 1
