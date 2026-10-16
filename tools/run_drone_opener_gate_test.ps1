param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 120,
    [string]$Only = ""
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_opener_gate_test.lua"
$Log = Join-Path $ToolsDir "drone_opener_gate_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# ft index -> the act_* the opener produces (MAINEQU.ASM)
$cases = @(
  @{ch=0;  act=0x010b; l="kunglao_backfist"},
  @{ch=1;  act=0x010c; l="liukang_backfist"},
  @{ch=2;  act=0x010d; l="cage_ppunch"},
  @{ch=11; act=0x0110; l="jax_powerpunch"}
)

$results = @()
foreach ($c in $cases) {
  if ($Only -and ($c.l -notmatch [regex]::Escape($Only))) { continue }
  Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
  $env:GATE_CHAR = "$($c.ch)"; $env:GATE_ACT = "$($c.act)"
  $env:GATE_LABEL = $c.l;      $env:GATE_LOG = $Log
  $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
    "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
    "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
  Write-Host ("[gate] {0,-20} char={1} act=0x{2:x4} ..." -f $c.l,$c.ch,$c.act)
  Push-Location (Split-Path -Parent $Mame)
  try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_opener_gate_mame.log") } finally { Pop-Location }
  $verdict = "NO-VERDICT"
  if (Test-Path $Log) {
    $tail = Get-Content $Log
    if ($tail | Select-String "PASS $([regex]::Escape($c.l)):" -Quiet) { $verdict = "PASS" }
    else {
      $f = $tail | Select-String "FAIL $([regex]::Escape($c.l)):" | Select-Object -Last 1
      if ($f) { $verdict = ($f.Line -replace ".*FAIL $([regex]::Escape($c.l)): ", "FAIL: ") }
    }
  }
  $results += [pscustomobject]@{ Case=$c.l; Verdict=$verdict }
  Write-Host ("        -> {0}" -f $verdict)
}
foreach ($e in @("GATE_CHAR","GATE_ACT","GATE_LABEL","GATE_LOG")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

Write-Host "`n===== DRONE OPENER GATE SUMMARY ====="
$results | Format-Table -AutoSize
$bad = ($results | Where-Object { $_.Verdict -ne "PASS" }).Count
Write-Host ("Cases: {0}  Pass: {1}  Issues: {2}" -f $results.Count, ($results.Count-$bad), $bad)
Write-Host "Full log: $Log"
