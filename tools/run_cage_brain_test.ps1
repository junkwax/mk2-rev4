param(
    # A privately named copy of mame.exe: this rig only ever stops its own.
    [string]$Mame = "C:\MAME\mame_cbrain.exe",
    # A dir holding the zip AND the mk2.map it was built with.
    [string]$RomDir = "C:\Users\you\Workplace\mk2-main\tmp\cage_brain_rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 300,
    # "all" = the twelve stock fighters, which covers all nine headhole bodies.
    [string[]]$Victim = @("kang"),
    [int]$SnapEvery = 4,
    # -Demo: sound on, a bigger window, and a few seconds on the last frame
    # before MAME closes - for WATCHING it, not for the verdict
    [switch]$Demo
)

# JOHNNY CAGE'S BRAIN PUNCH, one MAME run per victim: lineup on his
# jch_place row, chunks out of the back of the head only, back on his own
# floor once down.  See tools/cage_brain_test.lua.

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "cage_brain_test.lua"
if ($Victim -contains "all") {
    $Victim = @("kang", "kunglao", "cage", "baraka", "kitana", "mileena", "shang",
                "raiden", "subzero", "reptile", "scorpion", "jax")
}
$Map = Join-Path $RomDir "mk2.map"
if (-not (Test-Path (Join-Path $RomDir "mk2.zip")) -or -not (Test-Path $Map)) {
    Write-Host "[cb] REFUSING: $RomDir needs mk2.zip and the mk2.map it was built with."
    exit 2
}

$Dismiss = Join-Path $ToolsDir "mame_dismiss_warning.ps1"

$Private = Join-Path $Root "tmp\cage_brain_mame"
$SnapRoot = Join-Path $Root "tmp\cage_brain"
$results = @()
foreach ($v in $Victim) {
    $LogPath = Join-Path $SnapRoot "cage_brain_$v.log"
    $SnapDir = Join-Path $SnapRoot $v
    Remove-Item -LiteralPath $SnapDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Private -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force "$Private\nvram", "$Private\cfg" | Out-Null
    Get-Process (Split-Path -Leaf $Mame).Replace(".exe", "") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root; $env:CB_VICTIM = $v; $env:CB_LOG = $LogPath
    $env:CB_MAP = $Map; $env:CB_SNAP = "$SnapEvery"
    $env:CB_HOLD = if ($Demo) { "220" } else { "0" }
    if ($Demo) { $Resolution = "1200x900" }
    $mameArgs = @("-rompath", $RomDir, "mk2", "-window", "-nomaximize",
        "-resolution", $Resolution, "-video", "gdi", "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-nvram_directory", "$Private\nvram", "-cfg_directory", "$Private\cfg",
        "-snapshot_directory", $SnapDir, "-snapname", "%i",
        "-autoboot_script", $LuaScript, "-seconds_to_run", $BackstopEmuSeconds)
    if (-not $Demo) { $mameArgs += @("-sound", "none") }
    Write-Host "[cb] $v ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput "$SnapRoot\mame_out_$v.log" -RedirectStandardError "$SnapRoot\mame_err_$v.log"
    # mame_dismiss_warning.ps1 must be its OWN process (see its header).
    $poker = Start-Process -FilePath "powershell" -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Dismiss,
        "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", "120")
    $proc.WaitForExit()
    if (-not $poker.HasExited) { try { $poker.Kill() } catch {} }
    foreach ($e in "CB_VICTIM", "CB_LOG", "CB_MAP", "CB_SNAP", "CB_HOLD") { Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

    $lines = if (Test-Path $LogPath) { Get-Content $LogPath } else { @() }
    $lines | Select-String 'WINDUP|LINEUP|CHUNKS|FALL|SHAKE|SOUND|SPLASH' | ForEach-Object { Write-Host "  $($_.Line)" }
    $verdict = $lines | Select-String '\] (PASS|FAIL) ' | Select-Object -Last 1
    if ($verdict) { Write-Host $verdict.Line; $results += $verdict.Line }
    else { Write-Host "[cb/$v] NO VERDICT - see $LogPath"; $results += "[cb/$v] NO VERDICT" }
}
Write-Host ""
$results | ForEach-Object { Write-Host $_ }
$pass = ($results | Where-Object { $_ -match '\] PASS ' }).Count
Write-Host "[cb] $pass / $($results.Count) PASS"
if ($pass -ne $results.Count) { exit 1 }
