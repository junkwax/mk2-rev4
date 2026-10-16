param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 150,
    [string]$Only = ""
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "backhp_standing_test.lua"
$Log = Join-Path $ToolsDir "backhp_standing_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# ft index -> act_* the character's back+HP produces (MAINEQU.ASM)
#   liukang/kunglao/cage/jax = the four we added (gated in char_hi_punch)
#   baraka/kitana            = stock power punches (gated in joy_power_punch)
#   shang/raiden were NEVER gated at all - sthp11 and rdhp_normal tested only
#   is_stick_away. Raiden's is a zap so it lands anywhere in the 001h-016h
#   projectile block rather than on one fixed action id.
$cases = @(
  @{ch=1;  act=0x010c; l="liukang_backfist"},
  @{ch=0;  act=0x010b; l="kunglao_backfist"},
  @{ch=2;  act=0x010d; l="cage_ppunch"},
  @{ch=11; act=0x0110; l="jax_powerpunch"},
  @{ch=3;  act=0x011e; l="baraka_swipe"},
  @{ch=4;  act=0x0120; l="kitana_fanswipe"},
  @{ch=6;  act=0x0206; l="shang_roundpunch"},
  @{ch=7;  act=0x0001; hi=0x0016; l="raiden_shortbolt"}
)

$results = @()
foreach ($c in $cases) {
  if ($Only -and ($c.l -notmatch [regex]::Escape($Only))) { continue }
  Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
  $env:BHP_CHAR = "$($c.ch)"; $env:BHP_ACT = "$($c.act)"
  $env:BHP_LABEL = $c.l;      $env:BHP_LOG = $Log
  if ($c.ContainsKey('hi')) { $env:BHP_ACT_HI = "$($c.hi)" }
  else { Remove-Item "Env:\BHP_ACT_HI" -ErrorAction SilentlyContinue }
  $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
    "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
    "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
  Write-Host ("[bhp] {0,-20} char={1} act=0x{2:x4} ..." -f $c.l,$c.ch,$c.act)
  Push-Location (Split-Path -Parent $Mame)
  try { & $Mame @mameArgs *> (Join-Path $ToolsDir "backhp_standing_mame.log") } finally { Pop-Location }
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
foreach ($e in @("BHP_CHAR","BHP_ACT","BHP_ACT_HI","BHP_LABEL","BHP_LOG")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

Write-Host "`n===== BACK+HP STANDING-ONLY ====="
$results | Format-Table -AutoSize
$bad = ($results | Where-Object { $_.Verdict -ne "PASS" }).Count
Write-Host ("Cases: {0}  Pass: {1}  Issues: {2}" -f $results.Count, ($results.Count-$bad), $bad)
Write-Host "Full log: $Log"
