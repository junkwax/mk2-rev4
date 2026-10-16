param(
    # smoke    - the change: COMEHERE1/2 in flight, COMEHERE3 taut
    # scorpion - the CONTROL: BIGRP1/2 and SPEARHIT, unchanged by this work,
    #            and the half of the clip check that the old hard-coded 304
    #            would still pass.  Run both or the run proves half of it.
    [ValidateSet("smoke", "scorpion", "both")]
    [string]$Who = "both",
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$Frames = 5400,
    [int]$BackstopEmuSeconds = 260,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would otherwise be promoted
# to a terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "smoke_spear_test.lua"

# THE EXPECTATIONS ARE REGENERATED EVERY RUN, from src/SMROPE.TBL and
# src/MKNJ.TBL.  A rebuild moves every SAG in a pack, so a rig holding last
# week's numbers would compare the live object against art that has since
# moved - and pass.  This also refuses outright if a record is missing or its
# width no longer matches data/NEWROPE.IMG.
Write-Host "[spear] regenerating expectations from the linked tables"
& python (Join-Path $ToolsDir "smoke_spear_expect.py")
if ($LASTEXITCODE -ne 0) {
    Write-Host "[spear] could not build expectations - not running MAME"
    exit 1
}

# A zip older than the link means the rig would read every symbol at the wrong
# address and report nothing wrong (the run_ani2_guard_test trap).
$zip = Join-Path $Root "rom\mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((Test-Path $zip) -and (Test-Path $out)) {
    if ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime) {
        Write-Host "[spear] rom/mk2.zip is OLDER than src/mk2.out - repackage first"
        exit 1
    }
}

$targets = if ($Who -eq "both") { @("smoke", "scorpion") } else { @($Who) }
$fails = @()

foreach ($w in $targets) {
    $LogPath = Join-Path $ToolsDir "smoke_spear_$w.log"
    $MameOutLog = Join-Path $ToolsDir "smoke_spear_mame_$w.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = "C:/Users/you/Workplace/mk2-main"
    $env:MK2_SPEAR_WHO = $w
    $env:MK2_SPEAR_LOG = $LogPath
    $env:MK2_SPEAR_END = "$Frames"

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

    Write-Host "[spear] $w on the rope - watching every record the DMA is handed"
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> $MameOutLog
    } finally {
        Pop-Location
        foreach ($v in @("MK2_ROOT", "MK2_SPEAR_WHO", "MK2_SPEAR_LOG", "MK2_SPEAR_END")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $LogPath) {
        Get-Content $LogPath | Select-Object -Last 22
        $verdict = Select-String -Path $LogPath -Pattern '^\[spear\] (PASS|FAIL)' | Select-Object -Last 1
        if (-not ($verdict -and $verdict.Line -match 'PASS')) { $fails += $w }
    } else {
        Write-Host "[spear] $w - NO LOG, see $MameOutLog"
        $fails += $w
    }
    Write-Host ""
}

if ($fails.Count -gt 0) {
    Write-Host "[spear] FAIL: $($fails -join ', ')"
    exit 1
}
Write-Host "[spear] PASS: $($targets -join ', ')"
exit 0
