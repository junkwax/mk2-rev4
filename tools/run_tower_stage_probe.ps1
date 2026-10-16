param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tag = "base",
    [int]$BackstopEmuSeconds = 120
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "tower_stage_probe.lua"
$LogPath   = Join-Path $ToolsDir "tower_stage_probe_$Tag.log"
$RunSnapshots = Join-Path $ToolsDir "screens\tower_stage\$Tag"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Get-ChildItem -Path $RunSnapshots -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_TOWER_TAG = $Tag

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

Write-Host "[tower-probe] Launching THE TOWER stage probe (tag=$Tag)..."
$MameOutLog = Join-Path $ToolsDir "tower_stage_probe_${Tag}_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally { Pop-Location }

if (Test-Path $LogPath) {
    Write-Host "[tower-probe] Log tail:"
    Get-Content -Path $LogPath -Tail 60
} else {
    Write-Error "[tower-probe] No lua log at $LogPath - did the script load?"
}
Write-Host "[tower-probe] Snapshots: $RunSnapshots"
Get-ChildItem -Path $RunSnapshots -Filter *.png -ErrorAction SilentlyContinue | Select-Object Name, Length
