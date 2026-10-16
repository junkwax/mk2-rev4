param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 420
)
# Drives a 1P match to a loss so the game reaches the continue / buy-in screen,
# then dumps the process table every so often so we can see WHERE the master
# process is parked. See tools/buyin_hang_probe.lua.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "buyin_hang_probe.lua"
$Log = Join-Path $ToolsDir "buyin_hang_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:BUYIN_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[buyin] driving a 1P loss to the continue screen ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "buyin_hang_mame.log") } finally { Pop-Location }
Remove-Item Env:\BUYIN_LOG -ErrorAction SilentlyContinue

if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host $_ } }
else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
