param(
    # A/B the airswing gate end to end: set the switch, rebuild, package, sweep.
    #
    # The thing being measured is a MISS, and a miss is invisible unless the
    # gate can be turned off and the miss put back -- so the honest test is two
    # builds, not one. This does one side of it; run it twice.
    [ValidateSet("0","1")][string]$Airswing = "1",
    [string]$OutDir = "",
    [int[]]$Seed = @(0,1234,4242,7777,31337,90210,5150,424242),
    [string]$Char = "scorpion",
    [int]$Diff = 9
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutDir) { $OutDir = Join-Path $root ("tools\divep_" + $(if ($Airswing -eq "1") { "after" } else { "before" })) }
Set-Location $root

$equ = Join-Path $root "src\MAINEQU.ASM"
$txt = Get-Content $equ -Raw
# SINGLE-quoted replacement, then concatenate the value.  Written as one
# double-quoted string the group references and the parameter fought over the
# $ and the switch was NEVER FLIPPED: both halves of an A/B ran with
# airswing 0 and came out byte-identical, which read like proof that the
# branch under test never fires.  It was proof of nothing.
$rep = 'airswing${1}.set${2}' + $Airswing
$new = [regex]::Replace($txt, "(?m)^airswing(\s+)\.set(\s+)[01]", $rep)
# .NET, not Set-Content: `Set-Content -NoNewline $equ $new` failed outright
# here ("A parameter cannot be found that matches parameter name 'NoNewline'")
# and the file was never written at all, which is the other half of how an
# A/B ran twice on the same build.
[System.IO.File]::WriteAllText($equ, $new)

# ...AND READ IT BACK.  The old version printed the line and trusted the eye.
$line = (Select-String -Path $equ -Pattern "^airswing").Line
Write-Host ("[ab] " + $line)
if ($line -notmatch "^airswing\s+\.set\s+$Airswing(\s|$)") {
    Write-Host "FATAL: MAINEQU.ASM still does not say airswing = $Airswing."
    Write-Host "       Refusing to build - an A/B that did not switch is"
    Write-Host "       worse than no A/B at all."
    exit 1
}

Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($step in @("build.py --asm-only", "makerom.py", "mamerom.py --source-video")) {
    Write-Host "[ab] python $step"
    $args = $step -split " "
    & python @args 2>&1 | Select-Object -Last 4
    if ($LASTEXITCODE -ne 0) { Write-Host "FATAL: $step failed"; exit 1 }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Remove-Item (Join-Path $OutDir "*.log") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root "tools\drone_divepunish_${Char}_d${Diff}*.log") -Force -ErrorAction SilentlyContinue
& (Join-Path $root "tools\run_drone_divepunish_test.ps1") -Char $Char -Diff $Diff -Seed $Seed 2>&1 |
    Select-Object -Last 40
Copy-Item (Join-Path $root "tools\drone_divepunish_${Char}_d${Diff}*.log") $OutDir -Force
Write-Host "[ab] logs -> $OutDir"
& python (Join-Path $root "tools\divep_summary.py") $OutDir
