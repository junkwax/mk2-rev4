# run_flybrain_play.ps1 - watch (or batch-run) the fruit fly playing MK2 against the CPU.
#
#   .\tools\run_flybrain_play.ps1 -Watch                 # normal speed, sound, keeps playing
#   .\tools\run_flybrain_play.ps1 -Chars 9 -Watch        # the fly plays Reptile
#   .\tools\run_flybrain_play.ps1 -Games 12 -NoContinue  # fast: every fighter, one ladder attempt each
#
# Runs on its own nvram/cfg/snapshot folders, so the shared C:\MAME\nvram CMOS
# is never touched, and never kills other MAME processes. The ROM must carry
# fly_player (flyname in MAINEQU.ASM) and its map must match: -RomPath holds
# mk2.zip AND mk2.map. See tools/flybrain_play.lua for the brain and the rules.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\tmp\flybrain\rom23",  # 2026-09-21 10:23 link + 11:40 FLYBRAIN name level (-27.6 dB; the user's pick
                                                 # over 11:42's -26.8, which was too loud), Rain,
                                                 # on top of: the freeze fixes (proclock_fix, delobj_safe,
                                                 # palfree_safe, illop_recover) + innate moves (flyinv)
    [string]$Net = "C:\tmp\flybrain\out\flynet.lua",
    [string]$Out = "",
    [string]$Chars = "cycle",
    [int]$Games = 0,
    [int]$Gain = 5,
    [int]$Seed = 12345,
    [int]$MaxMinutes = 600,
    [switch]$NoContinue,
    [switch]$NoLearn,          # control: weights never move
    [string]$WeightsIn = "",   # continue training from a saved brain (-WeightsIn ...rain.lua -Watch)
    [string]$WeightsOut = "",  # save the brain at every round end
    [string]$Label = "fly",
    [string]$Resolution = "800x600",
    [switch]$Maximize,         # -Watch: open the window maximized (streams - viewers read the HUD)
    [int]$WatchdogSeconds = 0, # >0: kill MAME if play.log stops growing for this long (see below)
    [switch]$Sound,            # -Headless only: play the game's audio (off by default)
    [switch]$Headless,         # a STREAM with no MAME window: real time, silent, but the
                               # picture goes to the dashboard as stills instead of a window,
                               # so every panel of the stream is a browser source
    [switch]$Watch
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = "C:\tmp\flybrain\play_$(Get-Date -Format yyyyMMdd_HHmmss)" }
New-Item -ItemType Directory -Force "$Out\snap", "$Out\nvram", "$Out\cfg" | Out-Null
foreach ($f in @("$RomPath\mk2.zip", "$RomPath\mk2.map", $Net)) {
    if (-not (Test-Path $f)) { throw "missing $f" }
}
# The zip and the map must come from ONE link. Several sessions build into this tree, so
# copying a fresh src\mk2.map next to a stale mk2.zip is an easy mistake - and it does not
# look like a mistake: every symbol reads at a plausible-but-wrong address and the rig
# reports nothing wrong on a run that went wrong.
#
# MTIMES CANNOT DECIDE THIS. Copying installs both files at the same second whatever their
# provenance, and DOSBox stamps build outputs with its own clock (~13s ahead, whole-second,
# sometimes INVERTING the order) - see memory reference_dosbox_clock_skew_mtime_guard.
# So record what was installed, in PAIR.txt, and check the bytes are still those.
# Warn rather than throw: the stream loop must never be stopped at 3am by a bookkeeping
# problem, and a real mismatch lands in this log next to the round it ruined.
$pairFile = Join-Path $RomPath "PAIR.txt"
$zipHash = (Get-FileHash "$RomPath\mk2.zip" -Algorithm SHA256).Hash
$mapHash = (Get-FileHash "$RomPath\mk2.map" -Algorithm SHA256).Hash
if (Test-Path $pairFile) {
    $rec = @{}
    foreach ($line in Get-Content $pairFile) { if ($line -match '^(\w+)=(\S+)') { $rec[$Matches[1]] = $Matches[2] } }
    if ($rec.zip -and $rec.zip -ne $zipHash) {
        Write-Host "[flybrain] WARNING: $RomPath\mk2.zip has changed since PAIR.txt was written - if mk2.map was not replaced with it, every symbol is being read at the wrong address"
    }
    if ($rec.map -and $rec.map -ne $mapHash) {
        Write-Host "[flybrain] WARNING: $RomPath\mk2.map has changed since PAIR.txt was written - if mk2.zip was not replaced with it, every symbol is being read at the wrong address"
    }
} else {
    Write-Host "[flybrain] note: no PAIR.txt in $RomPath - install the zip and map together and write one to make mismatches detectable"
}
$env:FB_MAP = "$RomPath\mk2.map"; $env:FB_NET = $Net; $env:FB_OUT = $Out; $env:FB_READY = "$Out\ready.flag"
# The move catalogue belongs to the ROM, not to the working tree: tools/flybrain_moves.lua is
# regenerated whenever a special-move input is added, so a run on a frozen pair reads the copy
# frozen beside it when there is one.
if (Test-Path "$RomPath\flybrain_moves.lua") { $env:FB_MOVES = "$RomPath\flybrain_moves.lua" }
else { Remove-Item Env:FB_MOVES -ErrorAction SilentlyContinue }
# Charge moves (hold a button, let go) reach the ROM through the fly's mailbox only on builds whose
# fly_invoke_poll takes index 0FFFDh (2026-09-22 04:23 on); older ones drop them silently. A
# CHARGE_OK file beside the frozen pair says this build runs them.
if (Test-Path "$RomPath\CHARGE_OK") { $env:FB_CHARGE_INVOKE = "1" }
else { Remove-Item Env:FB_CHARGE_INVOKE -ErrorAction SilentlyContinue }
$env:FB_CHARS = $Chars; $env:FB_GAMES = "$Games"; $env:FB_GAIN = "$Gain"; $env:FB_SEED = "$Seed"
$env:FB_MAXMIN = "$MaxMinutes"; $env:FB_CONTINUE = $(if ($NoContinue) { "0" } else { "1" })
$env:FB_LEARN = $(if ($NoLearn) { "0" } else { "1" }); $env:FB_LABEL = $Label
if ($WeightsIn) { $env:FB_WEIGHTS_IN = $WeightsIn } else { Remove-Item Env:FB_WEIGHTS_IN -ErrorAction SilentlyContinue }
if ($WeightsOut) { $env:FB_WEIGHTS_OUT = $WeightsOut } else { Remove-Item Env:FB_WEIGHTS_OUT -ErrorAction SilentlyContinue }

# The dashboard shows ONE fly. Publishing is the rig's default so nobody has to remember
# FB_DASH, but a headless training run would then fight a watched stream over the same
# file - and it runs unthrottled, so it would win and the page would show the wrong fly.
# A watched run publishes; a batch run stays quiet unless FB_DASH names a file itself.
# -Headless is a watched run in every way but the window, so it publishes too.
$live = $Watch -or $Headless
if (-not $live) {
    if (-not $env:FB_DASH) { $env:FB_DASH = "0" }
} elseif ($env:FB_DASH -eq "0") {
    Remove-Item Env:FB_DASH            # an empty string is NOT unset to Lua's os.getenv
}

# The dashboard shows the game as stills, and MAME writes a snapshot relative to
# -snapshot_directory, which moves with every session. Tell the rig where that is so
# it can publish the folder rather than the page having to be re-pointed each restart.
$env:FB_DASH_SHOTDIR = "$Out\snap"
# OFF unless asked for. Encoding a PNG out of the frame buffer is emulator time spent on
# something that is not the fly playing, and at nine a second it is not free - so the
# picture panel is opt-in (-ShotEvery N), not something a run pays for by default.
if (-not $env:FB_DASH_SHOT) { $env:FB_DASH_SHOT = "0" }

# Batch runs are INVISIBLE: -video none opens no window and shows no ROM-warning
# screen to dismiss. -Watch gives a normal window at normal speed with sound.
$args2 = @("-rompath", $RomPath, "mk2", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", "$Out\snap", "-nvram_directory", "$Out\nvram", "-cfg_directory", "$Out\cfg",
    "-autoboot_script", (Join-Path $Tools "flybrain_play.lua"), "-seconds_to_run", "$($MaxMinutes * 60 + 60)")
if ($Watch -and $Maximize) { $args2 += @("-window", "-maximize") }
elseif ($Watch) { $args2 += @("-window", "-nomaximize", "-resolution", $Resolution) }
# Headless STREAM: no window, but real time and sound - the stills the rig drops are what
# the page shows, and MAME's audio still reaches the default device for OBS to capture.
# -throttle is NOT redundant: -video none runs as fast as it can even though throttling
# is on by default (measured - 98 emulated frames per real second, 1.8x speed), because
# there is no video update to pace it. A stream has to play at the board's own speed.
# Silent unless -Sound: a headless run is in the background, and nobody wants a fight
# playing out of the speakers from a window they cannot see (user, 2026-09-20).
elseif ($Headless) { $args2 += @("-video", "none", "-throttle"); if (-not $Sound) { $args2 += @("-sound", "none") } }
else { $args2 += @("-nothrottle", "-sound", "none", "-video", "none") }

Write-Host "[flybrain] output: $Out"
$p = Start-Process -FilePath $Mame -ArgumentList $args2 -WorkingDirectory (Split-Path -Parent $Mame) -PassThru `
    -WindowStyle $(if ($Watch) { "Normal" } else { "Hidden" }) `
    -RedirectStandardOutput "$Out\mame_out.log" -RedirectStandardError "$Out\mame_err.log"
if (-not $live) {
    # background training must never make a watched/streamed MAME stutter
    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
}
if ($Watch) {
    Start-Process pwsh -ArgumentList @("-NoProfile", "-File", (Join-Path $Tools "mame_dismiss_warning.ps1"),
        "-ProcessId", $p.Id, "-ReadyFile", "$Out\ready.flag") -WindowStyle Hidden | Out-Null
}
if ($WatchdogSeconds -gt 0) {
    # The rig's OWN stall detector cannot catch every freeze, and 2026-09-17 21:22 is why:
    # it counts EMULATED frames (1641 of them), so if the emulation itself stops advancing -
    # or crawls, as it does while the DMA is told to blit something enormous - the Lua frame
    # callback stops being called and the counter never reaches its threshold. The picture
    # sat dead for 47s and nothing in the process noticed. A watchdog OUTSIDE the process
    # can notice, because log() flushes every line: if play.log stops growing, the fly has
    # stopped playing, whatever the reason. Killing it makes the stream loop restart.
    $lastWrite = Get-Date
    $logFile = "$Out\play.log"
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        if (Test-Path $logFile) {
            $t = (Get-Item $logFile).LastWriteTime
            if ($t -gt $lastWrite) { $lastWrite = $t }
        }
        $quiet = ((Get-Date) - $lastWrite).TotalSeconds
        if ($quiet -ge $WatchdogSeconds) {
            Write-Host ("[flybrain] WATCHDOG: no log output for {0:N0}s - the fly has stopped playing, killing MAME" -f $quiet)
            Add-Content $logFile ("WATCHDOG: no log output for {0:N0}s - killed so the run can restart" -f $quiet)
            try { $p.Kill() } catch {}
            break
        }
    }
}
$p.WaitForExit()
Write-Host "[flybrain] MAME exited ($($p.ExitCode))"
if (Test-Path "$Out\play.log") { Get-Content "$Out\play.log" | Select-String "round end|GAME OVER|game \d+:" | Select-Object -Last 40 }
