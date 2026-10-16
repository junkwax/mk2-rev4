param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Shift = -1,          # -1 = leave the ROM's own oh_bigmonk_par alone
    [int]$Stage = 22,          # 22 = Outer Haven, 7 = stock Portal (control)
    [int]$Backstop = 150
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "oh_bigmonk_probe.lua"
$tag = if ($Shift -lt 0) { "rom" } else { "$Shift" }
if ($Stage -ne 22) { $tag = "s${Stage}_$tag" }
$Log = Join-Path $ToolsDir "oh_bigmonk_probe_$tag.log"
$SnapDir = Join-Path $ToolsDir "oh_bigmonk_$tag"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $SnapDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:BIGMONK_LOG = $Log
$env:MK2_MONK_STAGE = "$Stage"
if ($Shift -ge 0) { $env:MK2_BIGMONK_SHIFT = "$Shift" } else { Remove-Item Env:\MK2_BIGMONK_SHIFT -ErrorAction SilentlyContinue }

$mameArgs = @("-rompath", $RomPath, "mk2", "-window", "-nomaximize", "-resolution", "640x480",
    "-video", "gdi", "-sound", "none", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $SnapDir,
    "-autoboot_script", $Lua, "-seconds_to_run", $Backstop)

Write-Host "[monk] running big-monk probe (stage=$Stage shift=$tag) ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "oh_bigmonk_mame_$tag.log") } finally { Pop-Location }
Remove-Item Env:\BIGMONK_LOG, Env:\MK2_MONK_STAGE, Env:\MK2_BIGMONK_SHIFT -ErrorAction SilentlyContinue

Write-Host "`n===== BIG MONK PAN (shift $tag) ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "stop |residual|SPREAD|FAIL|TIMEOUT|ERROR|forcing" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
Write-Host "Snapshots: $SnapDir"
