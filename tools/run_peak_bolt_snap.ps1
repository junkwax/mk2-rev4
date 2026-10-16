param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 200,
    [string]$Tag = "run",
    [switch]$Sound
)
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "peak_bolt_snap.lua"
$LogPath = Join-Path $ToolsDir "peak_bolt_snap.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\peak_bolt\$Tag`_$RunId"
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
$NvramDir = Join-Path $env:TEMP "mk2_bolt_nvram_$RunId"
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null
Get-Process mame,mame_mk2test -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$env:MK2_ROOT = $Root
$env:BOLT_LOG = $LogPath
$env:BOLT_READY = Join-Path $ToolsDir "peak_bolt_ready.flag"
Remove-Item -LiteralPath $env:BOLT_READY -Force -ErrorAction SilentlyContinue
$args2 = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
           "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
           "-snapshot_directory",$SnapDir,"-nvram_directory",$NvramDir,
           "-autoboot_script",$Lua,"-seconds_to_run",$BackstopEmuSeconds)
if (-not $Sound) { $args2 += @("-sound","none") }
$Out = Join-Path $ToolsDir "peak_bolt_snap_mame.log"
Push-Location (Split-Path -Parent $Mame)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & $Mame @args2 *> $Out } finally {
  $ErrorActionPreference = $prevEAP
  Pop-Location
  Remove-Item Env:\BOLT_LOG,Env:\BOLT_READY -ErrorAction SilentlyContinue
}
Write-Host "snapshots: $SnapDir"
if (Test-Path $LogPath) { Get-Content $LogPath | Select-Object -Last 12 }
else { Write-Host "NO LOG - MAME never started; see $Out" }
