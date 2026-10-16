param(
    [string]$Victim = "jax",
    [int]$Dist = 240,
    [ValidateSet("left","right")][string]$Side = "left",
    [string]$RomDir = "",
    [switch]$Package,
    [switch]$NoSnaps,
    [switch]$Sound,
    [int]$BackstopEmuSeconds = 240
)
# ERMAC'S TELEKINETIC HEAD RIP (MKERFAT.ASM) - F,B,F,F + LK in FINISH HIM.
# See tools/ermac_headrip_test.lua for what is judged.
#
# Everything is PRIVATE: its own MAME binary name (mame_erftest.exe, so it
# never kills or shares cfg with another rig), its own nvram (the user's
# C:\MAME\nvram\mk2 holds their earned fighters), its own cfg and snapshots.
# -Package builds a private zip + map from the current link into
# tmp/erf_rom and refuses if src/mk2.out moves under it.
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Work = Join-Path $Root "tmp\ermac_headrip"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

if (-not $RomDir) { $RomDir = Join-Path $Root "tmp\erf_rom" }
if ($Package) {
    New-Item -ItemType Directory -Force -Path $RomDir | Out-Null
    $out = Join-Path $Root "src\mk2.out"
    $before = (Get-Item $out).LastWriteTimeUtc
    Push-Location $Root
    try {
        & python makerom.py | Out-Host
        & python mamerom.py --source-video --no-install --output (Join-Path $RomDir "mk2.zip") | Out-Host
    } finally { Pop-Location }
    if ((Get-Item $out).LastWriteTimeUtc -ne $before) { throw "src/mk2.out changed while packaging - rerun" }
    Copy-Item (Join-Path $Root "src\mk2.map") (Join-Path $RomDir "mk2.map") -Force
}
if (-not (Test-Path (Join-Path $RomDir "mk2.zip"))) { throw "no mk2.zip in $RomDir - pass -Package" }

$Mame = "C:\MAME\mame_erftest.exe"
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame }

$LogPath = Join-Path $Work "ermac_headrip_test_$Victim.log"
$Nvram = Join-Path $Work "nvram"; $Cfg = Join-Path $Work "cfg"; $Snap = Join-Path $Work "snap_$Victim"
Remove-Item -LiteralPath $Nvram,$Cfg,$Snap -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Nvram,$Cfg,$Snap | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:ERF_LOG = $LogPath
$env:ERF_MAP = (Join-Path $RomDir "mk2.map")
$env:ERF_VICTIM = $Victim
$env:ERF_DIST = [string]$Dist
$env:ERF_SIDE = $Side
$env:ERF_SNAPS = $(if ($NoSnaps) { "0" } else { "1" })
$args2 = @("-rompath",$RomDir,"mk2","-window","-nomaximize","-resolution","640x480",
           "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
           "-cfg_directory",$Cfg,"-nvram_directory",$Nvram,"-snapshot_directory",$Snap,
           "-autoboot_script",(Join-Path $ToolsDir "ermac_headrip_test.lua"),
           "-seconds_to_run",$BackstopEmuSeconds)
if (-not $Sound) { $args2 += @("-sound","none") }
$Out = Join-Path $Work "mame_$Victim.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @args2 *> $Out } finally {
    Pop-Location
    Remove-Item Env:\MK2_ROOT,Env:\ERF_LOG,Env:\ERF_MAP,Env:\ERF_VICTIM,Env:\ERF_DIST,Env:\ERF_SIDE,Env:\ERF_SNAPS -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
    $v = Select-String -Path $LogPath -Pattern '^\[erf\] (PASS|FAIL)' | Select-Object -Last 1
    if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never started; see $Out" }
