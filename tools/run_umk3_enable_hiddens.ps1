param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\MAME\roms",
    [switch]$Reset      # wipe UMK3's CMOS first, to prove the unlock from scratch
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $Tools "umk3_enable_hiddens.lua"
$Log = Join-Path $Tools "umk3_enable_hiddens.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
if ($Reset) {
    Remove-Item -LiteralPath "C:\MAME\nvram\umk3" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[umk3] CMOS wiped"
}
$env:U3_LOG = $Log
Push-Location (Split-Path -Parent $Mame)
try {
    & $Mame -rompath $RomPath umk3 -window -nomaximize -resolution 640x480 `
        -video gdi -keyboardprovider win32 -skip_gameinfo -sound none `
        -autoboot_script $Lua -seconds_to_run 120 *> (Join-Path $Tools "umk3_enable_mame.log")
} finally { Pop-Location; Remove-Item Env:\U3_LOG -ErrorAction SilentlyContinue }

if (Test-Path $Log) { Get-Content $Log | Select-Object -Last 3 }
Write-Host ""
Write-Host "Hidden fighters unlocked in UMK3's CMOS (persisted to C:\MAME\nvram\umk3)."
Write-Host "Start MAME normally - SELECT YOUR FIGHTER row 2, tiles 2-4 are now"
Write-Host "Mileena / ERMAC / Classic Sub-Zero instead of dragon logos."
Write-Host "Ermac's telekinetic slam is Back, Down, Back + High Kick."
