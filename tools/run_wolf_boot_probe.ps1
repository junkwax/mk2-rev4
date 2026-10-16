# run_wolf_boot_probe.ps1 - boot rom/wolf/umk3.zip (makewolf.py) in MAME's
# umk3 driver and record what it does: PC / gstate / tick every 60 frames
# plus snapshots, into tmp/wolf_boot/.  Private nvram/cfg/snapshot dirs;
# never writes C:\MAME\roms or the user's nvram; kills only its own pid.
# -Game mk2 runs the SAME script on the T-unit set, from tmp\tunit_rom\mk2.zip
# (package it first: python mamerom.py --no-install --output tmp/tunit_rom/mk2.zip,
# so it matches src\mk2.map) into tmp\wolf_boot_mk2\ - the control for any
# board-to-board comparison.  Never the installed C:\MAME\roms set: that can be
# another session's build, and a map from a different build pokes wrong RAM.
param(
    [int]$Frames = 3600,
    [switch]$Coin,          # insert two coins and press 1P start at frame 1500
    [switch]$Listen,        # record sound to <out>\wolf.wav
    [string]$DebugScript = "",  # run under MAME's debugger with this -debugscript (it must end in `go`)
    [switch]$Inputs,        # check every button lands on its T-unit bit, then LP/LK in a fight (implies -Coin)
    [switch]$Negative,      # with -Inputs: swap the gsw/gsw2 addresses - the mirror rows MUST fail
    [string[]]$Peek = @(),  # symbols (or 8-hex-digit raw bit addresses) logged every 600 frames, 16-bit
    [string[]]$Poke = @(),  # SYMBOL=value written every frame in -PokeStates, e.g. -Poke f_colbox=5
    [int[]]$PokeStates = @(2),  # gstates -Poke writes in (2 = fighting; 4,7 = select/VS, before the stage loads)
    [ValidateSet("umk3", "mk2")][string]$Game = "umk3",
    [string]$Script = "wolf_boot_probe.lua",   # autoboot script in tools/ (wolf_vrom_reach_test.lua, ...)
    [string[]]$Env = @(),                      # extra NAME=value pairs for that script
    [string]$Out = "",                         # output dir (default tmp\wolf_boot or tmp\wolf_boot_mk2)
    [int]$TimeoutSec = 300,                    # backstop for the whole MAME run
    [string[]]$Press = @(),                    # "frame:Field Name:hold" presses, any port (e.g. "600:Service Mode:10")
    [int[]]$Shots = @(),                       # snapshot frames (replaces the default schedule)
    [string[]]$Dip = @(),                      # "Field Name=value" DIPs set before boot, e.g. "Powerup Test=512"
    [string]$RomDir = "",                      # a zip dir other than rom\wolf (a test set; never overwrite the built one)
    [string]$MameExe = "C:\MAME\mame.exe"   # tools\mame_wolf\mame_wolf.exe = umk3 with sound sockets u6-u9
)
if ($Inputs) { $Coin = $true; if ($Frames -lt 4500) { $Frames = 4500 } }
$Root  = Split-Path -Parent $PSScriptRoot
$Mame  = $MameExe
$OutArg = $Out
if ($Game -eq "mk2") {
    $Out  = Join-Path $Root "tmp\wolf_boot_mk2"
    $RomD = Join-Path $Root "tmp\tunit_rom"
    $Map  = Join-Path $Root "src\mk2.map"
} else {
    $Out  = Join-Path $Root "tmp\wolf_boot"
    $RomD = Join-Path $Root "rom\wolf"
    $Map  = Join-Path $Root "tmp\wolf\src\MK2.MAP"
}
if ($OutArg) { $Out = if ([IO.Path]::IsPathRooted($OutArg)) { $OutArg } else { Join-Path $Root $OutArg } }   # MAME runs in C:\MAME
$Log = Join-Path $Out "probe.log"
if ($RomDir) { $RomD = if ([IO.Path]::IsPathRooted($RomDir)) { $RomDir } else { Join-Path $Root $RomDir } }
if (-not (Test-Path (Join-Path $RomD "$Game.zip"))) { throw "$Game.zip not in $RomD (Wolf: run makewolf.py)" }
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out, "$Out\nvram", "$Out\cfg", "$Out\snap" | Out-Null

function MapAddr($name) {
    $m = Select-String -Path $Map -CaseSensitive -Pattern ("(?:^|\s)([0-9a-fA-F]{8}) +" + $name + "(?:\s|$)") | Select-Object -First 1
    if (-not $m) { throw "symbol $name not in $Map" }
    return $m.Matches[0].Groups[1].Value
}
$env:WB_LOG    = $Log
$env:WB_GSTATE = MapAddr "gstate"
$env:WB_TICK   = MapAddr "tick"
$env:WB_FRAMES = "$Frames"
$env:WB_COIN   = if ($Coin) { "1" } else { "0" }
$env:WB_PEEK   = ($Peek | ForEach-Object { if ($_ -match '^[0-9a-fA-F]{8}$') { "raw_$_=$_" } else { "$_=" + (MapAddr $_) } }) -join ","
$env:WB_POKE   = ($Poke | ForEach-Object { $n, $v = $_ -split '='; "$n=" + (MapAddr $n) + "=$v" }) -join ","
$env:WB_PRESS  = $Press -join ";"
$env:WB_DIP    = $Dip -join ";"
$env:WB_SHOTS  = $Shots -join ","
$env:WB_POKEGS = $PokeStates -join ","
$env:WB_INPUTS = if ($Inputs) { "1" } else { "0" }
if ($Inputs) { $env:WB_GSW = MapAddr "gsw"; $env:WB_GSW2 = MapAddr "gsw2"; $env:WB_P1PROC = MapAddr "p1_proc" }
if ($Negative) { $t = $env:WB_GSW; $env:WB_GSW = $env:WB_GSW2; $env:WB_GSW2 = $t }
$extra = @()
foreach ($kv in $Env) { $n, $v = $kv -split '=', 2; Set-Item "env:$n" $v; $extra += $n }

# -keyboardprovider win32 + -video gdi: the house launch.  The warning-box
# dismisser posts its keypress to the MAME window, and only the win32
# keyboard provider sees a posted message when MAME is not foreground -
# without them the red ROM-warning box waits for a human.
$mameArgs = @($Game, "-rompath", $RomD, "-window", "-nomaximize", "-skip_gameinfo",
              "-resolution", "640x480", "-video", "gdi", "-keyboardprovider", "win32",
              "-nvram_directory", "$Out\nvram", "-cfg_directory", "$Out\cfg",
              "-snapshot_directory", "$Out\snap", "-nothrottle",
              "-autoboot_script", (Join-Path $PSScriptRoot $Script))
if ($Listen) { $mameArgs += @("-wavwrite", "$Out\wolf.wav") } else { $mameArgs += @("-sound", "none") }
if ($DebugScript) { $mameArgs += @("-debug", "-debugscript", $DebugScript) }

$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput "$Out\mame.log" -RedirectStandardError "$Out\mame.err"
$poker = Start-Process -FilePath "powershell" -PassThru -WindowStyle Hidden `
    -ArgumentList @("-ExecutionPolicy","Bypass","-File",
                    (Join-Path $PSScriptRoot "mame_dismiss_warning.ps1"),
                    "-ProcessId",$proc.Id,"-ReadyFile",$Log,"-TimeoutSec",120)
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited -or (Test-Path $Log)) { break }
}
if (-not $proc.HasExited -and -not (Test-Path $Log)) {
    Write-Host "[wolf] no lua log after 63s - parked on the warning box or failed to start; killing"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
$proc | Wait-Process -Timeout $TimeoutSec -ErrorAction SilentlyContinue
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
if ($poker -and -not $poker.HasExited) { Stop-Process -Id $poker.Id -Force -ErrorAction SilentlyContinue }
foreach ($e in @("WB_LOG","WB_GSTATE","WB_TICK","WB_FRAMES","WB_COIN","WB_INPUTS","WB_PEEK","WB_POKE","WB_POKEGS","WB_PRESS","WB_SHOTS","WB_DIP","WB_GSW","WB_GSW2","WB_P1PROC") + $extra) {
    Remove-Item "env:$e" -ErrorAction SilentlyContinue
}
Write-Host "[wolf] log: $Log"
Get-Content "$Out\mame.err" -ErrorAction SilentlyContinue | Select-Object -First 20
