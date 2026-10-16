<#
.SYNOPSIS
  You vs Shao Kahn at max difficulty, with every input and every exchange
  recorded so his exploits can be found and closed.

.DESCRIPTION
  Boots straight into the Kahn fight (auto coin + start), then hands the
  controls over completely - nothing is injected once you are at the select
  screen. Pick your fighter normally; Kahn, the arena and the difficulty are
  forced for you.

  Two logs land in tools/kahn_spar_logs/:
    <id>_events.log  your moves, his answers, every hit with the range
    <id>_inputs.log  raw pad trace, frame-stamped, for reproducing a run

  In-game hotkeys (MAME window focused):
    F5  mark "that was an exploit" at this exact frame
    F6  print the move-by-move summary now
    F7  reset the stats

  Default MAME keyboard for P1: arrows = stick, A/S/D/space/Z etc. depend on
  your mame.ini - press TAB in MAME to check or remap.

.EXAMPLE
  .\tools\run_kahn_spar.ps1
  .\tools\run_kahn_spar.ps1 -Char 10        # force Scorpion
  .\tools\run_kahn_spar.ps1 -Diff 5         # spar at a lower difficulty
#>
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Diff = 9,
    [int]$Char = -1,                 # -1 = pick your own on the select screen
    [string]$Resolution = "1280x960",
    [switch]$NoSound
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $ToolsDir
$Lua      = Join-Path $ToolsDir "kahn_spar.lua"
$LogDir   = Join-Path $ToolsDir "kahn_spar_logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$base  = Join-Path $LogDir $runId

$env:KAHN_SPAR_ROOT = $Root
$env:KAHN_SPAR_LOG  = ($base -replace '\\','/')
$env:KAHN_SPAR_DIFF = "$Diff"
if ($Char -ge 0) { $env:KAHN_SPAR_CHAR = "$Char" } else { Remove-Item Env:\KAHN_SPAR_CHAR -ErrorAction SilentlyContinue }

Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Banked credits desync the scripted boot; start from cold CMOS.
Remove-Item "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

# Claim the MAME lock for the whole session.  Every automated harness in this
# tree opens by force-killing mame.exe, so an agent starting a ladder run
# mid-session will kill YOUR fight out from under you - which is exactly what
# happened.  run_kahn_ladder_test.ps1 refuses to start while this file exists.
$LockFile = Join-Path $ToolsDir ".mame-in-use.lock"
Set-Content -LiteralPath $LockFile -Value "spar session PID=$PID started $(Get-Date -Format o)"
try {

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution",$Resolution,
    "-keyboardprovider","win32","-skip_gameinfo","-autoboot_script",$Lua)
if ($NoSound) { $mameArgs += @("-sound","none") }

Write-Host ""
Write-Host "  YOU vs SHAO KAHN   (difficulty $Diff)" -ForegroundColor Cyan
Write-Host "  F5 = mark an exploit   F6 = summary   F7 = reset stats"
Write-Host "  events: $base`_events.log"
Write-Host "  inputs: $base`_inputs.log"
Write-Host ""
Write-Host "  Play as long as you like, then close MAME (Esc) and tell me to read the log."
Write-Host ""

& $Mame @mameArgs
Write-Host ""
Write-Host "[spar] session over. Logs:"
Get-ChildItem "$base*" | ForEach-Object { Write-Host "   $($_.FullName)  ($($_.Length) bytes)" }

}
finally {
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}
