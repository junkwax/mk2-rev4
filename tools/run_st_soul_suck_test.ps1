param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\test",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    [int]$P2Char = 11,
    # Restamp the victim object's ochar once the round is live. Use this for
    # Smoke(14)/Noob(15)/Jade(16): those cannot be driven through the select
    # screen from here, but they are exactly the drain_table /
    # alternate_suck_pals rows that did not exist before 2026-08-03.
    [int]$ForceOchar = -1,
    [int]$TimeoutSeconds = 240,
    [switch]$Sound,
    # Where the Lua reads src/mk2.map from.  Point it at a snapshot that
    # matches -RomPath when another session may be rebuilding this tree.
    [string]$MapRoot = ""
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "st_soul_suck_test.lua"
$LogDir = Join-Path $ToolsDir "st_soul_suck_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\st_soul_suck"
$OutputRoot = Join-Path $ToolsDir "st_soul_suck_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "st_soul_suck.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:ST_SOUL_LOG
$oldStage = $env:ST_SOUL_STAGE
$oldP2 = $env:ST_SOUL_P2_CHAR
$oldForce = $env:ST_SOUL_FORCE_OCHAR
$env:MK2_ROOT = $(if ($MapRoot) { $MapRoot } else { $Root })
$env:ST_SOUL_LOG = $LogPath
$env:ST_SOUL_STAGE = [string]$Stage
$env:ST_SOUL_P2_CHAR = [string]$P2Char
$env:ST_SOUL_FORCE_OCHAR = [string]$ForceOchar

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

    Write-Host "[st-soul] Launching Shang Tsung soul suck fatality test (Up,Down,Up + LK; P2 char $P2Char; force ochar $ForceOchar)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) {
        Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MK2_ROOT = $oldRoot
    }
    if ($null -eq $oldLog) {
        Remove-Item Env:\ST_SOUL_LOG -ErrorAction SilentlyContinue
    } else {
        $env:ST_SOUL_LOG = $oldLog
    }
    if ($null -eq $oldStage) {
        Remove-Item Env:\ST_SOUL_STAGE -ErrorAction SilentlyContinue
    } else {
        $env:ST_SOUL_STAGE = $oldStage
    }
    if ($null -eq $oldP2) {
        Remove-Item Env:\ST_SOUL_P2_CHAR -ErrorAction SilentlyContinue
    } else {
        $env:ST_SOUL_P2_CHAR = $oldP2
    }
    if ($null -eq $oldForce) {
        Remove-Item Env:\ST_SOUL_FORCE_OCHAR -ErrorAction SilentlyContinue
    } else {
        $env:ST_SOUL_FORCE_OCHAR = $oldForce
    }
}

Write-Host "[st-soul] Lua log: $LogPath"
Write-Host "[st-soul] Screenshots: $RunSnapshots"
Write-Host "[st-soul] MAME output: $RunOutput"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[st-soul] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 60
} else {
    throw "[st-soul] Lua log was not created"
}

$text = Get-Content -LiteralPath $LogPath -Raw
$ok = ($text -match "\[st-soul\] PASS" -and $text -notmatch "\[st-soul\] ERROR")
if (-not $ok) {
    throw "[st-soul] Shang soul suck fatality test failed; see $LogPath"
}
