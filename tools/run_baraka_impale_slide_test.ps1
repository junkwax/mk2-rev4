param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 260,
    [int]$Observe = 150,
    [int]$Hang = 900,
    [string]$Tag = "run",
    [int]$Extra = 0,
    [int]$ExtraStep = 5,
    [int]$Victim = 11,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "baraka_impale_slide_test.lua"
$LogPath = Join-Path $ToolsDir "baraka_impale_slide_test.log"
$RunSnapshots = Join-Path $ToolsDir "screens\baraka_impale_slide\$Tag"
Remove-Item -LiteralPath $RunSnapshots -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:BIS_LOG = $LogPath
$env:BIS_OBSERVE = [string]$Observe
$env:BIS_HANG = [string]$Hang
$env:BIS_TAG = $Tag
$env:BIS_EXTRA = [string]$Extra
$env:BIS_EXTRA_STEP = [string]$ExtraStep
$env:BIS_VICTIM = [string]$Victim

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
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

Write-Host "[bis] Baraka B,F,D,F+LP impale slide probe (tag=$Tag)"
$MameOutLog = Join-Path $ToolsDir "baraka_impale_slide_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs 2>&1 | Out-File -FilePath $MameOutLog -Encoding utf8
    $ErrorActionPreference = $prevEAP
} finally {
    Pop-Location
    Remove-Item Env:\BIS_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\BIS_OBSERVE -ErrorAction SilentlyContinue
    Remove-Item Env:\BIS_HANG -ErrorAction SilentlyContinue
    Remove-Item Env:\BIS_TAG -ErrorAction SilentlyContinue
    Remove-Item Env:\BIS_EXTRA -ErrorAction SilentlyContinue
    Remove-Item Env:\BIS_EXTRA_STEP -ErrorAction SilentlyContinue
    Remove-Item Env:\BIS_VICTIM -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Copy-Item -LiteralPath $LogPath -Destination (Join-Path $RunSnapshots "run.log") -Force
    $verdict = Select-String -Path $LogPath -Pattern "^\[bis\] (PASS|FAIL) " | Select-Object -Last 1
    if ($verdict) { Write-Host "[bis] $($verdict.Line)" } else { Write-Warning "[bis] no verdict" }
    Select-String -Path $LogPath -Pattern "SLIDE SUMMARY" -Context 0, 8 | ForEach-Object { $_.Line; $_.Context.PostContext }
} else {
    Write-Error "[bis] no log written (see $MameOutLog)"
}
Write-Host "[bis] Log:       $LogPath"
Write-Host "[bis] Snapshots: $RunSnapshots"
