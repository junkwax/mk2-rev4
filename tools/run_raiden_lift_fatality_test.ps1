param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 260,
    [int]$Observe = 300,         # the head rests ~220 frames after the fatality ends
    [int]$Victim = 1,           # ft_* of the victim: 1 Liu Kang, 8 Sub-Zero (NJ family)
    [int]$Mash = 1,             # 1 mash Up+HP (explodes), 0 stop mashing (body drops)
    [int]$MashFrom = 0,         # start mashing this many frames after the fatality starts
    [string]$MashUp = "hold",   # hold | tap - how Up is pressed while mashing
    [int]$Climb = 0,            # >0: preview climb_limit = N during the fatality (no build)
    [int]$CamUp = 0,            # >0: preview driving the camera N px up during the lift
    [int]$CamSpeed = 2,         # px per frame for -CamUp
    [switch]$Sound2,            # tap the sound latch and log every track code
    [string]$Owner = "0",       # Raiden costume claim: 0x0004 red (Start+HP), 0x0010 purple (Start+LP)
    [int]$Stage = 5,            # curback: 5 Armory (default)
    [int]$Hang = 900,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "raiden_lift_fatality_test.lua"
$LogPath = Join-Path $ToolsDir "raiden_lift_fatality_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\raiden_lift_fatality\run_$RunId"
New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:RDLF_LOG = $LogPath
$env:RDLF_OBSERVE = [string]$Observe
$env:RDLF_HANG = [string]$Hang
$env:RDLF_VICTIM = [string]$Victim
$env:RDLF_MASH = [string]$Mash
$env:RDLF_MASH_FROM = [string]$MashFrom
$env:RDLF_MASH_UP = $MashUp
$env:RDLF_CLIMB = [string]$Climb
$env:RDLF_CAMUP = [string]$CamUp
$env:RDLF_CAMSPD = [string]$CamSpeed
$env:RDLF_SND = $(if ($Sound2) { "1" } else { "0" })
$env:RDLF_STAGE = [string]$Stage
$env:RDLF_OWNER = [string]([Convert]::ToInt32(($Owner -replace "^0x",""), $(if ($Owner -match "^0x") {16} else {10})))

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

Write-Host "[rdlf] Raiden F,F,F+LK lift fatality probe"
$MameOutLog = Join-Path $ToolsDir "raiden_lift_fatality_mame_out.log"
Push-Location (Split-Path -Parent $Mame)
try {
    # MAME writes its (expected) source-build CRC warnings to stderr and exits
    # non-zero because of them.  Merge the streams into the log instead of
    # letting ErrorActionPreference=Stop tear the run down before it starts.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Mame @mameArgs 2>&1 | Out-File -FilePath $MameOutLog -Encoding utf8
    $ErrorActionPreference = $prevEAP
} finally {
    Pop-Location
    Remove-Item Env:\RDLF_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\RDLF_OBSERVE -ErrorAction SilentlyContinue
    Remove-Item Env:\RDLF_HANG -ErrorAction SilentlyContinue
    Remove-Item Env:\RDLF_VICTIM -ErrorAction SilentlyContinue
}

if (Test-Path $LogPath) {
    $verdict = Select-String -Path $LogPath -Pattern "^\[rdlf\] (PASS|FAIL) " | Select-Object -Last 1
    if ($verdict) { Write-Host "[rdlf] $($verdict.Line)" } else { Write-Warning "[rdlf] no verdict" }
} else {
    Write-Error "[rdlf] no log written (see $MameOutLog)"
}
Write-Host "[rdlf] Log:       $LogPath"
Write-Host "[rdlf] Snapshots: $RunSnapshots"
