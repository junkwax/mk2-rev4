# run_adjgate_test.ps1 - do KOMBAT TOASTS / KOMBO KOUNTER actually gate the
# readouts in a fight?  See tools/sweep_addon_adjgate.lua for what is measured.
#
# Two runs, because one cannot tell "correctly off" from "broken":
#   -Force:off  factory defaults - expect the kounter to run and no toast
#   -Force:on   f_kalout pinned to 1 - expect BOTH to run
#
# nvram is wiped first so the run starts from the factory adjustment values,
# which is the whole point of the default case.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200,
    [switch]$Force
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src   = Join-Path $ToolsDir "sweep_addon_adjgate.lua"
$Lua   = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log   = Join-Path $ToolsDir ("adjgate_" + $(if ($Force) {"on"} else {"off"}) + ".txt")

Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "1"; $env:SWEEP_P2 = "11"; $env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "2400"; $env:SWEEP_LABEL = "adjgate"
$env:SWEEP_LOG = Join-Path $ToolsDir "adjgate_sweep.log"
$env:SWEEP_P2_HUMAN = "1"; $env:SWEEP_NO_HP_PIN = "0"
$env:ADJGATE_LOG = $Log
$env:ADJGATE_FORCE = $(if ($Force) {"1"} else {"0"})

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop,"-nothrottle")

Write-Host "[adjgate] run with ADJGATE_FORCE=$env:ADJGATE_FORCE ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "adjgate_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "adjgate_mame.err")

$wsh = New-Object -ComObject WScript.Shell
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) { break }
    if (Test-Path $Log) { break }
    try { $wsh.AppActivate($proc.Id) | Out-Null; $wsh.SendKeys("{ENTER}") } catch {}
}
$proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

Remove-Item $Addon -ErrorAction SilentlyContinue
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL",
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","ADJGATE_LOG","ADJGATE_FORCE")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue }

if (Test-Path $Log) { Get-Content $Log | Select-Object -Last 12 }
else { Write-Host "[adjgate] NO LOG - the fight never started" }
