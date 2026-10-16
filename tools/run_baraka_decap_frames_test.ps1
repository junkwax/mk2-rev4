param(
    # Private-name copy: every rig in this tree opens with Stop-Process on its
    # own MAME name, so a bare mame.exe run can kill (or be killed by)
    # whatever else is capturing right now.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 220,
    [int]$SnapX = 60,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "baraka_decap_frames_test.lua"
$LogPath = Join-Path $ToolsDir "baraka_decap_frames_test.log"
$MameOutLog = Join-Path $ToolsDir "baraka_decap_frames_mame_out.log"
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# Private nvram dir - wiping the shared C:\MAME\nvram\mk2 would yank CMOS out
# from under any other capture that happens to be running.
$NvramDir = Join-Path $ToolsDir "nvram_bdf"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null

$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:BDF_LOG = $LogPath
$env:BDF_SNAP_X = [string]$SnapX

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[bdf] Baraka head-cut fatality frame probe"
Push-Location (Split-Path -Parent $Mame)
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs 2>&1 | Out-File -FilePath $MameOutLog -Encoding utf8
    $ErrorActionPreference = $prevEAP
} finally {
    Pop-Location
    Remove-Item Env:\BDF_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\BDF_SNAP_X -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 25
} else {
    Write-Error "[bdf] no log written (see $MameOutLog)"
}
Write-Host "[bdf] Log: $LogPath"
