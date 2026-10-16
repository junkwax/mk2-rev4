param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 240,
    [int]$VictimX = 310,           # world x the victim is pinned at
    [ValidateSet("left", "right")]
    [string]$Side = "right",       # which side the ATTACKER stands on
    [int]$Gap = 55,
    [int]$Observe = 260,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "deadpool_slime_fall_test.lua"
$LogPath = Join-Path $ToolsDir "deadpool_slime_fall_test.log"
$RunId = "vx${VictimX}_$Side" + "_" + (Get-Date -Format "yyyyMMdd_HHmmss")
$RunSnapshots = Join-Path (Join-Path $ToolsDir "screens\deadpool_slime_fall") "run_$RunId"

New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:DP_TEST_LOG = $LogPath
$env:DP_VX = [string]$VictimX
$env:DP_SIDE = $Side
$env:DP_GAP = [string]$Gap
$env:DP_OBSERVE = [string]$Observe

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

Write-Host "[dpslime] victim_x=$VictimX attacker_side=$Side gap=$Gap"
$MameOutLog = Join-Path $ToolsDir "deadpool_slime_fall_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    "DP_TEST_LOG", "DP_VX", "DP_SIDE", "DP_GAP", "DP_OBSERVE" | ForEach-Object {
        Remove-Item "Env:\$_" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content -Path $LogPath | Select-String -Pattern "RESULT " | ForEach-Object { Write-Host $_ }
    if (-not (Select-String -Path $LogPath -Pattern "RESULT " -Quiet)) {
        Write-Warning "[dpslime] no verdict - see $LogPath / $MameOutLog"
        Get-Content -Path $LogPath -Tail 30
    }
} else {
    Write-Error "[dpslime] lua log was not created (see $MameOutLog)."
}
Write-Host "[dpslime] Log:       $LogPath"
Write-Host "[dpslime] Snapshots: $RunSnapshots"
