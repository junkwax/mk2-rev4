# run_frosty_test.ps1 - the crowd "ooo" when somebody is frozen IN THE AIR
# (iceooo, MAINEQU.ASM).  tools/frosty_test.lua says what is asserted.
#
#   -Package      private ROM dir from the CURRENT link (makerom.py, then
#                 mamerom.py --output, never installs) + src\mk2.map beside it.
#   -Rom <dir>    a dir holding mk2.zip AND the mk2.map from the same link.
#   -Negative     disable the <= 8 guard IN MEMORY - must FAIL.
#
# mame_frorig.exe is a byte copy of mame.exe under this rig's own name, and
# this rig KILLS NOTHING BY PROCESS NAME.
param(
    [string]$Mame = "C:\MAME\mame_frorig.exe",
    [string]$Rom = (Join-Path $env:TEMP "fro_rom"),
    [switch]$Package,
    [switch]$Negative,
    [int]$BackstopEmuSeconds = 200
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "frosty_test.lua"
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
    Write-Host "[fro] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[fro] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[fro] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "frorig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$Tag = if ($Negative) { "neg" } else { "pos" }
$Log = Join-Path $ToolsDir "frosty_test_$Tag.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:FRO_LOG = $Log; $env:FRO_MAP = $Map; $env:FRO_NEG = if ($Negative) { "1" } else { "0" }

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
)
Write-Host "[fro] $(if ($Negative) { 'NEGATIVE (guard disabled - must FAIL)' } else { 'positive' }) : $Rom"
$Out = Join-Path $ToolsDir "frosty_test_mame_$Tag.log"
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
    Write-Host "[fro] parked on the ROM warning box - no lua log after 63s, killing our own MAME (pid $($proc.Id))"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
if ($poker -and -not $poker.HasExited) { Stop-Process -Id $poker.Id -Force -ErrorAction SilentlyContinue }
Remove-Item Env:\FRO_LOG,Env:\FRO_MAP,Env:\FRO_NEG -ErrorAction SilentlyContinue

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match 'RESULT|PASS|FAIL|NEGATIVE|FROZE|cmpi|words' } | ForEach-Object { Write-Host $_ }
} else { Write-Host "[fro] NO LOG - MAME never started; see $Out" }
