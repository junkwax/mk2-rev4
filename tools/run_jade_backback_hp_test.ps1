param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,
    [switch]$Sound
)
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "jade_backback_hp_test.lua"
$LogPath = Join-Path $ToolsDir "jade_backback_hp_test.log"
$SnapDir = Join-Path $ToolsDir "screens\jade_backback"
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Get-ChildItem -Path $SnapDir -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:JADE_BB_LOG = $LogPath

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution, "-video", "gdi",
    "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript, "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[jade-bb] Launching Back,Back+HP repro..."
$MameOutLog = Join-Path $ToolsDir "jade_backback_hp_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally {
    Pop-Location
    Remove-Item Env:\JADE_BB_LOG -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
    Write-Host "[jade-bb] Log tail:"
    Get-Content -Path $LogPath -Tail 40
} else {
    Write-Error "[jade-bb] Lua log not created (see $MameOutLog)."
}
