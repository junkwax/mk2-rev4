**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
* 											     *
*  module: mklkdk.asm --- LIU KANG'S DOUBLE KNEE				     *
*											     *
*  lk_knee, lk_double_knee and lk_knee_ask: the ordinary close knee, the  *
*  combo window it opens, and the carry-on along a_lkdubknee (MKLK.ASM)   *
*  off the DUBLKNEESQ sequence embedded in data/KANG3.IMG.		     *
*											     *
*  ITS OWN OBJECT because MOVES.ASM is at GSPA's ceiling: adding this to  *
*  it aborts the assembler with "Out of memory" (the same wall BGND.ASM   *
*  hit twice - see the TWRBACK and ARENAKIN notes).  The ceiling tracks   *
*  symbols and content, not line count, so trimming prose buys nothing;   *
*  splitting is the fix.  Two consequences, both handled:			     *
*    - do_knee (MOVES.ASM) reaches lk_knee with jrne + jauc, because a    *
*      conditional branch is PC-relative and GSPLNK wraps an overflow	     *
*      SILENTLY.  jauc itself is ABSOLUTE and crosses objects fine.	     *
*    - .set equates do not cross objects, so lkdknee / lk_dknee_cool /    *
*      lkdk_win* / lk_stk_dubknee all live in MAINEQU.ASM, included below.*
*											     *
**************************************************************************
	.file	"mklkdk.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.if	lkdknee
	.globl	lk_knee			; MOVES.ASM do_knee jumps here
	.endif
	.globl	lk_spike		; MKREACT.ASM r_lk_spiked jumps here
	.ref	lk_spike_up		; MKREACT.ASM - his sweep get-up

* --- BEGIN GENERATED (tools/lk_dknee_wax_import.py) - do not hand-edit
* data/KANGDBLKNEE2.WAX: the victim's anchor off Liu Kang's, in his facing,
* and the ticks each sweep-fall pose holds.
lksp_f1_x	.set	73	; LKSWEEPFALL1
lksp_f1_y	.set	0
lksp_f1_hold	.set	4
lksp_f4_x	.set	78	; LKSWEEPFALL4
lksp_f4_y	.set	-2
lksp_f4_hold	.set	4
lksp_f5_x	.set	74	; LKSWEEPFALL5
lksp_f5_y	.set	-4
lksp_f5_hold	.set	4
* --- END GENERATED (lk_dknee_wax_import)

	.text

*
* LIU KANG'S DOUBLE KNEE - the DUBLKNEESQ sequence embedded in
* data/KANG3.IMG, authored in 1993 and never coded.  The seqscr plays
* LKKNEE1,2,3 - which a_lkknee already is - and then LKDUBLKNEE1-4 and
* LKBACKFIST1, so the move IS the ordinary knee with a carry-on, and it is
* wired as one: the knee comes out, and once it has struck a fixed COMBO
* WINDOW opens, exactly as rain_knee's does and for the same reason
* (process_combo_table, MKCOMBO.C).
*
*   ticks 1..lkdk_win_skip after contact   never fire (Trilogy's sleep 3)
*   ticks ..lkdk_win                       fire on the first tick with a
*                                          HIGH KICK press
*
* THE BUTTON IS A SECOND HIGH KICK, with no direction.  That is MK2's own
* grammar for this: do_knee below already gives Baraka a second knee by
* pressing a kick again (bt_2nd_knee / do_2nd_knee).  Rain's link needs
* Back because his carry-on is a roundhouse, a turn; this one drives
* forward, so Back would read backwards.  Nothing new records the press -
* the link reads the button-close queue, which queue_and_jump fills for
* every press whatever the button table says, and buttons are off for the
* whole knee.
*
* THE PRESS THAT STARTED THE KNEE IS EXCLUDED - the scan stops at the first
* queue entry as old as the knee - so one HK cannot link to itself.  A
* drone presses nothing and so never links it: a CPU Liu Kang throws the
* plain knee.
*
* WITH NO DIRECTION IN THE GESTURE, THE COOLDOWN IS THE LIMITER.  A mashed
* close HK would otherwise be offered the link on every knee, so the
* carry-on is refused inside lk_dknee_cool (64 ticks) of his last one.
*
* AND IT ENDS IN THE FLOOR (data/KANGDBLKNEE2.WAX): the second knee kicks
* him down through his own sweep fall, the ground rumbles and he bounces in
* place, then takes his sweep get-up - lk_spike below.  The backfist link that
* used to hang off LKBACKFIST1 is gone; that frame is Liu Kang's recovery.
*
* THE FIRST KNEE LAUNCHES, AS RETAIL, UNLESS THE LINK IS ALREADY DIALLED.
* Its reaction has to be chosen at CONTACT - a launched man is ~110 px away
* and airborne by the time the carry-on comes out - so the knee tests
* stk_lkknee_link (the chain's standing stun) only when the second High Kick
* is already in, and plain stk_lkknee (r_hhknee, retail's knock-up)
* otherwise.  A knee that launched him opens no link window.
*
* NOTHING IS PINNED AND NOTHING CHASES - and getting there took three goes.
* Rain's knee hands the victim stumble_back, who slides, so rain_super_knee
* has to hold him still.  Liu Kang's knee USED to hand him r_hhknee, a
* KNOCKDOWN into flight, and with the authored 24-tick carry-on that put him
* ~110 px away and airborne before the second knee was out: the carry-on
* whiffed in open space, and making Liu Kang run after him just turned the
* whiff into a slide.
*
* The fix is upstream, in stk_lkknee: the knee now hands him r_lopunched, a
* standing chest-hit stun with no pushback (see the note on that record in
* MKSTK.ASM).  He stays on his feet in front of Liu Kang, the chain links
* the way a dial-a-combo should, and neither fighter has to move.
*
* In lk_knee: a10 = the tick the knee started (low half), a11 = the tick
* counter.  In lk_double_knee they are re-used - a11 = the tick the
* carry-on started, a10 = counters.  Both survive sleep, do_next_a9_frame
* and strike_check_a0, which is why they carry the state.
*
	.if	lkdknee

lk_knee
	move	@tick,a10,w
	zext	a10,w			; a10 = the tick the knee started
	movi	act_knee,a1
	calla	fa_stamp		; what striker does first
	move	a1,*a13(p_action),w
	movi	021h,a9
	calla	get_char_ani		; a9 = a_lkknee
lkn_next
	calla	do_next_a9_frame
	jreq	lkn_active		; part 1 done - LKKNEE3 is up
	movk	3,a0			; do_knee's speed
	calla	prcslp
	jruc	lkn_next

lkn_active
	movk	2,a11			; do_knee's active ticks
lkn_chk	movi	00eh,a0			; stk_lkknee - retail's knock-up
	callr	lk_knee_ask		; (saves a0)
	jrnc	lkn_chk2
	movi	lk_stk_kneelink,a0	; dialled already: the chain's stun
lkn_chk2
	calla	strike_check_a0
	jrc	lkn_hit
	sleep	1
	dsj	a11,lkn_chk
	movi	act_knee_sd,a0
	move	a0,*a13(p_action),w	; whiffed
	callr	lk_knee_ask
	jrc	lk_double_knee		; HK already in: on into the carry-on
	jruc	lkn_back

lkn_hit	movi	act_knee_sd,a0
	move	a0,*a13(p_action),w	; action: knee sitting duck
	clr	a11			; a11 = ticks since contact
	callr	lk_knee_ask		; the same answer the strike was picked on
	jrnc	lkn_lhold		; launched him: no link, the stock hold
lkn_hhold
	sleep	1
	inc	a11
	cmpi	lkdk_win_skip,a11
	jrls	lkn_hwait		; the first ticks never fire
	cmpi	lkdk_win,a11
	jrhi	lkn_hwait		; the window has shut
	callr	lk_knee_ask
	jrc	lk_double_knee
lkn_hwait
	movi	knee_hit_sleeps,a0
	calla	get_char_word		; the stock hold on LKKNEE3
	cmp	a0,a11
	jrlo	lkn_hhold

	jruc	lkn_back
*
* he was launched (retail's r_hhknee): the stock hold on LKKNEE3 and no link
* window - the carry-on would only swing at a man already 100 px away.
*
lkn_lhold
	sleep	1
	inc	a11
	movi	knee_hit_sleeps,a0
	calla	get_char_word
	cmp	a0,a11
	jrlo	lkn_lhold

lkn_back
	calla	disable_all_buttons
	movk	6,a0
	jauc	retract_strike		; LKKNEE2, LKKNEE1 (MOVES.ASM - jauc is
*					;   ABSOLUTE, so it crosses objects)

*
* The link was made: the rest of DUBLKNEESQ, at the holds MIDWAY AUTHORED.
* a_lkdubknee (MKLK.ASM) is frame,hold PAIRS generated out of the sequence
* by tools/lk_dubknee_seq_import.py, and this walks them - 4, 8, 4, 4, 4
* game ticks, 24 in all.  It used to run at invented per-part speeds
* (2/3/3, 13 ticks) because a seqscr hold byte was read as GAME ticks
* instead of PREVIEW ticks; it is not, and the move was coming out at about
* twice its intended rate.  Never hand a pair lane to mframew: the hold
* longs would be read as frame pointers.
*
* The contact frame's hit hands the victim r_lk_spiked (lk_spike, below),
* and Liu Kang holds LKDUBLKNEE3 for exactly as long as the victim's first
* spiked pose (lksp_f1_hold), so LKDUBLKNEE4 and the floor arrive together,
* as data/KANGDBLKNEE2.WAX has them.  Part 4, LKBACKFIST1, is his recovery.
*
* a9 = the lane, a10 = counters, a11 = the tick the carry-on started.  All
* three survive sleep and do_next_a9_frame.
*
lk_double_knee
	move	@tick,a11,w
	zext	a11,w			; a11 = the tick the carry-on started
	movi	l_lkdknee,a0
	calla	update_tsl		; start the cooldown
	.if	ibuf
*
* The kick that linked it was a refused press and so may be parked; it is
* spent, and must not come back as a kick when the carry-on ends.
*
	clr	a0
	move	@p1_obj,a1,l
	cmp	a1,a8
	jrne	ldk_ib2
	move	a0,@p1_ibuf,l
	jruc	ldk_ib9
ldk_ib2	move	a0,@p2_ibuf,l
ldk_ib9
	.endif
	tsound	004h			; whoosh - do_roundhouse's
	calla	rsnd_attack
	movi	act_2nd_knee,a1
	move	a1,*a13(p_action),w
	movi	lk_stk_dubknee,a0
	move	a0,*a13(p_stk),w
	movk	7,a9
	calla	get_char_ani2		; a9 = a_lkdubknee

ldk_next
	calla	do_next_a9_frame
	jreq	ldk_strike		; part 1 done - the contact frame next
	callr	ldk_hold		; a0 = this frame's authored hold
	calla	prcslp
	jruc	ldk_next

ldk_strike
	calla	do_next_a9_frame	; LKDUBLKNEE3 - the contact frame
	callr	ldk_hold
	move	a0,a10			; its authored hold IS its active ticks
ldk_chk	movi	lk_stk_dubknee,a0
	calla	strike_check_a0		; stk_lkdubknee
	jrc	ldk_hit
	sleep	1
	dsj	a10,ldk_chk
	jruc	ldk_drop
ldk_hit	sleep	lksp_f1_hold		; hit ---> hold while he goes down
*					;   (r_lk_spiked's first pose, the WAX's)

ldk_drop
	calla	disable_all_buttons
	clr	a0
	move	a0,*a13(p_action),w	; what retract_strike does
	calla	do_next_a9_frame	; part 2's terminator
	calla	do_next_a9_frame	; LKDUBLKNEE4 - the drop
	callr	ldk_hold
	calla	prcslp
*
* PART 4 - LKBACKFIST1, his recovery, held for its authored ticks.  It used to
* be a chain window into do_lk_backfist; the spike ends the string now.
*
	calla	do_next_a9_frame	; part 3's terminator
	calla	do_next_a9_frame	; LKBACKFIST1
	callr	ldk_hold
	calla	prcslp
	calla	back_to_normal
	retp

*
* ldk_hold - a0 = the authored hold of the frame do_next_a9_frame just
* showed, and a9 stepped past it onto the next entry.  a10 and a11 are
* carrying the counter and the chain reference, so they are left alone.
*
ldk_hold
	move	*a9,a0,l
	addi	32,a9
	rets

*
* lk_knee_ask - carry set when the carry-on is linked: a HIGH KICK press
* made SINCE the knee started (a10's low half), and the move off
* lk_dknee_cool.  "Since" leaves out the press that started the knee - it
* was made on the start tick or before.  The queue is walked newest first
* and stops at the first entry as old as the knee.  Every register it
* touches is saved: it is called from inside the knee's own loops.
*
lk_knee_ask
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a11
	movi	l_lkdknee,a0
	calla	get_tsl			; a1 = ticks since his last double knee
	cmpi	lk_dknee_cool,a1
	jrls	lka_no			; inside the cooldown: the plain knee
	move	@tick,a4,w
	move	a4,a5
	sub	a10,a5
	zext	a5,w			; a5 = ticks since the knee started
	calla	get_bcq_next_pointer	; a7 = next spot, a6 = queue top
	movi	sqs,a3
lka_scan
	calla	previous_q_entry	; a0 = [switch,time]
	move	a4,a11
	sub	a0,a11
	zext	a11,w			; a11 = that press's age
	cmp	a5,a11
	jrhs	lka_no			; as old as the knee or older - none
	srl	16,a0			; a0 = switch
	cmpi	sw_hi_kick,a0
	jreq	lka_yes
	dsj	a3,lka_scan
lka_no	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a11
	clrc
	rets
lka_yes	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a11
	setc
	rets

	.endif

*
* lk_spike - THE DOUBLE KNEE KICKS HIM DOWN INTO THE FLOOR.  The victim's own
* process (a8 = him, a13 = his proc), jumped to from r_lk_spiked (MKREACT.ASM)
* once reaction_start_abc has run.  Outside .if lkdknee because react_to_lk
* names r_lk_spiked either way.
*
* data/KANGDBLKNEE2.WAX authors it on Liu Kang: on the tick LKDUBLKNEE3 lands
* he is on LKSWEEPFALL1, then FALL4, then FALL5 flat on the floor, each held 4
* ticks, all facing Liu Kang's way.  The game draws each victim's OWN sweep
* fall (anitab1 016h): part 1 row 0, part 1 row 3, and part 2's last (flat)
* frame - exactly Liu Kang's FALL1/4/5 - at the WAX's place off Liu Kang's
* anchor (lksp_*, generated above by tools/lk_dknee_wax_import.py).
*
* On the floor frame the ground rumbles; then he BOUNCES IN PLACE - Baraka's
* leg-grab bounce (salg_slammed, MOVES.ASM: MK3's -060000h up against 08000h)
* with no x - through flight, so he carries a real y velocity and a follow-up
* that catches him in the air takes the ordinary airborne path.  If nothing
* does, he lands with a thud and lk_spike_up (MKREACT) turns him to Liu Kang
* and gives him his SWEEP get-up, the one a real sweep ends in.
*
lk_spike
	tsound	019h			; smak !
	calla	rsnd_react_voice
	movk	2,a0
	calla	create_blood_proc
	movi	act_reacting,a0
	move	a0,*a13(p_action),w
	calla	stop_me
	clr	a0
	move	a0,*a8(ograv),l
	movi	016h,a9
	calla	get_char_ani		; his sweep fall
	calla	do_next_a9_frame	; FALL1
	movi	lksp_f1_x,a0
	movi	lksp_f1_y,a1
	callr	lksp_place
	sleep	lksp_f1_hold
	calla	do_next_a9_frame
	calla	do_next_a9_frame
	calla	do_next_a9_frame	; FALL4 (part 1 row 3)
	movi	lksp_f4_x,a0
	movi	lksp_f4_y,a1
	callr	lksp_place
	sleep	lksp_f4_hold
	movi	016h,a9
	calla	find_ani_part2
	calla	find_last_frame
	calla	do_next_a9_frame	; FALL5 - flat on the floor
	movi	lksp_f5_x,a0
	movi	lksp_f5_y,a1
	callr	lksp_place
	movi	00008000ch,a11
	calla	shake_a11		; the ground rumbles
	calla	rsnd_ground
	calla	rsnd_wasted_voice	; his voice - this is his process
	sleep	lksp_f5_hold
*
* the bounce, in place, holding the flat frame (a9 is past it: never_ani
* never steps, and a negative a9 tells flight the animation is set up)
*
	clr	a0			; no x: he bounces where he lies
	movi	-060000h,a1		; salg_slammed's (MK3's r_leg_slammed's)
	movi	08000h,a2
	movi	never_ani,a3
	jsrp	flight
	jauc	lk_spike_up		; thud, face Liu Kang, sweep get-up

*
* lksp_place - put him on the frame he is showing at Liu Kang's anchor plus
* (a0, Liu Kang's facing) and HIS OWN grounded anchor plus a1.  match_ani_points hands him Liu Kang's
* facing, so multi_adjust_xy's flip negation is Liu Kang's and the WAX
* (whose sweep-fall frames are unmirrored, i.e. facing Liu Kang's way) needs
* no turn.  Saves a9-a11 across the ani2 run inside flip_multi.
*
lksp_place
	mmtm	sp,a9,a10,a11
	mmtm	sp,a0,a1
	move	a8,a0			; a0 = me
	move	*a13(p_otherguy),a8,l	; a8 = Liu Kang
	calla	match_ani_points	; my anchor on his, facing his way
	move	a0,a8
	mmfm	sp,a0,a1
	calla	multi_adjust_xy		; the WAX's offset (x; a1 survives it)
	move	*a13(p_ganiy),a2,w	; y off HIS floor, not Liu Kang's: the
	add	a1,a2			;   two anchors are a few px apart, and
	move	a2,*a8(oypos),w		;   the bounce lands on his (p_ganiy)
	mmfm	sp,a9,a10,a11
	rets
