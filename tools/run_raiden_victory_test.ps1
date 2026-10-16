param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 150,
    [int]$Observe = 420,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "raiden_victory_test.lua"
$LogPath = Join-Path $ToolsDir "raiden_victory_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\raiden_victory\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:RAIDEN_VIC_LOG = $LogPath
$env:RAIDEN_VIC_OBSERVE = [string]$Observe

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

Write-Host "[rdvic] Raiden victory bolt-persistence probe"
$MameOutLog = Join-Path $ToolsDir "raiden_victory_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    Remove-Item Env:\RAIDEN_VIC_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\RAIDEN_VIC_OBSERVE -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    $verdict = Select-String -Path $LogPath -Pattern "^\[rdvic\] (PASS|FAIL) " | Select-Object -Last 1
    if ($verdict) { Write-Host "[rdvic] $($verdict.Line)" } else { Write-Warning "[rdvic] no verdict" }
} else {
    Write-Error "[rdvic] no log written (see $MameOutLog)"
}
Write-Host "[rdvic] Log:       $LogPath"
Write-Host "[rdvic] Snapshots: $RunSnapshots"
