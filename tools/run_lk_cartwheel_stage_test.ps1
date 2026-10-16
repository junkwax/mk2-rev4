# run_lk_cartwheel_stage_test.ps1 - Liu Kang's cartwheel + LP+LK held = the
# stage fatality.  See tools/lk_cartwheel_stage_test.lua for what is measured.
#
#   -Stage deadpool|pit|tomb|tor
#   -Hold      hold LP+LK once the fatality starts (PASS = stage payoff)
#   (no -Hold) plain cartwheel               (PASS = no stage payoff, completes)
#
# Launch pattern from run_conditions_test.ps1 (Start-Process + separate
# warning dismisser).  A first launch after a build sometimes never reaches
# frames - rerun before believing a no-verdict.
param(
    [ValidateSet("deadpool", "pit", "tomb", "tor")]
    [string]$Stage = "deadpool",
    [switch]$Hold,
    [int]$Gap = 150,
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 500
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Tag = "$Stage" + $(if ($Hold) { "_hold" } else { "_plain" })
$Lua = Join-Path $ToolsDir "lk_cartwheel_stage_test.lua"
$Log = Join-Path $ToolsDir "lk_cartwheel_stage_$Tag.log"
$Out = Join-Path $ToolsDir "lk_cartwheel_stage_mame_$Tag.log"
$Err = Join-Path $ToolsDir "lk_cartwheel_stage_mame_$Tag.err"
$SnapDir = Join-Path $ToolsDir "screens\lk_cartwheel_$Tag"

Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item $Log, $Out, $Err -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:CW_STAGE = $Stage
$env:CW_HOLD = $(if ($Hold) { "1" } else { "0" })
$env:CW_GAP = "$Gap"
$env:CW_TEST_LOG = $Log

$mameArgs = @("-rompath", $RomPath, "mk2", "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-sound", "none", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir, "-autoboot_script", $Lua, "-seconds_to_run", $Backstop,
    "-cfg_directory", "C:\MAME\cfg", "-nothrottle")

Write-Host "[cwstage] $Tag gap=$Gap"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru -RedirectStandardOutput $Out -RedirectStandardError $Err

Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
    "-ProcessId", $proc.Id, "-TimeoutSec", 25) | Out-Null

$proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
"CW_STAGE", "CW_HOLD", "CW_GAP", "CW_TEST_LOG" | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

# One source only: -Unique across the two would also drop repeated attempts
# whose lines happen to be identical, which hides exactly what a flake looks like.
$lines = @()
if (Test-Path $Log) { $lines = Get-Content $Log }
elseif (Test-Path $Out) { $lines = Get-Content $Out | Where-Object { $_ -match "\[cwstage\]" } }
$lines | Where-Object { $_ -match "RESULT|stage=|TRIGGER|dizzy|attempt|stage action|gstate .*->9|  rel=|  jcq|  gate|obs rel=" }
# A Lua error aborts the rest of that frame's callback every frame, so the rig
# keeps logging state while never pressing anything - say so loudly.
if (Test-Path $Err) {
    $luaErr = Select-String -Path $Err -Pattern "LUA ERROR" | Select-Object -First 1
    if ($luaErr) { Write-Warning "[cwstage] rig script error: $($luaErr.Line)" }
}
if (-not ($lines -match "RESULT ")) {
    Write-Warning "[cwstage] no verdict - see $Out / $Err"
    $lines | Select-Object -Last 8
}
Write-Host "[cwstage] snapshots: $SnapDir"
