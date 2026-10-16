param(
    [ValidateSet("ground", "air", "aim", "both")]
    [string]$Mode = "both",
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 180,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LuaScript = Join-Path $ToolsDir "kitana_fan_catch_test.lua"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"

$modes = if ($Mode -eq "both") { @("ground", "air", "aim") } else { @($Mode) }
$failed = $false

foreach ($m in $modes) {
    $LogPath = Join-Path $ToolsDir "kitana_fan_catch_$m.log"
    $MameOutLog = Join-Path $ToolsDir "kitana_fan_catch_${m}_mame_out.log"
    $RunSnapshots = Join-Path $ToolsDir "screens\kitana_fan_catch\run_${RunId}_$m"

    New-Item -ItemType Directory -Force -Path $RunSnapshots | Out-Null
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue

    # Boot determinism: leftover CMOS credits desync the scripted coin/start
    # schedule, so every run starts on a FRESH PRIVATE nvram.  This used to
    # delete C:\MAME\nvram\mk2 - the user's own cmos, which is where the
    # earned hidden fighters live.
    $PrivState = Join-Path $ToolsDir "..\tmp\fancatch_state\$m"
    Remove-Item -LiteralPath $PrivState -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $PrivState "nvram"), (Join-Path $PrivState "cfg") | Out-Null
    $PrivState = (Resolve-Path $PrivState).Path

    $env:FANCATCH_MODE = $m
    $env:FANCATCH_LOG = $LogPath -replace '\\', '/'

    # The red ROM-warning screen is posted on every run (source-built ROMs
    # never match MAME's CRC table) and a MAME parked on it is NOT emulating,
    # so -seconds_to_run never fires: the run hangs at ~0 CPU with only the
    # Lua's own header in the log.  It has to be answered by a SEPARATE
    # process - this shell redirects MAME's output and never owns the
    # foreground, so its own SetForegroundWindow is refused.
    # ReadyFile is the Lua's frame-120 flag, never its log: the log exists
    # from script load, which is before any frame has run.
    $ReadyFile = "$LogPath.ready"
    Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue

    # Dismiss the instance WE launched, not whichever mame.exe answers first.
    # This used to take `Get-Process mame | Select-Object -First 1`, which on a
    # machine with any other MAME running (a trainer, a long measuring run)
    # sends the keystrokes at THAT one and returns - our own instance then sits
    # on the red warning screen until the 90s deadline, which reads as "the Lua
    # never loaded" rather than as a process-selection bug.  So snapshot the
    # pids that already exist and wait for one that is NOT among them.
    $preExisting = @(Get-Process mame -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $dismisser = Start-Job -ArgumentList $ToolsDir, $ReadyFile, $preExisting -ScriptBlock {
        param($tools, $ready, $known)
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            $p = Get-Process mame -ErrorAction SilentlyContinue |
                 Where-Object { $known -notcontains $_.Id } |
                 Select-Object -First 1
            if ($p) {
                & (Join-Path $tools "mame_dismiss_warning.ps1") -ProcessId $p.Id -ReadyFile $ready
                return
            }
            Start-Sleep -Milliseconds 200
        }
    }

    # Direct blocking call, not Start-Process: under pwsh 7 the Start-Process
    # path mangles the command line and -autoboot_script never loads.
    $mameArgs = @(
        "-rompath", $RomPath,
        "mk2",
        "-window", "-nomaximize",
        "-resolution", $Resolution,
        "-video", "gdi",
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-snapshot_directory", $RunSnapshots,
        "-nvram_directory", (Join-Path $PrivState "nvram"),
        "-cfg_directory", (Join-Path $PrivState "cfg"),
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[fancatch] Launching MODE=$m ..."
    Push-Location (Split-Path -Parent $Mame)
    try {
        & $Mame @mameArgs *> $MameOutLog
    } finally {
        Pop-Location
        Stop-Job $dismisser -ErrorAction SilentlyContinue
        Remove-Job $dismisser -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $LogPath) {
        Write-Host "[fancatch] $m log tail:"
        Get-Content -Path $LogPath -Tail 30
        if (Select-String -Path $LogPath -Pattern "\[fancatch\] ERROR" -Quiet) {
            Write-Host "[fancatch] $m reported an ERROR." -ForegroundColor Red
            $failed = $true
        }
        if (-not (Select-String -Path $LogPath -Pattern "\[fancatch\] PASS" -Quiet)) {
            Write-Host "[fancatch] $m did not report PASS." -ForegroundColor Red
            $failed = $true
        }
    } else {
        Write-Host "[fancatch] $m log was not created." -ForegroundColor Red
        $failed = $true
    }
    Write-Host "[fancatch] $m snapshots: $RunSnapshots"
}

if ($failed) { exit 1 }
Write-Host "[fancatch] all modes PASS"
