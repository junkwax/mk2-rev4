param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Seconds = 180
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "srt_flash_test.lua"
$LogPath = Join-Path $ToolsDir "srt_flash_test.log"

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:SRT_LOG = $LogPath
$ReadyFile = Join-Path $ToolsDir "srt_flash_ready.flag"
Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
$env:SRT_READY = $ReadyFile

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-autoboot_script", $LuaScript, "-sound", "none",
    "-seconds_to_run", $Seconds
)

Write-Host "[srt] VRAM block-fill flash test"
Push-Location (Split-Path -Parent $Mame)
try {
    $ErrorActionPreference = "Continue"
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "srt_flash_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "srt_flash_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", $poker,
        "-ProcessId", $mameProc.Id, "-ReadyFile", $ReadyFile, "-TimeoutSec", 120) | Out-Null
    $mameProc.WaitForExit()
} finally {
    Pop-Location
    Remove-Item Env:SRT_LOG, Env:SRT_READY -ErrorAction SilentlyContinue
}

if (-not (Test-Path $LogPath)) { Write-Error "[srt] FAILED (no log)"; exit 1 }
Get-Content -Path $LogPath -Tail 20
if (-not (Select-String -Path $LogPath -Pattern "PASS" -Quiet)) {
    Write-Error "[srt] FAILED - see above"; exit 1
}
