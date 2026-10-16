param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$Stage = 1,
    [int]$AttackerSide = 1,
    [string]$State = "",
    [string]$StateDirectory = "",
    [switch]$StateHp,
    [string]$ScriptName = "",
    [int]$TimeoutSeconds = 180,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

if ($AttackerSide -notin 1, 2) {
    throw "[jcheadhole] AttackerSide must be 1 or 2"
}

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
if (-not $StateDirectory) {
    $StateDirectory = Join-Path $ToolsDir "states"
}
$LuaScriptName = if ($ScriptName) {
    $ScriptName
} elseif ($StateHp -or $State) {
    "jc_headhole_fatality_state_hp_test.lua"
} else {
    "jc_headhole_fatality_test.lua"
}
$LuaScript = Join-Path $ToolsDir $LuaScriptName
$LogDir = Join-Path $ToolsDir "jc_headhole_fatality_test_logs"
$SnapshotRoot = Join-Path $ToolsDir "screens\jc_headhole_fatality"
$OutputRoot = Join-Path $ToolsDir "jc_headhole_fatality_test_out"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $SnapshotRoot "run_$RunId"
$RunOutput = Join-Path $OutputRoot "run_$RunId"
$LogPath = Join-Path $LogDir "jc_headhole_fatality.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
New-Item -ItemType Directory -Force -Path $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$oldRoot = $env:MK2_ROOT
$oldLog = $env:JC_HEADHOLE_FATALITY_LOG
$oldStage = $env:JC_HEADHOLE_STAGE
$oldHud = $env:JC_HEADHOLE_HUD
$oldAttackerSide = $env:JC_HEADHOLE_ATTACKER_SIDE
$env:MK2_ROOT = $Root
$env:JC_HEADHOLE_FATALITY_LOG = $LogPath
$env:JC_HEADHOLE_STAGE = [string]$Stage
$env:JC_HEADHOLE_HUD = "1"
$env:JC_HEADHOLE_ATTACKER_SIDE = [string]$AttackerSide

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

    if ($State) {
        $runArgs.State = $State
        $runArgs.StateDirectory = $StateDirectory
    }

    Write-Host "[jcheadhole] Launching Cage headhole fatality test ($LuaScriptName; P$AttackerSide Cage; HUD on)..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) {
        Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MK2_ROOT = $oldRoot
    }
    if ($null -eq $oldLog) {
        Remove-Item Env:\JC_HEADHOLE_FATALITY_LOG -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_FATALITY_LOG = $oldLog
    }
    if ($null -eq $oldStage) {
        Remove-Item Env:\JC_HEADHOLE_STAGE -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_STAGE = $oldStage
    }
    if ($null -eq $oldHud) {
        Remove-Item Env:\JC_HEADHOLE_HUD -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_HUD = $oldHud
    }
    if ($null -eq $oldAttackerSide) {
        Remove-Item Env:\JC_HEADHOLE_ATTACKER_SIDE -ErrorAction SilentlyContinue
    } else {
        $env:JC_HEADHOLE_ATTACKER_SIDE = $oldAttackerSide
    }
}

Write-Host "[jcheadhole] Lua log: $LogPath"
Write-Host "[jcheadhole] Screenshots: $RunSnapshots"
Write-Host "[jcheadhole] MAME output: $RunOutput"

if (Test-Path -LiteralPath $LogPath) {
    Write-Host "[jcheadhole] Log tail:"
    Get-Content -LiteralPath $LogPath -Tail 120
} else {
    throw "[jcheadhole] Lua log was not created"
}

$text = Get-Content -LiteralPath $LogPath -Raw
$ok = ($text -match "\[jcheadhole\] PASS" -and $text -notmatch "\[jcheadhole\] ERROR")
if (-not $ok) {
    throw "[jcheadhole] Cage headhole fatality test failed; see $LogPath"
}
