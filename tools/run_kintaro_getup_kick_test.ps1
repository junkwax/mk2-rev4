param(
    # Its own binary: two rigs sharing one mame.exe kill each other mid-run
    # and the log stops with exit -1 that looks exactly like a crash.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 180,
    [int]$Frames = 5400,
    [int]$Diff = 9
)
# One Kintaro get-up-kick trial.  P1 is pinned on top of him uppercutting on a
# loop; every knockdown puts boss_getup through goro_getup_kick_check, whose
# branches are counted separately off @debug4.  See the header of
# tools/kintaro_getup_kick_test.lua for what each breadcrumb means.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "kintaro_getup_kick_test.lua"
$Log = Join-Path $ToolsDir "kintaro_getup_kick_test.log"
$MameLog = Join-Path $ToolsDir "kintaro_getup_kick_mame.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:KGK_LOG = $Log
$env:KGK_FRAMES = "$Frames"
$env:KGK_DIFF = "$Diff"

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[kgk] running Kintaro get-up kick trial (diff=$Diff, $Frames fight frames)..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameLog } finally { Pop-Location }

foreach ($e in @("KGK_LOG","KGK_FRAMES","KGK_DIFF")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

if (-not (Test-Path $Log)) {
  Write-Host "[kgk] NO-VERDICT - no log written; check $MameLog"
  exit 1
}
Get-Content $Log
$verdict = Get-Content $Log | Select-String "^\[kgk\] (PASS|PARTIAL|FAIL)" | Select-Object -Last 1
Write-Host "`n===== KINTARO GET-UP KICK ====="
if ($verdict) { Write-Host $verdict.Line } else { Write-Host "NO-VERDICT - see $Log and $MameLog" }
Write-Host "Full log: $Log"
