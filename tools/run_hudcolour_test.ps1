# run_hudcolour_test.ps1 - the HUD's colours and icon spacing.  See tools/sweep_addon_hudcolour.lua for what is measured.
#
# Reuses battle_stability_sweep.lua purely as a harness: it already forces the
# matchup (SWEEP_P1/P2/STAGE) and walks the select screen, and it loads
# tools/sweep_addon.lua if that file exists.  The addon is COPIED into place
# for the run and removed afterwards, because any later stability sweep would
# otherwise pick it up and drive the sticks.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 260,
    [switch]$Throttle,
    # Character driving the move: 4 = Kitana (square wave),
    # 15 = Noob (portal), 17 = Ermac (telekinetic slam).
    [int]$P1 = 4,
    # 1 = p1 opens (his toast + readout), 2 = p2 opens (mirrored toast)
    [int]$Side = 1,
    # keep jabbing so one string runs long and the numbers gain digits
    [switch]$Chain
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_hudcolour.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "hudcolour.txt"
$SnapDir = Join-Path $ToolsDir "screens\hudcolour"

# Two MAME rigs fight over the same window and kill each other; a leftover
# key-poker job posts into whatever window appears next.  Clear both first.
Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "1"          # Liu Kang
$env:SWEEP_P2 = "11"         # Jax, as the DRONE
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "3000"  # three phases of 900 frames plus settle
$env:SWEEP_LABEL = "hudcolour"
$env:SWEEP_LOG = Join-Path $ToolsDir "hudcolour_sweep.log"
$env:SWEEP_P2_HUMAN = "1"    # P2 must be the AI - that is the point
$env:SWEEP_NO_HP_PIN = "0"
$env:HCOL_LOG = $Log
$env:HCOL_SIDE = "$Side"
$env:HCOL_CHAIN = $(if ($Chain) { "1" } else { "0" })


$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
if (-not $Throttle) { $mameArgs += "-nothrottle" }

Write-Host "[hcol] Liu Kang (P1) vs Jax (P2, human), Dead Pool ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "hudcolour_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "hudcolour_mame.err")

# Poke past the ROM-warning screen; without this the battle silently never
# starts and scores as a failure it never had.
$wsh = New-Object -ComObject WScript.Shell
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) { break }
    if (Test-Path $Log) { break }
    try { $wsh.AppActivate($proc.Id) | Out-Null; $wsh.SendKeys("{ENTER}") } catch {}
}

$proc | Wait-Process -Timeout ($Backstop + 90) -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

Remove-Item $Addon -ErrorAction SilentlyContinue
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL",
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","HCOL_LOG","HCOL_SIDE","HCOL_CHAIN")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[hcol] no log produced" }
Write-Host "[hcol] snapshots: $SnapDir"
