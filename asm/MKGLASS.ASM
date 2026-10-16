**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
*											     *
*  module: mkglass.asm --- THE SCREEN CRACKS				     *
*											     *
*  Shao Kahn's hammer smash ends with the beaten man driven face-first     *
*  into the front of the screen (r_kahn_hammer_smash, MKBOSS.ASM: he	     *
*  grows to 2x on the way at the camera and PITFALL6 is the frame he	     *
*  arrives on).  This is what the glass does about it - a chip where he    *
*  landed, radial cracks running out of it, and two irregular webs of	     *
*  concentric cracks joining the radials where they kink.		     *
*											     *
*  IT IS DRAWN BY THE CPU, not blitted.  geo_seg / geo_pass (MKDISP.ASM)  *
*  is the line pass the hit boxes and Raiden's bolts use, and a crack is   *
*  exactly what it is good at: no art, no video-ROM space (bank 0 has      *
*  none left), no palette, and the shape can be rolled fresh every time.   *
*  Needs `geoline .set 1' in MKDISP.ASM, the same as the box overlay.	     *
*											     *
*  THE SHAPE IS ROLLED ONCE AND THEN HELD.  Every other producer on this   *
*  path re-rolls its geometry per frame because it is drawing something    *
*  that moves - the portal arc crackles, the bolt writhes.  A crack does   *
*  the opposite: it appears and then it is STILL.  So the segments are     *
*  built into gc_seg at the impact and the process only re-POSTS them,     *
*  because geo_pass consumes its list every frame and a producer that	     *
*  stops posting vanishes.						     *
*											     *
*  IT IS IN FRONT OF EVERYTHING, and that is the point rather than a	     *
*  limitation: geo_pass runs at dsa9, after every object and the score     *
*  area are queued, so the crack sits over the body, over Kahn, over the   *
*  HUD and over SHAO KAHN WINS / FATALITY.  The glass is in front of the   *
*  whole picture.  (geo_layer would put it under the HUD instead, at the   *
*  cost of a `.long -1,geo_layer' in every display list it could happen    *
*  on, and GEO_LMAX is 32 segments - not enough for this.)		     *
*											     *
*  A SEGMENT THAT LEAVES THE PAGE IS DROPPED WHOLE, not clipped	     *
*  (geo_onpage, MKDISP.ASM) - so a ray that ran off the top would not be   *
*  shortened, the whole ray would go missing.  Hence gcb_fit: each ray's   *
*  length is shortened until its TIP is inside the margin box, which keeps *
*  the ray straight and just stops it at the edge.  Clamping the points    *
*  instead bends the crack along the border, which reads as a frame, not   *
*  as glass.								     *
*											     *
*  ITS OWN OBJECT because MKBOSS.ASM is 280KB and GSPA's ceiling tracks    *
*  symbols and content (MOVES.ASM and BGND.ASM have both hit it).  So the  *
*  hook in r_kahn_hammer_smash is a `calla', and glasscrk / pid_glass live *
*  in MAINEQU.ASM - a .set does not cross objects.			     *
*											     *
**************************************************************************
	.file	"mkglass.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.if	glasscrk
	.globl	glass_crack_start	; MKBOSS.ASM r_kahn_hammer_smash
	.globl	glass_crack_pass	; MKDISP.ASM dsa9, beside box_pass
	.ref	geo_seg			; MKDISP.ASM - needs geoline .set 1.
					; MAINEQU .global's everything else this
					; uses (mpart_bounds, blood_randu /
					; blood_srand, gstate); the geometry pass
					; is declared per module, as BGND.ASM
					; does for the portal arc
	.endif

	.text

	.if	glasscrk

*
*  The web.  Every one of these is a knob - see doc/KAHN_HAMMER_GLASS.md
*  for what each one costs, because the budget here is FRAME TIME, not
*  segments: geo_line plots one PIXT per pixel with interrupts off, after
*  waiting for the whole dma queue to drain, and this finisher is already
*  handing the blitter a body drawn at 2x.  The count below is
*    chip 4 + rays 3*GC_RAYS + webs 2*GC_RAYS = 59
*  and about 2,100 pixels a frame.  GEO_MAX is 192 and nothing else is
*  producing during a fatality, so the LIST is not the limit; the pixels
*  are.  Measure (peak_overload, geo_full) before raising GC_RAYS or
*  GC_RMAX.
*
GC_RAYS		.set	11	; radial cracks.  ODD on purpose - an even
				;   count reads as a wheel, not a break
GC_RMIN		.set	78	; shortest ray, pixels
GC_RMAX		.set	136	; longest.  Rolled per ray, so the web is
				;   ragged rather than round
GC_F1		.set	87	; first kink, fraction of the ray * 256
GC_F2		.set	174	; second kink
GC_KINK		.set	8	; how far a kink moves off the straight line
GC_CHIP		.set	5	; the impact chip's radius
GC_MARGIN	.set	6	; keep every tip this far inside the page
GC_EDGE		.set	46	; ... and the impact point this far in, so a
				;   ray can never be shortened below GC_RMIN/2
				;   and still be off page
GC_STAGES	.set	6	; ticks the crack takes to finish spreading
GC_MAX		.set	64	; segments the shape can hold
*
*  Colours are boonpal pens (colour map 0 in the high half, which is what a
*  zero there means - see geo_pass).  The radials are white and the webs a
*  shade warmer, so the two read as different orders of crack instead of
*  one flat lattice.
*
GC_COL_RAY	.set	00000000eh	; bpal_white
GC_COL_WEB	.set	000000009h	; bpal_toast, #FFFFCE
*
*  How long it stays up, in drawn frames.  From the impact the finisher
*  runs ~96 ticks of hold plus ~150 of slide, and then the announcements
*  finish - so this is deliberately longer than the whole thing.  The
*  gstate test in glass_crack_pass is the real bound.
*
gc_life		.set	600

	.bss	gc_live,16		; a crack is up (see glass_crack_pass)
	.bss	gc_tick,16		; drawn frames since it appeared
	.bss	gc_ctr,32		; the impact point, packed y:x (screen)
	.bss	gc_vtx,GC_RAYS*3*32	; P1,P2,P3 per ray, packed y:x
	.bss	gc_chip_pts,4*32	; the impact chip's four corners
	.bss	gc_seg,GC_MAX*3*32	; [colour, start, delta] - geo_seg's own
					;   record, so posting is a copy
	.bss	gc_n,16			; segments built
	.bss	gc_sn,16		; stages marked so far
	.bss	gc_stage,GC_STAGES*16	; segments alive at tick 0,1,2...

;************************************************************************
;  glass_crack_start - break the screen over the man who just hit it.
;
;  in:  a8 = the victim's object (multipart, already scaled and placed)
;  Preserves everything.  Takes no process and no object: it rolls the
;  shape and raises gc_live, and the display pass does the rest.
;************************************************************************
glass_crack_start
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	callr	gc_point
	callr	gc_build
	clr	a0
	move	a0,@gc_tick,w
	movk	1,a0
	move	a0,@gc_live,w
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	rets

;************************************************************************
;  gc_point - where he hit the glass, in SCREEN coordinates.
;
;  in:  a8 = his object.  out: gc_ctr.  a0-a6 destroyed.
;
;  Measured off the art rather than off his anchor: at 2x, and lying in a
;  PITFALL pose, oypos is nowhere near the part of him that is touching
;  the screen.  mpart_bounds gives the drawn extent of every piece in one
;  walk, so the middle of that across and a third of the way down it is
;  his face - which is what went through.
;
;  Those are WORLD numbers (kahn_smash_trim takes the camera off oypos the
;  same way).  The camera is frozen for the whole finisher - stop_scrolling
;  plus f_noscrolly, back in r_kahn_hammer_smash - so a screen point taken
;  once stays put, which is exactly what a crack in the glass needs.
;************************************************************************
gc_point
	calla	mpart_bounds		; a0=top a1=bottom a2=left a3=right
	add	a3,a2
	sra	1,a2			; a2 = the middle of him, across
	move	a1,a4
	sub	a0,a4			; a4 = his drawn height
	move	a4,a5
	sll	2,a5
	add	a4,a5			; h*5 ...
	sra	4,a5			; ... /16, a bit under a third down
	add	a0,a5			; a5 = the impact, world y

	move	@worldtlx,a6,l		; -> screen.  SRA, not SRL: worldtl*
	sra	16,a6			;   are signed 16.16 and go negative
	sub	a6,a2
	move	@worldtly,a6,l
	sra	16,a6
	sub	a6,a5
*
*  Hold it GC_EDGE inside the page.  gcb_fit shortens a ray until its tip
*  fits and its floor is GC_RMIN/2, so the impact point has to be at least
*  that far in - otherwise a ray could reach the floor and still be off
*  page, and the segment would be dropped rather than drawn short.
*
	movi	GC_EDGE,a0
	cmp	a0,a2
	jrge	gcpt_x0
	move	a0,a2
gcpt_x0
	movi	scrrgt-GC_EDGE,a0
	cmp	a0,a2
	jrle	gcpt_x1
	move	a0,a2
gcpt_x1
	movi	GC_EDGE,a0
	cmp	a0,a5
	jrge	gcpt_y0
	move	a0,a5
gcpt_y0
	movi	scrbot-GC_EDGE,a0
	cmp	a0,a5
	jrle	gcpt_y1
	move	a0,a5
gcpt_y1
	move	a5,a0			; pack it, y in the high half
	sll	16,a0
	movx	a2,a0
	move	a0,@gc_ctr,l
	rets

;************************************************************************
;  gc_build - roll the whole shape into gc_seg, once.
;
;  Everything random here comes from @blood_rand (blood_randu /
;  blood_srand, UTIL.ASM), the stream that exists for exactly this: it is
;  cosmetic, and netplay's gameplay RNG must not move because a crack was
;  drawn.  Same rule the blood and the forceball follow.
;
;  THE ORDER THE SEGMENTS ARE BUILT IN IS THE ORDER THEY APPEAR.  The
;  process posts the first N of the list, N growing a stage a tick, so the
;  build order IS the animation: the chip, the radials shooting out, the
;  inner web filling in behind them, then the outer half of the radials
;  and the outer web.  gc_mark records N at each of those moments.
;
;  Preserves everything.
;************************************************************************
gc_build
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	clr	a0
	move	a0,@gc_n,w
	move	a0,@gc_sn,w

*
*  --- the rays' vertices -------------------------------------------------
*
*  gc_dirs is a hand-authored ring of unit vectors * 256.  The angles are
*  deliberately UNEVEN: glass breaks where it is weakest, not every 32
*  degrees, and an even spread is the one thing that makes this read as a
*  drawn star instead of a break.
*
	movi	gc_dirs,a6
	movi	gc_vtx,a4
	movi	GC_RAYS,a11
gcb_ray
	move	*a6+,a8,w
	sext	a8,0			; a8 = dx, unit * 256
	move	*a6+,a9,w
	sext	a9,0			; a9 = dy
	movi	GC_RMAX-GC_RMIN,a0
	calla	blood_randu
	addi	GC_RMIN,a0
	move	a0,a10			; a10 = this ray's length
*
*  Shorten it until the TIP is inside the margin box.  See the header: an
*  off-page segment is dropped whole, so this is the difference between a
*  ray that stops at the edge of the screen and a ray that is not there.
*
gcb_fit
	move	a8,a3
	mpys	a10,a3			; ODD Rd - the 32-bit product lands in
	sra	8,a3			;   a3 alone (as kahn_smash_trim does)
	move	a9,a5
	mpys	a10,a5
	sra	8,a5
	move	@gc_ctr,a0,l
	move	a0,a1
	sll	16,a1
	sra	16,a1
	add	a1,a3			; a3 = tip x
	sra	16,a0
	add	a0,a5			; a5 = tip y
	movi	GC_MARGIN,a0
	cmp	a0,a3
	jrlt	gcb_short
	movi	scrrgt-GC_MARGIN,a0
	cmp	a0,a3
	jrgt	gcb_short
	movi	GC_MARGIN,a0
	cmp	a0,a5
	jrlt	gcb_short
	movi	scrbot-GC_MARGIN,a0
	cmp	a0,a5
	jrle	gcb_fitted
gcb_short
	move	a10,a0
	sra	2,a0
	sub	a0,a10			; a quarter off, and try again
	cmpi	GC_RMIN/2,a10
	jrgt	gcb_fit
	movi	GC_RMIN/2,a10
gcb_fitted
	movi	GC_KINK,a0
	calla	blood_srand		; signed - either side of straight
	move	a0,a1
	movi	GC_F1,a0
	callr	gc_vertex
	move	a0,*a4+,l		; P1

	movi	GC_KINK,a0
	calla	blood_srand
	move	a0,a1
	movi	GC_F2,a0
	callr	gc_vertex
	move	a0,*a4+,l		; P2

	movi	GC_KINK/2,a0		; the tip barely wanders - a crack runs
	calla	blood_srand		;   out of energy, it does not swerve
	move	a0,a1
	movi	256,a0
	callr	gc_vertex
	move	a0,*a4+,l		; P3

	dsj	a11,gcb_ray

*
*  --- and the segments, in the order they appear -------------------------
*
	callr	gc_core
	callr	gc_mark			; tick 0 - the chip on its own

	movi	-1,a5			; from the impact point ...
	clr	a6			; ... to P1
	movi	GC_COL_RAY,a7
	callr	gc_ray_pass
	callr	gc_mark			; tick 1 - the radials are away

	clr	a5
	movi	GC_COL_WEB,a7
	callr	gc_web_pass
	callr	gc_mark			; tick 2 - the inner web catches up

	clr	a5
	movk	1,a6
	movi	GC_COL_RAY,a7
	callr	gc_ray_pass
	callr	gc_mark			; tick 3

	movk	1,a5
	movk	2,a6
	callr	gc_ray_pass
	callr	gc_mark			; tick 4 - the radials reach their end

	movk	1,a5
	movi	GC_COL_WEB,a7
	callr	gc_web_pass
	callr	gc_mark			; tick 5 - the outer web closes it

	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	rets

;************************************************************************
;  gc_vertex - one point along a ray.
;
;  in:  a8 = dx unit, a9 = dy unit (both * 256), a10 = the ray's length
;       a0 = how far along, fraction * 256
;       a1 = how far off the straight line, signed pixels
;  out: a0 = the point, packed y:x.  Everything else preserved.
;
;  The perpendicular of (dx,dy) is (-dy,dx), so a kink moves along that and
;  the ray keeps its direction.
;************************************************************************
gc_vertex
	mmtm	sp,a1,a2,a3,a5,a7
	move	a10,a3
	mpys	a0,a3
	sra	8,a3			; a3 = distance along the ray
	move	a8,a5
	mpys	a3,a5
	sra	8,a5			; a5 = x, along
	move	a9,a7
	mpys	a3,a7
	sra	8,a7			; a7 = y, along
	move	a9,a3
	mpys	a1,a3
	sra	8,a3
	sub	a3,a5			; ... - dy*j, the perpendicular
	move	a8,a3
	mpys	a1,a3
	sra	8,a3
	add	a3,a7			; ... + dx*j
	move	@gc_ctr,a0,l
	move	a0,a2
	sll	16,a2
	sra	16,a2			; a2 = the impact point, x
	sra	16,a0			; a0 = ... and y
	add	a2,a5
	add	a0,a7
	callr	gc_clamp
	move	a7,a0
	sll	16,a0
	movx	a5,a0
	mmfm	sp,a1,a2,a3,a5,a7
	rets

;************************************************************************
;  gc_clamp - a5 = x, a7 = y, onto the page.  a1 destroyed.
;
;  Belt and braces to gcb_fit's length fitting: the kinks move a point off
;  the ray by up to GC_KINK, so a tip that fitted exactly could still put
;  an interior vertex over the edge and lose that segment.
;************************************************************************
gc_clamp
	clr	a1
	cmp	a1,a5
	jrge	gcc_x0
	move	a1,a5
gcc_x0
	movi	scrrgt,a1
	cmp	a1,a5
	jrle	gcc_x1
	move	a1,a5
gcc_x1
	clr	a1
	cmp	a1,a7
	jrge	gcc_y0
	move	a1,a7
gcc_y0
	movi	scrbot,a1
	cmp	a1,a7
	jrle	gcc_y1
	move	a1,a7
gcc_y1
	rets

;************************************************************************
;  gc_core - the impact chip: four short segments round the point itself,
;  at four of the ray angles and at uneven radii, so it is a shard rather
;  than a diamond.  Preserves everything.
;************************************************************************
gc_core
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	movi	gc_dirs,a6
	movi	gc_chip_pts,a4
	movk	4,a11
gcc_pt
	move	*a6+,a8,w
	sext	a8,0
	move	*a6+,a9,w
	sext	a9,0
	addi	64,a6			; every third direction - two entries
	movi	GC_CHIP,a0		;   of two words each
	calla	blood_randu
	addi	GC_CHIP,a0
	move	a0,a10
	movi	256,a0
	clr	a1
	callr	gc_vertex
	move	a0,*a4+,l
	dsj	a11,gcc_pt

	movk	4,a11
	clr	a3			; a3 = corner index
gcc_join
	move	a3,a0
	sll	5,a0
	addi	gc_chip_pts,a0
	move	*a0,a0,l		; this corner ...
	move	a3,a1
	inc	a1
	andi	3,a1
	sll	5,a1
	addi	gc_chip_pts,a1
	move	*a1,a1,l		; ... and the next, wrapping
	movi	GC_COL_RAY,a2
	callr	gc_put
	inc	a3
	dsj	a11,gcc_join
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	rets

;************************************************************************
;  gc_ray_pass - one segment per ray, from vertex slot a5 to slot a6, in
;  colour a7.  Slot -1 is the impact point itself.  Preserves everything.
;************************************************************************
gc_ray_pass
	mmtm	sp,a0,a1,a2,a3,a4,a11
	clr	a4
	movi	GC_RAYS,a11
gcrp_lp
	move	a5,a0
	callr	gc_vget
	move	a0,a3
	move	a6,a0
	callr	gc_vget
	move	a0,a1
	move	a3,a0
	move	a7,a2
	callr	gc_put
	inc	a4
	dsj	a11,gcrp_lp
	mmfm	sp,a0,a1,a2,a3,a4,a11
	rets

;************************************************************************
;  gc_web_pass - the concentric cracks: a chord between each ray and the
;  next at vertex slot a5, in colour a7.  Preserves everything.
;
;  It joins the rays AT THEIR KINKS, which is why the web comes out
;  irregular for free - every ray is a different length, so the slot sits
;  at a different radius on each one.  A web drawn at a fixed radius is a
;  polygon, and reads as one.
;************************************************************************
gc_web_pass
	mmtm	sp,a0,a1,a2,a3,a4,a6,a11
	clr	a4
	movi	GC_RAYS,a11
gcwp_lp
	move	a5,a0
	callr	gc_vget
	move	a0,a3
	move	a4,a6
	inc	a4
	cmpi	GC_RAYS,a4
	jrlo	gcwp_next
	clr	a4			; back round to ray 0
gcwp_next
	move	a5,a0
	callr	gc_vget
	move	a0,a1
	move	a6,a4
	move	a3,a0
	move	a7,a2
	callr	gc_put
	inc	a4
	dsj	a11,gcwp_lp
	mmfm	sp,a0,a1,a2,a3,a4,a6,a11
	rets

;************************************************************************
;  gc_vget - a4 = ray index, a0 = vertex slot (0-2, or -1 for the impact
;  point).  Returns the point in a0; preserves everything else.
;************************************************************************
gc_vget
	move	a0,a0
	jrn	gcv_ctr
	mmtm	sp,a1,a2
	move	a4,a1
	move	a1,a2
	sll	1,a2
	add	a2,a1			; ray * 3 ...
	add	a0,a1			; ... + slot
	sll	5,a1			; ... * 32 bits
	addi	gc_vtx,a1
	move	*a1,a0,l
	mmfm	sp,a1,a2
	rets
gcv_ctr
	move	@gc_ctr,a0,l
	rets

;************************************************************************
;  gc_put - append one segment to gc_seg.
;
;  in: a0 = start packed y:x, a1 = end packed y:x, a2 = colour long
;  Preserves everything.  Drops the segment if the list is full, for the
;  same reason geo_seg does: gc_seg is DATA and a producer must not be
;  able to run off the end of it.
;************************************************************************
gc_put
	mmtm	sp,a0,a1,a2,a3,a4,a5
	move	@gc_n,a3,w
	cmpi	GC_MAX,a3
	jrhs	gcpu_x
	move	a3,a4
	sll	6,a4			; * 64 ...
	move	a3,a5
	sll	5,a5			; ... + * 32 = one [colour,xy,dydx]
	add	a5,a4
	addi	gc_seg,a4
	move	a2,*a4+,l		; colour
	move	a0,*a4+,l		; start
	subxy	a0,a1			; SUBXY does both halves at once
	move	a1,*a4,l		; delta
	inc	a3
	move	a3,@gc_n,w
gcpu_x
	mmfm	sp,a0,a1,a2,a3,a4,a5
	rets

;************************************************************************
;  gc_mark - remember how much of the crack exists at this stage.
;  Preserves everything.
;************************************************************************
gc_mark
	mmtm	sp,a0,a1,a2
	move	@gc_sn,a0,w
	cmpi	GC_STAGES,a0
	jrhs	gcm_x
	move	a0,a1
	sll	4,a1
	addi	gc_stage,a1
	move	@gc_n,a2,w
	move	a2,*a1,w
	inc	a0
	move	a0,@gc_sn,w
gcm_x
	mmfm	sp,a0,a1,a2
	rets

;************************************************************************
;  glass_crack_pass - post the crack, once per DRAWN FRAME.
;
;  Called from dsa9 (MKDISP.ASM) right beside box_pass, and that placement
;  is the whole point rather than a detail.  geo_pass consumes geo_list and
;  zeroes its count, so a producer that stops posting vanishes - and A
;  PROCESS DOES NOT POST OFTEN ENOUGH.  The first cut of this ran the post
;  from its own process on `sleep 1' and the crack came out on EVERY OTHER
;  FRAME: 70 captured frames of the finisher alternated hard between the
;  whole web and none of it, ~2,650 near-white pixels against ~1,590 (which
;  is the victim's own highlights, i.e. nothing).  It is not a cost problem
;  and it does not look like a cost problem - a frame that runs out of time
;  loses the pass at random, and this was a clean 2-frame square wave.
;
;  box_pass is the shape to copy: the hit-box overlay is the other thing in
;  this game that holds still for many frames, and it produces from inside
;  the display pass for exactly this reason.  Doing the same makes "every
;  frame" true by construction instead of by scheduling luck, and it costs
;  a process and a pid less than the version that did not work.
;
;  MUST COME BEFORE geo_pass in dsa9 - it APPENDS at geo_count, and
;  geo_pass is what consumes and clears the list.  Same contract as
;  box_pass, and the comment there says so.
;
;  THE GSTATE TEST IS THE REAL LIFETIME; gc_life is only a backstop.  The
;  moment the game is neither fighting nor counting the bonus - the next
;  match, the continue screen, attract - the glass is whole again.
;
;  Preserves everything.  Runs in the display interrupt, so it touches no
;  B-file register and calls nothing that sleeps.
;************************************************************************
glass_crack_pass
	mmtm	sp,a0,a1,a2,a3,a4,a5
	move	@gc_live,a0,w
	jrz	gcx_x

	move	@gstate,a0,w
	cmpi	gs_fighting,a0
	jreq	gcx_draw
	cmpi	gs_bonus,a0
	jreq	gcx_draw
	clr	a0
	move	a0,@gc_live,w		; the scene moved on - the glass is whole
	jruc	gcx_x

gcx_draw
	move	@gc_tick,a0,w		; how much of it exists yet
	cmpi	GC_STAGES-1,a0
	jrls	gcx_stage
	movi	GC_STAGES-1,a0		; finished spreading - all of it
gcx_stage
	sll	4,a0
	addi	gc_stage,a0
	move	*a0,a5,w		; a5 = segments alive this frame
	jrz	gcx_age
	movi	gc_seg,a4
gcx_lp
	move	*a4+,a2,l		; colour
	move	*a4+,a0,l		; start
	move	*a4+,a1,l		; delta
	calla	geo_seg			; preserves everything, so the walk can
	dsj	a5,gcx_lp		;   keep a4/a5 across it

gcx_age
	move	@gc_tick,a0,w
	inc	a0
	move	a0,@gc_tick,w
	cmpi	gc_life,a0
	jrlo	gcx_x
	clr	a0
	move	a0,@gc_live,w		; backstop reached
gcx_x
	mmfm	sp,a0,a1,a2,a3,a4,a5
	rets

*
*  gc_dirs - the ring of radial directions, unit * 256, y DOWN.  Uneven on
*  purpose (see gcb_ray).  Angles: 8, 41, 70, 104, 133, 160, 196, 225,
*  252, 288, 318 degrees.  gc_core walks it in THREES for the chip, which
*  is why 11 and 3 being coprime matters - it picks four different angles.
*
gc_dirs
	.word	253,36
	.word	193,168
	.word	88,241
	.word	-62,248
	.word	-175,187
	.word	-241,88
	.word	-246,-71
	.word	-181,-181
	.word	-79,-243
	.word	79,-243
	.word	190,-171

	.endif
