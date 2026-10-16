param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$TimeoutSeconds = 150,
    [switch]$NoSound,
    [switch]$StaticOnly
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Mkcanned = Join-Path $Root "src\MKCANNED.ASM"
$Mkst = Join-Path $Root "src\MKST.ASM"

function Assert-LaffSourceContract {
    $canned = Get-Content -LiteralPath $Mkcanned -Raw
    $victory = [regex]::Match($canned, '(?ms)^\s*st_victory\b.*?(?=^\s*lk_victory\b)')
    if (-not $victory.Success -or $victory.Value -notmatch '(?im)^\s*tsound\s+0ffh\b') {
        throw "[stlaff-run] Shang victory no longer contains its existing tsound 0ffh call: $Mkcanned"
    }
    if ($victory.Value -notmatch '(?im)^\s*(?:stv6\s+)?movi\s+000060029h,a9\b' -or
        $victory.Value -notmatch '(?im)^\s*jsrp\s+animate_a9\b') {
        throw "[stlaff-run] Shang victory is not using the stock six-tick victory cadence: $Mkcanned"
    }

    $mkst = Get-Content -LiteralPath $Mkst -Raw
    $table = [regex]::Match($mkst, '(?ms)^\s*a_stvictory\b.*?(?=^\s*STVIC1\b)')
    if (-not $table.Success) {
        throw "[stlaff-run] Could not find a_stvictory before STVIC1 in $Mkst"
    }
    $actual = @([regex]::Matches($table.Value, '(?im)^\s*\.long\s+STVIC([1-5])\b') |
        ForEach-Object { [int]$_.Groups[1].Value })
    $expected = @(2,3,4,5,4,3,4,5,4,5,4,3,2,3,4,3,1)
    if (($actual -join ',') -ne ($expected -join ',')) {
        throw "[stlaff-run] a_stvictory does not match native LAFF + STVIC1 order. Actual: $($actual -join ',')"
    }
    Write-Host "[stlaff-run] Source contract OK: 16 native LAFF entries, STVIC1 terminal pose; tsound 0ffh retained."
}

Assert-LaffSourceContract
if ($StaticOnly) {
    Write-Host "[stlaff-run] Static-only verification complete."
    return
}

$LuaScript = Join-Path $ToolsDir "shang_victory_laff_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapshotRoot = Join-Path $ToolsDir "screens\shang_victory_laff\run_$RunId"
$OutputRoot = Join-Path $ToolsDir "shang_victory_laff_out\run_$RunId"
$ReadoutRoot = Join-Path $ToolsDir "shang_victory_laff\run_$RunId"
$LogPath = Join-Path $ReadoutRoot "shang_victory_laff_test.log"
$CsvPath = Join-Path $ReadoutRoot "shang_victory_laff.csv"

New-Item -ItemType Directory -Force -Path $SnapshotRoot,$OutputRoot,$ReadoutRoot | Out-Null

$oldRoot = $env:MK2_ROOT
$oldLog = $env:SHANG_LAFF_LOG
$oldCsv = $env:SHANG_LAFF_CSV
$env:MK2_ROOT = $Root
$env:SHANG_LAFF_LOG = $LogPath
$env:SHANG_LAFF_CSV = $CsvPath

try {
    $runArgs = @{
        Mame = $Mame
        RomPath = $RomPath
        Machine = "mk2"
        Resolution = $Resolution
        Script = $LuaScript
        SnapshotDirectory = $SnapshotRoot
        OutputDirectory = $OutputRoot
        Video = "gdi"
        AutoCloseSeconds = $TimeoutSeconds
        Wait = $true
    }
    if ($NoSound) { $runArgs.NoSound = $true }
    Write-Host "[stlaff-run] Launching normal-win LAFF capture (sound=$(-not $NoSound))..."
    & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs
}
finally {
    if ($null -eq $oldRoot) { Remove-Item Env:\MK2_ROOT -ErrorAction SilentlyContinue } else { $env:MK2_ROOT = $oldRoot }
    if ($null -eq $oldLog) { Remove-Item Env:\SHANG_LAFF_LOG -ErrorAction SilentlyContinue } else { $env:SHANG_LAFF_LOG = $oldLog }
    if ($null -eq $oldCsv) { Remove-Item Env:\SHANG_LAFF_CSV -ErrorAction SilentlyContinue } else { $env:SHANG_LAFF_CSV = $oldCsv }
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "[stlaff-run] Lua log was not created: $LogPath"
}
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "[stlaff-run] Lua CSV was not created: $CsvPath"
}

$log = Get-Content -LiteralPath $LogPath -Raw
if ($log -notmatch '\[stlaff\] PASS reason=all_16_native_laff_samples') {
    Get-Content -LiteralPath $LogPath -Tail 100
    throw "[stlaff-run] Runtime LAFF review failed; see $LogPath"
}

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -ne 17) {
    throw "[stlaff-run] Expected 16 LAFF rows plus the STVIC1 terminal pose; found $($rows.Count)"
}
$expected = '12,13,14,15,14,13,14,15,14,15,14,13,12,13,14,13,11'
if (($rows.actual_stage -join ',') -ne $expected) {
    throw "[stlaff-run] Runtime stage order is not native LAFF followed by STVIC1: $($rows.actual_stage -join ',')"
}
$expectedTicks = @(0..16 | ForEach-Object { $_ * 6 })
$actualTicks = @($rows.laff_rel | ForEach-Object { [int]$_ })
if (($actualTicks -join ',') -ne ($expectedTicks -join ',')) {
    throw "[stlaff-run] LAFF samples were not captured six game ticks apart: $($actualTicks -join ',')"
}
$actualFrames = @($rows.emu_frame | ForEach-Object { [int]$_ })
$frameDeltas = @()
for ($i = 1; $i -lt $actualFrames.Count; $i++) {
    $frameDeltas += $actualFrames[$i] - $actualFrames[$i - 1]
}
if (($frameDeltas -join ',') -ne ((@(6) * 16) -join ',')) {
    throw "[stlaff-run] MAME frame deltas are not all six ticks: $($frameDeltas -join ',')"
}

$pngs = @(Get-ChildItem -LiteralPath (Join-Path $SnapshotRoot "mk2") -Filter '*.png' -ErrorAction SilentlyContinue |
    Sort-Object Name)
if ($pngs.Count -ne 17) {
    throw "[stlaff-run] Expected 17 LAFF/STVIC1 screenshots; found $($pngs.Count)"
}

Write-Host "[stlaff-run] PASS: 16 LAFF frames plus final STVIC1 pose reviewed."
Write-Host "[stlaff-run] Screenshots (0000-0016 match CSV rows): $SnapshotRoot"
Write-Host "[stlaff-run] CSV: $CsvPath"
Write-Host "[stlaff-run] Log: $LogPath"
