**************************************************************************
*											     *
*  video game project:	mortal kombat 2							*
*											     *
*  module: mkerfat.asm - ERMAC'S TELEKINETIC HEAD RIP (erfheadrip)	     *
*											     *
*  Forward, Back, Forward, Forward + LOW KICK in FINISH HIM, from more than *
*  half the screen away (erf_check, called from ermac_lo_kick, MOVES.ASM).  *
*											     *
*  The user's IMGTOOL project data/ERMACFAT2.WAX is the source of truth for  *
*  Ermac's poses, their holds and the head's whole flight; the generated    *
*  block at the bottom of this file and a_ermac_headrip (MKNJ.ASM) come out *
*  of tools/ermac_headrip_wax_import.py.  Edit the project, rerun the tool. *
*											     *
*  THE BEATS (ERF_T_*, read off the project):				     *
*    GRIP    he holds his arm out at the man - who SHAKES in his grip.	     *
*    RIP     the head comes off and flies to Ermac's hand.  The rest of     *
*	     him stands, headless (his own decap fall, frame 1).	     *
*    IMPACT  Ermac throws the head back INTO his torso.  He comes apart     *
*	     into two objects - legs standing where he stood (row 039h      *
*	     part 6), his own object the headless torso (part 10) - and the *
*	     head is GONE while it is inside him (parked off the plane),    *
*	     the legs drawn over the torso.  Both halves shake with the hit.*
*    PULL    the head is torn back out.  The torso goes over BACKWARDS off *
*	     the screen edge, only the neck left in view (part 11), and the legs wobble *
*	     forward and fall (parts 7-9, r_sai_split's beats).	     *
*    END     Ermac's lane is done; victory.					     *
*											     *
*  NO NEW ART.  Ermac's poses are the ninja body's own swipe / spear /	     *
*  death-blow frames; the victim's are each fighter's own decap fall and    *
*  head roll.  The torso half of the decap frames (039h parts 10/11) is	     *
*  generated into all nine fighter modules by the same tool.		     *
*											     *
*  Processes: Ermac's own is the director and steps @erf_tick; the victim   *
*  is takeover_him'd into erf_victim and acts on the tick; the head is its  *
*  own process (erf_head_proc).  Only a8-a11 survive a sleep.		     *
*											     *
**************************************************************************
	.file	"mkerfat.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	imgtbl.glo
	.text

	.ref	fatality_xfer_close		; MOVES.ASM - FINISH HIM, range, the common gate
	.ref	rain_obj_set_z			; MKZAP.ASM - re-link an object at a new z
	.ref	erf_pop_chunks			; MKDIE.ASM - the body pop's blood and chunks
	.ref	erf_splat_top			; MKBLOOD.ASM - one BLDXPD burst over him, a10 [Y:X] off a11
	.ref	a_flame_b			; BGND.ASM - THE TOWER's torch flame, FlameB1-4
	.ref	j_szvic				; MKNJ.ASM - Sub-Zero's victory frames
	.ref	jc_headhole_spill_proc		; MKDEATH.ASM - the headhole fatality's blood pool

erfgreen	.set	1		; 1 = the green flame (ERMACFATGRN.WAX); 0 = none
erflift		.set	1		; 1 = he tears the head off and LIFTS it on
					;   Sub-Zero's victory (the user's call,
					;   2026-10-10); 0 = throws it back into him
					;   and he bursts
erfheadrip	.set	1		; 0 = the input is dead (erf_check just returns)

	.def	erf_check
	.def	do_ermac_headrip

	.globl	erf_tick		; for tools/ermac_headrip_test.lua
	.bss	erf_tick,16,1		; ticks into Ermac's lane - every beat reads it
	.bss	erf_ex,16,1		; Ermac's anchor at the start
	.bss	erf_ey,16,1
	.bss	erf_vx,16,1		; the victim's anchor at the start
	.bss	erf_vy,16,1
	.bss	erf_landed,16,1		; 1 = the head is down
	.bss	erf_eobj,32,1		; Ermac's object (the lifted head hangs off it)
	.bss	erf_liftf,16,1		; lift: which victory frame he is on, 1-3 (0 = not yet)
	.bss	erf_hobj,32,1
	.bss	erf_flamed,16,1		; 1 = the flame process is started		; the flying head's object (the flame rides it)

*
* Tuning that is not in the project.
*
ERF_MINDIST	.set	0d8h	; a little more than half the screen away
ERF_MAXDIST	.set	0150h	; ...out to the far side of it
ERF_GRIP_JIT	.set	2	; px he shakes in the grip - out and back, the way
ERF_SHAKE_T	.set	3	;   shake_him_up does, this many ticks a half-step
ERF_HIT_JIT	.set	2	; px both halves shake at the impact, same cadence
ERF_INSIDE_Y	.set	02ch	; px below his anchor the face sits while it is in
				;   him: just above the legs' cut, its chin behind it
ERF_HIT_SHAKE	.set	01ch	; ...for this many ticks
ERF_TORSO_RATE	.set	7	; ticks a frame as the torso goes over
ERF_HIPS_OUT	.set	4	; px of the torso's cut bottom past the screen edge
				;   when it lands - it has no guts drawn on it
ERF_PACE	.set	4	; every this many authored ticks, one extra frame:
				;   the whole WAX timeline runs 5/4 as long...
ERF_PACE_OUT	.set	2	; ...and from the pull on, every 2nd: 3/2 as long
ERF_LEG_BUCKLE	.set	8	; the legs' beats - r_sai_split's, a little slower
ERF_LEG_WOBBLE	.set	00ch
ERF_LEG_FALL	.set	8
ERF_LEG_STAND	.set	018h	; ticks the cut legs stand before they buckle
ERF_END_HOLD	.set	030h	; ticks he holds his last pose once the head is down
ERF_END_MAX	.set	0180h	; ...but never longer than this waiting for it
ERF_DROP_SPIN	.set	5	; ticks a frame of its roll as it comes down -
				;   the body pop's head drop (init_anirate 5)
ERF_DROP_WAIT	.set	030h	; ticks the head is up in the blast before it
				;   drops back onto the screen
ERF_FLY_BACK	.set	16	; px a tick to Ermac's hand - quicker than Scorpion's
				;   spear (0a0000h), as asked
ERF_FLY_THROW	.set	20	; px a tick into the torso - a hard throw, about the
				;   authored WAX speed
ERF_SPIN_FAST	.set	2	; ticks a head frame while it flies to Ermac / is torn out
ERF_PULL_XV	.set	01c000h	; torn out: toward Ermac, ~1/4 screen with the roll
ERF_PULL_YV	.set	-048000h	; ...popped up out of him
ERF_PULL_G	.set	06000h	; ...a little under decapped_head's gravity
ERF_PULL_SPIN	.set	3	; ticks a frame as it tumbles out
ERF_HOP		.set	2	; a flight moves in hops this many ticks apart, a
				;   frame of the roll each hop - hand-timed, not a glide
ERF_SPIN_SLOW	.set	5	; ...and while it tumbles back into the torso
ERF_STRETCH_X	.set	0b0h	; xstep it stretches to on the throw (oscale: a
				;   SMALLER step draws WIDER - 0b0h = ~1.45x)
ERF_STRETCH_DX	.set	020h	; ...reached this much a tick from 0100h
ERF_FLAME_ONHEAD .set	4	; px into the top of the head its base sits
ERF_FLAME_BIG	.set	0a0h	; it grows in his palm to this step (1.6x)...
ERF_FLAME_SINK	.set	10	; ...its base sinking this many px down the face
ERF_STREAK_LEAN	.set	4	; thrown: the flame leans this many px back...
ERF_STREAK_XS	.set	080h	; ...drawn wider (2x)...
ERF_STREAK_YS	.set	0d0h	; ...and shorter (1.2x)
ERF_RIPSTK_XS	.set	0c0h	; torn off to his hand (the flame is 1:1 there): 1.33x wide,
ERF_RIPSTK_YS	.set	0130h	;   0.84x tall,
ERF_RIPT1_S	.set	0180h	;   tails 0.67x
ERF_RIPT2_S	.set	0200h	;   and 0.5x
ERF_TAIL1_S	.set	0f0h	; the tail flames: 1.07x, 3 leans back, this high
ERF_TAIL1_UP	.set	6
ERF_TAIL2_S	.set	0140h	; ...0.8x, 6 leans back, higher still
ERF_TAIL2_UP	.set	10
ERF_FLAME_RATE	.set	4	; ticks a frame it flickers
ERF_LIFT_RATE	.set	5	; ticks a frame of the lift (4 read quick, 6 slow)
ERF_LIFT_STAND	.set	030h	; ticks the headless body stands before it goes down
ERF_POOL_UP	.set	4	; px the pool's top sits above the legs' bottom
ERF_POOL_Z	.set	018000h		; the blood pool: over the burst's chunks (ozpos 1)
				;   so it shows, under the legs (2)
ERF_HEAD_Z	.set	front_z+4	; in front of everything while it flies
ERF_FLAME_PREZ	.set	front_z-2	; ...and behind the VICTIM (front_z-1) before the rip
ERF_PRE_DOWN	.set	14	; px the flame is sunk behind his head before the
				;   rip, so it is only a flicker over it (subtle)
ERF_FLAME_Z	.set	ERF_HEAD_Z-1	; the green flame: just BEHIND the head (the
				;   user's call), over everything else
ERF_HEAD_INZ	.set	front_z+2	; ...out of him on the pull: over the torso,
				;   under the legs
ERF_NOWHERE	.set	0800h	; px down: off the plane while it is inside him
ERF_TORSO_Z	.set	front_z+1	; under the legs (and under his lodged head)
ERF_STUCK_Z	.set	01c000h		; his head in his belly: over the torso, under
				;   the legs' cut (020000h)
ERF_STUCK_Y	.set	036h	; px below his anchor it sits: his belly
ERF_STUCK_X	.set	8	; ...and this far toward Ermac, so the neck
				;   sticks out of the front of him
ERF_LEGS_Z	.set	020000h		; the legs over everything, the burst's gore too:
				;   explode_piece puts its chunks at ozpos 1, an
				;   INTEGER z, which tops every front_z+n
ERF_HEAD_OUTZ	.set	030000h		; the head shooting out, over the legs and the gore
ERF_SHOOT_VY	.set	-0e0000h	; px a tick (16.16) it rockets up out of him

**************************************************************************
*											     *
*  erf_check - Ermac's LOW KICK, before his babality.  Returns if this is   *
*  not the head rip; on a match it drops its own return address (bb_check's *
*  shape) and leaves through fatality_xfer_close, which either transfers   *
*  to do_ermac_headrip or ends the handler.				     *
*											     *
**************************************************************************
erf_check
	.if	erfheadrip
	move	@winner_status,a0,w
	cmpi	3,a0
	jrne	erfc_no			; only during "finish him" mode

	movi	f1b0|f1b1|f1b2|f1b3,a0	; LK (b4) is the trigger: reject the rest
	movi	f2b0|f2b1|f2b2|f2b3,a1
	movi	scom_ermac_headrip,a11
	calla	combo_look_lr
	jrnc	erfc_no

	calla	get_x_dist		; a3 = |x distance between us|
	cmpi	ERF_MINDIST,a3
	jrlo	erfc_no			; too close - this is a reach across the stage

	pull	a0			; never coming back here
	movi	ERF_MAXDIST,a1
	movi	do_ermac_headrip,a7
	jauc	fatality_xfer_close
erfc_no
	.endif
	rets

*
* scom_ermac_headrip - Forward, Back, Forward, Forward, NEWEST FIRST; the
* first half facing right, the second facing left.  Window 038h, the game's
* ceiling for a four-input fatality (see scom_ermac_fatal, MOVES.ASM).
*
scom_ermac_headrip
	.word	038h
	.word	sw_right
	.word	sw_right
	.word	sw_left
	.word	sw_right
	.word	0
	.word	0

	.word	sw_left
	.word	sw_left
	.word	sw_right
	.word	sw_left
	.word	0
	.word	0

**************************************************************************
*											     *
*  do_ermac_headrip - the director, in Ermac's process.			     *
*											     *
**************************************************************************
do_ermac_headrip
	movk	1,a0			; fade = yes
	movk	2,a1			; fatality #
	calla	init_death_blow

	movi	040h*40,a0
	move	a0,@f_norepell,w	; disable_repell (MKDEATH.ASM)
	calla	stop_me
	calla	face_opponent

	clr	a0
	move	a0,@erf_tick,w
	move	a0,@erf_landed,w
	move	a0,@erf_flamed,w
	move	a0,@erf_hobj,l
	move	a0,@erf_liftf,w
	move	a8,@erf_eobj,l
*
* Both anchors, before anybody moves.  A multipart object's oxpos/oypos IS
* its anchor (lineup_1pwm relies on that), so this is the point every frame
* of either man hangs off.
*
	move	*a8(oxpos),a0,w
	move	a0,@erf_ex,w
	move	*a8(oypos),a0,w
	move	a0,@erf_ey,w
	move	*a13(p_otherguy),a1,l
	move	*a1(oxpos),a0,w
	move	a0,@erf_vx,w
	move	*a1(oypos),a0,w
	move	a0,@erf_vy,w

	movi	erf_victim,a7
	calla	takeover_him

	movi	0bh,a9
	calla	get_char_ani2		; a9 = a_ermac_headrip (ermac_anitab2 0bh)
	movi	erf_holds,a10
erf_frame
	move	*a10+,a11,w		; this frame's hold - 0 = the lane is done
	jreq	erf_done
	mmtm	sp,a10,a11
	calla	do_next_a9_frame
	mmfm	sp,a10,a11
erf_tickloop
	.if	erflift
	move	@erf_tick,a0,w
	cmpi	ERF_T_LIFT,a0		; he has held it, raised it and looked at it
	jrhs	erf_lift		;   (the project's own frames): up it goes
	.endif
	move	@erf_tick,a0,w
	cmpi	ERF_T_RIP,a0
	jrne	erf_sleep
	mmtm	sp,a10,a11
	move	*a13(p_otherguy),a10,l	; a10 = the victim, handed down
	create	pid_head,erf_head_proc
	mmfm	sp,a10,a11
erf_sleep
	.if	erfgreen
	move	@erf_tick,a0,w
	cmpi	ERF_T_GRIP,a0		; his arm goes out: the soul flame lights
	jrlo	erf_sleep2		;   behind the victim's head, still on him
	move	@erf_flamed,a0,w	; once (the pace can hold a tick two frames)
	jrne	erf_sleep2
	movk	1,a0
	move	a0,@erf_flamed,w
	mmtm	sp,a10,a11
	move	*a13(p_otherguy),a10,l	; a10 = the victim
	clr	a11			; the flame off his head
	create	pid_fx,erf_flame_proc
	mmfm	sp,a10,a11
erf_sleep2
	.endif
	sleep	1
	move	@erf_tick,a0,w
	cmpi	ERF_T_PULL,a0
	jrhs	erf_pout
	andi	ERF_PACE-1,a0
	jruc	erf_pchk
erf_pout
	andi	ERF_PACE_OUT-1,a0
erf_pchk
	jrne	erf_adv
	sleep	1			; the pace: this authored tick lasts two frames
erf_adv	move	@erf_tick,a0,w
	inc	a0
	move	a0,@erf_tick,w
	dsj	a11,erf_tickloop
	jruc	erf_frame

*
* He stays on his last pose (the lane ends on it) until the head is down,
* then holds it a moment more before the victory.
*
erf_done
	movi	ERF_END_MAX,a11
erfd_wait
	move	@erf_landed,a0,w
	jrne	erfd_down
	sleep	1
	.if	erflift
	callr	erf_lift_tick
	.else
	move	@erf_tick,a0,w		; the beats past the end of his lane (the
	inc	a0			;   burst) still come on the clock
	move	a0,@erf_tick,w
	.endif
	dsj	a11,erfd_wait
erfd_down
	sleep	ERF_END_HOLD
	calla	death_blow_complete
	.if	erflift
	jauc	wait_forever		; ...and he keeps it up there: no victory to
					;   play, he is already in one
	.else
	jauc	victory_animation
	.endif

	.if	erflift
*
* erf_lift - he has held the head in his hand, raised it slowly and looked
* at it on Sub-Zero's snowball pose (the project's lane to ERF_T_LIFT, with
* the generator's RISE_EXTRA / LOOK_EXTRA): now he LIFTS it, on Sub-Zero's victory
* (j_szvic, MKNJ.ASM: fist at the chest, over the head, arm straight up), and
* holds it there while the headless body goes down (erf_victim).  @erf_liftf
* tells the head which frame's fist to sit in (erf_lift_hand).  The clock
* runs on to just short of the throw and stops - nothing after the catch in
* the project happens, and the flame grows over exactly that stretch.
*
erf_lift
	movi	j_szvic,a9
	movk	3,a10
erfl_fr	push	a10
	calla	do_next_a9_frame
	pull	a10
	move	@erf_liftf,a0,w
	inc	a0
	move	a0,@erf_liftf,w
	movk	ERF_LIFT_RATE,a11
erfl_t	sleep	1
	callr	erf_lift_tick
	dsj	a11,erfl_t
	dsj	a10,erfl_fr
	jruc	erf_done

erf_lift_tick
	move	@erf_tick,a0,w
	cmpi	ERF_T_THROW-1,a0
	jrhs	elt_x
	inc	a0
	move	a0,@erf_tick,w
elt_x	rets

*
* where the MIDDLE of the head sits on each victory frame, off Ermac's anchor
* with the art facing right (x is mirrored when he is flipped): in his fist.
* Read off NJSUBVIC1-3.
*
erf_lift_hand
	.word	-8,14			; NJSUBVIC1 - fist at his chest
	.word	-4,-14			; NJSUBVIC2 - over his head
	.word	-13,-32			; NJSUBVIC3 - arm straight up
	.endif

**************************************************************************
*											     *
*  erf_head_proc - the head, from the rip to the end of the lane.	     *
*											     *
*  Built like decapped_head (MKCANNED.ASM) - the victim's own head roll     *
*  lane (anitab1 03dh), the entry the project holds - and placed every	     *
*  tick off erf_head_path through the two live anchors:			     *
*											     *
*	X = Ex + x * (Vx - Ex) / ERF_DIST				     *
*	Y = Ey + y + x * (Vy - Ey) / ERF_DIST				     *
*											     *
*  so x = ERF_DIST is on him and 0 on Ermac whatever the real distance -    *
*  and the sign of Vx - Ex is the facing.  MPYS/DIVS into an ODD register   *
*  are the 32-bit forms (an even one is a register pair).		     *
*											     *
**************************************************************************
erf_head_proc
	move	a10,a8			; a10 = the victim, handed down
	movi	03dh,a9
	calla	get_char_ani		; his head roll
	addi	ERF_HEAD_FRAME*32,a9
	move	*a9+,a5,l		; a9 = the rest of the roll, for the spin
	calla	gso_dmawnz		; a8 = the head
	move	a8,a8
	jreq	ehp_die			; object pool empty: no head to fly

	move	*a10(ochar),*a8(ochar),w
	movi	oid_head,a0
	move	a0,*a8(oid),w		; the body pop's delete_offscreen (MKDIE) frees
					;   any untagged object off screen - and this
					;   one is parked off the plane while he bursts
	calla	change_to_bloody_pal
	move	a8,a0
	move	a10,a1
	calla	lineup_1pwm		; his facing
	movi	ERF_HEAD_Z,a0
	move	a0,*a8(ozval),l
	clr	a0
	callr	ehp_xy_row
	callr	ehp_put			; where the project tears it off
	move	a8,*a13(p_store1),l
	move	a8,@erf_hobj,l		; the green flame rides it
	move	a9,*a13(p_store3),l
	calla	insobja8
*
* how many frames his head roll has (to the ani_jump that loops it): the throw
* turns it through exactly that many - one rotation, ending where it began
*
	move	a10,a8
	movi	03dh,a9
	calla	get_char_ani
	clr	a1
ehp_cnt	move	*a9+,a0,l
	cmpi	ani_jump,a0
	jreq	ehp_cnd
	inc	a1
	cmpi	16,a1
	jrlo	ehp_cnt			; (a lane with no ani_jump stops here)
ehp_cnd	move	a1,*a13(p_store2),l	; frames in one rotation
	clr	a0
	move	a0,*a13(p_store4),l	; ...and how many the throw has shown
	move	*a13(p_store1),a8,l	; the head again
	move	*a13(p_store3),a9,l	; ...and its roll cursor
	jruc	ehp_wax
*
* RIP -> HAND -> THROW -> INTO HIM: exactly the project - its one head frame,
* its keyframe positions, its holds.  No spin, no flip.
*
ehp_wax	sleep	1
	move	@erf_tick,a0,w
	cmpi	ERF_T_IMPACT,a0
	jrhs	ehp_inhim
	cmpi	ERF_T_THROW,a0
	jrlo	ehp_wax2
	subi	ERF_T_THROW,a0		; thrown: it stretches out WIDE, the way the
	sll	5,a0			;   forceball squashes, but only across -
	movi	0100h,a1		;   0100h down to ERF_STRETCH_X, 020h a tick
	sub	a0,a1
	cmpi	ERF_STRETCH_X,a1
	jrge	ehp_sx
	movi	ERF_STRETCH_X,a1
ehp_sx	addi	01000000h,a1		; y stays 1:1
	move	a1,*a8(oscale),l
	move	@erf_tick,a0,w
*
* ...and it turns ONCE, spread over the whole throw: by tick k of the throw it
* has shown (k+1) * frames / (IMPACT - THROW) of its roll, so the last frame
* of the turn lands as it hits.
*
	move	@erf_tick,a0,w
	subi	ERF_T_THROW-1,a0	; ticks into the throw, counting this one
	move	*a13(p_store2),a1,l
	mpyu	a0,a1			; odd register: the 32-bit product
	movi	ERF_T_IMPACT-ERF_T_THROW,a5
	divu	a5,a1			; frames of the turn due by now
	move	*a13(p_store2),a0,l
	cmp	a0,a1
	jrls	ehp_due
	move	a0,a1			; never more than one turn
ehp_due	move	a1,*a13(p_store5),l
ehp_turn
	move	*a13(p_store4),a0,l
	move	*a13(p_store5),a1,l
	cmp	a1,a0
	jrhs	ehp_turned
	inc	a0
	move	a0,*a13(p_store4),l
	calla	frame_a9
	jruc	ehp_turn
ehp_turned
	move	@erf_tick,a0,w
ehp_wax2
	.if	erflift
	move	@erf_liftf,a1,w
	jreq	ehp_path
	dec	a1			; lifted: in the fist of the frame he is on
	sll	5,a1
	addi	erf_lift_hand,a1
	move	*a1+,a2,w
	move	*a1,a3,w
	move	@erf_eobj,a4,l
	move	*a4(oflags),a0,w
	btst	b_fliph,a0
	jreq	ehp_lf
	neg	a2
ehp_lf	move	*a4(oxpos),a1,w
	add	a2,a1
	move	*a4(oypos),a0,w
	add	a0,a3
	callr	ehp_put
	jruc	ehp_wax
ehp_path
	move	@erf_tick,a0,w
	.endif
	subi	ERF_T_RIP,a0
	callr	ehp_xy_row
	callr	ehp_put
	jruc	ehp_wax
*
* IN HIM: lodged in his belly with its neck sticking out at Ermac - row 039h
* part 12, the roll frame the generator measured at ~45 deg up toward him -
* back to 1:1 (it was stretched for the throw), over the torso and under the
* legs, so the neck gore reads as the hole it made.  It rides the shake: its
* place is taken off his LIVE anchor every tick.
*
ehp_inhim
	move	a8,a0
	movi	ERF_STUCK_Z,a1
	calla	rain_obj_set_z
	movi	01000100h,a0
	move	a0,*a8(oscale),l
	move	a8,a11			; the head
	move	a10,a8			; ...his frame comes off his own row 039h
	movi	039h,a9
	calla	get_char_ani
	movk	12,a14
	calla	find_part_a14
	move	a11,a8
	calla	frame_a9
	move	*a10(oflags),a0,w	; facing him the way he faces: at Ermac
	move	*a8(oflags),a1,w
	andni	m_fliph,a1
	andi	m_fliph,a0
	or	a0,a1
	move	a1,*a8(oflags),w
ehp_inw	callr	ehp_stuck_xy
	callr	ehp_put
	sleep	1
	move	@erf_tick,a0,w
	cmpi	ERF_T_PULL,a0
	jrlo	ehp_inw
	callr	ehp_inside_xy		; blown apart with him: off the plane
	addi	ERF_NOWHERE,a3
	callr	ehp_put
*
* ...and it goes with him: blown apart in the burst, never seen again (the
* user's call).  It stays parked off the plane - oid_head keeps the burst's
* delete_offscreen off it.
*
ehp_die	die

*
* ehp_stuck_xy - a1/a3 = his belly, off his LIVE anchor (he is shaking), a
* little toward Ermac.  a10 = him.
*
ehp_stuck_xy
	move	*a10(oxpos),a1,w
	move	*a10(oypos),a3,w
	addi	ERF_STUCK_Y,a3
	movk	ERF_STUCK_X,a0
	move	@erf_ex,a2,w
	move	@erf_vx,a4,w
	cmp	a4,a2
	jrge	ehps_r
	neg	a0			; Ermac to his left
ehps_r	add	a0,a1
	rets

*
* ehp_inside_xy - a1/a3 = where his face sits while it is in him: on his
* middle, just above the legs' cut.
*
ehp_inside_xy
	move	@erf_vx,a1,w
	move	@erf_vy,a3,w
	addi	ERF_INSIDE_Y,a3
	rets

*
* ehp_xy_row - a0 = a row of erf_head_path -> a1 = X, a3 = Y, its anchor in
* the world, mapped through the two live anchors (see the header above).
*
ehp_xy_row
	sll	5,a0
	addi	erf_head_path,a0
	move	*a0+,a2,w		; a2 = x in front of Ermac
	move	*a0,a4,w		; a4 = y below him

	move	@erf_vx,a1,w
	move	@erf_ex,a3,w
	sub	a3,a1			; Vx - Ex
	mpys	a2,a1			; a1 = x * (Vx - Ex)
	movi	ERF_DIST,a5
	divs	a5,a1
	add	a3,a1			; a1 = X

	move	@erf_vy,a3,w
	move	@erf_ey,a6,w
	sub	a6,a3			; Vy - Ey
	mpys	a2,a3			; a3 = x * (Vy - Ey)
	divs	a5,a3
	add	a6,a3
	add	a4,a3			; a3 = Y
	rets

*
* ehp_put - the head's MIDDLE onto (a1, a3) - as DRAWN, so a stretched head
* stays centred.  Not its anipoint: the heads are
* not anchored alike (the female ninjas' sit well off centre), and the WAX was
* posed on NJHEAD6, whose anipoint is its middle - so the middle is what lands
* in Ermac's hand for everybody.  Flip-proof, too.
*
ehp_put
	move	*a8(oimg),a0,l
	move	*a0(isize),a2,l		; [y:x]
	move	a2,a4
	move	a2,a7
	zext	a7,w
	sll	8,a7
	move	*a8(oscale),a5,w	; xstep (0100h = 1:1)
	divu	a5,a7			; drawn width = w * 0100h / xstep (odd reg)
	srl	1,a7			; half the drawn width
	srl	16,a4
	srl	1,a4			; half the height
	sub	a7,a1
	sub	a4,a3
	sll	16,a1
	move	a1,*a8(oxval),l
	sll	16,a3
	move	a3,*a8(oyval),l
	rets

	.if	erfgreen
**************************************************************************
*											     *
*  erf_flame_proc - THE GREEN FLAME (erfgreen, data/ERMACFATGRN.WAX).	     *
*											     *
*  THE TOWER's torch frames (a_flame_b: FlameB1-4, packed in MKBGANI.TBL)    *
*  on MKBGANI.IMG's FLAME1_P - the torch recoloured green, carried here as  *
*  ERF_FLAME_P.  It lights on the head when Ermac holds it up (ERF_T_FLAME, *
*  Sub-Zero's snowball pose) and grows over the face (efp_grow); thrown, it *
*  streaks back (two tail flames); it is gone the tick the head goes into   *
*  his belly (ERF_T_IMPACT) - the burst after that is the plain one.	     *
*  a10 = him.								     *
*											     *
**************************************************************************
erf_flame_proc
	movi	a_flame_b,a9
	move	*a9+,a5,l		; FlameB1; a9 = the rest, for the flicker
	calla	gso_dmawnz		; a8 = the flame
	move	a8,a8
	jreq	efp_die
	movi	oid_head,a0
	move	a0,*a8(oid),w		; delete_offscreen leaves an oid_head alone
	movi	ERF_FLAME_P,a0
	calla	swpal			; green
	movi	ERF_FLAME_PREZ,a0	; behind him while his head is still on
	move	a0,*a8(ozval),l
	clr	a0
	move	a0,*a13(p_store4),l	; flicker countdown
	move	a0,*a13(p_store3),l	; the streak's tail not built yet
	move	a0,*a13(p_store5),l	; ...its two flames
	move	a0,*a13(p_store6),l
	move	a0,*a13(p_store2),l	; not yet brought in front (at the rip)
	callr	efp_place
	calla	insobja8

efp_lp	sleep	1
	move	@erf_tick,a0,w
	cmpi	ERF_T_IMPACT,a0
	jrhs	efp_out			; the head is in him: the flame is done
	cmpi	ERF_T_RIP,a0		; the head comes off: from behind him to in
	jrlo	efp_zok			;   front of everything but the head
	move	*a13(p_store2),a1,l
	jrne	efp_zok
	movk	1,a1
	move	a1,*a13(p_store2),l
	mmtm	sp,a8,a9
	move	a8,a0
	movi	ERF_FLAME_Z,a1
	calla	rain_obj_set_z
	mmfm	sp,a8,a9
efp_zok	move	@erf_tick,a0,w
	cmpi	ERF_T_RIP,a0
	jrlo	efp_fl
	move	*a13(p_store3),a1,l	; torn off: build the streak's tail, once
	jrne	efp_fl
	callr	efp_tails
efp_fl	move	*a13(p_store4),a0,l	; flicker: a frame every ERF_FLAME_RATE
	dec	a0
	jrgt	efp_fs
	calla	frame_a9		;   (a_flame_b loops itself)
	callr	efp_tail_ani
	movk	ERF_FLAME_RATE,a0
efp_fs	move	a0,*a13(p_store4),l
	callr	efp_place
	jruc	efp_lp

efp_out	move	*a8(oyval),a0,l		; off the plane (oid_head keeps the burst's
	addi	ERF_NOWHERE<<16,a0	;   delete_offscreen off it)
	move	a0,*a8(oyval),l
	move	*a13(p_store5),a0,l
	callr	efp_park
	move	*a13(p_store6),a0,l
	callr	efp_park
efp_die	die

efp_park
	move	a0,a0
	jreq	epk_x
	move	*a0(oyval),a1,l
	addi	ERF_NOWHERE<<16,a1
	move	a1,*a0(oyval),l
epk_x	rets

*
* efp_tails - the two smaller flames that trail behind the thrown one, so
* together they read as one flame BENT BACK by the speed (the DMA can only
* scale, not bend).  Built once, at the throw, out of step with the main
* flame's flicker.  p_store5/6 = the objects, p_store7/8 = their lanes.
*
efp_tails
	movk	1,a0
	move	a0,*a13(p_store3),l
	mmtm	sp,a8,a9
	movi	a_flame_b+64,a9		; FlameB3
	callr	efp_tail_new
	move	a8,*a13(p_store5),l
	move	a9,*a13(p_store7),l
	movi	a_flame_b+32,a9		; FlameB2
	callr	efp_tail_new
	move	a8,*a13(p_store6),l
	move	a9,*a13(p_store8),l
	mmfm	sp,a8,a9
	rets

efp_tail_new
	move	*a9+,a5,l
	calla	gso_dmawnz		; a8 = it (0: the pool is dry, no tail)
	move	a8,a8
	jreq	etn_x
	movi	oid_head,a0
	move	a0,*a8(oid),w
	movi	ERF_FLAME_P,a0
	calla	swpal			; the same green (getfpal shares the map)
	movi	ERF_FLAME_Z-1,a0	; just behind the main flame
	move	a0,*a8(ozval),l
	movi	01000100h,a0
	move	a0,*a8(oscale),l
	movi	ERF_NOWHERE*2,a0	; off the plane until a streak places it
	sll	16,a0
	move	a0,*a8(oyval),l
	calla	insobja8
etn_x	rets

efp_tail_ani
	move	*a13(p_store5),a0,l
	jreq	eta_x
	mmtm	sp,a8,a9
	move	a0,a8
	move	*a13(p_store7),a9,l
	calla	frame_a9
	move	a9,*a13(p_store7),l
	move	*a13(p_store6),a8,l
	move	a8,a8
	jreq	eta_r
	move	*a13(p_store8),a9,l
	calla	frame_a9
	move	a9,*a13(p_store8),l
eta_r	mmfm	sp,a8,a9
eta_x	rets

*
* efp_place - the flame's anchor (its base) onto this tick's place, drawn at
* this tick's size.  The DMA scales from the top left, so the anchor offset
* is scaled too: top left = anchor - ani * 0100h / step.
*
efp_place
	move	@erf_tick,a0,w
	cmpi	ERF_T_RIP,a0		; still on his shoulders: behind his head
	jrhi	efpp_head
	move	@erf_hobj,a1,l		; (until the head object exists)
	jrne	efpp_head
	mmtm	sp,a8,a9		; his head in the grip pose: row 039h part 15,
	move	a10,a8			;   measured off that frame's art
	movi	039h,a9
	calla	get_char_ani
	movk	15,a14
	calla	find_part_a14
	move	*a9,a9,l		; a9 ---> [x,y]
	move	*a9+,a2,w		; its middle x, facing space
	move	*a9,a3,w		; its top y
	mmfm	sp,a8,a9
	move	*a10(oflags),a0,w
	btst	b_fliph,a0
	jreq	epre_f
	neg	a2			; he faces left: mirrored
epre_f	move	*a10(oxpos),a1,w	; off his LIVE anchor - he is shaking
	add	a2,a1
	move	*a10(oypos),a0,w
	add	a0,a3
	addi	ERF_PRE_DOWN,a3		; sunk down behind him: only its tip shows
	callr	efp_grow		; a5 = 1:1, a7 = its base into the head
	add	a7,a3
	jruc	efpp_sc
efpp_head
	move	@erf_tick,a0,w		; the head's flame: on the head itself until
	cmpi	ERF_T_IMPACT,a0		;   it is in him (the lane's own keys are
	jrhs	efpp_lane		;   sparser than the head's and it trailed)
	callr	efp_grow		; a5 = its step, a7 = its base into the head
	move	@erf_hobj,a4,l
	move	*a4(oimg),a0,l
	move	*a0(isize),a1,w		; its drawn width / 2 = w * 080h / xstep
	sll	7,a1
	move	*a4(oscale),a6,w
	divu	a6,a1
	move	*a4(oxpos),a0,w
	add	a0,a1			; a1 = its middle
	move	*a4(oypos),a3,w
	add	a7,a3			; a3 = its top, a little into it
	move	@erf_tick,a0,w
	cmpi	ERF_T_THROW,a0
	jrhs	efs_thr
	cmpi	ERF_T_CATCH,a0
	jrlo	efs_rip
	callr	efp_hidetails		; in his palm: it stands still, no streak
	jruc	efpp_sc
*
* in flight - torn off to Ermac's hand, and thrown back - it STREAKS.  The
* main flame goes wider and shorter and leans back against the travel; the
* two tail flames sit further back and higher, each smaller, so the outline
* curves back off the head like a flame in the wind.  a4 = the sizes for
* this flight, a6 = px back for a flight TOWARD HIM (negated just below if
* he is to Ermac's right, and to begin with for the flight to Ermac).
*
efs_rip	movi	efs_rip_tab,a4
	movi	-ERF_STREAK_LEAN,a6	; flying to Ermac: back is toward the victim
	jruc	efs_go
efs_thr	movi	efs_thr_tab,a4
	movi	ERF_STREAK_LEAN,a6	; thrown at him: back is toward Ermac
efs_go	move	@erf_ex,a0,w
	move	@erf_vx,a2,w
	cmp	a2,a0
	jrge	efs_r			; he is left of Ermac: back is +x
	neg	a6
efs_r	mmtm	sp,a1,a3,a6
	add	a6,a1
	move	*a4+,a5,w
	move	*a4+,a2,w
	callr	efpp_sc2
	mmfm	sp,a1,a3,a6
	move	*a13(p_store5),a0,l
	jreq	efs_x
	mmtm	sp,a1,a3,a6,a8
	move	a0,a8
	move	a6,a0
	sll	1,a0
	add	a6,a0			; 3 x lean back
	add	a0,a1
	subi	ERF_TAIL1_UP,a3
	move	*a4+,a5,w
	move	a5,a2
	callr	efpp_sc2
	mmfm	sp,a1,a3,a6,a8
	move	*a13(p_store6),a0,l
	jreq	efs_x
	push	a8
	move	a0,a8
	move	a6,a0
	sll	1,a0
	add	a6,a0
	sll	1,a0			; 6 x lean back
	add	a0,a1
	subi	ERF_TAIL2_UP,a3
	move	*a4+,a5,w
	move	a5,a2
	callr	efpp_sc2
	pull	a8
efs_x	rets

*		main x step, main y step, tail 1 step, tail 2 step
efs_thr_tab	.word	ERF_STREAK_XS,ERF_STREAK_YS,ERF_TAIL1_S,ERF_TAIL2_S
efs_rip_tab	.word	ERF_RIPSTK_XS,ERF_RIPSTK_YS,ERF_RIPT1_S,ERF_RIPT2_S

*
* efp_hidetails - the tail flames off the plane (set outright: a streak
* re-places them from scratch).  a0, a2.
*
efp_hidetails
	movi	ERF_NOWHERE*2,a0
	sll	16,a0
	move	*a13(p_store5),a2,l
	jreq	eht_x
	move	a0,*a2(oyval),l
	move	*a13(p_store6),a2,l
	jreq	eht_x
	move	a0,*a2(oyval),l
eht_x	rets
efpp_lane
	subi	ERF_T_RIP,a0
	jrlt	efpp_x
	cmpi	ERF_HEAD_TICKS,a0
	jrlo	efpp_row
	movi	ERF_HEAD_TICKS-1,a0
efpp_row
	sll	5,a0
	addi	erf_flame_path,a0
	move	*a0+,a2,w		; x in front of Ermac
	move	*a0,a4,w		; y below him
	move	@erf_vx,a1,w		; ...mapped through the live anchors, as
	move	@erf_ex,a3,w		;   ehp_xy_row maps the head
	sub	a3,a1
	mpys	a2,a1
	movi	ERF_DIST,a5
	divs	a5,a1
	add	a3,a1			; a1 = X
	move	@erf_vy,a3,w
	move	@erf_ey,a6,w
	sub	a6,a3
	mpys	a2,a3
	divs	a5,a3
	add	a6,a3
	add	a4,a3			; a3 = Y
	jruc	efpp_size
efpp_size
	movi	0100h,a5		; 1:1
efpp_sc	move	a5,a2			; y step the same as x
efpp_sc2				; a5 = x step, a2 = y step
	move	a2,a0
	sll	16,a0
	or	a5,a0
	move	a0,*a8(oscale),l	; [y:x]
*
* anchor -> top left, scaled
*
	move	*a8(oimg),a0,l
	move	*a0(ianioffx),a7,w
	sll	8,a7
	divu	a5,a7			; anix * 0100h / step (odd register)
	sub	a7,a1
	move	*a0(ianioffy),a7,w
	sll	8,a7
	divu	a2,a7
	sub	a7,a3
	sll	16,a1
	move	a1,*a8(oxval),l
	sll	16,a3
	move	a3,*a8(oyval),l
efpp_x	rets

*
* efp_grow - from when he holds it up (ERF_T_FLAME) to the throw the
* flame grows from 1:1 to ERF_FLAME_BIG and its base sinks ERF_FLAME_SINK px
* further down the face, so it swallows more of the head before he throws;
* it stays that way through the throw.  -> a5 = the step, a7 = px its base
* sits below the head's top.  Odd registers: the 32-bit MPYS/DIVS forms.
*
efp_grow
	move	@erf_tick,a7,w
	subi	ERF_T_FLAME,a7
	jrge	efg_lo
	clr	a7
efg_lo	cmpi	ERF_T_THROW-ERF_T_FLAME,a7
	jrls	efg_hi
	movi	ERF_T_THROW-ERF_T_FLAME,a7
efg_hi	move	a7,a5
	movi	0100h-ERF_FLAME_BIG,a6
	mpys	a6,a5
	movi	ERF_T_THROW-ERF_T_FLAME,a6
	divs	a6,a5
	neg	a5
	addi	0100h,a5		; a5 = 0100h .. ERF_FLAME_BIG
	movi	ERF_FLAME_SINK,a6
	mpys	a6,a7
	movi	ERF_T_THROW-ERF_T_FLAME,a6
	divs	a6,a7
	addi	ERF_FLAME_ONHEAD,a7	; a7 = ONHEAD .. ONHEAD+SINK
	rets

	.endif

**************************************************************************
*											     *
*  erf_victim - the man, in his own process (takeover_him).		     *
*											     *
*  p_store1 = his oxval where he stood (every shake is measured from it, so  *
*  it cannot drift); p_store2 = the legs' oxval once there are legs.	     *
*  a10 = the legs object from IMPACT on.					     *
*											     *
**************************************************************************
erf_victim
	calla	stop_me
	calla	face_opponent
	move	*a8(oxval),a0,l
	move	a0,*a13(p_store1),l
	clr	a10
*
* stands in his daze until the arm comes out at him
*
	movi	ERF_T_GRIP,a0
	jsrp	ev_until
	movi	039h,a9			; the arm is out: he sways INTO it and holds -
	calla	get_char_ani		;   his dizzy frame whose head leans furthest
	movk	14,a14			;   toward Ermac (row 039h part 14)
	calla	find_part_a14
	calla	do_next_a9_frame
	calla	rsnd_wasted_voice	; he cries out as it takes hold of his head -
					;   sent FIRST, so the rumble cannot crowd it out
	tsound	0a3h			; the rumble Ermac's slam lifts on
	tsound	010bh			; ...and Shao Kahn's shockwave: his arm is
					;   all the way out (NJSCORPSWIPE3)
*
* GRIP: he shakes in it
*
	clr	a11
ev_grip	addk	1,a11
	movk	ERF_GRIP_JIT,a0
	move	a11,a1
	movk	ERF_SHAKE_T,a2
	divu	a2,a1			; a1 = half-steps so far (odd register: 32-bit)
	btst	0,a1
	jrne	evg_r
	clr	a0			; ...back where he stood
evg_r	move	*a13(p_store1),a1,l
	sll	16,a0
	add	a1,a0
	move	a0,*a8(oxval),l
	sleep	1
	move	@erf_tick,a0,w
	cmpi	ERF_T_RIP,a0
	jrlo	ev_grip
*
* RIP: off comes the head (erf_head_proc, started by the director on this
* tick).  The rest of him stands, headless - frame 1 of his own decap fall.
*
	move	*a13(p_store1),a0,l
	move	a0,*a8(oxval),l		; back where he stood
	calla	rsnd_death_voice	; his scream as it comes off - first in, so it
					;   has a channel (it was last and went unheard)
	tsound	09ah			; rip head off - Reptile's (do_tongue)
	movi	034h,a0
	calla	triple_sound2		; the crowd goes "ooo" (triple_sndtab2 34h -
					;   triple_sound2, NOT triple_sound: 34h in
					;   the first table is a wasted-voice grunt)
	calla	change_to_bloody_pal
	movi	03ch,a9
	calla	get_char_ani
	calla	do_next_a9_frame	; headless, standing

	move	a8,a11
	movi	00ah,a0
	calla	create_blood_proc	; decaped_blood - the geyser off the neck
*					; (no headrip_neck_blood drips here: on top of
*					;   the geyser it read as too much - playtest)

	.if	erflift
*
* lift: nothing comes back at him.  He stands headless while the head goes up,
* then goes down the way every decapitated man does (decap_fall, MKCANNED):
* to his knees, a wobble, over.
*
	movi	03ch,a9
	calla	get_char_ani		; (the blood calls owe a9 nothing)
	calla	do_next_a9_frame
	sleep	ERF_LIFT_STAND
	movk	6,a0
	jsrp	mframew			; fall to his knees
	movi	000050005h,a11
	calla	shake_a11
	movk	10,a0
	jsrp	mframew			; wobble
	movk	6,a0
	jsrp	mframew			; over
	movi	000050005h,a11
	calla	shake_a11
	calla	rsnd_ground
	movk	1,a0
	move	a0,@erf_landed,w	; Ermac's cue: hold a moment, then it is over
	jauc	wait_forever
	.endif

	movi	ERF_T_THROW,a0
	jsrp	ev_until
	tsound	004h			; he throws it: the DEEP whoosh
	movi	ERF_T_IMPACT,a0
	jsrp	ev_until
*
* IMPACT: the head is in him.  Legs: their own object where he stands.
*
	tsound	019h			; it hits him: the BIG smack the heavy kicks
					;   land with - sent first, so it has a channel
	tsound	096h			; ...into his guts: "guy getting
					;   split in half" - Kung Lao's hat split, a wet
					;   tear (the MK1 uppercut smack 01bh is gone,
					;   the user's call)
	movi	000020002h,a11
	calla	shake_a11

	push	a8
	movi	039h,a9
	calla	get_char_ani
	movk	6,a14
	calla	find_part_a14		; a9 = standing legz
	calla	gmo_proc		; a8 = the legs
	move	a8,a10
	pull	a8
	move	a10,a10
	jreq	ev_torso		; object pool empty: the torso still plays
	move	*a8(ochar),*a10(ochar),w
	move	*a8(oid),*a10(oid),w
	move	*a8(oflags2),*a10(oflags2),w
	push	a8
	move	a10,a8
	callr	ev_bloody		; the legs in his cut-up colours
	pull	a8
	move	a10,a0			; a0 = the legs
	calla	match_ani_points	; same anchor, same facing as him
	movi	ERF_LEGS_Z,a0
	move	a0,*a10(ozval),l
	push	a8
	move	a10,a8
	calla	insobja8
	pull	a8
	move	*a10(oxval),a0,l
	move	a0,*a13(p_store2),l

	move	a10,a11
	movk	7,a0
	calla	create_blood_proc	; torso_ripped_blood, off the stump
	movi	019h,a0
	calla	create_blood_proc	; sai_waist_blood - the slice spray at the cut
*
* ...and he is the torso: the top half of the same frame, in front of the
* head and the legs.
*
ev_torso
	movi	039h,a9
	calla	get_char_ani
	movk	10,a14
	calla	find_part_a14		; a9 = the headless torso, standing
	calla	do_next_a9_frame
	move	a8,a0
	movi	ERF_TORSO_Z,a1
	calla	rain_obj_set_z
*
* ...and it BURSTS with the head inside it: the body pop (r_shocker_pop) -
* BOOM, the white flash, the torso gone, kiss_explode's blood and the chunk
* shower - on the torso only, and ONE of UMK3's exploding-body splats
* (ermac_splat_one) running on after it.
*
*
* the head is in him: both halves shake with it a moment first...
*
	clr	a11
ev_hit	addk	1,a11
	movk	ERF_HIT_JIT,a0
	move	a11,a1
	movk	ERF_SHAKE_T,a2
	divu	a2,a1			; a1 = half-steps (odd register: 32-bit)
	btst	0,a1
	jrne	evh_r
	clr	a0
evh_r	sll	16,a0
	move	*a13(p_store1),a1,l
	add	a0,a1
	move	a1,*a8(oxval),l
	move	a10,a10
	jreq	evh_s
	move	*a13(p_store2),a1,l
	add	a0,a1
	move	a1,*a10(oxval),l
evh_s	sleep	1
	move	@erf_tick,a0,w
	cmpi	ERF_T_PULL,a0		; the head's authored hold in him
	jrlo	ev_hit
	move	*a13(p_store1),a0,l
	move	a0,*a8(oxval),l
	move	a10,a10
	jreq	evh_x
	move	*a13(p_store2),a0,l
	move	a0,*a10(oxval),l
evh_x
*
* ...then BOOM: ONE of the teleport slam fatality's BLDXPD bursts
* (ermac_splat_one), on the middle of the torso.
*
	tsound	0a4h			; BOOM !!!
	mmtm	sp,a10,a11
	move	a8,a11
	movi	erm_tksf_splashdy,a10
	create	pid_blood,erf_splat_top
	mmfm	sp,a10,a11
	jsrp	white_flash
	move	a8,a0
	calla	set_inviso		; the torso is gone
	mmtm	sp,a9,a10,a11		; explode loads its gravity into a10 - which
	calla	erf_pop_chunks		;   is the legs - and spends a6/a11: keep them
	mmfm	sp,a9,a10,a11		; ...in pieces
*
* the legs stand through it, then wobble and fall
*
	move	a10,a10
	jreq	ev_done
	move	a10,a8
	movi	039h,a9
	calla	get_char_ani
	movk	7,a14
	calla	find_part_a14		; a9 = the buckle, after the legz
	create	pid_head,erf_legs_proc	; a8 = the legs, a9 = their lane
ev_done	jauc	wait_forever

*
* ev_until - sleep until @erf_tick reaches a0.  It sleeps, so it is a PROCESS
* subroutine (jsrp/retp): a callr's return address is on the system stack and
* does not survive the dispatcher.  The target waits in p_store3 because a0
* does not survive a sleep either.
*
ev_until
	move	a0,*a13(p_store3),w
evu_lp	move	@erf_tick,a0,w
	move	*a13(p_store3),a1,w
	cmp	a1,a0
	jrhs	evu_x
	sleep	1
	jruc	evu_lp
evu_x	retp

*
* ev_bloody - a8 to its bloody palette, run as Ermac (a8_to_bloody_pal's
* shape, MKDEATH.ASM): change_to_bloody_pal must not mark the victim's own
* process.
*
ev_bloody
	push	a13
	move	*a13(p_otherproc),a13,l
	calla	change_to_bloody_pal
	pull	a13
	rets

*
* erf_pool_place - jc_headhole_spill_proc docks its pool on the LAST piece of
* the body it is handed: right for Cage's victim (the head hole), wrong for
* these legs, where it landed under the feet and below the floor.  So it is
* moved here, once (ani_flag keeps the anchor from then on): its anchor onto
* the CUT - row 039h part 13, measured by the generator off his last lying-
* legs frame (the red stump's x, the lowest pixel's y) - its top just above
* that floor line.  It copied the legs' facing, so it spreads from there AWAY
* from the body.  a0 = the pool, a8 = the legs.  No sleep.
*
erf_pool_place
	mmtm	sp,a0,a8
	movi	039h,a9
	calla	get_char_ani		; the legs carry his ochar
	movk	13,a14
	calla	find_part_a14
	move	*a9,a9,l		; a9 ---> [x,y]: the cut's x, the floor's y
	mmfm	sp,a0,a8
	move	*a9+,a3,w		; x, in facing space
	move	*a9,a1,w		; y
	move	*a8(oflags),a6,w
	btst	b_fliph,a6
	jreq	epp_f
	neg	a3			; he faces left: mirrored
epp_f	move	*a8(oxpos),a6,w
	add	a6,a3			; the cut, in the world
	move	*a8(oypos),a6,w
	add	a6,a1
	subi	ERF_POOL_UP,a1		; its top: just above the floor line
	move	*a0(oimg),a4,l
	move	*a4(ianioffx),a2,w
	move	*a0(oflags),a6,w
	btst	b_fliph,a6
	jreq	epp_nf
	move	*a4(isize),a6,w		; flipped: sizex - anix
	neg	a2
	add	a6,a2
epp_nf	sub	a2,a3			; its anchor on the cut
	sll	16,a3
	move	a3,*a0(oxval),l
	sll	16,a1
	move	a1,*a0(oyval),l		; (oyval/oypos = the art's top)
	rets

**************************************************************************
*											     *
*  erf_legs_proc - the cut legs, r_sai_split's beats: buckle to the knees,  *
*  wobble there, then over onto the floor.  a8 = the legs, a9 = row 039h    *
*  part 7.										     *
*											     *
**************************************************************************
erf_legs_proc
	sleep	ERF_LEG_STAND
elp_down
	calla	do_next_a9_frame
	jreq	elp_knees
	sleep	ERF_LEG_BUCKLE
	jruc	elp_down
elp_knees
elp_wobble
	sleep	ERF_LEG_WOBBLE
	calla	do_next_a9_frame
	jrne	elp_wobble
elp_fall
	calla	do_next_a9_frame
	jreq	elp_flat
	sleep	ERF_LEG_FALL
	jruc	elp_fall
elp_flat
	movi	000020002h,a11		; the one thud the camera feels
	calla	shake_a11
	calla	rsnd_ground
*
* ...and blood pools out of the cut, the headhole fatality's spill
* (SPILL1-13).  It docks on the LAST piece of the body it is handed - for
* Cage's victim the head hole, for these legs the cut waist.
*
	tsound	073h			; splish (blood_random_splish_sound's first)
	create	pid_head,jc_headhole_spill_proc
	move	a0,a0
	jreq	elp_x
	move	a8,*a0(pa10),l		; the legs = the spill's anchor
	move	a0,a10			; (a10 survives the sleep)
	sleep	1			; it has built its pool and slept: its saved
	move	*a10(pa8),a0,l		;   a8 IS the pool - lift it over the chunk
	push	a0
	movi	ERF_POOL_Z,a1		;   pile (ozpos 1) that lies round the legs,
	calla	rain_obj_set_z		;   or it spreads unseen beneath it
	pull	a0
	callr	erf_pool_place		; ...and put it at the CUT
	movk	1,a0
	move	a0,@erf_landed,w	; Ermac may let go of his pose now
	sleep	010h			; ...splishing until it has spread (13
	tsound	074h			;   frames at 5 ticks = 65): the three
	sleep	010h			;   splishes blood_random_splish_sound
	tsound	075h			;   picks from, in turn
	sleep	010h
	tsound	073h
	sleep	010h
	tsound	074h
elp_x
	movk	1,a0
	move	a0,@erf_landed,w
	die				; the object stays; its ram is gmo_proc's

;>>>WAX BEGIN ermac_headrip
; GENERATED by tools/ermac_headrip_wax_import.py from data/ERMACFAT2.WAX -
; edit the project in IMGTOOL and re-run the tool, never this block.
ERF_T_GRIP	.set	32	; victim starts to shake
ERF_T_RIP	.set	77	; head comes off
ERF_T_CATCH	.set	89	; it reaches Ermac's hand
ERF_T_THROW	.set	183	; he throws it back
ERF_T_FLAME	.set	89	; the soul flame lights (FLAME_POSE, else the catch)
ERF_T_LIFT	.set	129	; lift (erflift): he has looked at it on LOOK_POSE - up it goes
ERF_T_IMPACT	.set	195	; head is in the torso: legs and torso part
ERF_T_PULL	.set	255	; the head's hold in him is over: he BURSTS
ERF_T_END	.set	261	; Ermac's lane is done
ERF_DIST	.set	245	; px the WAX puts the victim in front of Ermac
ERF_HEAD_FRAME	.set	5	; NJHEAD6: entry of his head lane (03dh)
ERF_HEAD_TICKS	.set	178	; rows in erf_head_path
ERF_HIT_Y	.set	69	; px below his anchor the head goes in
ERF_HIT_YX	.set	0450000h	; [y:x] off HIS anchor where the head goes in -
				;   his middle, 69 px down (the head's height at the hit)
;
; Ermac's hold per frame of a_ermac_headrip (MKNJ.ASM), 0-terminated
erf_holds
	.word	24		; t=  0 NJSCORPSWIPE9
	.word	4		; t= 24 NJSCORPTHRO2
	.word	4		; t= 28 NJSCORPTHRO3
	.word	45		; t= 32 NJSCORPSWIPE3
	.word	8		; t= 77 NJSCORPTHRO3
	.word	4		; t= 85 NJSCORPTHRO2
	.word	40		; t= 89 NJSCORPSWIPE8
	.word	6		; t=129 NJSCORPTHRO1
	.word	20		; t=135 NJSUBDETHBLO1
	.word	28		; t=155 NJSCORPSWIPE1
	.word	6		; t=183 NJSCORPSWIPE2
	.word	4		; t=189 NJSUBDETHBLO5
	.word	62		; t=193 NJSCORPSWIPE4
	.word	8		; t=255 NJSCORPTHRO3
	.word	4		; t=263 NJSCORPTHRO2
	.word	24		; t=267 NJSCORPSWIPE9
	.word	0
;
; The head's anchor every tick from ERF_T_RIP to ERF_T_PULL: x px in
; FRONT of Ermac, y px BELOW him, as authored with the victim ERF_DIST
; away (erf_head_proc maps it through the live anchors).  Held on each WAX
; keyframe for its authored hold.  After the pull it is thrown, not authored.
erf_head_path
	.word	218,14		; t=77
	.word	218,14		; t=78
	.word	190,25		; t=79
	.word	190,25		; t=80
	.word	161,36		; t=81
	.word	161,36		; t=82
	.word	134,44		; t=83
	.word	134,44		; t=84
	.word	107,53		; t=85
	.word	107,53		; t=86
	.word	46,74		; t=87
	.word	46,74		; t=88
	.word	-15,94		; t=89
	.word	-15,94		; t=90
	.word	-15,94		; t=91
	.word	-15,94		; t=92
	.word	-15,94		; t=93
	.word	-15,94		; t=94
	.word	-15,94		; t=95
	.word	-15,94		; t=96
	.word	-15,94		; t=97
	.word	-15,94		; t=98
	.word	-15,94		; t=99
	.word	-15,94		; t=100
	.word	-15,94		; t=101
	.word	-15,94		; t=102
	.word	-15,94		; t=103
	.word	-15,94		; t=104
	.word	-15,94		; t=105
	.word	-15,94		; t=106
	.word	-15,94		; t=107
	.word	-15,94		; t=108
	.word	-15,94		; t=109
	.word	-15,94		; t=110
	.word	-15,94		; t=111
	.word	-15,94		; t=112
	.word	-15,94		; t=113
	.word	-15,94		; t=114
	.word	-15,94		; t=115
	.word	-15,94		; t=116
	.word	-15,94		; t=117
	.word	-15,94		; t=118
	.word	-15,94		; t=119
	.word	-15,94		; t=120
	.word	-15,94		; t=121
	.word	-15,94		; t=122
	.word	-15,94		; t=123
	.word	-15,94		; t=124
	.word	-15,94		; t=125
	.word	-15,94		; t=126
	.word	-15,94		; t=127
	.word	-15,94		; t=128
	.word	-24,82		; t=129
	.word	-24,82		; t=130
	.word	-24,82		; t=131
	.word	-24,82		; t=132
	.word	-24,82		; t=133
	.word	-24,82		; t=134
	.word	-41,26		; t=135
	.word	-41,26		; t=136
	.word	-41,26		; t=137
	.word	-41,26		; t=138
	.word	-41,26		; t=139
	.word	-41,26		; t=140
	.word	-41,26		; t=141
	.word	-41,26		; t=142
	.word	-41,26		; t=143
	.word	-41,26		; t=144
	.word	-41,26		; t=145
	.word	-41,26		; t=146
	.word	-41,26		; t=147
	.word	-41,26		; t=148
	.word	-41,26		; t=149
	.word	-41,26		; t=150
	.word	-41,26		; t=151
	.word	-41,26		; t=152
	.word	-41,26		; t=153
	.word	-41,26		; t=154
	.word	-57,40		; t=155
	.word	-57,40		; t=156
	.word	-57,40		; t=157
	.word	-57,40		; t=158
	.word	-57,40		; t=159
	.word	-57,40		; t=160
	.word	-57,40		; t=161
	.word	-57,40		; t=162
	.word	-57,40		; t=163
	.word	-57,40		; t=164
	.word	-57,40		; t=165
	.word	-57,40		; t=166
	.word	-57,40		; t=167
	.word	-57,40		; t=168
	.word	-57,40		; t=169
	.word	-57,40		; t=170
	.word	-57,40		; t=171
	.word	-57,40		; t=172
	.word	-57,40		; t=173
	.word	-57,40		; t=174
	.word	-57,40		; t=175
	.word	-57,40		; t=176
	.word	-57,40		; t=177
	.word	-57,40		; t=178
	.word	-57,40		; t=179
	.word	-57,40		; t=180
	.word	-57,40		; t=181
	.word	-57,40		; t=182
	.word	-12,58		; t=183
	.word	-12,58		; t=184
	.word	50,54		; t=185
	.word	50,54		; t=186
	.word	111,49		; t=187
	.word	111,49		; t=188
	.word	156,52		; t=189
	.word	156,52		; t=190
	.word	202,55		; t=191
	.word	202,55		; t=192
	.word	236,62		; t=193
	.word	236,62		; t=194
	.word	270,69		; t=195
	.word	270,69		; t=196
	.word	270,69		; t=197
	.word	270,69		; t=198
	.word	270,69		; t=199
	.word	270,69		; t=200
	.word	270,69		; t=201
	.word	270,69		; t=202
	.word	270,69		; t=203
	.word	270,69		; t=204
	.word	270,69		; t=205
	.word	270,69		; t=206
	.word	270,69		; t=207
	.word	270,69		; t=208
	.word	270,69		; t=209
	.word	270,69		; t=210
	.word	270,69		; t=211
	.word	270,69		; t=212
	.word	270,69		; t=213
	.word	270,69		; t=214
	.word	270,69		; t=215
	.word	270,69		; t=216
	.word	270,69		; t=217
	.word	270,69		; t=218
	.word	270,69		; t=219
	.word	270,69		; t=220
	.word	270,69		; t=221
	.word	270,69		; t=222
	.word	270,69		; t=223
	.word	270,69		; t=224
	.word	270,69		; t=225
	.word	270,69		; t=226
	.word	270,69		; t=227
	.word	270,69		; t=228
	.word	270,69		; t=229
	.word	270,69		; t=230
	.word	270,69		; t=231
	.word	270,69		; t=232
	.word	270,69		; t=233
	.word	270,69		; t=234
	.word	270,69		; t=235
	.word	270,69		; t=236
	.word	270,69		; t=237
	.word	270,69		; t=238
	.word	270,69		; t=239
	.word	270,69		; t=240
	.word	270,69		; t=241
	.word	270,69		; t=242
	.word	270,69		; t=243
	.word	270,69		; t=244
	.word	270,69		; t=245
	.word	270,69		; t=246
	.word	270,69		; t=247
	.word	270,69		; t=248
	.word	270,69		; t=249
	.word	270,69		; t=250
	.word	270,69		; t=251
	.word	270,69		; t=252
	.word	270,69		; t=253
	.word	270,69		; t=254
;
; The green flame's anchor (its BASE: the FlameB records' anipoint is at
; their bottom) every tick from ERF_T_RIP, the project's flame lane on the
; same clock and through the same anchors as the head.
erf_flame_path
	.word	213,13		; t=77
	.word	213,13		; t=78
	.word	186,23		; t=79
	.word	186,23		; t=80
	.word	158,33		; t=81
	.word	158,33		; t=82
	.word	130,42		; t=83
	.word	130,42		; t=84
	.word	101,51		; t=85
	.word	101,51		; t=86
	.word	40,70		; t=87
	.word	40,70		; t=88
	.word	-20,89		; t=89
	.word	-20,89		; t=90
	.word	-20,89		; t=91
	.word	-20,89		; t=92
	.word	-20,89		; t=93
	.word	-20,89		; t=94
	.word	-20,89		; t=95
	.word	-20,89		; t=96
	.word	-20,89		; t=97
	.word	-20,89		; t=98
	.word	-20,89		; t=99
	.word	-20,89		; t=100
	.word	-20,89		; t=101
	.word	-20,89		; t=102
	.word	-20,89		; t=103
	.word	-20,89		; t=104
	.word	-20,89		; t=105
	.word	-20,89		; t=106
	.word	-20,89		; t=107
	.word	-20,89		; t=108
	.word	-20,89		; t=109
	.word	-20,89		; t=110
	.word	-20,89		; t=111
	.word	-20,89		; t=112
	.word	-20,89		; t=113
	.word	-20,89		; t=114
	.word	-20,89		; t=115
	.word	-20,89		; t=116
	.word	-20,89		; t=117
	.word	-20,89		; t=118
	.word	-20,89		; t=119
	.word	-20,89		; t=120
	.word	-20,89		; t=121
	.word	-20,89		; t=122
	.word	-20,89		; t=123
	.word	-20,89		; t=124
	.word	-20,89		; t=125
	.word	-20,89		; t=126
	.word	-20,89		; t=127
	.word	-20,89		; t=128
	.word	-28,82		; t=129
	.word	-28,82		; t=130
	.word	-28,82		; t=131
	.word	-28,82		; t=132
	.word	-28,82		; t=133
	.word	-28,82		; t=134
	.word	-45,23		; t=135
	.word	-45,23		; t=136
	.word	-45,23		; t=137
	.word	-45,23		; t=138
	.word	-45,23		; t=139
	.word	-45,23		; t=140
	.word	-45,23		; t=141
	.word	-45,23		; t=142
	.word	-45,23		; t=143
	.word	-45,23		; t=144
	.word	-45,23		; t=145
	.word	-45,23		; t=146
	.word	-45,23		; t=147
	.word	-45,23		; t=148
	.word	-45,23		; t=149
	.word	-45,23		; t=150
	.word	-45,23		; t=151
	.word	-45,23		; t=152
	.word	-45,23		; t=153
	.word	-45,23		; t=154
	.word	-62,39		; t=155
	.word	-62,39		; t=156
	.word	-62,39		; t=157
	.word	-62,39		; t=158
	.word	-62,39		; t=159
	.word	-62,39		; t=160
	.word	-62,39		; t=161
	.word	-62,39		; t=162
	.word	-62,39		; t=163
	.word	-62,39		; t=164
	.word	-62,39		; t=165
	.word	-62,39		; t=166
	.word	-62,39		; t=167
	.word	-62,39		; t=168
	.word	-62,39		; t=169
	.word	-62,39		; t=170
	.word	-62,39		; t=171
	.word	-62,39		; t=172
	.word	-62,39		; t=173
	.word	-62,39		; t=174
	.word	-62,39		; t=175
	.word	-62,39		; t=176
	.word	-62,39		; t=177
	.word	-62,39		; t=178
	.word	-62,39		; t=179
	.word	-62,39		; t=180
	.word	-62,39		; t=181
	.word	-62,39		; t=182
	.word	-16,55		; t=183
	.word	-16,55		; t=184
	.word	25,52		; t=185
	.word	25,52		; t=186
	.word	67,49		; t=187
	.word	67,49		; t=188
	.word	108,46		; t=189
	.word	108,46		; t=190
	.word	153,48		; t=191
	.word	153,48		; t=192
	.word	198,51		; t=193
	.word	198,51		; t=194
	.word	198,51		; t=195
	.word	198,51		; t=196
	.word	197,54		; t=197
	.word	197,54		; t=198
	.word	197,54		; t=199
	.word	197,54		; t=200
	.word	246,12		; t=201
	.word	246,12		; t=202
	.word	246,12		; t=203
	.word	246,12		; t=204
	.word	246,12		; t=205
	.word	246,12		; t=206
	.word	246,12		; t=207
	.word	246,12		; t=208
	.word	246,12		; t=209
	.word	246,12		; t=210
	.word	246,12		; t=211
	.word	246,12		; t=212
	.word	246,12		; t=213
	.word	246,12		; t=214
	.word	246,12		; t=215
	.word	246,12		; t=216
	.word	246,12		; t=217
	.word	246,12		; t=218
	.word	246,12		; t=219
	.word	246,12		; t=220
	.word	246,12		; t=221
	.word	246,12		; t=222
	.word	246,12		; t=223
	.word	246,12		; t=224
	.word	246,12		; t=225
	.word	246,12		; t=226
	.word	246,12		; t=227
	.word	246,12		; t=228
	.word	246,12		; t=229
	.word	246,12		; t=230
	.word	246,12		; t=231
	.word	246,12		; t=232
	.word	246,12		; t=233
	.word	246,12		; t=234
	.word	246,12		; t=235
	.word	246,12		; t=236
	.word	246,12		; t=237
	.word	246,12		; t=238
	.word	246,12		; t=239
	.word	246,12		; t=240
	.word	246,12		; t=241
	.word	246,12		; t=242
	.word	246,12		; t=243
	.word	246,12		; t=244
	.word	246,12		; t=245
	.word	246,12		; t=246
	.word	246,12		; t=247
	.word	246,12		; t=248
	.word	246,12		; t=249
	.word	246,12		; t=250
	.word	246,12		; t=251
	.word	246,12		; t=252
	.word	246,12		; t=253
	.word	246,12		; t=254
;
; ERF_FLAME_P - MKBGANI.IMG's FLAME1_P verbatim: the torch flame recoloured
; green.  The records name the orange FLAME_P; the flame is swpal'd onto this.
ERF_FLAME_P
	.word	8
	.word	00000H,02FB9H,027B6H,01791H,01390H,00F4DH,00F2BH,00F0AH
;<<<WAX END ermac_headrip

	.end
