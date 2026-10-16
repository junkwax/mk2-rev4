param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tag = "base",
    [int]$BackstopEmuSeconds = 120
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "lair_stage_probe.lua"
$LogPath   = Join-Path $ToolsDir "lair_stage_probe_$Tag.log"
$RunSnapshots = Join-Path $ToolsDir "screens\tower_stage\$Tag"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Get-ChildItem -Path $RunSnapshots -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_LAIR_TAG = $Tag

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)

Write-Host "[lair-probe] Launching GORO'S LAIR stage probe (tag=$Tag)..."
$MameOutLog = Join-Path $ToolsDir "lair_stage_probe_${Tag}_mame.log"
# MAME prints a WRONG CHECKSUMS block to stderr for every source-built chip.
# With $ErrorActionPreference = "Stop" that stderr is a TERMINATING error and
# the probe dies before the emulator has run a frame, so it is relaxed for the
# duration of the call only.
Push-Location (Split-Path -Parent $Mame)
try {
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs *> $MameOutLog
} finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
}

if (Test-Path $LogPath) {
    Write-Host "[lair-probe] Log tail:"
    Get-Content -Path $LogPath -Tail 60
} else {
    Write-Error "[lair-probe] No lua log at $LogPath - did the script load?"
}
Write-Host "[lair-probe] Snapshots: $RunSnapshots"
Get-ChildItem -Path $RunSnapshots -Filter *.png -ErrorAction SilentlyContinue | Select-Object Name, Length
