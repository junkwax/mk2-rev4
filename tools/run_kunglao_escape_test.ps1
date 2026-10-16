param(
    # Its own executable name: every rig in this tree opens by killing its own
    # MAME by NAME, so a shared name lets two captures take each other down.
    [string]$Mame = "C:\MAME\mame_klesc.exe",
    # A ROM dir holding the escape build's mk2.zip.  Not rom\ and not
    # C:\MAME\roms - other sessions keep verified sets there.  Package with:
    #   python mamerom.py --no-install --output rom\escape_test\mk2.zip
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\escape_test",
    [string]$Resolution = "640x480",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs; on pwsh 7.3+ that alone would be promoted to a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Test-Path (Join-Path $RomPath "mk2.zip"))) {
    Write-Error "[klesc] no mk2.zip in $RomPath - package the escape build there first"
    exit 1
}
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame }

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kunglao_escape_test.lua"
$LogPath = Join-Path $ToolsDir "kunglao_escape_test.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\kunglao_escape\$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# A PRIVATE nvram dir: leftover CMOS credits desync the coin/start schedule,
# and wiping the shared one would yank CMOS out from under other captures.
$NvramDir = Join-Path $ToolsDir "nvram_klesc"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null
$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $Root
$env:KL_ESC_LOG = $LogPath

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir,
    "-seconds_to_run", 640
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[klesc] launching Kung Lao escape-dive test..."

# MAME's red "press any key" ROM-warning box appears on EVERY launch of a
# source build (the CRCs are spoofed, the SHA1s can never be) and it parks
# there forever at almost no CPU - indistinguishable from a slow boot.  This
# rig used to call MAME inline with no poker at all and depended on somebody
# noticing; a run then burnt the whole backstop producing no log.  The poker
# is its OWN process because this shell redirects MAME's stdio and so never
# owns the foreground - see tools/mame_dismiss_warning.ps1.
$OutLog = Join-Path $ToolsDir "kunglao_escape_mame_out.log"
$ErrLog = Join-Path $ToolsDir "kunglao_escape_mame_err.log"
try {
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
        "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", 60) | Out-Null

    # If the lua log has not appeared in 90s the box was never answered.  Kill
    # it and say so, rather than waiting the emulated backstop out and
    # reporting "no log" as if the ROM were broken.
    $marker = (Get-Date).AddSeconds(90)
    while (-not $proc.HasExited -and -not (Test-Path $LogPath) -and (Get-Date) -lt $marker) {
        Start-Sleep -Milliseconds 500
    }
    if (-not $proc.HasExited -and -not (Test-Path $LogPath)) {
        Write-Host "[klesc] no lua log after 90s - parked on the ROM warning box"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }

    $proc | Wait-Process -Timeout 720 -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) {
        Write-Host "[klesc] backstop hit - stopping this run only (pid $($proc.Id))"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item Env:MK2_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:KL_ESC_LOG -ErrorAction SilentlyContinue
}

Write-Host "[klesc] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[klesc] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath -Tail 24

# PASS proves the move fires, keeps its frame order, glides, tumbles, lands and
# leaves the ground spin alone.  It does NOT prove the art: a stale TMESCAPE SAG
# still reads as the right frame name.  Look at the snapshots.
if (-not (Select-String -Path $LogPath -Pattern "\[klesc\] PASS" -Quiet)) {
    Write-Error "[klesc] FAILED - see the field report above"
    exit 1
}
