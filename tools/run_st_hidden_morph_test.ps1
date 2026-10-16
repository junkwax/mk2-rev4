param(
    [ValidateSet("unlocked", "locked")]
    [string]$Mode = "unlocked",
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [int]$Stage = 5,
    # Which select-screen alternate Shang was picked in - the @alt_pal_owner
    # bit for P1.  "default" is his own costume; the rest prove stmorph_defpal:
    # a morph must land on the TARGET's default whichever of these is set.
    [ValidateSet("default", "block", "lp", "hp", "hk", "lk", "coin")]
    [string]$Costume = "default",
    [switch]$NoSnaps,
    [switch]$Sound
)

# Shang Tsung's Jade / Ermac morphs (stmorph_hidden) and their unlock gate,
# plus his RAIN morph (stmorph_rain), which has no gate at all.
# See tools/st_hidden_morph_test.lua for what each -Mode proves.
#
# Unlike run_st_unmorph_test.ps1 this does NOT kill every running MAME on the
# way in: other sessions' rigs share this machine.  It only clears its own
# leftover jobs.

$ErrorActionPreference = "Stop"
Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "st_hidden_morph_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $Root "tmp\st_hidden_morph\$Mode`_$Costume`_$RunId"
$SnapDir = Join-Path $OutDir "snap"
$LogPath = Join-Path $OutDir "st_hidden_morph.log"
New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null

$saved = @{}
foreach ($k in "MK2_ROOT", "ST_HM_LOG", "ST_HM_MODE", "ST_HM_STAGE", "ST_HM_SNAPS", "ST_HM_COSTUME") {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
$env:MK2_ROOT = $Root
$env:ST_HM_LOG = $LogPath
$env:ST_HM_MODE = $Mode
$env:ST_HM_STAGE = [string]$Stage
$env:ST_HM_SNAPS = if ($NoSnaps) { "0" } else { "1" }
$CostumeBits = @{ default = 0; block = 1; lp = 16; hp = 4; hk = 64; lk = 256; coin = 1024 }
$env:ST_HM_COSTUME = [string]$CostumeBits[$Costume]

try {
    $runArgs = @{
        Mame = $Mame
        RomPath = $RomPath
        Machine = "mk2"
        Resolution = $Resolution
        Script = $LuaScript
        SnapshotDirectory = $SnapDir
        OutputDirectory = $OutDir
        Video = "gdi"
        Wait = $true
    }
    if (-not $Sound) { $runArgs.NoSound = $true }
    Write-Host "[st-hmorph] mode=$Mode costume=$Costume rom=$RomPath -> $OutDir"
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$k" $saved[$k] }
    }
}

if (Test-Path $LogPath) {
    Get-Content $LogPath | Select-String -Pattern "check |morph_read|palette=|costume:|WARN|ERROR|fight_start|results|want=|PASS|FAIL" | ForEach-Object { $_.Line }
} else {
    Write-Host "[st-hmorph] FAIL no log written"
}
