param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string[]]$Char = @("scorpion"),
    # The drone that was reported: a ninja, whose rt_airborn_close random and
    # whose ochar_antiair are both the roundhouse. -Diff 0 is the control.
    [int[]]$Diff = @(9),
    # -Seed shifts the RNG stream. This rig is deterministic, so one rate can
    # be one unlucky stream; doc/AI_DRONE.md's rule is to shift and re-run
    # before believing a regression. 0 reproduces the historical runs.
    [int[]]$Seed = @(0),
    [int]$Backstop = 360
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_divepunish_test.lua"

# Poke past MAME's red ROM-warning box.  Without this the run silently never
# starts: MAME sits at the box burning ~0% CPU, the lua never gets a frame,
# and the harness reports NO LOG -- which reads exactly like a broken feature.
# It is intermittent, so it cost a run being half-believed before it showed
# itself.  Lifted from run_battle_stability_sweep.ps1, which has always done
# this; rawinput ignores synthetic keys, hence -keyboardprovider win32 below.
if (-not ("DivePunWin2" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
// Poke past MAME's red ROM-warning box.  Without this the run silently never
// starts: MAME pauses the machine on the box, the autoboot lua never gets a
// frame, and the harness reports NO LOG -- which reads exactly like a broken
// feature.
//
// SendInput, NOT PostMessage.  run_drone_antiair_test.ps1 posts WM_KEYDOWN and
// it works often enough to have shipped, but it missed most of a six-seed
// sweep here (every run "never reached fight start" at 0% CPU).  MAME's win32
// keyboard provider does not read the message queue for this, so the keys have
// to go through the real input path.
//
// SendInput goes to WHATEVER HAS FOCUS, so this refuses to type unless MAME is
// actually the foreground window -- otherwise the keystrokes land in whatever
// the user is doing.
public class DivePunWin2 {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KB ki; }
    [StructLayout(LayoutKind.Sequential)] struct KB {
        public ushort vk, scan; public uint flags; public uint time; public IntPtr extra;
        public int pad1, pad2;   // pads the union out to MOUSEINPUT's size
    }
    static void Key(ushort vk) {
        var down = new INPUT { type = 1, ki = new KB { vk = vk } };
        var up   = new INPUT { type = 1, ki = new KB { vk = vk, flags = 2 } };
        SendInput(1, new[] { down }, Marshal.SizeOf(typeof(INPUT))); Thread.Sleep(60);
        SendInput(1, new[] { up },   Marshal.SizeOf(typeof(INPUT)));
    }
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    static void Post(IntPtr h, int vk, char c) {
        PostMessage(h, 0x0100, (IntPtr)vk, IntPtr.Zero);
        if (c != (char)0) PostMessage(h, 0x0102, (IntPtr)c, IntPtr.Zero);
        Thread.Sleep(80);
        PostMessage(h, 0x0101, (IntPtr)vk, IntPtr.Zero);
    }
    // SendInput when MAME really has focus; otherwise PostMessage straight to
    // its window.  SendInput alone failed three runs in a row while another
    // window held focus (Windows refuses SetForegroundWindow from a background
    // process), parking MAME on the warning screen at 0% CPU every time - and
    // PostMessage, which never needs focus, got it running again at once.
    public static bool DismissWarning(IntPtr h) {
        if (h == IntPtr.Zero) return false;
        SetForegroundWindow(h); Thread.Sleep(250);
        if (GetForegroundWindow() == h) {
            Key(0x4F); Thread.Sleep(100);               // O
            Key(0x4B); Thread.Sleep(100);               // K
            Key(0x0D); Thread.Sleep(100);               // Enter
            Key(0x20);                                  // Space
        }
        Post(h, 0x4F, 'o'); Thread.Sleep(120);          // never types into
        Post(h, 0x4B, 'k'); Thread.Sleep(120);          // another window: it
        Post(h, 0x20, ' '); Thread.Sleep(120);          // is addressed to
        Post(h, 0x0D, (char)13);                           // MAME's handle only
        return true;
    }
}
'@
}

# The lua holds the log open, and Get-Content returns NOTHING on a locked file
# with the error swallowed -- same trap the sweep documents.
function Read-DivePunLog($path) {
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
    $Log = Join-Path $ToolsDir "drone_divepunish_${c}_d$d$sfx.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:DIVEP_LOG = $Log
    $env:DIVEP_CHAR = $c
    $env:DIVEP_DIFF = "$d"
    $env:DIVEP_SEED = "$s"
    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      # -nothrottle: emulation is deterministic either way, and at 100% speed a
      # 9000-frame run is 165 SECONDS of wall clock. Unthrottled it is seconds.
      "-nothrottle",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[divep] $c diff=$d seed=$s ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "drone_divepunish_mame.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "drone_divepunish_mame.err")
    $started = $false
    for ($i = 0; $i -lt 30 -and -not $proc.HasExited; $i++) {
        if ((Read-DivePunLog $Log) -match "fight start") { $started = $true; break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [void][DivePunWin2]::DismissWarning($proc.MainWindowHandle) }
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
            if ((Read-DivePunLog $Log) -match "fight start") { $started = $true; break }
            Start-Sleep -Milliseconds 700
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [void][DivePunWin2]::DismissWarning($proc.MainWindowHandle) }
            $proc.Refresh()
        }
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "  never reached 'fight start' in ~40s -- parked on the ROM warning box."
        Write-Host "  killing rather than waiting out the ${Backstop}s backstop."
        try { $proc.Kill() } catch {}
    }

    $proc.WaitForExit()
    "DIVEP_LOG","DIVEP_CHAR","DIVEP_DIFF","DIVEP_SEED" | ForEach-Object {
        Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    if (Test-Path $Log) {
        Get-Content $Log | Select-String "RESULT|REPRO|CLEAN|PARTIAL|NO-VERDICT|ERROR|FATAL|WHIFF" |
            ForEach-Object { Write-Host "  $($_.Line)" }
        $v = (Get-Content $Log | Select-String "REPRO|CLEAN|PARTIAL|NO-VERDICT" | Select-Object -Last 1)
        $summary += [pscustomobject]@{ Char = $c; Diff = $d; Seed = $s; Verdict = if ($v) { $v.Line } else { "NO VERDICT" } }
    } else {
        Write-Host "  no log produced (MAME red warning box not dismissed, or the"
        Write-Host "  lua never started -- MAME sits at ~0% CPU. Kill it and re-run.)"
        $summary += [pscustomobject]@{ Char = $c; Diff = $d; Seed = $s; Verdict = "NO LOG" }
    }
   }
  }
}

Write-Host "`n===== DRONE DIVE-KICK PUNISH ====="
$summary | ForEach-Object { Write-Host ("{0,-10} d{1} s{2}  {3}" -f $_.Char, $_.Diff, $_.Seed, $_.Verdict) }
