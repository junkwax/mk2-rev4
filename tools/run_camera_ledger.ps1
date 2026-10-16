param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Frames = 3000,
    [int]$Backstop = 200,
    [string]$Tag = ""
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "camera_ledger.lua"
$suffix = if ($Tag) { "_$Tag" } else { "" }
$Log = Join-Path $ToolsDir "camera_ledger$suffix.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:CAMLEDGER_LOG = $Log
$env:CAMLEDGER_FRAMES = "$Frames"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[ledger] accounting for every worldtly write over $Frames fight frames ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "camera_ledger_mame$suffix.log") } finally { Pop-Location }
Remove-Item "Env:\CAMLEDGER_LOG","Env:\CAMLEDGER_FRAMES" -ErrorAction SilentlyContinue

Write-Host "`n===== WORLDTLY LEDGER ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "fight start|^\[ledger\] burst |POP f|bursts of|single-frame|overlapped|worst single|PASS |FAIL |MISSING|ERROR" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
