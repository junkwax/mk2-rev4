<#
    run_hw_effects_demo.ps1 - launch the hardware-effects showcase at a pace
    you can screen-record.

    Companion to tools/hw_effects_demo.lua and doc/UNUSED_HARDWARE_EFFECTS.md.

    Unlike the regression run, this one keeps MAME THROTTLED (real 60 Hz) and
    holds each effect long enough to narrate.  Start OBS first - the script
    prints a countdown and tells you roughly when the tour begins.

    Every active effect NAMES ITSELF on screen, along with the doc item it
    demonstrates and what to look for, so the recording needs no commentary
    track.  Numpad / hides the readout if you want clean footage.

    Examples:
        # 8 seconds per effect, self-driving, stays open at the end
        tools\run_hw_effects_demo.ps1

        # slower still, and half emulation speed for close inspection
        tools\run_hw_effects_demo.ps1 -StepSeconds 12 -Speed 0.5

        # no auto-tour: boot it yourself and drive with the numpad
        tools\run_hw_effects_demo.ps1 -Manual
#>
param(
    # Seconds to hold each effect during the tour.
    [double]$StepSeconds = 8,
    # Emulation speed multiplier. 1 = normal. 0.5 = half speed, good for
    # watching the animated squash/stretch and the strobe.
    [double]$Speed = 1,
    # Skip the auto-tour: boot the game yourself and use the numpad keys.
    [switch]$Manual,
    # Exit as soon as the tour ends instead of leaving MAME open.
    [switch]$ExitWhenDone,
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600"
)

$root = Split-Path -Parent $PSScriptRoot
$lua  = Join-Path $PSScriptRoot "hw_effects_demo.lua"

if (-not (Test-Path $lua))  { throw "missing $lua" }
if (-not (Test-Path $Mame)) { throw "missing MAME at $Mame" }

# The Lua script reads its pacing from the environment.
if ($Manual) {
    Remove-Item Env:\HWFX_AUTO -ErrorAction SilentlyContinue
} else {
    $env:HWFX_AUTO = "1"
}
$env:HWFX_STEP_SECONDS = "$StepSeconds"
if ($ExitWhenDone) {
    Remove-Item Env:\HWFX_HOLD -ErrorAction SilentlyContinue
} else {
    $env:HWFX_HOLD = "1"
}

$steps = 10
$bootSecs = 30      # measured: a fight is reached around frame 1491
$tourSecs = $steps * $StepSeconds / $Speed

Write-Host ""
Write-Host "  MK2 hardware-effects showcase" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------"
if ($Manual) {
    Write-Host "  Manual mode. Get into a fight, then drive it from the numpad:"
    Write-Host "    + (plus)  run the tour        1  cycle target"
    Write-Host "    2 flip    3 silhouette        4  cycle colour"
    Write-Host "    5 fill    6 strobe            7  scale presets"
    Write-Host "    8 shake   9 dpytap shift      0  clear everything"
    Write-Host "    /  hide/show the on-screen readout"
} else {
    Write-Host ("  Auto tour: {0} effects x {1}s each" -f $steps, $StepSeconds)
    Write-Host ("  Boot to a fight takes ~{0}s, so the tour starts ~{0}s in." -f [int]($bootSecs / $Speed))
    Write-Host ("  Total runtime to the end of the tour: ~{0}s." -f [int](($bootSecs / $Speed) + $tourSecs))
    if (-not $ExitWhenDone) {
        Write-Host "  MAME stays open afterwards - close it when your recording is done."
    }
}
Write-Host ("  Emulation speed: {0}x" -f $Speed)
Write-Host "  On-screen readout names each effect; numpad / hides it."
Write-Host "  Log: tools\hw_effects_demo.log"
Write-Host "  ---------------------------------------------------------"
Write-Host "  Start your OBS recording now. Launching in 5s..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

$args = @(
    "mk2",
    "-rompath", $RomPath,
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-autoboot_script", $lua,
    "-nofilter"
)
# -speed needs an invariant-culture decimal or MAME rejects it on some locales
$args += @("-speed", $Speed.ToString([System.Globalization.CultureInfo]::InvariantCulture))

Write-Host "[hwfx] $Mame $($args -join ' ')"
& $Mame @args
Write-Host "[hwfx] MAME exited."
