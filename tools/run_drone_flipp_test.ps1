# run_drone_flipp_test.ps1 - the CPU's jump-in PUNCH (drnflipp, MAINEQU.ASM).
# tools/drone_flipp_test.lua says what is measured.
#
#   -Package      private ROM dir from the CURRENT link (makerom.py, then
#                 mamerom.py --output, never installs) + src\mk2.map beside it.
#   -Rom <dir>    a dir holding mk2.zip AND the mk2.map from the same link.
#   -Negative     zero rpt_flip_punch IN MEMORY: the same ROM must throw no
#                 punch.  The control, and the kick-only baseline.
#   -Char         the CPU's fighter (one with no air projectile, so every
#                 jump-in is a kick or a punch): scorpion cage baraka shang
#                 raiden kunglao liukang
#
# mame_dfprig.exe is a byte copy of mame.exe under this rig's own name, and
# this rig KILLS NOTHING BY PROCESS NAME.
param(
    [string]$Mame = "C:\MAME\mame_dfprig.exe",
    [string]$Rom = (Join-Path $env:TEMP "dfp_rom"),
    [switch]$Package,
    [switch]$Negative,
    [string]$Char = "scorpion",
    [int]$Diff = 9,
    [int]$Frames = 9000,
    [int]$BackstopEmuSeconds = 0,
    [int]$TraceAt = 0          # fight+N: instruction trace to the fault (adds -debug)
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "drone_flipp_test.lua"
$LinkOut = Join-Path $Root "src\mk2.out"
if ($BackstopEmuSeconds -le 0) { $BackstopEmuSeconds = [int]($Frames / 54) + 90 }

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
    Write-Host "[dfp] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[dfp] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[dfp] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "dfprig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Tag = "${Char}_d${Diff}_$(if ($Negative) { 'neg' } else { 'pos' })"
$Log = Join-Path $ToolsDir "drone_flipp_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT   = $Root.Replace("\", "/")
$env:DFP_LOG    = $Log
$env:DFP_MAP    = $Map
$env:DFP_NEG    = if ($Negative) { "1" } else { "0" }
$env:DFP_CHAR   = $Char
$env:DFP_DIFF   = [string]$Diff
$env:DFP_FRAMES = [string]$Frames

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)
if ($TraceAt -gt 0) {
    # MAME starts its debugger stopped: a one-line script lets it run, and the
    # lua turns the trace on at fight+TraceAt and off at the fault.
    $Go = Join-Path $Priv "go.ds"
    Set-Content -Path $Go -Value "go" -Encoding ascii
    $env:DFP_TRACE_AT = [string]$TraceAt
    $env:DFP_TRACE = (Join-Path $Root "tmp\dfp_trace.log").Replace("\", "/")
    Remove-Item -LiteralPath (Join-Path $Root "tmp\dfp_trace.log") -Force -ErrorAction SilentlyContinue
    $mameArgs += @("-debug", "-debugscript", $Go)
}

Write-Host "[dfp] $(if ($Negative) { 'NEGATIVE (odds zeroed - must throw no punch)' } else { 'positive' }) cpu=$Char diff=$Diff frames=$Frames : $Rom"
$Out = Join-Path $ToolsDir "drone_flipp_mame_$Tag.log"
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
Remove-Item Env:\DFP_TRACE_AT,Env:\DFP_TRACE,Env:\DFP_LOG,Env:\DFP_MAP,Env:\DFP_NEG,Env:\DFP_CHAR,Env:\DFP_DIFF,Env:\DFP_FRAMES -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match '^\[dfp\] (SUMMARY|HUMAN threw|gstate 2 ->|move present|NEGATIVE|PASS|FAIL|NO VERDICT)' } | ForEach-Object { Write-Host $_ }
} else { Write-Host "[dfp] NO LOG - MAME never started; see $Out" }
