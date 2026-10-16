# run_flybrain_stream.ps1 - the fruit fly plays MK2 live, for streaming.
#
# One window, normal speed, sound on. A normal one-player game against the stock
# CPU: the fly continues when it loses, moves to the next fighter at every select
# screen, attempts fatalities/babalities at FINISH HIM, and its wins
# read FRUIT FLY WINS with the fruit fly announcer line.
#
# It starts from a COPY of a trained brain and keeps learning into that copy, so
# a stream never changes the training data.
#
# SELF-RECOVERING: the open Kahn's Arena reset (memory project_kintaro_arena_dma_hang)
# wedges the board about once every two hours, and MAME itself can go down without
# the fly's recorder ever getting a frame to write. So this restarts after ANY exit
# with the fly's latest brain, and stops only when told to or when it cannot stay up
# (two sessions under a minute in a row). To end a stream, drop a STOP file in its
# output folder:
#   New-Item C:\tmp\flybrain\stream_<date>\STOP
#
#   .\tools\run_flybrain_stream.ps1                       # trained brain, every fighter
#   .\tools\run_flybrain_stream.ps1 -Chars 3              # Baraka only
#   .\tools\run_flybrain_stream.ps1 -Resolution 1920x1440
#   .\tools\run_flybrain_stream.ps1 -Fresh                # untrained fly, learning from zero
#   .\tools\run_flybrain_stream.ps1 -Brain C:\tmp\flybrain\stream_<date>\brain.lua   # carry on a stream's learning
#
# Output (logs, rounds.csv, finishers.csv, the stream's brain) goes to
# C:\tmp\flybrain\stream_<date_time>, one part<N> folder per MAME session.
param(
    [string]$Brain = "C:\tmp\flybrain\train3\full\brain.lua",
    [string]$RomPath = "",       # "" = run_flybrain_play.ps1's default ROM copy (a zip+map pair with PAIR.txt)
    [switch]$Maximize,           # maximized window on every restart - the stream never comes back small
    [switch]$Sound,              # -Headless: play the game's audio (silent by default)
    [switch]$Headless,           # NO MAME window: real time, silent, and the picture reaches
                                 # the stream through the dashboard's /screen view, so every
                                 # panel in OBS is a browser source you place yourself
    [string]$Pick = "mix",       # mix = a random fighter walked to with the cursor, or ~1 in 4 the
                                 # game's own random select (Up+Start); random | gamerandom | cycle
    [int]$Sharp = 2,             # pick by weight^Sharp; 1 = training's exploring pick
    [int]$BossTries = 3,         # give up after N boss losses running (Kintaro/Kahn) and start a
                                 # fresh game - continues otherwise loop the same lost fight for
                                 # hours (425 of 486 rounds on 2026-09-21). 0 = continue forever
    [int]$KahnEvery = 0,         # N = every Nth game starts on SHAO KAHN's rung and stays there
                                 # (1 = every game is Kahn). 0 = the normal ladder
    [switch]$Overlay,            # paint the in-game corner HUD over the fight (off by default:
                                 # the dashboard panels already say everything it said)
    [switch]$NoPoke,             # ignore the dashboard's "Poke a neuron" buttons (on by default:
                                 # a stream is a show; tests and trainers never read them)
    [switch]$BigHud,             # the old full-width brain strip along the bottom instead of the small panel
    [string]$Chars = "cycle",
    [string]$Resolution = "1280x960",
    [string]$Net = "C:\tmp\flybrain\out\flynet_oa.lua",   # 768 cells: the sensory fly + its octopamine cells
                                 # in shadow. Measured 2026-09-20: plays IDENTICALLY to the
                                 # 623-cell flynet_chase.lua (same decisions, block for block) -
                                 # the extra cells only show on the brain panel;
                                 # "" falls back to the rig's 64-cell default net
    [int]$ShotEvery = 0,         # dashboard picture every N frames. 0 (default) = none: the
                                 # emulator spends no time encoding PNGs. 6 is nine a second
    [int]$Minutes = 600,
    [int]$MaxRestarts = 20,
    [int]$SecretOppEvery = 0,    # N = force Smoke/Noob every Nth battle. 0 (default): only their real
                                 # pathways - both two-player, so a one-player stream never meets them
    [switch]$WaffleHouse,        # allow Smoke's fight to use the secret arena again
    [switch]$Fresh
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = "C:\tmp\flybrain\stream_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Force $Root | Out-Null
$streamBrain = Join-Path $Root "brain.lua"
if (-not $Fresh) {
    if (-not (Test-Path $Brain)) { throw "no trained brain at $Brain (use -Fresh to start untrained)" }
    Copy-Item $Brain $streamBrain
}
# the crash recorder must END the MAME session so this loop can start a clean one
$env:FB_EXIT_ON_CRASH = "1"
# A stream shows the brain working and the whole roster, including the two secret fighters
# (Jade and Ermac, reached through their select-screen unlocks) and the two secret opponents
# (Smoke and Noob, whose tower spot the ladder normally steps over). The WAFFLE HOUSE stays
# paused - Smoke's fight is redirected to the ordinary arenas - until asked for.
# The in-game corner HUD is OFF for a stream unless -Overlay asks for it. The dashboard
# panels carry everything it said, and on a captured MAME window it is just a box painted
# over the fight. It remains the readout for a plain run_flybrain_play.ps1 -Watch.
$env:FB_OVERLAY = $(if ($Overlay) { "1" } else { "0" })
# A stream is watched on the dashboard page as well as in the MAME window, and a browser
# cannot read another window's video - so drop a still every N frames for the page to show.
# 6 is about nine a second at 54.7 Hz, which reads as motion and costs a stream nothing.
$env:FB_DASH_SHOT = "$ShotEvery"
# The connectome the stream flies on. The all-senses net (looming, chase cells, the ears,
# the extra descending neurons) plays the same as the 64-cell default - measured, no better
# and no worse - but it is what the nervous-system panel is showing, so a stream flies it.
# run_flybrain_play.ps1 has its own -Net and writes FB_NET itself, so this has to be
# handed over as a PARAMETER - setting the environment variable here is overwritten.
if ($Net -and -not (Test-Path $Net)) {
    Write-Host "[stream] no net at $Net - using the rig's default"
    $Net = ""
}
# the small top-left panel by default (the fly-vs-fly stream's); -BigHud for the old bottom strip
$env:FB_PICK = $Pick
# lean on what it has learned: at difficulty 2 the same brain won 89% of rounds against the
# regular fighters picking by weight^2, 57% picking by weight (tmp\flybrain\ab_sharp)
$env:FB_SHARP = "$Sharp"
$env:FB_KAHN_EVERY = "$KahnEvery"
$env:FB_BOSS_TRIES = "$BossTries"
# SHOW MODE: the dashboard's neuron buttons drive the named cells for 1.5 s. Only a stream
# sets this - a test or a trainer never reads the poke file, so nothing pokes a measurement.
$env:FB_STIM = $(if ($NoPoke) { "0" } else { "1" })
$env:FB_HUD =$(if ($BigHud) { "big" } else { "small" })
$env:FB_SECRET_OPP_EVERY = "$SecretOppEvery"
$env:FB_NO_WAFFLE = $(if ($WaffleHouse) { "0" } else { "1" })
$quick = 0   # consecutive sessions that died in under a minute
Write-Host "[stream] brain: $(if ($Fresh) { 'fresh' } else { $Brain })   output: $Root"

for ($part = 1; $part -le ($MaxRestarts + 1); $part++) {
    $out = Join-Path $Root ("part{0:D2}" -f $part)
    # 120s of no log output means the fly has stopped playing - a frozen picture someone
    # would otherwise have to notice and close by hand. Rounds are ~20-40s, so this only
    # fires on a genuine wedge.
    $play = @{ Out = $out; Chars = $Chars; Resolution = $Resolution; MaxMinutes = $Minutes; Label = "stream"; Watch = $true;
               WatchdogSeconds = 120; WeightsOut = $streamBrain; Seed = (Get-Random -Minimum 1 -Maximum 1000000) }
    if (Test-Path $streamBrain) { $play.WeightsIn = $streamBrain }
    if ($RomPath) { $play.RomPath = $RomPath }
    if ($Maximize) { $play.Maximize = $true }
    if ($Headless) { $play.Watch = $false; $play.Headless = $true; if ($Sound) { $play.Sound = $true } }
    if ($Net) { $play.Net = $Net }
    $started = Get-Date
    & (Join-Path $Tools "run_flybrain_play.ps1") @play | Out-Null
    $ran = ((Get-Date) - $started).TotalSeconds
    # A stream should come back from ANYTHING - the board reset, MAME dying, a
    # sprite-address fault - so restart on every exit. Stop only when asked (a STOP
    # file in the stream folder) or when it cannot stay up (two quick exits running).
    if (Test-Path (Join-Path $Root "STOP")) { Write-Host "[stream] STOP file - stream over"; break }
    if ($ran -lt 60) {
        $quick++
        if ($quick -ge 2) { Write-Host "[stream] two immediate exits - stopping rather than looping"; break }
    } else { $quick = 0 }
    $log = Join-Path $out "play.log"
    # case-SENSITIVE, and the guard's report line is "DMA GUARD: SAG" - a case-blind match
    # also hits the boot line "DMA guard: 2 tap(s) installed" and calls every healthy run a crash
    $why = if ((Test-Path $log) -and (Select-String -Path $log -CaseSensitive -Pattern "CRASH RECORDER|HANG DETECTOR|DMA GUARD: SAG" -Quiet)) {
        "the board reset" } else { "MAME exited" }
    Write-Host ("[stream] part {0} ended after {1:N0}s ({2}) - restarting with the latest brain" -f $part, $ran, $why)
}
