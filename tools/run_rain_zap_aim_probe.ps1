param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 150,
    # Snapshot the `far` throw into tmp/rain_zap/ (every 2nd frame).
    [switch]$Snap,
    # Force a stage (curback id).  -1 = whatever the game picks.
    [int]$Stage = -1,
    # The mk2.map that belongs to -RomPath's zip.  Given = a frozen pair, so the
    # live-tree staleness check below is skipped.
    [string]$Map = "",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "rain_zap_aim_probe.lua"
$LogPath = Join-Path $ToolsDir "rain_zap_aim_probe.log"
$SnapDir = Join-Path $Root "tmp\rain_zap"

# A rig reads symbol addresses out of the CURRENT src/mk2.map; a zip from
# another build reads every one of them at the wrong address.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[rza] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
if ($Snap) {
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Get-ChildItem $SnapDir -Filter *.png -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
}

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:RZA_LOG = $LogPath
$env:RAIN_ZAP_SNAP = if ($Snap) { "1" } else { "0" }
if ($Map) { $env:RZA_MAP = $Map } else { Remove-Item Env:\RZA_MAP -ErrorAction SilentlyContinue }
if ($Stage -ge 0) { $env:RAIN_ZAP_STAGE = [string]$Stage } else { Remove-Item Env:\RAIN_ZAP_STAGE -ErrorAction SilentlyContinue }

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

Write-Host "[rza] Rain: water move (far / close / still / nomo)"
$MameOutLog = Join-Path $ToolsDir "rain_zap_aim_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    foreach ($v in @("MK2_ROOT", "RZA_LOG", "RAIN_ZAP_SNAP", "RAIN_ZAP_STAGE", "RZA_MAP")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 40
    $verdict = Select-String -Path $LogPath -Pattern '^\[rza\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match 'PASS') { exit 0 }
    if (-not $verdict) { Write-Host "[rza] NO VERDICT - see $MameOutLog" }
    exit 1
} else {
    Write-Host "[rza] NO LOG - MAME never started; see $MameOutLog"
    exit 1
}
