param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string]$Tag = "base",
    [int]$BackstopEmuSeconds = 120
)

# KOMBAT TOMB bat probe: see tools/tomb_bat_probe.lua.  Runs under
# mame_mk2test.exe with private nvram/cfg dirs so it cannot kill, or be killed
# by, another rig (doc: MAME rig contention).

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "tomb_bat_probe.lua"
$LogPath   = Join-Path $ToolsDir "tomb_bat_probe_$Tag.log"
$RunSnapshots = Join-Path $ToolsDir "screens\tomb_bat\$Tag"
$Private = Join-Path $env:TEMP "mk2_tomb_bat_probe"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Get-ChildItem -Path $RunSnapshots -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Private -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$Private\nvram", "$Private\cfg" | Out-Null

$env:MK2_TOMB_TAG = $Tag

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-nvram_directory", "$Private\nvram",
    "-cfg_directory", "$Private\cfg",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)

Write-Host "[tomb-probe] Launching KOMBAT TOMB bat probe (tag=$Tag)..."
$MameOutLog = Join-Path $ToolsDir "tomb_bat_probe_${Tag}_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally { Pop-Location }

if (Test-Path $LogPath) {
    Write-Host "[tomb-probe] Log tail:"
    Get-Content -Path $LogPath -Tail 40
} else {
    Write-Error "[tomb-probe] No lua log at $LogPath - did the script load?"
}
Get-ChildItem -Path $RunSnapshots -Filter *.png -ErrorAction SilentlyContinue | Select-Object Name, Length
