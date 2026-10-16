param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$TimeoutSeconds = 240,
    [ValidateSet("left", "right")]
    [string]$Side = "left",
    # sz_headrip_reach in MKDEATH.ASM is 070h; the harness snaps to the same
    # number so the run measures the shipped separation.  Override to sweep it.
    [int]$FatalX = 92,
    # Victim ochar. 11=Jax 0=KungLao 1=LiuKang 2=Cage 3=Baraka 4=Kitana
    # 5=Mileena 6=Shang 7=Raiden 8=SubZero 9=Reptile 10=Scorpion
    # 12=Kintaro 13=Kahn 14=Smoke 15=Noob 16=Jade
    [int]$Victim = 11,
    # C:\MAME\ui.ini normally has skip_warnings=1, but MAME does sometimes park
    # on the bad-checksum warning screen anyway - and when it does the autoboot
    # script never runs at all.  If a run produces no log, re-run with
    # -WarningDismissCount 4.
    [int]$WarningDismissCount = 0,
    # Stand Sub-Zero on the WRONG side of the victim through Finish Him and put
    # him across just before the press, so he arrives at the fatality having had
    # to turn - what jumping over the opponent leaves behind.
    [switch]$CrossUp,
    # Mirror the head prop off Sub-Zero's facing once it exists.  The run MUST
    # then report ALIGN BAD - the control for the alignment check itself.
    [switch]$Negative,
    # Super-freeze the dizzy victim before the rip.  With -CrossUp this is
    # "freeze him, flip over him, rip": he cannot turn while he is ice.
    [switch]$Freeze,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "sz_headrip_test.lua"
$LogDir = Join-Path $ToolsDir "sz_headrip_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\sz_headrip"
$OutputRoot = Join-Path $ToolsDir "sz_headrip_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$tag = $(if ($CrossUp) { "${Side}cross" } else { $Side })
if ($Negative) { $tag = "${tag}neg" }
if ($Freeze) { $tag = "${tag}ice" }
$LogPath = Join-Path $LogDir "sz_headrip_${tag}_v$Victim.log"
$CsvPath = Join-Path $LogDir "sz_headrip_${tag}_v$Victim.csv"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Leftover CMOS credits from a run that exited mid-fight desync the scripted
# coin/start schedule, so this run needs a clean one - but it must be a
# PRIVATE one.  This used to delete C:\MAME\nvram\mk2, which is the
# cabinet the user plays: since `hidearn` (2026-10-05) that directory holds the
# EARNED hidden fighters (cmos adj slot 25) and the operator GAME ADJUSTMENTS,
# so every rig run threw their progress away.  Same rule as
# run_blockloss_test.ps1 and run_boss_exploit_test.ps1: private nvram, touch
# nothing shared.
$NvramDir = Join-Path $OutputRoot "nvram"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null

$saved = @{}
foreach ($name in @("MK2_ROOT", "SZHR_LOG", "SZHR_FRAME_LOG", "SZHR_STAGE", "SZHR_SIDE", "SZHR_FATAL_X", "SZHR_VICTIM", "SZHR_CROSS", "SZHR_NEG", "SZHR_FREEZE")) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}

$env:MK2_ROOT = $Root
$env:SZHR_LOG = $LogPath
$env:SZHR_FRAME_LOG = $CsvPath
$env:SZHR_STAGE = [string]$Stage
$env:SZHR_SIDE = $Side
$env:SZHR_FATAL_X = [string]$FatalX
$env:SZHR_VICTIM = [string]$Victim
$env:SZHR_CROSS = $(if ($CrossUp) { "1" } else { "0" })
$env:SZHR_NEG = $(if ($Negative) { "1" } else { "0" })
$env:SZHR_FREEZE = $(if ($Freeze) { "1" } else { "0" })

try {
    $runArgs = @{
        Mame = $Mame
        RomPath = $RomPath
        Machine = "mk2"
        Resolution = $Resolution
        Script = $LuaScript
        SnapshotDirectory = $RunSnapshots
        OutputDirectory = $RunOutput
        Video = "gdi"
        AutoCloseSeconds = $TimeoutSeconds
        WarningDismissCount = $WarningDismissCount
        Wait = $true
        ExtraArgs = @("-nvram_directory", $NvramDir)
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }

    Write-Host "[szhr] Sub-Zero MK1 head-rip test: Sub-Zero on the $Side, victim ochar=$Victim, reach=$FatalX..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) {
            Remove-Item ("Env:\" + $name) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

Write-Host "[szhr] Lua log:     $LogPath"
Write-Host "[szhr] Frame CSV:   $CsvPath"
Write-Host "[szhr] Screenshots: $RunSnapshots"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[szhr] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 50
}
