param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so this
    # rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 150,
    # Force a stage (curback id).  -1 = whatever the game picks.
    [int]$Stage = -1,
    # The mk2.map that belongs to -RomPath's zip.  Given = a frozen pair, so the
    # live-tree staleness check below is skipped.
    [string]$Map = "",
    # -Negative: run against a ROM with act_rain_storm patched back OUT of
    # cmb_holds - one word, nothing else - and require the aircombo trial to
    # FAIL.  Without it a PASS only says the clock was not running; it does not
    # say this fix is why.
    [switch]$Negative,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "rain_zap_combo_test.lua"
$LogPath = Join-Path $ToolsDir "rain_zap_combo_test.log"

# A rig reads symbol addresses out of the CURRENT src/mk2.map; a zip from
# another build reads every one of them at the wrong address and reports
# nothing wrong.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[rzcombo] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

if ($Negative) {
    $negDir = Join-Path $env:TEMP "mk2_rzcombo_neg"
    $srcZip = Join-Path $RomPath "mk2.zip"
    $srcMap = if ($Map) { $Map } else { Join-Path $Root "src\mk2.map" }
    Remove-Item -LiteralPath $negDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $negDir | Out-Null
    Copy-Item $srcMap (Join-Path $negDir "mk2.map") -Force
    # The helper copies the map from beside the zip; give it one it can find.
    $negSrc = Join-Path $env:TEMP "mk2_rzcombo_src"   # NOT $stage: the param block has [int]$Stage and PowerShell variables are case-insensitive, so the path was coerced to Int32
    Remove-Item -LiteralPath $negSrc -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $negSrc | Out-Null
    Copy-Item $srcZip (Join-Path $negSrc "mk2.zip") -Force
    Copy-Item $srcMap (Join-Path $negSrc "mk2.map") -Force
    & python (Join-Path $ToolsDir "rain_zap_combo_negrom.py") (Join-Path $negSrc "mk2.zip") $negDir
    if ($LASTEXITCODE -ne 0) { Write-Host "[rzcombo] could not build the pre-fix ROM - no control, no verdict"; exit 2 }
    $RomPath = $negDir
    $Map = Join-Path $negDir "mk2.map"
    Write-Host "[rzcombo] NEGATIVE: act_rain_storm patched out of cmb_holds; aircombo MUST fail"
}

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:RZC_LOG = $LogPath
if ($Map) { $env:RZC_MAP = $Map } else { Remove-Item Env:\RZC_MAP -ErrorAction SilentlyContinue }
if ($Stage -ge 0) { $env:RZC_STAGE = [string]$Stage } else { Remove-Item Env:\RZC_STAGE -ErrorAction SilentlyContinue }

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[rzcombo] Rain's cloud: does the combo clock pause while he is held?"
$MameOutLog = Join-Path $ToolsDir "rain_zap_combo_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    foreach ($v in @("MK2_ROOT", "RZC_LOG", "RZC_STAGE", "RZC_MAP")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 45
    $verdict = Select-String -Path $LogPath -Pattern '^\[rzcombo\] (PASS|FAIL)' | Select-Object -Last 1
    if (-not $verdict) { Write-Host "[rzcombo] NO VERDICT - see $MameOutLog"; exit 1 }
    if ($Negative) {
        # The control has to fail for the RIGHT reason: a run that never held him,
        # or never built a 2-hit string, is NO VERDICT and not a passing control.
        $air = Select-String -Path $LogPath -Pattern '^\[rzcombo\] aircombo' | Select-Object -Last 1
        $ctl = Select-String -Path $LogPath -Pattern '^\[rzcombo\] pinnedair' | Select-Object -Last 1
        if ($air -and $air.Line -match 'NO VERDICT') {
            Write-Host "[rzcombo] NEGATIVE inconclusive - the trial never measured the hold"; exit 1
        }
        if ($air -and $air.Line -match 'FAIL' -and $air.Line -match 'clock_lost_in_hold=([1-9][0-9]*)') {
            Write-Host "[rzcombo] NEGATIVE OK - the pre-fix ROM loses $($Matches[1]) ticks of the window while he is held"
            if ($ctl -and $ctl.Line -notmatch 'OK') {
                Write-Host "[rzcombo] ...but pinnedair did not hold up on the control ROM"; exit 1
            }
            exit 0
        }
        Write-Host "[rzcombo] NEGATIVE FAILED - the pre-fix ROM passed, so this rig does not test the fix"
        exit 1
    }
    if ($verdict.Line -match 'PASS') { exit 0 }
    exit 1
} else {
    Write-Host "[rzcombo] NO LOG - MAME never started; see $MameOutLog"
    exit 1
}
