# run_blockloss_test.ps1 - a player who was HOLDING BLOCK when the round was
# decided must still leave his guard (joy_block_loop now polls
# check_winner_status; see tools/blockloss_test.lua for what is measured).
#
# -Rom takes a directory holding mk2.zip AND the mk2.map that belongs to it, so
# the fixed and control builds can be compared without either one reading the
# other's symbol addresses.  One instruction in JOY.ASM shifts .text and .bss,
# so the two maps genuinely differ and a shared map reads plausible wrong values.
#
# mame_blktest.exe is a byte copy of mame.exe under a NAME OF THIS RIG'S OWN,
# and this rig KILLS NOTHING BY PROCESS NAME: several rigs in this tree default
# to mame_mk2test.exe and clean up by name, and the flybrain trainers run as
# plain mame.exe.  A blanket Stop-Process takes a peer session's run with it and
# the loser's log stops mid-sweep, which reads exactly like a broken ROM.
param(
    [string]$Mame = "C:\MAME\mame_blktest.exe",
    [Parameter(Mandatory = $true)][string]$Rom,
    [ValidateSet("held", "control", "both")][string]$Mode = "both",
    [int]$BackstopEmuSeconds = 200,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "blockloss_test.lua"

if (-not (Test-Path (Join-Path $Rom "mk2.zip"))) { Write-Host "[blk] no mk2.zip in $Rom"; exit 2 }
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "[blk] no mk2.map beside the zip in $Rom - refusing rather than reading src/mk2.map, which belongs to a different link"; exit 2 }

if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame -Force }

# A private nvram/cfg dir: the shared C:\MAME\nvram\mk2 and C:\MAME\cfg belong
# to whatever else is running, and the repo's own committed cfg/mk2.cfg has the
# TEST switch on (the game then sits in the operator menu and the rig measures
# nothing, which reads like the feature being broken).
$Priv = Join-Path $env:TEMP "blkrig"
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Priv "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Priv "nvram\mk2") -ErrorAction SilentlyContinue

$modes = if ($Mode -eq "both") { @("control", "held") } else { @($Mode) }
$overall = 0

foreach ($m in $modes) {
    $Log = Join-Path $ToolsDir "blockloss_$m.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root.Replace("\", "/")
    $env:BL_LOG = $Log
    $env:BL_MAP = $Map
    $env:BL_HOLD = if ($m -eq "held") { "1" } else { "0" }

    $mameArgs = @(
        "-rompath", $Rom, "mk2",
        "-window", "-nomaximize", "-resolution", "640x480",
        "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
        "-nvram_directory", (Join-Path $Priv "nvram"),
        "-cfg_directory", (Join-Path $Priv "cfg"),
        "-autoboot_script", $Lua,
        "-seconds_to_run", $BackstopEmuSeconds, "-nothrottle"
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[blk] $m : $Rom"
    $OutLog = Join-Path $ToolsDir "blockloss_${m}_mame.log"
    $ErrLog = Join-Path $ToolsDir "blockloss_${m}_mame.err"

    # Detached so there is a pid to hand the poker.  Source-built ROMs ALWAYS
    # trip MAME's red ROM-warning screen and it cannot be switched off in this
    # build, so without the poker the run ends with no log at all - which reads
    # like a broken ROM rather than like nothing having started.
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

    # Its own process, not SendKeys from here: this shell started MAME with
    # redirected stdio so it never owns the foreground and Windows refuses its
    # SetForegroundWindow - and an AppActivate here would steal focus from, and
    # type into, a peer session's MAME window.  See mame_dismiss_warning.ps1.
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
        "-ProcessId", $proc.Id, "-ReadyFile", $Log, "-TimeoutSec", 40) | Out-Null

    try {
        $proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
        if (-not $proc.HasExited) {
            Write-Host "[blk] backstop hit - stopping this run only (pid $($proc.Id))"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    } finally {
        foreach ($v in @("MK2_ROOT", "BL_LOG", "BL_MAP", "BL_HOLD")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $Log) {
        Get-Content $Log | Select-Object -Last 30
        $v = Select-String -Path $Log -Pattern '^\[blk\] (PASS|FAIL|only )' | Select-Object -Last 1
        if (-not $v) { Write-Host "[blk] $m : NO VERDICT - see $OutLog"; $overall = 2 }
        elseif ($v.Line -notmatch 'PASS') { Write-Host "[blk] $m : FAIL"; if ($overall -eq 0) { $overall = 1 } }
    } else {
        Write-Host "[blk] $m : NO LOG - MAME never started; see $OutLog"
        $overall = 2
    }
    Write-Host ""
}

exit $overall
