param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string[]]$Char = @("raiden"),
    # Run -Diff 0 as the honesty control: rpt_antiair[0] is 0, so the easy
    # CPU must never anti-air. A hit down there means the gate ignores @diff.
    [int[]]$Diff = @(9),
    # -Seed shifts the RNG stream. This rig is deterministic, so one rate can
    # be one unlucky stream; doc/AI_DRONE.md's rule is to shift and re-run
    # before believing a regression. 0 reproduces the historical runs.
    [int[]]$Seed = @(0),
    [int]$Backstop = 300
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_antiair_test.lua"

# Poke past MAME's red ROM-warning box.  Without this the run silently never
# starts: MAME sits at the box burning ~0% CPU, the lua never gets a frame,
# and the harness reports NO LOG -- which reads exactly like a broken feature.
# It is intermittent, so it cost a run being half-believed before it showed
# itself.  Lifted from run_battle_stability_sweep.ps1, which has always done
# this; rawinput ignores synthetic keys, hence -keyboardprovider win32 below.
if (-not ("AntiAirWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class AntiAirWin {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    static void Press(IntPtr h, int vk) {
        PostMessage(h, 0x0100, (IntPtr)vk, IntPtr.Zero); Thread.Sleep(60);
        PostMessage(h, 0x0101, (IntPtr)vk, IntPtr.Zero);
    }
    static void Ch(IntPtr h, char c) { PostMessage(h, 0x0102, (IntPtr)c, IntPtr.Zero); }
    public static void DismissWarning(IntPtr h) {
        Press(h, 0x4F); Ch(h, 'o'); Thread.Sleep(80);
        Press(h, 0x4B); Ch(h, 'k'); Thread.Sleep(80);
        Press(h, 0x20); Thread.Sleep(60);
        Press(h, 0x0D);
    }
}
'@
}

# The lua holds the log open, and Get-Content returns NOTHING on a locked file
# with the error swallowed -- same trap the sweep documents.
function Read-AntiAirLog($path) {
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
  foreach ($d in $Diff) {
   foreach ($s in $Seed) {
    $sfx = if ($s -eq 0) { "" } else { "_s$s" }
    $Log = Join-Path $ToolsDir "drone_antiair_${c}_d$d$sfx.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:ANTIAIR_LOG = $Log
    $env:ANTIAIR_CHAR = $c
    $env:ANTIAIR_DIFF = "$d"
    $env:ANTIAIR_SEED = "$s"
    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[antiair] $c diff=$d seed=$s ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "drone_antiair_mame.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "drone_antiair_mame.err")
    $started = $false
    for ($i = 0; $i -lt 30 -and -not $proc.HasExited; $i++) {
        if ((Read-AntiAirLog $Log) -match "fight start") { $started = $true; break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [AntiAirWin]::DismissWarning($proc.MainWindowHandle) }
        $proc.Refresh()
    }

    # DO NOT WAIT OUT THE BACKSTOP ON A RUN THAT NEVER STARTED.
    #
    # DismissWarning is intermittent (see its own comment).  When it misses,
    # MAME sits on the red "one or more ROMs changed" box at ~0% CPU, the lua
    # never gets a frame, and WaitForExit then blocks for the WHOLE
    # -seconds_to_run backstop - 300s per character, producing nothing.  That
    # is indistinguishable from a slow run while you are watching it, and it
    # is how a two-character sweep silently becomes a ten-minute no-op.
    #
    # A second grace window first, so a genuinely slow start is not mistaken
    # for a parked one; only then give up.
    if (-not $started) {
        for ($i = 0; $i -lt 28 -and -not $proc.HasExited; $i++) {
            if ((Read-AntiAirLog $Log) -match "fight start") { $started = $true; break }
            Start-Sleep -Milliseconds 700
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [AntiAirWin]::DismissWarning($proc.MainWindowHandle) }
            $proc.Refresh()
        }
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "  never reached 'fight start' in ~40s -- parked on the ROM warning box."
        Write-Host "  killing rather than waiting out the ${Backstop}s backstop."
        try { $proc.Kill() } catch {}
    }

    $proc.WaitForExit()
    "ANTIAIR_LOG","ANTIAIR_CHAR","ANTIAIR_DIFF","ANTIAIR_SEED" | ForEach-Object {
        Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    if (Test-Path $Log) {
        Get-Content $Log | Select-String "RESULT|PASS |FAIL |ERROR|WHIFF" |
            ForEach-Object { Write-Host "  $($_.Line)" }
        $v = (Get-Content $Log | Select-String "PASS |FAIL " | Select-Object -Last 1)
        $summary += [pscustomobject]@{ Char = $c; Diff = $d; Seed = $s; Verdict = if ($v) { $v.Line } else { "NO VERDICT" } }
    } else {
        Write-Host "  no log produced (MAME red warning box not dismissed, or the"
        Write-Host "  lua never started -- MAME sits at ~0% CPU. Kill it and re-run.)"
        $summary += [pscustomobject]@{ Char = $c; Diff = $d; Seed = $s; Verdict = "NO LOG" }
    }
   }
  }
}

Write-Host "`n===== DRONE ANTI-AIR ====="
$summary | ForEach-Object { Write-Host ("{0,-10} d{1} s{2}  {3}" -f $_.Char, $_.Diff, $_.Seed, $_.Verdict) }
