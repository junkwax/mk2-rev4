param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 150,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "kitana_spinchop_test.lua"
$LogPath = Join-Path $ToolsDir "kitana_spinchop_test.log"
$SnapshotRoot = Join-Path $ToolsDir "screens\kitana_spinchop"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start
# schedule (see the kahn launcher precedent).
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

# NOTE: launched with a direct blocking call, not Start-Process.  Under
# pwsh 7 the Start-Process path in run_mame_small.ps1 launches MAME with
# a mangled command line and -autoboot_script never loads (no [LUA] line).
# The lua exits MAME itself on finish/error; -seconds_to_run is a backstop.
# The sidecar's SAGs move whenever KITSPIN is repacked, so the window the lua
# matches drawn frames against is READ from the build rather than remembered.
$KitspinTbl = Join-Path (Split-Path -Parent $ToolsDir) "src\KITSPIN.TBL"
$sags = Select-String -Path $KitspinTbl -Pattern '\.long\s+0*([0-9a-fA-F]+)H' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) }
if ($sags.Count -lt 2) { Write-Error "[kitspin-test] no SAGs in $KitspinTbl"; exit 2 }
# Pad the top end: the last record's SAG is where its pixels START.
$env:KITSPIN_SAG_LO = "0x{0:x8}" -f ([int64]($sags | Measure-Object -Minimum).Minimum)
$env:KITSPIN_SAG_HI = "0x{0:x8}" -f ([int64](($sags | Measure-Object -Maximum).Maximum + 0x40000))
Write-Host "[kitspin-test] KITSPIN SAG window $($env:KITSPIN_SAG_LO)..$($env:KITSPIN_SAG_HI) (from src/KITSPIN.TBL)"

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

Write-Host "[kitspin-test] Launching Kitana spin chop test (hold Block + F,F)..."
$MameOutLog = Join-Path $ToolsDir "kitana_spinchop_mame_out.log"
# Detached, so there is a pid to hand the poker.  Source-built ROMs ALWAYS
# trip MAME's red ROM-warning screen, so without the poker the game never
# boots: the log fills with gs=0 / p1objchar=65535 for the whole backstop,
# which reads like the move failing when in fact nothing ever started.  That
# is a NO VERDICT, not a FAIL - and this rig is now the negative control for
# ktspin (MAINEQU.ASM), so telling the two apart is its whole job.
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $MameOutLog -RedirectStandardError "$MameOutLog.err"

# Its own process, never AppActivate + SendKeys from here: this shell started
# MAME with redirected stdio so it never owns the foreground, and the keys
# would land in a peer session's MAME window.  See mame_dismiss_warning.ps1.
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
    "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", 40) | Out-Null

$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) {
    Write-Host "[kitspin-test] backstop hit - stopping pid $($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

# Which way round is this rig?  ktspin (MAINEQU.ASM) decides whether the move
# exists at all, so the expectation is READ from the source rather than assumed:
# at 1 the chop must fire, at 0 it must be unreachable.  A rig hard-wired to
# the move existing would simply stay red forever once it was compiled out,
# and a permanently-red rig guards nothing.
$MainEqu = Join-Path (Split-Path -Parent $ToolsDir) "src\MAINEQU.ASM"
$m = Select-String -Path $MainEqu -Pattern '^ktspin\s+\.set\s+(\d+)' | Select-Object -First 1
if (-not $m) { Write-Error "[kitspin-test] no ktspin .set in $MainEqu - cannot tell which result is correct."; exit 2 }
$Expect = [int]$m.Matches[0].Groups[1].Value
Write-Host "[kitspin-test] ktspin .set $Expect - expecting the chop to $(if ($Expect) {'FIRE'} else {'be ABSENT'})."

$failed = $false
if (Test-Path $LogPath) {
    Write-Host "[kitspin-test] Log tail:"
    Get-Content -Path $LogPath -Tail 40

    $fired   = [bool](Select-String -Path $LogPath -Pattern "\[kitspin\] PASS" -Quiet)
    $judged  = [bool](Select-String -Path $LogPath -Pattern "move_fired=" -Quiet)

    if (-not $judged) {
        # Never reached a fight, so there is nothing to conclude either way.
        # Calling that a FAIL would be a false negative - the commonest cause
        # is stale addresses in kitana_spinchop_test.lua (.bss moves on every
        # build; a dead GSTATE reads a constant 0 and nothing ever starts).
        Write-Host "[kitspin-test] NO VERDICT - no fight was reached; see $MameOutLog"
        exit 2
    }

    if ($Expect -eq 1) {
        if ($fired) { Write-Host "[kitspin-test] PASS - the chop fired, as ktspin 1 requires." }
        else { Write-Error "[kitspin-test] FAIL - ktspin is 1 but the chop never fired."; $failed = $true }
    } else {
        if ($fired) { Write-Error "[kitspin-test] FAIL - ktspin is 0 but the chop STILL fired."; $failed = $true }
        else { Write-Host "[kitspin-test] PASS - Kitana held Block and tapped Forward, Forward and the chop never started (ktspin 0)." }
    }
} else {
    Write-Error "[kitspin-test] Lua log was not created."
    $failed = $true
}

Write-Host "[kitspin-test] Snapshots: $RunSnapshots"
if ($failed) { exit 1 }
