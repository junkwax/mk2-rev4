param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,

    # cpu   - drone Khameleon must drag the match to YOTEIGAI TOR (018h)
    # human - a player who unlocked her must KEEP the selected stage
    # control - the same check against Jade, whose forcing already shipped;
    #           run it whenever this rig reports a failure, because most
    #           "the stage was not forced" results are the rig, not the ROM.
    [ValidateSet("cpu", "human", "control", "all")]
    [string]$Mode = "all",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "kham_stage_test.lua"

$modes = if ($Mode -eq "all") { @("cpu", "human", "control") } else { @($Mode) }
$anyFailed = $false

foreach ($m in $modes) {
    $LogPath = Join-Path $ToolsDir "kham_stage_$m.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = "C:/Users/you/Workplace/mk2-main"
    $env:KHAM_STAGE_LOG = $LogPath
    if ($m -eq "control") {
        # Jade (16) on her own arena (curback 9): a known-good reference.
        $env:KHAM_STAGE_MODE = "cpu"
        $env:KHAM_STAGE_HIDDEN = "16"
        $env:KHAM_STAGE_WANT = "9"
    } else {
        $env:KHAM_STAGE_MODE = $m
        Remove-Item Env:\KHAM_STAGE_HIDDEN, Env:\KHAM_STAGE_WANT -ErrorAction SilentlyContinue
    }

    $mameArgs = @(
        "-rompath", $RomPath, "mk2",
        "-window", "-nomaximize", "-resolution", $Resolution, "-video", "gdi",
        # Without an explicit keyboardprovider MAME parks on the "press any
        # key" warning screen and the rig times out with no ROM ever running.
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[kham-stage] mode: $m"
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> (Join-Path $ToolsDir "kham_stage_mame_$m.log")
    } finally {
        Pop-Location
        foreach ($v in @("MK2_ROOT", "KHAM_STAGE_LOG", "KHAM_STAGE_MODE",
                         "KHAM_STAGE_HIDDEN", "KHAM_STAGE_WANT")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    $verdict = Select-String -Path $LogPath -Pattern '^\[kham-stage\] (PASS|FAIL)' -ErrorAction SilentlyContinue |
               Select-Object -Last 1
    if ($verdict) { Write-Host "  $($verdict.Line)" } else { Write-Host "  NO VERDICT - see the mame log" }
    if (-not ($verdict -and $verdict.Line -match 'PASS')) { $anyFailed = $true }
}

if ($anyFailed) { exit 1 } else { exit 0 }
