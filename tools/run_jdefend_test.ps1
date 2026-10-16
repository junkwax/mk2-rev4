# run_jdefend_test.ps1 - the PERFECT BLOCK (jdefend, MAINEQU.ASM), measured.
#
# See tools/sweep_addon_jdefend.lua for what is measured and why the samples
# are bucketed by the ROM's own f_jdefend word rather than by the rig's idea
# of its own timing.
#
# Reuses battle_stability_sweep.lua purely as a harness: it forces the matchup
# (SWEEP_P1/P2/STAGE), walks the select screen, and loads tools/sweep_addon.lua
# if that file exists. The addon is COPIED into place for the run and removed
# afterwards, so a later stability sweep does not pick it up and drive sticks.
param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 220,
    [switch]$Throttle,
    [switch]$Shots,     # snapshot the white flash
    [int]$P1 = 1        # Liu Kang - his high kick is an ordinary 8-chip strike
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_jdefend.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "jdefend.txt"
$SnapDir = Join-Path $ToolsDir "screens\jdefend"

# Two MAME rigs fight over the same window and kill each other; a leftover
# key-poker job posts into whatever window appears next. Clear both first.
Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $SnapDir | Out-Null
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "11"          # Jax
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "5000"
$env:SWEEP_LABEL = "jdefend"
$env:SWEEP_LOG = Join-Path $ToolsDir "jdefend_sweep.log"
$env:SWEEP_P2_HUMAN = "1"     # jdjoyonly = 1: the blocker must be a joystick
$env:SWEEP_NO_HP_PIN = "0"
$env:JD_LOG = $Log
if ($Shots) { $env:JD_SHOTS = "1" }

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
if (-not $Throttle) { $mameArgs += "-nothrottle" }

Write-Host "[jd] Liu Kang (P1) vs Jax (P2, human), Dead Pool ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "jdefend_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "jdefend_mame.err")

# Poke past the ROM-warning screen; without this the battle silently never
# starts and scores as a failure it never had.
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
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","JD_LOG","JD_SHOTS")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[jd] no log produced" }
if ($Shots) { Write-Host "[jd] snapshots: $SnapDir" }
