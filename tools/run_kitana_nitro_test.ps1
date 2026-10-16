param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\test",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 60,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "kitana_nitro_test.lua"
$LogPath = Join-Path $ToolsDir "kitana_nitro_test.log"
$SnapshotRoot = Join-Path $ToolsDir "screens\kitana_nitro"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the kahn launcher precedent). Still relevant even though
# this test build boots straight to a fight (test_mode=1 in MKAMODE.ASM).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

# NOTE: launched with a direct blocking call, not Start-Process.  Under
# pwsh 7 the Start-Process path in run_mame_small.ps1 launches MAME with
# a mangled command line and -autoboot_script never loads (no [LUA] line).
# The lua exits MAME itself on finish/error; -seconds_to_run is a backstop.
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

Write-Host "[kitnitro-test] Launching Kitana nitro kick test_mode build (Down, Forward + LK)..."
$MameOutLog = Join-Path $ToolsDir "kitana_nitro_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
}

$failed = $false
if (Test-Path $LogPath) {
    Write-Host "[kitnitro-test] Log tail:"
    Get-Content -Path $LogPath -Tail 40

    if (Select-String -Path $LogPath -Pattern "\[kitnitro\] ERROR" -Quiet) {
        Write-Error "[kitnitro-test] Lua reported an error."
        $failed = $true
    }
    if (-not (Select-String -Path $LogPath -Pattern "\[kitnitro\] PASS" -Quiet)) {
        Write-Error "[kitnitro-test] Lua did not report PASS."
        $failed = $true
    }
} else {
    Write-Error "[kitnitro-test] Lua log was not created."
    $failed = $true
}

Write-Host "[kitnitro-test] Snapshots: $RunSnapshots"
if ($failed) { exit 1 }
