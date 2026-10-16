param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 180,
    [int]$Trials = 3
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "reptile_orb_timing_test.lua"
$Log = Join-Path $ToolsDir "reptile_orb_timing_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:ROB_LOG = $Log; $env:ROB_TRIALS = "$Trials"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-cfg_directory","C:\MAME\cfg",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "reptile_orb_timing_mame.log") } finally { Pop-Location }
foreach ($e in @("ROB_LOG","ROB_TRIALS")) { Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }
if (Test-Path $Log) { Get-Content $Log } else { Write-Host "NO LOG" }
