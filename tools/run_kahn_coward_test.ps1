# run_kahn_coward_test.ps1 - Shao Kahn says "RUN, COWARD" POINTING, and never
# into a live fireball (kahn_coward_talk / kahn_coward_note, MKBOSS.ASM).
# tools/kahn_coward_test.lua says what each mode measures.
#
#   -Package      build a private ROM dir from the CURRENT link: makerom.py, then
#                 mamerom.py --output (never installs to C:\MAME), and copy
#                 src\mk2.map beside the zip.  Refuses if src\mk2.out changes
#                 while it packages - a peer relinked under you.
#   -Rom <dir>    a dir holding mk2.zip AND the mk2.map from the same link
#                 (default: the -Package dir).
#   -Mode         flee | zone | behind | all   (behind is the gate's control)
#   -Watch        real speed WITH SOUND, to see and hear it (default is
#                 -nothrottle, silent).  Same assertions either way.
#
# mame_cowrig.exe is a byte copy of mame.exe under this rig's own name, and this
# rig KILLS NOTHING BY PROCESS NAME - only the pid it started.
param(
    [string]$Mame = "C:\MAME\mame_cowrig.exe",
    [string]$Rom = (Join-Path $env:TEMP "cow_rom"),
    [switch]$Package,
    [ValidateSet("flee", "zone", "behind", "all")][string]$Mode = "all",
    [int]$Trials = 3,
    [switch]$Watch,
    [int]$BackstopEmuSeconds = 360
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "kahn_coward_test.lua"
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
    Write-Host "[cow] packaged $Rom from the current link"
}

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[cow] no mk2.zip in $Rom - pass -Package"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[cow] no mk2.map beside the zip in $Rom - refusing"; exit 2 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

# Private nvram/cfg: the shared ones belong to whatever else is running, and the
# repo's committed cfg has the TEST switch on.
$Priv = Join-Path $env:TEMP "cowrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null

$modes = if ($Mode -eq "all") { @("behind", "flee", "zone") } else { @($Mode) }
$overall = 0

foreach ($m in $modes) {
    Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue
    $Log = Join-Path $ToolsDir "kahn_coward_$m.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root.Replace("\", "/")
    $env:CW_LOG = $Log
    $env:CW_MAP = $Map
    $env:CW_MODE = $m
    $env:CW_TRIALS = "$Trials"

    $mameArgs = @(
        "-rompath", $Rom, "mk2",
        "-window", "-nomaximize", "-resolution", "640x480",
        "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
        "-nvram_directory", (Join-Path $Priv "nvram"),
        "-cfg_directory", (Join-Path $Priv "cfg"),
        "-autoboot_script", $Lua,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Watch) { $mameArgs += @("-nothrottle", "-sound", "none") }
    $OutLog = Join-Path $ToolsDir "kahn_coward_${m}_mame.log"
    $ErrLog = Join-Path $ToolsDir "kahn_coward_${m}_mame.err"
    Write-Host "[cow] $m : $Rom"

    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

    # Source-built ROMs always trip MAME's red ROM-warning box; dismiss it with
    # PostMessage from its own process, never SendKeys from here.
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
        "-ProcessId", $proc.Id, "-ReadyFile", $Log, "-TimeoutSec", 40) | Out-Null

    try {
        # 63s with no Lua log at all = parked on the warning box, not a verdict
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            if (-not (Test-Path $Log) -and $sw.Elapsed.TotalSeconds -gt 63) {
                Write-Host "[cow] no lua log after 63s - stopping pid $($proc.Id)"
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; break
            }
            if ($sw.Elapsed.TotalSeconds -gt ($BackstopEmuSeconds + 90)) {
                Write-Host "[cow] backstop - stopping pid $($proc.Id)"
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; break
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        foreach ($v in @("MK2_ROOT", "CW_LOG", "CW_MAP", "CW_MODE", "CW_TRIALS")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $Log) {
        Get-Content $Log | Select-String -Pattern 'trial|PASS|FAIL|FATAL|NO VERDICT|backstop|MISSING' | Select-Object -Last 20 | ForEach-Object { $_.Line }
        $v = Select-String -Path $Log -Pattern '^\[cow\] (PASS|FAIL)' | Select-Object -Last 1
        if (-not $v) { Write-Host "[cow] $m : NO VERDICT - see $OutLog"; if ($overall -eq 0) { $overall = 2 } }
        elseif ($v.Line -notmatch '^\[cow\] PASS') { Write-Host "[cow] $m : FAIL"; $overall = 1 }
        else { Write-Host "[cow] $m : PASS" }
    } else {
        Write-Host "[cow] $m : NO LOG - MAME never started; see $OutLog"
        if ($overall -eq 0) { $overall = 2 }
    }
    Write-Host ""
}
exit $overall
