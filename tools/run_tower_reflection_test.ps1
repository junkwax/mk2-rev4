param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tag = "refl",
    [int]$BackstopEmuSeconds = 120
)

# THE TOWER's guard reflections - see doc/TOWER_GUARD_REFLECTIONS.md.
# Forces a match onto the stage, parks the camera at the left scroll limit so
# all three left-hand guards are on screen, then reports the baklst1 inventory
# and watches each strip's osag for long enough to prove the checkerboard
# alternates. A still frame cannot show that: the two phases are the same strip
# with the dither inverted.

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "tower_reflection_test.lua"
$LogPath   = Join-Path $ToolsDir "tower_reflection_test_$Tag.log"
$RunSnapshots = Join-Path $ToolsDir "screens\tower_reflection\$Tag"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Get-ChildItem -Path $RunSnapshots -Recurse -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_REFL_TAG = $Tag

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

Write-Host "[refl-test] Launching THE TOWER reflection test (tag=$Tag)..."
$MameOutLog = Join-Path $ToolsDir "tower_reflection_test_${Tag}_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally { Pop-Location }

if (Test-Path $LogPath) {
    Write-Host "[refl-test] Log tail:"
    Get-Content -Path $LogPath -Tail 40
} else {
    Write-Error "[refl-test] No lua log at $LogPath - did the script load?"
}
Write-Host "[refl-test] Snapshots: $RunSnapshots"
