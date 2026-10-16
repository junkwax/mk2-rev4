**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
* 											     *
*  module: mkscsw.asm --- SCORPION'S Back+HP SWORD SLASH			     *
*											     *
*  do_sc_swipe: his power punch, reached through joy_power_punch's	     *
*  ochar_power_punches row 10 (JOY.ASM) on HP with the stick held away,    *
*  exactly as Baraka's blade swipe and Kitana's fan swipe are.		     *
*											     *
*  The move is the OPENING SLASH of his sword fatality (do_spear_swipe,    *
*  MKDEATH.ASM) swung the other way - a BACK SLASH, frames 4,3,2,1: the    *
*  same NJSCORPSWIPE body frames and the same DSPEAR sword, built as a     *
*  slave object the way the fatality builds it.  The blade comes through   *
*  level at head height on NJSCORPSWIPE3, so the box                       *
*  (stk_sc_swipe, MKSTK.ASM) is high and a ducking man goes under it.  A   *
*  clean hit draws Kitana's fan-swipe blood: react_to_nj 20h is	     *
*  r_sa_swipe, which runs r_fn_swipe's own body.			     *
*											     *
*  Timing is Kitana's do_fan_swipe: 10 ticks cocked, 4 active, a	     *
*  2-tick pause hit or whiff, 8 to carry through - 24 whiff / 20 hit.	     *
*											     *
*  ITS OWN OBJECT because MOVES.ASM is at GSPA's ceiling (see MKLKDK.ASM), *
*  and the switch (scswipe) lives in JOY.ASM beside the table row rather   *
*  than in MAINEQU.ASM, which ~70 objects include.			     *
*											     *
**************************************************************************
	.file	"mkscsw.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.globl	do_sc_swipe		; JOY.ASM ochar_power_punches row 10
	.ref	a_sc_bswipe,a_sc_bsword	; MKNJ.ASM - body and sword, frame for frame

nj_stk_scswipe	.set	029h	; nj_strikes row - MKSTK.ASM .emsg's if it moves

scsw_cock	.set	10	; NJSCORPSWIPE4 - blade raised, cocked
scsw_active	.set	4	; NJSCORPSWIPE3 - ticks the box is live
scsw_hitpause	.set	2	; held on the blade after it connects
scsw_follow	.set	4	; NJSCORPSWIPE2 - carried through
scsw_return	.set	4	; NJSCORPSWIPE1 - blade out behind him

	.text

do_sc_swipe
	calla	init_special		; a special move: no block, buttons off
	movi	act_swipe,a0		; Baraka's - so the CPU ducks it (c_swipe)
	move	a0,*a13(p_action),w	;   and r_sa_swipe's p_hitby agrees
	movi	nj_stk_scswipe,a0
	move	a0,*a13(p_stk),w

	calla	rsnd_attack
	tsound	0c8h			; big swipe whoosh sound

	movi	a_sc_bswipe,a9
	calla	do_next_a9_frame	; NJSCORPSWIPE4 - cocked

	push	a9
	movi	a_sc_bsword,a9
	move	a9,a11
	calla	get_proj_obj_m		; a10 = sword, p_slave, lined up + flipped
	pull	a9
	move	a10,a10
	jreq	scsw_nosword		; process pool dry - no sword, no move
	move	a10,a0
	calla	insobj
	addi	32,a11			; past DSPEAR1: built on it for ROPE_P only
	mmtm	sp,a8,a9		;   (the other sword pieces are POF> - no
	move	a10,a8			;   palette - see a_sc_bsword, MKNJ.ASM)
	move	a11,a9
	calla	do_next_a9_frame	; DSPEAR4, this same tick: DSPEAR1 is
	move	a9,a11			;   never drawn
	mmfm	sp,a8,a9

	sleep	scsw_cock
	calla	double_next_a9		; NJSCORPSWIPE3 / DSPEAR3 - the slash

	movk	scsw_active,a0
	move	a0,-*a12,l		; active-tick count on the process stack
scsw_act
	movi	nj_stk_scswipe,a0
	calla	strike_check_a0
	jrc	scsw_hit
	sleep	1
	move	*a12,a0,l
	dec	a0
	move	a0,*a12,l
	jrnz	scsw_act		; whiffed: falls into the pause too

scsw_hit
	sleep	scsw_hitpause		; hit OR whiff, as do_fan_swipe: 24 / 20
scsw_swing
	pullp	a0			; drop the count

	calla	double_next_a9		; NJSCORPSWIPE2 / DSPEAR2
	sleep	scsw_follow
	calla	double_next_a9		; NJSCORPSWIPE1 / DSPEAR1
	sleep	scsw_return

scsw_nosword
	calla	back_to_normal		; delete_slave takes the sword away
	retp

	.end
