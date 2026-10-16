# run_jax_wave_slot_test.ps1 - a PLAYER-2 Jax's energy wave goes in player 2's
# projectile slot (jaxzappid, MAINEQU.ASM).  tools/jax_wave_slot_test.lua says
# what each half measures.
#
#   -Package      build a private ROM dir from the CURRENT link: makerom.py, then
#                 mamerom.py --output (never installs to C:\MAME), and copy
#                 src\mk2.map beside the zip.  Refuses if src\mk2.out changes
#                 while it packages - a peer relinked under you.
#   -Rom <dir>    run against a dir holding mk2.zip AND the mk2.map from the
#                 same link (default: the -Package dir).
#   -Negative     patch jax_zap_spawn back to retail IN MEMORY and keep the same
#                 expectations - the run must FAIL.  No second build.
#
# mame_jwsrig.exe is a byte copy of mame.exe under this rig's own name, and
# this rig KILLS NOTHING BY PROCESS NAME - a blanket Stop-Process takes a peer
# session's run with it and its log stops mid-run, which reads exactly like a
# broken ROM.
param(
    [string]$Mame = "C:\MAME\mame_jwsrig.exe",
    [string]$Rom = (Join-Path $env:TEMP "jws_rom"),
    [switch]$Package,
    [switch]$Negative,
    [switch]$Air,
    [int]$Delay = 0,
    [int]$Trials = 4,
    [switch]$Trace,
    [int]$BackstopEmuSeconds = 240
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "jax_wave_slot_test.lua"
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
    Write-Host "[jws] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[jws] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) {
    Write-Host "[jws] no mk2.map beside the zip in $Rom - refusing rather than reading src\mk2.map, which may belong to a different link"
    exit 2
}
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "jwsrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Tag = "$(if ($Air) { "air${Delay}_" })$(if ($Negative) { "neg" } else { "pos" })"
$Log = Join-Path $ToolsDir "jax_wave_slot_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT   = $Root.Replace("\", "/")
$env:JWS_LOG    = $Log
$env:JWS_MAP    = $Map
$env:JWS_NEG    = if ($Negative) { "1" } else { "0" }
$env:JWS_TRIALS = [string]$Trials
$env:JWS_TRACE  = if ($Trace) { "1" } else { "0" }
$env:JWS_AIR    = if ($Air) { "1" } else { "0" }
$env:JWS_DELAY  = [string]$Delay

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)

Write-Host "[jws] $(if ($Air) { 'AIR ' })$(if ($Negative) { 'NEGATIVE (retail patched in - must FAIL)' } else { 'positive' }) trials=$Trials : $Rom"
$Out = Join-Path $ToolsDir "jax_wave_slot_mame_$Tag.log"
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
Remove-Item Env:\JWS_LOG,Env:\JWS_MAP,Env:\JWS_NEG,Env:\JWS_TRIALS,Env:\JWS_TRACE,Env:\JWS_AIR,Env:\JWS_DELAY -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match '^\[jws\] (trial \d+( [AB]| FLIGHT|: NO VERDICT)|SUMMARY|fix present|NEGATIVE)' } | ForEach-Object { Write-Host $_ }
    $v = Select-String -Path $Log -Pattern '^\[jws\] (PASS|FAIL|NO VERDICT)' | Select-Object -Last 1
    if ($v) { Write-Host $v.Line } else { Write-Host "[jws] NO VERDICT - see $Log / $Out" }
} else { Write-Host "[jws] NO LOG - MAME never started; see $Out" }
