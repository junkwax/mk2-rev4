param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tag = "base",
    [string]$Stage = "19",          # hex curback to select - 1a = THE PIT (MK1)
    [string]$Watch = "",            # .bss counters to track, e.g. wf_lines,wf_short (1b parallax)
    [int]$BackstopEmuSeconds = 200
)
# THE CAVE stage probe - selects curback 019h on the VS screen with real input,
# then parks the camera at left/mid/right.  See tools/cave_stage_probe.lua.
# Does NOT kill other MAME processes: it runs its own windowed instance.

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "cave_stage_probe.lua"
$LogPath   = Join-Path $ToolsDir "cave_stage_probe_$Tag.log"
$RunSnapshots = Join-Path $ToolsDir "screens\cave_stage\$Tag"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Get-ChildItem -Path $RunSnapshots -Filter *.png -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$env:MK2_CAVE_TAG = $Tag
$env:MK2_CAVE_STAGE = $Stage
$env:MK2_CAVE_WATCH = $Watch

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-nothrottle",
    "-nvram_directory", (Join-Path $RunSnapshots "nvram"),
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)

Write-Host "[cave-probe] Launching THE CAVE stage probe (tag=$Tag)..."
$MameOutLog = Join-Path $ToolsDir "cave_stage_probe_${Tag}_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally { Pop-Location }

if (Test-Path $LogPath) {
    Write-Host "[cave-probe] Log:"
    Get-Content -Path $LogPath
} else {
    Write-Error "[cave-probe] No lua log at $LogPath - did the script load?"
}
Write-Host "[cave-probe] Snapshots: $RunSnapshots"
Get-ChildItem -Path $RunSnapshots -Filter *.png -Recurse -ErrorAction SilentlyContinue | Select-Object FullName, Length
