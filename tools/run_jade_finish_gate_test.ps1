param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    # Two rigs at once kill the loser with exit -1 and a log that stops
    # mid-run, which reads exactly like the ROM crashing.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 240,

    # human = a player who unlocked Jade must GET the FINISH HIM window and an
    #         ordinary stage/difficulty.
    # cpu   = a drone Jade (what the secret encounter hands the gate) must
    #         still be refused it.
    [ValidateSet("human", "cpu", "rounds", "both", "all")]
    [string]$Mode = "both",
    [switch]$Snap,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "jade_finish_gate_test.lua"
$MameOutLog = Join-Path $ToolsDir "jade_finish_gate_mame_out.log"

$modes = switch ($Mode) {
    "both" { @("human", "cpu") }
    "all"  { @("human", "cpu", "rounds") }
    default { @($Mode) }
}

foreach ($m in $modes) {
    $LogPath = Join-Path $ToolsDir "jade_finish_gate_$m.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:JFG_MODE = $m
    $env:JFG_LOG = $LogPath
    if ($Snap) { $env:JFG_SNAP = "1" }

    $mameArgs = @(
        "-rompath", $RomPath,
        "mk2",
        "-window", "-nomaximize",
        "-resolution", $Resolution,
        "-video", "gdi",
        # Without an explicit keyboardprovider MAME parks on the "press any
        # key" warning screen and the rig times out with no ROM ever running.
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[jfg] mode: $m"
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> $MameOutLog
    } finally {
        Pop-Location
        foreach ($v in @("JFG_MODE", "JFG_LOG", "JFG_SNAP")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $LogPath) {
        $verdict = Select-String -Path $LogPath -Pattern '^\[.*\] (PASS|FAIL)' |
                   Select-Object -Last 1
        if ($verdict) { Write-Host $verdict.Line }
        else { Write-Host "[jfg/$m] NO VERDICT - check $LogPath and $MameOutLog" }
    } else {
        Write-Host "[jfg/$m] NO LOG - MAME never started; see $MameOutLog"
    }
}
