param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs; on pwsh 7.3+ that alone would be promoted to a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "peak_stage_test.lua"
$LogPath = Join-Path $ToolsDir "peak_stage_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\peak_stage\run_$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:PEAK_LOG = $LogPath
$ReadyFile = Join-Path $ToolsDir "peak_stage_ready.flag"
Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
$env:PEAK_READY = $ReadyFile

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", 300
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }
if ($Sound) { $mameArgs += @("-wavwrite", (Join-Path $ToolsDir "peak_stage_audio.wav")) }

Write-Host "[peak] launching THE OVERLOOK stage test..."
Push-Location (Split-Path -Parent $Mame)
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # Source-built ROMs never match MAME's CRC table, so the red "press any
    # key" warning is posted on EVERY run.  -seconds_to_run counts EMULATED
    # time, so a MAME parked on that screen never times out: it sits at ~0 CPU
    # forever and looks exactly like "still booting".  The dismisser has to be
    # its OWN process - see the header of tools/mame_dismiss_warning.ps1 for why
    # doing it from this shell can never work.
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "peak_stage_mame_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "peak_stage_mame_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy","Bypass","-File",$poker,
        "-ProcessId",$mameProc.Id,"-ReadyFile",$ReadyFile,"-TimeoutSec",180) | Out-Null
    $mameProc.WaitForExit()
    $ErrorActionPreference = $prev
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:PEAK_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PEAK_READY -ErrorAction SilentlyContinue
}

Write-Host "[peak] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[peak] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath -Tail 30

# The field report proves the geometry and the scroll rates.  It does NOT prove
# the picture is right - look at the three snapshots.
if (-not (Select-String -Path $LogPath -Pattern "\[peak\] PASS" -Quiet)) {
    Write-Error "[peak] FAILED - see the field report above"
    exit 1
}
