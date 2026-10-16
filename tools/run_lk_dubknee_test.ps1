# run_lk_dubknee_test.ps1 - LIU KANG'S DOUBLE KNEE: a pre-dialled knee stuns
# and the second knee SPIKES him into the floor (bounce in place); a plain,
# late or cooled-down knee is retail's launch.  See tools/lk_dubknee_test.lua.
#
# -Rom takes a directory holding mk2.zip AND the mk2.map that belongs to it.
# -Package builds that directory from the CURRENT link (makerom + a private
# mamerom --output, never installed) into tmp\lkdk_rom.
#
# Private nvram/cfg, mame_lkdktest.exe (a byte copy of mame.exe under this rig's
# own name), and it kills nothing by process name: the shared C:\MAME\nvram\mk2
# holds the player's hidden-fighter unlocks, and a blanket Stop-Process takes a
# peer session's run with it.
param(
    [string]$Mame = "C:\MAME\mame_lkdktest.exe",
    [string]$Rom = "",
    [switch]$Package,
    [int]$BackstopEmuSeconds = 150,
    [switch]$Snap,
    [int]$Stage = -1,
    # the victim's ochar (MAINEQU ft_*): 11 Jax (default), 4 Kitana, 3 Baraka ...
    [int]$Victim = 11,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "lk_dubknee_test.lua"
$Log = Join-Path $ToolsDir "lk_dubknee_test.log"
$SnapDir = Join-Path $Root "tmp\lk_dubknee"

if ($Package) {
    $Rom = Join-Path $Root "tmp\lkdk_rom"
    New-Item -ItemType Directory -Force $Rom | Out-Null
    # Other sessions relink this tree: take the map FIRST and refuse if the
    # link moves while packaging, or the zip and the map belong to two builds.
    $outItem = Get-Item (Join-Path $Root "src\mk2.out")
    $stamp = $outItem.LastWriteTimeUtc
    Copy-Item (Join-Path $Root "src\mk2.map") (Join-Path $Rom "mk2.map") -Force
    Push-Location $Root
    try {
        python makerom.py
        if ($LASTEXITCODE) { Write-Host "[lk-dk] makerom failed"; exit 2 }
        python mamerom.py --source-video --no-install --output (Join-Path $Rom "mk2.zip")
        if ($LASTEXITCODE) { Write-Host "[lk-dk] mamerom failed"; exit 2 }
    } finally { Pop-Location }
    if ((Get-Item (Join-Path $Root "src\mk2.out")).LastWriteTimeUtc -ne $stamp) {
        Write-Host "[lk-dk] src\mk2.out changed while packaging (another build?) - refusing"; exit 2
    }
}
$Rom = (Resolve-Path $Rom).Path
if (-not $Rom) { Write-Host "[lk-dk] give -Rom <dir with mk2.zip + mk2.map> or -Package"; exit 2 }
if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[lk-dk] no mk2.zip in $Rom"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[lk-dk] no mk2.map beside the zip in $Rom - refusing"; exit 2 }

if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

$Priv = Join-Path $env:TEMP "lkdkrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
if ($Snap) {
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Get-ChildItem $SnapDir -Filter *.png -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force
}

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:LKDK_LOG = $Log
$env:LKDK_MAP = $Map
$env:LKDK_VICTIM = [string]$Victim
$env:LKDK_SNAP = if ($Snap) { "1" } else { "0" }
if ($Stage -ge 0) { $env:LKDK_STAGE = [string]$Stage } else { Remove-Item Env:\LKDK_STAGE -ErrorAction SilentlyContinue }

$mameArgs = @(
    "-rompath", $Rom, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $Lua,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[lk-dk] dubk (spike) and the three launches (knee / late / cool) : $Rom"
$OutLog = Join-Path $ToolsDir "lk_dubknee_mame_out.log"
$ErrLog = Join-Path $ToolsDir "lk_dubknee_mame_err.log"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
# Source-built ROMs always trip MAME's red ROM-warning box; the poker posts the
# key to THIS pid's window only (see mame_dismiss_warning.ps1).
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
    "-ProcessId", $proc.Id, "-ReadyFile", $Log, "-TimeoutSec", 40) | Out-Null

try {
    $proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) {
        Write-Host "[lk-dk] backstop hit - stopping this run only (pid $($proc.Id))"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} finally {
    foreach ($v in @("MK2_ROOT", "LKDK_LOG", "LKDK_SNAP", "LKDK_STAGE", "LKDK_MAP", "LKDK_VICTIM")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $Log) {
    Get-Content $Log | Select-Object -Last 12
    $verdict = Select-String -Path $Log -Pattern '^\[lk-dk\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match 'PASS') { exit 0 }
    if (-not $verdict) { Write-Host "[lk-dk] NO VERDICT - see $OutLog"; exit 2 }
    exit 1
} else {
    Write-Host "[lk-dk] NO LOG - MAME never started; see $OutLog"
    exit 2
}
