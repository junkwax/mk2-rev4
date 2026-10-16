# run_ani2_guard_test.ps1 - prove ani2's guards turn a lost list terminator
# from a cabinet reboot into a missing sprite, and that they never fire
# otherwise.
#
# The bug this is about: a multipart piece list that never reaches its zero
# made ani2 (MKUTIL.ASM) walk 112-bit nodes forward out of the object's shape
# RAM and across the rest of .bss - measured at 147 nodes, over ofree, gstate,
# p1_obj/p2_obj, both input queues and curback/diff/round_num.  With p1_obj
# pointing at rubbish, shadow_p1p2 read a node of 0ffffh, shadf scaled its
# height to 0fff9h rows and started a 65535 x 65529 blit; the DMA is still
# busy three minutes of machine time later, the cpu spins in shf8's idle wait,
# and the watchdog reboots the board.  See mp_max in src/DISPEQU.ASM.
#
# Waiting for it to happen on its own takes hours and depends on what the
# drone does, so this INJECTS it instead: one debugger command points ani2's
# list pointer at a long run of non-zero .text - which is what a lost
# terminator looks like from inside ani2 - and then removes itself.  Every-
# thing else about the runs is identical.
#
#   -Mode inject   one injected runaway.  PASS = the game plays on and
#                  @ani2_clip moved.  On a pre-fix ROM this wedges instead.
#   -Mode clean    no injection.  PASS = @ani2_clip never moves, i.e. the
#                  guards do not clip real art.
#
#   .\tools\run_ani2_guard_test.ps1 -Mode inject
#   .\tools\run_ani2_guard_test.ps1 -Mode clean -Minutes 30
#   .\tools\run_ani2_guard_test.ps1 -Mode inject -RomPath C:\tmp\some\oldrom
#
# -RomPath must hold BOTH mk2.zip and the matching mk2.map (the rig reads
# ani2 and ani2_clip out of it, and a mismatched map reads garbage - see
# doc/ and [[reference_mame_move_rig_traps]]).  A pre-fix ROM has no
# ani2_clip; the rig says so and falls back to "did the game survive".
param(
    [ValidateSet("inject", "clean")][string]$Mode = "inject",
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "",                 # default: this tree's own build
    [string]$Net = "C:\tmp\flybrain\out\flynet.lua",
    [string]$Brain = "C:\tmp\flybrain\train\full\brain.lua",
    [string]$Out = "",
    [int]$ArmFrame = 4000,                 # well inside battle 1 round 1
    [int]$Minutes = 5,
    [int]$Seed = 12345
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Tools

if (-not $RomPath) {
    # Stage this tree's build where the rig can point MAME at it.
    $RomPath = Join-Path $env:TEMP "ani2_guard_rom"
    New-Item -ItemType Directory -Force $RomPath | Out-Null
    $zip = Join-Path $Root "rom\mk2.zip"
    if (-not (Test-Path $zip)) { throw "no rom\mk2.zip - run makerom.py + mamerom.py first" }
    # A zip older than the link is a DIFFERENT ROM from the map beside it, and
    # the rig would then read every symbol at the wrong address and report
    # nothing wrong.  Refuse rather than produce a confident wrong answer.
    #
    # 120s of slack, the same tolerance tools/build_report.py uses: the linker
    # runs under DOSBox and stamps mk2.out/mk2.map with DOSBox's clock, so a
    # perfectly fresh package routinely looks a few seconds OLDER than the link
    # it came from.  A zero-tolerance test fails a healthy tree, which is worse
    # than no test - it teaches people to pass -RomPath to shut it up.
    $linkOut = Join-Path $Root "src\mk2.out"   # NOT $out: PowerShell
                                               #   variables are case-
                                               #   insensitive and $Out is
                                               #   the output directory
    $skew = ((Get-Item $linkOut).LastWriteTime - (Get-Item $zip).LastWriteTime).TotalSeconds
    if ($skew -gt 120) {
        throw ("rom\mk2.zip is {0:n0}s older than src\mk2.out - repackage it, or pass -RomPath" -f $skew)
    }
    Copy-Item $zip (Join-Path $RomPath "mk2.zip") -Force
    Copy-Item (Join-Path $Root "src\mk2.map") (Join-Path $RomPath "mk2.map") -Force
}
foreach ($f in @("$RomPath\mk2.zip", "$RomPath\mk2.map", $Net, $Brain)) {
    if (-not (Test-Path $f)) { throw "missing $f" }
}
if (-not $Out) { $Out = Join-Path $env:TEMP "ani2_guard_$Mode`_$(Get-Date -Format HHmmss)" }
New-Item -ItemType Directory -Force "$Out\snap", "$Out\nvram", "$Out\cfg" | Out-Null
Set-Content "$Out\go.ds" "g"

# Addresses come from the map that ships with the ROM, never from this file.
$map = Get-Content "$RomPath\mk2.map"
function Sym([string]$name) {
    foreach ($l in $map) {
        if ($l -match "^([0-9a-fA-F]{8})\s+$name(\s|$)") { return $matches[1] }
        if ($l -match "\s([0-9a-fA-F]{8})\s+$name(\s|$)") { return $matches[1] }
    }
    return ""
}
$ani2 = Sym "ani2"
$clip = Sym "ani2_clip"
if (-not $ani2) { throw "ani2 not in $RomPath\mk2.map" }
if (-not $clip) { Write-Host "[ani2] NOTE: this ROM has no ani2_clip - it predates the guards" }

$env:FB_MAP = "$RomPath\mk2.map"; $env:FB_NET = $Net; $env:FB_OUT = $Out
$env:FB_READY = "$Out\ready.flag"; $env:FB_WEIGHTS_IN = $Brain
$env:FB_CHARS = "cycle"; $env:FB_GAMES = "0"; $env:FB_GAIN = "5"; $env:FB_SEED = "$Seed"
$env:FB_MAXMIN = "$Minutes"; $env:FB_CONTINUE = "1"; $env:FB_LEARN = "1"; $env:FB_LABEL = "fly"
$env:FB_FORCE_P2_LEGACY = "12"     # every fight is Kintaro in KAHN'S ARENA
$env:FB_FORCE_DIFF = "6"
$env:FB_EXIT_ON_CRASH = "1"
$env:FB_DBG_AT = "$ArmFrame"

$cmds = @()
if ($Mode -eq "inject") {
    # a0 is ani2's list pointer.  bpclear makes this a ONE SHOT so the rest of
    # the run is ordinary play - the question is whether the game survives it.
    $cmds += "bpset $ani2,1,{a0=0xff900000; bpclear; printf `"INJECTED at pc=%08X`",pc; g}"
}
if ($clip) {
    # 4th field is the CONDITION and the 5th the ACTION - an action in the
    # condition slot is rejected with "unknown symbol" and the watchpoint is
    # never set, which reads exactly like "the guard never fired".
    $cmds += "wpset $clip,10,w,1,{printf `"ANI2_CLIP FIRED`"; g}"
}
$env:FB_DBG_CMDS = ($cmds -join '~~~')

$args2 = @("-rompath", $RomPath, "mk2", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", "$Out\snap", "-nvram_directory", "$Out\nvram", "-cfg_directory", "$Out\cfg",
    "-autoboot_script", (Join-Path $Tools "flybrain_play.lua"),
    "-seconds_to_run", "$($Minutes * 60 + 60)",
    "-nothrottle", "-sound", "none", "-video", "none",
    "-debug", "-debugscript", "$Out\go.ds", "-debuglog")
Write-Host "[ani2] mode=$Mode rom=$RomPath out=$Out"
Write-Host "[ani2] ani2=$ani2 ani2_clip=$(if ($clip) { $clip } else { '(none)' })"
$p = Start-Process -FilePath $Mame -ArgumentList $args2 -WorkingDirectory $Out -PassThru `
    -WindowStyle Hidden -RedirectStandardOutput "$Out\mame_out.log" -RedirectStandardError "$Out\mame_err.log"

# WALL CLOCK, not emulated frames.  -seconds_to_run ends a healthy run, but a
# MAME that has stopped advancing frames never reaches it and a bare
# WaitForExit() then blocks forever - the rig hangs instead of reporting, which
# is the one outcome a test must never have.  Nothing inside the emulator can
# police this: a frame-counting detector cannot notice that frames stopped.
# Budget is emulated time plus generous slack for -nothrottle contention.
$deadline = [int]($Minutes * 60 + 120)
if (-not $p.WaitForExit($deadline * 1000)) {
    Write-Host "[ani2] MAME still alive after ${deadline}s of wall clock - killing it"
    try { $p.Kill() } catch {}
    $p.WaitForExit(15000) | Out-Null
    $timedout = $true
}

$dbg = if (Test-Path "$Out\debug.log") { Get-Content "$Out\debug.log" } else { @() }
$play = if (Test-Path "$Out\play.log") { Get-Content "$Out\play.log" } else { @() }
$injected = ($dbg | Select-String "INJECTED").Count
$fired = ($dbg | Select-String "ANI2_CLIP FIRED").Count
$wpfail = ($dbg | Select-String "unknown symbol").Count
# Case-SENSITIVE, and the DMA pattern is the report line, not the install
# line: "DMA guard: 2 tap(s) installed" is printed on every healthy boot
# and a case-insensitive "DMA GUARD" matches it, failing a good run.
$died = ($play | Select-String -CaseSensitive "CRASH RECORDER|HANG DETECTOR|DMA GUARD: SAG").Count
$rounds = ($play | Select-String "round end").Count

Write-Host ""
Write-Host "  injected      $injected"
Write-Host "  guard fired   $fired$(if ($wpfail) { '  (WATCHPOINT REJECTED - result not trustworthy)' })"
Write-Host "  rounds played $rounds"
Write-Host "  crash/hang    $died"

if ($timedout) { Write-Host "`nNO VERDICT - MAME had to be killed on the wall clock"; exit 2 }
if ($wpfail -and $clip) { Write-Host "`nNO VERDICT - the watchpoint never installed"; exit 2 }
if ($Mode -eq "inject") {
    if ($injected -lt 1) { Write-Host "`nNO VERDICT - the injection never fired"; exit 2 }
    if ($died -gt 0) { Write-Host "`nFAIL - the game did not survive the runaway list"; exit 1 }
    if ($clip -and $fired -lt 1) { Write-Host "`nFAIL - the game survived but no guard fired"; exit 1 }
    Write-Host "`nPASS - a runaway list was absorbed; the game played $rounds more rounds"
} else {
    if ($fired -gt 0) { Write-Host "`nFAIL - a guard clipped a list in ORDINARY play"; exit 1 }
    if ($rounds -lt 2) { Write-Host "`nNO VERDICT - the run barely played ($rounds rounds)"; exit 2 }
    Write-Host "`nPASS - $rounds rounds, no guard ever fired"
}
exit 0
