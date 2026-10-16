# run_wolf_court_throne.ps1 - THE COURTYARD's throne (Wolf, curback 01Dh):
# Shang Tsung sits on it unless he is one of the two fighters, in which case
# it is EMPTY (mk1c_throne, MK1CRT.ASM).  Three real 1P games on
# rom/wolf/umk3.zip through run_wolf_boot_probe.ps1 + wolf_court_throne.lua:
#   none  Liu Kang vs Cage      -> seated
#   p1    Shang Tsung vs Cage   -> empty
#   p2    Liu Kang vs Shang     -> empty   (the CPU's Shang counts too)
# -Negative crosses the expectation with the ROM untouched: all three must FAIL.
# Every address and SAG is read out of the Wolf build (tmp\wolf\src), so a
# rebuild cannot leave it measuring a stale number.  Private nvram/cfg per run.
param([switch]$Negative, [string[]]$Only = @("none", "p1", "p2"))
$Root = Split-Path -Parent $PSScriptRoot
$Src  = Join-Path $Root "tmp\wolf\src"
$Map  = Join-Path $Src "MK2.MAP"
function MapAddr($name) {
    $m = Select-String -Path $Map -CaseSensitive -Pattern ("(?:^|\s)([0-9a-fA-F]{8}) +" + $name + "(?:\s|$)") | Select-Object -First 1
    if (-not $m) { throw "symbol $name not in $Map" }
    $m.Matches[0].Groups[1].Value
}
function TblSag($name) {
    $l = Get-Content (Join-Path $Src "MK1CYM.TBL")
    $i = [array]::IndexOf($l, "${name}:")
    if ($i -lt 0) { throw "$name not in MK1CYM.TBL" }
    if ($l[$i + 2] -notmatch '\.long\s+0?([0-9a-fA-F]{8})H') { throw "no SAG under $name" }
    $Matches[1]
}
function Equ($name) {
    $m = Select-String -Path (Join-Path $Src "MK1CRTB.ASM") -Pattern ("^" + $name + "\s+\.set\s+(\d+)") | Select-Object -First 1
    if (-not $m) { throw "$name not in MK1CRTB.ASM" }
    $m.Matches[0].Groups[1].Value
}
$common = @(("WT_LST=" + (MapAddr "mk1c_th_lst")), ("WT_CURBACK=" + (MapAddr "curback")),
            ("WT_P1CHAR=" + (MapAddr "p1_char")), ("WT_P2CHAR=" + (MapAddr "p2_char")),
            ("WT_SEAT=" + (TblSag "MK1CYTHRN")), ("WT_EMPTY=" + (TblSag "MK1CYTHRNE")),
            ("WT_X=" + (Equ "mk1c_th_x")), ("WT_Y=" + (Equ "mk1c_th_y")))
$cases = @{ none = @(1, 2, "seat"); p1 = @(6, 2, "empty"); p2 = @(1, 6, "empty") }   # ft_kang 1, ft_cage 2, ft_st 6
$fail = 0
foreach ($c in $Only) {
    $p1, $p2, $want = $cases[$c]
    if ($Negative) { $want = if ($want -eq "seat") { "empty" } else { "seat" } }
    $out = "tmp\wolf_court_throne\$c"
    & (Join-Path $PSScriptRoot "run_wolf_boot_probe.ps1") -Script wolf_court_throne.lua -Out $out `
        -Env ($common + @("WT_P1=$p1", "WT_P2=$p2", "WT_WANT=$want")) | Out-Null
    $log = Get-Content (Join-Path $Root "$out\probe.log") -ErrorAction SilentlyContinue
    $verdict = if ($log) { $log[-1] } else { "NO LOG" }
    Write-Host ("[throne] {0,-4} p1={1} p2={2} want {3,-5} -> {4}" -f $c, $p1, $p2, $want, $verdict)
    $log | Select-String "throne obj|samples|fight at" | ForEach-Object { Write-Host "         $_" }
    $expect = if ($Negative) { "FAIL" } else { "PASS" }
    if ($verdict -ne $expect) { $fail++ }
}
if ($fail) { Write-Host "[throne] $fail case(s) did not come out as expected"; exit 1 }
Write-Host ("[throne] all cases " + $(if ($Negative) { "FAILED, as the crossed control must" } else { "PASS" }))
