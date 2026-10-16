param(
    [string]$Tag = "run",
    [int]$Measure = 900,
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Seconds = 120
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "hud_perf_probe.lua"
$LogPath = Join-Path $ToolsDir "hud_perf_probe.log"

Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:HUD_LOG = $LogPath          # the probe APPENDS, so runs stack up
$env:HUD_TAG = $Tag
$env:HUD_MEASURE = $Measure
$ReadyFile = Join-Path $ToolsDir "hud_perf_ready.flag"
Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
$env:HUD_READY = $ReadyFile

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-autoboot_script", $LuaScript, "-sound", "none",
    "-seconds_to_run", $Seconds
)

Write-Host "[perf] $Tag - $Measure fight frames"
Push-Location (Split-Path -Parent $Mame)
try {
    $ErrorActionPreference = "Continue"
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "hud_perf_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "hud_perf_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", $poker,
        "-ProcessId", $mameProc.Id, "-ReadyFile", $ReadyFile, "-TimeoutSec", 120) | Out-Null
    $mameProc.WaitForExit()
} finally {
    Pop-Location
    Remove-Item Env:HUD_LOG, Env:HUD_TAG, Env:HUD_MEASURE, Env:HUD_READY -ErrorAction SilentlyContinue
}

Get-Content -Path $LogPath -Tail 12
