# run_flybrain_train.ps1 - long fly-brain training that survives crashes.
#
# Runs tools/run_flybrain_play.ps1 headless (no window, below-normal priority) in
# SEGMENTS under one arm directory. A segment ends when its time is up, or early
# when the game or MAME dies (the open Kahn's Arena reset - see memory
# project_kintaro_arena_dma_hang); the next segment restarts from the brain saved
# at the last round end, with the seed advanced so it does not replay the same fight
# into the same crash. flybrain_compare.py stitches <arm>\seg*\rounds.csv together.
#
# Stop it any time by creating <arm>\STOP (checked between segments; the running
# segment finishes its round saves first), or by stopping the MAME process - the
# brain is saved after every round either way.
#
#   .\tools\run_flybrain_train.ps1 -Arm C:\tmp\flybrain\train2\full -Minutes 360
#   .\tools\run_flybrain_train.ps1 -Arm C:\tmp\flybrain\train2\nolearn -Minutes 360 -NoLearn
#   .\tools\run_flybrain_train.ps1 -Arm C:\tmp\flybrain\train2\shuffled -Minutes 360 -Net C:\tmp\flybrain\out\flynet_shuffled.lua
#   .\tools\run_flybrain_train.ps1 -Arm C:\tmp\flybrain\background -Forever -WeightsIn <brain.lua>   # learn indefinitely
param(
    [Parameter(Mandatory = $true)][string]$Arm,
    [int]$Minutes = 360,
    [int]$SegmentMinutes = 360,  # cap per MAME session, so logs stay a manageable size
    [string]$Net = "C:\tmp\flybrain\out\flynet.lua",
    # "" = run_flybrain_play.ps1's own default frozen ROM pair; pass a folder holding a
    # zip+map installed TOGETHER (with PAIR.txt) to train on a newer build
    [string]$RomPath = "",
    [string]$WeightsIn = "",     # start from an existing brain instead of scratch
    [int]$Seed = 12345,
    # who the fly plays in TRAINING segments (run_flybrain_play -Chars); exams keep the play
    # script's own default so their series stays comparable across arms
    [string]$Chars = "cycle",
    [int]$MaxSegments = 30,
    [switch]$Forever,            # ignore -Minutes / -MaxSegments: run until STOP
    [switch]$NoLearn,
    # CURRICULUM: pin the CPU difficulty where the fly wins 30-60% instead of letting
    # continues carry it up to where it only loses. State lives in <arm>\curriculum.txt.
    [switch]$Curriculum,
    # EXAMS: every N segments, freeze a copy of the brain and play it (no learning) at
    # fixed difficulties with a fixed seed, into <arm>\exams.csv. Training win rates mix
    # difficulties and ladder positions and cannot show progress; this can.
    [int]$ExamEvery = 0,
    [string]$ExamDiffs = "0,2,7",     # 7: a CPU that ATTACKS. The escape-reflex fix was worth ~29 points at d7 and invisible at d2 (63.3 vs 64.7), because the d2 CPU barely attacks - so defence only shows up here
    [int]$ExamMinutes = 90,      # no continues, so each game is short: more minutes = more games
    [int]$ExamSeed = 777,
    # How strongly an exam plays its learned favourites (FB_SHARP: pick ~ weight^SHARP). Exams
    # used to run at 1 because they drop FB_CURRICULUM and SHARP defaults to 1 without it - the
    # most exploring pick there is - so they measured a far weaker player than the brain holds:
    # same frozen brain, d7, boss-capped, ~350 rounds each: SHARP 1 27.7%, 2 52.1%, 4 67.0%. At 1
    # the series read as a plateau while the brain improved 52% -> 66% (seg004 vs seg064 at 4).
    [int]$ExamSharp = 4
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force $Arm | Out-Null
$brain = Join-Path $Arm "brain.lua"
$stop = Join-Path $Arm "STOP"
if (Test-Path $stop) { Remove-Item $stop }
if ($WeightsIn -and -not (Test-Path $brain)) { Copy-Item $WeightsIn $brain }
$env:FB_EXIT_ON_CRASH = "1"
$done = 0.0
$stalls = 0
# RESUME after the highest existing segment. Starting at 0 made a relaunch into an
# existing arm overwrite seg001, seg002... - on fly2 that would have destroyed 53
# segments of history, including the ani2_clip latch files other sessions were using.
$seg = 0
Get-ChildItem $Arm -Directory -Filter "seg*" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match '^seg(\d+)$' -and [int]$Matches[1] -gt $seg) { $seg = [int]$Matches[1] }
}
if ($seg -gt 0) { Write-Host "[train] resuming after seg$('{0:D3}' -f $seg)" }
if ($Curriculum) { $env:FB_CURRICULUM = Join-Path $Arm "curriculum.txt" }
else { Remove-Item Env:FB_CURRICULUM -ErrorAction SilentlyContinue }

function Invoke-Exam([int]$segNo) {
    $examDir = Join-Path $Arm "exams"
    New-Item -ItemType Directory -Force $examDir | Out-Null
    $snap = Join-Path $examDir ("brain_seg{0:D3}.lua" -f $segNo)
    Copy-Item $brain $snap -Force
    # the exam must not move the curriculum or learn: it measures, it does not train
    $savedCurr = $env:FB_CURRICULUM
    Remove-Item Env:FB_CURRICULUM -ErrorAction SilentlyContinue
    $savedSharp = $env:FB_SHARP                  # training's own pick rule comes back after
    # and the training arm's opponent mix (hidden CPUs every Nth battle, boss games) stays out of
    # the exam, which climbs the stock tower so every arm's exams.csv reads the same question
    $savedOpp = @{}
    foreach ($k in "FB_SECRET_OPP_EVERY", "FB_SECRET_OPPS", "FB_KAHN_EVERY", "FB_KAHN_RUNG") {
        $savedOpp[$k] = [Environment]::GetEnvironmentVariable($k)
        Remove-Item "Env:$k" -ErrorAction SilentlyContinue
    }
    $env:FB_SHARP = "$ExamSharp"
    try {
        foreach ($d in ($ExamDiffs -split ',')) {
            $eo = Join-Path $examDir ("seg{0:D3}_d{1}" -f $segNo, $d)
            $env:FB_POKE = "diff=$d"
            try {
                # NO CONTINUES. With continues an exam spends its time retrying whichever
                # opponent walls it, so each exam measured a different mix and nothing was
                # comparable. From rung 1 with one credit, "how far up the tower does it get"
                # is the same question every time - and the plainest measure of an opponent.
                $exArgs = @{ Out = $eo; Net = $Net; Seed = $ExamSeed; MaxMinutes = $ExamMinutes;
                             NoLearn = $true; NoContinue = $true; WeightsIn = $snap; Label = "exam" }
                if ($RomPath) { $exArgs.RomPath = $RomPath }
                & (Join-Path $Tools "run_flybrain_play.ps1") @exArgs | Out-Null
            } finally { Remove-Item Env:FB_POKE -ErrorAction SilentlyContinue }
            # REGULARS AND BOSSES SEPARATELY. A blended rate mostly measures how soon the exam
            # reached Kintaro: the fly beats the twelve regulars 82-100% and Kintaro 3-8%, and
            # continues keep it on him, so one number hid both the progress and the wall.
            $all = @(); $reg = @(); $boss = @()
            $ecsv = Join-Path $eo "rounds.csv"
            if (Test-Path $ecsv) {
                $all = @(Import-Csv $ecsv | Where-Object { $_.winner -eq 'FLY' -or $_.winner -eq 'CPU' })
                $boss = @($all | Where-Object { $_.cpu_char -eq 'Kintaro' -or $_.cpu_char -eq 'ShaoKahn' })
                $reg = @($all | Where-Object { $_.cpu_char -ne 'Kintaro' -and $_.cpu_char -ne 'ShaoKahn' })
            }
            function Pct($set) { if ($set.Count) { [math]::Round(100.0 * @($set | Where-Object { $_.winner -eq 'FLY' }).Count / $set.Count, 1) } else { "" } }
            # how far up the tower each credit got: the highest battle reached in each game
            $games = @($all | Group-Object game | ForEach-Object { ($_.Group | ForEach-Object { [int]$_.battle } | Measure-Object -Maximum).Maximum })
            $reach = if ($games.Count) { [math]::Round(($games | Measure-Object -Average).Average, 2) } else { "" }
            $best = if ($games.Count) { ($games | Measure-Object -Maximum).Maximum } else { "" }
            # WHAT THE EXAM ACTUALLY RAN ON. Without these, a trainer relaunched onto another
            # network or build keeps appending to the same series and the change is invisible:
            # fly3_eyes went from rom23 + the 64-cell net to rom35 + the 768-cell net at seg 60,
            # the exam fell ~10 points, and it read for a week as the fly getting worse. The
            # values come from the exam's own play.log, not from our arguments - an empty
            # -RomPath means "the play script's default", which is not written anywhere else.
            $netNodes = ""; $romTable = ""
            $plog = Join-Path $eo "play.log"
            if (Test-Path $plog) {
                $m = Select-String -Path $plog -Pattern 'net (\d+) nodes' | Select-Object -First 1
                if ($m) { $netNodes = $m.Matches[0].Groups[1].Value }
                $m = Select-String -Path $plog -Pattern 'ROM table (\d+)' | Select-Object -First 1
                if ($m) { $romTable = $m.Matches[0].Groups[1].Value }
            }
            $netFile = Split-Path -Leaf $Net
            $ex = Join-Path $Arm "exams.csv"
            $hdr = "time,seg,diff,games,avg_battle_reached,best_battle,rounds,win_pct,reg_rounds,reg_win_pct,boss_rounds,boss_win_pct,net_nodes,net_file,rom_table,sharp"
            if (-not (Test-Path $ex)) { $hdr | Set-Content $ex }
            else {
                # an exams.csv from before these columns: widen its header in place. The old
                # rows simply end early, which Import-Csv reads as empty setup fields.
                $lines = @(Get-Content $ex)
                if ($lines.Count -and $lines[0] -notmatch ',sharp$') { $lines[0] = $hdr; $lines | Set-Content $ex }
            }
            Add-Content $ex ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $segNo, $d,
                $games.Count, $reach, $best, $all.Count, (Pct $all), $reg.Count, (Pct $reg), $boss.Count, (Pct $boss),
                $netNodes, $netFile, $romTable, $ExamSharp)
            Write-Host ("[exam] after seg {0}, difficulty {1}: {2} games, reached battle {3} on average (best {4}); regulars {5}%, bosses {6}%" -f `
                $segNo, $d, $games.Count, $reach, $best, (Pct $reg), (Pct $boss))
        }
    } finally {
        if ($savedCurr) { $env:FB_CURRICULUM = $savedCurr }
        foreach ($k in $savedOpp.Keys) { if ($savedOpp[$k]) { [Environment]::SetEnvironmentVariable($k, $savedOpp[$k]) } }
        if ($savedSharp) { $env:FB_SHARP = $savedSharp } else { Remove-Item Env:FB_SHARP -ErrorAction SilentlyContinue }
    }
}

while ($true) {
    $seg++
    if (-not $Forever -and ($seg -gt $MaxSegments -or $done -ge $Minutes)) { break }
    if (Test-Path $stop) { Write-Host "[train] STOP file found - stopping"; break }
    $out = Join-Path $Arm ("seg{0:D3}" -f $seg)
    $left = if ($Forever) { $SegmentMinutes } else { [int][math]::Min($SegmentMinutes, [math]::Ceiling($Minutes - $done)) }
    $args2 = @{ Out = $out; Net = $Net; Seed = ($Seed + $seg - 1); MaxMinutes = $left; Label = (Split-Path -Leaf $Arm) }
    $args2 = $args2 + @{ Chars = $Chars }
    if ($RomPath) { $args2.RomPath = $RomPath }
    if ($NoLearn) {
        $args2.NoLearn = $true
    } else {
        $args2.WeightsOut = $brain
        if (Test-Path $brain) { $args2.WeightsIn = $brain }
    }
    Write-Host "[train] segment $seg -> $out (up to $left emulated minutes)"
    & (Join-Path $Tools "run_flybrain_play.ps1") @args2 | Out-Null
    $csv = Join-Path $out "rounds.csv"
    $segmin = 0.0
    if (Test-Path $csv) {
        $last = Get-Content $csv | Select-Object -Last 1
        $f = ($last -split ",")[0]
        if ($f -match '^\d+$') { $segmin = [double]$f / 54.7068 / 60 }
    }
    $log = Join-Path $out "play.log"
    $crash = (Test-Path $log) -and (Select-String -Path $log -Pattern "CRASH RECORDER|HANG DETECTOR" -Quiet)
    Write-Host ("[train] segment {0}: {1:N1} emulated minutes{2}" -f $seg, $segmin, $(if ($crash) { " - ended by a crash, restarting from the saved brain" } else { "" }))
    if ($segmin -lt 1) {
        # a segment that makes no progress three times running means something is
        # wrong with the setup, not the game - do not spin forever
        $stalls++
        if ($stalls -ge 3) { Write-Host "[train] three segments in a row made no progress - stopping"; break }
    } else { $stalls = 0 }
    $done += $segmin
    if ($ExamEvery -gt 0 -and -not $NoLearn -and ($seg % $ExamEvery) -eq 0 -and (Test-Path $brain)) { Invoke-Exam $seg }
}
Write-Host ("[train] finished: {0:N0} emulated minutes in {1} segment(s)" -f $done, ($seg - 1))
