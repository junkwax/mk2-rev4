param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME.  Every
    # rig in this tree opens by killing MAME by process name, so two of them at
    # once take each other down and the loser's log stops mid-run looking
    # exactly like a crash.  Falls back to mame.exe if the copy is not there.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [switch]$NoSnap
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs; on pwsh 7.3+ that alone would be promoted to a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "reptile_uninviso_test.lua"
$LogPath = Join-Path $ToolsDir "reptile_uninviso.log"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapDir = Join-Path $ToolsDir "screens\reptile_uninviso\$RunId"

New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

# PRIVATE nvram dir - wiping C:\MAME\nvram yanks CMOS out from under any other
# capture that happens to be running.  Leftover credits desync the scripted
# coin/start schedule.
$NvramDir = Join-Path $ToolsDir "nvram_uninviso"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null

$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_UI_ROOT = $Root
$env:MK2_UI_LOG = $LogPath
$env:MK2_UI_SNAP = if ($NoSnap) { "0" } else { "1" }

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir,
    "-sound", "none",
    "-seconds_to_run", 400
)

Write-Host "[ui] launching Reptile un-inviso test..."
Push-Location (Split-Path -Parent $Mame)
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # Source-built ROMs never match MAME's CRC table, so the red "press any
    # key" warning is posted on EVERY run.  -seconds_to_run counts EMULATED
    # time, so a MAME parked on that screen never times out.
    $mameProc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "reptile_uninviso_mame_out.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "reptile_uninviso_mame_err.log")
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy","Bypass","-File",$poker,
        "-ProcessId",$mameProc.Id,"-ReadyFile",$LogPath,"-TimeoutSec",180) | Out-Null
    $mameProc.WaitForExit()
    Write-Host "[ui] mame exit code: $($mameProc.ExitCode)"
    $ErrorActionPreference = $prev
} finally {
    Pop-Location
    Remove-Item Env:MK2_UI_ROOT, Env:MK2_UI_LOG, Env:MK2_UI_SNAP -ErrorAction SilentlyContinue
}

Write-Host "[ui] screenshots: $SnapDir"
if (-not (Test-Path $LogPath)) { Write-Error "[ui] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath | Select-Object -Last 70

if (-not (Select-String -Path $LogPath -Pattern "\[ui\] PASS" -Quiet)) {
    Write-Error "[ui] FAILED - see the report above"
    exit 1
}
