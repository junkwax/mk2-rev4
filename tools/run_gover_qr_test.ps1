param(
    [Parameter(Mandatory = $true)][string]$Rom,       # dir holding mk2.zip AND its own mk2.map
    [switch]$Control,                                 # leave the dice alone: no QR may appear
    [string]$Mame = "C:\MAME\mame.exe",
    [int]$Backstop = 900
)
# The Discord QR on GORO'S LAIR's game-over screen - see tools/gover_qr_test.lua.
# Private nvram/cfg/snapshots under $Rom; kills nothing but its own MAME.
$ErrorActionPreference = "Continue"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Rom = (Resolve-Path $Rom).Path
$Map = Join-Path $Rom "mk2.map"
if (-not (Test-Path $Map)) { Write-Host "REFUSED: $Map missing (the zip needs its own map)"; exit 2 }
$Tag = if ($Control) { "control" } else { "lair" }
$Log = Join-Path $Rom "gover_qr_$Tag.log"
$Snap = Join-Path $Rom "snap_$Tag"
foreach ($d in @("nv_$Tag", "cfg_$Tag", "snap_$Tag")) { New-Item -ItemType Directory -Force (Join-Path $Rom $d) | Out-Null }
Remove-Item (Join-Path $Rom "nv_$Tag\*") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Log -Force -ErrorAction SilentlyContinue

$env:GQ_LOG = $Log; $env:GQ_MAP = $Map
$env:GQ_NOPATCH = if ($Control) { "1" } else { "0" }
$args = @("mk2", "-rompath", $Rom, "-window", "-nomaximize", "-sound", "none",
    "-keyboardprovider", "win32", "-skip_gameinfo", "-nothrottle",
    "-nvram_directory", (Join-Path $Rom "nv_$Tag"), "-cfg_directory", (Join-Path $Rom "cfg_$Tag"),
    "-snapshot_directory", $Snap,
    "-autoboot_script", (Join-Path $Tools "gover_qr_test.lua"), "-seconds_to_run", $Backstop)
$p = Start-Process -FilePath $Mame -ArgumentList $args -WorkingDirectory (Split-Path $Mame) -PassThru `
    -RedirectStandardOutput (Join-Path $Rom "mame_$Tag.out") -RedirectStandardError (Join-Path $Rom "mame_$Tag.err")
Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", (Join-Path $Tools "mame_dismiss_warning.ps1"),
    "-ProcessId", $p.Id, "-ReadyFile", $Log) -WindowStyle Hidden | Out-Null
$t0 = Get-Date
while (-not $p.HasExited) {
    Start-Sleep -Seconds 2
    if (-not (Test-Path $Log) -and ((Get-Date) - $t0).TotalSeconds -gt 63) {
        Write-Host "no lua log after 63s - killing our MAME"; Stop-Process -Id $p.Id -Force; break
    }
}
Remove-Item Env:\GQ_LOG, Env:\GQ_MAP, Env:\GQ_NOPATCH -ErrorAction SilentlyContinue
if (Test-Path $Log) { Get-Content $Log } else { Write-Host "NO VERDICT: no log" ; exit 2 }
if (Select-String -Path $Log -Pattern "RESULT PASS" -Quiet) { exit 0 } else { exit 1 }
