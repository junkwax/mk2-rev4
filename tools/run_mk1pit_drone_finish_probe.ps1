param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    # Two rigs at once kill the loser with exit -1 and a log that stops
    # mid-run, which reads exactly like the ROM crashing.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 900,
    [int]$VictimX = 400,           # world x the victim is pinned at
    [ValidateSet("left", "right")]
    [string]$Side = "left",        # which side the ATTACKER stands on
    [int]$Gap = 55,
    [int]$Observe = 260,
    [switch]$Sound
)

# THE PIT (MK1): the CPU wins on curback 01Ah and finishes with the pit.
# See tools/mk1pit_drone_finish_probe.lua and doc/MK1_PIT_STAGE.md.

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "mk1pit_drone_finish_probe.lua"
$LogPath = Join-Path $ToolsDir "mk1pit_drone_finish_probe.log"
$RunId = "vx${VictimX}_$Side" + "_" + (Get-Date -Format "yyyyMMdd_HHmmss")
$RunSnapshots = Join-Path (Join-Path $ToolsDir "screens\mk1pit_drone_finish") "run_$RunId"
$MameOutLog = Join-Path $ToolsDir "mk1pit_drone_finish_mame_out.log"
$MameErrLog = Join-Path $ToolsDir "mk1pit_drone_finish_mame_err.log"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MD_TEST_LOG = $LogPath
$env:MP_VX = [string]$VictimX
$env:MP_SIDE = $Side
$env:MP_GAP = [string]$Gap
$env:MP_OBSERVE = [string]$Observe

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-cfg_directory", "C:\MAME\cfg",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[mk1pit] victim_x=$VictimX attacker_side=$Side gap=$Gap"

$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $MameOutLog -RedirectStandardError $MameErrLog

# Poke past the ROM-warning screen.  It ALWAYS appears for mk2 - the driver
# carries undumped PLDs, and on top of that every source build changes the
# program and video SHA1s - and there is no -skip_warnings switch in this
# build.  Without this MAME parks on "press any key", the autoboot Lua never
# loads, no log is ever created, and it reads exactly like a crash.
#
# It has to be a SEPARATE process, not a SendKeys loop in here: this shell
# started MAME with redirected stdout/stderr, so it never owns the foreground
# and Windows refuses its SetForegroundWindow.  See the header of
# mame_dismiss_warning.ps1.
#
# ReadyFile is this rig's own log, which the Lua opens the instant it loads -
# a definitive "we are past the warning" signal, so the poker stops stealing
# focus rather than typing through the whole fatality.
$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $poker,
    "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", 60) | Out-Null

$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

"MD_TEST_LOG", "MP_VX", "MP_SIDE", "MP_GAP", "MP_OBSERVE" | ForEach-Object {
    Remove-Item "Env:\$_" -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Get-Content -Path $LogPath | Select-String -Pattern "RESULT " | ForEach-Object { Write-Host $_ }
    if (-not (Select-String -Path $LogPath -Pattern "RESULT " -Quiet)) {
        Write-Warning "[mk1pit] no verdict - see $LogPath / $MameOutLog"
        Get-Content -Path $LogPath -Tail 30
    }
} else {
    Write-Error "[mk1pit] lua log was not created (see $MameOutLog)."
}
Write-Host "[mk1pit] Log:       $LogPath"
Write-Host "[mk1pit] Snapshots: $RunSnapshots"
