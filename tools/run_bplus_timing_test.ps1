# run_bplus_timing_test.ps1 - Back+HP move timing for every fighter that has one.
#
# Packages a PRIVATE zip from the current link (never installs), then runs MAME
# once per fighter with tools/bplus_timing_test.lua: a hit trial and a whiff
# trial, reporting windup / hit total / whiff total in ticks.  Addresses are
# resolved out of src/mk2.map every run.  Private nvram/cfg; kills only its
# own process.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$Chars = "3,4,10,1,0,6,11,2",
    [switch]$NoPackage,
    [int]$BackstopSec = 300
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root  = Split-Path -Parent $Tools
$Work  = Join-Path $Root "tmp\bplus_timing"
$RomDir = Join-Path $Work "rom"
New-Item -ItemType Directory -Force -Path $RomDir, (Join-Path $Work "nvram"), (Join-Path $Work "cfg") | Out-Null

if (-not $NoPackage) {
    Push-Location $Root
    try {
        python makerom.py | Out-Host
        python mamerom.py --source-video --no-install --output (Join-Path $RomDir "mk2.zip") | Out-Host
    } finally { Pop-Location }
}

$map = @{}
foreach ($line in (python (Join-Path $Root "sym_resolve.py") --dump)) {
    if ($line -match '^\s*([0-9a-fA-F]{8})\s+(\S+)\s*$') { $map[$Matches[2]] = $Matches[1] }
}
$want = @{ BT_GSTATE='gstate'; BT_P1_CHAR='p1_char'; BT_P2_CHAR='p2_char'; BT_P1_OBJ='p1_obj'; BT_P2_OBJ='p2_obj';
           BT_P1_PROC='p1_proc'; BT_P1_BAR='p1_bar'; BT_P2_BAR='p2_bar'; BT_FREEZE='f_freeze_timer' }
foreach ($k in $want.Keys) {
    $v = $map[$want[$k]]
    if (-not $v) { Write-Error "[bt] $($want[$k]) not in the map"; exit 2 }
    Set-Item -Path "env:$k" -Value $v
}

$names = @{ 0='Kung Lao'; 1='Liu Kang'; 2='Cage'; 3='Baraka'; 4='Kitana'; 6='Shang'; 10='Scorpion'; 11='Jax' }
foreach ($c in ($Chars -split ',')) {
    $c = [int]$c
    $log = Join-Path $Work "bt_$c.log"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $Work "nvram\*") -ErrorAction SilentlyContinue
    $env:BT_CHAR = "$c"
    $env:BT_LOG = $log
    $args_ = @("-rompath", $RomDir, "mk2", "-window", "-nomaximize", "-video", "gdi", "-nothrottle",
               "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
               "-nvram_directory", (Join-Path $Work "nvram"), "-cfg_directory", (Join-Path $Work "cfg"),
               "-autoboot_script", (Join-Path $Tools "bplus_timing_test.lua"),
               "-seconds_to_run", $BackstopSec)
    $out = Join-Path $Work "mame_$c.log"
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $args_ -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Tools "mame_dismiss_warning.ps1"),
        "-ProcessId", $proc.Id, "-ReadyFile", $log, "-TimeoutSec", 40) | Out-Null
    $proc | Wait-Process -Timeout ($BackstopSec + 60) -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "== $($names[$c]) ($c)"
    if (-not (Test-Path $log)) { Write-Host "   NO VERDICT - no lua log; see $out"; continue }
    Get-Content $log | Select-String -Pattern "^\[bt\] (hit|whiff|NO VERDICT)" | ForEach-Object { "   " + $_.Line }
}
