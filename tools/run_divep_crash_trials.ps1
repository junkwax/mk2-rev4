param(
    # Repeat one divepunish seed N times against ONE build and tally how each run
    # ended: CRASH (the CPU was in illegal_opcode..errort, TRAP 30) or WEDGE (the
    # game was still running and the rig stalled) or no stall at all.
    #
    # WHY REPEATS OF THE SAME SEED: the crash this was written for is NOT
    # deterministic.  Seed 31337 on one airswing 1 build crashed twice and then
    # ran clean on the third try, so a single run - pass or fail - attributes
    # nothing.  Compare tallies across builds, never single runs.
    #
    #   .\tools\run_divep_crash_trials.ps1 -Airswing 0 -Airsweep 0 -Trials 4
    #
    # With -Airswing/-Airsweep given, sets the equates, reads them BACK (an A/B
    # that never switched is worse than none), rebuilds and packages first.
    # Without them, runs against whatever build is installed.
    [ValidateSet("","0","1")][string]$Airswing = "",
    [ValidateSet("","0","1")][string]$Airsweep = "",
    [int]$Trials = 4,
    [int]$Seed = 31337,
    [string]$Char = "scorpion",
    [int]$Diff = 9,
    [string]$OutDir = ""
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$equ = Join-Path $root "src\MAINEQU.ASM"

if ($Airswing -ne "" -or $Airsweep -ne "") {
    $t = [System.IO.File]::ReadAllText($equ)
    if ($Airswing -ne "") { $t = [regex]::Replace($t, '(?m)^(airswing\s+\.set\s+)[01]', '${1}' + $Airswing) }
    if ($Airsweep -ne "") { $t = [regex]::Replace($t, '(?m)^(airsweep\s+\.set\s+)[01]', '${1}' + $Airsweep) }
    [System.IO.File]::WriteAllText($equ, $t)
    $a = (Select-String -Path $equ -Pattern '^airswing\s').Line
    $b = (Select-String -Path $equ -Pattern '^airsweep\s').Line
    Write-Host "[trials] $a"; Write-Host "[trials] $b"
    if ($Airswing -ne "" -and $a -notmatch "^airswing\s+\.set\s+$Airswing(\s|$)") { Write-Host "FATAL: airswing did not switch"; exit 1 }
    if ($Airsweep -ne "" -and $b -notmatch "^airsweep\s+\.set\s+$Airsweep(\s|$)") { Write-Host "FATAL: airsweep did not switch"; exit 1 }
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($step in @("build.py --asm-only", "makerom.py", "mamerom.py --source-video")) {
        Write-Host "[trials] python $step"
        & python @($step -split " ") 2>&1 | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { Write-Host "FATAL: $step failed"; exit 1 }
    }
}

$sw = (Select-String -Path $equ -Pattern '^airswing\s').Line -replace '\s+;.*$',''
$ss = (Select-String -Path $equ -Pattern '^airsweep\s').Line -replace '\s+;.*$',''
if (-not $OutDir) {
    $tag = (($sw -replace '\s+', '') + "_" + ($ss -replace '\s+', '')) -replace '\.set', ''
    $OutDir = Join-Path $root "tools\divep_trials_$tag"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$log = Join-Path $root ("tools\drone_divepunish_{0}_d{1}_s{2}.log" -f $Char, $Diff, $Seed)

$crash = 0; $wedge = 0; $clean = 0; $nolog = 0
for ($i = 1; $i -le $Trials; $i++) {
    # A NO-LOG trial is MAME parked on its warning screen (stderr ends "the
    # machine might not run correctly", ~0% CPU) - it says nothing about the
    # ROM.  Retry it rather than let it shrink the tally; only count it as
    # no-log if it keeps happening.
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "[trials] $sw / $ss  trial $i of $Trials (attempt $attempt)"
        & (Join-Path $root "tools\run_drone_divepunish_test.ps1") -Char $Char -Diff $Diff -Seed $Seed 2>&1 | Select-Object -Last 1
        if (Test-Path $log) { break }
        Write-Host "  attempt $attempt produced no log - retrying"
    }
    if (-not (Test-Path $log)) {
        $nolog++
        Write-Host "  trial ${i}: NO LOG"
        Select-String -Path (Join-Path $root "tools\drone_divepunish_mame.err") -Pattern 'Fatal error|syntax error' |
            ForEach-Object { Write-Host ("  MAME: " + $_.Line) }
        continue
    }
    $dst = Join-Path $OutDir "trial$i.log"
    Copy-Item $log $dst -Force
    $v = Select-String -Path $dst -Pattern 'STALL-VERDICT (CRASH|WEDGE)' | Select-Object -First 1
    if ($v) {
        if ($v.Matches[0].Groups[1].Value -eq "CRASH") { $crash++ } else { $wedge++ }
        Write-Host ("  trial ${i}: " + $v.Matches[0].Value)
    } else {
        $clean++
        Write-Host "  trial ${i}: no stall"
    }
}
Write-Host ""
Write-Host ("TRIALS {0} / {1}  seed {2}:  CRASH={3}  WEDGE={4}  no-stall={5}  no-log={6}" -f $sw, $ss, $Seed, $crash, $wedge, $clean, $nolog)
Write-Host "logs -> $OutDir"
