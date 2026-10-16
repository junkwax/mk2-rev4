#
# run_deadpool_hanger_layout.ps1 - THE DEAD POOL hanger layout editor.
#
# Boots a 2-player idle match onto the Dead Pool at real speed and hands you
# the nine hanging bodies (tools/deadpool_hanger_layout.lua has the keys).
# Enter saves tools/hanger_layout.txt, which is then plugged into
# hanger_initab (src/MKHANG.ASM).
#
#   .\tools\run_deadpool_hanger_layout.ps1
#   .\tools\run_deadpool_hanger_layout.ps1 -Resolution 1600x1016
#
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "1200x762",
    [int]$P1Char = 1,
    [int]$P2Char = 11
)

$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "deadpool_hanger_layout.lua"

$OutDir = Join-Path $ToolsDir "screens\deadpool_hanger_layout"
$Private = Join-Path $OutDir "state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null
Remove-Item -Recurse -Force (Join-Path $Private "nvram\*") -ErrorAction SilentlyContinue
$Ready = Join-Path $OutDir "ready.flag"
Remove-Item $Ready -ErrorAction SilentlyContinue

# the map has to match the ROM or every address the editor writes is wrong
$map = Join-Path $RepoRoot "src\mk2.map"
$rom = Join-Path $RomPath "mk2.zip"
if ([math]::Abs(((Get-Item $rom).LastWriteTime - (Get-Item $map).LastWriteTime).TotalMinutes) -gt 30) {
    Write-Warning "[layout] mk2.map and rom\mk2.zip are more than 30 min apart - rebuild/repackage first or the editor pokes the wrong RAM."
}

if (-not ("HangLayout.Win" -as [type])) {
    Add-Type -Namespace HangLayout -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
}

$env:HL_ROOT = $RepoRoot.Replace("\", "/")
$env:HL_READY = $Ready.Replace("\", "/")
$env:HL_P1_CHAR = [string]$P1Char
$env:HL_P2_CHAR = [string]$P2Char

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-keyboardprovider", "win32", "-skip_gameinfo", "-sound", "none",
    "-snapshot_directory", $OutDir,
    "-cfg_directory", (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-autoboot_script", $LuaScript
)
$proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -WorkingDirectory (Split-Path -Parent $Mame) -PassThru

# get past MAME's CRC warning screen (source-built program ROMs)
$deadline = (Get-Date).AddSeconds(60)
while (-not $proc.HasExited -and -not (Test-Path $Ready) -and (Get-Date) -lt $deadline) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        foreach ($k in 0x0D, 0x20) {
            [HangLayout.Win]::PostMessage($h, 0x100, [IntPtr]$k, [IntPtr]0) | Out-Null
            Start-Sleep -Milliseconds 60
            [HangLayout.Win]::PostMessage($h, 0x101, [IntPtr]$k, [IntPtr]0) | Out-Null
        }
    }
    Start-Sleep -Milliseconds 700
}
Write-Host "[layout] editor running - Enter in the game window saves tools\hanger_layout.txt"
