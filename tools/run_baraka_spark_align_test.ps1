param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,
    [ValidateSet("down", "up", "none")]
    [string]$Aim = "down",
    [int]$ForceDy = 0,
    [int]$Range = 250,
    [int]$BurstBack = 0,
    [switch]$Mirror,
    [switch]$ColBox,
    [switch]$EmulateOld,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "baraka_spark_align_test.lua"
$LogPath = Join-Path $ToolsDir "baraka_spark_align_test.log"
$SnapshotRoot = Join-Path $ToolsDir "screens\baraka_spark_align"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$Tag = if ($ColBox) { "$Aim`_colbox" } elseif ($EmulateOld) { "$Aim`_OLD" } elseif ($Mirror) { "$Aim`_mirror" } elseif ($BurstBack -ne 0) { "$Aim`_back$BurstBack" } else { $Aim }
$RunSnapshots = Join-Path $SnapshotRoot "run_${RunId}_$Tag"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Boot determinism: leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:SPARK_ALIGN_LOG = $LogPath
$env:SPARK_AIM = $Aim
$env:SPARK_FORCE_DY = [string]$ForceDy
$env:SPARK_RANGE = [string]$Range
$env:SPARK_BURST_BACK = [string]$BurstBack
if ($ColBox) { $env:SPARK_COLBOX = "1" } else { Remove-Item Env:\SPARK_COLBOX -ErrorAction SilentlyContinue }
if ($Mirror) { $env:SPARK_MIRROR = "1" } else { Remove-Item Env:\SPARK_MIRROR -ErrorAction SilentlyContinue }
if ($EmulateOld) { $env:SPARK_EMULATE_OLD = "1" } else { Remove-Item Env:\SPARK_EMULATE_OLD -ErrorAction SilentlyContinue }

# Direct blocking call: Start-Process mangles -autoboot_script under pwsh 7.
# The lua exits MAME itself; -seconds_to_run is a backstop.
$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[spark-align] Launching - aim=$Aim force_dy=$ForceDy range=$Range"
$MameOutLog = Join-Path $ToolsDir "baraka_spark_align_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    Remove-Item Env:\SPARK_ALIGN_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_AIM -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_FORCE_DY -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_RANGE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_EMULATE_OLD -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_BURST_BACK -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_MIRROR -ErrorAction SilentlyContinue
    Remove-Item Env:\SPARK_COLBOX -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Write-Host "[spark-align] Log tail:"
    Get-Content -Path $LogPath -Tail 40
    if (Select-String -Path $LogPath -Pattern "PASS reason=aligned" -Quiet) {
        Write-Host "[spark-align] >>> BURST IS CONTACT-ALIGNED"
    } elseif (Select-String -Path $LogPath -Pattern "FAIL reason=misaligned" -Quiet) {
        Write-Host "[spark-align] >>> BURST IS OFF THE CONTACT POINT"
    } else {
        Write-Warning "[spark-align] No clean verdict (setup/timeout?)."
    }
} else {
    Write-Error "[spark-align] Lua log was not created (see $MameOutLog)."
}

Write-Host "[spark-align] Log:       $LogPath"
Write-Host "[spark-align] Snapshots: $RunSnapshots"
