param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 260,
    [string]$Block = "duck",
    [int]$Gap = 150,
    [string]$Delays = "0,4,8,12,16,24,32,40,48,54,58,62,66,70",
    [switch]$Control,
    [string]$Gaps = "60,70,80,86,90,96,100,104,110",
    [int]$P1Char = 2,
    [switch]$Verbose2
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "mileena_roll_punish_test.lua"
$Log = Join-Path $ToolsDir "mileena_roll_punish_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:MRP_LOG = $Log; $env:MRP_BLOCK = $Block; $env:MRP_GAP = "$Gap"; $env:MRP_DELAYS = $Delays
$env:MRP_GAPS = $Gaps; $env:MRP_P1CHAR = "$P1Char"
if ($Verbose2) { $env:MRP_VERBOSE = "1" } else { Remove-Item Env:\MRP_VERBOSE -ErrorAction SilentlyContinue }
if ($Control) { $env:MRP_CONTROL = "1" } else { Remove-Item Env:\MRP_CONTROL -ErrorAction SilentlyContinue }
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-cfg_directory","C:\MAME\cfg",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "mileena_roll_punish_mame.log") } finally { Pop-Location }
foreach ($e in @("MRP_LOG","MRP_BLOCK","MRP_GAP","MRP_DELAYS","MRP_GAPS","MRP_CONTROL","MRP_P1CHAR","MRP_VERBOSE")) { Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }
if (Test-Path $Log) { Get-Content $Log } else { Write-Host "NO LOG" }
