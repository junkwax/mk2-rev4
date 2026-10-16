#
# run_deadpool_boon_drop_test.ps1 - one THE DEAD POOL acid-drop trial.
#
# One scheduled hanger - Tony (2) by default, Ed (0) with -Hanger 0 - goes
# into the pool on its round-clock value (hp_drop_clock, rolled per match: Ed
# at :95, Tony 20-40s later).  This drives a 2-player idle match onto the Dead Pool,
# watches the whole sequence from hook to parked skeleton, and reports each
# beat separately: trigger, fall, submerge, splash, simmer, skeleton rise,
# park.
#
# The bodies hang across the whole acid now (the order photo), so the rig pulls
# the two idle fighters over to the one it is watching - the camera follows
# them, and at rest it shows only world x 373..773.  -NoPinCam leaves them
# where they spawn, which is how to see what a real fight would frame.
#
# The rig never writes into the drop itself - it only forces the stage and the
# character select.  Every expected number is read out of MKHANG.ASM, so
# retuning an equate retunes the rig instead of breaking it.
#
#   .\tools\run_deadpool_boon_drop_test.ps1
#   .\tools\run_deadpool_boon_drop_test.ps1 -ClockJump    # don't wait for :95
#   .\tools\run_deadpool_boon_drop_test.ps1 -Trace        # per-tick log
#   .\tools\run_deadpool_boon_drop_test.ps1 -Throttle     # watch it at speed
#
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$BackstopEmuSeconds = 360,
    [int]$Tolerance = 30,          # percent slack on the tick budgets
    [switch]$ClockJump,            # slam the round clock to the trigger
    [switch]$Trace,                # per-tick trace lines
    [switch]$NoSnaps,
    [switch]$Throttle,             # run at real speed to judge the feel
    [double]$Watch = 0,            # e.g. 0.33 = watch the DROP at a third speed,
                                   #   while boot still runs flat out
    [double]$Speed = 0,            # static: slows the WHOLE run, boot included
    [int]$SnapEvery = 0,           # also snapshot every N ticks of the drop (filmstrip)
    [switch]$Sound,
    [int]$Hanger = -1,             # -1 = Geo (4), the newest; 3 = John, 2 = Tony, 0 = Ed
    [switch]$NoPinCam,             # do not pull the fighters over to him
    [switch]$NextRound,            # run into round 2: dropped bodies stay skeletons
    [int]$P1Char = 1,              # ft_ ids (MAINEQU.ASM): Liu Kang...
    [int]$P2Char = 11              # ...vs Jax by default
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "deadpool_boon_drop_test.lua"

$RunId = (Get-Date -Format "yyyyMMdd_HHmmss") + $(if ($ClockJump) { "_clockjump" } else { "" })
$OutDir = Join-Path $ToolsDir "screens\deadpool_boon_drop\run_$RunId"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Log = Join-Path $OutDir "deadpool_boon_drop_test.log"
$Ready = Join-Path $OutDir "ready.flag"
$MameLog = Join-Path $OutDir "mame_out.log"
# Stable copy of the latest log, so the doc can point at one path.
$LatestLog = Join-Path $ToolsDir "deadpool_boon_drop_test.log"

# Private cfg/nvram: a fresh CMOS every run (leftover credits desync the
# scripted coin/start schedule) and never the repo's committed cfg with TEST on.
$Private = Join-Path $OutDir "state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

# The map has to match the ROM under test or every symbol read is garbage.
$map = Join-Path $RepoRoot "src\mk2.map"
$rom = Join-Path $RomPath "mk2.zip"
if (-not (Test-Path $map)) { Write-Error "[dpboon] no src\mk2.map - build first." }
if (-not (Test-Path $rom)) { Write-Error "[dpboon] no $rom - run mamerom.py." }
$mapAge = (Get-Item $map).LastWriteTime
$romAge = (Get-Item $rom).LastWriteTime
if ([math]::Abs(($romAge - $mapAge).TotalMinutes) -gt 30) {
    Write-Warning "[dpboon] mk2.map ($mapAge) and mk2.zip ($romAge) are more than 30 min apart - symbol reads may be stale."
}

if (-not ("DpBoon.Win" -as [type])) {
    Add-Type -Namespace DpBoon -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
}

$env:DP_TEST_LOG = $Log.Replace("\", "/")
$env:DP_READY = $Ready.Replace("\", "/")
$env:DP_TOLERANCE = [string]$Tolerance
$env:DP_CLOCK_JUMP = $(if ($ClockJump) { "1" } else { "0" })
$env:DP_TRACE = $(if ($Trace) { "1" } else { "0" })
$env:DP_SNAPS = $(if ($NoSnaps) { "0" } else { "1" })
$env:DP_SNAP_EVERY = [string]$SnapEvery
$env:DP_WATCH = [string]$Watch
$env:DP_HANGER = [string]$Hanger
$env:DP_PIN_CAM = $(if ($NoPinCam) { "0" } else { "1" })
$env:DP_NEXT_ROUND = $(if ($NextRound) { "1" } else { "0" })
$env:DP_P1_CHAR = [string]$P1Char
$env:DP_P2_CHAR = [string]$P2Char

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $OutDir,
    "-cfg_directory", (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }
# Unthrottled by default: this is a measuring rig, not a viewing one.
# -Speed is for WATCHING: MAME's own factor, which needs the throttle on to
# mean anything, so it turns it on regardless of -Throttle.
if ($Speed -gt 0) {
    $mameArgs += @("-speed", ([string]$Speed))
} elseif (-not $Throttle) {
    $mameArgs += "-nothrottle"
}

Write-Host "[dpboon] clock_jump=$($ClockJump.IsPresent) throttle=$($Throttle.IsPresent) speed=$Speed watch=$Watch snap_every=$SnapEvery tolerance=$Tolerance% rom=$rom"
$proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -WorkingDirectory (Split-Path -Parent $Mame) `
    -RedirectStandardOutput $MameLog -PassThru -WindowStyle Normal

# Source-built sets trip MAME's CRC warning and it parks there at ~0 CPU.
# Post Enter/Space until the Lua's ready flag appears (written once frames are
# really running) - NOT the log, which the Lua opens at load time.
$deadline = (Get-Date).AddSeconds(120)
while (-not $proc.HasExited -and -not (Test-Path $Ready) -and (Get-Date) -lt $deadline) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        foreach ($k in 0x0D, 0x20) {
            [DpBoon.Win]::PostMessage($h, 0x100, [IntPtr]$k, [IntPtr]0) | Out-Null
            Start-Sleep -Milliseconds 60
            [DpBoon.Win]::PostMessage($h, 0x101, [IntPtr]$k, [IntPtr]0) | Out-Null
        }
    }
    Start-Sleep -Milliseconds 700
}
$noFrames = -not (Test-Path $Ready)
if ($noFrames) {
    Write-Warning "[dpboon] no ready flag - MAME never ran frames; killing it"
    if (-not $proc.HasExited) { $proc.Kill() }
} else {
    $proc.WaitForExit()
}

"DP_TEST_LOG", "DP_READY", "DP_TOLERANCE", "DP_CLOCK_JUMP", "DP_TRACE", "DP_SNAPS",
    "DP_SNAP_EVERY", "DP_WATCH" |
    ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

if (Test-Path $Log) {
    Copy-Item -LiteralPath $Log -Destination $LatestLog -Force
    Get-Content -Path $Log |
        Select-String -Pattern "^\[dpboon\] (BEAT |CHECK |BEATS |BUDGET |MEASURE |NOTE |WARN |FATAL |STALL |RESULT |watch: )" |
        ForEach-Object { Write-Host $_.Line }
    if (-not (Select-String -Path $Log -Pattern "RESULT " -Quiet)) {
        Write-Warning "[dpboon] no verdict - see $Log / $MameLog"
        Get-Content -Path $Log -Tail 40
    }
} elseif (-not $noFrames) {
    Write-Error "[dpboon] lua log was not created (see $MameLog)."
}
Write-Host "[dpboon] Run dir: $OutDir"
