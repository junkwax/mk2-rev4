param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "300x200",
    [switch]$Debug,
    [string]$DebugScript = "",
    [switch]$Sound,
    [int]$MaxAttempts = 1
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BossMoveRunner = Join-Path $ToolsDir "run_kahn_boss_moves_test.ps1"

$commonArgs = @{
    Mame = $Mame
    RomPath = $RomPath
    Resolution = $Resolution
    MaxAttempts = $MaxAttempts
    UnlimitedHealth = $true
}

if ($Debug) {
    $commonArgs.Debug = $true
}
if ($DebugScript) {
    $commonArgs.DebugScript = $DebugScript
}
if ($Sound) {
    $commonArgs.Sound = $true
}

Write-Host "[kahn-jump-fly-test] Running clean-fight jump probe..."
& $BossMoveRunner @commonArgs -Move jump

Write-Host "[kahn-jump-fly-test] Running clean-fight fly/knee probe..."
& $BossMoveRunner @commonArgs -Move fly

Write-Host "[kahn-jump-fly-test] Jump and fly/knee probes passed with unlimited health."
