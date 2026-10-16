**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
* 											     *
*  module: arenakin.asm --- Kintaro in the Kahn's Arena stands	     *
* 											     *
*  arena_goro_proc and everything it drives: the walk-in along the	     *
*  stands, the idle, and the soul-escape leap.  Moved out of BGND.ASM,   *
*  which GSPA can no longer assemble at its size (see the TWRBACK note   *
*  there).  BGND.ASM keeps arena_calla, which creates this process, and  *
*  a_arena_goro_idle, whose gorostd* frames are in mkbgani.tbl - one	     *
*  copy of that table stays in BGND.ASM, it is not included twice.	     *
*											     *
**************************************************************************
	.file	"arenakin.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	imgtbl.glo
	.include	gorowalk.tbl		; the walk-in (data/GOROWALK.LOD)
	.if	soulesc
	.include	smtiger.tbl		; Kintaro's leap out of the Kahn's Arena
					; stands (data/SMTIGER.LOD, MKSOULS.ASM)
	.endif

	.globl	arena_goro_proc		; BGND.ASM arena_calla creates it
	.globl	a_arena_goro_idle	; BGND.ASM - frames in mkbgani.tbl

	.text

arena_goro_home_x	.set	0118h
arena_goro_watch_r	.set	0168h		; stop x walking right (past Sonya)
arena_goro_watch_l	.set	0040h		; stop x walking left (past Kano)
arena_goro_edge_l	.set	0060h		; visible-frame limits for the multipart rig
arena_goro_edge_r	.set	0208h
arena_goro_edge_far_l	.set	-0040h		; edge_l once parked left (< watch_l)
arena_goro_follow	.set	0018h		; parked on a side: step after a scroll
						; that has pushed him this far back in
						; from his watch spot
arena_goro_deadzone	.set	0006h
arena_goro_step		.set	0010h		; slower 16 px stride from the original walk-in
arena_goro_walk_wait	.set	0005h
arena_goro_idle_y	.set	0049h
arena_goro_bre1		.set	0028h		; IMGTOOL bre ticks 8,1,5,1 scaled for 60 Hz
arena_goro_bre2		.set	0005h
arena_goro_bre3		.set	0019h
arena_goro_bre4		.set	0005h
arena_goro_step_snd	.set	00b2h		; Goro quake thud, one per foot plant
arena_goro_growl_snd	.set	000ach		; Goro growl, once as he starts a walk-in
arena_goro_leap_rate	.set	0002h		; ticks per SMTIGERJUMP frame - the
						; crouch and spring is four frames, so
						; it only reads as a spring if it is
						; quick (was 5, which ambled)
arena_goro_leap_dy	.set	0032h		; px he rises per frame.  FOUR frames, so
						; this is the whole leap: 200 px, which
						; takes him off the top of a 254-line
						; screen from anywhere in the stands.
						; He has to LEAVE, not just clear the
						; wall - the fight-size Kintaro comes
						; down the moment he is gone, and the
						; two of them must never be on screen
						; at once

arena_goro_proc
	movi	a_arena_goro_idle,a9
	calla	gmo_proc
	move	a8,a8
	jreq	argoro9
	calla	clear_shadow_bit		; background prop only, no fighter shadow

	callr	arena_goro_home_pos_x
	move	a0,*a8(oxpos),w
	callr	arena_goro_set_idle_y
	callr	arena_goro_use_idle_pal
	callr	arena_goro_clear_flip
	movi	-1,a4			; background prop, locked to clear arena lane
	move	a4,*a8(ozpos),w

	move	a8,a0
	movi	baklst8,b4			; dedicated arena prop layer
	calla	insobj_v
	clr	a11				; a11 = parked side: 0 = home (no
						; follow), 1 = left (watch_l), 2 = right
argoro4
	.if	soulesc
	move	@f_soul_kintaro,a0,w	; Shang is face down - go (MKSOULS.ASM)
	cmpi	1,a0
	jrne	argoro5
	jsrp	arena_goro_leap		; it sleeps - process subroutine, not callr
argoro_parked
	sleep	01000h			; he is out of the stands for good
	jruc	argoro_parked
argoro5
	.endif
	callr	arena_goro_screen_x
	cmpi	1,a11
	jreq	argoro_parked_l
	cmpi	2,a11
	jreq	argoro_parked_r
	cmpi	arena_goro_edge_l,a0
	jrlt	argoro_walk_r
	cmpi	arena_goro_edge_r,a0
	jrgt	argoro_walk_l
argoro_watch
	jsrp	arena_goro_idle		; once in frame, stop and watch the match
	jruc	argoro4

argoro_parked_l
	cmpi	arena_goro_edge_far_l,a0
	jrlt	argoro_walk_r		; camera went right - back to watch_r
	subi	arena_goro_watch_l,a0	; a0 = how far the camera has pushed him
	cmpi	arena_goro_follow,a0	; right of his spot past Kano
	jrle	argoro_watch
argoro_walk_l
	movk	1,a11
	jsrp	arena_goro_walk_to_watch
	jruc	argoro4

argoro_parked_r
	cmpi	arena_goro_edge_r,a0
	jrgt	argoro_walk_l		; camera went left - over to watch_l
	movi	arena_goro_watch_r,a1
	sub	a0,a1			; a1 = how far the camera has pushed him
	cmpi	arena_goro_follow,a1	; left of his spot past Sonya
	jrle	argoro_watch
argoro_walk_r
	movk	2,a11
	jsrp	arena_goro_walk_to_watch
	jruc	argoro4

argoro9	die

arena_goro_home_pos_x
	move	@worldtlx2+16,a0,w
	addi	arena_goro_home_x,a0
	rets

arena_goro_watch_pos_x				; a10 = side, live camera
	move	@worldtlx2+16,a0,w
	cmpi	1,a10			; 1 = left, 2 = right
	jreq	argwp_l
	addi	arena_goro_watch_r,a0
	rets
argwp_l	addi	arena_goro_watch_l,a0
	rets

arena_goro_screen_x
	move	*a8(oxpos),a0,w
	move	@worldtlx2+16,a1,w
	sub	a1,a0
	rets

arena_goro_set_idle_y
	move	@worldtly+16,a4,w
	addi	arena_goro_idle_y,a4
	move	a4,*a8(oypos),w
	rets

arena_goro_clear_flip
	move	*a8(oflags),a0,w
	btst	b_fliph,a0
	jreq	argcf9
	calla	flip_multi
argcf9	rets

arena_goro_set_flip
	move	*a8(oflags),a0,w
	btst	b_fliph,a0
	jrne	argsf9
	calla	flip_multi
argsf9	rets

arena_goro_use_idle_pal
	movi	GOROBRE_p,a0
	jauc	swpal

arena_goro_use_walk_pal
	movi	KINTWLK_P,a0
	jauc	swpal

	.if	soulesc
**************************************************************************
*											     *
*  arena_goro_leap - Shang Tsung is face down and his souls are gone:	     *
*  Kintaro comes out of the stands.					     *
*											     *
*  Four frames at the prop's own scale (SMTIGERJUMP1-4, data/SMTIGER.LOD), *
*  rising far enough on each to take him off the TOP of the screen rather  *
*  than just over the arena wall, and then he is not there any more - what *
*  lands on the body is the fight-size Kintaro that soul_kintaro_finish    *
*  (MKSOULS.ASM) drops in, which is why this ends by handing the flag on   *
*  rather than walking him anywhere.  The set_inviso is the backstop: the  *
*  rise is what the player actually watches him leave on.		     *
*											     *
*  The leap art is the prop's own GOROBRE_p, swapped in below - he is the  *
*  SMALL Kintaro all the way up, and TIGERDK_P belongs to the one that	     *
*  comes back down.							     *
*											     *
*  jsrp, not callr, and it ends in retp: it sleeps between frames, and in   *
*  this file everything that sleeps is a PROCESS subroutine (compare	     *
*  arena_goro_idle and arena_goro_walk_to_watch).  Written as a plain	     *
*  callr it played its first frame and then parked in the stands forever,   *
*  because the return address a callr leaves on the shared system stack     *
*  does not survive the dispatcher.					     *
*											     *
**************************************************************************
arena_goro_leap
	pushp	a10
	tsound	arena_goro_growl_snd
	callr	arena_goro_use_idle_pal	; GOROBRE_p - he is still the SMALL
					; Kintaro up here and wears the prop's own
					; colours; TIGERDK_P is the fight-size one
					; that lands on the body (MKSOULS.ASM)
	movi	a_arena_goro_jump,a9
	movk	4,a10
argl2	calla	do_next_a9_frame
	movi	arena_goro_leap_rate,a0
	calla	prcslp
	move	*a8(oypos),a0,w
	subi	arena_goro_leap_dy,a0
	move	a0,*a8(oypos),w
	dsj	a10,argl2
	move	a8,a0
	calla	set_inviso		; gone from the wall
	movk	2,a0
	move	a0,@f_soul_kintaro,w	; MKSOULS.ASM: he is yours now
	pullp	a10
	retp
	.endif

arena_goro_walk_to_watch			; a11 = side (0 = watch_r)
	pushp	a10
	pushp	a11
	move	a11,a10
	tsound	arena_goro_growl_snd	; one intimidating growl as he starts moving
	callr	arena_goro_use_walk_pal
	movi	a_arena_goro_walk,a9
	movk	10,a11			; frames before the walk cycle wraps
argwc2	callr	arena_goro_set_idle_y
	callr	arena_goro_watch_pos_x	; follow the live camera through the full walk-in
	move	*a8(oxpos),a1,w
	sub	a1,a0			; a0 = watch spot - current position
	cmpi	arena_goro_deadzone,a0
	jrgt	argwc_right
	cmpi	-arena_goro_deadzone,a0
	jrlt	argwc_left
	callr	arena_goro_use_idle_pal
	callr	arena_goro_clear_flip
	pullp	a11
	pullp	a10
	retp

argwc_right
	move	a0,a2
	callr	arena_goro_clear_flip
	move	a2,a0
	cmpi	arena_goro_step,a0
	jrle	argwc_rstep
	movi	arena_goro_step,a0
argwc_rstep
	move	*a8(oxpos),a1,w
	add	a0,a1
	move	a1,*a8(oxpos),w
	jruc	argwc_frame

argwc_left
	move	a0,a2
	callr	arena_goro_set_flip
	move	a2,a0
	cmpi	-arena_goro_step,a0
	jrge	argwc_lstep
	movi	-arena_goro_step,a0
argwc_lstep
	move	*a8(oxpos),a1,w
	add	a0,a1
	move	a1,*a8(oxpos),w

argwc_frame
	calla	do_next_a9_frame
	subi	1,a11
	jrne	argwc_wait
	movi	a_arena_goro_walk,a9
	movk	10,a11
argwc_wait
	movi	arena_goro_walk_wait,a0
	calla	prcslp
	jruc	argwc2

arena_goro_idle
	movi	a_arena_goro_idle,a9
	calla	do_next_a9_frame
	movi	arena_goro_bre1,a0
	calla	prcslp
	calla	do_next_a9_frame
	movk	arena_goro_bre2,a0
	calla	prcslp
	calla	do_next_a9_frame
	movi	arena_goro_bre3,a0
	calla	prcslp
	calla	do_next_a9_frame
	movk	arena_goro_bre4,a0
	calla	prcslp
	retp

	.if	soulesc
*
*  He has watched Shang Tsung lose his souls; now he goes down there.
*  SMTIGERJUMP1-4 are drawn at the prop's own scale (data/SMTIGER.LOD);
*  the fight-size Kintaro that lands on the body is MKSOULS.ASM's.
*
a_arena_goro_jump
	.long	ARENA_GJUMP1
	.long	ARENA_GJUMP2
	.long	ARENA_GJUMP3
	.long	ARENA_GJUMP4
	.long	0

ARENA_GJUMP1	.long	SMTIGERJUMP1A,SMTIGERJUMP1B,0
ARENA_GJUMP2	.long	SMTIGERJUMP2A,SMTIGERJUMP2B,0
ARENA_GJUMP3	.long	SMTIGERJUMP3A,SMTIGERJUMP3B,0
ARENA_GJUMP4	.long	SMTIGERJUMP4A,SMTIGERJUMP4B,0
	.endif

a_arena_goro_walk
	.long	ani_sound,arena_goro_step_snd	; contact frame - left foot down
	.long	ARENA_GWALK1
	.long	ARENA_GWALK2
	.long	ARENA_GWALK3
	.long	ARENA_GWALK4
	.long	ARENA_GWALK5
	.long	ani_sound,arena_goro_step_snd	; contact frame - right foot down
	.long	ARENA_GWALK6
	.long	ARENA_GWALK7
	.long	ARENA_GWALK8
	.long	ARENA_GWALK9
	.long	ARENA_GWALK10
	.long	0

ARENA_GWALK1	.long	GWALK1A,GWALK1B,0
ARENA_GWALK2	.long	GWALK2A,GWALK2B,0
ARENA_GWALK3	.long	GWALK3A,GWALK3B,0
ARENA_GWALK4	.long	GWALK4A,GWALK4B,0
ARENA_GWALK5	.long	GWALK5A,GWALK5B,0
ARENA_GWALK6	.long	GWALK6A,GWALK6B,0
ARENA_GWALK7	.long	GWALK7A,GWALK7B,0
ARENA_GWALK8	.long	GWALK8A,GWALK8B,0
ARENA_GWALK9	.long	GWALK9A,GWALK9B,0
ARENA_GWALK10	.long	GWALK10A,GWALK10B,0
