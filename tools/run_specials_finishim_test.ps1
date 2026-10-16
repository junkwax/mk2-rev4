param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,
    [string[]]$Case = @("baraka_spark", "sz_tornado", "hh_spin", "sc_teleport"),
    [switch]$Control,             # run the same inputs in a NORMAL fight (A/B baseline)
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "specials_finishim_test.lua"
$SnapshotRoot = Join-Path $ToolsDir "screens\specials_finishim"

$results = @()

foreach ($c in $Case) {
    $LogPath = Join-Path $ToolsDir "specials_finishim_$c.log"
    $RunId = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunSnapshots = Join-Path $SnapshotRoot "${c}_$RunId"
    New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

    # Boot determinism: leftover CMOS credits desync the scripted coin schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:SPEC_CASE = $c
    $env:SPEC_LOG = $LogPath
    if ($Control) { $env:SPEC_CONTROL = "1" } else { Remove-Item Env:\SPEC_CONTROL -ErrorAction SilentlyContinue }

    $mameArgs = @(
        "-rompath", $RomPath,
        "mk2",
        "-window", "-nomaximize",
        "-resolution", $Resolution,
        "-video", "gdi",
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-snapshot_directory", $RunSnapshots,
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    $mode = if ($Control) { "CONTROL (normal fight)" } else { "FINISH HIM" }
    Write-Host "[specials] $c - mode: $mode"
    $MameOutLog = Join-Path $ToolsDir "specials_finishim_mame_out.log"
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> $MameOutLog
    } finally {
        Pop-Location
        Remove-Item Env:\SPEC_CASE -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_CONTROL -ErrorAction SilentlyContinue
    }

    $verdict = "NO VERDICT (setup/timeout?)"
    if (Test-Path $LogPath) {
        $line = Select-String -Path $LogPath -Pattern "^\[spec\] (PASS|FAIL) " | Select-Object -Last 1
        if ($line) { $verdict = $line.Line -replace "^\[spec\] ", "" }
    }
    Write-Host "[specials] $c -> $verdict"
    $results += [pscustomobject]@{ Case = $c; Verdict = $verdict }
}

Write-Host ""
Write-Host "==== specials during FINISH HIM ===="
$results | ForEach-Object { "{0,-14} {1}" -f $_.Case, $_.Verdict }
