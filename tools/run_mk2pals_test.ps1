# Runtime proof that holding START + HIGH PUNCH on the character select screen
# puts retail's MIRROR-MATCH costume on the fighter - the twelve palettes
# tools/make_mk2pals.py lifted out of mk2-readonly into data/MK2PALS.IMG and
# src/MK2PALS.ASM (character_palettes_4, MKGUYS.ASM).
#
# It drives the REAL GESTURE, not the table: 1P Start held with High Punch at
# the select screen, which is what claims the lane in @alt_pal_owner and is
# what a player actually does.  Then it reads the COLOUR RAM the fighter's
# object is pointing at, in the fight, and compares it word for word with the
# IMG.
#
# The expectation is regenerated from data/MK2PALS.IMG on every run into
# tools/mk2pals_expect.lua, so the rig cannot pass against a number somebody
# typed in.  -Negative asks for the palette slot 4 held BEFORE this change
# (TMBLACK_P, LIUALT2_P, ... SUB_P, REP_P, SCORP_P, JAXALT3_P) and must FAIL:
# that is the control that says the rig is reading the screen at all.
#
#   powershell -File tools/run_mk2pals_test.ps1                 # all twelve
#   powershell -File tools/run_mk2pals_test.ps1 -Char kitana
#   powershell -File tools/run_mk2pals_test.ps1 -Char kitana -Negative
#   powershell -File tools/run_mk2pals_test.ps1 -Char kitana -Keep
#
param(
    [string]$Rom    = "mk2",
    [string]$Char   = "all",
    [int]$Settle    = 120,
    [switch]$Keep,
    [switch]$Negative
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$mame = "C:\MAME\mame.exe"

# ochar order, as character_palettes_4 is indexed
$ROSTER = [ordered]@{
    kunglao  = 0;  liukang = 1;  cage    = 2;  baraka   = 3
    kitana   = 4;  mileena = 5;  shang   = 6;  raiden   = 7
    subzero  = 8;  reptile = 9;  scorpion = 10; jax     = 11
}

if ($Char -ne "all" -and -not $ROSTER.Contains($Char)) {
    throw "unknown -Char '$Char'.  One of: all $($ROSTER.Keys -join ' ')"
}

# --- the ROM the rig is about to read must be the one this build produced ----
$zip = "C:\MAME\roms\mk2.zip"
$out = Join-Path $root "src\mk2.out"
if (-not (Test-Path $zip)) { throw "no $zip - run: python mamerom.py --source-video" }
if ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime) {
    throw "$zip is older than src\mk2.out - the rig would read every symbol at the wrong address. Repackage first."
}

# --- regenerate the expectation straight out of the IMG and the ASM ----------
Write-Host "Regenerating tools/mk2pals_expect.lua"
Push-Location $root
try {
    python tools/mk2pals_expect.py
    if ($LASTEXITCODE -ne 0) { throw "could not build the expectation" }
} finally { Pop-Location }

$targets = if ($Char -eq "all") { $ROSTER.Keys } else { @($Char) }
$results = @()

foreach ($name in $targets) {
    $ochar = $ROSTER[$name]
    $log = Join-Path $root "tools\mk2pals_test.log"
    if (Test-Path $log) { Remove-Item $log }

    $env:MK2_ROOT    = $root
    $env:MP_LOG      = $log
    $env:MP_SETTLE   = "$Settle"
    $env:MP_OCHAR    = "$ochar"
    $env:MP_NEGATIVE = $(if ($Negative) { "1" } else { "0" })

    $mameArgs = @($Rom, "-autoboot_script", (Join-Path $root "tools\mk2pals_test.lua"),
                  "-window", "-nomaximize", "-skip_gameinfo", "-nothrottle",
                  "-seconds_to_run", "150")
    if (-not $Keep) { $mameArgs += "-exit_after_playback" }

    Write-Host ""
    Write-Host ("=== {0} (ochar {1}) ===" -f $name, $ochar)
    Push-Location "C:\MAME"
    try { & $mame @mameArgs | Out-Null } finally { Pop-Location }

    if (-not (Test-Path $log)) {
        Write-Host "NO VERDICT - the rig never wrote a log"
        $results += [pscustomobject]@{ Char = $name; Verdict = "NO VERDICT" }
        continue
    }
    Get-Content $log
    Copy-Item $log (Join-Path $root ("tools\mk2pals_test.{0}.log" -f $name)) -Force
    $v = Select-String -Path $log -Pattern '^\[mk2pals\] (PASS|FAIL)' | Select-Object -Last 1
    $results += [pscustomobject]@{
        Char    = $name
        Verdict = $(if (-not $v) { "NO VERDICT" } elseif ($v.Line -match 'PASS') { "PASS" } else { "FAIL" })
    }
}

Write-Host ""
Write-Host "================ SUMMARY ================"
$results | ForEach-Object { Write-Host ("  {0,-9} {1}" -f $_.Char, $_.Verdict) }
$pass = @($results | Where-Object Verdict -eq "PASS").Count
$tot  = $results.Count
Write-Host ("  {0}/{1} PASS" -f $pass, $tot)

if ($Negative) {
    # the control is inverted: every trial must FAIL, and a NO VERDICT is not a
    # failure of the feature, it is the rig not running
    $nv = @($results | Where-Object Verdict -eq "NO VERDICT").Count
    if ($nv -gt 0) { Write-Host "`nCONTROL INCONCLUSIVE - $nv trial(s) never reached a verdict"; exit 2 }
    if ($pass -eq 0) { Write-Host "`nCONTROL OK - every trial failed, as it must"; exit 0 }
    Write-Host "`nCONTROL BROKEN - $pass trial(s) passed against the OLD slot-4 palettes,"
    Write-Host "so the rig is not reading the colour RAM and any green run meant nothing"
    exit 1
}
if ($pass -eq $tot) { exit 0 } else { exit 1 }
