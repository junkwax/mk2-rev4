param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 150,
    # -Negative crosses the expectation: it demands the gleam come out in Kung
    # Lao's own COSTUME palette, which is what it did before hhgleam, so the
    # run MUST fail.  Without it the pass means only "some palette".
    [switch]$Negative,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would otherwise be promoted
# to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "hh_gleam_test.lua"
$Tag = if ($Negative) { "_negative" } else { "" }
$LogPath = Join-Path $ToolsDir "hh_gleam_test$Tag.log"
$SnapshotRoot = Join-Path $ToolsDir "screens\hh_gleam"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId$Tag"
$MameOutLog = Join-Path $ToolsDir "hh_gleam_mame_out$Tag.log"

# A zip paired with another build's map reads every symbol at the wrong address
# and reports nothing wrong, so refuse the pairing outright rather than
# producing a confident verdict about the wrong RAM.
$Zip = Join-Path $RomPath "mk2.zip"
$Map = Join-Path $Root "src\mk2.map"
foreach ($f in @($Zip, $Map, $LuaScript)) {
    if (-not (Test-Path $f)) { Write-Error "[hh-gleam] missing $f"; exit 1 }
}
if ((Get-Item $Zip).LastWriteTime -lt (Get-Item (Join-Path $Root "src\mk2.out")).LastWriteTime) {
    Write-Error "[hh-gleam] $Zip is older than src/mk2.out - repackage before testing"
    exit 1
}

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the jade-victory / boomerang launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:HH_GLEAM_LOG = $LogPath
$env:HH_GLEAM_EXPECT = if ($Negative) { "costume" } else { "hatgbl" }

# NOTE: direct blocking call, not Start-Process - under pwsh 7 the
# Start-Process path launches MAME with a mangled command line and
# -autoboot_script never loads. The lua exits MAME itself on finish/error;
# -seconds_to_run is a backstop only.
$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

$mode = if ($Negative) { "NEGATIVE (must fail)" } else { "normal" }
Write-Host "[hh-gleam] launching Kung Lao victory gleam test - $mode ..."
Push-Location (Split-Path -Parent $Mame)
try {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs *> $MameOutLog
    $ErrorActionPreference = $prevEap
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:HH_GLEAM_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:HH_GLEAM_EXPECT -ErrorAction SilentlyContinue
}

Write-Host "[hh-gleam] screenshots: $RunSnapshots"

if (-not (Test-Path $LogPath)) {
    Write-Error "[hh-gleam] NO VERDICT (no log created - did MAME stall on a warning screen?)"
    exit 1
}

Get-Content -Path $LogPath -Tail 30

$passed = Select-String -Path $LogPath -Pattern "\[hh-gleam\] PASS" -Quiet
$errored = Select-String -Path $LogPath -Pattern "\[hh-gleam\] ERROR" -Quiet
# A run that reached no verdict is neither a pass nor a regression, in either
# mode - saying so is the point.
if (Select-String -Path $LogPath -Pattern "NO VERDICT" -Quiet) {
    Write-Error "[hh-gleam] NO VERDICT - see the log; nothing is proved either way"
    exit 1
}

if ($Negative) {
    if ($errored -and -not $passed) {
        Write-Host "[hh-gleam] NEGATIVE CONTROL OK (crossed expectation failed, as it must)" -ForegroundColor Green
        exit 0
    }
    Write-Error "[hh-gleam] NEGATIVE CONTROL FAILED - the crossed expectation passed"
    exit 1
}

if ($errored -or -not $passed) {
    Write-Error "[hh-gleam] FAILED"
    exit 1
}

# The stage counter only proves the ani2 rows advance through the expected
# SAGs, and palram only proves which palette the object POINTS at - a matching
# pointer with nothing painted behind it is exactly how the Jade sidecar hole
# passed its harness for months.  So count the DRAWN pixels too.
Write-Host "[hh-gleam] pointer checks passed - verifying the drawn pixels..."
$snapOut = & python (Join-Path $ToolsDir "hh_gleam_pixels.py") $RunSnapshots 2>&1
$snapOut | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -eq 2) {
    Write-Warning "[hh-gleam] pixel check could not run - the PASS is pointer-level only"
} elseif ($LASTEXITCODE -ne 0) {
    Write-Error "[hh-gleam] FAILED - the object points at HATGBL_P but was not drawn in it"
    exit 1
}

Write-Host "[hh-gleam] PASSED (own object, own palette, drawn in it, hidden and released)" -ForegroundColor Green
