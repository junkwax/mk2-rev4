param(
    [string]$Mame = "C:\MAME\mame.exe",
    # Defaults to the repo rom/ dir, which holds the freshly installed build.
    # rom\test is a separate, often stale snapshot - do not point here by habit.
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$TimeoutSeconds = 300,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "st_kintaro_morph_test.lua"
$LogDir = Join-Path $ToolsDir "st_kintaro_morph_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\st_kintaro_morph"
$OutputRoot = Join-Path $ToolsDir "st_kintaro_morph_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "st_kintaro_morph.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:ST_KINTARO_LOG
$oldStage = $env:ST_KINTARO_STAGE
$env:MK2_ROOT = $Root
$env:ST_KINTARO_LOG = $LogPath
$env:ST_KINTARO_STAGE = [string]$Stage

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
    if (-not $Sound) { $runArgs.NoSound = $true }

    Write-Host "[st-kintaro] Launching Shang Tsung Goro reveal test (press-HK -> do_st_dive -> stgoro_roll)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) { Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue } else { $env:MK2_ROOT = $oldRoot }
    if ($null -eq $oldLog) { Remove-Item Env:\ST_KINTARO_LOG -ErrorAction SilentlyContinue } else { $env:ST_KINTARO_LOG = $oldLog }
    if ($null -eq $oldStage) { Remove-Item Env:\ST_KINTARO_STAGE -ErrorAction SilentlyContinue } else { $env:ST_KINTARO_STAGE = $oldStage }
}

Write-Host "[st-kintaro] Lua log: $LogPath"
Write-Host "[st-kintaro] Screenshots: $RunSnapshots"
Write-Host "[st-kintaro] MAME output: $RunOutput"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[st-kintaro] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 60
} else {
    throw "[st-kintaro] Lua log was not created"
}

$text = Get-Content -LiteralPath $LogPath -Raw
$ok = ($text -match "\[st-kintaro\] PASS" -and $text -notmatch "\[st-kintaro\] ERROR")
if (-not $ok) {
    throw "[st-kintaro] Goro morph test failed; see $LogPath"
}
