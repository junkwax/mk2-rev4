# RAIDEN'S ELECTRICITY MATCHES HIS COSTUME, and every electrocution runs the
# four-beat cycle.  Two things to prove, so two modes.
#
#   -Mode costume   per costume lane: he teleports, and the decoy he melts out
#                   of is drawn in the ELEC palette that lane pairs with - and
#                   in neither of the other two.  -Lane all walks the table.
#
#   -Mode cycle     per lane: he zaps the other man, and the man it hits wears
#                   four distinct palettes - two of them the solid white and
#                   black flashes, and BOTH BODY BEATS his own body's copy of
#                   Raiden's colour: the ELEC one and the FREZ one in front of
#                   it.  That is shock_next_beat + shock_elec_tabs +
#                   shock_frez_tabs (MKGUYS.ASM) and nothing else looks like it:
#                   retail's flicker is two states, no flashes, and blue whatever
#                   Raiden is wearing.
#
#                   THE PALETTE COUNT PROVES NOTHING ABOUT THE FREZ BEAT.  Until
#                   2026-09-28 that beat was the cyan frozen set whatever colour
#                   the bolt was - four distinct palettes, both solid flashes, the
#                   right ELEC beat - so it is asserted BY NAME or not at all.
#
#   -Mode crackle   per lane: he stands in his stance, the ambient RN*BOLT flash
#                   fires (every 16-47 ticks), and the object it draws is
#                   retinted with THIS lane's crackle palette - red on Start+HP,
#                   purple on LP/HK/LK - and with no other.  Nothing is pressed:
#                   the flash is gated on him standing.
#
#                   THE BLUE LANES ARE JUDGED TWO WAYS, because their crackle
#                   palette IS his costume palette and his body already wears
#                   it: no RDCRK_* may be allocated, AND the costume palette's
#                   refcount has to rise (the flash object's own getfpal).
#                   Without the second test a lane where nothing ever fired
#                   would pass for free.
#
#   -Mode victory   per lane: he wins the match, and his victory charge-up runs
#                   the same four beats in his own costume's colour - then puts
#                   that costume back.  The last of twelve beats is BLACK, so a
#                   loop that forgets leaves him a solid black silhouette.
#
# The expectation is REGENERATED from data/MK2PALS.IMG and src/MK2.MAP on every
# run into tools/raiden_elec_expect.lua, so the rig cannot pass against an
# address or a pairing somebody typed in and then moved.
#
#   powershell -File tools/run_raiden_elec_test.ps1
#   powershell -File tools/run_raiden_elec_test.ps1 -Mode costume -Lane all
#   powershell -File tools/run_raiden_elec_test.ps1 -Mode cycle
#   powershell -File tools/run_raiden_elec_test.ps1 -Mode cycle -Keep
#   powershell -File tools/run_raiden_elec_test.ps1 -Mode victory -Lane all
#   powershell -File tools/run_raiden_elec_test.ps1 -Mode cycle -Negative
#
param(
    [string]$Rom  = "mk2",
    [ValidateSet("costume", "cycle", "victory", "crackle")] [string]$Mode = "costume",
    # 0 default / 1 Start+HP / 2 Start+LP / 3 Start+HK / 4 Start+LK / 5 Start+BLOCK
    [string]$Lane = "all",
    [switch]$Keep,
    # -Negative asks each lane for ANOTHER lane's electric answer, ROM untouched.
    # Every trial must FAIL; the exit code is inverted so 0 = the control behaved.
    [switch]$Negative
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$mame = "C:\MAME\mame.exe"

# --- the ROM the rig is about to read must be the one this build produced ----
$zip = "C:\MAME\roms\mk2.zip"
$out = Join-Path $root "src\mk2.out"
if (-not (Test-Path $zip)) { throw "no $zip - run: python mamerom.py" }
if ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime) {
    throw "$zip is older than src\mk2.out - the rig would read every symbol at the wrong address. Repackage first."
}

Write-Host "Regenerating tools/raiden_elec_expect.lua from data/MK2PALS.IMG + src/MK2.MAP"
Push-Location $root
try {
    python tools/raiden_elec_expect.py
    if ($LASTEXITCODE -ne 0) { throw "could not build the expectation" }
} finally { Pop-Location }

# Both modes walk the lanes: the costume run proves the LIGHTNING's palette,
# the cycle run proves the FLASH on the man it hits, and each has a different
# answer per lane.
$lanes = if ($Lane -eq "all") { @(0, 1, 2, 3, 4, 5) } else { @([int]$Lane) }

$pass = 0; $fail = 0; $nov = 0
foreach ($l in $lanes) {
    $log = Join-Path $root ("tools\raiden_elec_test_{0}_{1}.log" -f $Mode, $l)
    if (Test-Path $log) { Remove-Item $log }

    $env:MK2_ROOT = $root
    $env:RE_LOG   = $log
    $env:RE_MODE  = $Mode
    $env:RE_LANE  = "$l"
    $env:RE_CROSS = $(if ($Negative) { "1" } else { "0" })

    $args = @($Rom, "-autoboot_script", (Join-Path $root "tools\raiden_elec_test.lua"),
              "-window", "-nomaximize", "-skip_gameinfo", "-nothrottle",
              "-seconds_to_run", $(if ($Mode -eq "victory") { "240" } else { "150" }))
    if (-not $Keep) { $args += "-exit_after_playback" }

    Write-Host ""
    Write-Host ("=== mode={0} lane={1}{2} ===" -f $Mode, $l,
                $(if ($Negative) { " NEGATIVE - must FAIL" } else { "" }))
    Push-Location "C:\MAME"
    try { & $mame @args | Out-Null } finally { Pop-Location }

    if (-not (Test-Path $log)) { Write-Host "NO VERDICT - the rig never wrote a log"; $nov++; continue }
    Get-Content $log
    $v = Select-String -Path $log -Pattern '^\[rd-elec\] (PASS|FAIL|NO VERDICT)' | Select-Object -Last 1
    if (-not $v)                        { $nov++  }
    elseif ($v.Line -match '\] PASS')   { $pass++ }
    elseif ($v.Line -match 'NO VERDICT'){ $nov++  }
    else                                { $fail++ }
}

Write-Host ""
Write-Host ("mode={0}: {1} PASS, {2} FAIL, {3} NO VERDICT (of {4})" -f $Mode, $pass, $fail, $nov, $lanes.Count)
if ($nov -gt 0)  { Write-Host "A NO VERDICT is the RIG, not the ROM - read its reason line."; exit 2 }
if ($Negative) {
    if ($fail -eq $lanes.Count) {
        Write-Host "CONTROL OK - every crossed trial failed, as it must"; exit 0
    }
    Write-Host "CONTROL BROKEN - a crossed trial PASSED, so the rig is not reading the"
    Write-Host "palettes and any green run meant nothing"; exit 1
}
if ($fail -gt 0) { exit 1 }
exit 0
