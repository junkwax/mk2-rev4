param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "300x225",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "scorpion_startcoin_aura_test.lua"
$LuaLog = Join-Path $ToolsDir "scorpion_startcoin_aura_test.log"
$SnapshotDir = Join-Path $ToolsDir "screens\scorpion_startcoin_aura"
$OutputDir = Join-Path $ToolsDir "scorpion_startcoin_aura_test_out"

Remove-Item -LiteralPath $LuaLog -Force -ErrorAction SilentlyContinue

$runArgs = @{
    Mame = $Mame
    RomPath = $RomPath
    Machine = "mk2"
    Resolution = $Resolution
    Script = $LuaScript
    SnapshotDirectory = $SnapshotDir
    OutputDirectory = $OutputDir
    Video = "gdi"
    Wait = $true
}

if (-not $Sound) {
    $runArgs.NoSound = $true
}

& (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs

Write-Host "[scorp-aura] Lua log: $Root\tools\scorpion_startcoin_aura_test.log"
Write-Host "[scorp-aura] Screenshots: $SnapshotDir"
Write-Host "[scorp-aura] MAME output: $OutputDir"
