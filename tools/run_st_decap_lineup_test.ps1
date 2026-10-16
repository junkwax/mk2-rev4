# run_st_decap_lineup_test.ps1
#
# LINE-UP harness for Shang Tsung's Old-Shang blade decapitation: is every
# victim stood his body's own distance from Shang, and is the blade in his neck?
#
#   .\tools\run_st_decap_lineup_test.ps1 -Package              # all 12 bodies, Shang on the left
#   .\tools\run_st_decap_lineup_test.ps1 -Victim jax -Side both
#   .\tools\run_st_decap_lineup_test.ps1 -Victim jax -Wall     # his spot is past the wall
#   .\tools\run_st_decap_lineup_test.ps1 -Victim kang -Negative   # crossed expectation: must FAIL
#
# The numbers come from tools/st_decap_lineup.py (measured off the art) and are
# asserted off the live objects by tools/st_decap_lineup_test.lua.  A trial that
# never reaches the fatality is NO VERDICT, never a pass.
#
# -Package builds a PRIVATE zip from the current link (mamerom.py --output,
# never installs) with src\mk2.map beside it.  Private nvram / cfg; kills only
# the MAME it started.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$Victim = "all",
    [ValidateSet("left", "right", "both")][string]$Side = "left",
    [int]$Dist = 72,
    [switch]$Wall,
    [switch]$Negative,
    [switch]$Package,
    [string]$RomDir = "",
    [int]$TimeoutSeconds = 150
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Work = Join-Path $Root "tmp\st_decap_lineup"
if (-not $RomDir) { $RomDir = Join-Path $Work "rom" }
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$names = [ordered]@{ kunglao = 0; kang = 1; cage = 2; baraka = 3; kitana = 4; mileena = 5; shang = 6
                     raiden = 7; subzero = 8; reptile = 9; scorpion = 10; jax = 11 }

Push-Location $Root
try {
    & python (Join-Path $ToolsDir "st_decap_lineup.py") --check
    if ($LASTEXITCODE -ne 0) { throw "st_decap_lineup.py --check failed: the table or the expectation is stale against the art" }
    & python (Join-Path $ToolsDir "st_decap_lineup.py") --png $Work | Out-Host

    if ($Package) {
        $outBefore = (Get-Item (Join-Path $Root "src\mk2.out")).LastWriteTimeUtc
        New-Item -ItemType Directory -Force -Path $RomDir | Out-Null
        & python makerom.py | Select-Object -Last 2 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "makerom.py failed" }
        & python mamerom.py --source-video --no-install --output (Join-Path $RomDir "mk2.zip") | Select-Object -Last 3 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "mamerom.py failed" }
        Copy-Item (Join-Path $Root "src\mk2.map") (Join-Path $RomDir "mk2.map") -Force
        if ((Get-Item (Join-Path $Root "src\mk2.out")).LastWriteTimeUtc -ne $outBefore) {
            throw "src\mk2.out changed while packaging - another build is running; the zip and the map may not match"
        }
    }
}
finally { Pop-Location }

$zip = Join-Path $RomDir "mk2.zip"
$map = Join-Path $RomDir "mk2.map"
if (-not (Test-Path $zip) -or -not (Test-Path $map)) { throw "no $zip + mk2.map - run with -Package" }

if ($Victim -eq "all") { $victims = @($names.Keys) }
elseif ($names.Contains($Victim.ToLower())) { $victims = @($Victim.ToLower()) }
elseif ($Victim -match '^\d+$') { $victims = @($Victim) }
else { throw "unknown victim '$Victim' (one of: $($names.Keys -join ', '), an ochar, or all)" }
$sides = if ($Side -eq "both") { @("left", "right") } else { @($Side) }
if ($Wall) { $sides = @("right"); $Dist = 40 }   # victim on the left wall, Shang too close on his right

$results = @()
foreach ($v in $victims) {
    $ochar = if ($v -match '^\d+$') { [int]$v } else { $names[$v] }
    foreach ($s in $sides) {
        $tag = "{0}_{1}{2}{3}" -f $v, $s, $(if ($Wall) { "_wall" } else { "" }), $(if ($Negative) { "_neg" } else { "" })
        $dir = Join-Path $Work $tag
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $log = Join-Path $dir "lineup.log"

        $env:MK2_ROOT = $Root; $env:STL_LOG = $log; $env:STL_MAP = $map
        $env:STL_VICTIM = "$ochar"; $env:STL_SIDE = $s; $env:STL_DIST = "$Dist"
        $env:STL_WALL = $(if ($Wall) { "1" } else { "0" }); $env:STL_NEG = $(if ($Negative) { "1" } else { "0" })

        $mameArgs = @("-rompath", $RomDir, "mk2", "-window", "-nomaximize", "-resolution", "640x480",
            "-keyboardprovider", "win32", "-video", "gdi", "-skip_gameinfo", "-sound", "none", "-nothrottle",
            "-nvram_directory", (Join-Path $dir "nvram"), "-cfg_directory", (Join-Path $dir "cfg"),
            "-snapshot_directory", $dir, "-autoboot_script", (Join-Path $ToolsDir "st_decap_lineup_test.lua"))
        $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $mameArgs -PassThru `
            -RedirectStandardOutput (Join-Path $dir "mame_stdout.log") -RedirectStandardError (Join-Path $dir "mame_stderr.log")
        Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @("-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $ToolsDir "mame_dismiss_warning.ps1"), "-ProcessId", $proc.Id, "-TimeoutSec", 90) | Out-Null

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $started = Get-Date
        while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            # no lua log after a minute = parked on the ROM warning, not a slow boot
            if (-not (Test-Path $log) -and ((Get-Date) - $started).TotalSeconds -gt 63) { break }
        }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

        $line = if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '\] (PASS|FAIL|NO VERDICT) ' } | Select-Object -Last 1 } else { $null }
        $verdict = if (-not $line) { "NO VERDICT" } elseif ($line -match '\] PASS ') { "PASS" } elseif ($line -match '\] FAIL ') { "FAIL" } else { "NO VERDICT" }
        if (-not $line) { $line = "(no verdict line - see $log)" }
        if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match 'fatality_started|lined up|CUT |BLADE ' } | ForEach-Object { Write-Host "    $_" } }
        Write-Host ("{0,-22} {1}" -f $tag, $line)
        $results += [pscustomobject]@{ Tag = $tag; Verdict = $verdict }
    }
}

$pass = @($results | Where-Object Verdict -eq "PASS").Count
$fail = @($results | Where-Object Verdict -eq "FAIL").Count
$nov  = @($results | Where-Object Verdict -eq "NO VERDICT").Count
Write-Host ""
Write-Host "st_decap_lineup: $pass PASS, $fail FAIL, $nov NO VERDICT of $($results.Count)   (snapshots + logs: $Work)"
if ($Negative) {
    # the crossed expectation must FAIL every trial; anything else means the rig cannot tell
    if ($fail -eq $results.Count) { Write-Host "NEGATIVE CONTROL OK: every crossed trial failed"; exit 0 }
    Write-Host "NEGATIVE CONTROL BROKEN: a crossed trial did not fail"; exit 1
}
if ($nov -gt 0) { exit 2 }
if ($fail -gt 0) { exit 1 }
exit 0
