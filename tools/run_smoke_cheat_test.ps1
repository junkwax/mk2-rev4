param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,
    [int]$Player = 1,          # 1 = P1 in a 1P game, 2 = P2 in a 2P game
    [int]$Hover = 10,          # 10 = Scorpion -> runs the cheat (expect Smoke).
                               # any other char -> REGRESSION: Block must confirm normally
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "smoke_cheat_test.lua"
$LogPath = Join-Path $ToolsDir "smoke_cheat_test.log"

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:SMOKE_LOG = $LogPath
$env:SMOKE_PLAYER = [string]$Player
$env:SMOKE_HOVER = [string]$Hover

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

$mode = if ($Hover -eq 10) { "CHEAT (hover Scorpion, Block x5 -> expect Smoke)" } else { "REGRESSION (hover char $Hover, Block x1 -> expect normal confirm)" }
Write-Host "[smoke-test] P$Player - mode: $mode"
$MameOutLog = Join-Path $ToolsDir "smoke_cheat_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame @mameArgs *> $MameOutLog
} finally {
    Pop-Location
    Remove-Item Env:\SMOKE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\SMOKE_PLAYER -ErrorAction SilentlyContinue
    Remove-Item Env:\SMOKE_HOVER -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Write-Host "[smoke-test] Log tail:"
    Get-Content -Path $LogPath -Tail 40
    if (Select-String -Path $LogPath -Pattern "^\[smoke\] PASS" -Quiet) {
        Write-Host "[smoke-test] >>> PASS"
    } elseif (Select-String -Path $LogPath -Pattern "^\[smoke\] FAIL" -Quiet) {
        Write-Host "[smoke-test] >>> FAIL - see log."
    } else {
        Write-Warning "[smoke-test] No clean verdict (setup/timeout?)."
    }
} else {
    Write-Error "[smoke-test] Lua log was not created (see $MameOutLog)."
}
