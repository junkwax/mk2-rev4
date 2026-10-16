**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
*											     *
*  module: mk3cave.asm  --- THE CAVE (curback 019h)				     *
*											     *
*  MK3's unshipped cave stage.  data/MK3CAVE.BDB/.BDD came out of the	     *
*  UMK3 art tree and nothing in MK3, UMK3 or Trilogy ever loaded them,	     *
*  so there was no Midway layout to port - the planes, rates and rows	     *
*  are ours, authored in tools/make_mk3cave.py (LAYOUT) and emitted into    *
*  src/MK3CAVBG.ASM as equates next to the tables they place.  Change a     *
*  number THERE and rerun --apply; `--preview` renders the screen from      *
*  the same constants.							     *
*											     *
*  Back to front:							     *
*    baklst4  mk3cave4  the far chamber, seen through the dip in the cavern *
*    baklst3  mk3cave3  the cavern - wall, skull pile, outcrop, the water    *
*    baklst5  mk3cave2  three columns standing in the water		     *
*    floor    FL_CAVE   UMK3 Kahn's Kave floor, CAVEFL_P, skewed off plane 2 *
*    baklst2  mk3cave1  stalagmite silhouettes along the floor's back edge  *
*										     *
*  THE LAYOUT IS MEASURED OFF MIDWAY'S EARLY MK3 BUILD (the "Cavern" footage,*
*  YouTube Jw84UTSXzdU - see tools/make_mk3cave.py and the doc): rates far   *
*  08000h, cavern 10000h, columns 18000h, floor edge 1C000h, camera 0..800.  *
*									     *
*  The stalagmites ride plane 2, and the floor is skewed off scrollx2 so   *
*  that ROW mk3c_kanc - not row 0 - tracks plane 2 exactly		     *
*  (mk3cave_skew_calla).  Every row is rate/128 faster than the one above, *
*  so that is the row whose painted shadows stay under their spikes at	     *
*  every camera; the footage puts the strip at floor row 4-6's speed.	     *
*									     *
*  Its own object, not part of BGND.ASM: that file is 8,424 lines and GSPA  *
*  runs out of memory near 8,673.  BGND.ASM only lists mk3cave_mod in	     *
*  table_o_mods.								     *
*										     *
*  All eight bak?mods are written - three as skip_bakmod - because a plane *
*  past the list's end keeps the PREVIOUS stage's module and multi_plane   *
*  goes on filling its list with those blocks.				     *
*										     *
*  The water ripples: mk3cave_water, below, redraws the cavern's water	     *
*  band a scanline at a time over the plain blocks.			     *
*											     *
**************************************************************************
	.file	"mk3cave.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	mk3cavbg.asm		; GENERATED - tools/make_mk3cave.py

cavewater	.set	1		; 0 = the water stands still, as it was

	.globl	mk3cave_mod		; BGND.ASM table_o_mods, entry 019h
	.globl	setup_floor_info	; BGND.ASM
	.if	cavewater
	.globl	mk3cave_water
	.globl	dma_q			; MKDISP.ASM - the object queue's floor
	.globl	f_cwater,cw_fixdx,cw_ran,cw_short,cw_lines
	.endif
	.text

mk3cave_mod
	.word	mk3c_erase		; autoerase color
	.word	mk3c_ground		; ground y
	.word	mk3c_worldy		; initial world y
	.word	mk3c_start		; initial worldx

	.word	mk3c_left		; scroll left limit
	.word	mk3c_right		; scroll right limit

	.long	mk3cave_calla
	.long	mk3cave_scroll		; scroll table
	.long	dlists_mk3cave

	.long	bak1mods
	.long	skip_bakmod		; baklst1 = the fighters' plane, no art
	.long	MK3CAVE1BMOD		; baklst2 = stalagmites on the floor's edge
	.word	mk3c_m1_x,mk3c_m1_y
	.long	MK3CAVE3BMOD		; baklst3 = the cavern
	.word	mk3c_m3_x,mk3c_m3_y
	.long	MK3CAVE4BMOD		; baklst4 = the far chamber
	.word	mk3c_m4_x,mk3c_m4_y
	.long	MK3CAVE2BMOD		; baklst5 = columns in the water
	.word	mk3c_m2_x,mk3c_m2_y
	.long	skip_bakmod		; baklst6 \
	.long	skip_bakmod		; baklst7  > never inherit the last stage's
	.long	skip_bakmod		; baklst8 /  modules
	.long	0ffffffffh

mk3cave_scroll
	.long	mk3c_rate8		; 8
	.long	mk3c_rate7		; 7
	.long	mk3c_rate6		; 6
	.long	mk3c_rate5		; 5 - columns
	.long	mk3c_rate4		; 4 - far chamber
	.long	mk3c_rate3		; 3 - cavern
	.long	mk3c_rate2		; 2 - stalagmites + the floor's top row
	.long	mk3c_rate1		; 1 - players
	.long	0			; 0

dlists_mk3cave
	.long	baklst4,worldtlx4+16		; far chamber
	.long	baklst3,worldtlx3+16		; cavern
	.if	cavewater
	.long	-1,mk3cave_water		; its water again, a line at a time
	.endif
	.long	baklst5,worldtlx5+16		; columns
	.long	-1,floor_code
	.long	baklst2,worldtlx2+16		; stalagmites, over the floor's edge
	.long	-2				; shadows
	.long	ghost_lst,worldtlx+16		; fighter afterimages (ghost_rec)
	.long	objlst,worldtlx+16
	.long	objlst2,worldtlx+16
	.long	0

mk3cave_calla
	movi	mk3cave_floor_info,a0
	calla	setup_floor_info
	movk	2,a0			; fast compressed shadows; legacy raw pieces
	move	a0,@shad_fast,w		; see STAGE_SHADOW_SWEEP.md
	rets

mk3cave_floor_info
	.long	FL_CAVE			; sag
	.long	MK3C_FLOOR_P		; palette for floor
	.word	mk3c_skew_y		; skew y position
	.word	mk3c_skew_h		; height
	.long	scrollx2		; row mk3c_kanc moves with the stalagmites
	.long	mk3cave_skew_calla

*
* floor_code has just taken this frame's scroll (a9) off skew_oc and holds the
* result in a10; a line's skew is skew_oc + line * skew_dx.  Giving back
* mk3c_kanc * scroll/128 makes line mk3c_kanc - not line 0 - the one that
* moves with scrollx2.  a10 AND @skew_oc: the rows are drawn off the register.
* A shift-and-add (mk3c_kanc = 1<<s1 + 1<<s2), never mpys - its product lands
* in Rd+1.  a0 is free here: it held this routine's own address.
*
mk3cave_skew_calla
	move	@skew_dx,a11,l		; dx per line
	sra	7,a9
	sub	a9,a11			; adjust with scroll
	move	a11,@skew_dx,l
	move	a9,a0
	sll	mk3c_kanc_s1,a0
	add	a0,a10
	move	a9,a0
	sll	mk3c_kanc_s2,a0
	add	a0,a10
	move	a10,@skew_oc,l
	jauc	skew_rets


**************************************************************************
*											     *
*  mk3cave_water - the cavern's water, rippling a scanline at a time.	     *
*											     *
*  dlist:  .long  -1,mk3cave_water     straight after baklst3 (the cavern),  *
*          before baklst5, so the columns still stand IN the water.	     *
*											     *
*  KAHN'S ARENA's heat haze (sky_rows, MKDISP.ASM) bends a sky by drawing it *
*  one single-row blit per line from a raw texture.  Water has to move	     *
*  differently, and there is no room for a texture, so this one reads the   *
*  cavern's OWN blocks: every block on a water palette that crosses the	     *
*  band is a span, and a line is one blit per span on screen, a single row  *
*  of that block's ROM data.  A compressed block can start at any row	     *
*  because tools/make_mk3cave.py walked each row's bit offset out of the    *
*  pack IRWs (MK3C_WATR??, [offset, left skip]) and proved them against the *
*  art.  The control word is the header's, ORed with 8002h exactly as	     *
*  addblock builds a block's flags, plus dmaclp so the skip is obeyed.					     *
*											     *
*  Each line takes one byte of MK3C_WATWAVE, [dv:3 | dx:5]: it is drawn dx  *
*  pixels across and reads the row dv lines away (held inside its span), so *
*  the water both sways and shimmers.  The table is perspective water - the *
*  band's top row is the far bank, where the waves are small and close	     *
*  together - and is computed by the tool, which renders the same numbers   *
*  as a GIF (--water-gif).  Lines are WORLD rows, so the ripple rides with  *
*  the water when the camera chases a jumper.				     *
*											     *
*  The plain blocks are still drawn underneath.  A line with no ripple is   *
*  not redrawn at all, a span whose palette is not loaded is left alone,    *
*  and when the queue gets down to mk3c_wat_resv cells the rest of the	     *
*  frame's lines are simply not queued - every one of those shows the	     *
*  water as it always was.  Nothing here can take the water away.	     *
*											     *
*  The skull pile shares the water's palette.  A row's left skip starts its *
*  blit right of the pile (the DMA's ofset low byte), wide enough for the   *
*  row a line may read and for dx, so no bone moves.			     *
*											     *
**************************************************************************
	.if	cavewater
CW_SPAN		.set	0a0h		; bits in a MK3C_WATSPANS record
CW_VIS		.set	48		; bits in a cw_vis entry: [span:32, pal:16]
CW_CELL		.set	192		; bits in a queue cell

	.bss	f_cwater,16		; 0 ripple | 1 off | 2 every line at cw_fixdx
					;   | 3 lines alternating +/-cw_fixdx (2 and
					;   3 are for rigs: dv 0, every line drawn)
	.bss	cw_fixdx,16		; signed pixels, modes 2 and 3
	.bss	cw_ran,16		; sentinel: frames that queued the water
	.bss	cw_short,16		; sentinel: frames the queue cut short
	.bss	cw_lines,16		; blits queued in the last frame
	.bss	cw_nvis,16
	.bss	cw_vis,mk3c_wat_nspan*CW_VIS
	.bss	cw_x0,16		; screen x of the cavern's column 0
	.bss	cw_y,16			; screen y of the current line
	.bss	cw_line,16
	.bss	cw_ph,16		; bit offset of this frame's step in a line
	.bss	cw_wrow,32		; the current line's wave steps

mk3cave_water
	mmtm	sp,a3,a4,a14		; a4 = [camera y : x] for every list after this
	clr	a0
	move	a0,@cw_lines,w
	move	@f_cwater,a0,w
	cmpi	1,a0
	jreq	cw_exit

* The spans that can reach the screen this frame, each with its live palette.
	move	@worldtlx3+16,a2,w
	sext	a2,w
	movi	mk3c_m3_x,a4
	sub	a2,a4
	move	a4,@cw_x0,w
	movi	MK3C_WATSPANS,a6
	movi	mk3c_wat_nspan,a7
	movi	cw_vis,a8
	clr	a10
cw_vis_lp
	move	*a6(060h),a12,w
	sext	a12,w
	add	a4,a12			; a12 = the block's screen x
	move	*a6,a0,l
	move	*a0,a13,w
	zext	a13,w			; its width
	add	a12,a13
	addi	mk3c_wat_dxmax,a13	; its right edge, swayed right
	jrle	cw_vis_nx		; off the left
	cmpi	400+mk3c_wat_dxmax,a12
	jrge	cw_vis_nx		; off the right
	move	*a6(040h),a0,l
	calla	findpal			; a0 = its pal word, Z = not loaded
	jrz	cw_vis_nx		; then that water stays as it is
	move	a6,*a8+,l
	move	a0,*a8+,w
	inc	a10
cw_vis_nx
	addi	CW_SPAN,a6
	dsj	a7,cw_vis_lp
	move	a10,@cw_nvis,w
	move	a10,a10
	jrz	cw_exit

	move	@tick,a0,w
	srl	mk3c_wat_tsh,a0
	andi	mk3c_wat_phmask,a0
	sll	3,a0
	move	a0,@cw_ph,w
	move	@worldtly+16,a0,w
	sext	a0,w
	movi	mk3c_m3_y+mk3c_wat_y0,a2
	sub	a0,a2
	move	a2,@cw_y,w		; screen y of line 0 = its world y - camera
	movi	MK3C_WATWAVE,a0
	move	a0,@cw_wrow,l
	clr	a0
	move	a0,@cw_line,w

cw_line_lp
	move	@cw_y,a14,w
	sext	a14,w			; a14 = this line's screen y
	cmpi	scrbot,a14
	jrhi	cw_line_nx		; unsigned: a line above the screen is huge
	move	@cw_wrow,a0,l
	move	@cw_ph,a2,w
	add	a2,a0
	movb	*a0,a0			; [dv:3 | dx:5], sign-extended
	move	a0,a11
	sra	5,a11			; a11 = dv
	sll	27,a0
	sra	27,a0
	move	a0,a10			; a10 = dx
	move	@f_cwater,a2,w
	jrz	cw_still
	clr	a11			; a rig's fixed offset, every line drawn
	move	@cw_fixdx,a10,w
	sext	a10,w
	cmpi	3,a2
	jrne	cw_spans
	btst	0,a14
	jreq	cw_spans
	neg	a10			; alternating: odd lines the other way
	jruc	cw_spans
cw_still
	move	a10,a0
	or	a11,a0
	jrz	cw_line_nx		; no ripple on this line: the blocks have it

cw_spans
	movi	cw_vis,a12
	move	@cw_nvis,a13,w
cw_span_lp
	move	*a12+,a4,l		; a4 = the span
	move	*a12+,a3,w
	zext	a3,w			; a3 = [0 : its pal]
	move	@cw_line,a6,w
	move	*a4(070h),a0,w
	sub	a0,a6			; a6 = this line's row in the span
	jrn	cw_span_nx
	move	*a4(080h),a0,w		; the span's rows
	cmp	a0,a6
	jrhs	cw_span_nx		; the line is not in this block
	add	a11,a6			; + dv, held inside the span
	jrnn	cw_r1
	clr	a6
cw_r1	cmp	a0,a6
	jrlo	cw_r2
	move	a0,a6
	dec	a6
cw_r2	sll	5,a6
	move	*a4(020h),a0,l
	add	a6,a0			; a0 -> [offset, left skip]
	move	*a0,a8,w
	zext	a8,w			; bits from the header's sag to the row
	move	*a0(010h),a9,w
	zext	a9,w			; left skip
	move	*a4,a0,l		; a0 = the header [w, h, sag, control]
	move	*a0,a6,w
	zext	a6,w			; a6 = width
	cmp	a6,a9
	jrhs	cw_span_nx		; skip = width: all skull pile, never redrawn
	move	*a0(020h),a7,l
	add	a7,a8			; a8 = sag of the row
	move	*a0(040h),a0,w
	ori	08042h,a0		; go, write non-zero - addblock's flags - and
					;   dmaclp, or the DMA ignores ofset's skip
	sll	16,a0
	move	@cw_x0,a7,w
	sext	a7,w
	move	*a4(060h),a2,w
	add	a2,a7
	add	a9,a7			; + the skip: with dmaclp, [y:x] is where the
					;   first DRAWN pixel lands
	add	a10,a7			; + dx
	or	a0,a9			; a9 = [control : left skip]
	ori	010000h,a6		; a6 = [1 : width]
	move	a14,a0
	sll	16,a0
	movx	a7,a0
	move	a0,a7
	addxy	a5,a7			; a7 = [y : x] + page
	move	a1,a0
	subi	dma_q,a0		; queue left below a1
	movi	mk3c_wat_resv*CW_CELL,a2
	cmp	a2,a0
	jrlo	cw_full
	movi	001000100h,a2		; 1:1
	mmtm	a1,a2,a3,a6,a7,a8,a9	; the row -> on the queue
	inc	b13
	move	@cw_lines,a0,w
	inc	a0
	move	a0,@cw_lines,w
cw_span_nx
	dsj	a13,cw_span_lp

cw_line_nx
	move	@cw_y,a0,w
	inc	a0
	move	a0,@cw_y,w
	move	@cw_wrow,a0,l
	addi	mk3c_wat_rowbits,a0
	move	a0,@cw_wrow,l
	move	@cw_line,a0,w
	inc	a0
	move	a0,@cw_line,w
	cmpi	mk3c_wat_lines,a0
	jrlo	cw_line_lp
	move	@cw_ran,a0,w
	inc	a0
	move	a0,@cw_ran,w
cw_exit
	mmfm	sp,a3,a4,a14
	rets

cw_full
	move	@cw_short,a0,w		; the rest of the lines keep their plain water
	inc	a0
	move	a0,@cw_short,w
	jruc	cw_exit
	.endif

	.end
