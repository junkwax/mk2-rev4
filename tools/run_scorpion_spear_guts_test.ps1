# run_scorpion_spear_guts_test.ps1 - guts from Scorpion's spear wound (spearguts,
# MAINEQU.ASM).  tools/scorpion_spear_guts_test.lua says what is asserted.
#
#   -Package      private ROM dir from the CURRENT link (makerom.py, then
#                 mamerom.py --output, never installs) + src\mk2.map beside it.
#   -Rom <dir>    a dir holding mk2.zip AND the mk2.map from the same link.
#   -Negative     cut the tail's lane to GUTS7 IN MEMORY - must FAIL.
#   -Victim       who gets speared (subzero, kang, cage, ...)
#
# mame_ssgrig.exe is a byte copy of mame.exe under this rig's own name, and
# this rig KILLS NOTHING BY PROCESS NAME.
param(
    [string]$Mame = "C:\MAME\mame_ssgrig.exe",
    [string]$Rom = (Join-Path $env:TEMP "ssg_rom"),
    [switch]$Package,
    [switch]$Negative,
    [string]$Victim = "subzero",
    [int]$Trials = 3,
    [int]$BackstopEmuSeconds = 150
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "scorpion_spear_guts_test.lua"
$LinkOut = Join-Path $Root "src\mk2.out"

if ($Package) {
    New-Item -ItemType Directory -Force $Rom | Out-Null
    $before = (Get-Item $LinkOut).LastWriteTimeUtc
    Push-Location $Root
    try {
        & python makerom.py | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "makerom.py failed" }
        & python mamerom.py --source-video --no-install --output (Join-Path $Rom "mk2.zip") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "mamerom.py failed" }
        Copy-Item (Join-Path $Root "src\mk2.map") (Join-Path $Rom "mk2.map") -Force
    } finally { Pop-Location }
    if ((Get-Item $LinkOut).LastWriteTimeUtc -ne $before) {
        throw "src\mk2.out changed while packaging - a peer relinked under you. Run -Package again."
    }
    Write-Host "[ssg] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[ssg] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[ssg] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "ssgrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Tag = "${Victim}_$(if ($Negative) { 'neg' } else { 'pos' })"
$Log = Join-Path $ToolsDir "scorpion_spear_guts_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT   = $Root.Replace("\", "/")
$env:SSG_LOG    = $Log
$env:SSG_MAP    = $Map
$env:SSG_NEG    = if ($Negative) { "1" } else { "0" }
$env:SSG_VICTIM = $Victim
$env:SSG_TRIALS = [string]$Trials

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none", "-snapshot_directory", (Join-Path $ToolsDir "screens\spear_guts\$Tag"),
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)

Write-Host "[ssg] $(if ($Negative) { 'NEGATIVE (lane cut to GUTS7 - must FAIL)' } else { 'positive' }) victim=$Victim : $Rom"
$Out = Join-Path $ToolsDir "scorpion_spear_guts_mame_$Tag.log"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $Out `
    -RedirectStandardError  ($Out + ".err")

# POKE PAST THE RED ROM-WARNING BOX, the house way (run_suddeath_test.ps1): a
# source build never matches MAME's SHA1 table, so that box is posted on EVERY
# launch and only a key press clears it.  It has to be the standalone
# PostMessage poker in its own process - this script starts MAME with
# redirected output and never owns the foreground.  This rig was first written
# from run_jax_multislam_probe.ps1, which calls MAME directly with no poker,
# and a run parked on the box in front of the user (2026-10-04).
$poker = Start-Process -FilePath "powershell" -PassThru -WindowStyle Hidden `
    -ArgumentList @("-ExecutionPolicy","Bypass","-File",
                    (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
                    "-ProcessId",$proc.Id,"-ReadyFile",$Log,"-TimeoutSec",180)

# Do not wait the backstop out if it never starts: no lua log inside the grace
# window means the box was never cleared.  Kill OUR process by id and say so.
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) { break }
    if (Test-Path $Log) { break }
}
if (-not $proc.HasExited -and -not (Test-Path $Log)) {
    Write-Host "[rig] parked on the ROM warning box - no lua log after 63s, killing our own MAME (pid $($proc.Id))"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
if ($poker -and -not $poker.HasExited) { Stop-Process -Id $poker.Id -Force -ErrorAction SilentlyContinue }
Remove-Item Env:\SSG_LOG,Env:\SSG_MAP,Env:\SSG_NEG,Env:\SSG_VICTIM,Env:\SSG_TRIALS -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match '] (guts tail|NEGATIVE|  pull|  GUTS|  trial|RESULT|PASS|FAIL)' } | ForEach-Object { Write-Host $_ }
} else { Write-Host "[ssg] NO LOG - MAME never started; see $Out" }
