param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so
    # this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 140,
    [int]$Frames = 3000,
    [int]$Tol = 8,
    # Same fight, same pose loop, P1 = Jax so no `lightning` process runs.
    # peak_overload means nothing without it.
    # Which behaviour to assert: "stance" = MK1's rule (lgtstance 1),
    # "everywhere" = lgtstance 0.
    [ValidateSet("stance","everywhere")]
    [string]$Mode = "stance",
    [switch]$Control,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "raiden_pose_bolt_test.lua"
$tag = if ($Control) { "_control" } else { "" }
$LogPath = Join-Path $ToolsDir "raiden_pose_bolt_test$tag.log"
$MameOutLog = Join-Path $ToolsDir "raiden_pose_bolt_mame_out$tag.log"

# A zip paired with ANOTHER link's map reads every symbol at the wrong address
# and reports a confident, entirely false FAIL: no bolts found anywhere, because
# objlst/p1_obj/p1_proc point at garbage.  This has already cost one bogus
# result here (map 00:51:40 against a zip from 00:49:52, while another session
# was mid-relink).  Refuse the pairing instead of measuring it.
$MapFile = Join-Path (Split-Path -Parent $ToolsDir) "src\mk2.map"
$ZipFile = Join-Path $RomPath "mk2.zip"
foreach ($f in @($MapFile, $ZipFile)) {
    if (-not (Test-Path $f)) { throw "missing $f - build first" }
}
$mapT = (Get-Item $MapFile).LastWriteTime
$zipT = (Get-Item $ZipFile).LastWriteTime
if ($mapT -gt $zipT) {
    throw ("src/mk2.map ({0:HH:mm:ss}) is NEWER than {1} ({2:HH:mm:ss}). " -f $mapT, $ZipFile, $zipT) +
          "The rig would read symbols from a different build than the ROM it loads. " +
          "Re-run makerom.py + mamerom.py so the pair matches, then try again."
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# Leftover CMOS credits desync the scripted coin/start schedule.
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$env:RDPOSE_LOG = $LogPath
$env:RDPOSE_FRAMES = [string]$Frames
$env:RDPOSE_TOL = [string]$Tol
$env:RDPOSE_MODE = $Mode
if ($Control) { $env:RDPOSE_CONTROL = "1" } else { Remove-Item Env:\RDPOSE_CONTROL -ErrorAction SilentlyContinue }

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    # Without an explicit keyboardprovider MAME parks on the "press any key"
    # warning screen and the rig times out with no ROM ever running.
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

Write-Host "[rdpose] Raiden ambient crackle vs pose - mode=$Mode frames=$Frames tol=$Tol"
Push-Location (Split-Path -Parent $Mame)
try {
    $p = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $MameOutLog -RedirectStandardError "$MameOutLog.err"
    # The ROM warning box ALWAYS appears for source-built ROMs; a rig that
    # misses it burns the whole -seconds_to_run backstop producing nothing.
    $dismiss = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    if (Test-Path $dismiss) {
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dismiss,
            "-ProcessId", $p.Id, "-ReadyFile", $LogPath) -WindowStyle Hidden | Out-Null
    }
    if (-not $p.WaitForExit(($BackstopEmuSeconds + 60) * 1000)) {
        Write-Host "[rdpose] backstop exceeded - killing MAME"
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
    }
} finally {
    Pop-Location
    foreach ($v in @("RDPOSE_LOG", "RDPOSE_FRAMES", "RDPOSE_TOL", "RDPOSE_CONTROL", "RDPOSE_MODE")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Select-String -Path $LogPath -Pattern '^\[rdpose\] (stand|walk|duck|air|peak_overload)' |
        ForEach-Object { Write-Host $_.Line }
    $verdict = Select-String -Path $LogPath -Pattern '^\[rdpose\] (PASS|FAIL)' |
               Select-Object -Last 1
    if ($verdict) { Write-Host $verdict.Line }
    else { Write-Host "[rdpose] NO VERDICT - check $LogPath and $MameOutLog" }
} else {
    Write-Host "[rdpose] NO LOG - MAME never started; see $MameOutLog"
}
