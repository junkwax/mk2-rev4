param(
    # A private-name copy avoids the "two MAME rigs kill each other" trap.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 120,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "lk_bike_carry_test.lua"
$LogPath = Join-Path $ToolsDir "lk_bike_carry_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\lk_bike_carry\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

$NvramDir = Join-Path $ToolsDir "nvram_lkbike"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null

$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $RunSnapshots,
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[bike] Liu Kang bicycle kick victim-carry probe"
$MameOutLog = Join-Path $ToolsDir "lk_bike_carry_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs 2>&1 | Out-File -FilePath $MameOutLog -Encoding utf8
    $ErrorActionPreference = $prevEAP
} finally {
    Pop-Location
}

if (Test-Path $LogPath) {
    $verdict = Select-String -Path $LogPath -Pattern "^\[bike\] (PASS|FAIL|TIMEOUT)" | Select-Object -Last 1
    if ($verdict) { Write-Host "[bike] $($verdict.Line)" } else { Write-Warning "[bike] no verdict" }
} else {
    Write-Error "[bike] no log written (see $MameOutLog)"
}
Write-Host "[bike] Log:       $LogPath"
Write-Host "[bike] Snapshots: $RunSnapshots"
