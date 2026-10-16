# run_tower_feet_probe.ps1 - do THE TOWER's shadows meet the feet (shad_feet)?
# Drives tools/tower_feet_probe.lua.  -Char N = P1 ft_ id (16 = Jade).
# Built from run_stage_park_probe.ps1 (-Stops is unused).
#
#   -Package      private ROM dir from the CURRENT link (makerom.py, then
#                 mamerom.py --output, never installs) + src\mk2.map beside it.
#   -Rom <dir>    a dir holding mk2.zip AND the mk2.map from the same link.
#   -Stage N      curback (0 = THE DEAD POOL, 3 = THE TOWER)
#   -Stops "a,b"  world x to park both fighters at
#
# mame_spprig.exe is a byte copy of mame.exe under this rig's own name, and
# this rig KILLS NOTHING BY PROCESS NAME.
param(
    [string]$Mame = "C:\MAME\mame_spprig.exe",
    [string]$Rom = (Join-Path $env:TEMP "tfp_rom"),
    [switch]$Package,
    [int]$Stage = 3,
    [int]$Char = 16,
    [string]$Stops = "40,300,560,820,1090",
    [string]$Tag = "jade",
    [int]$BackstopEmuSeconds = 200
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "tower_feet_probe.lua"
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
    Write-Host "[spp] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[spp] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[spp] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "spprig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Snaps = Join-Path $ToolsDir "screens\tower_feet\$Tag"
New-Item -ItemType Directory -Force $Snaps | Out-Null
Get-ChildItem -Path $Snaps -Recurse -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
$Log = Join-Path $ToolsDir "tower_feet_probe_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:SPP_TAG = $Tag; $env:SPP_LOG = $Log; $env:SPP_MAP = $Map
$env:SPP_STAGE = "$Stage"; $env:SPP_STOPS = $Stops; $env:TFP_CHAR = "$Char"

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-snapshot_directory", $Snaps,
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)
Write-Host "[spp] stage $Stage stops $Stops : $Rom"
$Out = Join-Path $ToolsDir "tower_feet_probe_mame_$Tag.log"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput $Out `
    -RedirectStandardError  ($Out + ".err")

# The red ROM-warning box: the standalone PostMessage poker in its own process
# (run_suddeath_test.ps1), never SendKeys - this script never owns the foreground.
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
    Write-Host "[spp] parked on the ROM warning box - no lua log after 63s, killing our own MAME (pid $($proc.Id))"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
if ($poker -and -not $poker.HasExited) { Stop-Process -Id $poker.Id -Force -ErrorAction SilentlyContinue }
Remove-Item Env:\SPP_TAG,Env:\SPP_LOG,Env:\SPP_MAP,Env:\SPP_STAGE,Env:\SPP_STOPS -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match 'tfp|FATAL' } | ForEach-Object { Write-Host $_ }
    Write-Host "[spp] snapshots: $Snaps"
} else { Write-Host "[spp] NO LOG - MAME never started; see $Out" }
