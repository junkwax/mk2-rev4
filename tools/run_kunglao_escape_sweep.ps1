param(
    # Its own executable name: rigs kill their own MAME by NAME.
    [string]$Mame = "C:\MAME\mame_klsweep.exe",
    # A ROM dir holding a PRIVATE escape build (mk2.zip). Package with:
    #   python mamerom.py --source-video --no-install --output rom\escape_test\mk2.zip
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom\escape_test",
    # A frozen tree holding src\mk2.map + src\MKHH.TBL that MATCH that zip - another
    # session's rebuild of src\ would otherwise move every .bss knob under the rig.
    [string]$MapRoot = "C:\Users\you\Workplace\mk2-main\tmp\klsweep",
    # name:k=v,...;name:...   (keys: rate roll rolltix drop xvel lift grav vcap rollspd
    #                           xdrag xmin rolldec rollmin - px/tick, lift up-positive)
    [string]$Configs = "stock:",
    [int]$Seconds = 300
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
if (-not (Test-Path (Join-Path $RomPath "mk2.zip"))) { Write-Error "no mk2.zip in $RomPath"; exit 1 }
if (-not (Test-Path (Join-Path $MapRoot "src\mk2.map"))) { Write-Error "no src\mk2.map under $MapRoot"; exit 1 }
if (-not (Test-Path $Mame)) { Copy-Item "C:\MAME\mame.exe" $Mame }

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "kunglao_escape_sweep.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $ToolsDir "screens\kunglao_escape_sweep\$RunId"
$SnapDir = Join-Path $OutDir "snap"
$LogPath = Join-Path $OutDir "sweep.log"
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
$NvramDir = Join-Path $OutDir "nvram"
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null
$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$env:MK2_ROOT = $MapRoot
$env:KLS_LOG = $LogPath
$env:KLS_SNAP = $SnapDir
$env:KLS_CONFIGS = $Configs
$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir, "-snapname", "%i",
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir, "-cfg_directory", (Join-Path $OutDir "cfg"),
    "-seconds_to_run", $Seconds, "-sound", "none"
)
try {
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $OutDir "mame_out.log") -RedirectStandardError (Join-Path $OutDir "mame_err.log")
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
        "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", 60) | Out-Null
    $marker = (Get-Date).AddSeconds(90)
    while (-not $proc.HasExited -and -not (Test-Path $LogPath) -and (Get-Date) -lt $marker) { Start-Sleep -Milliseconds 500 }
    if (-not $proc.HasExited -and -not (Test-Path $LogPath)) {
        Write-Host "[klsweep] no lua log after 90s - parked on the ROM warning box"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    # stop as soon as the sweep reports done, rather than idling out the clock
    while (-not $proc.HasExited) {
        if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern "sweep done|LUA ERROR" -Quiet)) {
            Start-Sleep -Seconds 1; Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; break
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Remove-Item Env:MK2_ROOT, Env:KLS_LOG, Env:KLS_SNAP, Env:KLS_CONFIGS -ErrorAction SilentlyContinue
}
Write-Host "[klsweep] out: $OutDir"
if (Test-Path $LogPath) { Get-Content $LogPath | Select-String -Pattern "SNAPRANGE|launch=|NEVER|ERROR|done" }
