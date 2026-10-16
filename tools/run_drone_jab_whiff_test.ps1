param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string[]]$Char = @("liukang"),
    [int]$Diff = 9,
    [string]$Gaps = "60,78,86,95,120",
    [int]$Backstop = 220
)
# "The CPU keeps throwing a low punch that cannot reach me."
#
# Pins both fighters at a series of fixed gaps and counts, per gap, how many
# of the drone's low punches connect and how many sweeps follow the ones that
# do not.  PASS wants: at whatever gap the jabs all whiff, sweeps appear.
# See tools/drone_jab_whiff_test.lua for what each phase is asking.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_jab_whiff_test.lua"
$Log = Join-Path $ToolsDir "drone_jab_whiff_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

$CHARS = @{ hathead=0; liukang=1; cage=2; baraka=3; kitana=4; mileena=5; shang=6;
            raiden=7; subzero=8; reptile=9; scorpion=10; jax=11 }

$results = @()
foreach ($c in $Char) {
  if (-not $CHARS.ContainsKey($c)) { Write-Host "[whiff] unknown char '$c'"; continue }
  Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

  $env:WHIFF_CHAR = "$($CHARS[$c])"
  $env:WHIFF_LABEL = $c
  $env:WHIFF_LOG = $Log
  $env:WHIFF_DIFF = "$Diff"
  $env:WHIFF_GAPS = $Gaps

  $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
    "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
    "-cfg_directory","C:\MAME\cfg",
    "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
  Write-Host ("[whiff] {0,-10} diff={1} gaps={2} ..." -f $c,$Diff,$Gaps)
  Push-Location (Split-Path -Parent $Mame)
  try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_jab_whiff_mame.log") } finally { Pop-Location }

  $verdict = "NO-VERDICT"
  if (Test-Path $Log) {
    $tail = Get-Content $Log
    if ($tail | Select-String "PASS $([regex]::Escape($c)):" -Quiet) { $verdict = "PASS" }
    else {
      $f = $tail | Select-String "(FAIL|INVALID) $([regex]::Escape($c)):" | Select-Object -Last 1
      if ($f) { $verdict = ($f.Line -replace ".*\[whiff\] ", "") }
    }
  }
  $results += [pscustomobject]@{ Char=$c; Verdict=$verdict }
  Write-Host ("        -> {0}" -f $verdict)
}
foreach ($e in @("WHIFF_CHAR","WHIFF_LABEL","WHIFF_LOG","WHIFF_DIFF","WHIFF_GAPS")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

Write-Host "`n===== DRONE JAB-WHIFF SUMMARY ====="
$results | Format-Table -AutoSize
Write-Host "Full log: $Log"
