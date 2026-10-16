param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Gap = 300,
    [switch]$NoSnap
)

$ErrorActionPreference = "Stop"
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$Log = Join-Path $ToolsDir "kahn_clap_box_probe.log"
$SnapshotDir = Join-Path $ToolsDir "screens\kahn_clap_box\$RunId"
$OutputDir = Join-Path $ToolsDir "kahn_clap_box_out\$RunId"
New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path (Split-Path -Parent $Mame) "nvram\mk2") -ErrorAction SilentlyContinue

$env:MK2_BOX_ROOT = $Root
$env:MK2_BOX_LOG = $Log
$env:MK2_BOX_GAP = [string]$Gap
$env:MK2_BOX_SNAP = if ($NoSnap) { "0" } else { "1" }

$runArgs = @{
    Mame = $Mame; RomPath = $RomPath; Machine = "mk2"; Resolution = $Resolution
    Script = (Join-Path $ToolsDir "kahn_clap_box_probe.lua")
    SnapshotDirectory = $SnapshotDir; OutputDirectory = $OutputDir
    Video = "gdi"; Wait = $true; NoSound = $true
    WarningDismissCount = 1; ReadyFile = $Log
}
& (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs

Remove-Item Env:\MK2_BOX_ROOT, Env:\MK2_BOX_LOG, Env:\MK2_BOX_GAP, Env:\MK2_BOX_SNAP -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $Log)) { throw "[box] no log at $Log" }
Write-Host ""
Get-Content -LiteralPath $Log | Where-Object { $_ -match "art |frames measured|ERROR" }
Write-Host ""
Write-Host "[box] log:       $Log"
Write-Host "[box] snapshots: $SnapshotDir"
