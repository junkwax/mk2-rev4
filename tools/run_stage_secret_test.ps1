param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Mode = "secret",          # secret | none | pong
    [int]$BackstopEmuSeconds = 90,
    [switch]$Shot
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "stage_secret_test.lua"
$LogPath = Join-Path $ToolsDir "stage_secret_$Mode.log"

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:STAGE_MODE = $Mode
$env:STAGE_LOG  = $LogPath
if ($Shot) { $env:STAGE_SHOT = "1" }

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32",
    "-skip_gameinfo", "-sound", "none",
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)

Write-Host "[stage-test] mode: $Mode"
$MameOutLog = Join-Path $ToolsDir "stage_secret_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameOutLog } finally {
    Pop-Location
    Remove-Item Env:\STAGE_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\STAGE_LOG  -ErrorAction SilentlyContinue
    Remove-Item Env:\STAGE_SHOT -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Get-Content -Path $LogPath -Tail 40
    if (Select-String -Path $LogPath -Pattern "^\[stage\] PASS" -Quiet) { Write-Host "[stage-test] >>> PASS" }
    elseif (Select-String -Path $LogPath -Pattern "^\[stage\] FAIL" -Quiet) { Write-Host "[stage-test] >>> FAIL" }
    else { Write-Warning "[stage-test] No clean verdict (setup/timeout?)." }
} else { Write-Warning "[stage-test] No log written." }
