param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string[]]$Char = @("mileena", "scorpion"),
    [int]$Diff = 9,
    [int]$Backstop = 400
)
# Does the drone actually PERFORM the scripted combos? The stability sweep
# only proves nothing crashed. Reports link by link, so a broken chain names
# which link it broke at instead of just failing.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_combo_test.lua"

if (-not ("ComboWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class ComboWin {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    static void Press(IntPtr h, int vk) {
        PostMessage(h, 0x0100, (IntPtr)vk, IntPtr.Zero); Thread.Sleep(60);
        PostMessage(h, 0x0101, (IntPtr)vk, IntPtr.Zero);
    }
    static void Ch(IntPtr h, char c) { PostMessage(h, 0x0102, (IntPtr)c, IntPtr.Zero); }
    // rawinput ignores synthetic keys, so the runner must pass
    // -keyboardprovider win32 for these posts to register at all.
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
    $Log = Join-Path $ToolsDir "drone_combo_$c.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:COMBO_LOG = $Log; $env:COMBO_CHAR = $c; $env:COMBO_DIFF = "$Diff"
    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[combo] $c (diff $Diff) ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $ToolsDir "drone_combo_mame.log") `
        -RedirectStandardError  (Join-Path $ToolsDir "drone_combo_mame.err")

    # The "lua never started" flake is the ROM-warning screen: MAME sits on it
    # burning ~1% CPU and the autoboot script never runs, so the character comes
    # back NO LOG and reads as "untested" (that is how Mileena was lost once).
    # ui.ini has skip_warnings=1 and it still happened, so do not trust it --
    # poke until the lua log EXISTS, which is the real proof the script is live.
    $started = $false
    for ($i = 0; $i -lt 40 -and -not $proc.HasExited; $i++) {
        if (Test-Path $Log) { $started = $true; break }
        Start-Sleep -Milliseconds 700
        $h = $proc.MainWindowHandle
        if ($h -ne [IntPtr]::Zero) { [ComboWin]::DismissWarning($h) }
        $proc.Refresh()
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "  (warning screen persisted; lua still not up after 30s)"
    }
    $proc.WaitForExit()
    "COMBO_LOG","COMBO_CHAR","COMBO_DIFF" | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    if (Test-Path $Log) {
        Get-Content $Log | Select-String "link |FULL CHAIN|RESULT|PASS |FAIL |ERROR|FATAL|armed |conversion" |
            ForEach-Object { Write-Host "  $($_.Line)" }
        $v = (Get-Content $Log | Select-String "PASS |FAIL " | Select-Object -Last 1)
        $summary += [pscustomobject]@{ Char=$c; Verdict = if ($v) { $v.Line } else { "NO VERDICT" } }
    } else {
        Write-Host "  no log (MAME lua-never-started flake? re-run)"
        $summary += [pscustomobject]@{ Char=$c; Verdict="NO LOG" }
    }
}
Write-Host "`n===== DRONE COMBOS ====="
$summary | ForEach-Object { Write-Host ("{0,-10} {1}" -f $_.Char, $_.Verdict) }
