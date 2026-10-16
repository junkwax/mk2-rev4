param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,

    # kham    - Khameleon's sai, whose lanes are relocated and biased
    # mileena - THE CONTROL.  Same move, no bias, shipped for thirty years.
    #           Always run both: this rig photographs art, and a photograph
    #           of one character proves nothing on its own.
    [ValidateSet("kham", "mileena", "both")]
    [string]$Mode = "both",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "kham_sai_hit_test.lua"
$SnapRoot = "C:\MAME\snap\saihit"

$modes = if ($Mode -eq "both") { @("mileena", "kham") } else { @($Mode) }
$anyFailed = $false

Remove-Item $SnapRoot -Recurse -Force -ErrorAction SilentlyContinue

foreach ($m in $modes) {
    $LogPath = Join-Path $ToolsDir "kham_sai_hit_$m.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = "C:/Users/you/Workplace/mk2-main"
    $env:KHAM_SAI_MODE = $m
    $env:KHAM_SAI_LOG = $LogPath

    $mameArgs = @(
        "-rompath", $RomPath, "mk2",
        "-window", "-nomaximize", "-resolution", $Resolution, "-video", "gdi",
        # Without an explicit keyboardprovider MAME parks on the "press any
        # key" warning screen and the rig times out with no ROM ever running.
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-snapshot_directory", (Join-Path $SnapRoot $m),
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[sai-hit] mode: $m"
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> (Join-Path $ToolsDir "kham_sai_hit_mame_$m.log")
    } finally {
        Pop-Location
        foreach ($v in @("MK2_ROOT", "KHAM_SAI_MODE", "KHAM_SAI_LOG")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    $verdict = Select-String -Path $LogPath -Pattern '^\[sai-hit/.*\] (PASS|FAIL)' -ErrorAction SilentlyContinue |
               Select-Object -Last 1
    if ($verdict) { Write-Host "  $($verdict.Line)" } else { Write-Host "  NO VERDICT - see the mame log" }
    if (-not ($verdict -and $verdict.Line -match 'PASS')) { $anyFailed = $true }
}

Write-Host ""
Write-Host "Snapshots under $SnapRoot\<mode>\mk2\ - COMPARE THEM."
Write-Host "Khameleon's sai must look like Mileena's; the failure this exists"
Write-Host "for draws Jade's green boomerang blade instead."

if ($anyFailed) { exit 1 } else { exit 0 }
