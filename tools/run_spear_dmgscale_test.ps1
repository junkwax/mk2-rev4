# run_spear_dmgscale_test.ps1 - a stun's free hit lands for FULL damage, and
# the string scales again from the hit after it.  Three moves are exempt from
# dmgscale and this runs any of them:
#
#   -Move spear    Scorpion's spear      (Back,Back + LP)
#   -Move freeze   Sub-Zero's ice ball   (Down,Fwd  + LP)
#   -Move puddle   Sub-Zero's floor ice  (Down,Back + LK)
#
# See tools/sweep_addon_speardmg.lua for what is measured and why.
#
# Reuses battle_stability_sweep.lua purely as a harness: it forces the matchup
# (SWEEP_P1/P2/STAGE) and walks the select screen, and loads tools/sweep_addon.lua
# if that file exists.  The addon is COPIED into place for the run and removed
# afterwards, or a later stability sweep would pick it up and drive the sticks.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 180,
    [switch]$Throttle,
    [int]$P2 = 11,              # the victim: Jax, as a passive HUMAN
    [ValidateSet("spear","freeze","puddle")]
    [string]$Move = "spear",
    # The setup lands as the (Seed+1)th hit of a string.  0 = it opens one.
    # A stun's free hit keeps the string's depth, so at Seed 2 the hit after
    # the spear is worth 1/2 - not full, which is what flip kick, teleport,
    # spear, uppercut used to get (52% of a bar).
    [int]$Seed = 0
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_speardmg.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "spear_dmgscale.txt"

# PRIVATE nvram and cfg, and nothing is killed by name.  This used to stop every
# mame* process and delete C:\MAME\nvram\mk2 - which is the user's cmos, and
# since hidearn that is where the fighters he has EARNED are kept.
$Priv = Join-Path (Split-Path -Parent $ToolsDir) "tmp\spear_scale\priv"
Remove-Item -Recurse -Force $Priv -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram"), (Join-Path $Priv "cfg") | Out-Null
$Poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"

Remove-Item $Log -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

# ft_scorpion = 10, ft_subzero = 8 (MAINEQU.ASM)
$P1 = @{ spear = 10; freeze = 8; puddle = 8 }[$Move]
$env:MOVE = $Move
$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "$P2"
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "3000"
$env:SWEEP_LABEL = "dmgscale_$Move"
$env:SWEEP_LOG = Join-Path $ToolsDir "spear_dmgscale_sweep.log"
$env:SWEEP_P2_HUMAN = "1"     # a passive human: he never blocks and never hits back
$env:SWEEP_NO_HP_PIN = "0"    # P1's bar is pinned; P2's is the instrument
$env:SPEAR_LOG = $Log
$env:SPEAR_SEED = "$Seed"

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-nvram_directory",(Join-Path $Priv "nvram"),"-cfg_directory",(Join-Path $Priv "cfg"),
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
if (-not $Throttle) { $mameArgs += "-nothrottle" }

# The launch is retried: the addon is loaded by dofile at MAME start, and a
# start that races the copy silently produces a battle with no measurement at
# all - a run that looks like a failure it never had.  No log file means the
# addon never ran, which is a rig fault, not a result.
for ($try = 1; $try -le 3; $try++) {
    Copy-Item $Src $Addon -Force
    if (-not (Test-Path $Addon)) { Write-Host "[spear] addon copy failed"; continue }
    Write-Host "[spear] attempt $try - $Move : char $P1 (P1) vs char $P2 (P2, passive human), Dead Pool ..."

    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "spear_dmgscale_mame.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "spear_dmgscale_mame.err")

    # Past the ROM-warning screen, by PostMessage from its own process - never
    # AppActivate + SendKeys, which lands in whatever MAME window has the focus.
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
        "-NoProfile","-File",$Poker,"-ProcessId",$proc.Id,"-ReadyFile",$Log,"-TimeoutSec",90) | Out-Null

    $proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

    if (Test-Path $Log) { break }
    Write-Host "[spear] the addon never ran (no log) - retrying"
}

Remove-Item $Addon -ErrorAction SilentlyContinue
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL",
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","SPEAR_LOG","SPEAR_SEED","MOVE")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[spear] no log produced" }
