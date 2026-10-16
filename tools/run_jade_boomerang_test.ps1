param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,
    [string[]]$Modes = @("jade", "kitana", "dronejade"),
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the
# crc_spoof'd ROMs (see mamerom.py); on pwsh 7.3+ that alone would
# otherwise be promoted to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "jade_boomerang_test.lua"
$SnapshotRoot = Join-Path $ToolsDir "screens\jade_boomerang"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"

$anyFailed = $false

foreach ($mode in $Modes) {
    $LogPath = Join-Path $ToolsDir "jade_boomerang_test_$mode.log"
    $RunSnapshots = Join-Path $SnapshotRoot "run_${RunId}_$mode"
    New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

    # Boot determinism: leftover CMOS credits desync the scripted coin/start
    # schedule (see the kahn/kitana-nitro launcher precedent).
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:JADE_MODE = $mode
    $env:JADE_BOOM_LOG = $LogPath

    # NOTE: launched with a direct blocking call, not Start-Process - under
    # pwsh 7 the Start-Process path launches MAME with a mangled command line
    # and -autoboot_script never loads. The lua exits MAME itself on
    # finish/error; -seconds_to_run is a backstop only.
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

    Write-Host "[jade-test] === mode: $mode ==="
    $MameOutLog = Join-Path $ToolsDir "jade_boomerang_mame_out_$mode.log"
    Push-Location (Split-Path -Parent $Mame)
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $Mame @mameArgs *> $MameOutLog
        $ErrorActionPreference = $prevEap
    } finally {
        Pop-Location
    }

    if (Test-Path $LogPath) {
        Write-Host "[jade-test] $mode log tail:"
        Get-Content -Path $LogPath -Tail 25

        if (Select-String -Path $LogPath -Pattern "\[jade-boom\] ERROR" -Quiet) {
            Write-Host "[jade-test] $mode FAILED (lua reported ERROR)" -ForegroundColor Red
            $anyFailed = $true
        } elseif (-not (Select-String -Path $LogPath -Pattern "\[jade-boom\] PASS" -Quiet)) {
            Write-Host "[jade-test] $mode FAILED (no PASS line)" -ForegroundColor Red
            $anyFailed = $true
        } else {
            Write-Host "[jade-test] $mode PASSED" -ForegroundColor Green
        }
    } else {
        Write-Host "[jade-test] $mode FAILED (no log created)" -ForegroundColor Red
        $anyFailed = $true
    }
}

Remove-Item Env:JADE_MODE -ErrorAction SilentlyContinue
Remove-Item Env:JADE_BOOM_LOG -ErrorAction SilentlyContinue

if ($anyFailed) {
    Write-Error "[jade-test] one or more modes FAILED"
    exit 1
}
Write-Host "[jade-test] ALL MODES PASSED" -ForegroundColor Green
