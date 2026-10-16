param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 300,
    [int]$Diff = 9,
    [int]$Seed = 0
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "cage_drone_ball_probe.lua"
$Log = Join-Path $ToolsDir "cage_drone_ball_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
$env:CDB_LOG = $Log; $env:CDB_DIFF = "$Diff"; $env:CDB_SEED = "$Seed"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "cage_drone_ball_mame.log") } finally { Pop-Location }
foreach ($e in @("CDB_LOG","CDB_DIFF","CDB_SEED")) { Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }
if (Test-Path $Log) { Get-Content $Log | Select-Object -Last 30 }
else { Write-Host "NO LOG" }
