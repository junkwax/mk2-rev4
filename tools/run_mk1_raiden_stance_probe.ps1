param(
    # Private-name copy so this cannot kill, or be killed by, an MK2 capture.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\MAME\roms",
    [int]$Frames = 4200,
    [int]$SnapEvery = 7,
    [int]$SnapMax = 40,
    # Cycle jumps / angle jumps / ducks / walks instead of standing idle.
    [switch]$Move
)

# Does MK1's Raiden crackle with electricity in his NORMAL STANCE?
#
# A static shape scan of mk.zip said no; calibrating that scan against MK2's
# own bolt records showed it only caught 12 of 102 of them, so it proved
# nothing.  This asks the running game: force a 1P game with Raiden, park him
# idle with both bars pinned, snapshot the stance and write-tap the DMA so
# every blit is recorded with its source address.
#
# Output: tools\screens\mk1_raiden_stance\run_<id>\
#   mk1_raiden_stance.log, mk1_raiden_blits.log, *.png

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "mk1_raiden_stance_probe.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$tag = if ($Move) { "_move" } else { "" }
$OutDir = Join-Path $ToolsDir "screens\mk1_raiden_stance\run_$RunId$tag"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Private cfg/nvram so this never touches the MK2 setup - shared with the
# other MK1 probes, both are MK1.
$Private = Join-Path $ToolsDir "mk1probe_state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

$env:MK1RD_OUT = ($OutDir.Replace("\", "/")) + "/"
$env:MK1RD_FRAMES = [string]$Frames
$env:MK1RD_SNAP_EVERY = [string]$SnapEvery
$env:MK1RD_SNAP_MAX = [string]$SnapMax
if ($Move) { $env:MK1RD_MOVE = "1" } else { Remove-Item Env:\MK1RD_MOVE -ErrorAction SilentlyContinue }

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

Write-Host "[mk1-raiden] $Mame -> $OutDir"
Push-Location $OutDir
try {
    & $Mame @mameArgs *> (Join-Path $OutDir "mame_out.log")
} finally {
    Pop-Location
    foreach ($v in @("MK1RD_OUT","MK1RD_FRAMES","MK1RD_SNAP_EVERY","MK1RD_SNAP_MAX","MK1RD_MOVE")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

$log = Join-Path $OutDir "mk1_raiden_stance.log"
if (-not (Test-Path $log)) { throw "no stance log - the Lua never loaded; see mame_out.log" }
Get-Content $log | Select-String "dma tap|select screen|FIGHT starts|done:" |
    ForEach-Object { Write-Host "  $_" }
Write-Host "[mk1-raiden] $OutDir"
