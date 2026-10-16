param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$HoldFrames = 1200,
    [int]$Backstop = 400
)
# Does Baraka's victory play its blade sparks, and does the game survive the
# hold afterwards? The reported crash came AFTER the sparks, so the hold is
# the test, not the animation.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "baraka_victory_test.lua"
$Log = Join-Path $ToolsDir "baraka_victory_test.log"

if (-not ("BarakaWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class BarakaWin {
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

Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:BARAKA_VICTORY_LOG = $Log
$env:BARAKA_HOLD_FRAMES = "$HoldFrames"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[baraka] victory test (hold $HoldFrames frames) ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "baraka_victory_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "baraka_victory_mame.err")

# Poke past the ROM-warning screen until the lua is demonstrably alive.
for ($i = 0; $i -lt 40 -and -not $proc.HasExited; $i++) {
    if (Test-Path $Log) { break }
    Start-Sleep -Milliseconds 700
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [BarakaWin]::DismissWarning($proc.MainWindowHandle) }
    $proc.Refresh()
}
$proc.WaitForExit()

if (Test-Path $Log) {
    Get-Content $Log | Select-String "SPARKS|HIDDEN|UGVICTORY7|sparks |sparks:|max multipart|post-victory|PASS |FAIL |FATAL|BAD gstate|went NULL|ADVANCED|gstate " |
        ForEach-Object { Write-Host "  $($_.Line)" }
} else {
    Write-Host "  no log (MAME never started - re-run)"
}
