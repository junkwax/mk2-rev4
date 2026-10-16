param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 300,
    # P2 gap (px) the snapshots are taken at.  Overlay is f_colbox = 5.
    [int]$ShotGap = 90
)
# Cage's AIR SHADOW KICK (Back, Down, Back + LK).  See jc_air_shadow_test.lua.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "jc_air_shadow_test.lua"
$Log = Join-Path $ToolsDir "jc_air_shadow_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

if (-not ("Jcas.Win" -as [type])) {
    Add-Type -Namespace Jcas -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
}

$env:JCAS_LOG = $Log
$env:JCAS_SHOT_GAP = "$ShotGap"
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
$mameLog = Join-Path $ToolsDir "jc_air_shadow_mame.log"
$proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -WorkingDirectory (Split-Path -Parent $Mame) `
    -RedirectStandardOutput $mameLog -PassThru -WindowStyle Normal

# Every source-built set trips MAME's checksum warning, and MAME parks on it
# with almost no CPU - it looks exactly like a slow boot.  Post Enter/Space
# until the lua's first log line appears (the keys do nothing in attract),
# and kill the run if it never starts rather than burning the backstop.
$deadline = (Get-Date).AddSeconds(60)
while (-not $proc.HasExited -and -not (Test-Path $Log) -and (Get-Date) -lt $deadline) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        foreach ($k in 0x0D, 0x20) {
            [Jcas.Win]::PostMessage($h, 0x100, [IntPtr]$k, [IntPtr]0) | Out-Null
            Start-Sleep -Milliseconds 60
            [Jcas.Win]::PostMessage($h, 0x101, [IntPtr]$k, [IntPtr]0) | Out-Null
        }
    }
    Start-Sleep -Milliseconds 700
}
if (-not (Test-Path $Log)) {
    Write-Host "NO START MARKER - MAME never ran the script; killing it"
    if (-not $proc.HasExited) { $proc.Kill() }
} else {
    $proc.WaitForExit()
}
Remove-Item "Env:\JCAS_LOG", "Env:\JCAS_SHOT_GAP" -ErrorAction SilentlyContinue
if (Test-Path $Log) { Get-Content $Log | Select-Object -Last 40 }
else { Write-Host "NO LOG" }
