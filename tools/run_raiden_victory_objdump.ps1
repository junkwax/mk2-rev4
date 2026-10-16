param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$BackstopEmuSeconds = 150,
    [string]$Dumps = "0,20,45,60,80,100,140,180,240",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "raiden_victory_objdump.lua"
$LogPath = Join-Path $ToolsDir "raiden_victory_objdump.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\raiden_objdump\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:RDOD_LOG = $LogPath
$env:RDOD_DUMPS = $Dumps

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
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

Write-Host "[rdod] Raiden victory object dump"
$MameOutLog = Join-Path $ToolsDir "raiden_victory_objdump_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    Remove-Item Env:\RDOD_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\RDOD_DUMPS -ErrorAction SilentlyContinue
}

Write-Host "[rdod] Log:       $LogPath"
Write-Host "[rdod] Snapshots: $RunSnapshots"
