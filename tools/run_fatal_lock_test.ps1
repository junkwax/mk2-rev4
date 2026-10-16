# run_fatal_lock_test.ps1 - one finisher per round (f_fatal_lock).
#
# Reproduces the state Liu Kang's cartwheel used to leave behind (FINISH HIM,
# victim dizzy, f_death = -1, stick handed back) and fires the Dead Pool
# stage-fatality uppercut (LP+LK held) at the dead victim.
#
#   -Mode locked   PASS = the victim is never slimed (no second finisher)
#   -Mode control  PASS = the victim IS slimed with the lock clear, proving
#                  the rig can see a stage fatality at all
#
# Launch pattern copied from run_conditions_test.ps1: Start-Process with
# redirected output plus mame_dismiss_warning.ps1 as a separate process,
# because a direct call parks on the ROM-warning screen.
param(
    [ValidateSet("locked", "control")]
    [string]$Mode = "locked",
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 400
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "fatal_lock_test.lua"
$Log = Join-Path $ToolsDir "fatal_lock_test_$Mode.log"
$Out = Join-Path $ToolsDir "fatal_lock_mame_$Mode.log"
$Err = Join-Path $ToolsDir "fatal_lock_mame_$Mode.err"
$SnapDir = Join-Path $ToolsDir "screens\fatal_lock_$Mode"

Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item $Log, $Out, $Err -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:FL_MODE = $Mode
$env:FL_TEST_LOG = $Log

$mameArgs = @("-rompath", $RomPath, "mk2", "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-sound", "none", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir, "-autoboot_script", $Lua, "-seconds_to_run", $Backstop,
    "-cfg_directory", "C:\MAME\cfg", "-nothrottle")

Write-Host "[fatlock] mode=$Mode"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru -RedirectStandardOutput $Out -RedirectStandardError $Err

Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
    "-ProcessId", $proc.Id, "-TimeoutSec", 25) | Out-Null

$proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Remove-Item Env:\FL_MODE, Env:\FL_TEST_LOG -ErrorAction SilentlyContinue

# The Lua's io.open log may not appear under MAME; its prints land on stdout.
$lines = @()
if (Test-Path $Log) { $lines += Get-Content $Log }
if (Test-Path $Out) { $lines += Get-Content $Out | Where-Object { $_ -match "\[fatlock\]" } }
$lines | Select-Object -Unique | Where-Object { $_ -match "RESULT|mode=|finish_him|dizzy|attempt|WARN|MISSING" }
if (-not ($lines -match "RESULT ")) {
    Write-Warning "[fatlock] no verdict - see $Out / $Err"
    if (Test-Path $Err) { Get-Content $Err -Tail 15 }
}
Write-Host "[fatlock] snapshots: $SnapDir"
