param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    # Two rigs at once kill the loser with exit -1 and a log that stops
    # mid-run, which reads exactly like the ROM crashing.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 300,

    # The victim - the side whose ochar indexes the tables under test.
    #   jade    - the fighter that inherited a retail pad row
    #   kitana  - the reference female
    #   subzero - the reference ninja
    [ValidateSet("jade", "kitana", "subzero", "females", "all")]
    [string]$Victim = "jade",

    # kunglao - SPLIT IN 2, the half-body art (split_in_2_tab)
    # reptile - TONGUE head rip, the animation index (head_lineups)
    [ValidateSet("kunglao", "reptile", "both")]
    [string]$Attacker = "kunglao",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would be promoted to a
# terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "split_fatality_victim_test.lua"

# Source-built ROMs never match MAME's CRC table, so EVERY launch posts the red
# "press any key to continue" box.  MAME then sits there at ~0% CPU forever,
# the autoboot script never gets a frame, and a plain WaitForExit burns the
# whole backstop producing nothing - which looks exactly like a slow run.
# Lifted from run_drone_antiair_test.ps1; rawinput ignores synthetic keys,
# hence -keyboardprovider win32 below.
if (-not ("SfvWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class SfvWin {
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
# with the error swallowed.
function Read-SfvLog($path) {
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

$victims = switch ($Victim) {
    "females" { @("kitana", "jade") }
    "all"     { @("kitana", "subzero", "jade") }
    default   { @($Victim) }
}
$attackers = if ($Attacker -eq "both") { @("kunglao", "reptile") } else { @($Attacker) }

foreach ($a in $attackers) {
  foreach ($v in $victims) {
    $LogPath = Join-Path $ToolsDir "split_fatality_${a}_$v.log"
    $MameOut = Join-Path $ToolsDir "split_fatality_mame_out_${a}_$v.log"
    $MameErr = Join-Path $ToolsDir "split_fatality_mame_err_${a}_$v.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # A stranded instance from an earlier run blocks or confuses this one.
    Get-Process (Split-Path -Leaf $Mame).Replace(".exe", "") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root
    $env:SFV_VICTIM = $v
    $env:SFV_ATTACKER = $a
    $env:SFV_LOG = $LogPath

    $mameArgs = @(
        "-rompath", $RomPath,
        "mk2",
        "-window", "-nomaximize",
        "-resolution", $Resolution,
        "-video", "gdi",
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[sfv] $a on $v ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $MameOut -RedirectStandardError $MameErr

    # Two grace windows, dismissing the warning box the whole way through: a
    # genuinely slow start should not be mistaken for a parked one.
    $started = $false
    for ($i = 0; $i -lt 60 -and -not $proc.HasExited; $i++) {
        if ((Read-SfvLog $LogPath) -match "select screen") { $started = $true; break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [SfvWin]::DismissWarning($proc.MainWindowHandle) }
        $proc.Refresh()
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "  never reached the select screen in ~40s - parked on the ROM warning box."
        Write-Host "  killing rather than waiting out the ${BackstopEmuSeconds}s backstop."
        try { $proc.Kill() } catch {}
    }
    $proc.WaitForExit()

    foreach ($e in @("SFV_VICTIM", "SFV_ATTACKER", "SFV_LOG")) {
        Remove-Item "Env:\$e" -ErrorAction SilentlyContinue
    }

    if (Test-Path $LogPath) {
        $verdict = Read-SfvLog $LogPath | Select-String '^\[.*\] (PASS|FAIL)' | Select-Object -Last 1
        if ($verdict) { Write-Host $verdict.Line }
        else { Write-Host "[sfv/$a-$v] NO VERDICT - check $LogPath and $MameOut" }
    } else {
        Write-Host "[sfv/$a-$v] NO LOG - MAME never ran a frame; see $MameOut"
    }
  }
}
