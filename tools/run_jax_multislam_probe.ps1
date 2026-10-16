# run_jax_multislam_probe.ps1 - Jax's multi-slam throw, slam by slam
# (tools/jax_multislam_probe.lua says what each number is).
#
# -Rom takes a DIRECTORY holding mk2.zip AND the mk2.map that belongs to it, so a
# gated build and its control can be compared without either reading the other's
# symbol addresses.
#
# mame_echrig.exe is a byte copy of mame.exe under a name of this rig's own, and
# this rig KILLS NOTHING BY PROCESS NAME - a blanket Stop-Process takes a peer
# session's run with it and the loser's log stops mid-run, which reads exactly
# like a broken ROM.
param(
    [string]$Mame = "C:\MAME\mame_echrig.exe",
    [Parameter(Mandatory = $true)][string]$Rom,
    [ValidateSet("jax","kang","cage","shang","raiden","kitana")] [string]$Char = "jax",
    [int]$Taps = 1,
    [int]$SeedHit = 0,
    [switch]$Jab,
    [ValidateSet("throw","noogy")] [string]$Move = "throw",
    [int]$BackstopEmuSeconds = 200
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "jax_multislam_probe.lua"

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[jms] no mk2.zip in $Rom"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[jms] no mk2.map beside the zip in $Rom - refusing rather than reading src/mk2.map, which belongs to a different link"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "echrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Log = Join-Path $ToolsDir "jax_multislam_${Move}_${Char}_t${Taps}_h${SeedHit}$(if ($Jab) { "_jab" }).log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT    = $Root.Replace("\", "/")
$env:JMS_LOG     = $Log
$env:JMS_MAP     = $Map
$env:JMS_TAPS    = [string]$Taps
$env:JMS_SEEDHIT = [string]$SeedHit
$env:JMS_CHAR    = $Char
$env:JMS_JAB     = if ($Jab) { "1" } else { "0" }
$env:JMS_MOVE    = $Move

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)

Write-Host "[jms] $Char taps=$Taps seedhit=$SeedHit : $Rom"
$Out = Join-Path $ToolsDir "jax_multislam_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $Out } finally {
    Pop-Location
    Remove-Item Env:\JMS_LOG,Env:\JMS_MAP,Env:\JMS_TAPS,Env:\JMS_SEEDHIT,Env:\JMS_CHAR,Env:\JMS_JAB,Env:\JMS_MOVE -ErrorAction SilentlyContinue
}

if (Test-Path $Log) {
    $v = Select-String -Path $Log -Pattern '^\[jms\] (PASS|FAIL)' | Select-Object -Last 1
    if ($v) { Write-Host $v.Line } else { Write-Host "[jms] NO VERDICT - see $Log / $Out" }
} else { Write-Host "[jms] NO LOG - MAME never started; see $Out" }
