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
$LuaScript = Join-Path $ToolsDir "hole_locate.lua"
$LogPath = Join-Path $ToolsDir "hole_locate.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\hole\run_$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:HOLE_LOG = $LogPath
$ReadyFile = Join-Path $ToolsDir "hole_locate_ready.flag"
Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
$env:HOLE_READY = $ReadyFile

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript, "-sound", "none",
    "-seconds_to_run", $Seconds
)

Write-Host "[hole] locating the portal hole"
Push-Location (Split-Path -Parent $Mame)
try {
    $ErrorActionPreference = "Continue"
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "hole_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "hole_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", $poker,
        "-ProcessId", $mameProc.Id, "-ReadyFile", $ReadyFile, "-TimeoutSec", 180) | Out-Null
    $mameProc.WaitForExit()
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT, Env:HOLE_LOG, Env:HOLE_READY -ErrorAction SilentlyContinue
}

Write-Host "[hole] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[hole] FAILED (no log)"; exit 1 }
Get-Content -Path $LogPath -Tail 40
