param(
    # A private-name copy avoids the "two MAME rigs kill each other" trap:
    # every rig in this tree opens with Get-Process mame | Stop-Process, so a
    # bare mame.exe run can kill (or be killed by) whatever else is capturing.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 260,
    [int]$Observe = 180,
    [int]$Hang = 900,
    [int]$DenseLo = -1,
    [int]$DenseHi = -1,
    [int]$DenseStep = 3,
    [int]$SnapX = 180,
    [switch]$NoCostume,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "lk_dragonflame_fatality_test.lua"
$LogPath = Join-Path $ToolsDir "lk_dragonflame_fatality_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\lk_dragonflame_fatality\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Private nvram dir - wiping the shared C:\MAME\nvram\mk2 would yank CMOS out
# from under any other capture that happens to be running right now.
$NvramDir = Join-Path $ToolsDir "nvram_lkdf"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null
# Only OUR instance, by name - never a bare `mame`.
$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:LKDF_LOG = $LogPath
$env:LKDF_OBSERVE = [string]$Observe
$env:LKDF_HANG = [string]$Hang
$env:LKDF_SNAP_X = [string]$SnapX
$env:LKDF_NO_COSTUME = $(if ($NoCostume) { "1" } else { "0" })
$env:LKDF_DENSE_LO = [string]$DenseLo
$env:LKDF_DENSE_HI = [string]$DenseHi
$env:LKDF_DENSE_STEP = [string]$DenseStep

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

Write-Host "[lkdf] Liu Kang red dragon flame fatality probe"
$MameOutLog = Join-Path $ToolsDir "lk_dragonflame_fatality_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs 2>&1 | Out-File -FilePath $MameOutLog -Encoding utf8
    $ErrorActionPreference = $prevEAP
} finally {
    Pop-Location
    Remove-Item Env:\LKDF_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\LKDF_OBSERVE -ErrorAction SilentlyContinue
    Remove-Item Env:\LKDF_HANG -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    $verdict = Select-String -Path $LogPath -Pattern "^\[lkdf\] (PASS|FAIL) " | Select-Object -Last 1
    if ($verdict) { Write-Host "[lkdf] $($verdict.Line)" } else { Write-Warning "[lkdf] no verdict" }
} else {
    Write-Error "[lkdf] no log written (see $MameOutLog)"
}
Write-Host "[lkdf] Log:       $LogPath"
Write-Host "[lkdf] Snapshots: $RunSnapshots"
