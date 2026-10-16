param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,
    # Snapshot the super roundhouse's flight into tmp/rain_rh/ (every 3rd frame).
    [switch]$Snap,
    # Force a stage (curback id): 3 = THE TOWER.  -1 = whatever the game picks.
    [int]$Stage = -1,
    # The mk2.map that belongs to -RomPath's zip.  Given = a frozen pair, so the
    # live-tree staleness check below is skipped (it compares the wrong files).
    [string]$Map = "",
    # Log every palette-slot change through the bolt (RAIN_RH_PALDUMP).
    [switch]$PalDump,
    # Clear the victim's shadow flag through the bolt (RAIN_RH_NOSHADOW).
    [switch]$NoShadow,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "rain_roundhouse_test.lua"
$LogPath = Join-Path $ToolsDir "rain_roundhouse_test.log"
$SnapDir = Join-Path $Root "tmp\rain_rh"

# A rig reads symbol addresses out of the CURRENT src/mk2.map; a zip from
# another build reads every one of them at the wrong address.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[rain-rh] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
if ($Snap) {
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Get-ChildItem $SnapDir -Filter *.png -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
}

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:RAIN_RH_LOG = $LogPath
$env:RAIN_RH_SNAP = if ($Snap) { "1" } else { "0" }
$env:RAIN_RH_NOSHADOW = if ($NoShadow) { "1" } else { "0" }
$env:RAIN_RH_PALDUMP = if ($PalDump) { "1" } else { "0" }
if ($Map) { $env:RAIN_RH_MAP = $Map } else { Remove-Item Env:\RAIN_RH_MAP -ErrorAction SilentlyContinue }
if ($Stage -ge 0) { $env:RAIN_RH_STAGE = [string]$Stage } else { Remove-Item Env:\RAIN_RH_STAGE -ErrorAction SilentlyContinue }

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

Write-Host "[rain-rh] Rain: super roundhouse (super / whiff / plain) + lightning bolt (bolt / cool / dodge)"
$MameOutLog = Join-Path $ToolsDir "rain_roundhouse_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    foreach ($v in @("MK2_ROOT", "RAIN_RH_LOG", "RAIN_RH_SNAP", "RAIN_RH_STAGE", "RAIN_RH_MAP", "RAIN_RH_PALDUMP", "RAIN_RH_NOSHADOW")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 30
    $verdict = Select-String -Path $LogPath -Pattern '^\[rain-rh\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match 'PASS') { exit 0 }
    if (-not $verdict) { Write-Host "[rain-rh] NO VERDICT - see $MameOutLog" }
    exit 1
} else {
    Write-Host "[rain-rh] NO LOG - MAME never started; see $MameOutLog"
    exit 1
}
