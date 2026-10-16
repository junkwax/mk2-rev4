param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    # Two rigs at once kill the loser with exit -1 and a log that stops
    # mid-run, which reads exactly like the ROM crashing.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,

    [ValidateSet("jade","smoke","noob","ermac","all")]
    [string]$Name = "all",
    [int]$Player = 1,           # 1 = P1 in a 1P game, 2 = P2 in a 2P game
    [int]$Snap = 40,            # frames between celebration screenshots (0 = none)
    # Regression mode: no cheat.  Confirm whoever the cursor starts on with a
    # plain Low Punch and require HIS roster name call.  cmove9 took over
    # select_speech's ochar -> table arithmetic, so every ordinary pick in the
    # game rides on that same edit.
    [switch]$Normal,
    # Carry on past the celebration into the match and check nothing the
    # celebration allocated is still on the display list (Jade's staff).
    [switch]$Fight,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "hidden_select_victory_test.lua"
$MameOutLog = Join-Path $ToolsDir "hidden_select_victory_mame_out.log"

$names = if ($Name -eq "all") { @("jade","smoke","noob","ermac") } else { @($Name) }
$results = @()

foreach ($n in $names) {
    $tag = if ($Normal) { "roster" } else { $n }
    $LogPath = Join-Path $ToolsDir "hidden_select_victory_$($tag)_p$Player.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # A previous run that did not exit cleanly poisons the next one: the two
    # instances fight over the same files and the loser dies mid-log with no
    # message, which reads exactly like the ROM crashing.
    Get-Process -Name "mame_mk2test" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:HSV_NAME = $n
    $env:HSV_PLAYER = [string]$Player
    $env:HSV_LOG = $LogPath
    $env:HSV_SNAP = [string]$Snap
    if ($Fight) { $env:HSV_FIGHT = "1" } else { Remove-Item "Env:HSV_FIGHT" -ErrorAction SilentlyContinue }
    if ($Normal) { $env:HSV_NORMAL = "1" } else { Remove-Item "Env:\HSV_NORMAL" -ErrorAction SilentlyContinue }

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

    Write-Host "[$tag] P$Player - select-screen celebration + name call"
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> $MameOutLog
    } finally {
        Pop-Location
        foreach ($v in @("HSV_NAME","HSV_PLAYER","HSV_LOG","HSV_SNAP","HSV_NORMAL","HSV_FIGHT")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $LogPath) {
        $verdict = Select-String -Path $LogPath -Pattern '^\[.*\] (PASS|FAIL)' | Select-Object -Last 1
        if ($verdict) { Write-Host $verdict.Line; $results += $verdict.Line }
        else { Write-Host "[$n] NO VERDICT - check $LogPath and $MameOutLog"; $results += "[$n] NO VERDICT" }
    } else {
        Write-Host "[$n] NO LOG - MAME never started; see $MameOutLog"
        $results += "[$n] NO LOG"
    }
}

Write-Host ""
Write-Host "=== summary ==="
$results | ForEach-Object { Write-Host $_ }
