# run_noob_curse_test.ps1 - the GHOST RING's payload: the man under Noob's ghost
# ring cannot hit, block or throw (nb_cursed / NGR_CURSE).  tools/noob_curse_test.lua
# says what each trial measures.
#
#   -Package      build a private ROM dir from the CURRENT link (makerom.py +
#                 mamerom.py --output, never installs) with src\mk2.map beside it.
#                 Refuses if src\mk2.out changes while it packages.
#   -Rom <dir>    run against a dir holding mk2.zip AND its own mk2.map.
#   -Negative     zero nb_cursed every frame - the cursed trials must FAIL.
#   -Only a,b     run only these trial kinds (hit,block,throw,dmg,cap,len,
#                 backfire,rise,slamblock).
#
# Private nvram/cfg (never C:\MAME\nvram\mk2 - that holds the earned-fighter
# unlocks), its own exe name, and it kills nothing by process name.
param(
    [string]$Mame = "C:\MAME\mame_ncrig.exe",
    [string]$Rom = (Join-Path $env:TEMP "nc_rom"),
    [switch]$Package,
    [switch]$Negative,
    [string]$Only = "",
    [int]$BackstopEmuSeconds = 700
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "noob_curse_test.lua"
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
    Write-Host "[nc] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[nc] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[nc] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "ncrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Tag = if ($Negative) { "neg" } else { "pos" }
$Log = Join-Path $ToolsDir "noob_curse_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:NC_LOG = $Log
$env:NC_MAP = $Map
$env:NC_NEG = if ($Negative) { "1" } else { "0" }
$env:NC_ONLY = $Only

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)

Write-Host "[nc] $(if ($Negative) { 'NEGATIVE (nb_cursed zeroed - must FAIL)' } else { 'positive' }) : $Rom"
$Out = Join-Path $ToolsDir "noob_curse_mame_$Tag.log"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $Out `
    -RedirectStandardError  ($Out + ".err")

# The red ROM-warning box is posted on every launch of a source build; the
# standalone PostMessage poker clears it (never AppActivate/SendKeys).
$poker = Start-Process -FilePath "powershell" -PassThru -WindowStyle Hidden `
    -ArgumentList @("-ExecutionPolicy","Bypass","-File",
                    (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
                    "-ProcessId",$proc.Id,"-ReadyFile",$Log,"-TimeoutSec",180)

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
Remove-Item Env:\NC_LOG,Env:\NC_MAP,Env:\NC_NEG,Env:\NC_ONLY -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match '^\[nc\] (trial|  ring|SUMMARY|mode|NO VERDICT)' } | ForEach-Object { Write-Host $_ }
    $v = Select-String -Path $Log -Pattern '^\[nc\] (PASS|FAIL|NO VERDICT) noob_curse' | Select-Object -Last 1
    if ($v) { Write-Host $v.Line } else { Write-Host "[nc] NO VERDICT - see $Log / $Out" }
} else { Write-Host "[nc] NO LOG - MAME never started; see $Out" }
