# run_ermac_chain_probe.ps1 - MEASURE Ermac's teleport -> telekinetic-slam
# chain (tools/ermac_chain_probe.lua says what each number is).
#
# -Rom takes a DIRECTORY holding mk2.zip AND the mk2.map that belongs to it, so
# a gated build and its control can be compared without either reading the
# other's symbol addresses, and so another session installing over
# C:\MAME\roms\mk2.zip cannot change what this run is measuring.
#
# mame_echrig.exe is a byte copy of mame.exe under a NAME OF THIS RIG'S OWN, and
# this rig KILLS NOTHING BY PROCESS NAME: several rigs here default to
# mame_mk2test.exe and clean up by name, and the flybrain trainers run as plain
# mame.exe.  A blanket Stop-Process takes a peer session's run with it, and the
# loser's log stops mid-run, which reads exactly like a broken ROM.
param(
    [string]$Mame = "C:\MAME\mame_echrig.exe",
    [Parameter(Mandatory = $true)][string]$Rom,
    [ValidateSet("chain","slamonly","teleonly","block","scale","cap","combo","cool")] [string]$Mode = "chain",
    [int]$Seed = 0,
    [int]$Cycles = 12,
    [int]$BackstopEmuSeconds = 220,
    [switch]$NoTrace
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "ermac_chain_probe.lua"

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[ech] no mk2.zip in $Rom"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[ech] no mk2.map beside the zip in $Rom - refusing rather than reading src/mk2.map, which belongs to a different link"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "echrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Log = if ($Mode -eq "scale" -or $Mode -eq "cap") { Join-Path $ToolsDir "ermac_chain_${Mode}$Seed.log" }
       else { Join-Path $ToolsDir "ermac_chain_$Mode.log" }
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT   = $Root.Replace("\", "/")
$env:ECH_LOG    = $Log
$env:ECH_MAP    = $Map
$env:ECH_MODE   = $Mode
$env:ECH_CYCLES = [string]$Cycles
$env:ECH_TRACE  = if ($NoTrace) { "0" } else { "1" }
$env:ECH_SEED   = [string]$Seed

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)

Write-Host "[ech] $Mode$(if ($Mode -eq 'scale') { " seed=$Seed" }) : $Rom"
$Out = Join-Path $ToolsDir "ermac_chain_${Mode}_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $Out } finally {
    Pop-Location
    Remove-Item Env:\ECH_LOG,Env:\ECH_MAP,Env:\ECH_MODE,Env:\ECH_CYCLES,Env:\ECH_TRACE,Env:\ECH_SEED -ErrorAction SilentlyContinue
}

if (Test-Path $Log) {
    $v = Select-String -Path $Log -Pattern '^\[ech\] (PASS|FAIL)' | Select-Object -Last 1
    if ($v) { Write-Host $v.Line } else { Write-Host "[ech] NO VERDICT - see $Log / $Out" }
} else { Write-Host "[ech] NO LOG - MAME never started; see $Out" }
