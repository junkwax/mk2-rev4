# run_wolf_vrom_reach_test.ps1 - can MK2's sprite DMA draw from video ROM
# above its own 12 MB on the Wolf board?  (doc/WOLF_SPACE.md)
#
# One title-screen sprite is moved: its pixels are copied up by -Delta bytes in
# MAME's video region and its header (program ROM) repointed at the copy, at
# frame 1, before anything is built.  Three deterministic runs, same frame:
#   control - unpatched
#   copy    - copied + repointed     -> MUST be pixel-identical to control
#   nocopy  - repointed, not copied  -> MUST differ (or the sprite was not drawn)
# The SAG/header defaults are this build's census pick (wolf_vrom_reach_test.lua
# WR_MODE=census); a different build moves them and the lua refuses to patch.
param(
    [string[]]$Delta = @("C00000", "1400000"),   # 12 MB (u118-u121), 20 MB (u110-u113)
    [string]$Sag = "04725AF8",
    [string]$RomOfs = "C22AC",
    [string]$Len = "20000",
    [int]$Bank = 1,          # thunder1 (MKFX.TBL) is in a bank-1 pack
    [int]$Snap = 400
)
$Root = Split-Path -Parent $PSScriptRoot
$Base = Join-Path $Root "tmp\wolf_reach"
function Run($mode, $delta) {
    $out = Join-Path $Base "$mode`_$delta"
    & (Join-Path $PSScriptRoot "run_wolf_boot_probe.ps1") -Script wolf_vrom_reach_test.lua -Out $out `
        -Env "WR_MODE=$mode","WR_SAG=$Sag","WR_ROMOFS=$RomOfs","WR_DELTA=$delta","WR_LEN=$Len","WR_BANK=$Bank","WR_SNAP=$Snap" | Out-Null
    $png = Get-ChildItem (Join-Path $out "snap") -Recurse -Filter *.png | Select-Object -First 1
    $line = Get-Content (Join-Path $out "probe.log") -ErrorAction SilentlyContinue | Select-String "snap f=" | Select-Object -First 1
    return @{ png = $png.FullName; log = "$line" }
}
$ctl = Run "control" "0"
$fail = 0
foreach ($d in $Delta) {
    $cp = Run "copy" $d
    $nc = Run "nocopy" $d
    $res = python -c @"
from PIL import Image, ImageChops
import sys
a, b, c = (Image.open(p).convert('RGB') for p in sys.argv[1:4])
same = ImageChops.difference(a, b).getbbox() is None
moved = ImageChops.difference(a, c).getbbox()
print(('COPY-IDENTICAL' if same else 'COPY-DIFFERS'), ('NOCOPY-DIFFERS ' + str(moved)) if moved else 'NOCOPY-IDENTICAL')
"@ $ctl.png $cp.png $nc.png
    $ok = ($res -match '^COPY-IDENTICAL NOCOPY-DIFFERS')
    if (-not $ok) { $fail++ }
    Write-Host ("delta {0,8} (video byte offset +{0}h): {1}  {2}" -f $d, $res, $(if ($ok) { "PASS" } else { "FAIL" }))
    Write-Host ("    copy:   " + $cp.log)
    Write-Host ("    nocopy: " + $nc.log)
}
if ($fail) { exit 1 }
