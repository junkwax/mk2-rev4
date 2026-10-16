param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [ValidateSet("coin","netplay")][string]$Mode = "coin",
    [int]$Backstop = 180
)
# Boots the ROM with an EMPTY nvram and checks the credit gate.
#   -Mode coin     : START must be refused at 0 credits, accepted after coins
#   -Mode netplay  : f_netplay poked to 1 must make START work at 0 credits
# See tools/coin_freeplay_probe.lua.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "coin_freeplay_probe.lua"
$Log = Join-Path $ToolsDir "coin_freeplay_$Mode.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame,mame_mk2test -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:COIN_LOG  = $Log
$env:COIN_MODE = $Mode
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[coin] mode=$Mode ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "coin_freeplay_mame_$Mode.log") } finally { Pop-Location }
Remove-Item Env:\COIN_LOG,Env:\COIN_MODE -ErrorAction SilentlyContinue

if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host $_ } }
else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
