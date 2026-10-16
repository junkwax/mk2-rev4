param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tag = "bk",
    [int]$BackstopEmuSeconds = 150
)

# THE TOWER's backdrop reflection - wall, arch, clouds, monk and the carpet
# runner pass. See doc/TOWER_GUARD_REFLECTIONS.md. Three camera stops; the
# log says whether every wall object lands on marble, whether every sky and
# monk reflection tracks its source, and what the frame cost.

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "tower_backdrop_test.lua"
$LogPath   = Join-Path $ToolsDir "tower_backdrop_test_$Tag.log"
$RunSnapshots = Join-Path $ToolsDir "screens\tower_backdrop\$Tag"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Get-ChildItem -Path $RunSnapshots -Recurse -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_BK_TAG = $Tag

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

Write-Host "[bk-test] Launching THE TOWER backdrop reflection test (tag=$Tag)..."
$MameOutLog = Join-Path $ToolsDir "tower_backdrop_test_${Tag}_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally { Pop-Location }

if (Test-Path $LogPath) {
    Get-Content -Path $LogPath -Tail 80
} else {
    Write-Error "[bk-test] No lua log at $LogPath - did the script load?"
}
Write-Host "[bk-test] Snapshots: $RunSnapshots"
