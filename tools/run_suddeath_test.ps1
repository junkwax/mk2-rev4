# run_suddeath_test.ps1 - a match's FIRST tie is a DRAW and the round replays;
# the NEXT tie is SUDDEN DEATH, where the first hit wins (suddeath /
# sudden_draws, MAINEQU.ASM).  Four rounds: DRAW, an ordinary round tied
# again, the sudden-death round, then an ordinary round 4.  See
# tools/sweep_addon_suddeath.lua for the steps.
#
# Reuses battle_stability_sweep.lua purely as a harness (forces the matchup,
# walks select, loads tools/sweep_addon.lua).  The addon is COPIED into place
# for the run and removed afterwards, so a later sweep does not pick it up.
# Runs rom/mk2.zip - repackage (mamerom.py) after a rebuild or the rig reads
# this build's map against another build's ROM.
param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 600,      # four rounds now, not three
    [switch]$Throttle,
    # -Listen: sound ON.  Records the EMULATED mix with -wavwrite (immune to
    # host-side starvation) and turns the snapshots off, because the PNG flood
    # chops the host sound device and reads exactly like a broken ROM.  Also
    # taps the hardware sound latch, so the log says whether the SUDDEN DEATH
    # track was really sent or was refused by triple_sound.
    [switch]$Listen,
    [int]$P1 = 1,       # Liu Kang - his high kick connects at the pinned 70px
    # -Mode stall: rounds 1-2 as usual (DRAW, then SUDDEN DEATH), then NOBODY
    # presses anything for the whole 99-second clock of the sudden-death round.
    # Both bars end it untouched at sudden_strength, which IS "both players at
    # full strength" for that round, so weed_out_cheaters must call GAME OVER.
    [ValidateSet("rounds","stall")]
    [string]$Mode = "rounds"
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_suddeath.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "suddeath.txt"
$SnapDir = Join-Path $ToolsDir "screens\suddeath"

# This rig keeps its OWN nvram/cfg (passed below), so it runs beside somebody
# else's MAME - a session playing the installed ROM, or another rig - without
# either clearing the other's state.  Nothing here touches C:\MAME\nvram.
$Private = Join-Path $ToolsDir "suddeath_rig"
New-Item -ItemType Directory -Force (Join-Path $Private "nvram") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Private "cfg") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Private "nvram" | Join-Path -ChildPath "mk2") -ErrorAction SilentlyContinue
if (Test-Path $Addon) {
    Write-Host "[sd] tools/sweep_addon.lua already exists (another rig's addon?) - refusing"
    exit 2
}

Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $SnapDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $SnapDir | Out-Null
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "11"          # Jax
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "15000"  # the addon exits MAME itself
$env:SWEEP_LABEL = "suddeath"
$env:SWEEP_LOG = Join-Path $ToolsDir "suddeath_sweep.log"
$env:SWEEP_P2_HUMAN = "1"     # P2 stands and blocks on the rig's say-so
$env:SWEEP_NO_HP_PIN = "1"    # the bars ARE the measurement
$env:SD_LOG = $Log
if ($Mode -eq "stall") { $env:SD_MODE = "stall" } else { Remove-Item Env:\SD_MODE -ErrorAction SilentlyContinue }
$Wav = Join-Path $ToolsDir "suddeath.wav"
if ($Listen) {
    $env:SD_NO_SHOTS = "1"
    if (-not $env:SD_SND) { $env:SD_SND = "1" }   # SD_SND=all logs every code
    Remove-Item $Wav -ErrorAction SilentlyContinue
} else {
    Remove-Item Env:\SD_NO_SHOTS -ErrorAction SilentlyContinue
    Remove-Item Env:\SD_SND -ErrorAction SilentlyContinue
}

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop,
  "-nvram_directory",(Join-Path $Private "nvram"),"-cfg_directory",(Join-Path $Private "cfg"))
if ($Listen) { $mameArgs += @("-wavwrite",$Wav) } else { $mameArgs += @("-sound","none") }
if (-not $Throttle) { $mameArgs += "-nothrottle" }

Write-Host "[sd] Liu Kang (P1) vs Jax (P2, human), Dead Pool - mode $Mode ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "suddeath_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "suddeath_mame.err")

# Poke past the ROM-warning screen.  This MUST be the standalone PostMessage
# poker, not AppActivate + SendKeys: SendKeys needs the FOREGROUND, and this
# script started MAME with redirected stdout/stderr so it never owns it.  With
# no other MAME window up the focus steal happened to work; the moment the user
# (or another rig) has one open, the keys land in THEIR window and this run
# parks on the red box for the whole -seconds_to_run backstop producing nothing.
# Measured 2026-09-28: 600s burnt, empty log, MAME alive and "Responding".
# See doc/ and the mame_dismiss_warning.ps1 header for why every in-process
# variant of this has failed.
$poker = Start-Process -FilePath "powershell" -PassThru -WindowStyle Hidden `
    -ArgumentList @("-ExecutionPolicy","Bypass","-File",
                    (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),
                    "-ProcessId",$proc.Id,"-ReadyFile",$Log,"-TimeoutSec",180)

# And do not wait the backstop out if it never starts: no log inside the grace
# window means the box was never cleared, so kill and say so rather than
# returning an empty run that reads like a broken ROM.
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) { break }
    if (Test-Path $Log) { break }
}
if (-not $proc.HasExited -and -not (Test-Path $Log)) {
    Write-Host "[sd] parked on the ROM warning box - no lua log after 63s, killing"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

$proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
if ($poker -and -not $poker.HasExited) { Stop-Process -Id $poker.Id -Force -ErrorAction SilentlyContinue }

Remove-Item $Addon -ErrorAction SilentlyContinue
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL",
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","SD_LOG",
                 "SD_NO_SHOTS","SD_SND","SD_MODE")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[sd] no log produced" }
if ($Listen) {
    if (Test-Path $Wav) {
        Write-Host "[sd] wav: $Wav"
        # Does the recording actually CONTAIN the line?  The tap only proves the
        # track was sent; this proves it came out of the mix.
        # BOTH announcer lines: DRAW at the first tie, SUDDEN DEATH at the
        # second.  Scored separately and BY LABEL - the two log in the same
        # format and DRAW comes first, so a single unlabelled search would
        # score the DRAW line and print it as the sudden-death verdict.
        $wavFails = 0
        foreach ($lbl in @("DRAW", "SUDDEN DEATH")) {
            python (Join-Path $ToolsDir "suddeath_wav_check.py") $Wav $Log $lbl
            if ($LASTEXITCODE -ne 0) { $wavFails++ }
        }
        if ($wavFails -gt 0) {
            Write-Host "[sd] wav: $wavFails of 2 announcer lines FAILED"
        } else {
            Write-Host "[sd] wav: both announcer lines are in the mix"
        }
    } else { Write-Host "[sd] -Listen: no wav was written" }
} else {
    Write-Host "[sd] snapshots: $SnapDir"
}
