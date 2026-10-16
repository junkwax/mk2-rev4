param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    # shang_revert   - the reported case as a player plays it: Shang -> Sub-Zero,
    #                  freeze, back to Shang, -> Kitana, fan decap
    # shang          - Sub-Zero straight to Kitana (only the CPU Shang can)
    # decap          - Kitana fan-decaps a frozen victim
    # decap_nofreeze - control, same decap on a plain dizzy victim
    # shatter        - regression: the shatter still takes a frozen victim
    [ValidateSet("shang_revert", "shang", "decap", "decap_nofreeze", "shatter")]
    [string]$Mode = "shang_revert",
    # Victim ochar. 11=Jax 0=KungLao 1=LiuKang 2=Cage 3=Baraka 4=Kitana
    # 5=Mileena 6=Shang 7=Raiden 8=SubZero 9=Reptile 10=Scorpion
    [int]$Victim = 11,
    [int]$Stage = 5,
    [int]$TimeoutSeconds = 240,
    # C:\MAME\ui.ini has skip_warnings=1 but MAME still parks on the
    # bad-checksum screen here, and then the script never runs.
    [int]$WarningDismissCount = 4
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir

# do_fan_decap, do_st_2_sz and do_st_2_fn1 are local labels - not in mk2.map.
# Find them in the built ROM:
#   do_fan_decap - movk 1,a0 / movk 2,a1 / callr init_death_blow / movk 3,a9 /
#                  calla get_char_ani2, with a movi decap_fall close behind
#   do_st_2_*    - MOVES.ASM's run of "movk n,a9 / jruc shang_morph" pairs
$Found = @'
import re, struct, sys
root = sys.argv[1]
mapt = open(root + "/src/mk2.map").read()
syms = {}
for a, n in re.findall(r"([0-9a-f]{8})\s+([\w.]+)", mapt):
    syms[n] = int(a, 16)
rom = open(root + "/rom/mk2_flat.bin", "rb").read()
words = struct.unpack_from("<%dH" % (len(rom) // 2), rom, 0)
def w(b): return words[(b - 0xFF800000) // 16]
def l(b): return w(b) | (w(b + 16) << 16)

lo = int(re.findall(r"([0-9a-f]{8})\s+[0-9a-f]{8}\s+MKDEATH\.OBJ \(\.text\)", mapt)[0], 16)
idb, gca2, df = syms["init_death_blow"], syms["get_char_ani2"], syms["decap_fall"]
fan = None
for b in range(lo, lo + 0x22f10, 16):
    if w(b) == 0x1820 and w(b + 16) == 0x1841 and w(b + 32) == 0x0D3F:
        d = w(b + 48); d = d - 0x10000 if d & 0x8000 else d
        if b + 64 + d * 16 == idb and w(b + 64) == 0x1869 and w(b + 80) == 0x0D5F and l(b + 96) == gca2:
            if any(l(b + 16 * k) == df for k in range(8, 40)):
                fan = b; break

run = [0x1829, 0x1849, 0x1869, 0x1889, 0x18A9]      # movk 1..5,a9
lk = None
for i in range(len(words) - 10):
    if all(words[i + 2 * k] == v and (words[i + 2 * k + 1] & 0xFF00) == 0xC000 for k, v in enumerate(run)):
        lk = 0xFF800000 + i * 16; break
if fan is None or lk is None:
    sys.exit("not found fan=%s lk=%s" % (fan, lk))
fn1, sz = lk + 3 * 32, lk + 6 * 32
assert w(fn1) == 0x1889 and w(sz) == 0x1909, "morph table layout changed"
print("%08x %08x %08x" % (fan, sz, fn1))
'@ | python - $Root
if (-not $Found) { throw "could not locate do_fan_decap / do_st_2_* in rom/mk2_flat.bin" }
$FanDecap, $St2Sz, $St2Fn1 = $Found.Trim() -split '\s+'

$LogDir = Join-Path $ToolsDir "sz_freeze_thaw_logs"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunSnapshots = Join-Path $ToolsDir "screens\sz_freeze_thaw\run_${Mode}_$RunId"
$RunOutput = Join-Path $ToolsDir "sz_freeze_thaw_out\run_$RunId"
$LogPath = Join-Path $LogDir "sz_freeze_thaw_${Mode}_v$Victim.log"

New-Item -ItemType Directory -Force -Path $LogDir, $RunSnapshots, $RunOutput | Out-Null
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

$vars = @{
    MK2_ROOT = $Root; SZFT_LOG = $LogPath; SZFT_MODE = $Mode
    SZFT_VICTIM = [string]$Victim; SZFT_STAGE = [string]$Stage
    SZFT_FAN_DECAP = $FanDecap; SZFT_ST_2_SZ = $St2Sz; SZFT_ST_2_FN1 = $St2Fn1
}
$saved = @{}
foreach ($k in $vars.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $vars[$k])
}

try {
    Write-Host "[szft] mode=$Mode victim=$Victim do_fan_decap=0x$FanDecap do_st_2_sz=0x$St2Sz do_st_2_fn1=0x$St2Fn1"
    & (Join-Path $ToolsDir "run_mame_small.ps1") -Mame $Mame -RomPath $RomPath -Machine mk2 `
        -Resolution 800x600 -Script (Join-Path $ToolsDir "sz_freeze_thaw_test.lua") `
        -SnapshotDirectory $RunSnapshots -OutputDirectory $RunOutput -Video gdi `
        -AutoCloseSeconds $TimeoutSeconds -WarningDismissCount $WarningDismissCount -NoSound -Wait
}
finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}

Write-Host "[szft] Screenshots: $RunSnapshots"
if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Tail 25 }
