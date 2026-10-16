param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$TimeoutSeconds = 240,
    [ValidateSet("left", "right")]
    [string]$Side = "left",
    [int]$FatalX = 90,
    # Victim ochar. 0=KungLao 1=LiuKang 2=Cage 3=Baraka 4=Kitana 5=Mileena
    # 6=Shang 7=Raiden 8=SubZero 9=Reptile 10=Scorpion 11=Jax
    # 14=Smoke 15=Noob 16=Jade  (12/13 are bosses - not arm-rippable)
    [int]$Victim = 8,
    # C:\MAME\ui.ini normally has skip_warnings=1, but MAME does sometimes park
    # on the bad-checksum warning screen anyway - and when it does the autoboot
    # script never runs at all.  If a run produces no log, re-run with
    # -WarningDismissCount 4.
    [int]$WarningDismissCount = 0,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "jx_armrip_test.lua"
$LogDir = Join-Path $ToolsDir "jx_armrip_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\jx_armrip"
$OutputRoot = Join-Path $ToolsDir "jx_armrip_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "jx_armrip_${Side}_v$Victim.log"
$CsvPath = Join-Path $LogDir "jx_armrip_${Side}_v$Victim.csv"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Leftover CMOS credits from a run that exited mid-fight desync the scripted
# coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$saved = @{}
foreach ($name in @("MK2_ROOT", "JXAR_LOG", "JXAR_FRAME_LOG", "JXAR_STAGE", "JXAR_SIDE", "JXAR_FATAL_X", "JXAR_VICTIM")) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}

$env:MK2_ROOT = $Root
$env:JXAR_LOG = $LogPath
$env:JXAR_FRAME_LOG = $CsvPath
$env:JXAR_STAGE = [string]$Stage
$env:JXAR_SIDE = $Side
$env:JXAR_FATAL_X = [string]$FatalX
$env:JXAR_VICTIM = [string]$Victim

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
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }

    Write-Host "[jxar] Jax arm-rip test: Jax on the $Side, victim ochar=$Victim, stage=$Stage..."
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

Write-Host "[jxar] Lua log:     $LogPath"
Write-Host "[jxar] Frame CSV:   $CsvPath"
Write-Host "[jxar] Screenshots: $RunSnapshots"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[jxar] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 40
}
