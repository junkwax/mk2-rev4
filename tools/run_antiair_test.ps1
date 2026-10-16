# run_antiair_test.ps1 - does the narrowed ANTI-AIR rung say yes to a stuffed
# jump attack and no to everything else?  See tools/sweep_addon_antiair.lua
# for what is measured.
#
# Reuses battle_stability_sweep.lua purely as a harness: it forces the matchup
# (SWEEP_P1/P2/STAGE), walks the select screen, and loads tools/sweep_addon.lua
# if that file exists.  The addon is COPIED into place for the run and removed
# afterwards, because any later stability sweep would otherwise pick it up and
# drive the sticks.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 260,
    [switch]$Throttle,
    [int]$P1 = 11,      # Jax, on the ground with the uppercut
    [int]$P2 = 8        # Sub-Zero, doing the jumping
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_antiair.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Log = Join-Path $ToolsDir "antiair.txt"
$SnapDir = Join-Path $ToolsDir "screens\antiair"

# Two MAME rigs fight over the same window and kill each other; a leftover
# key-poker job posts into whatever window appears next.  Clear both first.
Get-Process mame* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } |
    ForEach-Object { Stop-Job $_ -ErrorAction SilentlyContinue; Remove-Job $_ -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $SnapDir | Out-Null
Remove-Item $Log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
Copy-Item $Src $Addon -Force

$env:SWEEP_P1 = "$P1"
$env:SWEEP_P2 = "$P2"
$env:SWEEP_STAGE = "0"
$env:SWEEP_OBSERVE = "3000"
$env:SWEEP_LABEL = "antiair"
$env:SWEEP_LOG = Join-Path $ToolsDir "antiair_sweep.log"
$env:SWEEP_P2_HUMAN = "1"    # both sticks are the addon's - no drone in this
$env:SWEEP_NO_HP_PIN = "0"
$env:AA_LOG = $Log

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-snapshot_directory",$SnapDir,"-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
if (-not $Throttle) { $mameArgs += "-nothrottle" }

Write-Host "[aa] P1=$P1 (grounded uppercut) vs P2=$P2 (jumping in), Dead Pool ..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "antiair_mame.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "antiair_mame.err")

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
                 "SWEEP_LOG","SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","AA_LOG")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}

if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[aa] no log produced" }
