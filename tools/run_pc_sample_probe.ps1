param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Every = 120,
    [int]$Frames = 9000,
    [int]$Backstop = 200
)
# Samples the PC on a timer so a wedge can be resolved to a symbol. See
# tools/pc_sample_probe.lua. Feed a reported PC to: python sym_resolve.py <pc>
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "pc_sample_probe.lua"
$Log = Join-Path $ToolsDir "pc_sample_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

if (-not ("PcsWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class PcsWin {
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

$env:PCS_LOG = $Log; $env:PCS_EVERY = "$Every"; $env:PCS_FRAMES = "$Frames"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[pcs] sampling ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "pc_sample_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "pc_sample_mame.err")
for ($i = 0; $i -lt 30 -and -not $proc.HasExited; $i++) {
    if ((Get-Content $Log -ErrorAction SilentlyContinue) -match "f=") { break }
    Start-Sleep -Milliseconds 700
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [PcsWin]::DismissWarning($proc.MainWindowHandle) }
    $proc.Refresh()
}
$proc.WaitForExit()
"PCS_LOG","PCS_EVERY","PCS_FRAMES" | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host $_ } }
else { Write-Host "no log produced (warning box not dismissed? re-run)" }
