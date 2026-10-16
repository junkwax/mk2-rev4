param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "800x600",
    [Alias("Move")]
    [string]$OnlyMove = "",
    [switch]$NormalMatch,
    [switch]$P2Control,
    # Idle Kahn in kahn_puppet_hold (AI off, polls every tick) WITHOUT giving
    # the P2 pad control, so a scripted -Move fires immediately and skips the
    # move's own AI gates.  Use this when a -Move run reports
    # move_not_acknowledged against a passive dummy.
    [switch]$PuppetHold,
    [switch]$Colbox,
    [switch]$Debug,
    [string]$DebugScript = "",
    [switch]$Sound,
    [switch]$UnlimitedHealth,
    [switch]$AllowP1Damage,
    [switch]$PortalFatality,
    # Hold both fighters at a fixed 72px spacing so neither walks. See the
    # note on the same switch in run_kahn_boss_moves_live.ps1.
    [switch]$PinPlayers,
    # Distance in PIXELS to hold the pair at with -PinPlayers.  72 is the
    # historic value.  Sweep it to measure a move's real reach instead of
    # guessing: pin at 72/112/152/192/224 and read hit vs whiff off the
    # move's own breadcrumbs.
    [int]$PinSpacing = 72,
    # Release the pin the moment the move starts, so a lunge can actually
    # travel.  Without this the pin rewrites oxpos every frame and you
    # measure the static strike box instead of the move.
    [switch]$ReleasePinOnMove,
    # Walk the VICTIM this many pixels further away, once, -PinEscapeDelay
    # frames after the move is requested.  Kahn stays where he is.  This is
    # how you make a move MISS on purpose: pinning the pair wide instead just
    # hangs the move in its own stalk loop, which the rig then reports as
    # move_not_acknowledged.  Pin INSIDE the stalk's target, then open the gap
    # during the wind-up.  See the note in kahn_boss_moves_test.lua.
    [int]$PinEscape = 0,
    # When the escape happens, in frames after the request.  Default 6 - past
    # the stalk and inside the over-the-top hammer's 7-tick wind-up.
    [int]$PinEscapeDelay = 6,
    # Pin Kahn only; P1 stays free. See run_kahn_boss_moves_live.ps1.
    # NOTE this is a LIVE-mode switch. It anchors Kahn where he stands, which
    # at round start is 192px away - out of Portal Punch range - so a scripted
    # -Move run will log move_not_acknowledged. Use -PinPlayers here instead
    # (it sets a 72px spacing); use -PinKahn when a human is walking P1 in.
    [switch]$PinKahn,
    [int]$MaxAttempts = 1,
    # Fire the SAME move this many times in ONE run.  Not a retry - MaxAttempts
    # is the retry knob; this queues the move N times so a fault that only
    # shows on the second use is reachable.  That class is real and expensive:
    # ermac_zap_proc's swpal hung the game on the SECOND fireball of a round
    # (it freed a colour map the object had inherited and did not own), and the
    # rig that threw exactly one shot could never have seen it.
    [int]$Repeat = 1,
    # Hold P1's BLOCK button through the move. Tests the OTHER half of the
    # strike record: the block byte indexes block_xfers, a different table from
    # the hit byte, so a landed hit proves nothing about the blocked path.
    # Implies -AllowP1Damage - chip damage is the measurement.
    [switch]$BlockVictim
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kahn_boss_moves_test.lua"
$LogDir = Join-Path $ToolsDir "kahn_boss_moves_test_logs"
$SnapshotDir = Join-Path $ToolsDir "screens\kahn_boss_moves"
$OutputDir = Join-Path $ToolsDir "kahn_boss_moves_test_out"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$env:KAHN_TEST_ROOT = $Root
Remove-Item Env:\KAHN_TEST_CODES -ErrorAction SilentlyContinue
if ($UnlimitedHealth) {
    $env:KAHN_UNLIMITED_HEALTH = "1"
} else {
    Remove-Item Env:\KAHN_UNLIMITED_HEALTH -ErrorAction SilentlyContinue
}
if ($AllowP1Damage -or $PortalFatality) {
    $env:KAHN_ALLOW_P1_DAMAGE = "1"
} else {
    Remove-Item Env:\KAHN_ALLOW_P1_DAMAGE -ErrorAction SilentlyContinue
}
if ($PortalFatality) {
    $env:KAHN_PORTAL_FATALITY = "1"
} else {
    Remove-Item Env:\KAHN_PORTAL_FATALITY -ErrorAction SilentlyContinue
}
if ($PinKahn) {
    $env:KAHN_PIN_KAHN = "1"
} else {
    Remove-Item Env:\KAHN_PIN_KAHN -ErrorAction SilentlyContinue
}
if ($PinEscape -gt 0) {
    $env:KAHN_PIN_ESCAPE = "$PinEscape"
    $env:KAHN_PIN_ESCAPE_DELAY = "$PinEscapeDelay"
} else {
    Remove-Item Env:\KAHN_PIN_ESCAPE -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PIN_ESCAPE_DELAY -ErrorAction SilentlyContinue
}
if ($PinPlayers) {
    $env:KAHN_PIN_PLAYERS = "1"
    $env:KAHN_PIN_SPACING = [string]$PinSpacing
    if ($ReleasePinOnMove) { $env:KAHN_PIN_RELEASE_ON_MOVE = "1" }
    else { Remove-Item Env:\KAHN_PIN_RELEASE_ON_MOVE -ErrorAction SilentlyContinue }
} else {
    Remove-Item Env:\KAHN_PIN_PLAYERS -ErrorAction SilentlyContinue
    Remove-Item Env:\KAHN_PIN_SPACING -ErrorAction SilentlyContinue
}
if ($P2Control) {
    $env:KAHN_P2_PAD = "1"
} else {
    Remove-Item Env:\KAHN_P2_PAD -ErrorAction SilentlyContinue
}
if ($PuppetHold) {
    $env:KAHN_PUPPET_HOLD = "1"
} else {
    Remove-Item Env:\KAHN_PUPPET_HOLD -ErrorAction SilentlyContinue
}
if ($Colbox) {
    $env:KAHN_COLBOX = "1"
} else {
    Remove-Item Env:\KAHN_COLBOX -ErrorAction SilentlyContinue
}
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"

$moves = @(
    @{ Code = 1; Name = "big_power" },
    @{ Code = 2; Name = "slam" },
    @{ Code = 3; Name = "sonic" },
    @{ Code = 4; Name = "portal" },
    @{ Code = 5; Name = "nupower" },
    @{ Code = 6; Name = "jump" },
    @{ Code = 7; Name = "fly" },
    @{ Code = 16; Name = "hammer" },
    @{ Code = 17; Name = "hamtop" },
    # Ordinary BGPUNCH. Not part of the restored-specials sweep - it is here to
    # check that a landed punch draws blood (r_kahn_fist). Pass -AllowP1Damage
    # with it, or the rig heals the victim every frame and the run cannot tell
    # a connect from a whiff.
    @{ Code = 8; Name = "punch" },
    # The green projectile (do_kahn_eyeshot). Its AI entry is far-band only, so
    # pin wide to see it the way Kahn throws it: -PinPlayers -PinSpacing 208.
    @{ Code = 18; Name = "eyeshot" },
    # Throat slam (kahn_throat_slam). Set $env:KAHN_P1_CHAR = "2" to fight Cage,
    # the fighter data/SHAOSLAMCAGE.WAX was authored against.
    @{ Code = 19; Name = "throatslam" }
)

if ($NormalMatch) {
    $moves = @(@{ Code = 0; Name = "normal_match" })
} elseif ($P2Control) {
    $moves = @(@{ Code = 0; Name = "p2_control" })
} elseif (-not $OnlyMove) {
    throw "[kahn-test] pick one move with -Move big_power|slam|sonic|portal|nupower|jump|fly|hammer|hamtop|punch|eyeshot|throatslam, or -Move 1..8,16,17,18,19"
} else {
    $selectedMove = $OnlyMove.ToLowerInvariant()
    $moves = @($moves | Where-Object { $_.Name -eq $selectedMove -or ([string]$_.Code) -eq $selectedMove })
    if ($moves.Count -eq 0) {
        throw "[kahn-test] unknown move '$OnlyMove'; use big_power, slam, sonic, portal, nupower, jump, fly, hammer, hamtop, punch, eyeshot, throatslam, or 1..8/16/17/18/19"
    }
}

if ($Debug -and -not $DebugScript) {
    $DefaultDebugScript = Join-Path $Root "mame_autoresume.ds"
    if (Test-Path -LiteralPath $DefaultDebugScript) {
        $DebugScript = $DefaultDebugScript
    }
}

function Test-KahnMoveLog {
    param(
        [string]$Path,
        [string]$MoveName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match "\[kahn-test\] ERROR") {
        return $false
    }

    if ($MoveName -eq "normal_match") {
        return ($text -match "normal_match finished" -and $text -match "\[kahn-test\] finished")
    }

    if ($MoveName -eq "p2_control") {
        # play session: user closes MAME when done - pass if the mode came up
        return ($text -match "mode=p2_pad")
    }

    if ($MoveName -eq "punch") {
        # "ack" only proves he swung. The blood verdict is the point of the run.
        return ($text -match "punch_blood PASS" -and $text -match "\[kahn-test\] finished")
    }

    if ($MoveName -eq "eyeshot") {
        # "ack" only proves he leaned in. The star has to exist, travel the
        # way he faces, and take stk_sk_eyeshot's damage - that is the verdict.
        # Every queued shot has to pass, so a -Repeat run fails on the first
        # FAIL line rather than passing because an earlier shot was clean.
        return ($text -match "eyeshot PASS" -and $text -notmatch "eyeshot FAIL" -and
                $text -match "\[kahn-test\] finished")
    }

    if ($MoveName -eq "throatslam") {
        return ($text -match "throatslam PASS" -and $text -match "\[kahn-test\] finished")
    }

    if ($MoveName -eq "sonic") {
        return ($text -match "sonic contact ok" -and $text -match "\[kahn-test\] finished")
    }

    if ($MoveName -eq "jump" -or $MoveName -eq "fly") {
        $movePattern = [regex]::Escape($MoveName)
        return (
            $text -match "ack move=$movePattern" -and
            $text -match "complete move=$movePattern" -and
            $text -match "\[kahn-test\] finished"
        )
    }

    $movePattern = [regex]::Escape($MoveName)
    return ($text -match "ack move=$movePattern" -and $text -match "\[kahn-test\] finished")
}

foreach ($moveSpec in $moves) {
    $moveName = $moveSpec.Name
    $moveLog = Join-Path $LogDir "$moveName.log"

    $passed = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptName = "run_${RunId}_attempt_$attempt"
        $moveOutput = Join-Path (Join-Path $OutputDir $moveName) $attemptName
        $moveSnapshots = Join-Path (Join-Path $SnapshotDir $moveName) $attemptName

        Remove-Item -LiteralPath $moveLog -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $moveSnapshots | Out-Null
        New-Item -ItemType Directory -Force -Path $moveOutput | Out-Null

        # Fresh factory CMOS every boot: leftover credits from a run that
        # exited mid-fight desync the scripted coin/start schedule and can
        # stall the boot at character select.
        $MameDir = Split-Path -Parent $Mame
        Remove-Item -Recurse -Force (Join-Path $MameDir "nvram\mk2") -ErrorAction SilentlyContinue

        if ($NormalMatch) {
            Remove-Item Env:\KAHN_TEST_CODE -ErrorAction SilentlyContinue
            $env:KAHN_NORMAL_MATCH = "1"
        } elseif ($P2Control) {
            Remove-Item Env:\KAHN_TEST_CODE -ErrorAction SilentlyContinue
            Remove-Item Env:\KAHN_NORMAL_MATCH -ErrorAction SilentlyContinue
        } else {
            Remove-Item Env:\KAHN_NORMAL_MATCH -ErrorAction SilentlyContinue
            $env:KAHN_TEST_CODE = [string]$moveSpec.Code
            if ($Repeat -gt 1) {
                $env:KAHN_TEST_CODES = (@([string]$moveSpec.Code) * $Repeat) -join ","
            } else {
                Remove-Item Env:\KAHN_TEST_CODES -ErrorAction SilentlyContinue
            }
        }
        if ($BlockVictim) {
            $env:KAHN_BLOCK_VICTIM = "1"
            $env:KAHN_ALLOW_P1_DAMAGE = "1"
        } else {
            Remove-Item Env:\KAHN_BLOCK_VICTIM -ErrorAction SilentlyContinue
        }
        $env:KAHN_TEST_LOG = $moveLog

        $runArgs = @{
            Mame = $Mame
            RomPath = $RomPath
            Machine = "mk2"
            Resolution = $Resolution
            Script = $LuaScript
            SnapshotDirectory = $moveSnapshots
            OutputDirectory = $moveOutput
            Video = "gdi"
            Wait = $true
            # Ask for warning dismissal.  This was NEVER set, and the whole
            # dismissal block in run_mame_small.ps1 is gated on it being > 0,
            # so every run sat on MAME's red ROM warning until somebody hit a
            # key by hand.  mk2 shows that warning on EVERY launch (undumped
            # PLDs in the driver - `mame -verifyroms mk2` still reports the
            # set as good), so this is not optional.
            WarningDismissCount = 1
        }

        if (-not $Sound -and -not $P2Control) {
            $runArgs.NoSound = $true
        }

        if ($Debug) {
            $runArgs.Debug = $true
        }

        if ($DebugScript) {
            $runArgs.DebugScript = $DebugScript
        }

        if ($NormalMatch) {
            Write-Host "[kahn-test] Running normal Liu Kang vs Shao Kahn match (attempt $attempt/$MaxAttempts)..."
        } elseif ($P2Control) {
            Write-Host "[kahn-test] P2 pad controls Shao Kahn (puppet mode). P1 = Liu Kang as usual."
            Write-Host "[kahn-test]   toward/away=walk  Up=jump  HP=punch  toward+HP=charge  down+HP=uppercut"
            Write-Host "[kahn-test]   LP=zap  down+LP=big_power  HK=kick  toward+HK=portal  down+HK=sonic"
            Write-Host "[kahn-test]   LK=fly knee  down+LK=slam  BLK=block  down+BLK=nupower heal"
            Write-Host "[kahn-test] Close MAME when done."
        } else {
            Write-Host "[kahn-test] Running $moveName (code $($moveSpec.Code), attempt $attempt/$MaxAttempts)..."
        }
        $runArgs.ReadyFile = $moveLog
        & (Join-Path $ToolsDir "run_mame_small.ps1") @runArgs

        if (Test-KahnMoveLog -Path $moveLog -MoveName $moveName) {
            $passed = $true
            break
        }

        Write-Warning "[kahn-test] $moveName attempt $attempt did not complete cleanly; retrying if attempts remain."
        Start-Sleep -Seconds 1
    }

    if (-not $passed) {
        throw "[kahn-test] $moveName failed after $MaxAttempts attempt(s); see $moveLog and $OutputDir\$moveName"
    }
}

Remove-Item Env:\KAHN_BLOCK_VICTIM -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_TEST_CODE -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_TEST_CODES -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_TEST_LOG -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_TEST_ROOT -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_NORMAL_MATCH -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_UNLIMITED_HEALTH -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_ALLOW_P1_DAMAGE -ErrorAction SilentlyContinue
Remove-Item Env:\KAHN_PORTAL_FATALITY -ErrorAction SilentlyContinue

Write-Host "[kahn-test] Lua logs: $LogDir"
Write-Host "[kahn-test] Screenshots: $SnapshotDir"
Write-Host "[kahn-test] MAME output: $OutputDir"
