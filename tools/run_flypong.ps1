# run_flypong.ps1 - two fruit flies play Ed Boon's Pong, first to 99, match after match.
#
#   .\tools\run_flypong.ps1                  # fast, invisible training (no window, no sound)
#   .\tools\run_flypong.ps1 -Watch           # a window at the board's own speed, for a stream
#   .\tools\run_flypong.ps1 -Watch -WeightsIn C:\tmp\flybrain\pong\brains.lua   # carry on
#
# Needs the Pong-only ROM (pong_only .set 1 in src/MKAMODE.ASM) frozen with its own map in
# -RomPath. Runs on private nvram/cfg folders and kills no other MAME. The dashboard reads
# <Out>\pong.json: python tools/flypong_dashboard.py --state <Out>\pong.json
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\tmp\flybrain\pong_rom_v5",  # v5: score to 99; ball quickens 3%/return to 1.5x; FROSTY sound when he scores
    [string]$Net = "C:\tmp\flybrain\out\flynet_oa.lua",
    [string]$Out = "C:\tmp\flybrain\pong",
    [string]$WeightsIn = "",
    [int]$MaxMinutes = 0,
    [int]$React = 8,
    [int]$Seed = 0,
    [switch]$NoLearn,
    [switch]$NoAim,            # the original "where is the ball now" fly (FP_AIM=0, flypong.lua)
    [switch]$Clamp,            # the old per-option weight clamp (FP_CLAMP=1, flypong.lua)
    [switch]$Maximize,
    [switch]$Sound,
    [switch]$Watch
)
$ErrorActionPreference = "Stop"
$Tools = $PSScriptRoot
foreach ($f in @("$RomPath\mk2.zip", "$RomPath\mk2.map", $Net)) { if (-not (Test-Path $f)) { throw "missing $f" } }
New-Item -ItemType Directory -Force "$Out\nvram", "$Out\cfg", "$Out\snap" | Out-Null
$env:FP_MAP = "$RomPath\mk2.map"; $env:FB_NET = $Net; $env:FP_OUT = $Out
$env:FP_REACT = "$React"; $env:FP_MAXMIN = "$MaxMinutes"
$env:FP_LEARN = $(if ($NoLearn) { "0" } else { "1" })
$env:FP_AIM = $(if ($NoAim) { "0" } else { "1" })
$env:FP_CLAMP = $(if ($Clamp) { "1" } else { "0" })
if ($Seed -ne 0) { $env:FP_SEED = "$Seed" } else { Remove-Item Env:FP_SEED -ErrorAction SilentlyContinue }
if ($WeightsIn) { $env:FP_WEIGHTS_IN = $WeightsIn } else { Remove-Item Env:FP_WEIGHTS_IN -ErrorAction SilentlyContinue }
$a = @("-rompath", $RomPath, "mk2", "-skip_gameinfo", "-keyboardprovider", "none", "-mouseprovider", "none", "-joystickprovider", "none", "-lightgunprovider", "none",
    "-nvram_directory", "$Out\nvram", "-cfg_directory", "$Out\cfg", "-snapshot_directory", "$Out\snap",
    "-autoboot_script", (Join-Path $Tools "flypong.lua"))
if ($Watch) {
    # MAME's ROM-warning screen waits for a key, and this MAME reads no keys. MAME skips its
    # startup screens when the debugger is on, so the window runs with it on, hidden
    # (-debugger none) and told to just go. No key is ever sent to anything.
    Set-Content -Path "$Out\go.ds" -Value "go" -Encoding ascii
    $a += @("-debug", "-debugger", "none", "-debugscript", "$Out\go.ds")
    # big but never stretched: keep the arcade's 4:3 whatever mame.ini says
    $a += @("-keepaspect", "-nounevenstretch")
    $a += @("-window"); if ($Maximize) { $a += "-maximize" } else { $a += @("-nomaximize", "-resolution", "800x600") }
    if (-not $Sound) { $a += @("-sound", "none") }
} else { $a += @("-nothrottle", "-video", "none", "-sound", "none") }
Write-Host "[flypong] output: $Out"
$p = Start-Process -FilePath $Mame -ArgumentList $a -WorkingDirectory (Split-Path -Parent $Mame) -PassThru `
    -WindowStyle $(if ($Watch) { "Normal" } else { "Hidden" }) `
    -RedirectStandardOutput "$Out\mame_out.log" -RedirectStandardError "$Out\mame_err.log"
if ($Watch) {
    # NO WARNING-SCREEN HELPER. mame_dismiss_warning.ps1 pulls MAME to the front and types
    # Enter/Space as REAL key presses every half second for up to three minutes - it took
    # the user's keyboard. With every input provider off, MAME does not wait on that
    # screen (measured: a -window run with no helper played its first rally 11 s in).
} else {
    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
}
$p.WaitForExit()
Write-Host "[flypong] MAME exited ($($p.ExitCode))"
if (Test-Path "$Out\pong.log") { Get-Content "$Out\pong.log" -Tail 15 }
