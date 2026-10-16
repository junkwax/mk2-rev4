**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
* 											     *
*  module: mkstel.asm --- SHANG TSUNG'S ELBOW CHAIN				     *
*											     *
*  st_elbow, st_elbow_2 and st_elbow_ask: the ordinary close elbow, the   *
*  combo window it opens, and the SECOND elbow along the half of a_stelbow *
*  (MKST.ASM) nothing has ever drawn, off the ELBO sequence embedded in    *
*  data/TSUNG2.IMG.							     *
*											     *
*  ITS OWN OBJECT because MOVES.ASM is at GSPA's ceiling: adding this to  *
*  it aborts the assembler with "Out of memory" (the same wall BGND.ASM   *
*  hit twice, and the reason MKLKDK.ASM exists).  Two consequences, both  *
*  handled the way MKLKDK handles them:					     *
*    - do_elbow (MOVES.ASM) reaches st_elbow with jrne + jauc, because a  *
*      conditional branch is PC-relative and GSPLNK wraps an overflow	     *
*      SILENTLY.  jauc itself is ABSOLUTE and crosses objects fine.	     *
*    - .set equates do not cross objects, so stelchain / st_chain_cool /  *
*      stel_win* and st_rct_chainstun all live in MAINEQU.ASM, included  *
*      below, and every helper it calls is .global there.		     *
*											     *
**************************************************************************
	.file	"mkstel.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.if	stelchain
	.globl	st_elbow		; MOVES.ASM do_elbow jumps here
	.endif

	.text

*
* SHANG TSUNG'S ELBOW CHAIN - the ELBO sequence authored into
* data/TSUNG2.IMG in 1993 and never coded as a string, on the art both
* elbows were always drawn in:
*
*   close HP           the FIRST elbow, STELBO1,2 - a_stelbow part 1
*   HP again           the SECOND elbow, STELBO3,4,5 - part 3
*
* BARAKA'S DOUBLE KNEE IS THE SHAPE: his second knee comes out for pressing
* a kick again (bt_2nd_knee / do_2nd_knee, MOVES.ASM), and that is MK2's
* whole grammar for a two-hit string - the same button, no direction, a
* window a few ticks wide.  THE ROUND PUNCH IS NOT PART OF IT:
* do_st_roundpunch (MOVES.ASM) stays the standalone Back + HP move it
* already was, on its own record 014h.  The IMG's ELBOROUND script does
* pair the two, but a third hit is not what this is (2026-10-05, the
* user's call).
*
* THE SECOND ELBOW IS NOT NEW ART AND NOT A NEW LANE.  a_stelbow (MKST.ASM)
* is the only elbow lane in the game with FOUR parts - every other fighter's
* is a swing and a retract - because STELBO1-5 are TWO swings.  ELBO (the
* TSUNG2.IMG sequence) plays STELBO1,2,3,4,5 straight through: 1 is the
* wind-up and 2 the contact of the first elbow, 3 the turn, 4 the cock and 5
* the contact of the second.
*
* RETAIL OPENED THE LANE ON STELBO3, so the elbow MK2 ships is the SECOND of
* the pair and the first has never been drawn by anything - which is also why
* nobody noticed that MK3MIL.LOD packs STELBO1A twice and STELBO1B never, or
* that src/MKST.ASM matched the typo with a one-piece STELBO1.  Both are
* fixed (data/STELBO1.LOD), the lane is re-cut 1,2 / 3,4,5, and the chain is
* the two elbows in the order they were authored.
*
* THE WINDOWS are rain_knee's and lk_knee's, which are UMK3's
* (process_combo_table, MKCOMBO.C):
*
*   ticks 1..stel_win_skip after contact   never fire (Trilogy's sleep 3)
*   ticks ..stel_win                       fire on the first tick with the
*                                          input
*
* so the carry-on always starts on a fixed beat whenever the button came -
* pressing early is remembered, not taken early.  Each window sits INSIDE
* the hold its own hit already had, so an unlinked elbow has exactly the
* stock recovery and retail's frame data is untouched.
*
* THE PRESS THAT STARTED A HIT IS EXCLUDED - each scan stops at the first
* queue entry as old as that hit - so one HP cannot link to itself.  Nothing
* new records the presses: the tests read the button-close queue, which
* queue_and_jump fills for every press whatever the button table says, and
* buttons are off for the whole move (init_special ends in
* disable_all_buttons).  A drone presses nothing and so never links either
* half: a CPU Shang throws the plain elbow.
*
* a10 = the tick the CURRENT hit started (low half), a11 = the tick counter.
* Both survive sleep, do_next_a9_frame and strike_check_a0.
*
	.if	stelchain

*
* do_elbow's own numbers for Shang, so an unlinked elbow is retail: speed
* from elbow_speeds (row 6 = 2), the landed hold from elbow_pauses (14), 5
* active ticks, strike 00fh (stk_stelbow), and the retract at 3 with
* act_elbow_sd - which is jelb5, the tail do_elbow would have run.
*
STEL_ACTIVE	.set	5	; do_elbow's a10
*
st_elbow
	move	@tick,a10,w
	zext	a10,w			; a10 = the tick the elbow started
	movi	act_elbow,a1
	calla	fa_stamp		; what striker does first
	move	a1,*a13(p_action),w
	movi	022h,a9
	calla	get_char_ani		; a9 = a_stelbow, part 1
ste_next
	calla	do_next_a9_frame
	jreq	ste_active		; part 1 done - STELBO5 is up
	callr	ste_rate
	calla	prcslp
	jruc	ste_next

*
* AN ELBOW INTO AN ELBOW THROWS HIM AWAY.  The stun (stk_stelbow,
* r_st_chainstun) gives up retail's pushback so the chain's second swing can
* reach - and handed out on EVERY elbow it left the man standing in front of
* Shang for the next one, so a mashed close HP was elbow, elbow, elbow and
* he was never thrown clear.  So an elbow that lands on a man STILL REELING
* FROM AN ELBOW (st_elbow_spam) is retail's - stk_stelbow_end, the same box
* and 24/6 with r_saelbow - and the stun is only ever the FIRST elbow of a
* string.  The chain itself never meets this: its second swing has its own
* record, and its first lands on a man the elbow has not touched.
*
* The answer is carried in a10's HIGH half (bit 16 = threw him away), because
* once the hit has landed he IS reeling from an elbow and the question can no
* longer be asked.  a10's low half is the start tick; every reader zexts it.
*
ste_active
	movk	STEL_ACTIVE,a11
ste_chk	zext	a10,w			; clear last tick's answer
	movk	00fh,a0			; stk_stelbow - the chain's stun
	callr	st_elbow_spam		; (saves a0)
	jrnc	ste_chk2
	movi	st_stk_elbow_end,a0	; elbow on elbow: retail's, throws him
	addi	010000h,a10
ste_chk2
	calla	strike_check_a0
	jrc	ste_hit
	sleep	1
	dsj	a11,ste_chk
	movi	act_elbow_sd,a0
	move	a0,*a13(p_action),w	; whiffed
	callr	st_elbow_ask
	jrc	st_elbow_2		; HP already in: on into the second
	jruc	ste_back

ste_hit	movi	act_elbow_sd,a0
	move	a0,*a13(p_action),w	; action: elbow sitting duck
	clr	a11			; a11 = ticks since contact
	btst	16,a10			; the answer the strike was picked on
	jrne	ste_lhold		; threw him away: no link, the stock hold
ste_hhold
	sleep	1
	inc	a11
	cmpi	stel_win_skip,a11
	jrls	ste_hwait		; the first ticks never fire
	cmpi	stel_win,a11
	jrhi	ste_hwait		; the window has shut
	callr	st_elbow_ask
	jrc	st_elbow_2
ste_hwait
	movi	elbow_pauses,a0
	calla	get_char_word		; the stock hold on STELBO5
	cmp	a0,a11
	jrlo	ste_hhold
	jruc	ste_back
*
* he was thrown away (r_saelbow): the stock hold on STELBO2, no window.
*
ste_lhold
	sleep	1
	inc	a11
	movi	elbow_pauses,a0
	calla	get_char_word
	cmp	a0,a11
	jrlo	ste_lhold

ste_back
	movk	3,a0			; do_elbow's jelb5, unchanged
	movi	act_elbow_sd,a1
	jauc	retract_strike_act	; part 2: STELBO1 (MOVES.ASM -
*					;   jauc is ABSOLUTE, so it crosses
*					;   objects; retract_strike_act ends in
*					;   back_to_normal and retp)

*
* THE SECOND ELBOW - a_stelbow part 3, STELBO3,STELBO4,STELBO5.  That is
* RETAIL'S OWN ELBOW: MK2 opens the lane on STELBO3, so the swing it ships
* is the second of an authored pair and the first - STELBO1, STELBO2 - was
* never drawn by anything.  The chain plays the pair in the order the ELBO
* sequence in data/TSUNG2.IMG authored them, so part 1 is the first elbow
* and this is the second.
*
* PART 2 IS BURNT, NOT PLAYED.  It is the first elbow's retract (STELBO1),
* which retract_strike_act needs sitting right behind part 1 for an UNLINKED
* elbow - and a carry-on that rewound to the wind-up before swinging again
* would step backwards on screen.  ste2_skip walks it with no sleep between
* the calls, so a9 lands on part 3 inside the same tick and part 3's first
* frame overwrites STELBO1 before anything is drawn.
*
* At STEL_SPEED that is 6 ticks from the link firing to contact, against
* lk_double_knee's 8 - and the link fires 4-9 ticks after the first elbow
* landed, so the second one reaches a man the first one is still HOLDING
* STILL in r_st_chainstun.  That stun is why it reaches at all.
*
* IT IS A DIFFERENT RECORD FROM THE FIRST ELBOW, and only in its reaction:
* stk_stelbow_end (st_stk_elbow_end) is the same box and the same 24/6 with
* RETAIL'S OWN r_saelbow back on it, so the hit that ENDS the chain throws
* the man away the way an elbow always has.  Nothing needs to reach after
* it, so there is nothing for a stun to buy here.  dmgscale charges it 3/4
* for being the second hit of the string, as before: 24 + 18 = 42.
*
STEL_SPEED	.set	2	; ticks a frame of the second swing
STEL_RECOVER	.set	3	; ticks a frame of part 4, the way back
*
st_elbow_2
	movi	l_stchain,a0
	calla	update_tsl		; start the cooldown
	.if	ibuf
*
* The punch that linked it was a refused press and so may be parked; it is
* spent, and must not come back as a punch when the chain ends.
*
	clr	a0
	move	@p1_obj,a1,l
	cmp	a1,a8
	jrne	ste2_ib2
	move	a0,@p1_ibuf,l
	jruc	ste2_ib9
ste2_ib2 move	a0,@p2_ibuf,l
ste2_ib9
	.endif
	calla	rsnd_attack
	movi	act_elbow,a1
	move	a1,*a13(p_action),w
*
* a9 is already sitting at part 2 - do_next_a9_frame stepped past part 1's
* terminator on the call that ended it.  Burn part 2 with NO sleep between
* the calls: it is the first elbow's retract and this is the one caller that
* must not play it.  Nothing reaches a screen, because the next frame set in
* the same tick is part 3's first.
*
ste2_skip calla	do_next_a9_frame
	jrne	ste2_skip		; part 2 burnt - a9 is at part 3
ste2_p3	calla	do_next_a9_frame
	jreq	ste2_active		; part 3 done - STELBO5 is up again
	movk	STEL_SPEED,a0
	calla	prcslp
	jruc	ste2_p3

ste2_active
	movk	STEL_ACTIVE,a11
ste2_chk
	movi	st_stk_elbow_end,a0
	calla	strike_check_a0		; stk_stelbow_end - the SAME swing with
*					;   retail's own r_saelbow back on it
	jrc	ste2_hit
	sleep	1
	dsj	a11,ste2_chk
	movi	act_elbow_sd,a0
	move	a0,*a13(p_action),w	; whiffed
	jruc	ste2_back

ste2_hit
	movi	act_elbow_sd,a0
	move	a0,*a13(p_action),w
	clr	a11			; a11 = ticks since contact
ste2_hold
	sleep	1
	inc	a11
	movi	elbow_pauses,a0
	calla	get_char_word		; the same hold the first elbow had
	cmp	a0,a11
	jrlo	ste2_hold

*
* Part 4, STELBO4, and that is the lane finished.  There is no window here:
* the chain is TWO hits, so the second elbow has nothing to link into and
* simply serves its stock hold and recovers.
*
ste2_back
	calla	disable_all_buttons
	clr	a0
	move	a0,*a13(p_action),w	; what retract_strike does
ste2_rec
	calla	do_next_a9_frame
	jreq	ste2_done		; part 4 played
	movk	STEL_RECOVER,a0
	calla	prcslp
	jruc	ste2_rec
ste2_done
	calla	back_to_normal
	retp

*
* st_elbow_spam - carry set when the man in front of me is STILL IN A
* STRING (p_hit) AND THE LAST THING THAT HIT HIM WAS AN ELBOW (p_hitby, stamped by
* JOY's strike code with the attacker's p_action - act_elbow for both of the
* chain's swings).  Saves everything: called from inside the elbow's loop.
*
st_elbow_spam
	mmtm	sp,a0,a1
	move	*a13(p_otherproc),a0,l
	movb	*a0(p_hit),a1		; still in a string ? (back_to_normal
	jreq	stsp_no			;   clears it; reaction_start_abc
*					;   never writes act_reacting)
	move	*a0(p_hitby),a1,w
	cmpi	act_elbow,a1
	jrne	stsp_no
	mmfm	sp,a0,a1
	setc
	rets
stsp_no	mmfm	sp,a0,a1
	clrc
	rets

*
* ste_rate - a0 = Shang's elbow frame rate, straight out of MOVES.ASM's
* elbow_speeds, so the unlinked elbow is retail whatever that table says.
* Called from inside the elbow's own loop, so it saves what it touches.
*
ste_rate
	mmtm	sp,a1
	movi	elbow_speeds,a0
	calla	get_char_word		; a0 = my ani speed
	mmfm	sp,a1
	rets

*
* st_elbow_ask - carry set when the SECOND ELBOW is linked: a HIGH PUNCH
* press made SINCE the elbow started (a10's low half), and the chain off
* st_chain_cool.  There is no direction in this one, so the cooldown is the
* whole limiter - see MAINEQU.ASM.  "Since" leaves out the press that
* started the elbow: it was made on the start tick or before.  The queue is
* walked newest first and stops at the first entry as old as the elbow.
* Every register it touches is saved: it is called from inside the elbow's
* own loops.
*
st_elbow_ask
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a11
	movi	l_stchain,a0
	calla	get_tsl			; a1 = ticks since his last chain
	cmpi	st_chain_cool,a1
	jrls	sta_no			; inside the cooldown: the plain elbow
	callr	st_hp_since
	jrc	sta_yes
sta_no	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a11
	clrc
	rets
sta_yes	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a11
	setc
	rets

*
* st_hp_since - carry set when the button-close queue holds a HIGH PUNCH
* press YOUNGER than a10's low half.  Clobbers freely; its caller has
* already saved everything.
*
st_hp_since
	move	@tick,a4,w
	move	a4,a5
	sub	a10,a5
	zext	a5,w			; a5 = ticks since this hit started
	calla	get_bcq_next_pointer	; a7 = next spot, a6 = queue top
	movi	sqs,a3
sths_scan
	calla	previous_q_entry	; a0 = [switch,time]
	move	a4,a11
	sub	a0,a11
	zext	a11,w			; a11 = that press's age
	cmp	a5,a11
	jrhs	sths_no			; as old as the hit or older - none
	srl	16,a0			; a0 = switch
	cmpi	sw_hi_punch,a0
	jreq	sths_yes
	dsj	a3,sths_scan
sths_no	clrc
	rets
sths_yes
	setc
	rets

	.endif
