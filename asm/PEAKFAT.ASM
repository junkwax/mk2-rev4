**************************************************************************
*                                                                        *
*  video game project:	Mortal Kombat 2                                   *
*                                                                        *
*  module: peakfat.asm --- YOTEIGAI TOR's stage fatality                 *
*                                                                        *
*  r_fall_off_mountain and everything it drives: the throw, the camera   *
*  ride down the mountain, the splash, the rising skull and the display  *
*  list he falls behind.  Moved out of BGND.ASM, which GSPA can no       *
*  longer assemble at its size - see src/TWRBACK.ASM and                 *
*  src/ARENAKIN.ASM, the two splits before this one.                     *
*                                                                        *
*  BGND.ASM keeps the STAGE (peak_mod, its scroller, the rain and        *
*  a_green_splash, which THE DEAD POOL uses too).  Only the fatality is  *
*  here.  peak_ground_y is in MAINEQU.ASM: both files need it and .set   *
*  equates do not cross an object boundary.                              *
*                                                                        *
**************************************************************************
	.file	"peakfat.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	imgtbl.glo
	.include	mtnskul.tbl		; the rising skull (data/MTNSKUL.LOD)

	.globl	r_fall_off_mountain	; MKREACT.ASM r_upcutted
	.globl	a_mtn_skull,fleshup1

;
;  Externals that MAINEQU.ASM does NOT already declare.  peak_rain_lst is not
;  here on purpose - MAINEQU.ASM:1935 globals it with the other list blocks.
;
	.ref	a_green_splash		; BGND.ASM - shared with THE DEAD POOL
	.ref	acidsplash1a		; BGND.ASM - the splash's first frame
	.ref	mtntop1_p		; IMGPAL7.ASM - this stage's splash colour
	.ref	peak_fill_lst,peak_front_lst	; RAM.ASM
	.ref	flash_layer		; MKDISP.ASM - only under srtflash+peakflash

	.text

;**********************************************************************
;*                                                                    *
;*  YOTEIGAI TOR's stage fatality - off the bridge, down the mountain  *
;*                                                                    *
;**********************************************************************
;
;  There is no cut.  The Pit II hands its victim to falling_down_the_pit
;  (MKFALL.ASM), which blanks the display, murders every other process and
;  rebuilds the screen out of four scaled quadrants of one PITFLOOR tile.
;  This stage does not need any of that, because mount1BMOD is 509x961 and
;  sits at world y 82: there are 796 rows of mountain BELOW the fighters'
;  feet and the bottom 22 of them are the blood-red sea at its foot.  So the
;  camera simply keeps chasing him down, the module streams its own blocks
;  in as it goes, and what the player sees is the mountain he was standing
;  on going past.
;
;  What IS borrowed from the Pit is the fall itself: the same -0c0000h
;  launch, the same 06000h gravity, the same 00fh animation.  Only the floor
;  moves - p_ganiy + peak_fall_drop instead of + 0400h - so the descent
;  takes ~103 ticks against the Pit's 118 and reads identically.
;
;  Geometry, all measured off MOUNTAIN.BDB/.BDD by tools/peak_sea_band.py,
;  which runs in Phase D so a re-cut of the mountain cannot move the sea out
;  from under the fatality without failing the build.
;
peak_sea_y	.equ	1021		; the waterline, world y.  Flat to within
					; 5 rows across the span, so one number
					; is honest here
peak_sea_lft	.equ	395		; the sea's extent, in PLANE 3's world x,
peak_sea_rgt	.equ	792		; not the fighting plane's - baklst3 runs
					; at a quarter of the deck's rate, so the
					; conversion has to be done live
;peak_sea_cx	.equ	593		; the sea's middle, and how near is near
;peak_sea_slop	.equ	24		; enough.  The steer stopped aiming at the
					; middle, so nothing references these now.
					; Left as text because the rig and
					; tools/peak_sea_band.py read them here
peak_throw_vel	.equ	020000h		; the uppercut's own drift, 2px a tick -
					; the FASTEST he is thrown
peak_throw_min	.equ	04000h		; ...and the slowest, 1/4 px a tick, so a
					; man with no water left ahead of him still
					; drifts away off the hit instead of going
					; straight up
peak_sea_margin	.equ	88		; how far inside the water's near edge he
					; must land - the only thing asked now.
					;
					; It measures the BODY, and the splash
					; that lineup_1pwm puts on him draws about
					; 43px further out, so this has to carry
					; the splash's own width as well as a
					; margin.  At 48 the body landed legally
					; and the splash sat 5px inside the
					; waterline with its left half on the rock
					; (victim x 200 right, sea starting at
					; screen 70, splash at 75).  72 was still
					; 6px short there - peak_mtn_arc is an
					; estimate and lands within ~11px, so the
					; margin carries that too
peak_mtn_arc	.equ	208		; how far sideways the whole fall carries
					; him at peak_throw_vel.  -0c0000h against
					; 06000h of gravity is 32 ticks and 192px
					; of rise, then 192+peak_fall_drop = 960px
					; down at 0.375 px a tick a tick = 72
					; ticks: ~104 ticks at 2px each
peak_skull_mid	.equ	20		; the skull's middle off its oxpos -
					; fleshup7 is 41 wide
peak_mod_wx	.equ	304		; mount1's placement, plane-3 world
peak_mod_wy	.equ	82		;   (tools/peak_sea_band.py MODULE_WORLD_X/Y)
peak_hole_w	.equ	91		; mount1's bottom-left hole - peak_dress_bottom
peak_splash_lip	.equ	24		; how far inside the sea's edge the splash's
					; left edge has to sit
peak_skull_drift .equ	04000h		; 1/4 px a tick - half THE DEAD POOL
					; skeleton's 08000h (r_fall_in_slime), at
					; the user's call: slower out
peak_fall_drop	.equ	peak_sea_y-peak_ground_y+12
					; feet to 12px UNDER the waterline - he
					; goes in, he does not land on it
peak_sea_bot	.equ	1042		; mount1's LAST row, world y
peak_art_bot	.equ	1040		; the last row any of its blocks PAINTS -
					; the water blocks stop 2 rows short of the
					; module, which left 2 rows of sky along the
					; bottom of the screen
peak_fall_cam_y	.equ	peak_art_bot-scrbot
					; the camera's floor - past this the module
					; is out of blocks and the autoerase colour
					; shows as a black band
peak_skull_y	.equ	peak_sea_y-3	; the rise straddles the waterline - where
					; the FIRST frame sits (anig1 migrates it
					; 8 rows up as they play).  At -17 it was
					; entirely in the air.  Measured, see doc
peak_body_anioff .equ	139		; a fighter's anipoint sits this far above
					; his feet.  Measured off the live object
					; (oypos 126, peak_ground_y 265) - NOT the
					; ~115 the floor-anchor arithmetic uses
peak_behind_y	.equ	peak_ground_y-peak_body_anioff+24
					; when he goes behind the bridge: 24px past
					; standing height, where his feet start
					; entering the deck.  Testing his ANIPOINT
					; against the ground line is 115px too late
peak_settle_vel	.equ	040000h		; 4px a tick, to close the last rows onto
					; peak_fall_cam_y after he has stopped
;
;  peak_water_bounds - where the water is, in the screen the player sees.
;
;  Sea on plane 3, body on plane 1, so a fixed world x is right at exactly one
;  camera position and wrong at the rest.  Screen space is the only space they
;  share.  Clipped to the SCREEN too - the sea runs off both sides at most
;  cameras (measured -20..377 of a 0..399 screen), and he has to come down on
;  water the player can actually see.
;
;  r_fall_off_mountain sizes the THROW with it.
;
;  returns: a0 = left bound, a1 = right bound, screen x.  clobbers a2
;
peak_water_bounds
	move	@worldtlx3+16,a2,w
	movi	peak_sea_lft,a0
	sub	a2,a0
	jrnn	pwb1
	clr	a0			; the sea runs off the left of the screen
pwb1	addi	peak_sea_margin,a0	; a0 = left bound

	movi	peak_sea_rgt,a1
	sub	a2,a1
	cmpi	scrrgt,a1
	jrle	pwb2
	movi	scrrgt,a1		; ...and off the right
pwb2	subi	peak_sea_margin,a1	; a1 = right bound
	rets

;
;  mtn_fall_behind - flight_call's every-tick hook.  ONE job: the display list
;  swap below, so he falls BEHIND the bridge.
;
;  It used to be mtn_steer_to_sea and also caught a body heading off the
;  water, leaning him back in mid-air.  However gently that was ramped it was
;  still something invisible turning the body round, and it read as him
;  bouncing off the side of the screen.  He now keeps the line the uppercut
;  gave him for the whole fall, as THE PIT (MK1) does - r_fall_off_mountain
;  picks the SPEED of that line so it ends in the water, and nothing touches
;  him after that.
;
mtn_fall_behind
	mmtm	sp,a0,a1
	move	*a8(oypos),a0,w
	cmpi	peak_behind_y,a0
	jrle	mfb9			; still standing height - leave the list
	movi	dlists_peak_fall,a1
	move	a1,@dlists,l		; See the list itself for why this is a
					;   dlist swap and not a z sort
mfb9	mmfm	sp,a0,a1
	rets

;
;  peak_fall_scroll - the scroller, for the length of the fall.
;
;  pit_scroll's chase without its two Pit-specific halves: no
;  bridge_list_fixed and no switch_camera_angle.  bak3mods has to stay LIVE or
;  the mountain stops streaming blocks the moment the camera leaves the deck.
;  Horizontal scrolling stops for the duration - a camera chasing him sideways
;  would drag the sea under him at a quarter of his own speed.
;
;  a11 = the falling object, passed in through pa11 by r_fall_off_mountain.
;
peak_fall_scroll
	calla	stop_scrolling		; calla, not callr - pit_scroll's own call is
					;   absolute too, and this sits far enough down
					;   BGND.OBJ that PC-relative is not safe
	clr	a0
	move	a0,@scrolly,l
;
;  The background updater streams blocks only every 8 ticks (background,
;  BGND.ASM) with a 48px pad round the screen.  Falling at up to ~27 rows a
;  tick the camera outruns that by ~200 rows, so blocks coming up from below
;  arrive late and show as straight-edged holes of sky in the mountain for a
;  few frames.  pit_scroll turns it up to every tick for the Pit II's fall and
;  mk1p_fall_scroll (MK1PTOP.ASM) does the same; this dropped it when it was
;  cut down from pit_scroll.  The round's rebuild creates a fresh updater, so
;  nothing has to put it back.
;
	clr	a1
	not	a1
	movi	pid_backg,a0
	calla	existp
	jrz	pfs1			; no updater ?  nothing to speed up
	movk	1,a1
	move	a1,*a0(pa10),l		; background updater = every tick

pfs1	sleep	1
;
;  Clamp FIRST - terminal velocity is ~27px a tick, so a test made after the
;  chase overshoots the last row of art by most of a screen of black.
;
	move	@worldtly,a1,l
	movi	peak_fall_cam_y*010000h,a2
	cmp	a2,a1
	jrlt	pfs2			; still above the floor
	move	a2,@worldtly,l		; pin it to the bottom of the mountain
	clr	a0
	move	a0,@scrolly,l
	jruc	pfs1

pfs2	move	*a11(oyvel),a6,l
	jrn	pfs3			; heading up ---> dont scroll y
	jrz	pfs_settle		; stopped falling - close the last rows

	move	*a11(oypos),a0,w
	move	@worldtly+16,a1,w
	sub	a1,a0
	cmpi	060h,a0
	jrlt	pfs3			; not far enough down the screen yet

	move	a6,@scrolly,l		; follow him down the mountain
	jruc	pfs1
;
;  A velocity chase stops where HE stops, leaving the waterline wherever he
;  came down (12 rows high on the first trial).  Close the last rows under our
;  own power.  Gated on how far down he is, not just oyvel - he is standing
;  still on the bridge before the uppercut too.
;
pfs_settle
	move	*a11(oypos),a0,w
	cmpi	peak_ground_y+200,a0
	jrlt	pfs3			; still up top
	movi	peak_settle_vel,a0
	move	a0,@scrolly,l
	jruc	pfs1

pfs3	clr	a0
	move	a0,@scrolly,l
	jruc	pfs1

;
;  r_fall_off_mountain - the victim's side, from r_upcutted's act_mtn_fall
;  test (MKREACT.ASM).  No reaction_start, following r_fall_in_slime rather
;  than r_fall_down_pit: he is already act_mtn_fall, flight owns his
;  animation, and nothing downstream reads act_reacting.
;
r_fall_off_mountain
	movi	pid_master,a0
	calla	existp
	jreq	rfom3			; a0 = master proc
	move	*a0(pwake),a1,l
	cmpi	fatality_waiting,a1	; still counting down the window ?
	jrne	rfom3
	movi	0100h,a2
	move	a2,*a0(pa11),l		; hold it open - this one is long

rfom3	clr	a0			; dlists_peak_fall walks these three as soon
	move	a0,@peak_skull_lst,l	;   as he drops behind the deck, and the
	move	a0,@peak_fill_lst,l	;   object pool is rebuilt between rounds -
	move	a0,@peak_front_lst,l	;   a stale head would be walked
;
;  NO nosounds here.  It was copied from r_fall_down_pit, which needs it
;  because it tears the whole screen down; this does not, and it cut off
;  both the death-blow chime (make_db_tone's 034h, a few ticks old) and the
;  uppercut's own hit sound - so the hit landed silent but for the scream.
;  THE DEAD POOL (r_fall_in_slime) never calls it and plays the same
;  monster-hit pair; this now does what it does.
;
	movk	1,a0
	calla	create_blood_proc
	movi	0001b001ch,a1
	calla	randsnd			; either of these monster hit sounds
	calla	disturbing_scream	; ahhh !!!
	movi	000060006h,a11
	calla	shake_a11		; shake upon contact
	sleep	1			; the tick nosounds used to take - keeps the fall's timing
;
;  Repell, hands off the fall.  It stays live through a stage fatality unless
;  told otherwise and disagrees three ways (repell_now, rep5/rep8, stuff_a6a7)
;  - it also dragged the WINNER 36px in his victory pose.  Measured; see doc.
;  disable_repell (MKDEATH.ASM) is the pattern; round_init_words zeroes it.
;
	movi	040h*40,a0
	move	a0,@f_norepell,w	; disable_repell (MKDEATH.ASM)
;
;  Take the camera before the floor moves, not after: flight snaps oypos
;  onto p_ganiy if he is already below it, and the scroller has to be
;  watching him by then.
;
	clr	a1
	not	a1
	movi	pid_scroll,a0
	calla	existp
	movi	peak_fall_scroll,a7
	calla	fastxfer		; scroller ---> ride him down
	move	a8,*a0(pa11),l		; pass my object

	move	*a13(p_ganiy),a0,w
	addi	peak_fall_drop,a0
	move	a0,*a13(p_ganiy),w	; floor = the sea, 756 rows down

;
;  The throw.  ALWAYS away from the winner - the uppercut's own direction, as
;  THE PIT (MK1) throws - and never corrected afterwards: he flies one straight
;  line from the hit to the water and the camera does not move sideways.
;
;  What is chosen is only the SPEED.  The fall takes ~104 ticks (32 up, 72
;  down - see peak_mtn_arc), so the water left ahead of him, in screen px,
;  times 640 is the 16.16 velocity that runs out just as he goes in
;  (65536/104 = 630; 640 is two shifts and ~2% long, inside the margin).
;  Capped at peak_throw_vel, floored at peak_throw_min.
;
;  This replaced a throw that could come back OVER the winner and a mid-air
;  catch that hauled him in from the edge.  Both kept him on the water and
;  both read as the body bouncing - a man flying TOWARDS whoever uppercut him
;  is the hit going the wrong way, and a man turned round in the air has hit
;  something that is not there.
;
	calla	is_he_right		; the same test away_x_vel makes, so the
					;   direction here cannot disagree with the
					;   one flight actually flies.  Read the
					;   carry IMMEDIATELY - it clobbers a3/a4
	jrc	pk_thr_left		; winner on his RIGHT ---> away is LEFT

	callr	peak_water_bounds	; a0 = left bound, a1 = right bound
	move	*a8(oxpos),a5,w
	move	@worldtlx+16,a2,w
	sub	a2,a5			; a5 = his screen x
	sub	a5,a1
	move	a1,a5			; a5 = water ahead of him, going right
	jruc	pk_thr_speed

pk_thr_left
	callr	peak_water_bounds
	move	*a8(oxpos),a5,w
	move	@worldtlx+16,a2,w
	sub	a2,a5
	sub	a0,a5			; a5 = water ahead of him, going left

pk_thr_speed
	cmpi	1,a5
	jrlt	pk_thr_slow		; none - he is already past it
	move	a5,a0
	sll	9,a0
	sll	7,a5
	add	a5,a0			; a0 = room * 640
	cmpi	peak_throw_vel,a0
	jrle	pk_thr_floor
	movi	peak_throw_vel,a0	; plenty of water - the uppercut's own 2px
pk_thr_floor
	cmpi	peak_throw_min,a0
	jrge	pk_thr_go
pk_thr_slow
	movi	peak_throw_min,a0
pk_thr_go
	movi	-0c0000h,a1		; a1 = initial y vel
	movi	06000h,a2		; a2 = gravity
	movk	5,a3			; a3 = ani speed
	movi	00fh,a9			; a9 = ani offset
	movi	mtn_fall_behind,a6	; ...and behind the bridge
	jsrp	flight_call
;
;  He is in.
;
	movi	000060006h,a11
	calla	shake_a11

	move	a8,a9
	movi	acidsplash1a,a5
	calla	gso_dmawnz
	movi	mtntop1_p,a0
	calla	swpal			; THE DEAD POOL's splash, this stage's
					;   colour - mtntop1_p's first 44 entries
					;   are apool_p re-hued in the same
					;   luminance order (IMGPAL7.ASM)
	move	a8,a0
	move	a9,a1
	calla	lineup_1pwm

;
;  The throw is never corrected, so a man with no water left ahead of him
;  comes down at its very edge, and the splash is wider than he is.  Slide
;  the SPLASH onto the water instead of the body: a few pixels at most.
;
	move	@worldtlx3+16,a2,w
	move	@worldtlx+16,a3,w
	sub	a3,a2			; a2 = plane 3 minus plane 1, screen terms
	movi	peak_sea_lft-peak_hole_w+peak_splash_lip,a0	; the fill is water too
	sub	a2,a0			; a0 = leftmost legal oxpos, plane-1 world
	move	*a8(oxpos),a1,w
	cmp	a0,a1
	jrge	pks_lft_ok
	move	a0,*a8(oxpos),w
	jruc	pks_ok
pks_lft_ok
	movi	peak_sea_rgt-peak_splash_lip,a0
	sub	a2,a0			; a0 = rightmost legal oxpos
	cmp	a0,a1
	jrle	pks_ok
	move	a0,*a8(oxpos),w
pks_ok
	movk	20,a0
	move	a0,*a8(ozpos),w		; splash in front of dude
	movi	peak_sea_y,a0
	move	a0,*a8(oypos),w		; on the waterline
	calla	insobja8
	create	pid_green_splash,mtn_splash_proc
	swap	a8,a9			; a8 = dude / a9 = splash
	callr	peak_dress_bottom	; fill the hole, rocks in front

	move	a8,a0
	calla	set_inviso		; and he is gone
	sleep	050h
;
;  The skull comes up - on peak_skull_lst, which dlists_peak_fall draws BEFORE
;  baklst3.  So the mountain plane, which is the sea and the rocks standing in
;  it, covers him: he rises OUT of the water instead of over it, and the rocks
;  at the waterline pass in front.
;
;  It has to be a list of its own.  ozpos only orders objects WITHIN one list -
;  the sea is background blocks on baklst3, and the order between lists is
;  dlists_peak_fall and nothing else.  The list is cleared here rather than at
;  round start because the object pool is rebuilt between rounds and a stale
;  pointer in it would be walked.
;
	clr	a0
	move	a0,@peak_skull_lst,l



	move	a8,a10
	movi	fleshup1,a5
	calla	gso_dmawnz
	move	*a10(oxpos),*a8(oxpos),w
	movi	peak_skull_y,a0
	move	a0,*a8(oypos),w
	move	a8,a0
	movi	peak_skull_lst,b4	; insobj_v only READS b4
	calla	insobj_v

;
;  Close it out properly: death_blow_complete raises f_death to -1 AND sends
;  035h.  Writing f_death by hand (as THE DEAD POOL does) is only half, and
;  the 035h death-blow-over tune is what closes the fall out (rfom3 used
;  to call nosounds, which killed the 034h tone; it no longer does).
;  a8-a11 survive.
;
	calla	death_blow_complete	; f_death = -1 + the death blow over tune

	movi	a_mtn_skull,a9
	movk	4,a11			; ticks a frame for the rise; was 10
	jsrp	skull_lane		; fleshup1..7, once

	tsound	0f6h			; bubble
;
;  Then it BOBS IN PLACE, the way a float does when a fish has hold of it:
;  one small tug - sharp down, slower back up
;  and it lets go.  peak_bob_tab is the whole pattern.  Each dip is the
;  rise played back down and up again; anig1 migrates oyval by the anipoint
;  delta on every frame change, so fleshup7 -> 3 sinks it 4 rows and shrinks
;  it back into the water.  No new art.
;
	movi	peak_bob_tab,a10
rfom_bob
	move	*a10+,a0,l		; the wait before this tug
	jrz	rfom_float		; end of the table
	calla	prcslp
	move	*a10+,a9,l		; down...
	move	*a10+,a11,l
	jsrp	skull_lane
	move	*a10+,a9,l		; ...and back up
	move	*a10+,a11,l
	jsrp	skull_lane
	jruc	rfom_bob
;
;  Then it floats off, slowly, towards whichever side of the screen has MORE
;  room, and keeps going.  dclipl adds oxvel every frame for anything in a
;  drawn list, so there is no process to run.
;
rfom_float
	move	*a8(oxpos),a1,w
	move	@worldtlx+16,a2,w
	sub	a2,a1			; a1 = its screen x
	addi	peak_skull_mid,a1
	movi	peak_skull_drift,a0	; right...
	cmpi	scrrgt/2,a1
	jrlt	rfom4			; ...if it is left of middle
	neg	a0
rfom4	move	a0,*a8(oxvel),l
	jauc	wait_forever

;
;  skull_lane - play lane a9 on the skull (a8) at a11 ticks a frame, straight
;  UP AND DOWN.  ani migrates oxval as well as oyval by the anipoint delta,
;  and fleshup's anix runs 8..16 while its head stays at the left of every
;  frame, so framew walked the skull sideways by up to 8px a lane - the bob
;  read as diagonal.  This puts oxval back after each frame change, keeping
;  only the vertical half.  The drift is untouched: dclipl adds oxvel BETWEEN
;  frames, never inside ani.  a10 survives; a0/a1/a4/a6 do not.
;
skull_lane
	move	*a8(oxval),a6,l
	calla	frame_a9		; one frame - C set = it was the last
	jrc	skl_last
	move	a6,*a8(oxval),l		; ...without its sideways migration
	move	a11,a0
	calla	prcslp
	jruc	skull_lane
skl_last
	move	a6,*a8(oxval),l
	move	a11,a0
	calla	prcslp
	retp

;
;  peak_dress_bottom - two things the bottom of the mountain needs while the
;  camera sits on it, both done by CLONING blocks mount1 already has, so there
;  is no new art.  The clones are copies of the live baklst3 objects, so they
;  carry that plane's sag, size, flags and colour map exactly.
;
;  - The ROCKS stand in front of the skull.  The skull is on peak_skull_lst,
;    which has to be drawn after baklst3 (behind it, the water surface washed
;    the whole skull out), so the rocks in the water drew BEHIND it.  Both
;    rocks are cut-out blocks of their own - the spike (03Ah at 396,922) and
;    the flat rock (028h at 325,943) - so a copy on peak_front_lst, drawn
;    after the skull, puts them back in front and nothing else.
;  - mount1 has no blocks in its BOTTOM-LEFT corner (module x 0..90 below row
;    896), and stops short at the BOTTOM-RIGHT, so at either end of the stage
;    the sky showed through as a black box under the cliff.  Blocks next to
;    each gap are copied across it (peak_fill_tab on the left, the whole
;    right-hand column by peak_fill_right) onto peak_fill_lst, drawn
;    BEFORE baklst3, so the real blocks cover any overlap and the copies show
;    only through the holes.
;
;  Module x/y + (304,82) is plane-3 world (tools/peak_sea_band.py).  Nothing
;  scrolls sideways for the rest of the round, so a copy made now stays right.
;

peak_dress_bottom
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a9,a10
	movi	peak_front_lst,a9
	movi	peak_front_tab,a10
	callr	pdb_walk
	movi	peak_fill_lst,a9
	movi	peak_fill_tab,a10
	callr	pdb_walk
	callr	peak_fill_right
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a9,a10
	rets

pdb_walk
	move	*a10+,a3,l		; source x, plane-3 world (0 = end)
	jrz	pdb9
	move	*a10+,a4,l		; source y
	move	*a10+,a5,l		; how far to move the copy
	callr	peak_clone_block
	jruc	pdb_walk
pdb9	rets
;
;  The blocks, by their mount1BLKS position (module x,y) - x, y, shift.
;
pdbx	.equ	peak_mod_wx
pdby	.equ	peak_mod_wy

peak_front_tab				; in FRONT of the skull, not moved
	.long	396+pdbx,922+pdby,0	; the spike		04243H,396,922,03AH
	.long	325+pdbx,943+pdby,0	; the flat rock		04043H,325,943,028H
	.long	0

peak_fill_tab				; BEHIND baklst3
;
;  Bottom-left: mount1 has no blocks at module x 0..90 below row 896.  The
;  rock-and-water blocks just right of it, moved left by the hole's width.
;
	.long	91+pdbx,878+pdby,-peak_hole_w	; 04143H,91,878,04H
	.long	91+pdbx,937+pdby,-peak_hole_w	; 04044H,91,937,05H
	.long	0
;
;  peak_clone_block - copy the baklst3 object at (a3,a4) onto list a9, moved
;  a5 px sideways.  Quietly does nothing if the block is not streamed in or
;  the object pool is empty.  clobbers a0,a1,a2,a6.
;
peak_clone_block
	move	@baklst3,a1,l
pcb1	jrz	pcb9			; end of the list - not there
	move	*a1(oxpos),a0,w
	cmp	a3,a0
	jrne	pcb2
	move	*a1(oypos),a0,w
	cmp	a4,a0
	jreq	pcb3
pcb2	move	*a1(olink),a1,l
	jruc	pcb1

pcb3	callr	peak_clone_obj
pcb9	rets
;
;  peak_clone_obj - copy object a1 onto list a9, moved a5 px sideways.
;  clobbers a0,a2,a6; a1 survives.
;
peak_clone_obj
	calla	getobj
	jrz	pco9			; pool empty
	move	a1,-*sp,l
	move	a0,a6
	movi	obsiz/16,a2
pco1	move	*a1+,*a6+,w		; the whole object block, word for word
	dsj	a2,pco1
	move	*sp+,a1,l
	move	*a0(oxpos),a2,w
	add	a5,a2
	move	a2,*a0(oxpos),w
	move	a9,b4			; insobj_v only READS b4
	calla	insobj_v
pco9	rets
;
;  peak_fill_right - mount1 stops at module x 508 and has its own empty
;  corner at x 490..508 below row 816, and at the right end of the stage
;  the screen reaches module x ~590.  So the right-hand column of the
;  mountain - every block starting at module x 389..470 that reaches the
;  bottom view (rows 690+), rock face and water together - is copied
;  peak_fill_shift to the right, and again at twice that, as ONE piece.  Copying it block by block
;  with each block's own width left seams in the water, a step in the
;  waterline and a strip of sky above; a translated column has none of
;  them, because the copies keep their positions relative to each other
;  and their own z order (ozval is copied, insobj_v sorts on it).
;  The spike is not copied - a second one would stand in the sea.
;
peak_fill_shift	.equ	83		; the water block (03Ch) is 84 wide with an
					;   EMPTY last column - 84 left a 1px crack at
					;   every join, 83 overlaps it.  So
					;   the copied sea meets the real one; done
					;   at 1x and 2x to reach module x ~590
peak_strip_l	.equ	389+peak_mod_wx
peak_strip_r	.equ	470+peak_mod_wx
peak_strip_top	.equ	690+peak_mod_wy

peak_fill_right
	movi	peak_fill_lst,a9
	movi	peak_fill_shift,a5
	callr	pfr_pass
	movi	peak_fill_shift*2,a5
pfr_pass
	move	@baklst3,a1,l
pfr1	jrz	pfr9
	move	*a1(oxpos),a0,w
	cmpi	peak_strip_l,a0
	jrlt	pfr2
	cmpi	peak_strip_r,a0
	jrgt	pfr2
	cmpi	396+peak_mod_wx,a0	; the spike's x...
	jrne	pfr_y
	move	*a1(oypos),a0,w
	cmpi	922+peak_mod_wy,a0	; ...and y - leave it
	jreq	pfr2
pfr_y	move	*a1(oypos),a0,w
	move	*a1(osizey),a2,w
	add	a2,a0			; a0 = its bottom row
	cmpi	peak_strip_top,a0
	jrlt	pfr2			; entirely above the bottom view
	callr	peak_clone_obj
pfr2	move	*a1(olink),a1,l
	jruc	pfr1
pfr9	rets


mtn_splash_proc
	tsound	0f5h			; splash sound
	movi	a_green_splash,a9
	movk	4,a0
	jsrp	framew
	move	a8,a0
	calla	delobjp
	jauc	wait_forever


;
;  dlists_peak_fall - what the screen is once he is off the bridge.
;
;  NO RAIN: peak_rain_lst is left out, so the storm stops drawing the tick
;  mtn_fall_behind installs this - his feet into the deck.  Its process
;  carries on unseen and the next round's module puts dlists_peak back.
;
;  dlists_peak draws objlst AFTER baklst5/4, so a fighter stands in front of
;  the far railing and on the deck - right while he stands on it, wrong the
;  moment he falls past it.  So the fighters move back a course: after the
;  mountain, before the deck.  A z sort CANNOT do this - ozval only orders
;  within one list, and these are hand-placed objects on baklst4/5/7.
;
;  Cost: the winner is on objlst too, so his feet are behind the deck's top
;  rows for the ~30 frames the bridge is still on screen.  Nothing swaps it
;  back; the next round re-runs the module, which installs dlists_peak.
;
dlists_peak_fall
	.if srtflash
	.if peakflash
	.long	-1,flash_layer
	.endif
	.endif
	.long	baklst6,worldtlx6+16	; sky
	.long	baklst2,worldtlx2+16	; lightning
	.long	peak_fill_lst,worldtlx3+16	; mount1's bottom-left hole, filled
	.long	baklst3,worldtlx3+16	; the mountain - he falls in FRONT of this
	.long	-2			; shadows
	.long	objlst,worldtlx+16	; ...and BEHIND everything below
	.long	peak_skull_lst,worldtlx+16	; the skull, IN FRONT of the sea.
					;   It was tried BEHIND baklst3, which put
					;   it behind the rocks standing in the
					;   water - but baklst3 is the water
					;   SURFACE as well, so the whole skull
					;   washed out instead of just the
					;   submerged part of it.  Only the rock
					;   should be in front, and one block of a
					;   background module cannot be lifted out
					;   of it by list order - that needs a copy
					;   of the rock hand-placed on a list above
					;   this one
	.long	peak_front_lst,worldtlx3+16	; the rocks in the water, in front of it
	.long	baklst5,worldtlx5+16	; far railing
	.long	baklst4,worldtlx4+16	; stone deck
	.long	baklst7,worldtlx7+16	; near railing
	.long	objlst2,worldtlx+16	; text, always last
	.long	0


a_mtn_skull
	.long	fleshup1
	.long	fleshup2
	.long	fleshup3
	.long	fleshup4
	.long	fleshup5
	.long	fleshup6
	.long	fleshup7
	.long	0

peak_bob_tab				; wait, down lane+rate, up lane+rate.
;	.long	4				;   one small tug: sharp down,
;	.long	a_mtn_dip_mid,1,a_mtn_rise_mid,2	;   slower up
	.long	0				; NO bob, at the user's call - it
						;   rises and drifts.  The line above
						;   is one fish-bite tug, if wanted

a_mtn_dip_mid				; to fleshup3: 4 rows
	.long	fleshup6,fleshup5,fleshup4,fleshup3,0
a_mtn_rise_mid
	.long	fleshup4,fleshup5,fleshup6,fleshup7,0

a_mtn_bob_deep				; to fleshup2 and back: 7 rows
	.long	fleshup6,fleshup5,fleshup4,fleshup3,fleshup2
	.long	fleshup3,fleshup4,fleshup5,fleshup6,fleshup7
	.long	0
a_mtn_bob_mid				; to fleshup3: 4 rows
	.long	fleshup6,fleshup5,fleshup4,fleshup3
	.long	fleshup4,fleshup5,fleshup6,fleshup7
	.long	0
a_mtn_bob_small				; to fleshup4: 2 rows - the last four
	.long	fleshup6,fleshup5,fleshup4	;   frames sit within 2 rows of
	.long	fleshup5,fleshup6,fleshup7	;   each other
	.long	0
