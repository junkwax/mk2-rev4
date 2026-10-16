param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Seconds = 180
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "hitpop_demo.lua"
$LogPath = Join-Path $ToolsDir "hitpop_demo.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\hitpop\run_$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:HITPOP_LOG = $LogPath
$ReadyFile = Join-Path $ToolsDir "hitpop_ready.flag"
Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
$env:HITPOP_READY = $ReadyFile

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript, "-sound", "none",
    "-seconds_to_run", $Seconds
)

Write-Host "[pop] hit pop"
Push-Location (Split-Path -Parent $Mame)
try {
    $ErrorActionPreference = "Continue"
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "hitpop_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "hitpop_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", $poker,
        "-ProcessId", $mameProc.Id, "-ReadyFile", $ReadyFile, "-TimeoutSec", 180) | Out-Null
    $mameProc.WaitForExit()
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT, Env:HITPOP_LOG, Env:HITPOP_READY -ErrorAction SilentlyContinue
}

Write-Host "[pop] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[pop] FAILED (no log)"; exit 1 }
Get-Content -Path $LogPath -Tail 40
