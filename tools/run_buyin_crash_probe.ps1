param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 400
)
# Reproduces the portal CRASH_lockup and dumps registers + both stacks at the
# moment of the trap, so the faulting address can be resolved to a symbol
# instead of guessed at. See tools/buyin_crash_probe.lua.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "buyin_crash_probe.lua"
$Log = Join-Path $ToolsDir "buyin_crash_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:CRASH_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[crash] reproducing portal lockup ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "crash_probe_mame.log") } finally { Pop-Location }
Remove-Item Env:\CRASH_LOG -ErrorAction SilentlyContinue

if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host $_ } }
else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
