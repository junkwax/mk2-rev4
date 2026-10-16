param(
    # mame_mk2test.exe, not mame.exe, and the name is the whole point: these
    # rigs find each other with Get-Process and kill each other, and the
    # symptom is MAME exiting -1 (255) part way through a log with no error
    # message -- which reads exactly like the ROM having crashed at whatever
    # the rig happened to be doing. Running under a private binary name keeps
    # this probe out of everyone else's Get-Process mame.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    # ochar of the fighter to take up the tower. The ladder is built against
    # the MATCHUP CHART for whoever this is, so run more than one.
    [int[]]$Char = @(5),
    [int]$Diff = 9,
    [int]$Backstop = 400,
    # Towers to collect per character before a verdict. The variance half of
    # the check needs at least two, and each one costs an attract demo game
    # (~50s), so Backstop has to be generous enough to cover them.
    [int]$Builds = 2
)

# Drives tools/dyn_map_probe.lua: force a character at select, let the ladder
# screen build the tower, then read dyn_map back out of RAM and check it is
# ordered kindest-matchup-first.
#
# NEVER run alongside another MAME harness -- they all kill mame.exe on start.

$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "dyn_map_probe.lua"
$NAMES = @("kung lao","liu kang","cage","baraka","kitana","mileena","shang",
           "raiden","sub-zero","reptile","scorpion","jax")

# MAME's red ROM-warning box has to be answered or the run never starts: MAME
# sits on it at ~0% CPU, -seconds_to_run counts EMULATED time so it never times
# out, and the lua logs its header (written at script load) and then nothing --
# which reads exactly like the ROM having hung.
#
# This USED to be an in-process WM key poster and it did not reliably work.
# The launching shell redirects MAME's stdout and never owns the foreground, so
# Windows refuses its SetForegroundWindow and MAME on -keyboardprovider win32
# ignores the keys. Hand it to tools/mame_dismiss_warning.ps1 as a separate
# process instead, exactly as run_mame_small.ps1 does -- its header has the
# full account of what else was tried.

# The lua holds the log open; Get-Content returns NOTHING on a locked file and
# swallows the error, so a run reads as "no verdict" while the log says PASS.
function Read-ProbeLog($path) {
  for ($i = 0; $i -lt 12; $i++) {
    try {
      $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
      $sr = New-Object System.IO.StreamReader($fs)
      $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
      if ($t) { return ($t -split "`r?`n") }
    } catch { Start-Sleep -Milliseconds 250 }
  }
  return @()
}

$summary = @()
foreach ($c in $Char) {
    $nm = if ($c -lt $NAMES.Count) { $NAMES[$c] } else { "char$c" }
    $Log = Join-Path $ToolsDir ("dyn_map_" + ($nm -replace '\s','') + ".log")
    $Ready = "$Log.ready"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Ready -Force -ErrorAction SilentlyContinue
    # Only ever kill OUR binary, never every mame.exe on the machine.
    $MameProc = [System.IO.Path]::GetFileNameWithoutExtension($Mame)
    Get-Process $MameProc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:DYNMAP_LOG = $Log
    $env:DYNMAP_READY = $Ready
    $env:DYNMAP_CHAR = "$c"
    $env:DYNMAP_DIFF = "$Diff"
    $env:DYNMAP_BUILDS = "$Builds"

    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      # Running MAME from the repo would otherwise pick up the committed
      # cfg/mk2.cfg, which has the TEST switch ON -- the game boots to the
      # operator menu and no tower is ever built.
      "-cfg_directory","C:\MAME\cfg","-nvram_directory","C:\MAME
vram",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[dynmap] $nm (ochar $c, diff $Diff) ..."
    # LAUNCH MAME WITH A DIRECT BLOCKING CALL, not Start-Process.
    #
    # Start-Process silently breaks -autoboot_script under pwsh 7: MAME boots,
    # the ROM audit lands on stderr, and the lua NEVER loads -- no log file at
    # all, which is the same symptom as the warning screen and as a dead
    # script, so it is impossible to tell apart from the console. It is also
    # intermittent, which is worse: some runs load the script and some do not.
    # A direct call works every time.
    #
    # That costs the PID the dismisser wants, so the dismisser is started
    # FIRST and finds MAME by name. It stops the moment $Ready appears -- and
    # $Ready means "frames are running" (the lua writes it at frame 120), not
    # "the log exists", because the log is opened at script load before any
    # frame and would stop the poker before it ever poked.
    $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
    $findAndPoke = @"
`$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt `$deadline) {
    `$m = Get-Process $MameProc -ErrorAction SilentlyContinue | Select-Object -First 1
    if (`$m) {
        & '$poker' -ProcessId `$m.Id -ReadyFile '$Ready' -TimeoutSec 120
        break
    }
    Start-Sleep -Milliseconds 250
}
"@
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy","Bypass","-Command",$findAndPoke) | Out-Null

    & $Mame @mameArgs *> (Join-Path $ToolsDir "dyn_map_mame.log")
    "DYNMAP_LOG","DYNMAP_READY","DYNMAP_CHAR","DYNMAP_DIFF","DYNMAP_BUILDS" | ForEach-Object {
        Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    # Distinguish the two failures. "No log at all" means the lua never loaded
    # (autoboot path, syntax error, or MAME parked on the red warning screen).
    # "A log with no PASS/FAIL" means it ran and simply never reached a verdict
    # -- almost always the persistence watch being re-armed by the next attract
    # game before it could complete. Reporting both as "warning box?" sends you
    # to debug the launcher when the rig is running fine.
    $verdict = "NO LOG - lua never loaded (warning screen / autoboot path?)"
    $lines = Read-ProbeLog $Log
    if ($lines.Count) {
        $verdict = "NO VERDICT - ran but never concluded (lower DYNMAP_WATCH / raise -Backstop)"
        $lines | Select-String "map_start ->|^\[dynmap\]\s+\d+\.|PASS |FAIL |FATAL" |
            ForEach-Object { Write-Host "  $($_.Line)" }
        $v = $lines | Select-String "PASS |FAIL " | Select-Object -Last 1
        if ($v) { $verdict = $v.Line -replace "^\[dynmap\] ", "" }
    }
    Write-Host "[dynmap] $nm -> $verdict"
    $summary += [pscustomobject]@{ Char = $nm; Verdict = $verdict }
}

Write-Host "`n===== DYNAMIC TOWER ====="
$summary | ForEach-Object { Write-Host ("{0,-10} {1}" -f $_.Char, $_.Verdict) }
