param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [ValidateSet("continue","initials","twoplayer")][string]$Mode = "continue",
    [int]$Backstop = 480
)
# Presses START on the continue screen and checks the game actually resumes.
# See tools/buyin_continue_probe.lua.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "buyin_continue_probe.lua"
$Log = Join-Path $ToolsDir "buyin_continue_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:BUYIN_LOG = $Log
$env:BUYIN_MODE = $Mode
$Snaps = Join-Path $ToolsDir "buyin_snaps\$Mode"
Remove-Item -Recurse -Force $Snaps -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Snaps | Out-Null

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$Snaps,
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[cont] continue-screen START test (mode=$Mode) ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "buyin_continue_mame.log") } finally { Pop-Location }
Remove-Item Env:\BUYIN_LOG, Env:\BUYIN_MODE -ErrorAction SilentlyContinue

if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host $_ } }
else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
