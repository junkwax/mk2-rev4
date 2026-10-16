#
# run_deadpool_rotation_probe.ps1 - THE DEAD POOL hangs three bodies a match.
#
# Proves the three things hp_pick_lineup (MKHANG.ASM) is there to do, off the
# running machine rather than off the source: three bodies hang, one in each
# zone (left corner / the view the round opens on / right corner), and the
# next three are not the three before them.
#
#   .\tools\run_deadpool_rotation_probe.ps1
#   .\tools\run_deadpool_rotation_probe.ps1 -Picks 9      # watch more cycles
#   .\tools\run_deadpool_rotation_probe.ps1 -Mode drops   # the OTHER half
#   .\tools\run_deadpool_rotation_probe.ps1 -Throttle     # watch it at speed
#
# -Mode drops plays a real match out instead: the three stay the same for the
# whole match, a body that went in stays in, and only one or two MORE fall in
# any round (hp_round_cap).
#
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [ValidateSet("rotate","drops")][string]$Mode = "rotate",
    [int]$Picks = 6,
    [int]$BackstopEmuSeconds = 420,
    [switch]$Throttle
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "deadpool_rotation_probe.lua"

$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $ToolsDir "screens\deadpool_rotation\run_$RunId"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Log = Join-Path $OutDir "deadpool_rotation_probe.log"
$Ready = Join-Path $OutDir "ready.flag"
$MameLog = Join-Path $OutDir "mame_out.log"
$LatestLog = Join-Path $ToolsDir "deadpool_rotation_probe.log"

# Private cfg/nvram: leftover credits desync the scripted coin/start schedule.
$Private = Join-Path $OutDir "state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

# The map has to match the ROM under test or every symbol read is garbage.
$map = Join-Path $RepoRoot "src\mk2.map"
$rom = Join-Path $RomPath "mk2.zip"
if (-not (Test-Path $map)) { Write-Error "[dprot] no src\mk2.map - build first." }
if (-not (Test-Path $rom)) { Write-Error "[dprot] no $rom - run mamerom.py." }
$mapAge = (Get-Item $map).LastWriteTime
$romAge = (Get-Item $rom).LastWriteTime
if ([math]::Abs(($romAge - $mapAge).TotalMinutes) -gt 30) {
    Write-Warning "[dprot] mk2.map ($mapAge) and mk2.zip ($romAge) are more than 30 min apart - symbol reads may be stale."
}

if (-not ("DpRot.Win" -as [type])) {
    Add-Type -Namespace DpRot -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
}

$env:DP_ROOT = $RepoRoot.Replace("\", "/")
$env:DP_TEST_LOG = $Log.Replace("\", "/")
$env:DP_READY = $Ready.Replace("\", "/")
$env:DP_PICKS = [string]$Picks
$env:DP_MODE = $Mode

$mameArgs = @(
    "-rompath", $RomPath,
    "mk2",
    "-window", "-nomaximize",
    "-resolution", $Resolution,
    "-video", "gdi",
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-snapshot_directory", $OutDir,
    "-cfg_directory", (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-sound", "none",
    "-autoboot_script", $LuaScript,
    "-seconds_to_run", $BackstopEmuSeconds
)
if (-not $Throttle) { $mameArgs += "-nothrottle" }

Write-Host "[dprot] mode=$Mode picks=$Picks rom=$rom"
$proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -WorkingDirectory (Split-Path -Parent $Mame) `
    -RedirectStandardOutput $MameLog -PassThru -WindowStyle Normal

# Source-built sets trip MAME's CRC warning and it parks there at ~0 CPU.
$deadline = (Get-Date).AddSeconds(120)
while (-not $proc.HasExited -and -not (Test-Path $Ready) -and (Get-Date) -lt $deadline) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        foreach ($k in 0x0D, 0x20) {
            [DpRot.Win]::PostMessage($h, 0x100, [IntPtr]$k, [IntPtr]0) | Out-Null
            Start-Sleep -Milliseconds 60
            [DpRot.Win]::PostMessage($h, 0x101, [IntPtr]$k, [IntPtr]0) | Out-Null
        }
    }
    Start-Sleep -Milliseconds 700
}
$noFrames = -not (Test-Path $Ready)
if ($noFrames) {
    Write-Warning "[dprot] no ready flag - MAME never ran frames; killing it"
    if (-not $proc.HasExited) { $proc.Kill() }
} else {
    $proc.WaitForExit()
}

"DP_ROOT", "DP_TEST_LOG", "DP_READY", "DP_PICKS", "DP_MODE" |
    ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

if (Test-Path $Log) {
    Copy-Item -LiteralPath $Log -Destination $LatestLog -Force
    Get-Content -Path $Log
    if (-not (Select-String -Path $Log -Pattern "RESULT " -Quiet)) {
        Write-Warning "[dprot] no verdict - see $Log / $MameLog"
    }
} elseif (-not $noFrames) {
    Write-Error "[dprot] lua log was not created (see $MameLog)."
}
Write-Host "[dprot] Run dir: $OutDir"
