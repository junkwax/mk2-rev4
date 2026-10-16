# run_flybrain_vs_stream.ps1 - two fruit flies fight each other, live, for streaming.
#
# Wraps run_flybrain_selfplay.ps1 in the same self-recovering loop as the single-player stream:
# any exit (a crash, a hang caught by the watchdog, MAME dying) starts a fresh session with the
# brains exactly where they had got to, and the window comes back at the same size every time.
#
# The two flies play different STYLES on purpose - two copies of one brain chose the same moves
# in the same spots and mirrored each other. A is a BRAWLER (hot temperament, leans on attacks
# and specials), B a COUNTER-fighter (cool, leans on blocking, backing off and punishing). Each
# has its own small HUD in its own top corner, under its life bar.
#
#   .\tools\run_flybrain_vs_stream.ps1                          # newest trained brain for both
#   .\tools\run_flybrain_vs_stream.ps1 -StyleB aggressive       # brawler vs brawler
#   .\tools\run_flybrain_vs_stream.ps1 -Resolution 1280x960     # smaller window
#
# End it by creating a STOP file in the stream folder (closing the window just restarts it).
param(
    [string]$BrainA = "",                # default: the newest frozen exam snapshot of fly2
    [string]$BrainB = "",                # default: the same brain - the STYLES make the difference
    [string]$StyleA = "aggressive",
    [string]$StyleB = "counter",
    [string]$NameA = "VINEGAR",           # shown in fly A's HUD
    [string]$NameB = "DISH SOAP",
    # big enough that viewers can read the HUDs; 1760x1320 is the largest 4:3 window that sits
    # above the taskbar on a 2560x1440 screen
    [string]$Resolution = "1760x1320",
    [int]$Minutes = 600,
    [int]$MaxRestarts = 20
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = "C:\tmp\flybrain\vs_stream_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Force $Root | Out-Null
if (-not $BrainA) {
    $snap = Get-ChildItem "C:\tmp\flybrain\fly2\exams" -Filter "brain_seg*.lua" | Sort-Object Name | Select-Object -Last 1
    if (-not $snap) { throw "no trained brain found - pass -BrainA" }
    $BrainA = $snap.FullName
}
if (-not $BrainB) { $BrainB = $BrainA }
# the stream learns into its OWN copies, so training brains are never touched
$curA = Join-Path $Root "brain_a.lua"; $curB = Join-Path $Root "brain_b.lua"
Copy-Item $BrainA $curA; Copy-Item $BrainB $curB
Write-Host "[vs-stream] A $StyleA, B $StyleB, from $BrainA   output: $Root"

$env:FS_NAME_A = $NameA; $env:FS_NAME_B = $NameB
$quick = 0
for ($part = 1; $part -le ($MaxRestarts + 1); $part++) {
    $out = Join-Path $Root ("part{0:D2}" -f $part)
    $started = Get-Date
    & (Join-Path $Tools "run_flybrain_selfplay.ps1") -Out $out -BrainA $curA -BrainB $curB -StyleA $StyleA -StyleB $StyleB `
        -Minutes $Minutes -Seed (Get-Random -Minimum 1 -Maximum 1000000) -Watch -Overlay -Maximize `
        -WatchdogSeconds 180 | Out-Null
    # carry the learning forward: the part learned into its own copies of the brains
    foreach ($pair in @(@("brain_a.lua", $curA), @("brain_b.lua", $curB))) {
        $learned = Join-Path $out $pair[0]
        if (Test-Path $learned) { Copy-Item $learned $pair[1] -Force }
    }
    $ran = ((Get-Date) - $started).TotalSeconds
    if (Test-Path (Join-Path $Root "STOP")) { Write-Host "[vs-stream] STOP file - stream over"; break }
    if ($ran -lt 60) {
        $quick++
        if ($quick -ge 2) { Write-Host "[vs-stream] two immediate exits - stopping rather than looping"; break }
    } else { $quick = 0 }
    Write-Host ("[vs-stream] part {0} ended after {1:N0}s - restarting with both flies' latest brains" -f $part, $ran)
}
