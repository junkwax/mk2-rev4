param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 150,
    [int]$Snap = 6,
    [switch]$Sound
)
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "ermac_teleslam_test.lua"
$LogPath = Join-Path $ToolsDir "ermac_teleslam_test.log"
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:TKS_LOG = $LogPath
$env:TKS_SNAP = [string]$Snap
$args2 = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
           "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
           "-autoboot_script",$Lua,"-seconds_to_run",$BackstopEmuSeconds)
if (-not $Sound) { $args2 += @("-sound","none") }
$Out = Join-Path $ToolsDir "ermac_teleslam_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @args2 *> $Out } finally {
  Pop-Location
  Remove-Item Env:\TKS_LOG,Env:\TKS_SNAP -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
  $v = Select-String -Path $LogPath -Pattern '^\[tks\] (PASS|FAIL)' | Select-Object -Last 1
  if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never started; see $Out" }
