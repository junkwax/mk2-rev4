param(
    # Its own binary: two rigs sharing one mame.exe kill each other mid-run
    # and the log stops with exit -1 that looks exactly like a crash.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 180,
    [int]$Frames = 5400,
    [int]$Diff = 9,
    # Snapshot the whole lane, a frame-triple at a time - the spin has to be
    # looked at, not reasoned about.
    [switch]$Shots
)
# One Kintaro backhand trial.  P1 is teleported to Kintaro's other side on a
# timer, which is what makes am_i_facing_him fail and sends him to
# drone_turnaround - the only road to goro_backhand.  Its branches (started /
# connected / whiffed / too far / roll declined) are counted off @debug4.
# See the header of
# tools/kintaro_backhand_test.lua for what each breadcrumb means.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "kintaro_backhand_test.lua"
$Log = Join-Path $ToolsDir "kintaro_backhand_test.log"
$MameLog = Join-Path $ToolsDir "kintaro_backhand_mame.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:KBH_LOG = $Log
$env:KBH_FRAMES = "$Frames"
$env:KBH_DIFF = "$Diff"
if ($Shots) { $env:KBH_SHOTS = "1" } else { Remove-Item Env:\KBH_SHOTS -ErrorAction SilentlyContinue }

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[kbh] running Kintaro backhand trial (diff=$Diff, $Frames fight frames)..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameLog } finally { Pop-Location }

foreach ($e in @("KBH_LOG","KBH_FRAMES","KBH_DIFF","KBH_SHOTS")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

if (-not (Test-Path $Log)) {
  Write-Host "[kbh] NO-VERDICT - no log written; check $MameLog"
  exit 1
}
Get-Content $Log
$verdict = Get-Content $Log | Select-String "PASS|PARTIAL|FAIL" | Select-Object -Last 1
Write-Host "`n===== KINTARO BACKHAND ====="
if ($verdict) { Write-Host $verdict.Line } else { Write-Host "NO-VERDICT - see $Log and $MameLog" }
Write-Host "Full log: $Log"
