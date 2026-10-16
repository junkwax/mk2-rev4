<#
.SYNOPSIS
  Runs Shao Kahn (AI) against every playable character (AI) at max difficulty
  and reports, per opponent, whether he took BOTH rounds.

.DESCRIPTION
  One MAME session per opponent so a hang or a crash in one match cannot take
  the rest of the sweep with it.  Deliberately sequential: every harness in
  this tree opens by killing stray mame.exe processes, and two of them running
  at once produce NO-VERDICT rows that look exactly like a real regression.

  PASS means Kahn won 2-0.  A 2-1 is reported as FAIL_DROPPED_ROUND, because
  the bar asked for was both rounds.

.EXAMPLE
  .\tools\run_kahn_ladder_test.ps1
  .\tools\run_kahn_ladder_test.ps1 -Only raiden,jax
  .\tools\run_kahn_ladder_test.ps1 -Seed 31337     # re-roll the RNG stream
#>
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Diff = 9,
    [int]$Backstop = 400,          # emulated seconds per match before giving up
    [string[]]$Only = @(),
    [int]$Seed = 0,
    [int]$Attempts = 4,            # retries per opponent when the ENGINE faults
    [int]$FixedSeeds = 0,          # >0: run exactly this many seeds, score them all
    [int]$SeedShift = 0,           # rotate the seed ladder: an independent re-run
    [switch]$Window                # show the MAME window (default is headless)
)

# NOTE: a plain re-run of this script reproduces its own output exactly - MAME
# is deterministic and round_init reseeds @rand from battle_num/wiar/constants,
# so the same seed ladder replays the same twelve matches move for move. To
# actually re-test rather than re-print, rotate the streams with -SeedShift.

# -FixedSeeds exists because the retry rule below is BIASED and saying so
# matters.  Retrying until a match completes throws away exactly the matches
# that ran long - and a match runs long when Kahn is struggling - so
# "12/12 with retries" answers "can he win 2-0 on some seed", not "does he
# win 2-0 reliably".  In fixed mode every seed is run and scored, engine
# faults are reported as no-data rather than re-rolled, and the number quoted
# is 2-0 wins over DECISIVE matches.  Use fixed mode for any before/after
# comparison; use the retry mode for the acceptance run.

# Seeds retried when a match ends in a hang/reset rather than a result.
#
# A drone-vs-drone fight is a configuration the shipped game never runs, and it
# can wedge the board part way through - this reproduces on an UNMODIFIED
# baseline build too, so it is not a property of the AI under test.  Rerolling
# @rand changes which moves both sides throw and usually walks around it.  A
# fault is never scored: it is retried, and only a real 2-0 / 2-1 / 1-2 counts.
$seedLadder = @(0, 31337, 4242, 7777, 1234, 90210,
                0x5A17BEEF, 0x0BADF00D, 0x13579BDF, 0x2468ACE0,
                0x77E1D0A3, 0x0C0FFEE1)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $ToolsDir
$Lua      = Join-Path $ToolsDir "kahn_ladder_test.lua"
$LogDir   = Join-Path $ToolsDir "kahn_ladder_logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# The 12 playable characters.  ft_* indices from MAINEQU.ASM; ft_goro (12) and
# ft_final_boss (13) are bosses and the three secret fighters (14-16) are not
# part of "every opponent" here.
$roster = @(
    @{ Char =  0; Name = "kunglao"  },
    @{ Char =  1; Name = "liukang"  },
    @{ Char =  2; Name = "cage"     },
    @{ Char =  3; Name = "baraka"   },
    @{ Char =  4; Name = "kitana"   },
    @{ Char =  5; Name = "mileena"  },
    @{ Char =  6; Name = "shang"    },
    @{ Char =  7; Name = "raiden"   },
    @{ Char =  8; Name = "subzero"  },
    @{ Char =  9; Name = "reptile"  },
    @{ Char = 10; Name = "scorpion" },
    @{ Char = 11; Name = "jax"      }
)

if ($Only.Count -gt 0) {
    $wanted = $Only | ForEach-Object { $_.ToLowerInvariant() }
    $roster = @($roster | Where-Object { $wanted -contains $_.Name })
    if ($roster.Count -eq 0) { throw "[ladder] no roster entry matched -Only $($Only -join ',')" }
}

# REFUSE to run while a human spar session holds the MAME lock.  Every loop
# below opens with Get-Process mame | Stop-Process -Force, so starting this
# during a live session kills the player's fight mid-round.  That happened.
$LockFile = Join-Path $ToolsDir ".mame-in-use.lock"
if (Test-Path -LiteralPath $LockFile) {
    Write-Host ""
    Write-Host "[ladder] REFUSING TO START - a spar session holds the MAME lock:" -ForegroundColor Yellow
    Write-Host "         $(Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue)"
    Write-Host "         This harness force-kills every mame.exe, which would end that session."
    Write-Host "         Close the spar session first, or delete $LockFile if it is stale."
    Write-Host ""
    exit 2
}

$env:KAHN_LADDER_ROOT = $Root
$env:KAHN_LADDER_DIFF = "$Diff"

$engineFaults = @("CRASH", "HANG", "NO_VERDICT")

$results = @()
$runId = Get-Date -Format "yyyyMMdd_HHmmss"

$fixedMode = ($FixedSeeds -gt 0)
$tryCount  = if ($fixedMode) { $FixedSeeds } else { $Attempts }

foreach ($entry in $roster) {
    $name = $entry.Name
    $verdict = "NO_VERDICT"; $detail = ""; $rounds = ""; $faults = 0
    $log = ""
    $twoNil = 0; $decisive = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()

    for ($try = 0; $try -lt $tryCount; $try++) {
        $thisSeed = if ($Seed -ne 0) { $Seed } else { $seedLadder[($try + $SeedShift) % $seedLadder.Count] }
        if ($thisSeed -ne 0) { $env:KAHN_LADDER_SEED = "$thisSeed" }
        else { Remove-Item Env:\KAHN_LADDER_SEED -ErrorAction SilentlyContinue }

        $log = Join-Path $LogDir "$runId`_$name`_try$try.log"

        Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        # Banked credits desync the scripted boot; start every match from cold CMOS.
        Remove-Item "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

        $env:KAHN_LADDER_CHAR = "$($entry.Char)"
        $env:KAHN_LADDER_NAME = $name
        $env:KAHN_LADDER_LOG  = $log

        $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
            "-sound","none","-keyboardprovider","win32","-skip_gameinfo","-nothrottle",
            "-autoboot_script",$Lua,"-seconds_to_run","$Backstop")
        if (-not $Window) { $mameArgs += @("-video","none") } else { $mameArgs += @("-video","gdi") }

        $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
            -ArgumentList $mameArgs -PassThru -WindowStyle Minimized
        $proc | Wait-Process -Timeout ($Backstop + 180) -ErrorAction SilentlyContinue
        if (-not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }

        $verdict = "NO_VERDICT"; $detail = ""; $rounds = ""
        if (Test-Path -LiteralPath $log) {
            $line = Select-String -Path $log -Pattern "\[ladder\] RESULT " | Select-Object -Last 1
            if ($line) {
                if ($line.Line -match "verdict=(\S+)") { $verdict = $Matches[1] }
                $detail = ($line.Line -replace ".*verdict=\S+\s*", "")
            }
            $rl = Select-String -Path $log -Pattern "\[ladder\] ROUNDS " | Select-Object -Last 1
            if ($rl) { $rounds = ($rl.Line -replace ".*ROUNDS\s*", "") }
        }

        if ($engineFaults -contains $verdict) {
            $faults++
        } else {
            $decisive++
            if ($verdict -eq "PASS") { $twoNil++ }
        }
        if (-not $fixedMode -and ($engineFaults -notcontains $verdict)) { break }
    }
    $sw.Stop()

    if ($fixedMode) {
        $verdict = if ($decisive -eq 0) { "NO_DATA" } elseif ($twoNil -eq $decisive) { "PASS" } else { "MIXED" }
        $rounds  = "$twoNil/$decisive"
    }

    $results += [pscustomobject]@{
        Opponent = $name
        Verdict  = $verdict
        Rounds   = $rounds
        TwoNil   = $twoNil
        Decisive = $decisive
        Faults   = $faults
        Detail   = $detail
        Seconds  = [int]$sw.Elapsed.TotalSeconds
        Log      = $log
    }
    Write-Host "[ladder] $name (char $($entry.Char)) ... $verdict  ($rounds)  faults=$faults  [$([int]$sw.Elapsed.TotalSeconds)s]"
}

Write-Host ""
Write-Host "==================== KAHN LADDER (diff $Diff) ===================="
$results | Format-Table Opponent,Verdict,Rounds,Faults,Seconds -AutoSize | Out-String | Write-Host

$pass = @($results | Where-Object { $_.Verdict -eq "PASS" }).Count
$total = $results.Count
if ($fixedMode) {
    $tn = ($results | Measure-Object TwoNil -Sum).Sum
    $dc = ($results | Measure-Object Decisive -Sum).Sum
    $ft = ($results | Measure-Object Faults -Sum).Sum
    $rate = if ($dc -gt 0) { [math]::Round(100.0 * $tn / $dc, 1) } else { 0 }
    Write-Host "2-0 RATE $tn / $dc decisive matches ($rate%)   engine faults (no data): $ft"
    Write-Host "clean sweeps: $pass / $total opponents took every decisive match 2-0"
} else {
    Write-Host "PASS $pass / $total  (pass = Kahn took both rounds)"
}

$summary = Join-Path $LogDir "$runId`_summary.csv"
$results | Export-Csv -NoTypeInformation -Path $summary
Write-Host "summary: $summary"

if ($pass -ne $total) { exit 1 }
exit 0
