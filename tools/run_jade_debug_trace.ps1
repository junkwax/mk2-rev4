param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Input2 = "fb",
    [switch]$Right,
    [switch]$Spam,
    [int]$Seconds = 70
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua      = Join-Path $ToolsDir "jade_backback_hp_test.lua"
$Dbg      = Join-Path $ToolsDir "debug_jade_illop.txt"
$Trace    = Join-Path $ToolsDir "jade_zap_trace.log"
$Out      = Join-Path $ToolsDir "debug_out.log"
$Nvram    = Join-Path "C:\MAME" "nvram\mk2"

Remove-Item -LiteralPath $Trace -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Nvram -Recurse -Force -ErrorAction SilentlyContinue

$env:JADE_BB_LOG = Join-Path $ToolsDir "jade_backback_hp_test.log"
$env:JADE_INPUT  = $Input2
if ($Right) { $env:JADE_RIGHT = "1" } else { Remove-Item Env:\JADE_RIGHT -ErrorAction SilentlyContinue }
if ($Spam)  { $env:JADE_SPAM  = "1" } else { Remove-Item Env:\JADE_SPAM  -ErrorAction SilentlyContinue }

$args = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", "640x480", "-video", "gdi",
    "-keyboardprovider", "win32", "-skip_gameinfo",
    "-debug", "-debugscript", $Dbg,
    "-autoboot_script", $Lua,
    "-seconds_to_run", $Seconds, "-sound", "none"
)
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @args *> $Out } finally {
    Pop-Location
    Remove-Item Env:\JADE_INPUT,Env:\JADE_RIGHT,Env:\JADE_SPAM,Env:\JADE_BB_LOG -ErrorAction SilentlyContinue
}
if (Test-Path $Trace) {
    $n = (Get-Content $Trace | Measure-Object -Line).Lines
    Write-Host "trace lines: $n"
} else { Write-Host "no trace file (bp may not have fired)" }
Get-Content (Join-Path $ToolsDir "jade_backback_hp_test.log") | Select-String "LOCKUP" | Select-Object -Last 1
