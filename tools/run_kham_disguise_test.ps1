param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    # She needs four changes at up to 7s each, plus the boot and the select
    # screen, so this backstop is much longer than the old BIV rig's.
    [int]$BackstopEmuSeconds = 320,
    [int]$Player = 2,
    # Cross the expected disguise colours by one - it MUST fail.  A rig that
    # only notices "the colour map moved" passes this; one that reads WHICH
    # disguise arrived cannot.
    [switch]$Negative,
    # Play the same 1P game and make NO taps: she must not appear. This is
    # the control for the summons itself, as opposed to -Negative which is
    # the control for the palette reading.
    [switch]$NoTaps,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kham_disguise_test.lua"
$LogPath = Join-Path $ToolsDir "kham_disguise_test.log"
$MarkerPath = Join-Path $ToolsDir "kham_disguise_started.tmp"

# Regenerate the expectations from data/MK2PALS.IMG every run, so the rig can
# never pass against a colour that was true before the last repaint.
Write-Host "[kham-dis] regenerating expectations from data/MK2PALS.IMG"
& python (Join-Path $ToolsDir "kham_disguise_expect.py")
if ($LASTEXITCODE -ne 0) { Write-Host "[kham-dis] expectation generator FAILED"; exit 1 }

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $RepoRoot.Replace("\", "/")
$env:KD_PLAYER = [string]$Player
$env:KD_LOG = $LogPath
if ($Negative) { $env:KD_NEGATIVE = "1" } else { $env:KD_NEGATIVE = "0" }
if ($NoTaps) { $env:KD_NOTAPS = "1" } else { $env:KD_NOTAPS = "0" }
$env:KD_MARKER = $MarkerPath.Replace("\", "/")

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    # Without an explicit keyboardprovider MAME parks on the "press any key"
    # warning screen and the rig times out with no ROM ever running.
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

$mode = if ($NoTaps) { "CONTROL (no taps - she must not appear)" } elseif ($Negative) { "NEGATIVE (must fail)" } else { "normal" }
Write-Host "[kham-dis] P$Player $mode - real summons (1P, Start x5 on the BATTLE PLAN), then watch her disguises"
$MameOutLog = Join-Path $ToolsDir "kham_disguise_mame_out.log"
$MameErrLog = Join-Path $ToolsDir "kham_disguise_mame_err.log"

# A source-built ROM never matches MAME's hardcoded CRC/SHA1 table, so the
# "press any key to continue" box is posted on EVERY launch. It has to be poked
# past from a SEPARATE process: this shell starts MAME with redirected
# stdout/stderr, so it never owns the foreground and Windows refuses its
# SetForegroundWindow - the keys would go nowhere. See the header of
# mame_dismiss_warning.ps1.
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $MameOutLog -RedirectStandardError $MameErrLog

# -ReadyFile is the MARKER the lua drops on reaching the select screen, not the
# lua's own log: that log is opened when the script LOADS, before emulation has
# started, so a poker waiting on it would stop before poking once. The marker
# cannot appear until the warning is gone.
$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $poker,
    "-ProcessId", $proc.Id, "-ReadyFile", $MarkerPath, "-TimeoutSec", 30) | Out-Null

# Grace, then KILL. A rig that misses the box and then waits the process out
# burns the whole -seconds_to_run backstop producing nothing, and from the
# outside that is indistinguishable from a slow run. So poll for the marker and
# say WHY if it never lands, rather than leaving it to be guessed at.
$graceSec = 60
$deadline = (Get-Date).AddSeconds($graceSec)
$started = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $MarkerPath) { $started = $true; break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $started -and -not $proc.HasExited) {
    Write-Host "[kham-dis] never reached the select screen in ${graceSec}s - almost certainly parked on the ROM warning box; killing"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
foreach ($v in @("MK2_ROOT", "KD_PLAYER", "KD_LOG", "KD_NEGATIVE", "KD_NOTAPS", "KD_MARKER")) {
    Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 8
    # The lua prints PASS/FAIL already inverted for -Negative, so the verdict
    # line means the same thing in both modes: PASS = the run did what it must.
    $verdict = Select-String -Path $LogPath -Pattern '^\[kham-dis\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match '^\[kham-dis\] PASS') { exit 0 }
    exit 1
} else {
    Write-Host "[kham-dis] NO LOG - see $MameOutLog and $MameErrLog"
    exit 1
}
