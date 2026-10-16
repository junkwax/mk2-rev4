# Live tuner for Kitana's fan boomerang turn.  Opens MAME in a window on a
# Kitana vs idle Jax fight with tools/fan_tune_live.lua's overlay; the keys are
# listed at the top of that file and on screen.
#
# By default it PACKAGES ITS OWN zip + map from the current link into
# tmp\fan_tune\ (and refuses if src\mk2.out changes while it does), because the
# tuner pokes the ROM by symbol address and the tree's src\mk2.map moves every
# time any session relinks.  -NoPackage reuses the last package.
#
# PRIVATE nvram, so your cmos (earned fighters, settings) is never touched.
# Close the MAME window when you are done.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$Resolution = "1200x762",
    [switch]$NoPackage,
    [switch]$NoSound,
    [switch]$SelfTest     # unattended: throw on the built numbers, edit live, throw again, PASS/FAIL
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Tools
$Lua = Join-Path $Tools "fan_tune_live.lua"
$Log = Join-Path $Tools "fan_tune_live.log"
$Ready = "$Log.ready"
$Pkg = Join-Path $Root "tmp\fan_tune"
$Nvram = Join-Path $Pkg "nvram"
New-Item -ItemType Directory -Force -Path $Pkg, $Nvram | Out-Null
if (Test-Path $Ready) { Remove-Item -LiteralPath $Ready -Force }

$zip = Join-Path $Pkg "mk2.zip"
$map = Join-Path $Pkg "mk2.map"
if (-not $NoPackage) {
    $out = Join-Path $Root "src\mk2.out"
    $srcMap = Join-Path $Root "src\mk2.map"
    if (-not (Select-String -Path $srcMap -Pattern "\bfan_tune\b" -Quiet)) {
        throw "src\mk2.map has no fan_tune - rebuild (python build.py --asm-only)"
    }
    $h0 = (Get-FileHash $out).Hash
    Copy-Item $srcMap $map -Force
    Push-Location $Root
    try {
        python makerom.py | Out-Null
        if ($LASTEXITCODE) { throw "makerom.py failed" }
        python mamerom.py --source-video --no-install --output $zip | Out-Null
        if ($LASTEXITCODE) { throw "mamerom.py failed" }
    } finally { Pop-Location }
    if ((Get-FileHash $out).Hash -ne $h0) {
        throw "src\mk2.out changed while packaging (another session relinked) - run it again"
    }
    Write-Host "[fantune] packaged $zip"
}
if (-not (Test-Path $zip) -or -not (Test-Path $map)) { throw "no package in $Pkg - run without -NoPackage" }

$env:FANTUNE_LOG = $Log -replace '\\', '/'
$env:FANTUNE_MAP = $map -replace '\\', '/'
$mameArgs = @(
    "-rompath", $Pkg, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-keyboardprovider", "win32", "-skip_gameinfo",
    "-nvram_directory", $Nvram,
    "-autoboot_script", $Lua
)
if ($NoSound -or $SelfTest) { $mameArgs += @("-sound", "none") }
$env:FANTUNE_SELFTEST = ""
$env:FANTUNE_SAVE = ""
if ($SelfTest) {
    $env:FANTUNE_SELFTEST = "1"
    $env:FANTUNE_SAVE = (Join-Path $Pkg "selftest_saved.txt") -replace '\\', '/'
    $mameArgs += @("-seconds_to_run", "150", "-snapshot_directory", (Join-Path $Pkg "snap"))
}

$p = Start-Process -FilePath $Mame -ArgumentList $mameArgs -WorkingDirectory (Split-Path -Parent $Mame) -PassThru
# the red ROM-warning box has to be answered by a separate process
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Tools "mame_dismiss_warning.ps1"),
    "-ProcessId", $p.Id, "-ReadyFile", $Ready) | Out-Null
Write-Host "[fantune] MAME pid $($p.Id).  Log: $Log"
if ($SelfTest) {
    if (-not $p.WaitForExit(240000)) { Stop-Process -Id $p.Id; Write-Host "[fantune] timed out" }
    Get-Content $Log
    if (Select-String -Path $Log -Pattern "SELFTEST PASS" -Quiet) { exit 0 } else { exit 1 }
}
Write-Host "[fantune] After saving (M):  python tools\fan_tune_apply.py   bakes the numbers into MKZAP.ASM"
