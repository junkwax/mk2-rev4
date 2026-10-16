<#
    run_dp_reflect.ps1 - play the Dead Pool with the acid reflections live.

    Boots itself into a Dead Pool fight with Ed (hanger 0) framed, then hands
    the controls back.  Runs THROTTLED and windowed so it is watchable and
    recordable, unlike the headless capture runs.

        tools\run_dp_reflect.ps1
        tools\run_dp_reflect.ps1 -Speed 0.5     # half speed, to study the ripple
#>
param(
    [double]$Speed = 1,
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "1024x768"
)

$lua = Join-Path $PSScriptRoot "dp_reflect_play.lua"
if (-not (Test-Path $lua))  { throw "missing $lua" }
if (-not (Test-Path $Mame)) { throw "missing MAME at $Mame" }

Write-Host ""
Write-Host "  Dead Pool - acid reflections" -ForegroundColor Cyan
Write-Host "  ------------------------------------------------------"
Write-Host "  Boots to a Dead Pool fight (~25s), frames Ed, then it's yours."
Write-Host ""
Write-Host "  Look in the thin acid strip just ABOVE the walkway:"
Write-Host "    fighters      -> green      (boonpal idx 6)"
Write-Host "    Ed, hanger 0  -> brighter   (boonpal idx 7)"
Write-Host ""
Write-Host "  numpad 1 = re-frame Ed     numpad 2 = hide the readout"
Write-Host "  ------------------------------------------------------"
Write-Host ""

$args = @(
    "mk2",
    "-rompath", $RomPath,
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-autoboot_script", $lua,
    "-nofilter",
    "-speed", $Speed.ToString([System.Globalization.CultureInfo]::InvariantCulture)
)

& $Mame @args
