# The select screen's Reptile <-> Ermac START toggle (MKSEL.ASM
# ermac_start_tap).  See tools/ermac_start_toggle_test.lua.
#
#   tools\run_ermac_start_toggle_test.ps1 -Player 1                # 5 taps, confirm -> Ermac
#   tools\run_ermac_start_toggle_test.ps1 -Player 2
#   tools\run_ermac_start_toggle_test.ps1 -Player 1 -Mode leave    # tap, walk off -> Cage
#
# Snapshots (mid-wipe, Ermac, back to Reptile, the confirm) land in
# tmp/ermac_start_toggle/<mode>_p<N>/.
param(
    # mame_mk2test.exe is a byte copy of mame.exe under another NAME, so this
    # rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 160,
    [int]$Player = 1,
    [ValidateSet("toggle","leave","cross","ladder","inert","count")]
    [string]$Mode = "toggle",
    # ermac = Scorpion's square, jade = Kitana's, rain = Sub-Zero's (morph_table);
    # kham = MILEENA's, which is a Start x5 COUNTER not a morph (-Mode count);
    # reptile = no morph at all, for -Mode inert
    [ValidateSet("ermac","jade","rain","reptile","kham")]
    [string]$Target = "ermac",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "ermac_start_toggle_test.lua"
$OutDir = Join-Path $Root "tmp\ermac_start_toggle\$($Target)_$($Mode)_p$Player"
$LogPath = Join-Path $OutDir "rig.log"
New-Item -ItemType Directory -Force $OutDir | Out-Null
Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

# DOSBox stamps mk2.out with its own clock, which runs up to a minute AHEAD of
# the host, so a zip packaged straight after a build can look older than the
# link it came from.  Only a gap bigger than that skew means a stale zip.
if ((Get-Item (Join-Path $RomPath "mk2.zip")).LastWriteTime.AddSeconds(120) -lt (Get-Item (Join-Path $Root "src\mk2.out")).LastWriteTime) {
    throw "$RomPath\mk2.zip is older than src\mk2.out - the map would not match the ROM; run makerom/makevrom/mamerom first"
}

$env:EST_LOG = $LogPath
$env:EST_PLAYER = [string]$Player
$env:EST_MODE = $Mode
$env:EST_TARGET = $Target

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
    "-snapshot_directory", $OutDir,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[est] $Target P$Player mode=$Mode"
$MameOutLog = Join-Path $OutDir "mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    foreach ($v in @("EST_LOG","EST_PLAYER","EST_MODE","EST_TARGET")) { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
}

if (Test-Path $LogPath) {
    $verdict = Select-String -Path $LogPath -Pattern '^\[est\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict) { Write-Host $verdict.Line } else { Write-Host "[est] NO VERDICT - check $LogPath and $MameOutLog" }
} else {
    Write-Host "[est] NO LOG - MAME never started; see $MameOutLog"
}
