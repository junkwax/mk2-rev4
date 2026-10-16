param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    # Two rigs at once kill the loser with exit -1 and a log that stops
    # mid-run, which reads exactly like the ROM crashing.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,

    # Which unlock to exercise.  Name selects the c_/f_ RAM variables.
    [ValidateSet("smoke","noob","ermac","kham","rain")]
    [string]$Name = "ermac",
    # DCS track (hex, e.g. 0578) the select-screen name call must send.
    [string]$WatchTrack = "",
    [int]$Player = 1,           # 1 = P1 in a 1P game, 2 = P2 in a 2P game

    # Hover a character other than the unlock's base to run the REGRESSION
    # check instead: Block is a confirm button, so one press off-base must
    # still confirm normally and must never produce the hidden fighter.
    [int]$Hover = -1,
    # Frames to keep running PAST the unlock before saving a screenshot.
    # 0 = stop at the unlock (the plain pass/fail check).
    [int]$Snap = 0,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDirProbe = Split-Path -Parent $MyInvocation.MyCommand.Path

# ft_ ids from src/MAINEQU.ASM.  base = the roster character the cursor sits
# on; expect = the hidden fighter Block x5 must produce.
$Unlocks = @{
    smoke = @{ base = 10; expect = 14 }   # Scorpion -> Smoke
    noob  = @{ base =  8; expect = 15 }   # Sub-Zero -> Noob Saibot
    ermac = @{ base =  9; expect = 17 }   # Reptile  -> Ermac
    # KHAMELEON is no longer a Block cheat at all: she moved to MILEENA +
    # Start x5 on 2026-09-25 (kham_start_tap, MKSEL.ASM - use
    # run_ermac_start_toggle_test.ps1 -Target kham -Mode count for the
    # positive test).  Her row is kept here as the REGRESSION control that
    # Block on Kitana confirms Kitana normally again, so `blockpath = $false`
    # forces the disabled-path assertion whatever kham_select_enable says.
    # NOTE 2026-09-26: this row has NO f_kham_blk_held<P> in mk2.map, because
    # her Block cheat is gone.  That is expected, not a fault - the lua treats
    # `held` as optional and reports it as n/a.  If -Name kham ever starts
    # failing oddly, or a rig reports a missing symbol, CHECK HERE FIRST: the
    # likely cause is someone restoring an unguarded read of A.held, or this
    # row being mistaken for a stale entry and deleted.  It is a deliberate
    # regression control and should stay.
    kham  = @{ base =  4; expect = 18; blockpath = $false }   # Kitana -> ordinary confirm
    rain  = @{ base = 10; expect = 19 }   # Scorpion -> Rain
}
$u = $Unlocks[$Name]
if ($Hover -lt 0) { $Hover = $u.base }

# Each Block x5 unlock is behind a *_select_enable equate in MAINEQU.ASM, and
# check_hidden_blk_cheat .if's its branch out when that is 0.  Rain, Ermac,
# Noob and Smoke were all switched off on 2026-09-22 in favour of the START-tap
# morph (MKSEL.ASM morph_table), so Block on their base character is an
# ordinary confirm and this rig must assert THAT, not report FAIL for the
# feature working as designed.  Read the equate rather than hardcoding it.
$EnableEqu = @{
    smoke = "smoke_select_enable"
    noob  = "noob_select_enable"
    ermac = "ermac_blk_select_enable"
    kham  = "kham_select_enable"
    rain  = "rain_select_enable"
}
$MainEqu = Join-Path (Split-Path -Parent $ToolsDirProbe) "src\MAINEQU.ASM"
$equName = $EnableEqu[$Name]
$equLine = Select-String -Path $MainEqu -Pattern "^\s*$equName\s+\.set\s+(\d+)" |
           Select-Object -First 1
if (-not $equLine) { throw "could not read $equName from $MainEqu" }
$equVal = [int]$equLine.Matches[0].Groups[1].Value
# kham_select_enable still gates KHAMELEON, but her input left the Block path,
# so the equate being 1 does not mean Block x5 unlocks her.
$onBlockPath = -not ($u.ContainsKey("blockpath") -and -not $u.blockpath)
$Disabled = (($equVal -eq 0) -or (-not $onBlockPath))

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "hidden_cheat_test.lua"
$LogPath = Join-Path $ToolsDir "hidden_cheat_$($Name)_p$Player.log"

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:CHEAT_LOG = $LogPath
$env:CHEAT_NAME = $Name
if ($WatchTrack) { $env:CHEAT_WATCH = $WatchTrack } else { Remove-Item Env:\CHEAT_WATCH -ErrorAction SilentlyContinue }
$env:CHEAT_PLAYER = [string]$Player
$env:CHEAT_HOVER = [string]$u.base
$env:CHEAT_HOVER_OVERRIDE = [string]$Hover
$env:CHEAT_EXPECT = [string]$u.expect
$env:CHEAT_SNAP = [string]$Snap
if ($Disabled) { $env:CHEAT_DISABLED = "1" } else { Remove-Item Env:\CHEAT_DISABLED -ErrorAction SilentlyContinue }

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

$mode = if ($Disabled -and $Hover -eq $u.base) {
    $(if ($onBlockPath) { "DISABLED ($equName = 0" }
      else { "DISABLED (not a Block unlock any more" }) +
    " - hover $($u.base), Block x5 -> expect NO hidden fighter)"
} elseif ($Hover -eq $u.base) {
    "CHEAT (hover $($u.base), Block x5 -> expect char $($u.expect))"
} else {
    "REGRESSION (hover char $Hover, Block x1 -> expect normal confirm)"
}
Write-Host "[$Name] P$Player - mode: $mode"
$MameOutLog = Join-Path $ToolsDir "hidden_cheat_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    foreach ($v in @("CHEAT_LOG","CHEAT_NAME","CHEAT_PLAYER","CHEAT_HOVER",
                     "CHEAT_HOVER_OVERRIDE","CHEAT_EXPECT","CHEAT_SNAP",
                     "CHEAT_DISABLED")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    $verdict = Select-String -Path $LogPath -Pattern '^\[.*\] (PASS|FAIL)' |
               Select-Object -Last 1
    if ($verdict) { Write-Host $verdict.Line }
    else { Write-Host "[$Name] NO VERDICT - check $LogPath and $MameOutLog" }
} else {
    Write-Host "[$Name] NO LOG - MAME never started; see $MameOutLog"
}
