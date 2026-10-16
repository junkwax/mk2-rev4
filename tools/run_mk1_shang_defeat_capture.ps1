param(
    # Private-name copy so this cannot kill, or be killed by, an MK2 capture.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\MAME\roms",
    [int]$Frames = 620,
    [switch]$NoExtract
)

# AUTOMATIC capture of MK1's "Shang Tsung defeated - the souls escape"
# sequence (MAME `mk`, rev 5.0 T-unit).  No input needed: the Lua forces the
# ladder to Shang, pins P1's health and wins both rounds itself.  Takes ~2
# minutes unthrottled.  See doc/MK1_SHANG_SOUL_ESCAPE.md.
#
# Output: tools\screens\mk1_shang_defeat\run_<id>\ - cap_*.png (one per frame
# from gstate 0Bh), blits.log, cram.bin, capture.log.  Then runs
# tools\mk1_shang_souls_extract.py --capture on it (skip with -NoExtract).

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "mk1_shang_defeat_capture.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $ToolsDir "screens\mk1_shang_defeat\run_$RunId"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Private cfg/nvram so this never touches the MK2 setup (a committed
# cfg/mk2.cfg with the TEST switch on has bitten runs here before).  Shared
# with run_mk1_flame_timing_probe.ps1 - both are MK1.
$Private = Join-Path $ToolsDir "mk1probe_state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

$env:MK1S_OUT = $OutDir.Replace("\", "/")
$env:MK1S_FRAMES = [string]$Frames

$mameArgs = @(
    "mk", "-rompath", $RomPath,
    "-video", "none", "-sound", "none", "-nothrottle",
    "-skip_gameinfo",
    "-snapshot_directory", $OutDir,
    "-cfg_directory",   (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", "900"
)

Write-Host "[mk1-shang] $Mame -> $OutDir"
Push-Location $OutDir
try {
    & $Mame @mameArgs *> (Join-Path $OutDir "mame_out.log")
} finally {
    Pop-Location
}

$log = Join-Path $OutDir "capture.log"
if (-not (Test-Path $log)) { throw "no capture.log - the Lua never loaded; see mame_out.log" }
Get-Content $log | Select-String "Shang picked|DEFEATED|PASS|ERROR|FAILED" | ForEach-Object { Write-Host "  $_" }
if (-not (Select-String -Path $log -Pattern "PASS" -Quiet)) { throw "capture did not complete" }

if (-not $NoExtract) {
    # the soul matching P1's own fighter wears the mirror-match palette in-game
    $extra = @()
    $m = Select-String -Path $log -Pattern "P1 ochar (\d+)" | Select-Object -First 1
    if ($m) { $extra = @("--player", $m.Matches[0].Groups[1].Value) }
    python (Join-Path $ToolsDir "mk1_shang_souls_extract.py") --capture $OutDir @extra
}
