# run_kitana_kiss_blood_test.ps1 - Kitana's kiss of death bleeds (kissblood,
# MAINEQU.ASM).  tools/kitana_kiss_blood_test.lua says what is asserted.
#
#   -Package      private ROM dir from the CURRENT link (makerom.py, then
#                 mamerom.py --output, never installs) + src\mk2.map beside it.
#   -Rom <dir>    a dir holding mk2.zip AND the mk2.map from the same link.
#   -Negative     NOP the splash's create IN MEMORY - must FAIL.
#   -Victim       who gets kissed (subzero, kang, cage, ...)
#
# mame_kkbrig.exe is a byte copy of mame.exe under this rig's own name, and
# this rig KILLS NOTHING BY PROCESS NAME.
param(
    [string]$Mame = "C:\MAME\mame_kkbrig.exe",
    [string]$Rom = (Join-Path $env:TEMP "kkb_rom"),
    [switch]$Package,
    [switch]$Negative,
    [string]$Victim = "subzero",
    [int]$BackstopEmuSeconds = 150
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "kitana_kiss_blood_test.lua"
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
    Write-Host "[kkb] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[kkb] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[kkb] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "kkbrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Tag = "${Victim}_$(if ($Negative) { 'neg' } else { 'pos' })"
$Log = Join-Path $ToolsDir "kitana_kiss_blood_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT   = $Root.Replace("\", "/")
$env:KKB_LOG    = $Log
$env:KKB_MAP    = $Map
$env:KKB_NEG    = if ($Negative) { "1" } else { "0" }
$env:KKB_VICTIM = $Victim

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none", "-snapshot_directory", (Join-Path $ToolsDir "screens\kiss_blood\$Tag"),
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)

Write-Host "[kkb] $(if ($Negative) { 'NEGATIVE (splash NOPd - must FAIL)' } else { 'positive' }) victim=$Victim : $Rom"
$Out = Join-Path $ToolsDir "kitana_kiss_blood_mame_$Tag.log"
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
Remove-Item Env:\KKB_LOG,Env:\KKB_MAP,Env:\KKB_NEG,Env:\KKB_VICTIM -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match '\] (kiss blood|NEGATIVE|fatality|  \+|  pop|RESULT|PASS|FAIL)' } | ForEach-Object { Write-Host $_ }
} else { Write-Host "[kkb] NO LOG - MAME never started; see $Out" }
