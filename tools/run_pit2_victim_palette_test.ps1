param(
    # A byte copy of mame.exe under its own name, so rigs never kill each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 300,
    [int]$VictimX = 400,
    [ValidateSet("left", "right")]
    [string]$Side = "left"
)

# THE PIT II: the victim must keep his palette across the cut to the pit
# bottom (falling_down_the_pit rebuilds him).  Liu Kang mirror, so player 2
# wears the mirror lane rather than player 1's default.  Private nvram/cfg;
# kills nothing by name.  See tools/pit2_victim_palette_test.lua.

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "pit2_victim_palette_test.lua"
$OutDir = Join-Path $Repo "tmp\pit2_victim_palette"
$LogPath = Join-Path $OutDir "test.log"
$Priv = Join-Path $OutDir "mame_state"
$Snaps = Join-Path $OutDir ("snap_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $OutDir, $Snaps, "$Priv\nvram", "$Priv\cfg" | Out-Null
Remove-Item -Recurse -Force "$Priv\nvram\*" -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path (Join-Path $RomPath "mk2.zip"))) { Write-Error "no mk2.zip in $RomPath"; exit 2 }
$out = Join-Path $Repo "src\mk2.out"
if ((Get-Item (Join-Path $RomPath "mk2.zip")).LastWriteTime -lt (Get-Item $out).LastWriteTime) {
    Write-Error "mk2.zip in $RomPath is older than src\mk2.out - the map would not match"; exit 2
}

$env:PP_TEST_LOG = $LogPath
$env:PP_VX = [string]$VictimX
$env:PP_SIDE = $Side

$mameArgs = @("-rompath", $RomPath, "mk2", "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-cfg_directory", "$Priv\cfg", "-nvram_directory", "$Priv\nvram",
    "-snapshot_directory", $Snaps, "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds)

$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $OutDir "mame_out.log") -RedirectStandardError (Join-Path $OutDir "mame_err.log")

$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $poker,
    "-ProcessId", $proc.Id, "-ReadyFile", $LogPath, "-TimeoutSec", 60) | Out-Null

$proc | Wait-Process -Timeout ($BackstopEmuSeconds + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
"PP_TEST_LOG", "PP_VX", "PP_SIDE" | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-String "victim_ready|FALL_PAL|BOTTOM|RESULT" | ForEach-Object { Write-Host $_ }
    if (Select-String -Path $LogPath -Pattern "RESULT PASS" -Quiet) { exit 0 }
    if (-not (Select-String -Path $LogPath -Pattern "RESULT " -Quiet)) { Get-Content $LogPath -Tail 20; exit 2 }
    exit 1
} else { Write-Error "lua log was not created"; exit 2 }
