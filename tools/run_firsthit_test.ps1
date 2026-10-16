# run_reptile_frozen_spit_test.ps1 - Reptile keeps his face when frozen
# mid-acid-spit.  See tools/sweep_addon_firsthit.lua for what is measured.
#
# Reuses battle_stability_sweep.lua purely as a harness: it already forces the
# matchup (SWEEP_P1/P2/STAGE) and walks the select screen, and it loads
# tools/sweep_addon.lua if that file exists.  The addon is COPIED into place
# for the run and removed afterwards, because any later stability sweep would
# otherwise pick it up and drive the sticks.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 600,
    [switch]$Throttle,
    # Character to measure. 4 = Kitana / 5 = Mileena are the ones whose retract
    # lane is six frames, so they recover 4 ticks slower than everyone else.
    [int]$P1 = 1
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_firsthit.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "firsthit.txt"
$SnapDir = Join-Path $ToolsDir "screens\firsthit"

# Two MAME rigs fight over the same window and kill each other; a leftover
# key-poker job posts into whatever window appears next.  Clear both first.
Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "11"         # Jax
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "7000"  # three phases of 900 frames plus settle
$env:SWEEP_LABEL = "firsthit"
$SweepLog = Join-Path $ToolsDir "firsthit_sweep.log"
Remove-Item $SweepLog -ErrorAction SilentlyContinue   # it is the poker's
$env:SWEEP_LOG = $SweepLog                            #   "we are past the
                                                      #   warning" signal
$env:SWEEP_P2_HUMAN = "1"    # Sub-Zero must be driveable, not a drone
$env:SWEEP_NO_HP_PIN = "1"
$env:FIRSTHIT_LOG = $Log


$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop,
  # Explicit, even though -WorkingDirectory already points MAME at C:\MAME and
  # so at C:\MAME\cfg. If that ever goes, MAME reads the REPO's committed
  # cfg/mk2.cfg, which has the TEST switch on: the game sits in the operator
  # menu and the rig measures nothing, which reads exactly like the feature
  # being broken. Named by the hudcmb rig, which hit it the hard way.
  "-cfg_directory","C:\MAME\cfg")
if (-not $Throttle) { $mameArgs += "-nothrottle" }

Write-Host "[firsthit] Reptile (P1) vs Sub-Zero (P2, human), Dead Pool ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "firsthit_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "firsthit_mame.err")

# Poke past the ROM-warning screen; without this the battle silently never
# starts and scores as a failure it never had.
#
# This has to be a SEPARATE process, not a SendKeys loop in here: this shell
# started MAME with redirected stdout/stderr, so it never owns the foreground
# and Windows refuses its SetForegroundWindow - the keys go nowhere and MAME
# sits on the warning screen until the backstop kills it. That looks exactly
# like a rig that measured nothing. See the header of mame_dismiss_warning.ps1.
$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $poker,
    "-ProcessId", $proc.Id, "-TimeoutSec", 25) | Out-Null
#
# A fixed 25s of poking and NO ReadyFile, which is what the SendKeys loop this
# replaced did. Both other choices are wrong here:
#
#  - this rig's own log never appears (the addon's io.open goes nowhere under
#    MAME's Lua; everything it logs comes back on stdout), so a poker waiting
#    on that one never stops - it keeps injecting keys and stealing focus for
#    the whole fight, which cuts the run off mid-way with no verdict.
#  - the SWEEP's log appears the moment the warning clears, which is too
#    early: this runner wipes nvram, so there is a second screen behind it,
#    and stopping there gives "never_reached_fight".

$proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

Remove-Item $Addon -ErrorAction SilentlyContinue
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL",
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","FIRSTHIT_LOG")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[firsthit] no log produced" }
Write-Host "[firsthit] snapshots: $SnapDir"
