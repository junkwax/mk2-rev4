# run_backblock_dip_test.ps1 - the back-block dipswitch, both positions.
#
# The retired Comic Book Offer switch (dip_backblock, DIPEQU.ASM) turns
# "holding away blocks" on and off.  MAME still calls it "Comic Book Offer":
# On (the default) = back-block on, Off = button-only (retail).
# See tools/sweep_addon_backblock_dip.lua for what is measured.
#
# Private rompath (a frozen copy of the zip + map), cfg and nvram, so it
# neither touches the user's MAME settings nor races another session's
# build.  Kills only the MAME it started.
param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$Zip = "C:\Users\you\Workplace\mk2-main\rom\mk2.zip",
    [ValidateSet("both","on","off")][string]$Mode = "both",
    [int]$Backstop = 200
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Addon = Join-Path $ToolsDir "sweep_addon.lua"
$Src = Join-Path $ToolsDir "sweep_addon_backblock_dip.lua"
$Lua = Join-Path $ToolsDir "battle_stability_sweep.lua"
$Work = Join-Path $Root "tmp\backblock_dip"

if (Test-Path $Addon) { Write-Host "[bbdip] tools\sweep_addon.lua exists - another rig is running. Refusing."; exit 2 }
New-Item -ItemType Directory -Force (Join-Path $Work "rom") | Out-Null
Copy-Item $Zip (Join-Path $Work "rom\mk2.zip") -Force
Copy-Item (Join-Path $Root "src\mk2.map") (Join-Path $Work "mk2.map") -Force

$modes = if ($Mode -eq "both") { @("on","off") } else { @($Mode) }
$fail = 0
foreach ($m in $modes) {
    $cfg = Join-Path $Work "cfg_$m"; $nv = Join-Path $Work "nvram_$m"
    Remove-Item -Recurse -Force $cfg, $nv -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $cfg, $nv | Out-Null
    # Comic Book Offer is raw mask 0x0800 (2048); value 2048 = On, 0 = Off.
    $val = if ($m -eq "on") { 2048 } else { 0 }
    @"
<?xml version="1.0"?>
<mameconfig version="10">
    <system name="mk2">
        <input>
            <port tag=":DSW" type="DIPSWITCH" mask="2048" defvalue="2048" value="$val" />
        </input>
    </system>
</mameconfig>
"@ | Set-Content -Encoding ascii (Join-Path $cfg "mk2.cfg")

    $Log = Join-Path $Work "backblock_$m.txt"
    Remove-Item $Log -ErrorAction SilentlyContinue
    Copy-Item $Src $Addon -Force
    $env:SWEEP_P1 = "1"; $env:SWEEP_P2 = "11"; $env:SWEEP_STAGE = "0"
    $env:SWEEP_OBSERVE = "1800"; $env:SWEEP_LABEL = "bbdip_$m"
    $env:SWEEP_LOG = Join-Path $Work "sweep_$m.log"
    $env:SWEEP_P2_HUMAN = "1"; $env:SWEEP_NO_HP_PIN = "0"
    $env:BB_LOG = $Log; $env:BB_EXPECT = $m; $env:BB_MAP = Join-Path $Work "mk2.map"

    $mameArgs = @("-rompath",(Join-Path $Work "rom"),"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-cfg_directory",$cfg,"-nvram_directory",$nv,
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop,"-nothrottle")
    Write-Host "[bbdip] DIP $m ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput (Join-Path $Work "mame_$m.log") `
        -RedirectStandardError  (Join-Path $Work "mame_$m.err")
    Start-Process -WindowStyle Hidden pwsh -ArgumentList @("-NoProfile","-File",
        (Join-Path $ToolsDir "mame_dismiss_warning.ps1"),"-ProcessId",$proc.Id,"-ReadyFile",$Log) | Out-Null
    $proc | Wait-Process -Timeout ($Backstop + 60) -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $Addon -ErrorAction SilentlyContinue

    if (Test-Path $Log) { Get-Content $Log } else { Write-Host "[bbdip] no log produced" }
    if (-not ((Test-Path $Log) -and (Select-String -Quiet -Path $Log -Pattern "VERDICT PASS"))) { $fail++ }
}
foreach ($e in @("SWEEP_P1","SWEEP_P2","SWEEP_STAGE","SWEEP_OBSERVE","SWEEP_LABEL","SWEEP_LOG",
                 "SWEEP_P2_HUMAN","SWEEP_NO_HP_PIN","BB_LOG","BB_EXPECT","BB_MAP")) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}
if ($fail -eq 0) { Write-Host "[bbdip] ALL PASS"; exit 0 } else { Write-Host "[bbdip] $fail run(s) did not PASS"; exit 1 }
