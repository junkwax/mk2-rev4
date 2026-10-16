param(
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [switch]$HoldDown,
    [switch]$Early,
    [switch]$Walk,
    [switch]$Right,
    [int]$BackstopEmuSeconds = 400
)
# Reptile's invisible fatality (do_inviso_kill).  See reptile_inviso_fatal_test.lua.
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "reptile_inviso_fatal_test.lua"
$Tag = (@($(if ($HoldDown) {"hold"} else {"tap"}), $(if ($Early) {"early"}), $(if ($Walk) {"walk"}), $(if ($Right) {"right"})) | Where-Object { $_ }) -join "_"
$LogPath = Join-Path $ToolsDir "reptile_inviso_fatal_$Tag.log"
$SnapDir = Join-Path $Root "tmp\reptile_inviso_fatal\$Tag"
$NvramDir = Join-Path $ToolsDir "nvram_rif"

$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((Test-Path $zip) -and (Test-Path $out) -and
    ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime.AddSeconds(-30))) {
    Write-Host "[rif] REFUSING: $zip is older than src\mk2.out - repackage first."; exit 2
}

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $SnapDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $NvramDir | Out-Null

$env:MK2_ROOT = $Root
$env:RIF_LOG = $LogPath
$env:RIF_HOLD = if ($HoldDown) { "1" } else { "0" }
$env:RIF_EARLY = if ($Early) { "1" } else { "0" }
$env:RIF_WALK = if ($Walk) { "1" } else { "0" }
$env:RIF_RIGHT = if ($Right) { "1" } else { "0" }

$mameArgs = @("-rompath", $RomPath, "mk2", "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir, "-snapname", "%i",
    "-nvram_directory", $NvramDir, "-autoboot_script", $LuaScript,
    "-sound", "none", "-seconds_to_run", $BackstopEmuSeconds)

$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "reptile_inviso_fatal_mame_out.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "reptile_inviso_fatal_mame_err.log")
$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-ExecutionPolicy","Bypass","-File",$poker,"-ProcessId",$proc.Id,"-ReadyFile",$LogPath,"-TimeoutSec",180) | Out-Null
if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch {}; Write-Host "[rif] killed after 300s" }

foreach ($e in @("MK2_ROOT","RIF_LOG","RIF_HOLD","RIF_EARLY","RIF_WALK","RIF_RIGHT")) { Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }
if (-not (Test-Path $LogPath)) { Write-Host "[rif] NO LOG"; exit 2 }
Get-Content $LogPath
Write-Host "snapshots: $SnapDir"
if (Select-String -Path $LogPath -Pattern '\] PASS' -Quiet) { exit 0 } else { exit 1 }
