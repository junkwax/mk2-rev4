#!/usr/bin/env python3
"""
Convert LOAD2 .IRW files into MAME-compatible 4-way interleaved video ROMs.

MK2 T-Unit video hardware:
- 4-byte-wide bus (4-way interleave)
- Bank 0 and Bank 1 (dual-banked, /E flag in LOAD2)
- 12 ROM chips total, each 1 MB
- MAME region "video" = 0xC00000 (12 MB)

Address mapping (TMS34010 bit addresses -> byte offsets):
  Bank 0: 0x2000000 -> offset 0x000000, 0x3000000 -> 0x200000, etc.
  Bank 1: 0x2000000 -> offset 0x800000, 0x3000000 -> 0xA00000, etc.

Usage:
    python makevrom.py              # build 12 interleaved ROM chips for MAME
    python makevrom.py --debug-bin  # also produce raw header-stripped .bin
                                    #   files for MAME debugger `loadr`
    python makevrom.py --data-dir path/to/staged/data
"""
import argparse
import re
import struct
import sys
from pathlib import Path

# TMS34010 image ROM base (bit address)
IROM_BASE = 0x02000000
IROM_BANK1_HIGH_BASE = 0x04000000

# MAME video ROM layout: 12 MB total, 4-way interleave
VIDEO_SIZE = 0xC00000  # 12 MB flat

# WOLF-ONLY video ROM (doc/WOLF_UNIT.md, doc/WOLF_CONTENT_PLAN.md).  The Wolf
# board's video region runs to 32 MB; MK2's own 12 MB lands in u133..u122 and
# MAME's umk3 driver also loads u121..u118 (12-16 MB) and u113..u110 (20-24 MB).
# A Wolf-only pack is a BANK-1 LOD whose ***> line is 4000000,1 or above.  That
# is LOD form - an IRW header records the LOD line, and for bank 1 it runs
# 02000000h BELOW the runtime SAG - so its linear offset is
# 0x800000 + (base - 0x2000000) / 8: 4000000,1 is linear 12 MB, runtime SAG
# 06000000h (tools/make_mk1pit.py lod_address writes exactly this).
# image_byte_offset's ">= 0x4000000 in bank 1" branch reads such a base as a
# RUNTIME SAG and would put it at 8 MB, on bank-1 art, so the Wolf loop below
# does not use it.  A Wolf pack is kept OUT of the 12 T-unit chips and written
# to rom/wolf_video_hi.bin, which makewolf.py interleaves into those chips.
# The sprite DMA reaching it is proven (tools/run_wolf_vrom_reach_test.ps1).
WOLF_HI_BASE = VIDEO_SIZE                      # linear offset 12 MB
WOLF_HI_SIZE = 0x2000000 - WOLF_HI_BASE        # up to 32 MB
WOLF_MAME_BLOCKS = [(0xC00000, 0x1000000, "u121..u118"),
                    (0x1400000, 0x1800000, "u113..u110")]
# The sockets UMK3 leaves empty.  Stock MAME's umk3 does not load them; the
# patched tools/mame_wolf mk2wolf.exe does (and so does a real board), which is
# the footing the Wolf sound set already stands on (u6-u9).  A pack may go here
# only if nothing has to be seen in stock MAME - makewolf.py writes the chips
# as mk2wolf_video_rom_uNNN.  doc/WOLF_OPPORTUNITIES.md W02.
WOLF_EXTRA_BLOCKS = [(0x1000000, 0x1400000, "u117..u114 (mk2wolf.exe only)"),
                     (0x1800000, 0x2000000, "u109..u102 (mk2wolf.exe only)")]
# Taken on every Wolf build: the VS portraits (MK8MIL.IRW), which the T-unit
# keeps in the program-ROM REVX pool, are read from image ROM on Wolf
# (src/UNZIP.ASM wolf_vs_cpu = 05E00000h, bank 1 = linear 0FC0000h) and placed
# there by makewolf.py.  No Wolf pack may overlap it.
# The character endings (data/ENDWOLF.LOD) are read the same way, out of image
# BANK 2 (UNZIP.ASM wolf_end_cpu = 04400000h = linear 1480000h), and also placed
# by makewolf.py: 24 frames, 362,197 bytes, in a 512 KB slot.
WOLF_RESERVED = [(0xFC0000, 0x1000000, "the Wolf VS portraits (UNZIP.ASM wolf_vs_cpu)"),
                 (0x1480000, 0x1500000, "the Wolf character endings (UNZIP.ASM wolf_end_cpu)")]
# LOAD2 refuses a load address of 8000000 and up ("Illegal load address"), and
# that is exactly where the u110-u113 block starts (linear 0x1400000).  A pack
# meant for it is loaded 4 MB LOWER - inside the u114-u117 hole, which MAME never
# loads - and moved up by this much here.  Its tool adds the same distance (as
# bits, 2000000h) to every SAG it emits, so nothing reads LOAD2's own tables.
WOLF_RELOCATE = {
    # JADE'S DESERT (UMK3) - tools/make_umk3desert.py RELOC
    "DSRT1.IRW": 0x400000, "DSRTM.IRW": 0x400000, "DSRTFL.IRW": 0x400000,
    # THE SOUL CHAMBER and THE PIT 3 (UMK3) - tools/make_umk3stages.py RELOC
    "USC1.IRW": 0x400000, "USC2.IRW": 0x400000, "USCM.IRW": 0x400000, "USCFL.IRW": 0x400000,
    "UP31.IRW": 0x400000, "UP32.IRW": 0x400000,
    # NOOB'S DORFEN (UMK3) - tools/make_umk3stages.py RELOC
    "UNW1.IRW": 0x400000, "UNW2.IRW": 0x400000, "UNWFL.IRW": 0x400000,
    # THE PIT III's throne Kahn - tools/make_pit3kahn.py RELOC
    "UP3KN.IRW": 0x400000,
    # MK3 NIGHTWOLF - tools/make_nightwolf.py RELOC
    "NWOLFA.IRW": 0x400000, "NWOLFB.IRW": 0x400000, "NWOLFC.IRW": 0x400000, "NWSEL.IRW": 0x400000,
    # MK3 ROBOT SMOKE - tools/make_robosmoke.py RELOC
    "RSMOKA.IRW": 0x400000, "RSMOKB.IRW": 0x400000, "RSSEL.IRW": 0x400000,
}

# Bank mapping: bank 0 starts at linear offset 0, bank 1 at 0x800000
BANK_OFFSETS = {0: 0x000000, 1: 0x800000}

# Per-file bank assignment. Without LOAD2's /E flag, the IRW header's bank field
# is 0xFFFF (undefined). MK2-MK5 are bank 0 (first 8 MB), MK6-MK7 are bank 1
# (second 4 MB). This matches Asure's pipeline per Discord 2026-04-16.
FILE_BANK = {
    "MK2MIL.IRW": 0, "MK3MIL.IRW": 0, "MK4MIL.IRW": 0, "MK5MIL.IRW": 0,
    "MK6MIL.IRW": 1, "MK7MIL.IRW": 1,
    "MOVEART2.IRW": 0, "MOVEART1.IRW": 0, "SCLAP.IRW": 1, "SHAOSIT.IRW": 0, "KITSPIN.IRW": 0, "GOROWALK.IRW": 0, "FLAPJACK.IRW": 0,
    "JADERANG.IRW": 0, "JADVIC.IRW": 0,
   
    "MK1SKULL.IRW": 0,
    # Was MISSING until 2026-09-03, and its absence was not harmless: this
    # dict is what tools/rom_space_report.py walks, so TIMEFLR's 14,318 bytes
    # were invisible to it and the report advertised the JADERANG-to-SAHELI
    # run as one free 15,258-byte hole - the largest in bank 0 - when the
    # staircase is sitting in it.  makevrom's own overlap guard would have
    # caught a build placed there, but only after the LOD was written.
    # Placement is unaffected either way: bank 0 is this lookup's default and
    # the /E headers carry the real bank.
    # Bank 1 since 2026-09-09.  The staircase is a BACKGROUND multipart -
    # DMA-drawn off a private display list, never walked by shadow_p1p2's CPU
    # read - so it has no business holding 14KB of bank 0 open.  Moving it out
    # is what paid for BOSSHAM's nine-frame over-the-top hammer; see the note
    # on its slot below.
    "TIMEFLR.IRW": 1,
    # Shao Kahn's hammer glow, both swings.  Overlay objects with no shadow,
    # so bank 1 is safe for the same reason ERMFIRE and ROBOFIRE are.
    "HAMGLOW.IRW": 1,
    # THE TOWER guard reflections.  Bank 1 for the same reason HAMGLOW is:
    # DMA-drawn overlay art with m_shadow clear, so shadow_p1p2's bank-less
    # CPU read never walks it.  See data/STATREF.LOD.
    "STATREF.IRW": 1,
    # Shao Kahn's green-projectile muzzle flash (KAHNGLOWA).  Overlay with no
    # shadow, so bank 1 for the same reason HAMGLOW and ERMFIRE are.  See
    # data/SKGLOW.LOD.
    "SKGLOW.IRW": 1,
    # Rain's lightning bolt - projectile frames, no shadow, so bank 1 for the
    # same reason ERMFIRE is.
    "RAINBOLT.IRW": 1,
    # Jade's staff impale rod - a bare object, no shadow, so bank 1 for the
    # same reason RAINBOLT is.  See data/JDROD.LOD.
    "JDROD.IRW": 1,
    # Rain's storm cloud - a projectile and bare drop objects, no shadow, so
    # bank 1 for the same reason RAINBOLT is.  See data/RAINCLD.LOD.
    "RAINCLD.IRW": 1,
    # RAINBUB.IRW was here - the WATER BUBBLE the man Rain's cloud catches
    # hung in.  RETIRED 2026-09-29 to reclaim its bank-1 bytes: `rainbub' had
    # been 0 since it was authored, so nothing drew it.  See the rainbub note
    # in src/MAINEQU.ASM for what restoring it costs now.
    # Smoke's harpoon rope - a bare projectile object, no shadow, so bank 1 for
    # the same reason RAINBOLT is.  See data/SMROPE.LOD.
    "SMROPE.IRW": 1,
    # The kiss of death's blood splash - a bare blood object, no shadow, so
    # bank 1 for the same reason RAINBOLT is.  See data/BLDSPLSH.LOD.
    "BLDSPLSH.IRW": 1,
    # Kung Lao's hat at angle - a bare projectile object, no shadow, so bank 1
    # for the same reason RAINBOLT is.  See data/SLICEHAT.LOD.
    "SLICEHAT.IRW": 1,
    # Noob Saibot's ghost ball - a projectile object of its own, no shadow, so
    # bank 1 for the same reason RAINBOLT is.  See data/NOOBPRJ.LOD.
    "NOOBPRJ.IRW": 1,
    # ...and the ghost ring it spawns on the victim - an FX object, no
    # shadow either.  See data/NOOBRING.LOD.
    "NOOBRING.IRW": 1,
    # The female ninjas' soul-suck wither upper halves (SOULSUCKKT1B/2B) -
    # bank 1 like their A halves in MK6MIL.  See data/KTSOULB.LOD.
    "KTSOULB.IRW": 1,
    # The Discord page's picture (discord_info, MKAMODE.ASM) - two halves of
    # MK3's OBKNEEBREAK2, bare objects with no shadow.  See tools/make_discord_ob.py.
    "DISCOB1.IRW": 1,
    "DISCOB2.IRW": 1,
    "MKSOUL1.IRW": 1,
    "SZSPINE.IRW": 0,
    "JXAIRPRO.IRW": 0,
    # SHAOFIST.IRW was here - Kahn's portal-punch pulp burst (FISTPULP1-15).
    # RETIRED 2026-09-29 to reclaim its bank-1 bytes; `kfistpulp' has been 0
    # since 2026-09-28 (the body pops instead).  See src/MAINEQU.ASM.
    "UMK3FIRE.IRW": 0,
    "BOSSHAM.IRW": 0,
    "RNVIC7.IRW": 0,
   
    "MTOPFLR.IRW": 0,
    "ERMACSLM.IRW": 0,
    "RAIN.IRW": 1,          # bank 1 since 2026-09-17 - background, never shadowed
    "SAHELI.IRW": 0,
    "ERMFIRE.IRW": 1,
    "ROBOFIRE.IRW": 1,
    "HICLOUD.IRW": 1,
    "MTNSKUL.IRW": 0,
    "CAVEYES.IRW": 1,
    "BLDXPD.IRW": 1,
    "SMTIGER.IRW": 1,
    # THE CAVE - image packs + floor, all bank 1 (see the slot notes below)
    "MK3CV1.IRW": 1, "MK3CV2.IRW": 1, "MK3CV3.IRW": 1, "MK3CV4.IRW": 1,
    "CAVEFLR.IRW": 1,
    # THE PIT (MK1) - bridge packs and sky packs (see the slot notes below)
    "MK1PT1.IRW": 1, "MK1PT2.IRW": 1, "MK1PT3.IRW": 1, "MK1PT4.IRW": 1,
    "MK1PSK1.IRW": 1, "MK1PSK2.IRW": 0, "MK1PSK3.IRW": 1, "MK1PSK4.IRW": 1,
    "MK1PSK5.IRW": 1, "MK1PFLY.IRW": 1,
    # THE WARRIOR SHRINE (MK1) - image packs, bank 0 (see the slot notes below)
    "MK1WS1.IRW": 0, "MK1WS2.IRW": 0, "MK1WS3.IRW": 0,
    "TWRJNT.IRW": 1,
    "ARNSKY.IRW": 1,
    # Cage's air shadow kick strips.  BANK 0 is REQUIRED, not preferred: this
    # is a fighter's own body art, so shadow_p1p2's CPU read walks it every
    # frame he is on screen and that read has no video-ROM bank select.
    "JCAIRKIK.IRW": 0,
    # Cage's unused MK1 flip kick.  BANK 0 for the same reason as JCAIRKIK:
    # it is his own body art and shadow_p1p2's CPU read has no bank select.
    "JCFKICK.IRW": 0,
    # Cage's OTOMIX logo pieces.  BANK 0: fighter body art, walked by
    # shadow_p1p2's bank-less CPU read.  See data/JCLOGO.LOD.
    "JCLOGO.IRW": 0,
    # Shao Kahn's throat slam (SHASLAM1-13 A/B strips).  BANK 0 is REQUIRED:
    # his body art, walked by shadow_p1p2's bank-less CPU read.
    "SHASLAM.IRW": 0,
    # Shao Kahn's soul rip (SHASOULRIP1-9 A/B/C strips, five packs).  BANK 0
    # is REQUIRED for the same reason SHASLAM is: his body art, walked by
    # shadow_p1p2's bank-less CPU read.
    "SKSOUL1.IRW": 0, "SKSOUL2.IRW": 0, "SKSOUL3.IRW": 0, "SKSOUL4.IRW": 0,
    "SKSOUL5.IRW": 0,
    # Select screen's Scorpion -> Ermac box wipe.  BANK 1: a grid box casts no
    # shadow, and bank 0 has no room left.  (REPERM, the Reptile -> Ermac wipe,
    # was retired 2026-09-23 - Reptile has no morph now; ERSCO, the previous
    # cut of THIS wipe, was retired 2026-09-24.)
    "ERBOX.IRW": 1,
    # Kintaro's stomp (TIGERJUMP strips restored to Midway's size, six packs).
    # BANK 0 IS REQUIRED: body art, walked by shadow_p1p2's bank-less CPU read
    # during the in-fight stomp.  See data/TIGJMP1.LOD.
    "TIGJMP1.IRW": 0, "TIGJMP2.IRW": 0, "TIGJMP3.IRW": 0, "TIGJMP4.IRW": 0, "TIGJMP5.IRW": 0, "TIGJMP6.IRW": 0,
    # The Kitana -> Jade wipe.  BANK 0 only because that is where the slot
    # is (REPERM's old one); a grid box casts no shadow, so bank 1 would do
    # too.  See data/JDBOX.LOD.  (JADMIL1-3, the Mileena -> Jade wipe dealt
    # over three holes, was retired 2026-09-25 and handed 30,544 bytes back.)
    "JDBOX.IRW": 0,
    # Sub-Zero <-> Rain select-box wipe.  BANK 1: a grid box casts no shadow,
    # and bank 0 has no room left.  See data/RNBOX.LOD.  (RAINICE, ICERAIN and
    # RAINICEE, earlier cuts of this wipe, were retired 2026-09-22/23/24.)
    "RNBOX.IRW": 1,
    # Liu Kang's DOUBLE KNEE - LKDUBLKNEE strips restored to bank 0 (body art,
    # shadow_p1p2's bank-less CPU read walks it).  Pack 1 lives in a new section
    # at the end of data/MOVEART2.LOD, so only packs 2 and 3 are their own IRWs.
    "LKDKNEE2.IRW": 0, "LKDKNEE3.IRW": 0,
    # Shang Tsung's FIRST elbow - STELBO1B, the back half of STELBO1, which
    # retail's MK3MIL.LOD never packed (it names STELBO1A twice).  BANK 0:
    # body art, walked by shadow_p1p2's bank-less CPU read.
    "STELBO1.IRW": 0,
    "PILREFD.IRW": 0,       # THE TOWER pillar reflection - see data/PILREFD.LOD
    "LUBUZZ.IRW": 0,
    "XRAY1.IRW": 1, "XRAY2.IRW": 1, "XRAY3.IRW": 1, "XRAY4.IRW": 1,
    "XRAY5.IRW": 0, "XRAY6.IRW": 1, "XRAY7.IRW": 1, "XRAY8.IRW": 1, "XRAY9.IRW": 1,
    # Dead Pool hanger Tony: body bank 1 (like Ed's EDHANG1 in MK7MIL), skeleton
    # bank 0 (like his DEDHANG1 in MOVEART1).  The IRW headers carry the bank, so
    # makevrom places them right without this - but rom_space_report reads THIS
    # map, and without it counted both slots as free.
    "HANGTONY.IRW": 0, "HANGTNYD.IRW": 0,
    "HANGJOHN.IRW": 0, "HANGJOHD.IRW": 0,
    "HANGGEO.IRW": 0, "HANGGEOD.IRW": 0,
    "HANGMARK.IRW": 0, "HANGJEFF.IRW": 0, "HANGSTEV.IRW": 0, "HANGSAL.IRW": 0, "HANGERIC.IRW": 0,
    # THE THRONE ROOM (MK1) - background blocks dealt over four free runs, two
    # in each bank.  EITHER BANK IS SAFE: a background block is DMA-drawn and
    # never walked by shadow_p1p2's bank-less CPU read, and none of it is a
    # movie frame.  See data/MK1TR1.LOD and tools/make_mk1throne.py PACKS.
    "MK1TR1.IRW": 0, "MK1TR2.IRW": 1, "MK1TR3.IRW": 1, "MK1TR4.IRW": 0,
    "MK1TRSH.IRW": 1, "MK1TRS2.IRW": 1,
    # THE THRONE ROOM's empty throne (tools/make_thrnchair.py): background
    # strips in the free tails of MK1TRS2, MK1TR1 and MK1TR2.
    "THRCHP1.IRW": 1, "THRCHP2.IRW": 0, "THRCHP3.IRW": 1,
}

# LOAD2 can emit an empty bootstrap header before the real payload for MK7MIL.
# The payload is still based at the LOD's declared address.
FILE_BASE_OVERRIDE = {
    "MK7MIL.IRW": 0x03000000,
}

# No active payloads intentionally overlap. Retired MK7 ranges remain available
# for future fixed-slot allocations, but must be declared when assigned.
ALLOWED_OVERLAP_WINDOWS = {}

# Fixed slots for source-built custom video payloads.  These are deliberately
# stricter than simple overlap checks: once a wrapper works, future art should
# use a new wrapper or its assigned growth room instead of shifting its base.
CUSTOM_VIDEO_SLOTS = {
    # name: (start inclusive, end exclusive, purpose)
    # ---------------------------------------------------------------------
    # Bank-0 PACKED SIDECAR REGION: 0x760000..0x7BC000
    #
    # Packed 2026-08-10 by tools/pack_bank0_sidecars.py.  Every sidecar here
    # used to get its own 4KB-aligned slot with a comfortable tail, granted
    # one at a time over months.  Individually tidy; collectively it scattered
    # bank 0's free space into a dozen fragments - 102,104 bytes free whose
    # largest single run was 26,346, so a 40KB asset fit nowhere even though
    # there was room for four of them.
    #
    # They now sit tight on 512-byte boundaries in address order, and all that
    # slack is ONE 74,752-byte run at 0x7A9C00..0x7BC000.  Packing creates no
    # space - it moves the same free bytes somewhere spendable.
    #
    # Each slot end is the next 512-byte boundary above the real payload end,
    # so guards run 14..434 bytes.  These payloads are frozen in place;
    # anything that needs to grow re-runs the packer instead of eating a
    # neighbour.  0x760000 is the first 4KB boundary above MK5MIL's payload
    # end (0x75FB5C) - the pairwise overlap check is what protects MK5MIL if
    # it ever grows.  The region stops short of FLAPJACK's fixed base.
    #
    # To re-pack after any sidecar changes size:
    #     python tools/pack_bank0_sidecars.py            # report
    #     python tools/pack_bank0_sidecars.py --apply    # rewrite LOD ***>
    # then paste the printed entries below, rebuild, and promote_tbls.
    #
    # VSJDMOV and VSNBMOV are MOVIE frames, so their bases are not only SAGs -
    # they are also the `VS_JD` / `VS_NB` .set equates in src/VSJDZIP.TBL and
    # src/VSNBZIP.TBL that UNZIP.ASM's zipped_pics points at.  Those tables
    # were NOT promoted before 2026-08-10: promote_tbls.py matches records by
    # a label with a trailing colon, so a `.set`-only table always reported
    # "ok" however stale it had gone.  Both are in SET_EQUATE_TABLES now.  A
    # stale movie address does not draw a wrong picture, it hangs gstate 0dh.
    # ---------------------------------------------------------------------
    # THE TOWER floor joints, data/TWRJNT.LOD.  1200x54 raw 6bpp = 48,600
    # bytes, off the BOTTOM of the free run above MK7MIL (229,982 bytes, the
    # largest in bank 1), 4KB aligned with the slot end on the next 512-byte
    # boundary above the payload.  Bank 1 is correct: DMA-drawn floor, never
    # walked by shadow_p1p2.
    "TWRJNT.IRW":  (0xB95310, 0xBA10F0, "THE TOWER floor joints over the reflection"),
    # KAHN'S ARENA's sky, data/ARNSKY.LOD.  440x127 raw 6bpp = 41,910 bytes for
    # sky_rows' per-scanline heat haze.  Top of the free run above TWRJNT,
    # hard under SMTIGER, so nothing already placed moves.  Bank 1: a
    # DMA-drawn background, never walked by shadow_p1p2.
    "ARNSKY.IRW":  (0xBB53A0, 0xBBF760, "Kahn's Arena sky texture for per-line haze"),
    # Johnny Cage's air shadow kick - the A/B strips of JCSHADOWKICK1/2/3 out
    # of CAGE5.IMG, the three new poses for the airborne half of B,F + LK.
    # 16,384 bytes against an ~8,476-byte payload, taken off the TOP of the
    # free run above MK5MIL's payload (0x7292F6..0x738000) so MK5MIL keeps its
    # base and 43,786 bytes of growth room.  Bank 0 because the floor shadow's
    # CPU read walks a fighter's own frames.  See data/JCAIRKIK.LOD.
    # End pulled back 0x738000 -> 0x736600 on 2026-09-16: THE PIT (MK1) MK1PSK2 sits in the
    # top of this guard.  Payload frozen, base unchanged.
    "JCAIRKIK.IRW": (0x730950, 0x732D50, "Cage air shadow kick pose strips"),
    # Cage's unused MK1 FLIP KICK (VDFKICK1-4), rebuilt from data/VANDAN.TBL.
    # 16,384 bytes against an ~12,300-byte payload, taken directly under
    # JCAIRKIK off the same free run above MK5MIL (0x7292F6..0x734000), which
    # leaves MK5MIL its base and 27,914 bytes of growth room.  Bank 0 because
    # the floor shadow's CPU read walks a fighter's own frames.
    # See data/JCFKICK.LOD.
    # End pulled back 0x734000 -> 0x733A00 on 2026-09-16: THE PIT (MK1) MK1PFLY sits in the
    # top of this guard.  Payload frozen, base unchanged.
    # 2026-09-17: packed down onto JCLOGO's shrunk slot end (see BOSSHAM/SHASLAM).
    "JCFKICK.IRW":  (0x72E140, 0x730950, "Cage MK1 flip kick pose strips"),
    # Johnny Cage's OTOMIX logo, one piece per frame that shows it, cut off the
    # pieces by tools/make_cage_logo.py.  32,768 bytes directly under JCFKICK off
    # the free run above MK5MIL's payload.  The display walker (clip41,
    # MKDISP.ASM) recognises a logo piece by its SAG being in THIS slot -
    # CL_SAG_LO/HI there must move with it.  Bank 0 because the floor shadow's
    # CPU read walks a fighter's own frames.  See data/JCLOGO.LOD.
    # 2026-09-17: slot end 0x730000 -> 0x72E140 (payload ends 0x72E034, 268
    # bytes of guard) so JCFKICK and the chain above could pack down into its
    # tail.  CL_SAG_HI in MKDISP.ASM moved with it - anything whose SAG lands
    # inside this slot is dropped when flipped.
    "JCLOGO.IRW":   (0x728000, 0x72E140, "Cage OTOMIX logo pieces"),
    "SZSPINE.IRW":  (0x734670, 0x735870, "Sub-Zero head-rip spine + head props"),
    "MOVEART2.IRW": (0x735870, 0x738740, "second custom move-art pool"),
    "MOVEART1.IRW": (0x738740, 0x74D970, "frozen custom move-art pool"),
    # End pulled back 0x75AC00 -> 0x756800 on 2026-09-16: THE PIT (MK1) MK1PT1 sits in the
    # top of this guard.  Payload frozen, base unchanged.
    "SHAOSIT.IRW":  (0x74D970, 0x751890, "Shao Kahn throne stand-up pool (retired KGBLOOD slot)"),
    # RETIRED 2026-09-25: 0x751890..0x755740 (16,048 bytes) is FREE.  Jade's
    # portrait grew to 16,056 bytes and this chain is packed at 2-10 byte
    # guards, so she moved into the PROGRAM ROM pool (MK8MIL.LOD) beside the
    # twelve stock portraits and Ermac.  Bank 0 is the scarce space; program
    # ROM had ~102 KB of .data headroom.  data/VSJDMOV.LOD is gone.
    # "VSJDMOV.IRW":  (0x751890, 0x755740, "Jade VS portrait, zipped movie frame"),
    "JXAIRPRO.IRW": (0x755740, 0x759060, "Jax air lightwave throw frames"),
    # OFF (noob_extras / vs_noob_smoke_pics = 0, MAINEQU): "NOOBFX.IRW":   (0x759060, 0x75C150, "Noob shadow move frames (retired VSNOOB slot)"),
    # OFF (noob_extras / vs_noob_smoke_pics = 0, MAINEQU): "VSNBMOV.IRW":  (0x75C150, 0x75F400, "Noob VS portrait, zipped movie frame"),
    "KITSPIN.IRW":  (0x75F400, 0x764140, "Kitana overhead spin chop pool"),
    "MK1SKULL.IRW": (0x764140, 0x76F1D0, "MK1 scortch fatality frames"),
    "GOROWALK.IRW": (0x76F1D0, 0x778020, "Kahn Arena Goro walk pool"),
    # The run the pack produced - the largest free block in the ROM - reserved
    # for Scorpion's UMK3 flame fatality (D,U,U,U + HK).  STAGED, NOT SHIPPED:
    # UMK3FIRE.IRW is deliberately absent from irw_files below, because the
    # art as authored packs to 140,160 bytes and still does not fit.  The
    # frames are being re-cut as multipart subframes; when the payload fits,
    # add UMK3FIRE.IRW to irw_files and set umk3_burn_enable to 1 in
    # src/MAINEQU.ASM.  Declaring the slot now means the overlap and bounds
    # guards cover it from the moment it is switched on.
    #
    # End pulled back from 0x7BC000 to 0x7AC000 to hand the run's top 65,536
    # bytes to BOSSHAM.  UMK3FIRE keeps its 0x05C0E000 base and 172,032 bytes,
    # still comfortably above the 140,160 the art currently packs to - taking
    # the space off the TOP is what let that base stay put.
    # End pulled back again from 0x7AC000 to 0x7AA000 to hand the run's top
    # 8,192 bytes to RNVIC7.  UMK3FIRE keeps its 0x05C0E000 base and 165,888
    # bytes, still well above the 140,160 the art currently packs to - taking
    # the space off the TOP is what lets that base stay put.
    # End pulled back a THIRD time, 0x7AA000 -> 0x79C000, to hand 57,344 bytes
    # to NOOBPORT.  Same rule as the two above: taken off the TOP so the
    # 0x05C0E000 base is untouched.  This one DOES cut into what the staged
    # flame fatality needs - 107,520 bytes left against the 140,160 the art
    # currently packs to - and that is a deliberate trade, not an oversight:
    # NOOBPORT fits in no other free run in either bank (next largest are the
    # bank-1 MKSOUL1 tail at 20,412 and the JADVIC tail at 12,014), and
    # UMK3FIRE is not shipped.  Re-cutting its frames as multipart strips is
    # what was always going to make it fit - see the SHAOFIST note in
    # doc/ASSET_SPACE_LEDGER.md, where the same re-cut took 56,240 bytes to
    # 26,664.
    # End pulled back a FIFTH time, 0x798000 -> 0x78A000, to widen the floor
    # slot from 16,384 to 73,728 when MOUNTAIN TOP's single ledge tile was
    # replaced by the parallax + soulteeth pair.  Same rule as the four above:
    # taken off the TOP so the 0x05C0E000 base is untouched.
    #
    # 2026-08-19: 25,600 bytes GIVEN BACK (0x78A000 -> 0x791000) when the floor
    # was rebuilt to reuse its art mirrored - parallax4-6 dropped for a flipped
    # 3,2,1, and the soulteeth composites dropped for their A..E subframes.
    # UMK3FIRE is back to 62,464 against the 140,160 its art packs to.  Still
    # short, and still fixed only by the multipart re-cut that has always been
    # the plan (the same re-cut took SHAOFIST from 56,240 to 26,664) - but no
    # longer short by a factor of four.
    "UMK3FIRE.IRW": (0x781C00, 0x791000, "UMK3 flame fatality frames (the packed region's free run)"),
    # MOUNTAIN TOP's floor, both halves.  parallax1-6 (MKFLOORS.IMG) are six
    # 200x42 slices of one 1200-wide stone plane, positionally encoded in their
    # own anipoints; soulteeth1-5 (CASTLE.IMG) are the bone teeth in front of
    # it, laid by width in a ping-pong past 1200px.  One LOD because both
    # palettes are already 6bpp.  PON> rather than POF>, so object_setup's
    # icmap read lands on a real binding.  See data/MTOPFLR.LOD.
    # End pulled back 0x79C000 -> 0x79B800 to seat RAIN above it, then
    # 0x79B800 -> 0x79A000 on 2026-09-03 to start the chain that made room for
    # BGEYESHOT.  MTOPFLR's real payload ends at 0x799D50, so it keeps its
    # 0x05C88000 base and 688 bytes of guard.  The art is finished (three
    # courses out of two reused sets), which is why that guard was the first
    # thing spent - it was slack, not growth room.  The BASE has never moved.
    # Base moved 0x791000 -> 0x78D000 on 2026-09-09, following SAHELI down
    # into TIMEFLR's vacated bank-0 slot.  The base had never moved before;
    # it moves now only because the chain shifts together, and the 688-byte
    # guard is unchanged.
    "MTOPFLR.IRW": (0x782D40, 0x78BA90, "Mountain Top bridge floor - parallax + soulteeth strips"),
    # YOTEIGAI TOR's rain: DROP1-4 and DROPHIT1-2 out of data/RAIN.IMG, the
    # six MK3 MKRAIN.TBL records rebuilt from pixels read back out of a UMK3
    # ROM set (tools/make_rain_img.py).  276 bytes against a 2,048-byte slot,
    # and the payload is frozen - the frames are MK3's, transcribed, not art
    # that is going to grow.  Carved off the TOP of MTOPFLR's slot, the same
    # rule BOSSHAM/RNVIC7/NOOBPORT/MTOPFLR/TIMEFLR used on the UMK3FIRE run,
    # so the floor below it does not move.  See data/RAIN.LOD.
    # Moved 0x79B800 -> 0x79A000 on 2026-09-03, down against MTOPFLR's payload
    # end, as the second link in the chain that opened 17KB for BGEYESHOT.
    # 276 bytes against a 512-byte slot now (was 2,048) - fine, because the
    # payload really is frozen: these six records are MK3's, transcribed.
    # Moved 0x79A000 -> 0x795E00 on 2026-09-09, riding MTOPFLR down.
    "RAIN.IRW": (0xBFF490, 0xBFF5B0, "Yoteigai Tor rain drops + splashes"),
    # Noob Saibot's shadow portal, all three sets, all from data/NOOBPORT.IMG:
    # NOOBPORTAL1-12 (the vortex that opens under the opponent on Down,Down +
    # LK), NSPORTALSHOT1-3 as A/B strips (Noob's own body casting it) and
    # NOOBAIRGUNK3/4/5/6/8 (the blast that opens the hole).  50,778 of 65,536.
    #
    # Its own sidecar rather than extra records in NOOBFX.LOD (PPP> 4):
    # NBPORTL_P is 32 entries the vortex uses in full, NOOBDEF_P is 64 and
    # NOOBGUK_P is 31, so nothing here can be cut to 4 bits.
    #
    # 2026-09-12: DEPTH IS NOW PER BLOCK.  The vortex and the blast pack at
    # 5bpp (their ramps reach index 31 and 30); Noob's own cast strips stay at
    # 6 because they are fighter art, and no bpp change to a fighter is safe
    # until the CPU shadow reader's ownership of the record is established.
    # 58,552 -> 50,778 payload bytes, guard 6,984 -> 14,758; the slot
    # boundaries are unchanged and NOTHING moves into the recovered bytes.
    # Mixed depth is safe in this file because both effect objects are
    # multipart and ani2 rewrites each piece's control word from the record;
    # the SONICCLAP garble was an ani0 merge keeping stale depth bits.
    # tools/check_noobport_packing.py holds the split.
    #
    # 2026-08-20: grew 0x79C000..0x7AA000 -> 0x79C000..0x7AC000 for the blast.
    # The base is PINNED FROM UNDERNEATH now - MTOPFLR took 0x791000..0x79C000
    # - so unlike the two previous growths this one could not come off the
    # UMK3FIRE run below.  It went UPWARD into RNVIC7's old slot, and RNVIC7
    # moved into BOSSHAM's tail to pay for it.  Guard is down to 2,880 on live,
    # still-growing art: the next set of frames will need something moved.
    # 2026-09-03: moved DOWN 0x79C000 -> 0x79A200 (and its end with it) so
    # BOSSHAM could grow for BGEYESHOT.  The slot is the same 65,536 bytes and
    # the guard is the same 6,984 - this art is live and still growing, so the
    # rebase deliberately took nothing from it.  What paid for BGEYESHOT was
    # MTOPFLR's and RAIN's slack below, plus RNVIC7 leaving the region.
    # 2026-09-09: moved DOWN again, 0x79A200 -> 0x796000, as the last link in
    # the chain that let BOSSHAM grow for BGHAMMERTOP7-9.  The slot is still
    # 65,536 bytes and the guard is still 6,984 - this rebase took nothing
    # from live art either.  What paid for the hammer was TIMEFLR leaving
    # bank 0, not a guard being squeezed.
    # End pulled back 0x7A6000 -> 0x7A2A00 on 2026-09-16: THE PIT (MK1) MK1PT2 sits in the
    # top of this guard.  Payload frozen, base unchanged.
    # OFF (noob_extras / vs_noob_smoke_pics = 0, MAINEQU): "NOOBPORT.IRW": (0x78BA90, 0x7980F0, "Noob shadow portal + cast + blast frames"),
    # Raiden's HELD victory pose as ONE 99x156 record instead of MK3MIL's four
    # RNVICTORY7A-D chunks.  The DMA over-reads a few bits at a chunk edge and
    # paints 3 junk pixels on an edge row; one piece has no interior boundary
    # for that to land on.  ~6.5KB against the chunks' 4,660 - as a single wide
    # rectangle the gap between his raised arms becomes 2,999 INTERIOR
    # transparent pixels and zero compression only skips leading/trailing runs.
    # Worth the trade only because this pose is HELD on screen; RNVICTORY1-6
    # flash past and keep their chunks.  See data/RNVIC7.LOD.
    # Moved 0x7AA000 -> 0x7BA000 on 2026-08-20 to hand its slot to NOOBPORT,
    # which had nowhere left to grow downward; that landed it in BOSSHAM's
    # tail.  Moved AGAIN 0x7BA000 -> 0x7FE200 on 2026-09-03, because BOSSHAM
    # needed that tail and the whole region below it for BGEYESHOT.  It now
    # sits in the ERMACSLM tail at the very top of bank 0 - which was the
    # largest free hole left in the bank (8,132 bytes) and had no other
    # claimant.  6,468 against 7,680, so 1,212 bytes of guard, unchanged in
    # spirit from what it had before.
    # One record, and its TBL is promoted, so the rebase is self-healing.
    # Slot end came back 0x800000 -> 0x7FFB80 when LKDKNEE3 took the tail.
    "RNVIC7.IRW": (0x7FE200, 0x7FFB80, "Raiden whole-frame held victory pose"),
    # Shao Kahn's BOSS8.IMG sidecar: the hammer-smash fatality (BGFATHAM1-7 as
    # fourteen A/B strips plus four BGHAMSWIPE blur frames), the over-the-top
    # swing (BGHAMMERTOP1-6), and now BGEYESHOT1-4 - the wind-up for the green
    # projectile (do_kahn_eyeshot).
    #
    # 2026-09-03: base 0x7AC000 -> 0x7AA200, end 0x7BA000 -> 0x7BC000, for
    # BGEYESHOT's 17,006 bytes.  Bank 0 had NO free run within 9KB of that
    # (largest hole was 8,132), and these are BODY frames, so bank 1 was not
    # an option - shadow_p1p2's shad7 walks them with a CPU read that has no
    # bank select.  The space came from pulling RAIN and NOOBPORT down against
    # MTOPFLR's payload end and moving RNVIC7 out to the ERMACSLM tail, which
    # spent only guards the LODs call slack or frozen and left NOOBPORT's
    # growth room alone.
    #
    # 72,054 of 73,216.  THE GUARD IS 1,162 BYTES - this sidecar is full, and
    # a fourth Kahn animation needs a slot moved rather than a record
    # appended.  FLAPJACK's 0x7BC000 base is the ceiling and it has 8,102
    # bytes of its own slack above the payload if it ever has to give.
    # 2026-09-09: base 0x7AA200 -> 0x7A6000, slot 73,216 -> 90,112, for the
    # OVER-THE-TOP swing growing from six frames to nine.  BGHAMMERTOP is
    # eighteen A/B strips now: 44,733 bytes, against 56,679 for the same nine
    # frames as whole composites - measured both ways, and that 11,946 is
    # nearly half of what the growth cost.  The other 14,336 came from
    # TIMEFLR moving to bank 1.  86,968 of 90,112, so 3,144 bytes of guard.
    # 2026-09-17: the whole bank-0 chain from JCLOGO up to here, and the
    # bank-1 chain from MK3CV2 up to SCLAP (plus the run above SCLAP), were
    # packed tight on 16-byte boundaries for SHASLAM below.  Every slot in
    # both chains is now [base, payload end rounded to 16) - there is no
    # growth room anywhere in them; the free bytes were gathered into one run.
    # The MK1 Pit bridge packs MK1PT1/PT2 and MK1PFLY/RAIN went to bank 1 to
    # pay for it (background art, never shadowed).  tmp/shaslam/plan.py has
    # the arithmetic.
    "BOSSHAM.IRW": (0x7980F0, 0x7AD4B0, "Kahn BOSS8 sidecar - hammers + eyeshot wind-up"),
    # Shao Kahn's throat slam, SHASLAM1-13 as 26 A/B strips out of
    # NEWSHAO.IMG (the UMK3 art).  56,652 bytes measured with a standalone
    # LOAD2 run; the same frames as whole composites are ~72KB.  Bank 0 is
    # required - body frames, walked by shadow_p1p2's bank-less CPU read.
    # Top of the packed run, 3,588 bytes of guard under FLAPJACK.
    "SHASLAM.IRW": (0x7AD4B0, 0x7BC000, "Kahn throat slam (SHASLAM1-13)"),
    # Shao Kahn's SOUL RIP, SHASOULRIP1-9 as twenty A/B/C strips out of
    # NEWSHAO.IMG.  42,214 bytes measured with a standalone LOAD2 run; the
    # same frames as whole composites are ~51,375.  Bank 0 is required -
    # body frames, walked by shadow_p1p2's bank-less CPU read.
    #
    # FIVE PACKS.  When this was built the packed sidecar region
    # 0x760000..0x7BC000 was full to its last few bytes (see the SHASLAM note
    # above), so the only space left in bank 0 was the four gaps above the
    # MKnMIL payloads plus FLAPJACK's tail - 53,608 bytes whose largest run
    # was 15,160.  The art is dealt across them biggest-first, the way THE
    # CAVE's MK3CV1-4 and THE PIT's MK1PT1-4 are dealt.
    #
    # Each pack sits at the TOP of its gap, so the MKnMIL file below keeps
    # its base and 834-1,074 bytes of growth room.  THAT IS ALL THE GROWTH
    # ROOM THOSE FILES HAVE LEFT: bank 0 is full after this, and the next
    # re-cut of core fighter art that grows an MKnMIL payload past its guard
    # needs one of these packs moved, not a nudge.
    # Dead Pool hanger TONY, two packs because his two libraries are both out
    # of room: the body after MK6MIL (bank 1, like Ed's EDHANG1 in MK7MIL) and
    # the skeleton in SHASLAM's tail (bank 0, like his DEDHANG1 in MOVEART1).
    # NOT the 15KB after MK4MIL - that is SKSOUL1's, and growing MK4MIL into it
    # is what the overlap check caught.
    "HANGTONY.IRW": (0x791000, 0x791A00, "Dead Pool hanger Tony - hanging body bands (was after MK6MIL: overlapped it once MK6MIL grew)"),
    "HANGTNYD.IRW": (0x7BB200, 0x7BBBD0, "Dead Pool hanger Tony - acid skeleton bands"),
    "TIGJMP6.IRW": (0x7BBBD0, 0x7BC000, "Kintaro stomp strip TIGERJUMP4D (bottom of HANGTNYD's guard)"),
    # Dead Pool hanger JOHN, in the run NOOBFX + VSNBMOV held (both off with
    # noob_extras / vs_noob_smoke_pics = 0, MAINEQU.ASM): body, then skeleton.
    # 2026-09-19 HANGER REPACK: John's two packs and the six in the NOOBPORT
    # run (Geo x2, Mark, Jeff, Steve, Tony) were packed tight on 512-byte
    # boundaries so their tails - 28KB in six pieces - came together into two
    # runs for the Mileena -> Jade select-box wipe (JADMIL1/2 below).  Only
    # the ***> lines moved; every SAG is a promoted TBL.  Proved by
    # tools/art_identity_snapshot.py (0 CHANGED) and the Dead Pool drop rig.
    "HANGJOHN.IRW": (0x759060, 0x759A00, "Dead Pool hanger John - hanging body halves"),
    # End pulled back 0x75F400 -> 0x75BE00 on 2026-09-19: THE WARRIOR SHRINE's
    # MK1WS2 sits in the top of the guard.  Base 0x75B060 -> 0x759A00 in the
    # repack above.
    "HANGJOHD.IRW": (0x759A00, 0x75A400, "Dead Pool hanger John - acid skeleton halves"),
    # JADMIL2 (JADEMIL7) sat at 0x75A400..0x75B310 until 2026-09-25; TIGJMP1
    # keeps its own base, so retiring it just widens HANGJOHD's guard.
    "TIGJMP1.IRW": (0x75B310, 0x75BE00, "Kintaro stomp strip TIGERJUMP4C (old JADMIL2 run)"),
    # Dead Pool hanger GEO, at the bottom of the run NOOBPORT held.
    "HANGGEO.IRW":  (0x78BA90, 0x78C400, "Dead Pool hanger Geo - hanging body pieces"),
    "HANGGEOD.IRW": (0x78C400, 0x78CE00, "Dead Pool hanger Geo - acid skeleton pieces"),
    # The rest (RESTHANG.WAX): Mark/Jeff/Steve up the NOOBPORT run, Sal/Eric
    # in the slot VSSMMOV held.  Body + skeleton in one pack each.
    "HANGMARK.IRW": (0x78CE00, 0x78E600, "Dead Pool hanger Mark - body + skeleton"),
    "HANGJEFF.IRW": (0x78E600, 0x78FA00, "Dead Pool hanger Jeff - body + skeleton"),
    "HANGSTEV.IRW": (0x78FA00, 0x791000, "Dead Pool hanger Steve - body + skeleton"),
    # JADMIL1 (JADEMIL1-6, 8 bit) held 0x791A00..0x797440 in the top of the
    # NOOBPORT run until 2026-09-25.  Retired with the rest of the Mileena ->
    # Jade wipe; LKDKNEE2 below keeps its own base, so the whole 23KB is free.
    # LIU KANG'S DOUBLE KNEE, packs 2 and 3.  The ten LKDUBLKNEE strips came out
    # of MOVEART2 on 2026-09-20 as dead art and the move is coded now, so they go
    # back - but bank 0 no longer has one hole that holds 8,571 bytes.  Pack 1
    # (4,572 B) is a section at the end of data/MOVEART2.LOD, inside that slot.
    # Pack 2 (3,082 B) takes JADMIL1's tail, bottom-anchored one 64-byte boundary
    # past its payload end (0x79743C) and running to BOSSHAM's fixed base.  Pack 3
    # (917 B) takes RNVIC7's tail up to the top of bank 0.  Both files below are
    # finished art; there is no way to leave either growth room and still fit.
    "LKDKNEE2.IRW": (0x797440, 0x7980F0, "Liu Kang double knee pack 2 (JADMIL1 tail)"),
    "LKDKNEE3.IRW": (0x7FFB80, 0x800000, "Liu Kang double knee pack 3 (RNVIC7 tail)"),
    # SHANG TSUNG'S FIRST ELBOW, data/STELBO1.LOD.  One record, STELBO1B out
    # of TSUNG2.IMG - the back half of a frame retail packed only the front of
    # (MK3MIL.LOD says "STELBO1A,STELBO1A,STELBO2A").  Bottom-anchored on the
    # first free byte above HANGJOHD's slot end and stopped at the 512-byte
    # boundary that clears the ~1,700-byte estimate with margin; TIGJMP1's base
    # at 0x75B310 is untouched.  MK3MIL itself has 960 bytes left, which is why
    # this is a sidecar and not an extra name on its TSUNG2 line.
    "STELBO1.IRW": (0x75A400, 0x75AC00, "Shang Tsung first elbow - STELBO1B"),
    # THE TOWER's pillar reflection: CASTLE.IMG's PILREF with a dither fade
    # (tools/make_pilref_img.py).  0x75AC00..0x75B310 was claimed by no slot -
    # STELBO1 stops at 0x75AC00 and TIGJMP1 starts at 0x75B310.  ~1,260 bytes.
    "PILREFD.IRW": (0x75AC00, 0x75B310, "THE TOWER pillar reflection (CASTLE PILREF, faded)"),
    "HANGSAL.IRW": (0x400800, 0x4018A0, "Dead Pool hanger Sal - body + skeleton"),
    "TIGJMP4.IRW": (0x4018A0, 0x402100, "Kintaro stomp strip TIGERJUMP1D (bottom of HANGSAL's guard)"),
    "HANGERIC.IRW": (0x402100, 0x403200, "Dead Pool hanger Eric - body + skeleton"),
    # JADMIL3 (FN3BOX at 7 bit) held 0x403200..0x404000 until 2026-09-25 -
    # the end of the Mileena -> Jade wipe, between HANGERIC and MK4MIL.
    # LIU KANG'S X-RAY FLASH (LUBUZZ2 out of MKSHOCK.IMG) in Raiden's lift
    # fatality, ~2.1KB against 3,584.  BANK 0 because it is a BODY frame that
    # casts a shadow - see data/LUBUZZ.LOD.  The whole JADMIL3 tail, which no
    # IRW had claimed, so nothing is pulled back.
    "LUBUZZ.IRW": (0x403200, 0x404000, "Liu Kang X-ray flash, Raiden lift fatality (retired JADMIL3 tail)"),
    # The other seven X-ray flashes, BANK 1 - safe only because rd_lift_buzz
    # (MKRDLIF.ASM) turns the victim's shadow off for those steps; see
    # data/XRAY1.LOD.  Two records a pack, sized off LUBUZZ2's real payload
    # (+9% over the IMG estimate).
    "XRAY1.IRW": (0x9DE600, 0x9E0000, "X-ray flashes Cage/Shang (RAINCLD's tail)"),
    "XRAY2.IRW": (0x9EC800, 0x9EE000, "X-ray flashes Kung Lao/Raiden (RAINBOLT's tail)"),
    "XRAY3.IRW": (0xB80800, 0xB82000, "X-ray flashes Kitana family (SMROPE's tail)"),
    "XRAY4.IRW": (0x9CA000, 0x9CB000, "X-ray flash Baraka/ninjas/Jax (NOOBPRJ..ERBOX, unclaimed)"),
    # The rest of MKSHOCK.IMG's X-rays, so every one is in the ROM whether a WAX
    # names it yet or not (2026-10-04).  One a pack - no hole left holds two.
    "XRAY5.IRW": (0x754000, 0x755740, "X-ray flash JXBUZZ2 (MK1TR4's tail, bank 0)"),
    "XRAY6.IRW": (0x9DA900, 0x9DC000, "X-ray flash SGBUZZ2 (RNBOX's tail)"),
    "XRAY7.IRW": (0x9E3300, 0x9E4000, "X-ray flash INBUZZ2 (SLICEHAT's tail)"),
    "XRAY8.IRW": (0xB79400, 0xB7A000, "X-ray flash OBBUZZ2 (MK7MIL's tail, under NOOBRING)"),
    "XRAY9.IRW": (0x9C9500, 0x9CA000, "X-ray flash TRBUZZ2 (NOOBPRJ's tail)"),
    "SKSOUL1.IRW": (0x6028E0, 0x606000, "Kahn soul rip pack 1 (MK4MIL gap)"),
    "SKSOUL2.IRW": (0x725790, 0x728000, "Kahn soul rip pack 2 (MK5MIL gap)"),
    "SKSOUL3.IRW": (0x1FE720, 0x200000, "Kahn soul rip pack 3 (MK2MIL gap)"),
    "SKSOUL4.IRW": (0x3FF060, 0x400800, "Kahn soul rip pack 4 (MK3MIL gap)"),
    # Pack 5 takes FLAPJACK's tail.  FLAPJACK's slot end came back
    # 0x7EF000 -> 0x7EE210 and MTNSKUL moved up to 0x7EF700 to put the whole
    # hole in one piece; both payloads are frozen and MTNSKUL's TBL is
    # promoted, so that rebase is self-healing.
    "SKSOUL5.IRW": (0x7EE210, 0x7EF700, "Kahn soul rip pack 5 (FLAPJACK tail)"),
    # RETIRED 2026-09-23: the Reptile -> Ermac wipe.  Ermac is now a START tap
    # on SCORPION (data/ERBOX.LOD) and Reptile has no morph, so this whole
    # slot is free again apart from TIGJMP3 at its top.
    # The select screen's Reptile -> Ermac box wipe (REPERM1-7 + ERBOX, 8bpp,
    # ~30.8KB).  Taken off the TOP of FLAPJACK's free tail, directly under
    # SKSOUL5, so FLAPJACK keeps its base and the rest of the WAFFLE HOUSE
    # hole below stays one run.  See data/REPERM.LOD.
    # "REPERM.IRW": (0x7E6000, 0x7ED860, "Reptile/Ermac select box morph (FLAPJACK tail)"),
    # ...and that is the slot the KITANA -> JADE wipe took on 2026-09-25.
    # 30,816 bytes against 30,800: REPERM was the same eight 55x70 8-bit
    # boxes, so the fit is proven rather than estimated.  A 55x70 ZOF record
    # at PPP 8 is always 3,850 bytes, which is why 16 bytes of slack is safe
    # here and would not be for compressed art.  See data/JDBOX.LOD.
    "JDBOX.IRW":   (0x7E6000, 0x7ED860, "Kitana/Jade select box morph (REPERM's old FLAPJACK-tail slot)"),
    "TIGJMP3.IRW": (0x7ED860, 0x7EE210, "Kintaro stomp strip TIGERJUMP3C (bottom of REPERM's guard)"),
    # Smoke's VS portrait. A movie frame MUST be bank 0 - movie_run
    # (UNZIP.ASM) has no video-ROM bank select, so a bank-1 label decodes bank
    # 0's bytes at the same window and hangs the game; VSSMMOV was built in
    # the bank-1 MKSOUL1 tail first and hung the VS screen.
    #
    # It lived in the bank-0 MK3MIL-to-MK4MIL gap at 0x400800 until
    # 2026-08-20, when the UGSPARK re-cut grew MK3MIL by 1,508 bytes to
    # 0x400E74 and ran into it. That gap is capped by MK4MIL's hard 0x404000
    # base, so after the collision only 12,288 bytes were left there against a
    # 13,336-byte payload - it could not be nudged, it had to move. Re-sited
    # in the run after TIMEFLR, the ONLY bank-0 hole still big enough, with
    # 15,336 bytes of guard below MTOPFLR's 0x791000 base.
    #
    # The old gap is free again and is where MK3MIL now grows into: about
    # 12.5KB from 0x400E74 up to 0x404000. Note tools/rom_space_report.py
    # over-reported that region as one 44,438-byte run because it does not
    # subtract TIMEFLR; compute holes from makevrom's own placement list.
    # OFF (noob_extras / vs_noob_smoke_pics = 0, MAINEQU): "VSSMMOV.IRW": (0x400800, 0x404000, "Smoke VS portrait, zipped movie frame"),
    "SCLAP.IRW": (0xBF1000, 0xC00000, "Shao Kahn Sonic Clap fixed sidecar"),
    # End pulled back from 0x800000 - which was never real, JADVIC/ERMACSLM/
    # RNVIC7 have always sat inside it - to 0x7EF000, so MTNSKUL below has a
    # declared floor under it instead of relying on the pairwise payload
    # check alone.  FLAPJACK's real payload ends at 0x7EE05A, so it keeps
    # 3,998 bytes of guard.
    # End pulled back again 0x7EF000 -> 0x7EE210 on 2026-09-18 so the soul
    # rip's pack 5 could have the tail; FLAPJACK's payload ends at 0x7EE05A,
    # so it keeps 438 bytes of guard on frozen background art.
    # End pulled back again 0x7EE210 -> 0x7E6000 on 2026-09-18 for REPERM.
    # WAFFLE HOUSE's removal left the real payload ending near 0x7D3A6E, so
    # the numbers above are history; FLAPJACK still has ~74KB of guard.
    # End pulled back again 0x7E6000 -> 0x7D4200 on 2026-09-19: THE WARRIOR
    # SHRINE's MK1WS1 sits in the top of the guard.  Payload ends 0x7D3A6E,
    # so FLAPJACK keeps 1,938 bytes of guard.
    "FLAPJACK.IRW": (0x7BC000, 0x7D3A70, "FLAPJACK sprite sidecar (WAFFLE HOUSE stage removed)"),
    "TIGJMP5.IRW": (0x7D3A70, 0x7D4200, "Kintaro stomp strip TIGERJUMP1C (bottom of FLAPJACK's guard)"),
    # YOTEIGAI TOR's rising skull, fleshup1-7.  4,096 bytes against a
    # ~3,000-byte payload, taken off the TOP of the FLAPJACK-to-JADVIC hole
    # so FLAPJACK keeps its base.  Bank 0 - same stage as MTOPFLR and RAIN.
    # Moved up 0x7EF000 -> 0x7EF700 on 2026-09-18, against JADVIC's fixed
    # 0x7F0000 base, so the soul rip's pack 5 has the run below it in one
    # piece.  2,304 bytes against a 2,170-byte payload; the art is frozen and
    # its TBL is promoted, so the rebase is self-healing.
    "MTNSKUL.IRW":  (0x7EF700, 0x7F0000, "Yoteigai Tor stage-fatality rising skull"),
    # Verified free via a fresh `python makevrom.py` run (2026-07-19): SCLAP's
    # real payload ends at 0xBF2D80, leaving 0xBF2D80..0xC00000 (53,888 bytes)
    # unclaimed in bank-1's tail. 0xBF4000 start leaves a 0x1280-byte margin
    # past SCLAP's real end in case its own payload grows slightly.
    # Slot end pulled back from 0xC00000 to 0xBF8400 (real payload ends at
    # 0xBF826A, so 406 bytes of guard remain) to hand the bank-1 tail - the
    # largest free run left in the ROM - to SHAOFIST.  SHAOFIST holds all ten
    # pulp frames (26,664 of 31,232); it needed three tails until the art was
    # re-cut from composites into multipart strips.
    # BANK 0, and it has to stay bank 0.  JDTHROWBLADE2-4 are body frames, so
    # Jade casts a shadow off them, and shadow_p1p2's shad7 walks the
    # compressed lines with a CPU read that has no bank select (same rule that
    # pins movie frames to bank 0).  In the old bank-1 tail that read aliased
    # onto bank 0's bytes and shredded the shadow while the DMA-drawn sprite
    # stayed clean.  Placed in the free run after GOROWALK (0x781A4E).
    # End pulled back 0x787000 -> 0x786800 on 2026-09-09.  It always overlapped
    # TIMEFLR's declared base and only the pairwise PAYLOAD check kept that
    # honest; SAHELI sits at 0x786800 now, so the declared slot has to agree.
    # JADERANG's payload ends at 0x786730 - 208 bytes of guard, unchanged.
    "JADERANG.IRW": (0x778020, 0x77C750, "Jade boomerang sidecar (bank-0, shadow-safe)"),
    # Outer Haven's portal staircase as per-tile strips: nine views, 8..11
    # tiles each, 90 records.  Drawn as a multipart so each tile moves by its
    # own anipoint - that is what makes the sweep fluid instead of nine rigid
    # frame swaps.  ~16KB at 5bpp against ~32KB for the composites.
    #
    # Placed in the run left after JADERANG's payload inside the staged
    # UMK3FIRE window.  JADERANG is already sited there, so this follows that
    # precedent; UMK3FIRE is staged, not shipped (absent from irw_files below,
    # umk3_burn_enable is 0 in src/MAINEQU.ASM).
    # Slot end pulled back 0x78B400 -> 0x78A000 to seat SAHELI below MTOPFLR.
    # Start moved 0x786400 -> 0x786600 -> 0x786800 (LOD base 0x05C32000 ->
    # 0x05C33000 -> 0x05C34000).  Both moves were JADERANG growing underneath
    # it: first BOOMGHOST, then UBWISP + UBTRAIL1-6 when the boomerang's trail
    # was rebuilt as the arcade's dissipating smoke (every echo is born as the
    # wisp and animates through the six trail frames).  JADERANG's payload is
    # now 18,224 and ends at 0x786730, so this start must stay above that.
    #
    # TIMEFLR's payload is 14,250 and ends at 0x789FAA, which leaves only
    # 86 bytes before SAHELI at 0x78A000.  THIS RUN IS NOW FULL - the art is
    # finished (nine authored views, 90 strips) so TIMEFLR itself will not
    # grow, but nothing else can be squeezed in here and the next sidecar
    # that grows in bank 0 has to move somebody rather than shave this.
    # MOVED TO BANK 1 2026-09-09: 0x786800 -> 0xBE0000, into the bottom of the
    # ROBOFIRE-to-ERMFIRE run.  Background art, DMA-only, no shadow_p1p2 CPU
    # read - the same class as HICLOUD and as every background in MK7MIL - so
    # nothing about it needed bank 0 except history.  The 14,336 bytes it gave
    # back are the whole reason BOSSHAM could grow from 73,216 to 90,112 for
    # BGHAMMERTOP7-9; SAHELI, MTOPFLR, RAIN and NOOBPORT each slid down by
    # exactly that much behind it, spending none of their own guards.
    "TIMEFLR.IRW": (0xBDC330, 0xBDFAE0, "Outer Haven staircase, per-tile strips"),
    # Shao Kahn's hammer glow: HAMMERGLOWTOP1-5 for the over-the-top swing and
    # HAMMERGLOWSIDE1/SIDE2/SID3 for the fatality, all on the 16-entry
    # PURPHAM_P and so PPP 4.  4,416 bytes against 8,192.  Its own slot rather
    # than records in BOSSHAM because BOSSHAM is PPP 6 wall to wall and a
    # mixed-depth LOD is what garbled SONICCLAP.  See data/HAMGLOW.LOD.
    # End pulled back 0xBE6000 -> 0xBE5400 on 2026-09-16: THE PIT (MK1) MK1PSK5 sits in the
    # top of this guard.  Payload frozen, base unchanged.
    "HAMGLOW.IRW": (0xBDFAE0, 0xBE0C20, "Shao Kahn hammer glow, both swings"),
    # THE TOWER's six terracotta guard REFLECTIONS - STATREF1a/1b/2a/2b/3a/3b
    # out of CASTLE.IMG, the statue-base strips Midway drew for a castle stage
    # that was never built.  ~4,124 bytes uncompressed against an 8,192-byte
    # slot (ZON> makes it smaller - the art is a 50%% checkerboard, so half the
    # pixels are zero).
    #
    # THIS RUN WAS UNCLAIMED.  0xBE6000 is exactly where HAMGLOW's slot ends
    # and 0xBE8000 is exactly where ERMFIRE's begins, so this took growth room
    # from neither - the one gap in bank 1 that belonged to nobody.  Do not
    # widen it downward into HAMGLOW or upward into ERMFIRE without moving
    # that file's base first.  See data/STATREF.LOD.
    # End pulled back 0xBE8000 -> 0xBE7000 on 2026-09-16: THE PIT (MK1) MK1PSK4 sits in the
    # top of this guard.  Payload frozen, base unchanged.
    "STATREF.IRW": (0xBE0C20, 0xBE1A20, "THE TOWER terracotta guard reflections"),
    # Shao Kahn's green-projectile MUZZLE FLASH: KAHNGLOWA out of NEWSHAO.IMG,
    # on the 15-entry SKGLOW_P and so PPP 4.  MK3's own art for the move
    # (REV21/MKSK.ASM a_zap, where `ani_sladd,KAHNGLOW` is commented out).
    #
    # THIS RUN WAS UNCLAIMED.  MKSOUL1's slot ends at 0x9FC000 and MK1PSK3's
    # base is 0x9FE800, so the 10,240 bytes between them belonged to nobody;
    # this takes the bottom 4,096 and leaves 6,144 still free above it.  It is
    # NOT in HAMGLOW because HAMGLOW's slot is exactly full (4,416 of 4,416).
    # Do not widen this downward into MKSOUL1 or upward past 0x9FD000 without
    # moving that file's base first.  See data/SKGLOW.LOD.
    # End pulled back 0x9FD000 -> 0x9FC400 on 2026-09-30: THE THRONE ROOM's
    # seated Shang Tsung sits in the top of the guard and the free run above
    # it.  SKGLOW is 306 bytes of finished art (one record) and keeps 718
    # bytes of guard, more than twice its payload.
    "SKGLOW.IRW": (0x9FC000, 0x9FC400, "Shao Kahn green-projectile muzzle flash"),
    # THE THRONE ROOM (MK1) - SHANG TSUNG SEATED ON THE THRONE, the one
    # process MK1's calla creates.  Eleven records (seven heads and the four
    # pieces every frame shares) decoded out of mk.zip by
    # tools/make_mk1throne.py --shang; the five arms-open records MK1 builds
    # on and never shows stay in the IMG and are NOT packed.  Bank 1: a
    # background object, never a shadow source and never a movie frame.
    # The slot is SHANG_PACK in that tool - move them together.
    "MK1TRSH.IRW": (0x9FC400, 0x9FE800, "THE THRONE ROOM (MK1) seated Shang Tsung"),
    # Pack 2, for the CLAP poses.  Top of JDROD's guard - JDROD is Jade's
    # staff, finished art, and keeps 3,634 bytes.  Also SHANG_PACKS in
    # tools/make_mk1throne.py - move them together.
    # End pulled back 0x9E8000 -> 0x9E7700 on 2026-10-05: THRCHP1, a strip of
    # the empty throne, sits in the tail.  SHANG_PACKS still says 0x9E8000 on
    # purpose - its deal fills to 90% of that number and a smaller one would
    # re-deal Shang; the overlap check here is what stops him growing into it.
    "MK1TRS2.IRW": (0x9E6400, 0x9E7700, "THE THRONE ROOM (MK1) Shang Tsung, clap poses"),
    # THE THRONE ROOM's EMPTY THRONE - drawn instead of the seated Shang Tsung
    # when either player is Shang (mk1thrn_calla, MK1THRN.ASM).  Three strips
    # of MKBGANI.IMG's thrnchair, only the pixels he covers, cut by
    # tools/make_thrnchair.py (STRIPS - move them together).  ~1.5K/1.3K/1.1K
    # of payload each.  Bank either way: background objects, never a shadow
    # source and never a movie frame.
    "THRCHP1.IRW": (0x9E7700, 0x9E8000, "THE THRONE ROOM empty throne, strip 1 (MK1TRS2's tail)"),
    "THRCHP2.IRW": (0x796C00, 0x797400, "THE THRONE ROOM empty throne, strip 2 (MK1TR1's tail)"),
    "THRCHP3.IRW": (0xBFBB00, 0xBFC200, "THE THRONE ROOM empty throne, strip 3 (MK1TR2's tail)"),
    # Rain's lightning bolt (RAINLT1-6, MK Trilogy N64 art via
    # tools/make_rainbolt_img.py).  Top of the MK6MIL free run, hard under
    # CAVEFLR, so MK6MIL keeps its growth room below.
    # End pulled back 0x9EE000 -> 0x9EC800 on 2026-10-04: XRAY2 (the lift
    # fatality's X-ray flashes) sits in the top of the guard.  Payload frozen.
    "RAINBOLT.IRW": (0x9E8000, 0x9EC800, "Rain lightning bolt (top of the MK6MIL free run)"),
    # Jade's staff impale rod (RODIMPALE1-7 out of KITANA11.IMG, UMK3's own
    # staff).  Top of the MK6MIL free run, hard under RAINBOLT.
    # End pulled back 0x9E8000 -> 0x9E6400 on 2026-09-30: MK1TRS2 sits in the
    # top of the guard.  JDROD is 5,582 bytes of finished art and keeps 3,634.
    # End pulled back 0x9E6400 -> 0x9E5A00 on 2026-10-10: DISCOB2 sits in the
    # top of the guard.  JDROD's payload ends at 0x9E59CE.
    "JDROD.IRW": (0x9E4000, 0x9E5A00, "Jade staff impale rod (top of the MK6MIL free run)"),
    # The Discord page picture (tools/make_discord_ob.py): the bottom half in
    # JDROD's old guard, the top half above RAIN at the very top of bank 1.
    "DISCOB2.IRW": (0x9E5A00, 0x9E6400, "Discord page picture, bottom half"),
    "DISCOB1.IRW": (0xBFF600, 0xC00000, "Discord page picture, top half"),
    # Rain's water move (the storm cloud, its burst and its raindrops - MK
    # Trilogy N64 art via tools/make_raincld_img.py).  Top of the MK6MIL free
    # run, hard under JDROD.
    # NOOB SAIBOT'S GHOST BALL (2026-09-28).  Top of the MK6MIL free run, hard
    # under ERBOX's fixed 0x9CB000 base.  MK6MIL's payload ends at 0x9C5522, so
    # it keeps 6,878 bytes to grow into below this.  16,384 bytes against a
    # ~13,500-byte payload: the margin is deliberate, because a packed size
    # estimated off the IMG runs 3-14% low in this tree.  If it ever overflows,
    # data/NOOBPRJ.LOD's comment names the four flight frames to drop (Trilogy
    # itself packs only four of the eight).
    # The kiss of death's BLOOD SPLASH (BLDSPLASH2-5 out of MKMORPH2.IMG; retail
    # packed only frame 1).  4,930 bytes off a real LOAD2 run.  Top of the run
    # between MK6MIL's payload end (0x9C5522) and NOOBPRJ, so MK6MIL keeps
    # 1,758 bytes to grow into below it.
    "BLDSPLSH.IRW": (0x9C5C00, 0x9C7000, "Kiss of death blood splash (top of the MK6MIL tail)"),
    # End pulled back 0x9CA000 -> 0x9C9500 on 2026-10-04 for XRAY9.
    "NOOBPRJ.IRW": (0x9C7000, 0x9C9500, "Noob ghost ball (top of the MK6MIL free run)"),
    # The ghost RING, 13,611 bytes.  Top of the MK7MIL free run, hard under
    # SMROPE's fixed 0xB7E000 base; MK7MIL keeps 0xB7933A..0xB7A000.  It could
    # not join NOOBPRJ: the two together are 23,157 bytes and no single free
    # run left in either bank is that big.
    # End pulled back 0xB7E000 -> 0xB7D600 on 2026-10-05 for KTSOULB.
    "NOOBRING.IRW": (0xB7A000, 0xB7D600, "Noob ghost ring (top of the MK7MIL free run)"),
    # SOULSUCKKT1B/2B, ~1,700 bytes, in NOOBRING's tail hard under SMROPE.
    "KTSOULB.IRW": (0xB7D600, 0xB7E000, "Female ninja soul-suck wither upper halves"),
    # RAINCLD gave up the top half of its slot to SLICEHAT: it was 0x9DC000..
    # 0x9E4000 (32,768) against a ~9,400-byte payload, and 16,384 still leaves
    # it ~7KB of growth.
    # End pulled back 0x9E0000 -> 0x9DE600 on 2026-10-04 for XRAY1; the
    # payload ends 0x9DE48C and the cloud is finished art.
    "RAINCLD.IRW": (0x9DC000, 0x9DE600, "Rain storm cloud (top of the MK6MIL free run)"),
    # RAINBUB's slot was 0xBF2000..0xBF6000 (7,226 bytes of payload), the
    # BOTTOM of the 16,940-byte run above SCLAP (0xBF1FA4).  RETIRED
    # 2026-09-29: the whole run above SCLAP is free again, ~16,848 bytes to
    # 0xBF61D0, which is the largest single hole in bank 1.
    # Kung Lao's hat at ANGLE (SLICEHAT1-6/13-16 out of HATHED12.IMG - renders
    # of the hat banked for the angle it is flying at, in no retail IMG and
    # never packed).  Top of the MK6MIL free run, hard under JDROD's fixed
    # 0x9E4000 base.  ~8,600 bytes against 16,384: the margin is deliberate,
    # because a packed size estimated off the IMG runs 3-14% low in this tree.
    # If it ever overflows, SLICEHAT6 (the -38.8 deg climb extreme) is the one
    # to drop - hat_proc then clamps the climb at SLICEHAT5.
    # End pulled back 0x9E4000 -> 0x9E3300 on 2026-10-04 for XRAY7.
    "SLICEHAT.IRW": (0x9E0000, 0x9E3300, "Kung Lao hat bank angles (top of the MK6MIL free run)"),
    # Smoke's harpoon (COMEHERE1/2/3 out of NEWROPE.IMG - Midway's second rope,
    # the coiled spring with a trident head, drawn beside Scorpion's and never
    # packed by retail).  Top of the MK7MIL free run, hard under MK3CV2's base,
    # so MK7MIL keeps everything below it to grow into.  ZOF> in the LOD, so
    # the payload is exactly W*H*5 bits a record - see data/SMROPE.LOD for why
    # it must not be compressed.
    # End pulled back 0xB82000 -> 0xB80800 on 2026-10-04 for XRAY3.  ZOF>,
    # so the payload is exact (W*H*5 bits a record) and cannot creep.
    "SMROPE.IRW": (0xB7E000, 0xB80800, "Smoke harpoon rope (top of the MK7MIL free run)"),
    # The Scorpion -> Ermac select-box wipe (ERBOX2..9, 8bpp, 30,800 bytes),
    # under RNBOX's base in the same run.  See data/ERBOX.LOD.
    "ERBOX.IRW": (0x9CB000, 0x9D3000, "Scorpion/Ermac select box morph (MK6MIL free run)"),
    # The Sub-Zero -> Rain select-box wipe (RNBOX8..1, 8bpp, 30,800 bytes),
    # off the TOP of the run the friendship removal left after MK6MIL and
    # under RAINCLD's fixed base, so MK6MIL keeps ~56KB of growth below it.
    # End pulled back 0x9DC000 -> 0x9DA900 on 2026-10-04 for XRAY6.
    "RNBOX.IRW": (0x9D3000, 0x9DA900, "Sub-Zero/Rain select box morph (MK6MIL free run)"),
    # Baraka's Up,Up+LK heliport DESCENT: the eight whole-frame spin records
    # out of UGMO9SP.IMG (a_sa_heli_drop / do_sa_heliport).  23,782 bytes
    # against a 28,672-byte slot.
    #
    # BANK 0.  These are body frames and the only reason the shadow does not
    # shear off them (shadow_p1p2's shad7 CPU read has no bank select - the
    # rule that pins JADERANG and every movie frame to bank 0) is that
    # do_sa_heliport clears m_shadow for the whole teleport.  Do not move this
    # to a bank-1 tail on the strength of that: restoring the shadow one frame
    # earlier would be enough to shred it.
    #
    # Carved off TIMEFLR's guard plus the free run below MTOPFLR's 0x791000
    # base, inside the staged UMK3FIRE window - the same run BOSSHAM, RNVIC7,
    # NOOBPORT, MTOPFLR and TIMEFLR were all taken from.  It was the only
    # bank-0 hole big enough: the next largest is MTOPFLR's own 8,880-byte
    # tail.
    # Base moved 0x78A000 -> 0x786800 on 2026-09-09, into the slot TIMEFLR
    # vacated when it moved to bank 1.  The payload and the guard are
    # unchanged - the whole chain up to BOSSHAM shifts by the same 14,336
    # bytes, so nothing here was spent.
    "SAHELI.IRW": (0x77C750, 0x782D40, "Baraka heliport descent spin frames"),
    # SHAOFIST's slot was 0xBF73D0..0xBFC2E0 - 20,236 bytes of payload with no
    # guard left (MK1PSK1 starts 20 bytes past its end).  RETIRED 2026-09-29,
    # so 0xBF73D0..0xBFC2E0 is now a clean 20,240-byte hole.  MK1PSK1 keeps its
    # 0xBFC2E0 base: nothing was relocated to take these bytes.
    # Historical, for the prose elsewhere in the tree: 0x789000..0x790000 used
    # to be free and held JADVIC1, one half of a two-slot Jade victory split
    # that never had any payload (both LODs asked for JDVICTORY*A/*B strips
    # JADERANG.IMG does not contain, so LOAD2 wrote header-only IRWs; the 15
    # composites live entirely in JADVIC).  0x790000..0x797000 held STGORO,
    # the "Goro lives" reveal removed 2026-08-05 - the RETAIL Kintaro morph is
    # untouched, it borrows Kintaro's own anitab.  0x797000..0x79B400 briefly
    # held VSNOOB, a sprite copy of Noob's portrait retired 2026-07-31 once
    # the movie form was proven.  All three ranges are inside the packed
    # region above now.
    # End pulled back from 0x800000 to 0x7FD200 to hand the tail to ERMACSLM.
    # JADVIC's payload ends at 0x7FD112, so this is the next 512-byte boundary
    # above it - the rule the packed region above uses - leaving a 238-byte
    # guard.  Taken off the TOP so JADVIC's 0x7F0000 base is untouched.  This
    # was the largest free run left in bank 0 at 12,014 bytes; the next largest
    # is the FLAPJACK tail at 8,102.
    # 2026-09-27: end 0x7FD200 -> 0x7FD120, spending 224 of that 238-byte guard
    # on ERMACSLM below, which had nowhere else to go - it is boxed in by
    # RNVIC7 at 0x7FE200 and NJTELESLAM3 was re-cut from three strips to two.
    # 0x7FD120 is the next 32-byte boundary above the 0x7FD112 payload end, so
    # JADVIC keeps 14 bytes; it is a finished pack and its payload is exact.
    "JADVIC.IRW": (0x7F0000, 0x7FD120, "Jade victory body+staff frames (post-FLAPJACK slack)"),
    # Ermac's telekinetic-slam pose, NJTELESLAM3A/B out of data/ERMAC.IMG.
    # BANK 0 IS MANDATORY, not a preference: these are BODY frames, and
    # shadow_p1p2 (MKDISP.ASM) walks the compressed sprite data with the CPU
    # and has no video-ROM bank select, so a bank-1 body frame draws perfectly
    # and ships a torn, speckled shadow.
    #
    # Only ONE pose is here.  The three earlier frames of the lift windup -
    # NJELBO1, NJELBO2, NJHIPUNCH7 - are stock ninja multipart frames already
    # in MK4MIL, reused at new anipoints, so they cost no video ROM at all.
    #
    # THE CEILING IS RNVIC7 AT 0x7FE200, NOT THE END OF THE BANK.  This slot
    # said 0x800000 until 2026-09-27 and that was stale by three weeks: RNVIC7
    # moved into this tail on 2026-09-03 and LKDKNEE3 took 0x7FFB80..0x800000.
    # Nothing caught it, because the payload was small enough never to cross
    # 0x7FE200 - declared slots are checked against their own payload, so two
    # slots that overlap EACH OTHER go unnoticed until one of them grows.  The
    # re-cut to two strips grew this pack to 4,188 bytes against the 4,096 the
    # real hole holds, and what failed was flat_rom (art_identity_snapshot.py)
    # comparing actual payloads, not the slot table.
    # A stale ceiling here defeats the SLOT check and nothing else: the
    # pairwise payload-overlap check below would still have refused to write
    # chips (it is what caught HANGTONY and MKSOUL1), so this could not have
    # shipped silently - it would have failed later and less legibly, blaming
    # RNVIC7 for a hole that was never ERMACSLM's to grow into.
    # Base 0x7FD200 -> 0x7FD120, bought out of JADVIC's guard above.
    "ERMACSLM.IRW": (0x7FD120, 0x7FE200, "Ermac telekinetic slam pose (JADVIC tail)"),
    # Bank-1 MK6-to-MK7 gap: MK6MIL's payload ends at 0x9F6AA0 and MK7MIL is
    # based at 0xA00000, so 0x9F7000 is the first 4KB boundary inside the hole.
    # Deliberately bank 1 - the rest of the soul-suck art (every *SOULSUCK*
    # pose and the CORPSE1A husk) is MKSOUL.IMG content inside MK6MIL.
    # The end went to 0x9FB400 for a while to lend the tail to SHAOFIS3, part
    # 3 of a three-way split of the Kahn portal-punch pulp.  Re-cutting that
    # art as multipart strips got all ten frames into SHAOFIST alone, so the
    # whole 0x9FB044..0xA00000 run (20,412 bytes) came back here.  It is the
    # largest free run left in the ROM, but it is BANK 1 - so it cannot hold a
    # movie frame.  VSSMMOV was built here first and hung the VS screen: see
    # the bank-0 note on VSSMMOV above.  Nothing here can grow past 0xA00000,
    # MK7MIL's hard base.
    # Slot end pulled back 0xA00000 -> 0x9FC000 to seat SAHELI3 in the tail.
    # Base moved 0x9F7000 -> 0x9F7C00 (LOD 0x02FB8000 -> 0x02FBE000) to let
    # MK6MIL grow: the callout icons, the MK3 win medal and the FONTFADE hit
    # counter pushed its payload from 0x9F6AA0 to just past 0x9F7000 and
    # makevrom refused the overlap.  This is the CHEAP side of that squeeze -
    # MKSOUL1 had 4,028 bytes of tail guard doing nothing, and spending 3,072
    # of it costs no art.  Its payload now ends at 0x9FBC44, keeping 956 bytes
    # before the slot end.  Nothing here can grow past 0xA00000, MK7MIL's
    # hard base; if MK6MIL ever needs more than this, the next thing to move
    # is MK7MIL, not this slot.
    "MKSOUL1.IRW": (0x9F7C00, 0x9FC000, "Shang Tsung soul-suck corpse drop"),
    # THE TOWER's high clouds: CLOUD2 (209x38) and CLOUD3 (96x15) out of
    # data/CASTLE.IMG, the two flat sky shapes that sit above the stock
    # drifting cloud row.  Midway drew them and packed them nowhere - no TBL
    # in the tree defines either label, so tower_mod's sky had only cloud1a-d.
    # Bank 1, the run above MK7MIL's tail - the largest free run left in the
    # ROM.  Own sidecar because MK6MIL, where cloud1a-d live and where these
    # belong by subject, has 1,376 bytes before MKSOUL1 against the 7,037 these
    # pack to; putting them there overlapped MKSOUL1 by 5,730 and makevrom
    # refused the write.
    # POF> - CASTLE.IMG's CLOUD palette is byte-identical to newcld_p, so
    # nothing is bound and nothing was added to IMGPAL6.  See data/HICLOUD.LOD.
    #
    # Moved 0xBD0000 -> 0xBEE000 on 2026-09-01.  MK7MIL grew when THE TOWER's
    # background became TWRSIDE (TOWER2 plus the four terracotta guards, +43KB
    # of BDD pixel data) and its payload ran 25,304 bytes into this slot.  Sat
    # at the BOTTOM of the free run before; now at the TOP of it, hard against
    # SCLAP's 0xBF1000 base, so MK7MIL keeps ~98KB to grow into and no other
    # sidecar has to move.  Same 8,192-byte slot it always had.
    "HICLOUD.IRW": (0xBE8480, 0xBE9620, "Tower high clouds CLOUD2/CLOUD3"),
    # Ermac's fireball - ERMFIRE1-11, the green starburst Shao Kahn throws in
    # UMK3, lifted 1:1 out of the arcade ROM by tools/make_ermfire_img.py.
    #
    # BANK 1, and unlike ERMACSLM/JADERANG that is not a compromise.  Those are
    # pinned to bank 0 because they are BODY frames: a body casts a shadow, and
    # shadow_p1p2 (MKDISP.ASM) walks the compressed data with a CPU read that
    # has no video-ROM bank select.  A projectile casts no shadow, nothing
    # walks this art with the CPU, and the DMA is bank-aware - so bank 1 is
    # simply correct here.
    #
    # Placed at the TOP of the free run above MK7MIL, hard under HICLOUD's
    # 0xBEE000 base - the same rule HICLOUD itself follows - so MK7MIL keeps
    # 0xBD5748..0xBE8000 (~74KB) to grow into and nothing else moves.
    # 5bpp, not 6: every frame tops out at colour index 30 against a 31-entry
    # palette, so the re-encode is lossless and costs a fifth less.
    # End pulled back 0xBEE000 -> 0xBEB400 on 2026-09-16: THE PIT (MK1) MK1PT3 sits in the
    # top of this guard.  Payload frozen, base unchanged.
    "ERMFIRE.IRW": (0xBE2980, 0xBE5A00, "Ermac fireball starburst (top of the MK7MIL free run)"),
    # Liu Kang's red-dragon fire breath - ROBOFIRE1-7 out of HORNBUCK.IMG,
    # the blast that replaces the borrowed MK1FIRE column in his flame
    # fatality.  Bank 1 for the same reason ERMFIRE above is: projectile
    # frames, no shadow, nothing CPU-walks them.
    #
    # Sits at the BOTTOM of the same free run, on the first 512-byte boundary
    # above MK7MIL's payload end (0xBDD534), so ERMFIRE keeps its base and
    # MK7MIL keeps its guard.  30,756 bytes against a 43,008-byte slot.
    # End pulled back 0xBE8000 -> 0xBE0000 on 2026-09-09 to seat TIMEFLR and
    # HAMGLOW above it.  ROBOFIRE's payload ends at 0xBDF8C0, so it keeps its
    # base and 1,856 bytes of guard.
    "ROBOFIRE.IRW": (0xBDA070, 0xBDC330, "Liu Kang dragon fire breath (bottom of the MK7MIL free run)"),
    # UMK3's exploding-body blood burst - BLDXPD1-13, decoded 1:1 out of the
    # arcade ROM by tools/make_bldxpd_img.py.  The three splats Ermac's
    # telekinetic slam fatality throws when the body pops (stand_blood_explode
    # -> cbx3, MKFX.C).  Replaced the drawn MKSPLASH1-4 stand-in.
    #
    # Hard UNDER ROBOFIRE's 0xBDD600 base, at the top of what is left of the
    # MK7MIL free run, so no existing sidecar moves.  Sized to the MEASURED
    # pack, not the raw pixels. Originally 63,196 payload bytes (63,264 with
    # the IRW header). Per-frame 4/3/2/1bpp now packs to 46,142 payload bytes,
    # leaving 19,394 reserved bytes; the slot boundaries are unchanged.
    # Bank 1 for the same reason ERMFIRE and ROBOFIRE are: blood casts no
    # shadow, so shadow_p1p2's CPU read - the one thing in the game with no
    # video-ROM bank select - never walks it.
    # End pulled back 0xBDD600 -> 0xBD9000 on 2026-09-16 to seat MK3CV4 in the
    # top of the guard.  The payload ends at 0xBD8A3E and is frozen (UMK3's
    # frames, decoded 1:1), so 1,474 bytes of guard remain and the base stays.
    "BLDXPD.IRW": (0xBCAA90, 0xBD5ED0, "UMK3 blood-explode burst (under ROBOFIRE)"),
    # Kintaro's leap out of the Kahn's Arena stands - SMTIGERJUMP1-4 as A/B
    # strips from TIGER3.IMG.  The prop-scale crouch and spring that hands
    # over to the full-size stomp coming down on Shang's body (MKSOULS.ASM).
    #
    # Hard UNDER BLDXPD's 0xBCD600 base, at the top of the free run above
    # TWRJNT, so nothing already placed moves.  48KB against ~36KB of raw
    # 6bpp art - LOAD2's zero compression takes it comfortably under.
    #
    # Bank 1 for the usual reason: only art a SHADOW is drawn from has to be
    # bank 0 (shadow_p1p2's CPU read has no video-ROM bank select), and
    # arena_goro_proc clears the shadow bit on this prop.
    # End pulled back 0xBCD600 -> 0xBC7000 on 2026-09-16 to seat MK3CV3 in the
    # top of the guard.  The payload ends at 0xBC66BE (four finished frames),
    # so 2,370 bytes of guard remain and the base stays.
    "SMTIGER.IRW": (0xBBF760, 0xBC4820, "Kintaro arena leap (under BLDXPD)"),
    # THE CAVE - MK3's unshipped cave stage.  Its 60 background images pack to
    # ~201KB and no free run is that big, so tools/make_mk3cave.py deals them
    # into four packs and merges the header tables back into the four modules
    # (src/MK3CAVBG.ASM) - a module's headers carry absolute SAGs, so its
    # blocks can live in any slot.  The pack boundaries are also PACKS in that
    # tool; move both together.  Bank 1: DMA-drawn background, never walked by
    # shadow_p1p2's bank-less CPU read.
    "MK3CV2.IRW": (0xB82000, 0xB95310, "THE CAVE image pack 2 (above MK7MIL, under TWRJNT)"),
    "MK3CV1.IRW": (0xBA10F0, 0xBB53A0, "THE CAVE image pack 1 (TWRJNT slot end .. ARNSKY)"),
    "MK3CV3.IRW": (0xBC4820, 0xBCAA90, "THE CAVE image pack 3 (top of SMTIGER's guard)"),
    "MK3CV4.IRW": (0xBD5ED0, 0xBDA070, "THE CAVE image pack 4 (top of BLDXPD's guard)"),
    # UMK3's FL_CAVE.BIN, 1200x42 raw 6bpp = 37,800 bytes, in the MK6MIL-to-
    # MKSOUL1 gap.  MK6MIL's payload ends at 0x9EC762, so it keeps 6,302 bytes
    # of growth room below this base.
    "CAVEFLR.IRW": (0x9EE000, 0x9F7C00, "THE CAVE skew floor (UMK3 FL_CAVE)"),
    # THE PIT (MK1) - MK1's bridge stage, its shaft and its night sky.  The
    # bridge/shaft art is KUNGFU5 images the Pit Bottom does not already carry
    # (~45KB) and the sky is MK1's own moon, rocks, clouds and silhouettes out
    # of mk.zip (~27KB).  No free run holds either, so tools/make_mk1pit.py
    # deals both into packs seated in the TOPS of ten frozen slots' guards and
    # --apply merges the headers back (src/MK1PTOPB.ASM).  The slots are also
    # PACKS / SKY_PACKS / FLY_PACK in that tool - move them together.  Either
    # bank is safe for all of it: background blocks and m_noscroll sky
    # objects, none of it a shadow source or a movie frame.  NOT JCLOGO's
    # guard - clip41 reads any flipped SAG in 0x728000..0x730000 as a logo.
    "MK1PT1.IRW": (0xBE9620, 0xBED770, "THE PIT (MK1) bridge pack 1 (top of SHAOSIT's guard)"),
    "MK1PT2.IRW": (0xBED770, 0xBF0B10, "THE PIT (MK1) bridge pack 2 (top of NOOBPORT's guard)"),
    "MK1PT3.IRW": (0xBE5A00, 0xBE8480, "THE PIT (MK1) bridge pack 3 (top of ERMFIRE's guard)"),
    "MK1PT4.IRW": (0xBF61D0, 0xBF73D0, "THE PIT (MK1) bridge pack 4 (over the free SAHELI2 run)"),
    "MK1PSK1.IRW": (0xBFC2E0, 0xBFEB10, "THE PIT (MK1) sky pack 1 (above the retired SHAOFIST hole)"),
    "MK1PSK2.IRW": (0x732D50, 0x734670, "THE PIT (MK1) sky pack 2 (top of JCAIRKIK's guard)"),
    "MK1PSK3.IRW": (0x9FE800, 0x9FFE00, "THE PIT (MK1) sky pack 3 (over the free SAHELI3 run)"),
    "MK1PSK4.IRW": (0xBE1A20, 0xBE2980, "THE PIT (MK1) sky pack 4 (top of STATREF's guard)"),
    "MK1PSK5.IRW": (0xBFEB10, 0xBFF090, "THE PIT (MK1) sky pack 5 (top of HAMGLOW's guard)"),
    "MK1PFLY.IRW": (0xBFF090, 0xBFF490, "THE PIT (MK1) moon silhouettes (top of JCFKICK's guard)"),
    # THE WARRIOR SHRINE (MK1) - MK1's statue gallery, data/KUNGFU1.  90 new
    # images (~82KB; three more reuse THE PIT's SAGs), dealt by
    # tools/make_mk1shrine.py into two packs seated in the TOPS of the two
    # biggest guards left in bank 0 - FLAPJACK's (the WAFFLE HOUSE hole) and
    # HANGJOHD's - and merged back by --apply (src/MK1WSHRB.ASM).  The slots
    # are also PACKS in that tool - move them together.  Background blocks
    # only: never a shadow source or a movie frame, so either bank is safe.
    # MK1WS3 is the top 1KB of the FLAPJACK run, a PPP> 6 pack for the two
    # blocks LOAD2's auto depth would store a bit short (WIDE_TAIL, the tool).
    "MK1WS1.IRW": (0x7D4200, 0x7E5120, "THE WARRIOR SHRINE (MK1) pack 1 (top of FLAPJACK's guard)"),
    "TIGJMP2.IRW": (0x7E5120, 0x7E5C00, "Kintaro stomp strip TIGERJUMP4B (bottom of MK1WS1's guard)"),
    "MK1WS3.IRW": (0x7E5C00, 0x7E6000, "THE WARRIOR SHRINE (MK1) pack 3, PPP 6 (top of FLAPJACK's guard)"),
    "MK1WS2.IRW": (0x75BE00, 0x75F400, "THE WARRIOR SHRINE (MK1) pack 2 (top of HANGJOHD's guard)"),
    # THE THRONE ROOM (MK1) - MK1's court of Shang Tsung, stage record FFCB8080.
    # There is no .BDB/.BDD for it in the leak, so tools/make_mk1throne.py
    # decodes all 45 images (40 payloads - MK1 gives five pairs one SAG) out of
    # mk.zip and deals ~62KB across four FREE RUNS, because none holds it:
    #   1  the 23KB the retired JADMIL1 slot left in bank 0
    #   2  between MK1PT4's payload and MK1PSK1's base
    #   3  inside SCLAP's guard under MK1PT4, where THE PIT's packs already sit
    #   4  above SHAOSIT's payload
    # Nothing is pulled back: every one is space no IRW had claimed.  The slots
    # are also PACKS in that tool - move them together.
    # Ends of 1 and 2 pulled back on 2026-10-05 (0x797400 -> 0x796C00 and
    # 0xBFC200 -> 0xBFBB00) for THRCHP2/THRCHP3, the empty throne's strips.
    # PACKS keeps the old ends on purpose: its deal fills to 90% of them and a
    # smaller number would re-deal the stage.  This overlap check is what stops
    # either pack growing into a strip.
    "MK1TR1.IRW": (0x791A00, 0x796C00, "THE THRONE ROOM (MK1) pack 1 (retired JADMIL1 run)"),
    "MK1TR2.IRW": (0xBF7400, 0xBFBB00, "THE THRONE ROOM (MK1) pack 2 (MK1PT4 .. MK1PSK1)"),
    "MK1TR3.IRW": (0xBF2000, 0xBF61D0, "THE THRONE ROOM (MK1) pack 3 (SCLAP's guard under MK1PT4)"),
    # End pulled back 0x755600 -> 0x754000 on 2026-10-04 for XRAY5 - and in
    # tools/make_mk1throne.py PACKS, which the deal is checked against.
    "MK1TR4.IRW": (0x751A00, 0x754000, "THE THRONE ROOM (MK1) pack 4 (above SHAOSIT)"),
    # GORO'S LAIR's glowing eyes: CAVEYE1-6 out of data/CAVEYES.IMG, the six
    # one-pixel-tall slivers MK1 blinks in the dark archways.  12 bytes against
    # 512, and the payload is FROZEN - these six records are MK1's, transcribed
    # by tools/make_caveyes_img.py from C:\MAME\roms\mk.zip, not art that is
    # going to grow.
    #
    # BANK 1, with the rest of the stage: MK1CAVE's own wall blocks live in
    # MK7MIL.  Safe because nothing walks this art with the CPU - it is DMA
    # drawn off cave_eyes_lst, it casts no shadow (shad7's bank-select-free
    # read is the JADERANG rule) and it is not a movie frame.
    "CAVEYES.IRW": (0x9FFE00, 0xA00000, "Goro's Lair glowing eyes"),
}

# MAME ROM chip definitions (name, flat_offset, size)
MAME_ROMS = [
    # Group 1: flat offset 0x000000
    ("l1_mortal_kombat_ii_game_rom_ug14.ug14", 0x000000, 0x100000, 0),
    ("l1_mortal_kombat_ii_game_rom_uj14.uj14", 0x000000, 0x100000, 1),
    ("l1_mortal_kombat_ii_game_rom_ug19.ug19", 0x000000, 0x100000, 2),
    ("l1_mortal_kombat_ii_game_rom_uj19.uj19", 0x000000, 0x100000, 3),
    # Group 2: flat offset 0x400000
    ("l1_mortal_kombat_ii_game_rom_ug16.ug16", 0x400000, 0x100000, 0),
    ("l1_mortal_kombat_ii_game_rom_uj16.uj16", 0x400000, 0x100000, 1),
    ("l1_mortal_kombat_ii_game_rom_ug20.ug20", 0x400000, 0x100000, 2),
    ("l1_mortal_kombat_ii_game_rom_uj20.uj20", 0x400000, 0x100000, 3),
    # Group 3: flat offset 0x800000
    ("l1_mortal_kombat_ii_game_rom_ug17.ug17", 0x800000, 0x100000, 0),
    ("l1_mortal_kombat_ii_game_rom_uj17.uj17", 0x800000, 0x100000, 1),
    ("l1_mortal_kombat_ii_game_rom_ug22.ug22", 0x800000, 0x100000, 2),
    ("l1_mortal_kombat_ii_game_rom_uj22.uj22", 0x800000, 0x100000, 3),
]

VIDEO_CHIP_SIZE = 0x100000  # 1 MB per video chip

IRW_HEADER_SIZE = 68
IRW_RECORD_HEADER_SIZE = 24

def parse_irw(path):
    """Read an IRW file, return (base_addr, bank, pixel_data).

    Most LOAD2 IRWs are a single 68-byte header followed by one raw payload.
    Some /E builds can append additional IMAGE RAM records after the first
    payload.  Those continuation records have a compact 24-byte descriptor
    followed by more raw bytes.  The runtime tables address this as one packed
    stream, so makevrom must concatenate the payload chunks and strip the
    continuation descriptors.
    """
    data = path.read_bytes()
    base_addr = struct.unpack_from("<I", data, 44)[0]
    data_size = struct.unpack_from("<I", data, 48)[0]
    bank = struct.unpack_from("<I", data, 60)[0]
    chunks = []

    if data_size == 0 and path.name in FILE_BASE_OVERRIDE:
        return FILE_BASE_OVERRIDE[path.name], bank, data[IRW_HEADER_SIZE:]

    pos = IRW_HEADER_SIZE
    end = min(pos + data_size, len(data))
    chunks.append(data[pos:end])
    pos = end

    while pos < len(data):
        remaining = len(data) - pos
        if remaining >= IRW_RECORD_HEADER_SIZE:
            extra_size = struct.unpack_from("<I", data, pos + 4)[0]
            extra_start = pos + IRW_RECORD_HEADER_SIZE
            extra_end = extra_start + extra_size
            if extra_size > 0 and extra_end <= len(data):
                chunks.append(data[extra_start:extra_end])
                pos = extra_end
                continue

        # Keep any unexpected tail visible in the build output, but do not drop
        # bytes silently.  A bad parse here means missing sprites at runtime.
        print(f"  {path.name}: WARNING - keeping {remaining} unparsed trailing IRW bytes")
        chunks.append(data[pos:])
        break

    pixel_data = b"".join(chunks)
    return base_addr, bank, pixel_data


def image_byte_offset(base_addr, bank):
    """Convert a TMS image SAG to a byte offset within that bank window."""
    if bank == 1 and base_addr >= IROM_BANK1_HIGH_BASE:
        return (base_addr - IROM_BANK1_HIGH_BASE) // 8
    return (base_addr - IROM_BASE) // 8


def overlap_is_allowed(fname, other_name, start, end):
    window = ALLOWED_OVERLAP_WINDOWS.get(frozenset((fname, other_name)))
    if window is None:
        return False
    allowed_start, allowed_end = window
    return start >= allowed_start and end <= allowed_end


LOD_BASE_RE = re.compile(r"^\*\*\*>\s*([0-9a-fA-F]+)\s*(?:,\s*(\d+))?")
IMGBUILD_RE = re.compile(r"^\s*[^\s]*load2\s+(\S+)", re.IGNORECASE)


def check_lod_bases(script_dir, data_dir):
    """Reject two BUILT LOD files claiming the same bank/base address.

    The payload overlap check below only sees IRWs that LOAD2 actually
    produced AND that are listed in irw_files, so a sidecar can sit in data/
    for months quietly claiming an address another sidecar already owns. That
    is not a silent-corruption risk - it takes edits in three places to ship
    such a payload, and the overlap check then refuses to write chips - but it
    reads exactly like a live bug, which costs review time. Catch it at the
    declaration instead.

    Duplicates involving a LOD that IMGBUILD.BAT does not build are reported
    as notes, not errors: retiring a sidecar and handing its slot to the next
    one is a normal move (SHAOSIT inherited KGBLOOD's 0x5C00000 that way).
    """
    imgbuild = next((p for p in (data_dir / "IMGBUILD.BAT", script_dir / "IMGBUILD.BAT")
                     if p.exists()), None)
    if imgbuild is None:
        print("  NOTE: IMGBUILD.BAT not found; skipping LOD base check")
        return

    built = set()
    for line in imgbuild.read_text(errors="replace").splitlines():
        if line.lstrip().upper().startswith("REM"):
            continue
        m = IMGBUILD_RE.match(line)
        if m:
            built.add(m.group(1).upper())

    seen = {}
    errors, notes = [], []
    for lod in sorted(data_dir.glob("*.LOD")):
        name = lod.stem.upper()
        head = lod.read_text(errors="replace").splitlines()
        m = next((LOD_BASE_RE.match(l) for l in head[:8] if LOD_BASE_RE.match(l)), None)
        if not m:
            continue
        key = (int(m.group(2) or 0), int(m.group(1), 16))
        prev = seen.get(key)
        if prev is None:
            seen[key] = name
            continue
        pair = sorted((prev, name))
        desc = f"{pair[0]} and {pair[1]} both declare bank {key[0]} base 0x{key[1]:07X}"
        if prev in built and name in built:
            errors.append(desc)
        else:
            unbuilt = [n for n in pair if n not in built]
            notes.append(f"{desc} (not built: {', '.join(unbuilt)})")
        if name in built:
            seen[key] = name

    for note in notes:
        print(f"  NOTE: {note}")
    if errors:
        print("\nERROR: two built LOD files claim the same video ROM address.")
        for msg in errors:
            print(f"  - {msg}")
        print("Give one of them a new slot in CUSTOM_VIDEO_SLOTS before building.")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Build MK2 video ROMs from IRW files")
    parser.add_argument("--debug-bin", action="store_true",
                        help="Also write raw header-stripped .bin files for MAME "
                             "debugger `loadr` (equivalent to `dd bs=0x44 skip=1`)")
    parser.add_argument("--data-dir", type=Path,
                        help="Optional directory containing IRW inputs; defaults to ./data")
    args = parser.parse_args()

    script_dir = Path(__file__).parent.resolve()
    data_dir = args.data_dir.resolve() if args.data_dir else script_dir / "data"
    if not data_dir.exists():
        print(f"ERROR: IRW data directory not found: {data_dir}")
        sys.exit(1)

    check_lod_bases(script_dir, data_dir)

    rom_dir = script_dir / "rom"
    rom_dir.mkdir(exist_ok=True)
    debug_dir = rom_dir / "debug"
    if args.debug_bin:
        debug_dir.mkdir(exist_ok=True)

    # IRW files to process (in order).
    # MK8MIL.IRW targets program ROM area, embedded by makerom.py instead.
    # Source-built custom wrappers are written after the stock MIL payloads.
    irw_files = [
        "MK2MIL.IRW", "MK3MIL.IRW", "MK4MIL.IRW", "MK5MIL.IRW",
        "MK6MIL.IRW", "MK7MIL.IRW", "MOVEART2.IRW", "MOVEART1.IRW", "SHAOSIT.IRW",
        "SCLAP.IRW", "KITSPIN.IRW",
        "GOROWALK.IRW", "FLAPJACK.IRW", "JADERANG.IRW", "JADVIC.IRW",
        "TIMEFLR.IRW",
        
        "MK1SKULL.IRW", 
        "MKSOUL1.IRW", "SZSPINE.IRW", "JXAIRPRO.IRW",
        "BOSSHAM.IRW",
        "HAMGLOW.IRW",
        "STATREF.IRW",
        "SKGLOW.IRW",
        "RAINBOLT.IRW",
        "JDROD.IRW",
        "RAINCLD.IRW",
        "NOOBPRJ.IRW",
        "NOOBRING.IRW",
        "RNVIC7.IRW",
        
        "MTOPFLR.IRW",
        "ERMACSLM.IRW",
        "RAIN.IRW",
        "SAHELI.IRW",
        "HICLOUD.IRW",
        "ERMFIRE.IRW",
        "ROBOFIRE.IRW",
        "MTNSKUL.IRW",
        "CAVEYES.IRW",
        "BLDXPD.IRW",
        "SMTIGER.IRW",
        "TWRJNT.IRW",
        "ARNSKY.IRW",
        "JCAIRKIK.IRW",
        "JCFKICK.IRW",
        "JCLOGO.IRW",
        "MK3CV1.IRW", "MK3CV2.IRW", "MK3CV3.IRW", "MK3CV4.IRW",
        "CAVEFLR.IRW",
        "MK1PT1.IRW", "MK1PT2.IRW", "MK1PT3.IRW", "MK1PT4.IRW",
        "MK1PSK1.IRW", "MK1PSK2.IRW", "MK1PSK3.IRW", "MK1PSK4.IRW", "MK1PSK5.IRW",
        "MK1PFLY.IRW",
        "MK1WS1.IRW", "MK1WS2.IRW", "MK1WS3.IRW",
        "MK1TR1.IRW", "MK1TR2.IRW", "MK1TR3.IRW", "MK1TR4.IRW",
        "MK1TRSH.IRW", "MK1TRS2.IRW",
        "THRCHP1.IRW", "THRCHP2.IRW", "THRCHP3.IRW",
        "SHASLAM.IRW",
        "HANGTONY.IRW", "HANGTNYD.IRW",
        "HANGJOHN.IRW", "HANGJOHD.IRW",
        "HANGGEO.IRW", "HANGGEOD.IRW",
        "HANGMARK.IRW", "HANGJEFF.IRW", "HANGSTEV.IRW", "HANGSAL.IRW", "HANGERIC.IRW",
        "SKSOUL1.IRW", "SKSOUL2.IRW", "SKSOUL3.IRW", "SKSOUL4.IRW", "SKSOUL5.IRW",
        "ERBOX.IRW",
        "TIGJMP1.IRW", "TIGJMP2.IRW", "TIGJMP3.IRW", "TIGJMP4.IRW", "TIGJMP5.IRW", "TIGJMP6.IRW",
        "JDBOX.IRW",
        "RNBOX.IRW",
        "LKDKNEE2.IRW", "LKDKNEE3.IRW",
        "STELBO1.IRW",
        "PILREFD.IRW",
        "LUBUZZ.IRW",
        "XRAY1.IRW", "XRAY2.IRW", "XRAY3.IRW", "XRAY4.IRW",
        "XRAY5.IRW", "XRAY6.IRW", "XRAY7.IRW", "XRAY8.IRW", "XRAY9.IRW",
        "SMROPE.IRW",
        "SLICEHAT.IRW",
        "BLDSPLSH.IRW",
        "KTSOULB.IRW",
        "DISCOB1.IRW", "DISCOB2.IRW",
        # "UMK3FIRE.IRW",  <- staged, see the slot comment above.  IMGBUILD.BAT
        # builds it every run so the IRW and src/UMK3FIRE.TBL keep tracking the
        # IMG while the art is re-cut, but it is not written into the ROM until
        # its payload fits the 36,864-byte slot (currently 140,160).
    ]

    # Wolf-only packs (see WOLF_HI_BASE).  Never written into the T-unit chips.
    wolf_irw_files = [
        # THE COURTYARD (MK1) - tools/make_mk1court.py PACKS / MONK_PACK
        "MK1CY1.IRW", "MK1CYM.IRW",
        # PALACE GATES (MK1) - tools/make_mk1gates.py PACKS / SPR_PACK
        "MK1GT1.IRW", "MK1GTM.IRW",
        # SCORPION'S LAIR (UMK3) - tools/make_umk3lair.py PACKS / SPR_PACK / FLOOR_PACK
        "LAIR1.IRW", "LAIRM.IRW", "LAIRFL.IRW", "LAIRRX.IRW",
        # JADE'S DESERT (UMK3) - tools/make_umk3desert.py PACKS / SPR_PACK / FLOOR_PACK,
        # the first art in the u110-u113 block (linear 0x1400000)
        "DSRT1.IRW", "DSRTM.IRW", "DSRTFL.IRW",
        # THE SOUL CHAMBER (UMK3) - tools/make_umk3stages.py, linear 0x1440000-0x1478000
        "USC1.IRW", "USCM.IRW", "USCFL.IRW",
        # THE PIT 3 (UMK3) - tools/make_umk3stages.py, linear 0x1500000-0x1560000
        "UP31.IRW",
        # ...and Shao Kahn on its throne - tools/make_pit3kahn.py, linear 0x1568000-0x1580000
        "UP3KN.IRW",
        # NOOB'S DORFEN (UMK3) - tools/make_umk3stages.py, linear 0x1590000-0x15BA000
        "UNW1.IRW", "UNWFL.IRW",
        # MK3 NIGHTWOLF - tools/make_nightwolf.py, linear 0x1600000-0x16D8000
        "NWOLFA.IRW", "NWOLFB.IRW", "NWOLFC.IRW",
        # ...and his select screen (box wipe, ladder mug, name plate), linear 0x16D8000
        "NWSEL.IRW",
        # MK3 ROBOT SMOKE - tools/make_robosmoke.py, linear 0x16E2000-0x1780000
        "RSMOKA.IRW", "RSMOKB.IRW",
        # ...and his select screen (box wipe, ladder mug), linear 0x1780000
        "RSSEL.IRW",
        # MK3 SONYA (Shang morph) - tools/make_umk3sonya.py, linear 0xC88000
        "UMK3SNY.IRW",
        # her fatality art (MK3 SBFIRE/SKELFIRE), linear 0xD30000
        "UMK3SNF.IRW",
        # Wolf-only name plates (Sindel), linear 0xD50000
        "WOLFHUD.IRW",
        # Shang -> Sindel select-box wipe (SNBOX8..1), linear 0xD58000
        "SNBOX.IRW",
        # Scorpion's Lair arches as a raw texture, for the heat haze, linear 0xD60000
        "LAIRWALL.IRW",
        # UMK3 SINDEL - tools/make_umk3sindel.py, linear 0xD6A000 / 0xDC8000
        "UMK3SDA.IRW", "UMK3SDB.IRW",
        # the flesh rip, every fighter - tools/make_fleshrip.py, linear 0xE58000
        "FLRIPA.IRW",
        # MK1 KANO (Shang morph) + the morph frames - tools/make_mk1kano_port.py, linear 0xEB4000
        "MK1KNO.IRW",
        # attract story (ATRAX1-4) + bio (STORY1) + ending (MKSTORY1/2) backgrounds - tools/make_wolf_story.py, linear 0xF60000 (above MK1KNO)
        "WSTORY.IRW",
        # attract profile portraits (UPPROF.IMG) - tools/make_upprof.py, linear 0xF91000
        "UPPROF.IRW",
    ]

    # Build flat video ROM image from the same generated IRW payloads that the
    # promoted SAG tables point at.  Do not seed from a retail baseline here:
    # table and payload drift must be fixed at the source, not hidden in
    # packaging.
    video_rom = bytearray(b'\xff' * VIDEO_SIZE)
    written_ranges = []
    overlap_errors = []

    for fname in irw_files:
        path = data_dir / fname
        if not path.exists():
            print(f"Warning: {fname} not found, skipping")
            continue

        base_addr, bank, pixel_data = parse_irw(path)

        # Per-IRW raw bin for MAME loadr (header stripped, no interleave)
        if args.debug_bin:
            bin_name = path.stem.lower() + ".bin"
            (debug_dir / bin_name).write_bytes(pixel_data)

        # Bank assignment: prefer header field if valid (0 or 1), else use filename map.
        # LOAD2 without /E writes bank=0xFFFF; we fall back to FILE_BANK in that case.
        if bank not in BANK_OFFSETS:
            bank = FILE_BANK.get(fname, 0)
        byte_offset = image_byte_offset(base_addr, bank)
        linear_offset = BANK_OFFSETS[bank] + byte_offset

        end = linear_offset + len(pixel_data)
        if end > VIDEO_SIZE:
            print(f"  {fname}: WARNING - data exceeds video ROM! truncating")
            pixel_data = pixel_data[:VIDEO_SIZE - linear_offset]
            end = VIDEO_SIZE

        slot = CUSTOM_VIDEO_SLOTS.get(fname)
        if slot is not None:
            slot_start, slot_end, purpose = slot
            if linear_offset != slot_start:
                msg = (
                    f"{fname} base drifted for {purpose}: "
                    f"expected 0x{slot_start:06x}, got 0x{linear_offset:06x}"
                )
                print(f"  {fname}: ERROR - {msg}")
                overlap_errors.append(msg)
            if end > slot_end:
                msg = (
                    f"{fname} overflows {purpose}: "
                    f"ends 0x{end:06x}, slot ends 0x{slot_end:06x}"
                )
                print(f"  {fname}: ERROR - {msg}")
                overlap_errors.append(msg)

        for other_name, other_start, other_end in written_ranges:
            if linear_offset < other_end and end > other_start:
                if overlap_is_allowed(fname, other_name, linear_offset, end):
                    continue
                msg = (
                    f"{fname} overlaps {other_name} "
                    f"at 0x{max(linear_offset, other_start):06x}-0x{min(end, other_end):06x}"
                )
                print(f"  {fname}: ERROR - {msg}")
                overlap_errors.append(msg)
        written_ranges.append((fname, linear_offset, end))

        video_rom[linear_offset:linear_offset + len(pixel_data)] = pixel_data
        print(f"  {fname:16s} bank={bank} addr=0x{base_addr:08x} -> offset 0x{linear_offset:06x} size={len(pixel_data):8d}")

    # Wolf-only region, 12-32 MB: its own buffer, its own overlap check
    wolf_hi = bytearray(b'\xff' * WOLF_HI_SIZE)
    wolf_ranges = []
    for fname in wolf_irw_files:
        path = data_dir / fname
        if not path.exists():
            overlap_errors.append(f"Wolf pack {fname} not found (run build.py)")
            continue
        base_addr, _bank, pixel_data = parse_irw(path)
        bank = 1                                   # every Wolf pack is bank 1
        if base_addr < 0x4000000:
            overlap_errors.append(f"Wolf pack {fname}: LOD base 0x{base_addr:08x} is below "
                                  "4000000,1 (12 MB) - that is the T-unit's video ROM")
            continue
        linear_offset = 0x800000 + (base_addr - 0x2000000) // 8 + WOLF_RELOCATE.get(fname, 0)
        end = linear_offset + len(pixel_data)
        block = next((b for b in WOLF_MAME_BLOCKS + WOLF_EXTRA_BLOCKS
                      if b[0] <= linear_offset and end <= b[1]), None)
        if block is None:
            overlap_errors.append(f"Wolf pack {fname} at 0x{linear_offset:07x}-0x{end:07x} is not inside "
                                  "one Wolf video block (0xC00000-0xFFFFFF, 0x1000000-0x13FFFFF, "
                                  "0x1400000-0x17FFFFF or 0x1800000-0x1FFFFFF)")
            continue
        # wolf_ranges is (name, start, end); WOLF_RESERVED is (start, end, what)
        for other, a, b in wolf_ranges + [(w, a, b) for a, b, w in WOLF_RESERVED]:
            if linear_offset < b and end > a:
                overlap_errors.append(f"Wolf pack {fname} overlaps {other}")
        wolf_ranges.append((fname, linear_offset, end))
        wolf_hi[linear_offset - WOLF_HI_BASE:end - WOLF_HI_BASE] = pixel_data
        print(f"  {fname:16s} WOLF bank={bank} addr=0x{base_addr:08x} -> offset 0x{linear_offset:07x} "
              f"({block[2]}) size={len(pixel_data):8d}")

    if overlap_errors:
        print("\nERROR: video ROM payload overlaps detected; refusing to write chips.")
        for msg in overlap_errors:
            print(f"  - {msg}")
        sys.exit(1)

    wolf_out = Path(__file__).resolve().parent / "rom" / "wolf_video_hi.bin"
    if wolf_ranges:
        wolf_out.parent.mkdir(exist_ok=True)
        wolf_out.write_bytes(wolf_hi)
        print(f"\nWolf-only video: {len(wolf_ranges)} pack(s) -> {wolf_out.name} (makewolf.py ships it)")
    elif wolf_out.exists():
        wolf_out.unlink()        # no Wolf packs: makewolf.py keeps the donor's chips

    # Extract 4-way interleaved ROM chips
    print(f"\nVideo ROM: {VIDEO_SIZE:,d} bytes ({VIDEO_SIZE // 1024 // 1024} MB)")
    print(f"\nGenerating 12 MAME video ROM chips:")

    for rom_name, group_offset, chip_size, lane in MAME_ROMS:
        chip_data = bytearray(chip_size)
        for i in range(chip_size):
            flat_idx = group_offset + i * 4 + lane
            if flat_idx < VIDEO_SIZE:
                chip_data[i] = video_rom[flat_idx]

        out_path = rom_dir / rom_name
        out_path.write_bytes(chip_data)
        # Count non-0xFF bytes to see how much actual data
        used = sum(1 for b in chip_data if b != 0xFF)
        pct = used * 100 // chip_size if chip_size > 0 else 0
        print(f"  {rom_name:52s} {chip_size:8d} bytes  ({pct}% used)")

    # Per-chip capacity validation
    print(f"\n  Video chip capacity ({len(MAME_ROMS)} chips ? {VIDEO_CHIP_SIZE // 1024} KB):")
    all_ok = True
    for rom_name, _group_offset, chip_size, _lane in MAME_ROMS:
        out_path = rom_dir / rom_name
        if out_path.exists():
            sz = out_path.stat().st_size
            status = "OK" if sz <= chip_size else "OVERFLOW"
            marker = "  " if sz <= chip_size else "!!"
            pct = sz / chip_size * 100
            print(f"  {marker} {rom_name:52s} {sz:>8,d} / {chip_size:>8,d}  ({pct:5.1f}%)  {status}")
            if sz > chip_size:
                all_ok = False
    if all_ok:
        print(f"  PASS ? video ROMs fit T-Unit chip capacity")
    else:
        print(f"  FAIL ? video ROMs exceed T-Unit capacity. Reduce sprite data or split across more chips.")

    print(f"\nVideo ROM chips written to: {rom_dir}")

    if args.debug_bin:
        # Also write flat 12MB video ROM for loadr at video region base
        flat_path = debug_dir / "video_flat.bin"
        flat_path.write_bytes(video_rom)

        print(f"\nDebug bins written to: {debug_dir}")
        print(f"  Per-IRW raw bins (header stripped):")
        for fname in irw_files:
            bin_name = Path(fname).stem.lower() + ".bin"
            if (debug_dir / bin_name).exists():
                sz = (debug_dir / bin_name).stat().st_size
                print(f"    {bin_name:20s} {sz:>10,d} bytes")
        print(f"  Flat video ROM (all IRWs combined):")
        print(f"    video_flat.bin       {len(video_rom):>10,d} bytes")
        print()
        print("MAME debug usage (press ~ or use -debug flag):")
        print("  loadr rom/debug/mk2mil.bin,0,0,:video   # load single IRW at video base")
        print("  loadr rom/debug/video_flat.bin,0,0,:video  # load full flat video ROM")
        print("  Format: loadr <file>,<length|0=all>,<offset>,<region_tag>")

    print("\nDone.")


if __name__ == "__main__":
    main()
