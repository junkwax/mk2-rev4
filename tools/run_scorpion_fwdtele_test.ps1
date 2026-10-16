param(
    # mame_mk2test.exe is a byte copy of mame.exe under a different NAME so this
    # rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 240,
    # Cross the forward and backward expectations.  Every crossed trial must
    # FAIL - swapping the two directions is the likely regression, so that is
    # the control worth having.
    [switch]$Negative,
    # The mk2.map that belongs to -RomPath's zip.  Given = a frozen pair, so the
    # live-tree staleness check below is skipped.
    [string]$Map = "",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "scorpion_fwdtele_test.lua"
$LogPath = Join-Path $ToolsDir "scorpion_fwdtele_test.log"
$MameOutLog = Join-Path $ToolsDir "scorpion_fwdtele_mame_out.log"

# A rig reads symbol addresses out of the CURRENT src/mk2.map; a zip paired with
# another build's map reads every one of them at the wrong address and then
# reports nothing wrong.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and
    ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[sft] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
# PRIVATE nvram/cfg: this used to delete C:\MAME\nvram\mk2, which is the
# user's cmos (earned fighters, operator settings).
$Priv = Join-Path $Root "tmp\scorpion_fwdtele"
Remove-Item -LiteralPath $Priv -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $Priv "nvram"), (Join-Path $Priv "cfg") | Out-Null

$env:MK2_ROOT = $Root.Replace("\", "/")
$env:SFT_LOG = $LogPath
$env:SFT_NEGATIVE = if ($Negative) { "1" } else { "0" }
if ($Map) { $env:SFT_MAP = $Map } else { Remove-Item Env:\SFT_MAP -ErrorAction SilentlyContinue }

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-nvram_directory", (Join-Path $Priv "nvram"),
    "-cfg_directory", (Join-Path $Priv "cfg"),
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Sound) { $mameArgs += @("-sound", "none") }

if ($Negative) {
    Write-Host "[sft] Scorpion forward teleport - NEGATIVE control (crossed expectations must FAIL)"
} else {
    Write-Host "[sft] Scorpion forward teleport: fwd / back / fwdleft / cool / coolback / fkfwd / fkback / airfwd"
}

# THE RED ROM-WARNING SCREEN.  It ALWAYS appears for mk2 (undumped PLDs) and
# there is no -skip_warnings in this build, so it has to be ANSWERED: MAME sits
# at the screen, the Lua log is never written, and the run is indistinguishable
# from a hang.  tools/mame_dismiss_warning.ps1 does it and must be its OWN
# process - this shell starts MAME with redirected stdout, so it never owns the
# foreground and its posted keys are ignored.  ReadyFile is the Lua log: once
# that exists we are past the screen and the poker stops, so no dismissal key
# ever lands in the game.
#
# Kill the run ourselves if the Lua log never appears, instead of waiting the
# backstop out: an empty log with MAME alive and "Responding" reads exactly like
# a broken ROM, and burning 240s of backstop to learn that wastes a cycle.
$proc = $null
Push-Location (Split-Path -Parent $Mame)
try {
    $proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
                          -RedirectStandardOutput $MameOutLog `
                          -RedirectStandardError "$MameOutLog.err"
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", $poker,
        "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", "150") | Out-Null
    $waited = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 3
        $waited += 3
        if ($waited -ge 75 -and -not (Test-Path $LogPath)) {
            Write-Host "[sft] no Lua log after ${waited}s - killing MAME (see $MameOutLog)"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            break
        }
        if ($waited -ge ($BackstopEmuSeconds * 4 + 120)) {
            Write-Host "[sft] backstop exceeded - killing MAME"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            break
        }
    }
} finally {
    Pop-Location
    foreach ($v in @("MK2_ROOT", "SFT_LOG", "SFT_NEGATIVE", "SFT_MAP")) {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-Object -Last 45
    $verdict = Select-String -Path $LogPath -Pattern '^\[sft\] (PASS|FAIL)' | Select-Object -Last 1
    if ($verdict -and $verdict.Line -match 'PASS') { exit 0 }
    if (-not $verdict) { Write-Host "[sft] NO VERDICT - see $MameOutLog" }
    exit 1
} else {
    Write-Host "[sft] NO LOG - MAME never started; see $MameOutLog"
    exit 1
}
