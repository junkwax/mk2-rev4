<#
.SYNOPSIS
  Drive a 1P game onto the MOUNTAIN (battle-plan / ladder screen) as a given
  fighter and prove it reaches the fight.

.DESCRIPTION
  The mountain runs at gstate 07 between the select screen and the round, and
  the only part of it that varies by fighter is his `mini_mug_table` row
  (MKSEL.ASM).  A mug whose palette is too big for `fadeproc` to stage inside
  a process block used to wedge the board there - see the comment above
  `fadeproc` in src/UTIL.ASM.

  PASS = gs_fighting reached.  FAIL/HANG = gstate 07 never moved; the log then
  carries the active process list and the last PCs.  Expect every PC to be in
  `prclsp`: the dispatcher stays alive, it just never finishes a scan.

  -Char takes an ft_ id (MAINEQU.ASM) or a name from the table below.  The
  fighter is forced by writing @p1_char after the select screen, so this works
  for fighters with no roster square of their own.

.EXAMPLE
  .\tools\run_ladder_char_probe.ps1                       # the four that matter
  .\tools\run_ladder_char_probe.ps1 -Char rain -Snap 8
  .\tools\run_ladder_char_probe.ps1 -Char rain -RunOn     # on through the rounds
#>
param(
    # A byte copy of mame.exe under its own NAME, so this rig and any other
    # MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [string[]]$Char = @("rain","ermac","jade","subzero"),
    [int]$End = 5000,
    [int]$Snap = 0,
    [switch]$RunOn,
    [int]$BackstopEmuSeconds = 150
)

$ErrorActionPreference = "Stop"

# ft_ ids from src/MAINEQU.ASM.  The default set is the one the 2026-09-23
# freeze turned on: rain/ermac carry the 8-bit mugs, jade/subzero are the
# controls that always worked.
$Ids = @{
    kunglao = 0;  liukang = 1;  cage = 2;  baraka = 3;  kitana = 4; mileena = 5
    shang   = 6;  raiden  = 7;  subzero = 8; reptile = 9; scorpion = 10; jax = 11
    kintaro = 12; kahn = 13; smoke = 14; noob = 15; jade = 16; ermac = 17
    khameleon = 18; rain = 19
}

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $ToolsDir
$Lua      = Join-Path $ToolsDir "ladder_char_probe.lua"
$Dismiss  = Join-Path $ToolsDir "mame_dismiss_warning.ps1"

# A zip older than the map it will be read against makes every symbol read
# land at the wrong address and reports nothing wrong.
$zip = Join-Path $RomPath "mk2.zip"
$map = Join-Path $Root "src\mk2.map"
if ((Test-Path $zip) -and (Test-Path $map)) {
    if ((Get-Item $zip).LastWriteTime -lt (Get-Item $map).LastWriteTime) {
        Write-Warning "$zip is OLDER than src\mk2.map - repackage before trusting this run."
    }
}

$results = @()
foreach ($c in $Char) {
    $id = if ($Ids.ContainsKey($c.ToLower())) { $Ids[$c.ToLower()] } else { [int]$c }
    $name = ($Ids.GetEnumerator() | Where-Object { $_.Value -eq $id } | Select-Object -First 1).Key
    if (-not $name) { $name = "char$id" }

    $log   = Join-Path $ToolsDir "ladder_char_$name.log"
    $ready = Join-Path $env:TEMP "ladder_char_$name.ready"
    Remove-Item -LiteralPath $log,$ready -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:LCP_CHAR  = [string]$id
    $env:LCP_LOG   = $log
    $env:LCP_READY = $ready
    $env:LCP_END   = [string]$End
    $env:LCP_SNAP  = [string]$Snap
    $env:LCP_RUNON = if ($RunOn) { "1" } else { "0" }

    $mameArgs = @(
        "-rompath", $RomPath, "mk2",
        "-window", "-nomaximize", "-resolution", $Resolution, "-video", "gdi",
        # Without an explicit keyboardprovider MAME parks on the red
        # "press any key" ROM warning and the Lua never loads at all.
        "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
        "-autoboot_script", $Lua,
        "-seconds_to_run", $BackstopEmuSeconds
    )

    Write-Host "[ladder] $name (ft_ $id) ..."
    $out = Join-Path $ToolsDir "ladder_char_mame_out.log"
    $proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -PassThru `
                          -WorkingDirectory (Split-Path -Parent $Mame) `
                          -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # The dismisser must be its own process, and its ReadyFile must NOT be the
    # Lua's log - that is opened at script load, before a frame has run.
    if (Test-Path $Dismiss) {
        Start-Process -FilePath "pwsh" -ArgumentList @(
            "-NoProfile","-File",$Dismiss,"-ProcessId",$proc.Id,"-ReadyFile",$ready,"-TimeoutSec","120"
        ) -WindowStyle Hidden | Out-Null
    }
    $proc.WaitForExit()

    $v = if (Test-Path $log) {
        (Select-String -Path $log -Pattern '^(PASS|FAIL)' | Select-Object -Last 1).Line
    } else { $null }
    if (-not $v) { $v = "NO VERDICT - see $log and $out" }
    $fade = if (Test-Path $log) {
        (Select-String -Path $log -Pattern 'OVER 94' | Select-Object -Last 1).Line
    } else { $null }
    Write-Host "  $v"
    if ($fade) { Write-Host "  $fade" }
    $results += [pscustomobject]@{ Char = $name; Id = $id; Verdict = $v }
}

foreach ($v in @("LCP_CHAR","LCP_LOG","LCP_READY","LCP_END","LCP_SNAP","LCP_RUNON")) {
    Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
}

$pass = ($results | Where-Object { $_.Verdict -like "PASS*" }).Count
Write-Host ""
Write-Host "[ladder] $pass/$($results.Count) PASS"
$results | Format-Table -AutoSize
