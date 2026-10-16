param(
    # mame_slhtest.exe is a byte copy of mame.exe under a NAME OF THIS RIG'S
    # OWN.  A shared "test" binary does not isolate anything: several rigs in
    # this tree default to mame_mk2test.exe, and one of them cleans up by
    # process NAME, so a concurrent session's sweep killed this rig's MAME
    # mid-run.  That does not read as contention - it reads as a broken ROM:
    # every trial NOT REACHED, "input UI Select MISSING", FAIL reason=timeout.
    # It is a NO-VERDICT, not a failure.  This rig itself kills nothing.
    [string]$Mame = "C:\MAME\mame_slhtest.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 340,
    # Snapshot the steered trials into tmp/slicehat/ (every 3rd flight frame).
    [switch]$Snap,
    # The mk2.map that belongs to -RomPath's zip.  Given = a frozen pair, so the
    # live-tree staleness check below is skipped.
    [string]$Map = "",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "slicehat_test.lua"
$LogPath = Join-Path $ToolsDir "slicehat_test.log"
$SnapDir = Join-Path $Root "tmp\slicehat"

# A rig reads symbol addresses out of the CURRENT src/mk2.map; a zip from
# another build reads every one of them at the wrong address.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[slh] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

# The SAGs move on every rebuild, so the expectation file is regenerated here
# rather than trusted.  A stale one would pass against whatever art landed at
# the old address.
& python (Join-Path $ToolsDir "slicehat_expect.py")
if ($LASTEXITCODE -ne 0) { Write-Host "[slh] could not regenerate expectations"; exit 2 }

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
if ($Snap) {
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Get-ChildItem $SnapDir -Filter *.png -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
}

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:SLH_LOG = $LogPath
$env:SLH_SNAP = if ($Snap) { "1" } else { "0" }
if ($Map) { $env:SLH_MAP = $Map } else { Remove-Item Env:\SLH_MAP -ErrorAction SilentlyContinue }

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

# Explicit, even though -WorkingDirectory already points MAME at C:\MAME and so
# at C:\MAME\cfg.  If that ever goes, MAME reads the REPO's committed
# cfg/mk2.cfg, which has the TEST switch on: the game sits in the operator menu
# and the rig measures nothing, which reads exactly like the feature being
# broken.
$mameArgs += @("-cfg_directory", "C:\MAME\cfg")

Write-Host "[slh] Kung Lao: hat bank angle (both facings / boomerang / hit)"
$MameOutLog = Join-Path $ToolsDir "slicehat_mame_out.log"
$MameErrLog = Join-Path $ToolsDir "slicehat_mame_err.log"

# START IT DETACHED so there is a pid to hand the poker.  `& $Mame` blocks and
# gives no handle, and without the poker MAME sits on the ROM-warning screen
# waiting for a key it will never get - the run then ends with NO LOG, which
# reads exactly like the ROM being broken rather than like nothing having
# started.  Source-built ROMs always trip that warning, so this is not an
# occasional thing; earlier runs only got past it by luck of focus.
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $MameOutLog -RedirectStandardError $MameErrLog

# A SEPARATE PROCESS, not a SendKeys loop in here: this shell started MAME with
# redirected stdout/stderr, so it never owns the foreground and Windows refuses
# its SetForegroundWindow - the keys go nowhere.  See the header of
# mame_dismiss_warning.ps1.
$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $poker,
    "-ProcessId", $proc.Id, "-TimeoutSec", 25) | Out-Null

try {
    $proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) {
        Write-Host "[slh] backstop hit - stopping MAME"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} finally {
    foreach ($v in @("MK2_ROOT", "SLH_LOG", "SLH_SNAP", "SLH_MAP")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 60
    $verdict = Select-String -Path $LogPath -Pattern '^\[slh\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match 'PASS') { exit 0 }
    if (-not $verdict) { Write-Host "[slh] NO VERDICT - see $MameOutLog" }
    exit 1
} else {
    Write-Host "[slh] NO LOG - MAME never started; see $MameOutLog"
    exit 1
}
