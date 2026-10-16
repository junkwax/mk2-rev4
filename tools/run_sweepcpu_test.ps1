# run_sweepcpu_test.ps1 - does the CPU duck-block repeated sweeps and answer
# them low?  See tools/sweep_addon_sweepcpu.lua for what is measured.
#
# Reuses battle_stability_sweep.lua as the harness (matchup + select screen);
# the addon is copied into tools/sweep_addon.lua for the run and removed after,
# or every later stability sweep would pick it up and drive P1.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200,
    [int]$P1 = 1,          # Liu Kang sweeps
    [int]$P2 = 11,         # Jax drone
    [int]$Diff = 9,
    [int]$Dist = 70,
    [string]$Tag = "run"
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_sweepcpu.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "sweepcpu_$Tag.txt"

Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "$P2"
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "2400"
$env:SWEEP_LABEL = "sweepcpu"
$env:SWEEP_LOG = Join-Path $ToolsDir "sweepcpu_sweep.log"
$env:SWEEP_P2_HUMAN = "0"
$env:SWEEP_NO_HP_PIN = "1"   # the addon pins both bars itself
$env:SWPCPU_LOG = $Log
$env:SWPCPU_DIFF = "$Diff"
$env:SWPCPU_DIST = "$Dist"

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop,"-nothrottle")

Write-Host "[swpcpu] P1=$P1 sweeps P2=$P2 (drone) diff=$Diff dist=$Dist ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "sweepcpu_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "sweepcpu_mame.err")

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
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL","SWEEP_LOG",
                 "SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","SWPCPU_LOG","SWPCPU_DIFF","SWPCPU_DIST")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[swpcpu] no log produced" }
