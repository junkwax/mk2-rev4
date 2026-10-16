# run_scorpion_swipe_test.ps1 - SCORPION'S Back+HP SWORD SLASH (do_sc_swipe, MKSCSW.ASM)
#
# Packages a PRIVATE zip from the current link (never installs), runs MAME on
# it with a private nvram/cfg, and drives tools/scorpion_swipe_test.lua: three
# trials (P2 standing / ducking / blocking).  Addresses are resolved out of
# src/mk2.map every run.  Exit 0 PASS, 1 FAIL, 2 NO VERDICT.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [int]$Gap = 85,
    [switch]$NoPackage,
    [switch]$Negative,
    [string]$Costume = "",
    [int]$BackstopSec = 240
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root  = Split-Path -Parent $Tools
$Work  = Join-Path $Root "tmp\scorpion_swipe"
$RomDir = Join-Path $Work "rom"
$Log   = Join-Path $Tools "scorpion_swipe_test.log"
New-Item -ItemType Directory -Force -Path $RomDir, (Join-Path $Work "nvram"), (Join-Path $Work "cfg"), (Join-Path $Work "snap") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Work "nvram\*") -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

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
$want = @{ SS_GSTATE='gstate'; SS_P1_CHAR='p1_char'; SS_P1_OBJ='p1_obj'; SS_P2_OBJ='p2_obj';
           SS_P1_PROC='p1_proc'; SS_P2_PROC='p2_proc'; SS_P1_BAR='p1_bar'; SS_P2_BAR='p2_bar';
           SS_FREEZE='f_freeze_timer'; SS_OBJLST='objlst'; SS_OBJLST2='objlst2'; SS_OBJLST3='objlst3'; SS_ACTIVE='active'; SS_SWIPE='do_sc_swipe'; SS_PALRAM='palram'; SS_ROPE='ROPE_P' }
foreach ($k in $want.Keys) {
    $v = $map[$want[$k]]
    if (-not $v) { Write-Error "[ss] $($want[$k]) not in the map"; exit 2 }
    Set-Item -Path "env:$k" -Value $v
}
$env:SS_GAP = "$Gap"
$env:SS_COSTUME = $Costume
$env:SS_NEG = $(if ($Negative) { "1" } else { "0" })
$env:SS_LOG = $Log

$args_ = @("-rompath", $RomDir, "mk2", "-window", "-nomaximize", "-video", "gdi",
           "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
           "-nvram_directory", (Join-Path $Work "nvram"), "-cfg_directory", (Join-Path $Work "cfg"),
           "-snapshot_directory", (Join-Path $Work "snap"),
           "-autoboot_script", (Join-Path $Tools "scorpion_swipe_test.lua"),
           "-seconds_to_run", $BackstopSec)
$out = Join-Path $Work "mame_out.log"
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $args_ -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError "$out.err"
Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Tools "mame_dismiss_warning.ps1"),
    "-ProcessId", $proc.Id, "-ReadyFile", $Log, "-TimeoutSec", 40) | Out-Null
$proc | Wait-Process -Timeout ($BackstopSec + 60) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

if (-not (Test-Path $Log)) { Write-Host "[ss] NO VERDICT - no lua log; see $out"; exit 2 }
Get-Content $Log | Select-String -Pattern "^\[ss\] (stand|duck|block|RESULT|negative|.*firing|.*never)" | ForEach-Object { $_.Line }
Write-Host "[ss] snapshots: $(Join-Path $Work 'snap')"
if (Select-String -Path $Log -Pattern "RESULT PASS" -Quiet) { exit 0 }
if (Select-String -Path $Log -Pattern "RESULT FAIL" -Quiet) { exit 1 }
exit 2
