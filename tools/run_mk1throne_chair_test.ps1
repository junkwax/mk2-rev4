param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [ValidateSet("shang","control")]
    [string]$Mode = "shang",
    [int]$BackstopEmuSeconds = 160
)
# THE THRONE ROOM (MK1), curback 01Ch: with Shang Tsung IN the fight is the
# throne drawn EMPTY (the strips tools/make_thrnchair.py cuts), and without him
# is the seated Shang still drawn?  See tools/mk1throne_chair_test.lua.
#
#   -Mode shang     P2 forced to Shang Tsung: every strip, no Shang piece
#   -Mode control   nobody is Shang: Shang's pieces, no strip
#
# Runs its own windowed instance against rom/, NOT C:\MAME\roms - the shared
# install belongs to whoever put it there.

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "mk1throne_chair_test.lua"
$LogPath   = Join-Path $ToolsDir "mk1throne_chair_test_$Mode.log"
$RunSnapshots = Join-Path $ToolsDir "screens\mk1throne_chair\$Mode"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$env:MK2_CHAIR_MODE = $Mode
$env:MK2_CHAIR_TAG = $Mode

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-nothrottle",
    "-nvram_directory", (Join-Path $RunSnapshots "nvram"),
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)

Write-Host "[chair] Launching the THE THRONE ROOM empty-throne test (mode=$Mode)..."
$MameOutLog = Join-Path $ToolsDir "mk1throne_chair_${Mode}_mame.log"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $MameOutLog `
    -RedirectStandardError  "$MameOutLog.err"

# Poke past the ROM-warning box.  Source-built video ROMs always mismatch SHA1,
# so MAME parks on the red screen; -skip_gameinfo does not cover it.  This MUST
# be the standalone PostMessage poker, not AppActivate + SendKeys - see the
# header of mame_dismiss_warning.ps1.
$poker = Start-Process -FilePath "powershell" -PassThru -WindowStyle Hidden `
    -ArgumentList @("-ExecutionPolicy","Bypass","-File",
                    (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
                    "-ProcessId",$proc.Id,"-ReadyFile",$LogPath,"-TimeoutSec",180)

# Do not wait the backstop out if it never starts: no lua log inside the grace
# window means the box was never cleared, so kill and say so rather than
# returning an empty run that reads like a broken ROM.
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) { break }
    if (Test-Path $LogPath) { break }
}
if (-not $proc.HasExited -and -not (Test-Path $LogPath)) {
    Write-Host "[chair] parked on the ROM warning box - no lua log after 63s, killing"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
if ($poker -and -not $poker.HasExited) { Stop-Process -Id $poker.Id -Force -ErrorAction SilentlyContinue }

if (Test-Path $LogPath) {
    Get-Content -Path $LogPath | Select-String "FIGHT|chair|RESULT"
} else {
    Write-Host "[chair] no log - the run produced nothing"
}
