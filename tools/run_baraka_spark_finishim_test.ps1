param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,
    [int]$WinnerStatus = 3,       # 3 = finish him (the repro); 0 handled by -Control
    [switch]$Control,             # fire the spark during a NORMAL fight instead
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "baraka_spark_finishim_test.lua"
$LogPath = Join-Path $ToolsDir "baraka_spark_finishim_test.log"
$SnapshotRoot = Join-Path $ToolsDir "screens\baraka_spark_finishim"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (kahn/kitana launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:BARAKA_TEST_LOG = $LogPath
$env:BARAKA_WS = [string]$WinnerStatus
if ($Control) { $env:BARAKA_CONTROL = "1" } else { Remove-Item Env:\BARAKA_CONTROL -ErrorAction SilentlyContinue }

# Direct blocking call (see kitana wrapper note): Start-Process mangles
# -autoboot_script under pwsh 7. The lua exits MAME itself; -seconds_to_run
# is a backstop.
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

$mode = if ($Control) { "CONTROL (normal fight)" } else { "FINISH HIM (ws=$WinnerStatus)" }
Write-Host "[baraka-test] Launching Baraka spark repro - mode: $mode"
$MameOutLog = Join-Path $ToolsDir "baraka_spark_finishim_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    Remove-Item Env:\BARAKA_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\BARAKA_WS -ErrorAction SilentlyContinue
    Remove-Item Env:\BARAKA_CONTROL -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Write-Host "[baraka-test] Log tail:"
    Get-Content -Path $LogPath -Tail 50

    if (Select-String -Path $LogPath -Pattern "REPRO/FAIL reason=repro_" -Quiet) {
        Write-Host "[baraka-test] >>> BUG REPRODUCED (corruption detected). See log + snapshots."
    } elseif (Select-String -Path $LogPath -Pattern "PASS reason=spark_correctly_suppressed" -Quiet) {
        Write-Host "[baraka-test] >>> FIX CONFIRMED: spark correctly suppressed during FINISH HIM (no soft-lock)."
    } elseif (Select-String -Path $LogPath -Pattern "PASS reason=no_corruption" -Quiet) {
        Write-Host "[baraka-test] No corruption detected this run (spark fired + recovered cleanly)."
    } else {
        Write-Warning "[baraka-test] Harness did not reach a clean verdict (setup/timeout?)."
    }
} else {
    Write-Error "[baraka-test] Lua log was not created (see $MameOutLog)."
}

Write-Host "[baraka-test] Log:       $LogPath"
Write-Host "[baraka-test] Snapshots: $RunSnapshots"
