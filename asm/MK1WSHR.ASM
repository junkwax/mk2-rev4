**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
*											     *
*  module: mk1wshr.asm  --- THE WARRIOR SHRINE (MK1), curback 01Bh	     *
*											     *
*  MK1's statue gallery: Sub-Zero, Cage, Kano, Goro, Liu Kang, Raiden and   *
*  Sonya on their plinths between the pillars, a line of trees and a	     *
*  mountain behind, and the moon over it all.				     *
*											     *
*  Where it all comes from - read, not remembered - is in the header of     *
*  tools/make_mk1shrine.py.  In short:					     *
*    art       data/KUNGFU1.BDB/.BDD, MK1's own shrine background; the	     *
*              tool proves every build that its blocks, pixels and	     *
*              palettes are the ones MK1 rev 5.0 shipped (mk.zip)	     *
*    layout    MK1's stage record FFCB7160: erase colour, camera, limits,   *
*              module placements and scroll rates all read off it	     *
*    moon      MK1's calla FFCB8E40 is THE PIT's moon subroutine, word for  *
*              word - so it is MK1PTOP.ASM's mk1p_moon and THE PIT's own    *
*              PITMOON record, no art of its own			     *
*										     *
*  Change a number in tools/make_mk1shrine.py and rerun --apply; the	     *
*  tool's --preview renders the screen from the same constants.	     *
*										     *
*  wshrpar 0 is MK1's shrine as MK1 drew it - back to front:		     *
*    mk1p_sky_lst  the moon, m_noscroll (THE PIT's list: one stage at a     *
*                  time owns it, and each stage's calla zeroes it)	     *
*    baklst3       the mountain - rate 0, it never scrolls sideways	     *
*    baklst2       the trees - half the fighters' speed		     *
*    baklst1       the shrine, the fighters' plane			     *
*										     *
*  wshrpar 1 adds depth: the statue row is pulled out onto its own plane,  *
*  slower than the fighters, so it slides behind the side gates:	     *
*    mk1p_sky_lst, baklst3, baklst2   as above				     *
*    baklst5       the floor, flat, at the fighters' speed - MK1's floor    *
*    baklst4       the statue row, slower than the fighters (mk1w_back_rate)*
*    baklst1       the side gates, at the fighters' speed		     *
*  The floor can spread toward the viewer too, MK2-style (wshr_floor,	     *
*  below) - FLOOR_BANDS in the tool, off since 2026-09-19 by choice.	     *
*										     *
*  Its own object for MK3CAVE.ASM's reason: BGND.ASM is near GSPA's	     *
*  out-of-memory point, and only lists mk1wshr_mod in table_o_mods.	     *
*										     *
**************************************************************************
	.file	"mk1wshr.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	mk1wshrb.asm		; GENERATED - tools/make_mk1shrine.py

wshrpar	.set	1		; 0 = MK1's shrine, every layer at MK1's own speed

	.globl	mk1wshr_mod		; BGND.ASM table_o_mods, entry 01Bh
	.globl	mk1p_moon		; MK1PTOP.ASM - MK1's moon subroutine
	.global	mk1p_sky_lst		; RAM.ASM's list block
	.if	wshrpar
	.if	mk1w_fbands
	.globl	dma_q			; MKDISP.ASM - the object queue's floor
	.globl	wf_lines,wf_short,wf_ran
	.endif
	.endif
	.text

mk1wshr_mod
	.word	mk1w_erase		; autoerase colour - MK1's night sky
	.word	mk1w_ground		; ground y
	.word	mk1w_worldy		; initial world y
	.word	mk1w_start		; initial worldx

	.word	mk1w_left		; scroll left limit
	.word	mk1w_right		; scroll right limit

	.long	mk1wshr_calla
	.long	mk1wshr_scroll		; scroll table
	.long	dlists_mk1wshr

	.long	bak1mods
	.if	wshrpar
	.long	WSFRONTBMOD		; baklst1 = the side gates
	.word	mk1w_mf_x,mk1w_mf_y
	.else
	.long	WOKWAY1BMOD		; baklst1 = the shrine
	.word	mk1w_m1_x,mk1w_m1_y
	.endif
	.long	WOKWAY2BMOD		; baklst2 = the trees
	.word	mk1w_m2_x,mk1w_m2_y
	.long	WOKWAY3BMOD		; baklst3 = the mountain
	.word	mk1w_m3_x,mk1w_m3_y
	.if	wshrpar
	.long	WSBACKBMOD		; baklst4 = the statue row
	.word	mk1w_mb_x,mk1w_mb_y
	.long	WSUNDERBMOD		; baklst5 = the floor, flat
	.word	mk1w_mu_x,mk1w_mu_y
	.else
	.long	skip_bakmod		; baklst4 \ never inherit the previous
	.long	skip_bakmod		; baklst5 / stage's modules
	.endif
	.long	skip_bakmod		; baklst6 \
	.long	skip_bakmod		; baklst7  > never inherit the previous
	.long	skip_bakmod		; baklst8 /  stage's modules
	.long	0ffffffffh

mk1wshr_scroll
	.long	0			; 8
	.long	0			; 7
	.long	0			; 6
	.if	wshrpar
	.long	mk1w_rate1		; 5 - the floor, with the fighters
	.long	mk1w_back_rate		; 4 - the statue row
	.else
	.long	0			; 5
	.long	0			; 4
	.endif
	.long	mk1w_rate3		; 3 - the mountain (0: MK1 parks it)
	.long	mk1w_rate2		; 2 - the trees
	.long	mk1w_rate1		; 1 - the shrine (gates), players
	.long	0			; 0

dlists_mk1wshr
	.long	mk1p_sky_lst,worldtlx8+16	; the moon (m_noscroll - x is unused)
	.long	baklst3,worldtlx3+16		; the mountain
	.long	baklst2,worldtlx2+16		; the trees
	.if	wshrpar
	.long	baklst5,worldtlx5+16		; the floor, flat, at the fighters'
						;   speed as MK1 has it (with bands on:
						;   the few end blocks under them)
	.if	mk1w_fbands
	.long	-1,wshr_floor			; the floor, in bands
	.endif
	.long	baklst4,worldtlx4+16		; the statue row, its plinths standing
						;   on the walkway
	.long	baklst1,worldtlx+16		; the side gates, over all of it
	.else
	.long	baklst1,worldtlx+16		; the shrine
	.endif
	.long	-2				; shadows
	.long	ghost_lst,worldtlx+16		; fighter afterimages (ghost_rec)
	.long	objlst,worldtlx+16
	.long	objlst2,worldtlx+16
	.long	0

mk1wshr_calla
	clr	a0
	move	a0,@mk1p_sky_lst,l	; the object pool is rebuilt between
					; stages - never inherit a list head, and
					; not even for the one tick before the moon
					; process first runs
	create	pid_bani,mk1p_moon	; pid_bani, not pid_fx: killfx sweeps every
					;   pid_fx process on a fatality
	movi	mk1w_shad_fast,a0	; fast compressed shadows, as every
	move	a0,@shad_fast,w		;   fightable stage - STAGE_SHADOW_SWEEP.md
*
* Clip the shadow to the walkway (see calla_battle, BGND.ASM, for why a
* high-thrown man's shadow climbs off the floor).  Measured on the rest frame,
* camera on the ceiling (worldtly = mk1w_worldy = 25): the plinths' stone
* base ends at screen 175 and the walkway runs from 176 to the bottom of
* the screen - world 201..278 against ground_y mk1w_ground (259): 58 rows
* above the line, 19 below.  A 234 px launch put rows 170-198 on screen;
* the six on the ledge are the ones this drops.
*
	movi	58,a0
	move	a0,@shad_hi,w		; ground_y-58 = the walkway's back edge
	movi	19,a0
	move	a0,@shad_lo,w		; ground_y+19 = the screen's last row
	.if	wshrpar
	.if	mk1w_fbands
	movi	WSFPALS,a8		; wshr_floor's palettes.  A background
wsc_pal	move	*a8+,a0,l		;   palette is only loaded while one of its
	jrz	wsc_done		;   blocks is on a display list, and the
	calla	getfpal			;   floor's blocks are not on one - so they
	jruc	wsc_pal			;   are loaded here, as setup_floor_info
wsc_done				;   loads a skewed floor's
	.endif
	.endif
	rets

	.if	wshrpar
	.if	mk1w_fbands		; tools/make_mk1shrine.py FLOOR_BANDS
**************************************************************************
*										     *
*  wshr_floor - the shrine's floor, spreading toward the viewer.	     *
*										     *
*  dlist:  .long  -1,wshr_floor    after baklst5 (the underlay), before     *
*          baklst4 (the statue row), whose plinth bases stand on it.	     *
*										     *
*  MK2's floors are one raw texture a scanline at a time (floor_code).	     *
*  This one would be ~62KB more video ROM and there is 10KB to spare, so   *
*  it redraws the floor's OWN blocks instead, the Cavern water's way: every *
*  block of the walkway, the deck and the two side walls is a span, and a   *
*  span is drawn as pieces - runs of its rows - read straight out of the    *
*  block's ROM data from the piece's first row (WSFR_??: bits from the	     *
*  header's sag to each row, walked out of the IRWs by the tool and proved  *
*  against the art).							     *
*										     *
*  Each piece belongs to a band, and a band is drawn from its own camera:   *
*  the fighters' camera plus F of the way to the statue row's (plane 4).    *
*  F is 1 for the top band, so the plinth bases stay planted on the	     *
*  walkway; 0 at the ground row, so the fighters' feet stay planted on the  *
*  deck; negative below it, so the rows nearest the viewer run fastest.     *
*  Both cameras are the REAL worldtlx the scroller left, so nothing here    *
*  can drift from them.  The deck and the side walls are in pieces of	     *
*  BAND_ROWS rows; the walkway, one featureless tile of dirt, is a whole    *
*  tile at the statue row's speed - shear cannot be seen in it, and that    *
*  halved the blits.							     *
*										     *
*  DMA TIME IS THE BUDGET, not the queue: a frame that starts with blits    *
*  still pending throws them away (init_dma_regs, dmaq_late), and the HUD   *
*  goes first.  The first cut of this - the whole floor drawn flat as well  *
*  as in bands, every band a piece of every span - ran 184-229 blits and    *
*  left 397-1,516 of 2,400 frames late.  So the underlay is only the few    *
*  end blocks the tool found ever showing through, and the rest is	     *
*  measured - see doc/MK1_WARRIOR_SHRINE.md.				     *
*										     *
*  A span whose palette is not loaded is skipped, and when the queue is     *
*  down to mk1w_fresv cells the rest of the frame is not queued (wf_short). *
*										     *
*  Registers as mk3cave_water: a1 is the queue, a5 the page, a4 [camera y : *
*  x] for every list after this (saved), b13 the queue count.		     *
*										     *
**************************************************************************
WF_SPAN		.set	0a0h		; bits in a WSFSPANS record
WF_VIS		.set	48		; bits in a wf_vis entry: [span:32, pal:16]
WF_CELL		.set	192		; bits in a queue cell
mk1w_fresv	.set	150		; queue cells left for everything after

	.bss	wf_lines,16		; blits queued in the last frame
	.bss	wf_short,16		; sentinel: frames the queue cut short
	.bss	wf_ran,16		; sentinel: frames that queued the floor
	.bss	wf_nvis,16
	.bss	wf_vis,mk1w_nspan*WF_VIS
	.bss	wf_bx,mk1w_nband*16	; every band's camera x, this frame
	.bss	wf_ty,16		; camera y
	.bss	wf_w,16			; the current span's width
	.bss	wf_sag,32		; ...its row 0
	.bss	wf_ctrl,32		; ...its [control : 0]

wshr_floor
	mmtm	sp,a3,a4,a14		; a4 = [camera y : x] for every list after this
	clr	a0
	move	a0,@wf_lines,w
	move	@worldtlx+16,a2,w
	sext	a2,w			; a2 = the fighters' camera x
	move	@worldtlx4+16,a3,w
	sext	a3,w
	sub	a2,a3			; a3 = the statue row's, less it
	move	@worldtly+16,a0,w
	sext	a0,w
	move	a0,@wf_ty,w

* Every band's camera: a2 plus F of the way to the statue row's.
	movi	WSFBANDS,a6
	movi	wf_bx,a7
	movi	mk1w_nband,a8
wfc_lp	move	*a6+,a11,l		; F, 16.16
	move	a3,a12
	mpys	a11,a12			; EVEN Rd: a12:a13 = a3 * F, the low
	sra	16,a13			;   half in a13 - the band's shift
	add	a2,a13
	move	a13,*a7+,w
	dsj	a8,wfc_lp

* The spans that can reach the screen this frame, each with its live palette.
	movi	WSFSPANS,a6
	movi	mk1w_nspan,a7
	movi	wf_vis,a8
	clr	a10
wfv_lp	move	*a6(080h),a12,w
	sext	a12,w
	sub	a2,a12			; screen x at the fighters' camera
	move	*a6,a0,l
	move	*a0,a13,w
	zext	a13,w			; its width
	add	a12,a13
	addi	mk1w_fmargin,a13
	jrle	wfv_nx			; off the left, however far its band runs
	cmpi	400+mk1w_fmargin,a12
	jrge	wfv_nx			; off the right
	move	*a6(020h),a0,l
	calla	findpal			; a0 = its pal word, Z = not loaded
	jrz	wfv_nx
	move	a6,*a8+,l
	move	a0,*a8+,w
	inc	a10
wfv_nx	addi	WF_SPAN,a6
	dsj	a7,wfv_lp
	move	a10,@wf_nvis,w
	move	a10,a10
	jrz	wf_exit

* Span by span, piece by piece.
	movi	wf_vis,a12
	move	@wf_nvis,a13,w
wfs_lp	move	*a12+,a4,l		; a4 = the span
	move	*a12+,a3,w
	zext	a3,w			; a3 = [0 : its pal]
	move	*a4,a9,l		; its header [w, h, sag, control]
	move	*a9,a0,w
	zext	a0,w
	move	a0,@wf_w,w
	move	*a9(020h),a0,l
	move	a0,@wf_sag,l
	move	*a9(040h),a9,w
	ori	08002h,a9		; go, write non-zero - addblock's flags
	move	*a4(090h),a0,w
	jrz	wfs1
	ori	dmahfl,a9		; mirrored
wfs1	sll	16,a9
	move	a9,@wf_ctrl,l
	move	*a4(060h),a10,l		; a10 -> its pieces
	move	*a10+,a11,w
	zext	a11,w			; a11 = how many
	jrz	wfs_nx

wfp_lp	move	*a10+,a7,w
	zext	a7,w			; a7 = the piece's first row in the block
	move	*a10+,a6,w
	zext	a6,w			; a6 = its rows
	move	*a10+,a14,w
	sext	a14,w			; its first world row
	move	*a10+,a8,w
	zext	a8,w			; its band
	move	@wf_ty,a0,w
	sext	a0,w
	sub	a0,a14			; a14 = screen y
	cmpi	scrbot,a14
	jrgt	wfp_nx			; below the screen
	move	a14,a0
	add	a6,a0
	jrle	wfp_nx			; above it
	sll	4,a8
	addi	wf_bx,a8
	move	*a8,a8,w
	sext	a8,w			; the band's camera
	move	*a4(080h),a0,w
	sext	a0,w
	sub	a8,a0			; a0 = screen x
	move	*a4(090h),a8,w
	jrz	wfp1
	move	@wf_w,a8,w
	zext	a8,w
	add	a8,a0			; mirrored: drawn back from its right edge,
	dec	a0			;   as the object path does it
wfp1	sll	16,a14
	movx	a0,a14			; a14 = [y : x]
	sll	5,a7
	move	*a4(040h),a8,l
	add	a7,a8
	move	*a8,a8,l		; bits from the sag to that row
	move	@wf_sag,a0,l
	add	a0,a8			; a8 = the row's sag
	sll	16,a6
	move	@wf_w,a0,w
	zext	a0,w
	or	a0,a6			; a6 = [rows : width]
	move	a14,a7
	addxy	a5,a7			; a7 = [y : x] + page
	move	@wf_ctrl,a9,l		; a9 = [control : 0]
	move	a1,a0
	subi	dma_q,a0		; queue left below a1
	movi	mk1w_fresv*WF_CELL,a2
	cmp	a2,a0
	jrlo	wf_full
	movi	001000100h,a2		; 1:1
	mmtm	a1,a2,a3,a6,a7,a8,a9	; the piece -> on the queue
	inc	b13
	move	@wf_lines,a0,w
	inc	a0
	move	a0,@wf_lines,w
wfp_nx	dsj	a11,wfp_lp
wfs_nx	dsj	a13,wfs_lp

	move	@wf_ran,a0,w
	inc	a0
	move	a0,@wf_ran,w
wf_exit
	mmfm	sp,a3,a4,a14
	rets

wf_full
	move	@wf_short,a0,w		; the rest of the frame is not queued
	inc	a0
	move	a0,@wf_short,w
	jruc	wf_exit
	.endif
	.endif

	.end
