param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    # 200 truncated the run: MAME exited during the control_idle trial, so no
    # verdict was ever printed and the log just stopped mid-trial.
    [int]$Backstop = 400
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_newreact_test.lua"
$Log = Join-Path $ToolsDir "drone_newreact_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:NEWREACT_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[newreact] running new drone reaction test ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_newreact_mame.log") } finally { Pop-Location }
Remove-Item "Env:\NEWREACT_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== NEW DRONE REACTIONS ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "reaction #|RESULT|PASS |FAIL |ERROR|trial ->|done:|fight start" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced" }
Write-Host "Full log: $Log"
