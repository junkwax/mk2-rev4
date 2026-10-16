param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 240
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "sz_juggle_freeze_test.lua"
$Log = Join-Path $ToolsDir "sz_juggle_freeze_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:JFREEZE_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[jfreeze] flip-kick then ground freeze on an airborne victim ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "sz_juggle_freeze_mame.log") } finally { Pop-Location }
Remove-Item "Env:\JFREEZE_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== SZ ICE BLAST vs JUGGLED OPPONENT ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "RESULT|PASS |FAIL |fight start|FROZE|ice thrown|MISSING|p1act=" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
