param(
    [ValidateSet("reptile", "kunglao", "noob")]
    [string]$Char = "reptile",
    # A THIRD executable name, not mame.exe and not mame_mk2test.exe.  Every rig
    # in this tree opens by killing its own MAME by NAME, so two captures that
    # share a name take each other down: the loser exits -1 mid-log, with no
    # error line, which reads exactly like the thing under test crashing.
    # mame_mk2test.exe is often already in use by another session, so this rig
    # gets its own byte copy and is created on demand.
    [string]$Mame = "C:\MAME\mame_rdive.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [switch]$Sound,
    # Dive while invisible: the dive must bring him back (MK2_DIVE_INVISO).
    [switch]$Inviso
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs; on pwsh 7.3+ that alone would be promoted to a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame }

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "reptile_divekick_test.lua"
$LogPath = Join-Path $ToolsDir "reptile_divekick_$Char.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\reptile_divekick\${Char}_$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# A PRIVATE nvram dir, not C:\MAME\nvram - leftover CMOS credits desync the
# scripted coin/start schedule, but wiping the shared one yanks CMOS out from
# under any other capture that happens to be running.
$NvramDir = Join-Path $ToolsDir "nvram_rdive"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null
# Only OUR instance, by name.
$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:REP_DIVE_LOG = $LogPath
$env:MK2_DIVE_CHAR = $Char
$env:MK2_DIVE_INVISO = if ($Inviso) { "1" } else { "0" }

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir,
    "-seconds_to_run", 240
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[rdive] launching $Char dive-kick test..."
Push-Location (Split-Path -Parent $Mame)
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs *> (Join-Path $ToolsDir "reptile_divekick_${Char}_mame_out.log")
    $ErrorActionPreference = $prev
} finally {
    Pop-Location
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:REP_DIVE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:MK2_DIVE_CHAR, Env:MK2_DIVE_INVISO -ErrorAction SilentlyContinue
}

Write-Host "[rdive] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[rdive] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath -Tail 24

# The field report proves the move fires, flies and launches its victim. It
# does NOT prove the art is right - the dive rides anitab1 01eh and a bad frame
# still reads as a clean PASS. Look at the snapshots.
if (-not (Select-String -Path $LogPath -Pattern "\[rdive\] PASS" -Quiet)) {
    Write-Error "[rdive] FAILED - see the field report above"
    exit 1
}
Write-Host "[rdive] PASSED ($Char) - now check the snapshots show the flip kick" -ForegroundColor Green
