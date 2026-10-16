param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Observe = 500,
    [int]$Backstop = 90,
    [string]$Only = "",     # optional: run only battles whose label matches this substring
    # Run MAME unthrottled.  -seconds_to_run is EMULATED time, so at real speed
    # a 90-second backstop costs 90 seconds of wall clock per battle and the
    # 20-battle sweep takes ~15 minutes for no reason.  Emulation is
    # deterministic either way and the rigs are frame-based, so nothing about
    # the result changes - only how long you wait.  Pass -Throttle to go back
    # to real speed (e.g. if you want to WATCH a battle).
    [switch]$Throttle,
    # Make P2 a second joystick player instead of the AI drone.  Needed by any
    # probe that has to drive the opponent (jumping into a corner, holding
    # block); the flag lives here because MKGUYS.ASM latches p2_state when it
    # creates the fighters, so it must be right before the fight starts.
    [switch]$P2Human,
    # Let P1 actually take damage (the harness normally pins his bar).
    [switch]$NoHpPin
)
$ErrorActionPreference = "Continue"

# STRAY-PROCESS GUARD -- this sweep is the safety gate, so a dirty environment
# here does not just lose a run, it manufactures a fake regression.
#
# Every other run_*.ps1 kills MAME on entry; this one did not, and it also
# never cleaned up the BACKGROUND KEY-POKER JOBS that run_mame_small.ps1 and
# this script both spawn. A poker left over from an earlier harness keeps
# posting OK/space/enter into whatever MAME window appears next, which lands
# stray input in the running game and leaves battles parked before character
# select -- scored NO-VERDICT with an EMPTY anomaly section.
#
# That is indistinguishable from a crash regression by inspection, and it
# cost a full baseline A/B plus a six-step bisect to rule out: baseline read
# 19/19 against 9/19 for a build whose only real difference was that a stray
# job had been alive during its run. See doc/AI_DRONE.md, "the RNG stream
# will lie to you" -- same class of trap, different mechanism.
#
# Cheap, unconditional, and it makes a dirty environment impossible rather
# than merely unlikely.
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "battle_stability_sweep.log"
$SnapDir = Join-Path $ToolsDir "screens\battle_sweep\run_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# ft: 1=Kang 11=Jax 12=Kintaro 13=ShaoKahn 16=Jade
# stage (curback): 0 DeadPool 1 Tomb 2 Wasteland 3 Tower 4 Forest 5 Armory
#   6 Bridge 7 Portal 8 KahnArena 9 MK1Pit 10 PitBottom 13 Mountain/Pit2
#   22 OuterHaven 23 FLAPJACK
$battles = @(
  @{p1=1;p2=11;st=0;  l="kang_jax_deadpool"},
  # Baraka (3) vs Scorpion (10).  Added 2026-08-26 to investigate the blade
  # swipe (Back+HP, do_swipe -> stk_swipe): the blade visibly reaches the
  # opponent's face while the strike box misses entirely.
  @{p1=3;p2=10;st=0;  l="baraka_scorpion_swipe"},
  # MIRROR MATCH. Any measurement that compares the two SIDES has to hold the
  # character constant, or a character difference reads as a side advantage:
  # the first P1-vs-P2 trade test scored 5-0 to P2 with Baraka against
  # Scorpion, whose high kick reaches 100 px against Baraka's 83.
  @{p1=3;p2=3;st=0;   l="mirror_baraka"},
  # Smoke as P2 so his walk speed can be measured BOTH ways: with
  # -P2Human he is a human and should walk like a ninja, without it he is
  # the drone and keeps the boss speed. Secret characters have no select-
  # grid slot, so P2 is the only side they can be forced onto.
  # A secret fighter as the CPU.  The mirror of this - Smoke forced onto
  # P1 - is deliberately NOT here: no secret character can be forced into
  # a fight at all (select forcing and test_mode both fail to start one),
  # so that battle can only ever report NO-VERDICT and would red the gate
  # forever.  Only the select cheat reaches them.
  @{p1=1;p2=14;st=0;  l="smoke_walk"},
  @{p1=1;p2=11;st=1;  l="kang_jax_tomb"},
  @{p1=1;p2=11;st=2;  l="kang_jax_wasteland"},
  @{p1=1;p2=11;st=3;  l="kang_jax_tower"},
  @{p1=1;p2=11;st=4;  l="kang_jax_forest"},
  @{p1=1;p2=11;st=5;  l="kang_jax_armory"},
  @{p1=1;p2=11;st=6;  l="kang_jax_bridge"},
  @{p1=1;p2=11;st=7;  l="kang_jax_portal"},
  @{p1=1;p2=11;st=8;  l="kang_jax_arena"},
  @{p1=1;p2=11;st=9;  l="kang_jax_mk1pit"},
  @{p1=1;p2=11;st=10; l="kang_jax_pitbottom"},
  @{p1=1;p2=11;st=13; l="kang_jax_mountain"},
  @{p1=1;p2=16;st=0;  l="jade_p2_deadpool"},
  # Kitana as P1: her fan throw is F,F + HP AND LP together, which is
  # the two-button input the slack work measures.
  @{p1=4;p2=11;st=0;  l="kitana_p1_deadpool"},
  # Reptile as P1: his spit is F,F+HP on a 24-tick window - one of the
  # tightest double-taps, and a projectile, so it is cleanly detectable.
  @{p1=9;p2=11;st=0;  l="reptile_p1_deadpool"},
  # Raiden was absent from this list entirely, which left his ambient body
  # lightning - a process that spawns and retints an object every 16-47 ticks
  # for the whole round - completely uncovered.
  @{p1=7;p2=11;st=0;  l="raiden_jax_deadpool"},
  @{p1=1;p2=13;st=8;  l="kahnboss_p2_arena"},
  @{p1=1;p2=12;st=8;  l="kintaro_p2_arena"},
  @{p1=1;p2=11;st=22; l="kang_jax_outerhaven"},
  @{p1=1;p2=11;st=23; l="kang_jax_flapjack"},
  # Reported crash from real play: Mileena drone rolls into Kung Lao on Outer
  # Haven. drone_kano funnels through drone_do_a0 and ends in retp, so a
  # dispatch without a pushed return frame jumps into the void. No existing
  # battle used Mileena as the drone, which is why the sweep stayed green.
  @{p1=0;p2=5; st=22; l="lao_mileena_outerhaven"},
  @{p1=0;p2=5; st=0;  l="lao_mileena_deadpool"},
  # Reported crash from real play (2026-09-09): Reptile vs the Noob drone on
  # The Portal, an illegal-opcode lockup in illegal_opcode's jauc $. Noob is
  # a secret fighter, so like Smoke he can only be forced onto P2.
  @{p1=9;p2=15;st=7;  l="reptile_noob_portal"},
  @{p1=9;p2=15;st=0;  l="reptile_noob_deadpool"}
)

if (-not ("SweepWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class SweepWin {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    static void Press(IntPtr h, int vk) {
        PostMessage(h, 0x0100, (IntPtr)vk, IntPtr.Zero); Thread.Sleep(60);
        PostMessage(h, 0x0101, (IntPtr)vk, IntPtr.Zero);
    }
    static void Ch(IntPtr h, char c) { PostMessage(h, 0x0102, (IntPtr)c, IntPtr.Zero); }
    public static void DismissWarning(IntPtr h) {
        Press(h, 0x4F); Ch(h, 'o'); Thread.Sleep(80);
        Press(h, 0x4B); Ch(h, 'k'); Thread.Sleep(80);
        Press(h, 0x20); Thread.Sleep(60);
        Press(h, 0x0D);
    }
}
'@
}

# Read the log even while the lua still holds it open. Get-Content takes an
# exclusive-ish read and returns NOTHING on a locked file, with the error
# swallowed -- so every battle scored NO-VERDICT while the log plainly said
# PASS. A safety gate that cannot read its own results is worse than no gate:
# it reported 19 failures for a build that was fine, twice.
function Read-SweepLog($path) {
  for ($i = 0; $i -lt 12; $i++) {
    try {
      $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
      $sr = New-Object System.IO.StreamReader($fs)
      $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
      if ($t) { return ($t -split "`r?`n") }
    } catch { Start-Sleep -Milliseconds 250 }
  }
  return @()
}

$results = @()
foreach ($b in $battles) {
  if ($Only -and ($b.l -notmatch [regex]::Escape($Only))) { continue }
  Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
  $env:SWEEP_P1 = "$($b.p1)"; $env:SWEEP_P2 = "$($b.p2)"; $env:SWEEP_STAGE = "$($b.st)"
  $env:SWEEP_OBSERVE = "$Observe"; $env:SWEEP_LABEL = $b.l; $env:SWEEP_LOG = $Log
  $env:SWEEP_P2_HUMAN = $(if ($P2Human) { "1" } else { "0" })
  $env:SWEEP_NO_HP_PIN = $(if ($NoHpPin) { "1" } else { "0" })
  $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
    "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
    "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
  if (-not $Throttle) { $mameArgs += "-nothrottle" }
  Write-Host ("[sweep] {0,-22} p1={1} p2={2} stage={3} ..." -f $b.l,$b.p1,$b.p2,$b.st)
  $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
      -ArgumentList $mameArgs -PassThru `
      -RedirectStandardOutput (Join-Path $ToolsDir "battle_sweep_mame.log") `
      -RedirectStandardError  (Join-Path $ToolsDir "battle_sweep_mame.err")
  # Poke past the ROM-warning screen until the battle actually reports in.
  # Without this a battle silently never starts (kang_jax_mk1pit logged its
  # header and nothing else) and scores as a crash it never had.
  #
  # THE ITERATION COUNT IS A CORRECTNESS SETTING, NOT A TIMEOUT. 30 x 700ms
  # gave up after 21s, but a healthy boot only reaches fight_start at frame
  # 1435 -- about 24s -- so the poker could stop one second BEFORE the game
  # it is waiting for ever appears. A run that lost the race scored
  # NO-VERDICT with an empty anomaly section, which is indistinguishable
  # from a real hang and cost a full A/B to rule out. The loop exits the
  # moment fight_start is seen, so a larger bound costs nothing on a healthy
  # run and only ever buys patience on a slow one.
  for ($i = 0; $i -lt 90 -and -not $proc.HasExited; $i++) {
    if ((Read-SweepLog $Log) -match [regex]::Escape("fight_start $($b.l)")) { break }
    Start-Sleep -Milliseconds 700
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [SweepWin]::DismissWarning($proc.MainWindowHandle) }
    $proc.Refresh()
  }
  $proc.WaitForExit()
  $verdict = "NO-VERDICT"
  if (Test-Path $Log) {
    $tail = Read-SweepLog $Log
    $done = $tail | Select-String "battle_done $([regex]::Escape($b.l))" -Quiet
    $pass = $tail | Select-String "PASS $([regex]::Escape($b.l)):" -Quiet
    $fail = $tail | Select-String "FAIL $([regex]::Escape($b.l)):" | Select-Object -Last 1
    if ($pass) { $verdict = "PASS" }
    elseif ($fail) { $verdict = ($fail.Line -replace ".*FAIL $([regex]::Escape($b.l)): ", "FAIL: ") }
    elseif (-not $done) { $verdict = "NO-VERDICT (crash/hang before report?)" }
  }
  $results += [pscustomobject]@{ Battle=$b.l; Verdict=$verdict }
  Write-Host ("           -> {0}" -f $verdict)
}
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL","SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

Write-Host "`n===== BATTLE STABILITY SWEEP SUMMARY ====="
$results | Format-Table -AutoSize
$bad = $results | Where-Object { $_.Verdict -ne "PASS" }
Write-Host ("Battles: {0}  Pass: {1}  Issues: {2}" -f $results.Count, ($results.Count-$bad.Count), $bad.Count)
Write-Host "Full log: $Log"
Write-Host "Snapshots: $SnapDir"
if ($bad) {
  Write-Host "`nAnomaly detail (from log):"
  Read-SweepLog $Log | Select-String "ANOMALY" | ForEach-Object { $_.Line }
}
