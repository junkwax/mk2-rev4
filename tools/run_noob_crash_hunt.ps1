# run_noob_crash_hunt.ps1 - hunt the reported Reptile-vs-Noob lockup.
#
# The stock battle sweep passes this matchup because it presses nothing.  This
# runs the same battles with tools/sweep_addon_fuzz.lua armed (random P1 input
# from a seeded PRNG, plus the process-stack bounds probe) across many seeds,
# because the ROM's @rand reseeds identically every round - varying the SEED is
# the only way to get a different fight out of the same matchup.
param(
  [int]$From = 7,
  [int]$To = 24,
  [string]$Only = "reptile_noob",
  [int]$Observe = 3000,
  [int]$Backstop = 170
)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Copy-Item (Join-Path $root "tools\sweep_addon_fuzz.lua") (Join-Path $root "tools\sweep_addon.lua") -Force
$out = Join-Path $root "tools\noob_crash_hunt.log"
Remove-Item $out -Force -ErrorAction SilentlyContinue
foreach ($s in $From..$To) {
  $env:FUZZ_SEED = "$s"
  $r = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\run_battle_stability_sweep.ps1") `
        -Only $Only -Observe $Observe -Backstop $Backstop -NoHpPin 2>&1
  $lines = $r | Select-String "->|ANOMALY|FAULT"
  "seed $s"        | Tee-Object -FilePath $out -Append
  $lines           | Tee-Object -FilePath $out -Append
}
Write-Host "done - $out"
