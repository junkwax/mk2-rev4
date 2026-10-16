param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 240
)
# Fluidity check: watches both fighters every frame and reports any sprite
# that is MOVING with a frozen image, or any process stuck on one action.
# This is the regression net for "the CPU stutters / pauses" -- a cooldown
# must never be visible as the sprite hitching.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "ai_anim_debug.lua"
$Log = Join-Path $ToolsDir "ai_anim_debug.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[ai-dbg] watching for frozen anims / stuck actions ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "ai_anim_debug_mame.log") } finally { Pop-Location }

Write-Host "`n===== ANIM FLUIDITY ====="
if (-not (Test-Path $Log)) {
    Write-Host "no log produced (MAME lua-never-started flake? re-run)"
    exit 1
}
$missing = Get-Content $Log | Select-String "MISSING SYMBOL"
if ($missing) { $missing | ForEach-Object { Write-Host $_.Line }; Write-Host "-> results are worthless"; exit 1 }

$frozen = @(Get-Content $Log | Select-String "ANIM-FROZEN")
$stuck  = @(Get-Content $Log | Select-String "ACT-STUCK")
$launch = @(Get-Content $Log | Select-String "SKY-LAUNCH")
$acts   = @(Get-Content $Log | Select-String "act [0-9a-f]{4} ->")

Write-Host ("anim-frozen : {0}" -f $frozen.Count)
Write-Host ("act-stuck   : {0}" -f $stuck.Count)
Write-Host ("sky-launch  : {0}" -f $launch.Count)
Write-Host ("act changes : {0}   (evidence the fight actually ran)" -f $acts.Count)
$frozen + $stuck + $launch | Select-Object -First 12 | ForEach-Object { Write-Host $_.Line }

if ($frozen.Count -eq 0 -and $stuck.Count -eq 0 -and $acts.Count -gt 30) {
    Write-Host "`nPASS fluidity: no frozen sprites, no stuck processes"
} else {
    Write-Host "`nFAIL fluidity: see above"
}
Write-Host "Full log: $Log"
