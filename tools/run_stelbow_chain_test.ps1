param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 90,
    # Snapshot the chain into tmp/stelbow_chain/ (every other frame).
    [switch]$Snap,
    # Cross the expectation - every trial must FAIL.  The control for the
    # whole rig: elbo/cool are told to expect the chain and dual the plain
    # elbow, so a detector that answers the same way either way is caught.
    [switch]$Negative,
    # Force a stage (curback id).  -1 = whatever the game picks.
    [int]$Stage = -1,
    # The mk2.map that belongs to -RomPath's zip.  Given = a frozen pair, so
    # the live-tree staleness check below is skipped.
    [string]$Map = "",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "stelbow_chain_test.lua"
$LogPath = Join-Path $ToolsDir "stelbow_chain_test.log"
$SnapDir = Join-Path $Root "tmp\stelbow_chain"

# A rig reads symbol addresses out of the CURRENT src/mk2.map; a zip from
# another build reads every one of them at the wrong address and reports
# nothing wrong.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[stel] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# PRIVATE nvram/cfg - never C:\MAME\nvram\mk2, which holds the user's earned fighters.
$PrivNv = Join-Path $Root "tmp\stelbow_chain_nvram"
$PrivCfg = Join-Path $Root "tmp\stelbow_chain_cfg"
Remove-Item -LiteralPath $PrivNv -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $PrivNv, $PrivCfg | Out-Null
if ($Snap) {
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Get-ChildItem $SnapDir -Filter *.png -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
}

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:STEL_LOG = $LogPath
$env:STEL_SNAP = if ($Snap) { "1" } else { "0" }
$env:STEL_NEG = if ($Negative) { "1" } else { "0" }
if ($Map) { $env:STEL_MAP = $Map } else { Remove-Item Env:\STEL_MAP -ErrorAction SilentlyContinue }
if ($Stage -ge 0) { $env:STEL_STAGE = [string]$Stage } else { Remove-Item Env:\STEL_STAGE -ErrorAction SilentlyContinue }

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-nvram_directory", $PrivNv,
    "-cfg_directory", $PrivCfg,
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[stel] Shang Tsung: the elbow chain draws STELBO1,2 then 3,4,5 (elbo / dual / cool / spam)"
$MameOutLog = Join-Path $ToolsDir "stelbow_chain_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    foreach ($v in @("MK2_ROOT", "STEL_LOG", "STEL_SNAP", "STEL_NEG", "STEL_STAGE", "STEL_MAP")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 40
    $verdict = Select-String -Path $LogPath -Pattern '^\[stel\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match 'PASS') { exit 0 }
    if (-not $verdict) { Write-Host "[stel] NO VERDICT - see $MameOutLog" }
    exit 1
} else {
    Write-Host "[stel] NO LOG - MAME never started; see $MameOutLog"
    exit 1
}
