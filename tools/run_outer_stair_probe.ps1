param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Stage = 22,          # 22 = 0x16 = Outer Haven, 7 = stock Portal (control run)
    [ValidateSet("sweep","pan")][string]$Mode = "sweep",
    [int]$Backstop = 150
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "outer_stair_probe.lua"
$Log = Join-Path $ToolsDir "outer_stair_probe_${Stage}_$Mode.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:STAIRPROBE_LOG = $Log
$env:MK2_STAIR_STAGE = "$Stage"
$env:MK2_STAIR_MODE = $Mode
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$ToolsDir,
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[stair] running Outer Haven staircase probe (stage $Stage, mode $Mode) ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "outer_stair_probe_mame.log") } finally { Pop-Location }
Remove-Item "Env:\STAIRPROBE_LOG","Env:\MK2_STAIR_STAGE","Env:\MK2_STAIR_MODE" -ErrorAction SilentlyContinue

Write-Host "`n===== STAIRCASE VIEW SWEEP ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "tlx3|pan stop|baklst|initial view|views seen|PASS|FAIL|TIMEOUT|sweep base|pan mode" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
