param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string[]]$Char = @("raiden"),
    [string[]]$Move = @("hp"),       # hp lp hk lk
    # the HUMAN's character - "does <char>'s <move> connect at all" needs this
    [string]$P1 = "liukang",
    # make P2 a PASSIVE HUMAN instead of the drone - for measuring damage
    # numbers, where a blocking drone destroys the sample
    [switch]$P2Human,
    # turtle = player holds Block and pokes out of it (the informative one);
    # mash   = player never blocks (loses to anything - sanity check only)
    [ValidateSet("turtle","mash","duckupper","backjump","fight")][string]$Style = "turtle",
    [int]$Diff = 9,
    [int]$Backstop = 360
)
# Measures whether mashing ONE move keeps working against the drone.
# Reports damage per third of the fight; it is a MEASUREMENT, not a
# pass/fail, except that it calls itself INVALID if the rig never fought.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_pressure_test.lua"

# Poke past MAME's red ROM-warning box. Without it the run silently never
# starts -- MAME sits at the box at ~0% CPU, the lua never gets a frame, and
# this harness reports "never reached fight", which reads exactly like a
# broken feature. Intermittent, so it passes for weeks and then bites.
if (-not ("PressWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class PressWin {
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

$summary = @()
foreach ($c in $Char) {
  foreach ($m in $Move) {
    $Log = Join-Path $ToolsDir "drone_pressure_${Style}_${c}_${m}_d$Diff.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:PRESSURE_LOG = $Log
    $env:PRESSURE_CHAR = $c
    $env:PRESSURE_MOVE = $m
    $env:PRESSURE_P1 = $P1
    $env:PRESSURE_P2_HUMAN = if ($P2Human) { "1" } else { "0" }
    $env:PRESSURE_DIFF = "$Diff"
    $env:PRESSURE_STYLE = $Style
    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[pressure] $c vs $Style $m (diff $Diff, p1=$P1) ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "drone_pressure_mame.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "drone_pressure_mame.err")
    for ($i = 0; $i -lt 30 -and -not $proc.HasExited; $i++) {
        if ((Get-Content $Log -ErrorAction SilentlyContinue) -match "fight start") { break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [PressWin]::DismissWarning($proc.MainWindowHandle) }
        $proc.Refresh()
    }
    $proc.WaitForExit()
    "PRESSURE_LOG","PRESSURE_CHAR","PRESSURE_MOVE","PRESSURE_DIFF","PRESSURE_STYLE","PRESSURE_P1","PRESSURE_P2_HUMAN" | ForEach-Object {
        Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    if (Test-Path $Log) {
        Get-Content $Log | Select-String "RESULT|taken by third|dealt by third|hit sizes|MEASURED|VERDICT|opening rate|INVALID|exchange:|ERROR" |
            ForEach-Object { Write-Host "  $($_.Line)" }
        $v = (Get-Content $Log | Select-String "MEASURED|INVALID" | Select-Object -Last 1)
        $summary += [pscustomobject]@{ Char=$c; Move=$m; Verdict = if ($v) { $v.Line } else { "NO VERDICT" } }
    } else {
        Write-Host "  no log produced (MAME lua-never-started flake? re-run)"
        $summary += [pscustomobject]@{ Char=$c; Move=$m; Verdict="NO LOG" }
    }
  }
}

Write-Host "`n===== DRONE PRESSURE ====="
$summary | ForEach-Object { Write-Host ("{0,-9} {1,-3} {2}" -f $_.Char, $_.Move, $_.Verdict) }
