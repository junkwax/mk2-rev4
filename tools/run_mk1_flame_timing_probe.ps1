param(
    # Private-name copy so this cannot kill, or be killed by, an MK2 capture.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\MAME\roms",
    [string]$Resolution = "800x600",
    [int]$Step = 6,
    [int]$Trig = 12,
    [int]$Snaps = 200,
    [int]$SnapMin = 100,
    [switch]$NoSound
)

# INTERACTIVE probe - you drive it.  Measures MK1's own animation holds off
# the screen, because mk has no symbol map to force the fatality with.
#
#   1. Coin up, pick SCORPION, win a round.
#   2. At FINISH HIM: hold BLOCK at sweep distance, press UP, UP.
#   3. Let the burn finish, then close MAME.
#
# mk here is rev 5.0 T-Unit: same board, same 54.7068 Hz tick as MK2, so the
# frame counts it reports drop straight into our sleeps.

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "mk1_flame_timing_probe.lua"
$LogPath = Join-Path $ToolsDir "mk1_flame_timing.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\mk1_flame_timing\run_$RunId"
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Private cfg/nvram so this never touches the MK2 setup.  A committed
# cfg/mk2.cfg with the TEST switch on has bitten runs here before.
$Private = Join-Path $ToolsDir "mk1probe_state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

$env:MK2_ROOT    = Split-Path -Parent $ToolsDir
$env:MK1P_LOG    = $LogPath
$env:MK1P_STEP    = [string]$Step
$env:MK1P_TRIG    = [string]$Trig
$env:MK1P_SNAPMIN = [string]$SnapMin
$env:MK1P_SNAPS  = [string]$Snaps
$env:MK1P_SNAPDIR = $SnapDir.Replace("\","/")

$mameArgs = @(
    "-rompath", $RomPath, "mk",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-cfg_directory",   (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-autoboot_script", $LuaScript
)
if ($NoSound) { $mameArgs += @("-sound", "none") }

Write-Host ""
Write-Host "  MK1 flame-timing probe - INTERACTIVE, you drive it." -ForegroundColor Cyan
Write-Host "    1. Coin up, pick SCORPION, win a round."
Write-Host "    2. FINISH HIM:  hold BLOCK at sweep distance, press UP, UP."
Write-Host "    3. Let the burn play out, then close MAME."
Write-Host ""

$MameOut = Join-Path $ToolsDir "mk1_flame_timing_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & $Mame @mameArgs 2>&1 | Out-File -FilePath $MameOut -Encoding utf8
    $ErrorActionPreference = $prev
} finally {
    Pop-Location
    foreach ($v in "MK1P_LOG","MK1P_STEP","MK1P_TRIG","MK1P_SNAPS","MK1P_SNAPMIN","MK1P_SNAPDIR") {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    $frames = Select-String -Path $LogPath -Pattern "^\[mk1p\] F " | Measure-Object
    $big    = Select-String -Path $LogPath -Pattern "<== BIG" | Measure-Object
    Write-Host ("[mk1p] {0} frames sampled, {1} with a big flame" -f $frames.Count, $big.Count)
    if ($big.Count -eq 0) {
        Write-Warning "[mk1p] no big-flame frames - the burn was probably not captured."
    }
} else {
    Write-Warning "[mk1p] no log written (see $MameOut)"
}
Write-Host "[mk1p] Log:       $LogPath"
Write-Host "[mk1p] Snapshots: $SnapDir"
