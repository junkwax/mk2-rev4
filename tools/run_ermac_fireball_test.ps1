param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 150,
    [int]$Snap = 0,
    [switch]$Sound
)
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "ermac_fireball_test.lua"
$LogPath = Join-Path $ToolsDir "ermac_fireball_test.log"
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:FB_LOG = $LogPath
$env:FB_SNAP = [string]$Snap
$env:FB_DUMP = $env:FB_DUMP
$args2 = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
           "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
           "-autoboot_script",$Lua,"-seconds_to_run",$BackstopEmuSeconds)
if (-not $Sound) { $args2 += @("-sound","none") }
$Out = Join-Path $ToolsDir "ermac_fireball_mame.log"
Push-Location (Split-Path -Parent $Mame)
# MAME writes its ROM-hash complaint to stderr on every custom build (mamerom.py
# spoofs the CRCs, not the SHA1s), and with ErrorActionPreference=Stop PowerShell
# turns that into a terminating error - the run completes and the verdict below is
# never printed.  Let the native command's stderr be output, not an exception.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & $Mame @args2 *> $Out } finally {
  $ErrorActionPreference = $prevEAP
  Pop-Location
  Remove-Item Env:\FB_LOG,Env:\FB_SNAP -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
  $v = Select-String -Path $LogPath -Pattern '^\[fb\] (PASS|FAIL)' | Select-Object -Last 1
  if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never started; see $Out" }
