param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\test",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$TimeoutSeconds = 240,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "st_decap_fatality_test.lua"
$LogDir = Join-Path $ToolsDir "st_decap_fatality_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\st_decap_fatality"
$OutputRoot = Join-Path $ToolsDir "st_decap_fatality_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "st_decap_fatality.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:ST_DECAP_LOG
$oldStage = $env:ST_DECAP_STAGE
$env:MK2_ROOT = $Root
$env:ST_DECAP_LOG = $LogPath
$env:ST_DECAP_STAGE = [string]$Stage

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
        Wait = $true
    }

    if (-not $Sound) {
        $runArgs.NoSound = $true
    }

    Write-Host "[st-decap] Launching Shang Tsung decap fatality test (P1 Shang HK hook)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) {
        Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MK2_ROOT = $oldRoot
    }
    if ($null -eq $oldLog) {
        Remove-Item Env:\ST_DECAP_LOG -ErrorAction SilentlyContinue
    } else {
        $env:ST_DECAP_LOG = $oldLog
    }
    if ($null -eq $oldStage) {
        Remove-Item Env:\ST_DECAP_STAGE -ErrorAction SilentlyContinue
    } else {
        $env:ST_DECAP_STAGE = $oldStage
    }
}

Write-Host "[st-decap] Lua log: $LogPath"
Write-Host "[st-decap] Screenshots: $RunSnapshots"
Write-Host "[st-decap] MAME output: $RunOutput"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[st-decap] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 60
} else {
    throw "[st-decap] Lua log was not created"
}

$text = Get-Content -LiteralPath $LogPath -Raw
$ok = ($text -match "\[st-decap\] PASS" -and $text -notmatch "\[st-decap\] ERROR")
if (-not $ok) {
    throw "[st-decap] Shang decap fatality test failed; see $LogPath"
}
