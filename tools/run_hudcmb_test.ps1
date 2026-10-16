# run_hudcmb_test.ps1 - the LIVE COMBO READOUT (hudcmb).  See
# tools/sweep_addon_hudcmb.lua for what is measured.
#
# Reuses battle_stability_sweep.lua purely as a harness: it already forces the
# matchup (SWEEP_P1/P2/STAGE) and walks the select screen, and it loads
# tools/sweep_addon.lua if that file exists.  The addon is COPIED into place
# for the run and removed afterwards, because any later stability sweep would
# otherwise pick it up and drive the sticks.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 200,
    [switch]$Throttle,
    [int]$P1 = 1,      # Liu Kang
    [int]$P2 = 11      # Jax
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_hudcmb.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "hudcmb.txt"
$SnapDir = Join-Path $ToolsDir "screens\hudcmb"

# Two MAME rigs fight over the same window and kill each other; a leftover
# key-poker job posts into whatever window appears next.  Clear both first.
Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item (Join-Path $SnapDir "*.png") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "$P2"
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "2400"
$env:SWEEP_LABEL = "hudcmb"
$env:SWEEP_LOG = Join-Path $ToolsDir "hudcmb_sweep.log"
$env:SWEEP_P2_HUMAN = "1"    # a drone would block and duck; this one stands there
$env:SWEEP_NO_HP_PIN = "0"
$env:HUDCMB_LOG = $Log

# -cfg_directory is NOT optional here.  Run from the repo, MAME picks up the
# committed cfg/mk2.cfg, which has the TEST switch ON: the game boots straight
# into the operator menu and sits at gstate 8 forever.  The fight never starts
# and it reads exactly like the feature under test doing nothing.
$CfgDir = Join-Path $ToolsDir "screens\_cfg"
New-Item -ItemType Directory -Force $CfgDir | Out-Null

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-cfg_directory",$CfgDir,
  "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
if (-not $Throttle) { $mameArgs += "-nothrottle" }

# Called directly, NOT through Start-Process.  Under Start-Process the harness
# does not pick the addon up - it runs the fight and reports a clean sweep with
# no addon output at all, which reads exactly like a rig that measured nothing
# and found nothing.  battle_stability_sweep.lua drives the select screen
# through ioport, so nothing has to poke the ROM-warning screen either.
Write-Host "[hudcmb] P1=$P1 vs P2=$P2 (human), Dead Pool ..."
& $Mame @mameArgs 2>&1 | Tee-Object -FilePath (Join-Path $ToolsDir "hudcmb_mame.log") | Out-Null

Remove-Item $Addon -ErrorAction SilentlyContinue
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL",
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","HUDCMB_LOG")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[hudcmb] no log produced" }
Write-Host "[hudcmb] snapshots: $SnapDir"
