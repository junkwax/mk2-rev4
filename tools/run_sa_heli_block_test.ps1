param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$Mode = "block",
    [int]$Seconds = 150,
    # -sound none makes the sound strobe unobservable: the game's writes to
    # 1d01030h never complete and a write tap sees only the power-up
    # handshake.  Pass -Sound to watch cues.
    [switch]$Sound
)

$repo = "C:\Users\you\Workplace\mk2-main"
$lua  = Join-Path $repo "tools\sa_heli_block_test.lua"
$log  = Join-Path $repo ("tools\sa_heli_block_test.$Mode.log")
$out  = Join-Path $repo ("tools\sa_heli_block_test.$Mode.mame.log")

Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
# nvram kept: a blank CMOS boots this build into gs_diag and never reaches a fight

$env:MK2_HELI_MODE = $Mode

$args = @(
    "-rompath", (Join-Path $repo "rom\test"),
    "mk2",
    "-window", "-nomaximize", "-resolution", "640x480",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", ($Sound ? "auto" : "none"),
    "-video", "gdi",
    "-snapshot_directory", (Join-Path $repo "tmp\heli_block_snap"),
    "-seconds_to_run", $Seconds,
    "-autoboot_script", $lua
)

Write-Host "[heli] mode=$Mode launching MAME..."
Push-Location (Split-Path -Parent $Mame)
& $Mame @args *> $out
Pop-Location

if (Test-Path $log) {
    Write-Host "[heli] --- log tail ---"
    Get-Content -Path $log -Tail 80
} else {
    Write-Warning "[heli] no lua log; MAME output tail:"
    if (Test-Path $out) { Get-Content -Path $out -Tail 40 }
}
