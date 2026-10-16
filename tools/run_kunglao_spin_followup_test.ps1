param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200,
    [int]$Trials = 4,
    [int]$Trace = 1,
    [string]$Tag = ""
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "kunglao_spin_followup_test.lua"
$suffix = if ($Tag -ne "") { "_$Tag" } else { "" }
$Log = Join-Path $ToolsDir "kunglao_spin_followup_test$suffix.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:KLS_LOG = $Log; $env:KLS_TRIALS = "$Trials"; $env:KLS_TRACE = "$Trace"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-cfg_directory","C:\MAME\cfg",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "kunglao_spin_followup_mame$suffix.log") } finally { Pop-Location }
foreach ($e in @("KLS_LOG","KLS_TRIALS","KLS_TRACE")) { Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }
if (Test-Path $Log) { Get-Content $Log } else { Write-Host "NO LOG" }
