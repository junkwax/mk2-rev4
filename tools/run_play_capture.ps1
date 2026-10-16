<#
  run_play_capture.ps1 - play the game NORMALLY with the freeze probe riding along,
  so the next crash is DIAGNOSED instead of described.

  gstate5_probe.lua only watches - it drives no inputs and changes no state, so this
  is an ordinary cabinet session. When the game wedges it dumps every live process,
  where each is parked, the CPU PC and the trap frame at SP (which names the faulting
  code), plus every guard counter the moment it moves.

  G5_ANY=1 is set here on purpose: the known post-round park is gstate 5, but
  "both fighters gone and the background half-drawn" can wedge in any state, so this
  watches the things that always move in a live game (bars, positions, round) rather
  than one state.

  The ROM warning box ("press any key to continue") is a permanent fact of a
  source build - CRC32 is spoofed but SHA1 can never be - so dismiss it yourself
  with a key press when it appears, same as always.

    pwsh -File tools/run_play_capture.ps1
    pwsh -File tools/run_play_capture.ps1 -Tag kunglao_round3
#>
param(
  [string]$Tag  = "play",
  [string]$Rom  = "mk2",
  [string]$Mame = "C:\MAME\mame.exe",
  [int]$AnyHold = 900     # ~16 s of nothing moving before it calls it a freeze
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$map  = Join-Path $root "src\mk2.map"
$log  = Join-Path $root ("tools\play_capture_{0}.txt" -f $Tag)

if (-not (Test-Path $Mame)) { throw "no MAME at $Mame" }
if (-not (Test-Path $map))  { throw "no src/mk2.map - the probe cannot name addresses without it" }

# A map from another build reads every symbol at the wrong address and reports
# nothing wrong, so refuse a map older than the ROM it is being read against.
$zip = Join-Path "C:\MAME\roms" ("{0}.zip" -f $Rom)
if (Test-Path $zip) {
  $mapT = (Get-Item $map).LastWriteTime
  $zipT = (Get-Item $zip).LastWriteTime
  Write-Host ("map  {0:yyyy-MM-dd HH:mm}   {1}" -f $mapT, $map)
  Write-Host ("rom  {0:yyyy-MM-dd HH:mm}   {1}" -f $zipT, $zip)
  if ($mapT -lt $zipT.AddMinutes(-5)) {
    Write-Warning "src/mk2.map is OLDER than $zip - symbol names in the dump will be wrong. Rebuild or re-install before trusting a capture."
  }
}

$env:MK2_ROOT   = $root
$env:G5_MAP     = $map
$env:G5_LOG     = $log
$env:G5_ANY     = "1"
$env:G5_ANY_HOLD= "$AnyHold"

Write-Host ""
Write-Host "probe log -> $log"
Write-Host "Play normally. When it wedges, LEAVE IT SITTING for ~20 s so the probe"
Write-Host "can dump, then close MAME and report the log."
Write-Host ""

# Run with C:\MAME as the working directory, exactly as a normal session does:
# launched from the repo instead, MAME reads the repo's own cfg/nvram (whose
# committed TEST switch boots straight into the diagnostic menu) and finds no
# roms at all. See reference_mame_repo_cwd_cfg_trap.
$mameDir = Split-Path -Parent $Mame
Push-Location $mameDir
try {
& $Mame $Rom -window -nomax -rompath (Join-Path $mameDir "roms") `
    -autoboot_script (Join-Path $PSScriptRoot "gstate5_probe.lua")
} finally { Pop-Location }
Write-Host ""
if (Test-Path $log) {
  $dumps = (Select-String -Path $log -Pattern "^=== " -ErrorAction SilentlyContinue).Count
  $guards= (Select-String -Path $log -Pattern "^guard fired" -ErrorAction SilentlyContinue).Count
  Write-Host ("capture done: {0} freeze dump(s), {1} guard line(s)  ->  {2}" -f $dumps, $guards, $log)
  if ($dumps -eq 0 -and $guards -eq 0) { Write-Host "nothing fired - no freeze and no guard tripped this session." }
} else {
  Write-Warning "no probe log written - the lua script never armed (did MAME reach frame 1?)."
}
