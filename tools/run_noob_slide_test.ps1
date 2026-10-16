param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs; on pwsh 7.3+ that alone would be promoted to a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "noob_slide_test.lua"
$LogPath = Join-Path $ToolsDir "noob_slide_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\noob_slide\run_$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:NOOB_SLIDE_LOG = $LogPath

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", 200
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[slide] launching Noob Saibot slide test..."
Push-Location (Split-Path -Parent $Mame)
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs *> (Join-Path $ToolsDir "noob_slide_mame_out.log")
    $ErrorActionPreference = $prev
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:NOOB_SLIDE_LOG -ErrorAction SilentlyContinue
}

Write-Host "[slide] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[slide] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath -Tail 24

# The field report proves the move fires, moves NOOB and connects, and that the
# frames he shows are NJSLIDE and not Scorpion's spear pose. It does not prove
# the palette - look at the snapshot.
if (-not (Select-String -Path $LogPath -Pattern "\[slide\] PASS" -Quiet)) {
    Write-Error "[slide] FAILED - see the field report above"
    exit 1
}
Write-Host "[slide] PASSED" -ForegroundColor Green
