param(
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 900,
    [int]$SnapEvery = 3,
    # souls = the real thing; control = an ordinary CPU opponent, which must
    # still get a normal FINISH HIM and never the souls
    [ValidateSet("souls","control")][string]$Mode = "souls",
    [int]$Stage = -1,       # control mode: force curback, to compare arenas
    [int]$DumpAt = 0        # dump every object N frames after winner_status 4
)
# Shang defeated: the souls escape (src/MKSOULS.ASM).  AUTOMATIC: a real
# one-player game against a CPU Shang, won twice, then the whole sequence is
# recorded.  See tools/shang_soul_escape_test.lua for what PASS requires.
#
# Output: tools\screens\shang_soul_escape\run_<id>\ - snapshots + the log.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "shang_soul_escape_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $ToolsDir "screens\shang_soul_escape\run_$RunId"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Log = Join-Path $OutDir "shang_soul_escape_test.log"
$Ready = Join-Path $OutDir "ready.flag"

# Private cfg/nvram: a fresh CMOS every run (leftover credits desync the
# coin/start schedule) and never the repo's committed cfg with TEST on.
$Private = Join-Path $OutDir "state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null

if (-not ("Sse.Win" -as [type])) {
    Add-Type -Namespace Sse -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
}

$env:SSE_LOG = $Log.Replace("\", "/")
$env:SSE_READY = $Ready.Replace("\", "/")
$env:SSE_SNAP_EVERY = "$SnapEvery"
$env:SSE_MODE = $Mode
$env:SSE_STAGE = "$Stage"
$env:SSE_DUMP_AT = "$DumpAt"
$mameArgs = @("-rompath", $RomPath, "mk2", "-window", "-nomaximize", "-resolution", "800x600",
    "-video", "gdi", "-sound", "none", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-snapshot_directory", $OutDir,
    "-cfg_directory", (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-autoboot_script", $Lua, "-seconds_to_run", $Backstop)
$mameLog = Join-Path $OutDir "mame_out.log"
$proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs -WorkingDirectory (Split-Path -Parent $Mame) `
    -RedirectStandardOutput $mameLog -PassThru -WindowStyle Normal

# Source-built sets trip MAME's CRC warning and it parks there at ~0 CPU.
# Post Enter/Space until the Lua's ready flag (written at frame 120, i.e.
# frames are really running) - NOT the log, which the Lua opens at load.
$deadline = (Get-Date).AddSeconds(90)
while (-not $proc.HasExited -and -not (Test-Path $Ready) -and (Get-Date) -lt $deadline) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        foreach ($k in 0x0D, 0x20) {
            [Sse.Win]::PostMessage($h, 0x100, [IntPtr]$k, [IntPtr]0) | Out-Null
            Start-Sleep -Milliseconds 60
            [Sse.Win]::PostMessage($h, 0x101, [IntPtr]$k, [IntPtr]0) | Out-Null
        }
    }
    Start-Sleep -Milliseconds 700
}
if (-not (Test-Path $Ready)) {
    Write-Host "NO READY FLAG - MAME never ran frames; killing it"
    if (-not $proc.HasExited) { $proc.Kill() }
} else {
    $proc.WaitForExit()
}
Remove-Item "Env:\SSE_LOG", "Env:\SSE_READY", "Env:\SSE_SNAP_EVERY", "Env:\SSE_MODE", "Env:\SSE_STAGE", "Env:\SSE_DUMP_AT" -ErrorAction SilentlyContinue
Write-Host "run dir: $OutDir"
if (Test-Path $Log) { Get-Content $Log | Select-Object -Last 45 } else { Write-Host "NO LOG" }
