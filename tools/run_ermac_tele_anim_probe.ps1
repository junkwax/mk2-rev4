param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 200,
    [int]$Snap = 3,
    [switch]$Sound
)
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "ermac_tele_anim_probe.lua"
$LogPath = Join-Path $ToolsDir "ermac_tele_anim_probe.log"
$Out = Join-Path $ToolsDir "ermac_tele_anim_probe_mame.log"

# Any MAME still up from an earlier run fights this one for the window and the
# nvram, and the loser parks with an empty log - which reads exactly like the
# move hanging the game.  See reference_mame_rig_contention.
Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:TP_LOG = $LogPath
$env:TP_SNAP = [string]$Snap
$args2 = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
           "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
           "-autoboot_script",$Lua,"-seconds_to_run",$BackstopEmuSeconds)
if (-not $Sound) { $args2 += @("-sound","none") }

Push-Location (Split-Path -Parent $Mame)
try {
  # MAME's red "One or more ROMs are incorrect - press any key" screen ALWAYS
  # appears for mk2 (undumped PLDs in the driver) and there is no
  # -skip_warnings in this build.  The rig's own input cannot answer it: the
  # Lua's UI Select field is reported MISSING, and nothing in the emulated
  # machine's ports dismisses a UI screen anyway.  When it is not answered
  # MAME sits there at ~0 CPU forever, the Lua log is never created, and the
  # run looks identical to a hang.
  #
  # mame_dismiss_warning.ps1 answers it, and it has to be a SEPARATE process -
  # its own header explains why a poker inside this shell can never win the
  # foreground.  ReadyFile is the Lua log: the moment it exists we are past
  # the screen and the poker stops, so no dismissal key lands in the game.
  $proc = Start-Process -FilePath $Mame -ArgumentList $args2 -PassThru `
            -RedirectStandardOutput $Out -RedirectStandardError "$Out.err"
  $poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
  Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
      "-ExecutionPolicy","Bypass","-File",$poker,
      "-ProcessId",$proc.Id,"-ReadyFile",$LogPath,"-TimeoutSec","120") | Out-Null
  $proc.WaitForExit()
} finally {
  Pop-Location
  Remove-Item Env:\TP_LOG,Env:\TP_SNAP -ErrorAction SilentlyContinue
  if (Test-Path "$Out.err") { Get-Content "$Out.err" | Add-Content $Out; Remove-Item "$Out.err" -Force }
}

if (Test-Path $LogPath) {
  $v = Select-String -Path $LogPath -Pattern '^\[tp\] (PASS|FAIL)' | Select-Object -Last 1
  if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never got past the ROM warning; see $Out" }
