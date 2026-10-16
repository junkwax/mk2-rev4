# run_flybrain_selfplay.ps1 - fly versus fly.
#
# Two fruit-fly brains fight each other in a two-player game, one on each stick,
# under the same fairness rules as the single-player fly. They swap sticks every
# match (player 2 has a real side advantage in MK2) and both learn from what lands.
#
#   .\tools\run_flybrain_selfplay.ps1                       # headless, learns from scratch
#   .\tools\run_flybrain_selfplay.ps1 -Watch                # watch them fight
#   .\tools\run_flybrain_selfplay.ps1 -BrainA C:\tmp\flybrain\fly2\brain.lua   # A starts trained
#   .\tools\run_flybrain_selfplay.ps1 -FreezeB              # B never learns (a fixed sparring partner)
#   .\tools\run_flybrain_selfplay.ps1 -NetB C:\tmp\flybrain\out\flynet_shuffled.lua  # real wiring vs shuffled
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\tmp\flybrain\rom4",
    [string]$Out = "",
    [string]$Net = "C:\tmp\flybrain\out\flynet.lua",
    [string]$NetB = "",
    [string]$BrainA = "",          # copied in; the run learns into its own copy
    [string]$BrainB = "",
    [string]$Chars = "cycle",
    [int]$Minutes = 360,
    [int]$Seed = 31337,
    [string]$Stage = "cycle",   # a curback in decimal, or "cycle" for the VS stage cycle (no Kahn's Arena / Waffle House)
    [string]$Resolution = "1280x960",
    [string]$StyleA = "aggressive",   # BRAWLER - see STYLES in flybrain_selfplay.lua
    [string]$StyleB = "counter",      # COUNTER
    [int]$WatchdogSeconds = 0,        # >0: kill MAME if selfplay.log stops growing this long
    [switch]$Maximize,               # open the window maximized (viewers need to read the HUDs)
    [switch]$FreezeB,
    [switch]$Overlay,
    [switch]$Watch
)
$ErrorActionPreference = "Stop"
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = "C:\tmp\flybrain\selfplay_$(Get-Date -Format yyyyMMdd_HHmmss)" }
New-Item -ItemType Directory -Force "$Out\snap", "$Out\nvram", "$Out\cfg" | Out-Null
foreach ($f in @("$RomPath\mk2.zip", "$RomPath\mk2.map", $Net)) { if (-not (Test-Path $f)) { throw "missing $f" } }
# NOTE: not $brainA/$brainB - PowerShell variable names are case-insensitive, so
# those would overwrite the -BrainA/-BrainB parameters
$dstA = Join-Path $Out "brain_a.lua"
$dstB = Join-Path $Out "brain_b.lua"
# a run learns into ITS OWN copy, so training brains are never overwritten; skip the
# copy when the source already is that copy (a resumed run)
function Copy-Brain([string]$src, [string]$dst) {
    if (-not $src) { return }
    if ((Test-Path $dst) -and ((Resolve-Path $src).Path -eq (Resolve-Path $dst).Path)) { return }
    Copy-Item $src $dst -Force
}
Copy-Brain $BrainA $dstA
Copy-Brain $BrainB $dstB

$env:FS_MAP = "$RomPath\mk2.map"; $env:FS_OUT = $Out; $env:FS_READY = "$Out\ready.flag"
$env:FS_NET = $Net; $env:FS_NET_B = $(if ($NetB) { $NetB } else { $Net })
$env:FS_BRAIN_A = $dstA; $env:FS_BRAIN_B = $dstB
$env:FS_FREEZE_B = $(if ($FreezeB) { "1" } else { "0" })
$env:FS_CHARS = $Chars; $env:FS_SEED = "$Seed"; $env:FS_MAXMIN = "$Minutes"; $env:FS_STAGE = "$Stage"
$env:FS_OVERLAY = $(if ($Overlay) { "1" } else { "0" })
$env:FS_STYLE_A = $StyleA; $env:FS_STYLE_B = $StyleB

$args2 = @("-rompath", $RomPath, "mk2", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", "$Out\snap", "-nvram_directory", "$Out\nvram", "-cfg_directory", "$Out\cfg",
    "-autoboot_script", (Join-Path $Tools "flybrain_selfplay.lua"), "-seconds_to_run", "$($Minutes * 60 + 60)")
if ($Watch -and $Maximize) { $args2 += @("-window", "-maximize") }
elseif ($Watch) { $args2 += @("-window", "-nomaximize", "-resolution", $Resolution) }
else { $args2 += @("-nothrottle", "-sound", "none", "-video", "none") }

Write-Host "[vs] output: $Out"
$p = Start-Process -FilePath $Mame -ArgumentList $args2 -WorkingDirectory (Split-Path -Parent $Mame) -PassThru `
    -WindowStyle $(if ($Watch) { "Normal" } else { "Hidden" }) `
    -RedirectStandardOutput "$Out\mame_out.log" -RedirectStandardError "$Out\mame_err.log"
if (-not $Watch) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
else {
    Start-Process pwsh -ArgumentList @("-NoProfile", "-File", (Join-Path $Tools "mame_dismiss_warning.ps1"),
        "-ProcessId", $p.Id, "-ReadyFile", "$Out\ready.flag") -WindowStyle Hidden | Out-Null
}
if ($WatchdogSeconds -gt 0) {
    # same idea as run_flybrain_play.ps1: the Lua side cannot notice that the emulator itself
    # has stopped, but selfplay.log is flushed on every line, so silence means stopped
    $lastWrite = Get-Date
    $logFile = "$Out\selfplay.log"
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        if (Test-Path $logFile) { $t = (Get-Item $logFile).LastWriteTime; if ($t -gt $lastWrite) { $lastWrite = $t } }
        $quiet = ((Get-Date) - $lastWrite).TotalSeconds
        if ($quiet -ge $WatchdogSeconds) {
            Write-Host ("[vs] WATCHDOG: no log output for {0:N0}s - killing MAME" -f $quiet)
            Add-Content $logFile ("WATCHDOG: no log output for {0:N0}s - killed so the run can restart" -f $quiet)
            try { $p.Kill() } catch {}
            break
        }
    }
}
$p.WaitForExit()
Write-Host "[vs] MAME exited ($($p.ExitCode))"
if (Test-Path "$Out\rounds.csv") {
    $r = Import-Csv "$Out\rounds.csv"
    $a = ($r | Where-Object winner -eq "A").Count; $b = ($r | Where-Object winner -eq "B").Count
    Write-Host ("[vs] {0} rounds: A {1}, B {2}" -f $r.Count, $a, $b)
}
