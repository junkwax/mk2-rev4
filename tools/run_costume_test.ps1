# Runtime proof for the two costume rules (doc/COSTUME_PALETTES.md).
#
#   -Mode nodup   TWO PLAYERS NEVER WEAR THE SAME COSTUME (costnodup).  A 2P
#                 MIRROR match where player 1 claims START+LP with the real
#                 gesture - the very lane the mirror rule hands player 2 - so
#                 player 2 confirms plain and must land on his DEFAULT (lane 0).
#                 Then both plain (P2 -> the default alt, Start+HP, lane 1), then both
#                 START+LP (taken -> P2's default, lane 0), then P2 confirms
#                 FIRST and P1 takes START+HP: P2's select-screen preview must
#                 go ALT1 -> default while P1 holds it.  Each asserts the
#                 SPECIFIC lane, not merely that the two differ.
#
#   -Mode drone   THE CPU WEARS A RANDOM COSTUME IN 1P (dronecos).  Each run
#                 is ONE SAMPLE: it asserts the CPU's palette is one of his own
#                 lanes, is not player 1's, and is unchanged in round 2 (the
#                 pick is per OPPONENT while setup_players runs per ROUND).
#                 VARIETY is this wrapper's job - -Rolls runs it N times and
#                 requires at least two different lanes across them, which is
#                 the only way to tell a random pick from a fixed one.
#
#   -Mode both    nodup, then drone.
#
# The expectation is regenerated from the LINKED SOURCE every run
# (tools/costume_expect.py), so a pass means "the screen matches what is
# linked", never "the screen matches a number in a rig".
#
#   powershell -File tools/run_costume_test.ps1 -Mode nodup
#   powershell -File tools/run_costume_test.ps1 -Mode drone -Char noob -Rolls 6
#   powershell -File tools/run_costume_test.ps1 -Mode drone -Char smoke
#   powershell -File tools/run_costume_test.ps1 -Mode both
#
param(
    [string]$Rom  = "mk2",
    [ValidateSet("nodup", "drone", "both")] [string]$Mode = "both",
    [string]$Char = "liukang",
    [int]$Rolls   = 6,
    [int]$Settle  = 120,
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$mame = "C:\MAME\mame.exe"

$ROSTER = [ordered]@{
    kunglao = 0;  liukang = 1;  cage    = 2;  baraka  = 3
    kitana  = 4;  mileena = 5;  shang   = 6;  raiden  = 7
    subzero = 8;  reptile = 9;  scorpion = 10; jax    = 11
    kintaro = 12; kahn    = 13; smoke   = 14; noob    = 15
    jade    = 16; ermac   = 17; khameleon = 18; rain  = 19
}
if (-not $ROSTER.Contains($Char)) {
    throw "unknown -Char '$Char'.  One of: $($ROSTER.Keys -join ' ')"
}
$ochar = $ROSTER[$Char]

# --- the ROM the rig reads must be the one this build produced ---------------
$zip = "C:\MAME\roms\mk2.zip"
$out = Join-Path $root "src\mk2.out"
if (-not (Test-Path $out)) { throw "no src\mk2.out - build first" }
if (-not (Test-Path $zip)) { throw "no $zip - run: python mamerom.py --source-video" }
if ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime) {
    throw "$zip is older than src\mk2.out - the rig would read every symbol at the wrong address. Repackage first."
}

Write-Host "Regenerating tools/costume_expect.lua"
Push-Location $root
try {
    # capture, don't pipe: `Select-Object -First` closes the pipeline early and
    # python then exits non-zero on the broken pipe, which reads as a failure
    $gen = & python tools/costume_expect.py 2>&1
    if ($LASTEXITCODE -ne 0) { $gen | Write-Host; throw "could not build the expectation" }
    $gen | Select-Object -First 1 | Write-Host
} finally { Pop-Location }

function Invoke-Trial([string]$mode, [int]$och, [string]$tag, [int]$jitter = 0) {
    $log = Join-Path $root "tools\costume_test.log"
    if (Test-Path $log) { Remove-Item $log }

    $env:MK2_ROOT  = $root
    $env:CT_LOG    = $log
    $env:CT_MODE   = $mode
    $env:CT_OCHAR  = "$och"
    $env:CT_SETTLE = "$Settle"
    # a deterministic boot gives a deterministic @rand, so the drone's seed - and
    # its pick - would be identical on every run.  Shifting the input schedule a
    # few frames per trial is what makes the sample a sample.
    $env:CT_JITTER = "$jitter"
    # in drone mode player 1 must be somebody else, or a mirror muddies it
    $env:CT_P1CHAR = $(if ($och -eq 11) { "1" } else { "11" })

    $mameArgs = @($Rom, "-autoboot_script", (Join-Path $root "tools\costume_test.lua"),
                  "-window", "-nomaximize", "-skip_gameinfo", "-nothrottle",
                  "-seconds_to_run", "240")
    if (-not $Keep) { $mameArgs += "-exit_after_playback" }

    Write-Host ""
    Write-Host ("=== {0} ===" -f $tag)
    Push-Location "C:\MAME"
    try { & $mame @mameArgs | Out-Null } finally { Pop-Location }

    if (-not (Test-Path $log)) {
        Write-Host "NO VERDICT - the rig never wrote a log"
        return [pscustomobject]@{ Tag = $tag; Verdict = "NO VERDICT"; Lane = $null }
    }
    Get-Content $log | Write-Host
    Copy-Item $log (Join-Path $root ("tools\costume_test.{0}.log" -f $tag)) -Force
    $v = Select-String -Path $log -Pattern '^\[costume\] (PASS|FAIL)' | Select-Object -Last 1
    $l = Select-String -Path $log -Pattern 'CHOSE lane=(\d+)' | Select-Object -Last 1
    [pscustomobject]@{
        Tag     = $tag
        Verdict = $(if (-not $v) { "NO VERDICT" } elseif ($v.Line -match 'PASS') { "PASS" } else { "FAIL" })
        Lane    = $(if ($l) { [int]$l.Matches[0].Groups[1].Value } else { $null })
    }
}

$results = @()
if ($Mode -eq "nodup" -or $Mode -eq "both") {
    foreach ($g in @(@("1","0","manual-plain","LP","0"), @("0","0","plain-plain","LP","0"),
                     @("1","1","taken","LP","0"), @("1","0","alt1-after","HP","1"))) {
        $env:CT_P1GEST = $g[0]; $env:CT_P2GEST = $g[1]; $env:CT_P1BTN = $g[3]; $env:CT_P2FIRST = $g[4]
        # the select-preview trial must be REPTILE - P2's cursor starts on him
        $och = $(if ($g[4] -eq "1") { 9 } else { $ochar })
        $nm  = $(if ($g[4] -eq "1") { "reptile" } else { $Char })
        $results += Invoke-Trial "nodup" $och ("nodup-{0}-{1}" -f $nm, $g[2])
    }
    $env:CT_P1GEST = $null; $env:CT_P2GEST = $null; $env:CT_P1BTN = $null; $env:CT_P2FIRST = $null
}
$droneRuns = @()
if ($Mode -eq "drone" -or $Mode -eq "both") {
    for ($i = 1; $i -le $Rolls; $i++) {
        $r = Invoke-Trial "drone" $ochar ("drone-{0}-{1}" -f $Char, $i) (($i - 1) * 11)
        $droneRuns += $r
        $results += $r
    }
}

Write-Host ""
Write-Host "================ SUMMARY ================"
$results | ForEach-Object {
    Write-Host ("  {0,-18} {1}{2}" -f $_.Tag, $_.Verdict,
                $(if ($null -ne $_.Lane) { "  lane $($_.Lane)" } else { "" }))
}
$pass = @($results | Where-Object Verdict -eq "PASS").Count
Write-Host ("  {0}/{1} PASS" -f $pass, $results.Count)

$exit = $(if ($pass -eq $results.Count) { 0 } else { 1 })

# --- variety: the assertion that separates a random pick from a fixed one ----
if ($droneRuns.Count -gt 1) {
    $lanes = @($droneRuns | Where-Object { $null -ne $_.Lane } | ForEach-Object { $_.Lane })
    $distinctLanes = @($lanes | Sort-Object -Unique)
    # how many costumes he actually HAS - a one-costume fighter cannot vary
    $expect = Join-Path $root "tools\costume_expect.lua"
    $have = 1
    $m = Select-String -Path $expect -Pattern ("^\s*\[{0}\] = .*distinct = (\d+)" -f $ochar)
    if ($m) { $have = [int]$m.Matches[0].Groups[1].Value }

    Write-Host ""
    Write-Host ("VARIETY: {0} roll(s) landed on lane(s) {1}; {2} has {3} distinct costume(s)" -f
                $lanes.Count, ($distinctLanes -join ","), $Char, $have)
    if ($lanes.Count -lt 2) {
        Write-Host "  NO VERDICT - fewer than two rolls reported a lane"
        if ($exit -eq 0) { $exit = 2 }
    } elseif ($have -eq 1) {
        Write-Host "  OK - one costume, so one lane is the only possible answer and the roll is inert"
    } elseif ($distinctLanes.Count -lt 2) {
        Write-Host ("  FAIL - every roll chose lane {0} out of {1} costumes. That is not random;" -f
                    $distinctLanes[0], $have)
        Write-Host "         suspect the seed (dcos_rand off @rand) is identical on every boot."
        $exit = 1
    } else {
        Write-Host ("  OK - {0} different lanes across {1} rolls" -f $distinctLanes.Count, $lanes.Count)
    }
}

exit $exit
