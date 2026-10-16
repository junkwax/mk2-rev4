param(
    # Private-name copy so this cannot kill, or be killed by, an MK2 capture.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\MAME\roms"
)

# AUTOMATIC capture of MK1's THE WARRIOR SHRINE (MAME `mk`, rev 5.0 T-unit):
# the stage as MK1 draws it at the start camera and both scroll limits.  No
# input needed.  The reference for MK2's import (doc/MK1_WARRIOR_SHRINE.md).
#
# Output: tools\screens\mk1_shrine\run_<id>\ - start_*.png, right_*.png,
# left_*.png, capture.log.

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "mk1_shrine_capture.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $ToolsDir "screens\mk1_shrine\run_$RunId"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Private cfg/nvram shared with the other MK1 rigs, never the MK2 setup.
$Private = Join-Path $ToolsDir "mk1probe_state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

$env:MK1S_OUT = $OutDir.Replace("\", "/")

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

Write-Host "[mk1-shrine] $Mame -> $OutDir"
Push-Location $OutDir
try {
    & $Mame @mameArgs *> (Join-Path $OutDir "mame_out.log")
} finally {
    Pop-Location
}

$log = Join-Path $OutDir "capture.log"
if (-not (Test-Path $log)) { throw "no capture.log - the Lua never loaded; see mame_out.log" }
Get-Content $log | Select-String "FIGHT|start_|right_|left_|PASS|ERROR" | ForEach-Object { Write-Host "  $_" }
if (-not (Select-String -Path $log -Pattern "PASS" -Quiet)) { throw "capture did not complete" }
Write-Host "[mk1-shrine] $OutDir"
