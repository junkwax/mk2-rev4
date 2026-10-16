param(
    [ValidateSet("peak")]
    [string]$Stage = "peak",
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Seconds = 240,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs; on pwsh 7.3+ that alone would be promoted to a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "flatband_demo.lua"
$LogPath = Join-Path $ToolsDir "flatband_demo_$Stage.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\flatband\$Stage`_$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:FXDEMO_LOG = $LogPath
$env:FXDEMO_STAGE = $Stage
$ReadyFile = Join-Path $ToolsDir "flatband_demo_ready.flag"
Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
$env:FXDEMO_READY = $ReadyFile

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $Seconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[fx] flat colour band demo - $Stage"
Push-Location (Split-Path -Parent $Mame)
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # Source-built ROMs never match MAME's CRC table, so the red "press any
    # key" warning is posted on EVERY run.  -seconds_to_run counts EMULATED
    # time, so a MAME parked on that screen never times out.  The dismisser
    # has to be its OWN process - see tools/mame_dismiss_warning.ps1.
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "flatband_demo_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "flatband_demo_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", $poker,
        "-ProcessId", $mameProc.Id, "-ReadyFile", $ReadyFile, "-TimeoutSec", 180) | Out-Null
    $mameProc.WaitForExit()
    $ErrorActionPreference = $prev
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:FXDEMO_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:FXDEMO_STAGE -ErrorAction SilentlyContinue
    Remove-Item Env:FXDEMO_READY -ErrorAction SilentlyContinue
}

Write-Host "[fx] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[fx] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath -Tail 40

if (-not (Select-String -Path $LogPath -Pattern "\[fx\] PASS" -Quiet)) {
    Write-Error "[fx] FAILED - see the report above"
    exit 1
}
