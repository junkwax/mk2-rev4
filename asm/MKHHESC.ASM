**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
* 											     *
*  module: mkhhesc.asm --- KUNG LAO'S ESCAPE DIVE				     *
*											     *
*  do_hh_escape and its knobs: the cut "X CAYP" sequence authored in	     *
*  data/HATHED12.IMG (TMESCAPE1, TMESCAPE2, TMESCAPE3) flown as a dive    *
*  into the jump-flip tuck frames rolling along the floor.		     *
*											     *
*  ITS OWN OBJECT because MOVES.ASM is at GSPA's ceiling: moving the	     *
*  escape's timings into .bss knobs aborted the assembler with "Out of    *
*  memory", the same wall BGND.ASM hit twice and MOVES.ASM hit for Liu    *
*  Kang's double knee (see MKLKDK.ASM).  The ceiling tracks symbols and   *
*  content, not line count, so splitting is the fix and trimming prose    *
*  is not.  Consequences, both handled:					     *
*    - hh_lo_punch (MOVES.ASM) reaches it with movi + jauc airborn_xfer;  *
*      do_hh_escape is .global in MAINEQU.ASM for that reference.	     *
*    - .set equates do not cross objects, so every hhesc_* default below  *
*      lives HERE, next to the only code that reads it.			     *
*											     *
**************************************************************************
	.file	"mkhhesc.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.globl	do_hh_escape		; MOVES.ASM hh_lo_punch jumps here

	.text

**************************************************************************
*											     *
*  do_hh_escape - Kung Lao's cut ESCAPE dive: airborne Forward,Forward+LP *
*											     *
**************************************************************************
*
* HATHED12.IMG carries it authored and never coded: sequence "X CAYP" is
* TMESCAPE1, TMESCAPE2 and TMESCAPE3 held 32, inside a script that plays
* JFLIPSQ2 twice and then JFLIP1 - a dive, two tucked rotations, up onto his
* feet.  Every row is authored with dX/dY 0, so where he goes is ours.
*
* hhesc_noatk 1 (2026-10-10, the user's call): it is an escape and has NO
* attack - neither box below is ever tested.  The stk_ records stay in
* hh_strikes (balance.lock reads them by position); 0 restores them.
*
* Built as a DIVE INTO A ROLL, in the shape of Mileena's (do_fn2_kano, MKPROP):
*   - dive: thrown AT the other man in a short arch, stretched out
*     on TMESCAPE3 until the BELLY meets the floor.  stk_hhescdive covers the
*     flat body, so someone who teleports in under the dive is caught too.
*     One contact per escape: whichever of dive or roll meets him first.
*   - roll: his jump-flip tuck frames dropped onto the floor and driven at
*     Mileena's roll speed.  A pure escape, but anyone he rolls into is
*     bowled over by stk_hhescape (r_kano, her roll's reaction).  Blocked,
*     he just stops and gets up - no pop-off, it is not an attack.
*   - up: stop, floor, face him, do_backup - the way she gets up.
*
* The action is act_angle_jump in the air and act_kano on the floor, so the
* CPU and the reaction code treat the roll as the roll it is.
*
* x speed goes into p?_xvel through set_x_vel, never oxvel alone: repell
* (MAIN.ASM) copies p?_xvel over BOTH fighters' oxvel every tick, so a bare
* oxvel write lasts one tick (measured: the first cut flew the whole dive at
* the jump's 4 px/tick).  oxvel is written too, so the current tick is right.
* Keep both speeds at or under 0a0000h - the scroller has no rate above that
* and locks up.
*
* Not air_init_special: its stop_me would kill the jump's x velocity.
*
hhesc_rate	.set	2		; ticks on TMESCAPE1 and TMESCAPE2
hhesc_xvel	.set	080000h		; 9 px/tick towards the other man
hhesc_lift	.set	-070000h	; 6 px/tick UP as it fires - the top of the arch
hhesc_grav	.set	014ccdh		; 1.5 px/tick^2 over the top and down
hhesc_vcap	.set	0e0000h	; ...but never falling faster than 18 px/tick
hhesc_norep	.set	28		; ticks repell stays off for the dive
hhesc_touch	.set	054h		; anchor this far below his floor line puts
					;   TMESCAPE3's belly (bottom 66) on the floor
hhesc_airmax	.set	40		; most ticks to wait for the floor
hhesc_drop	.set	03fh		; roll frames: TMJUMPFLIP3, the lowest, sits on
					;   the floor (his are 61-92 above it; Mileena's
					;   038h is the same rule for her 54-76)
hhesc_rollspd	.set	080000h		; stk_kano's roll speed, 10 px/tick
hhesc_rolltix	.set	16		; ticks rolling along the floor
hhesc_after	.set	6		; ticks he rolls on after bowling one over
hhesc_roll	.set	2		; ticks per tuck frame
hhesc_fwdonly	.set	1		; 1 = always dive AT him  0 = along his line of travel
hhesc_xdrag	.set	0		; px/tick shed from the dive's x speed every air tick
hhesc_xmin	.set	0		; ...but never slower than this
hhesc_rolldec	.set	08000h		; px/tick shed from the roll's speed every roll tick
hhesc_rollmin	.set	020000h		; ...but never slower than this
hhesc_rollcarry	.set	1		; 1 = the roll never starts faster than he landed
hhesc_tuck	.set	2		; ticks each on TMESCAPE2, TMESCAPE1 as he comes
					; in to land (the dive run backwards)  0 = none
hhesc_corner	.set	080h		; CORNER RULE: only out of a back flip, with the
					; wall behind him this close (px)  0 = anywhere
hhesc_noatk	.set	0		; 1 = no attack: dive and roll never test a box
					; (p_store1 starts spent)  0 = 2026-09-14's boxes
*
* THE KNOBS.  Every number above is the DEFAULT for a word/long in .bss that the move
* actually reads, so a rig can sweep the feel of this move without a rebuild: poke
* hhesc_v_* and fire it again.  hhesc_kinit is set the first time it runs, so the
* defaults are laid down once and a poked value survives every later escape.
* The art's own timing, for reference (HATHED12.IMG "X CAYP"): TMESCAPE1 and 2 held
* ONE tick each, TMESCAPE3 held 32, then the tuck frames one tick each.
*
	.bss	hhesc_kinit,16		; 0 = the defaults have not been laid down yet
	.bss	hhesc_v_rate,16		; ticks on TMESCAPE1/TMESCAPE2 (art: 1)
	.bss	hhesc_v_xvel,32		; dive speed towards the other man
	.bss	hhesc_v_lift,32		; up velocity as it fires - the arch
	.bss	hhesc_v_grav,32		; gravity over the top
	.bss	hhesc_v_vcap,32		; fastest he may fall - the glide
	.bss	hhesc_v_drop,16		; how far the ball is set down onto the floor
	.bss	hhesc_v_roll,16		; ticks per tuck frame (art: 1)
	.bss	hhesc_v_rolltix,16	; ticks rolling
	.bss	hhesc_v_rollspd,32	; roll speed
	.bss	hhesc_v_xdrag,32	; dive x speed lost per tick (ease out)
	.bss	hhesc_v_xmin,32		; slowest the dive may drag down to
	.bss	hhesc_v_rolldec,32	; roll speed lost per tick (ease out)
	.bss	hhesc_v_rollmin,32	; slowest the roll may slow down to
	.bss	hhesc_v_corner,16	; corner rule distance (0 = rule off)
	.bss	hhesc_v_tuck,16		; ticks per tuck-in frame before the floor (0 = off)
	.bss	hhesc_v_rollcarry,16	; 1 = roll starts at min(rollspd, touchdown speed)
	.global	hhesc_kinit,hhesc_v_rate,hhesc_v_xvel,hhesc_v_lift,hhesc_v_grav
	.global	hhesc_v_vcap,hhesc_v_drop,hhesc_v_roll,hhesc_v_rolltix,hhesc_v_rollspd
	.global	hhesc_v_xdrag,hhesc_v_xmin,hhesc_v_rolldec,hhesc_v_rollmin,hhesc_v_rollcarry
	.global	hhesc_v_tuck,hhesc_v_corner
*
* hhesc_knobs - lay the defaults down once.  Trashes a0 only.
*
hhesc_knobs
	move	@hhesc_kinit,a0,w
	jrne	hhk_done
	movk	1,a0
	move	a0,@hhesc_kinit,w
	movk	hhesc_rate,a0
	move	a0,@hhesc_v_rate,w
	movi	hhesc_xvel,a0
	move	a0,@hhesc_v_xvel,l
	movi	hhesc_lift,a0
	move	a0,@hhesc_v_lift,l
	movi	hhesc_grav,a0
	move	a0,@hhesc_v_grav,l
	movi	hhesc_vcap,a0
	move	a0,@hhesc_v_vcap,l
	movi	hhesc_drop,a0
	move	a0,@hhesc_v_drop,w
	movk	hhesc_roll,a0
	move	a0,@hhesc_v_roll,w
	movk	hhesc_rolltix,a0
	move	a0,@hhesc_v_rolltix,w
	movi	hhesc_rollspd,a0
	move	a0,@hhesc_v_rollspd,l
	movi	hhesc_xdrag,a0
	move	a0,@hhesc_v_xdrag,l
	movi	hhesc_xmin,a0
	move	a0,@hhesc_v_xmin,l
	movi	hhesc_rolldec,a0
	move	a0,@hhesc_v_rolldec,l
	movi	hhesc_rollmin,a0
	move	a0,@hhesc_v_rollmin,l
	movi	hhesc_rollcarry,a0
	move	a0,@hhesc_v_rollcarry,w
	movi	hhesc_tuck,a0
	move	a0,@hhesc_v_tuck,w
	movi	hhesc_corner,a0
	move	a0,@hhesc_v_corner,w
hhk_done
	rets

*
* hhesc_corner_ok - THE CORNER RULE (2026-10-10, the user's call): the escape
* is a way OUT OF A CORNER, so it only fires out of a BACK FLIP (act_angle_jump
* travelling away from him - or pinned at 0 against the wall, where the edge
* clamp has eaten the speed; a flip TOWARDS him is refused) with the wall behind
* him within hhesc_v_corner px - OR a straight-up jump (act_jumpup) that close
* to either wall (the user's, same day: "against the wall you should be able to
* just jump in the air as well").
* In: a13 = the player's proc, a8 = his object.  Out: carry set = allowed.
* Trashes a0-a6.  Lays the knob defaults down itself: it runs before the first
* escape ever has.
*
hhesc_corner_ok
	callr	hhesc_knobs
	move	@hhesc_v_corner,a0,w
	jreq	hco_yes			; rule off
	move	*a13(p_action),a0,w
	cmpi	act_jumpup,a0
	jreq	hco_up			; straight up off the wall: any speed
	cmpi	act_angle_jump,a0
	jrne	hco_no			; not a jump
	calla	is_he_right
	jrc	hco_wl			; he is right: the wall behind is LEFT
	move	*a8(oxvel),a0,l
	jrlt	hco_no			; flying left, at him
	calla	get_my_dfe
	move	a6,a1			; distance to the right wall
	jruc	hco_d
hco_wl	move	*a8(oxvel),a0,l
	jrgt	hco_no			; flying right, at him
	calla	get_my_dfe
	move	a5,a1			; distance to the left wall
	jruc	hco_d
hco_up	calla	get_my_dfe		; nearer wall, whichever side
	move	a5,a1
	cmp	a6,a1
	jrls	hco_d
	move	a6,a1
hco_d	move	@hhesc_v_corner,a0,w
	cmp	a0,a1
	jrhi	hco_no			; not in the corner
hco_yes	setc
	rets
hco_no	clrc
	rets

*
* hhesc_ease - take a3 off the size of his x speed, never below a4, and hand it
* to repell (set_x_vel) and this tick (oxvel).  a3 = 0 does nothing.  No sleep,
* so callr.  Trashes a0-a4.
*
hhesc_ease
	move	a3,a3
	jreq	hhe_done		; no easing configured
	move	*a8(oxvel),a0,l
	jrnn	hhe_pos
	add	a3,a0			; moving left: towards zero
	neg	a4			; ...floor is -min
	cmp	a4,a0
	jrle	hhe_set			; still at least min
	move	a4,a0
	jruc	hhe_set
hhe_pos	sub	a3,a0			; moving right: towards zero
	cmp	a4,a0
	jrge	hhe_set
	move	a4,a0
hhe_set	calla	set_x_vel		; keeps a0
	move	a0,*a8(oxvel),l
hhe_done
	rets

do_hh_escape
	callr	hhesc_knobs		; defaults into .bss the first time
*
* THE CORNER RULE is asked HERE, after the hand-over, because MOVES.ASM (the
* button handler) and MKDRONE.ASM both sit at GSPA's out-of-memory ceiling and
* could not take the call (tried 2026-10-10: two calls, one stub - both aborted
* the build).  airborn_xfer leaves his registers and his flip's motion alone,
* so a refused escape just carries on the flip he was in.  The CPU never gets
* here refused: its odds (rpt_air_klesc, MKDRONE) are 0 under the rule.
*
	callr	hhesc_corner_ok
	jrnc	hhesc_refused
	move	*a13(p_flags),a4,w
	ori	pm_special,a4
	move	a4,*a13(p_flags),w	; airborn_xfer refuses a second one
	calla	set_no_block
	calla	disable_all_buttons	; no flip kick swapped in mid-dive
	calla	rsnd_whoosh

	movi	act_angle_jump,a0
	move	a0,*a13(p_action),w

*
* FORWARD, ALWAYS - he dives AT the other man.
*
* It used to be thrown along his LINE OF TRAVEL (oxvel, with the facing flag
* read only when a straight-up jump left no velocity to read).  The input is
* Forward,Forward, so travel and intent disagree in two ordinary cases and
* both of them flew him the wrong way:
*   - a BACKWARD jump.  He is already moving away, so the whole dive went away
*     from the man the player had just pointed the stick at twice.
*   - a CROSSUP.  oxvel still carries the jump that took him over the man's
*     head, so the moment he is past, that same sign points away - while
*     combo_look_lr had already canonicalised the press against the side he is
*     on NOW (crossfix), i.e. the pattern that fired meant the other way.
* The art leads with his head, so either one draws him diving backwards as
* well as travelling backwards.
*
* face_opponent FIRST: nothing turns a man round in mid air, so a crossup
* leaves the flip pointing at where the other man used to be, and a dive drawn
* with his back leading is the thing being complained about.  Then
* towards_x_vel, which asks is_he_right - the same question combo_look_lr
* stamps "forward" with, so the dive goes where the input said.  The signed
* speed goes on the process stack: the roll carries on in the same direction.
*
	.if	hhesc_fwdonly
	calla	face_opponent		; lead with his head, not his back
	move	@hhesc_v_xvel,a0,l
	calla	towards_x_vel		; p?_xvel - what repell hands back
	pushp	a0			; the dive's direction, for the roll
	move	a0,*a8(oxvel),l		; ...and this tick, before repell does
	.else
	move	@hhesc_v_xvel,a1,l
	move	*a8(oxvel),a0,l
	jrgt	hhesc_x			; moving right
	jrlt	hhesc_neg		; moving left
	move	*a8(oflags),a4,w
	btst	b_fliph,a4		; straight up: facing left ?
	jreq	hhesc_x			; no
hhesc_neg
	neg	a1
hhesc_x	pushp	a1			; the dive's direction, for the roll
	move	a1,a0
	calla	set_x_vel		; p?_xvel - what repell hands back
	move	a0,*a8(oxvel),l		; ...and this tick, before it does
	.endif

*
* An ARCH: a small lift off wherever he fired it, then gravity over the top
* and down.  Two cuts before this were each half right - plain gravity from a
* downward start had no top and ended in a plunge (4 px/tick down at first, 16
* at the end); an even straight line to the floor was smooth but flat, no
* arch.  So he goes UP first, and the fall is capped at hhesc_vcap so the arch
* eases into a glide instead of steepening all the way down.
*
* Repell is off for the dive: in repell_now's point-blank branch a disabled
* repell skips stuff_velocities, so the oxvel written above survives over the
* other man's body (with repell on it cut his x from 9 to 3 there) and he
* hands 9 px/tick straight on to the roll's 10.
*
	movi	hhesc_norep,a0
	move	a0,@f_norepell,w

	move	@hhesc_v_lift,a0,l
	move	a0,*a8(oyvel),l		; up off the jump...
	move	@hhesc_v_grav,a0,l
	move	a0,*a8(ograv),l		; ...and over the top

	movk	3,a9
	calla	get_char_ani2		; a9 = a_hh_escape
	calla	do_next_a9_frame	; TMESCAPE1 - tuck
	jsrp	hhesc_hold		; hhesc_v_rate ticks
	calla	do_next_a9_frame	; TMESCAPE2 - stretch
	jsrp	hhesc_hold
	calla	do_next_a9_frame	; TMESCAPE3 - flat out
*
* Stretched out until the belly meets the floor.  oypos is the anchor, and
* TMESCAPE3 draws 84px above the floor line while the anchor is ON it, so he
* has to fall hhesc_touch past p_ganiy before he is really down.
*
* Every tick: cap the fall, and test the flat body against anyone who has got
* under it.  p_store1 is the one-contact flag - a hit OR a block ends testing
* for the whole escape, dive and roll alike.
*
	.if	hhesc_noatk
	movk	1,a0			; an escape, not an attack: contact spent
	.else
	clr	a0			; nobody met yet
	.endif
	move	a0,*a13(p_store1),l
	movi	hhesc_airmax,a10	; a10 survives the sleep
hhesc1	sleep	1
	move	*a8(oyvel),a0,l
	move	@hhesc_v_vcap,a1,l
	cmp	a1,a0			; falling faster than the cap ?
	jrle	hhesc_c			; no
	move	a1,a0
	move	a0,*a8(oyvel),l		; hold it there - the arch eases into a glide
hhesc_c
	move	@hhesc_v_xdrag,a3,l
	move	@hhesc_v_xmin,a4,l
	callr	hhesc_ease		; the dive sheds speed as it glides
	move	*a13(p_store1),a0,l
	jrne	hhesc_nochk		; already met someone
	movi	hh_stk_escdive,a0
	calla	strike_check_a0		; teleported in under him ?
	jrnc	hhesc_nochk
	movk	1,a0
	move	a0,*a13(p_store1),l	; hit or blocked - that was his one contact
hhesc_nochk
	move	*a13(p_ganiy),a0,w
	addi	hhesc_touch,a0
	move	*a8(oypos),a1,w
	cmp	a0,a1			; belly on the floor ?
	jrge	hhesc_floor		; yes
*
* Close enough that two tuck frames just fit before the floor ?  The room
* they need is worked out from how fast he is falling NOW, so any arch or
* speed lands the tuck on the floor without a knob of its own.
*
	move	@hhesc_v_tuck,a2,w
	jreq	hhesc_notk		; no tuck-in
	move	*a8(oyvel),a3,l
	jrle	hhesc_notk		; still going up
	sra	16,a3			; px a tick
	sll	1,a2			; two frames
	clr	a4
hhesc_tk0
	add	a3,a4
	dsjs	a2,hhesc_tk0		; a4 = px he falls during the tuck
	sub	a1,a0			; px still to fall
	cmp	a4,a0
	jrle	hhesc_tkin		; it fits exactly now
hhesc_notk
	dsj	a10,hhesc1
	jruc	hhesc_floor

hhesc_tkin
	movk	3,a9
	calla	get_char_ani2
	calla	find_part2		; a9 ---> a_hh_escape_tuck
	calla	do_next_a9_frame	; TMESCAPE2 - pulling in
	jsrp	hhesc_tuckhold
	calla	do_next_a9_frame	; TMESCAPE1 - tucked
	jsrp	hhesc_tuckhold
*
* Roll.  stop_me / ground_player make no promise about a9, so the tuck lane
* is looked up again after them.
*
hhesc_floor
	move	*a8(oxvel),a0,l
	abs	a0
	pushp	a0			; the speed he touched down with
	calla	stop_me			; no gravity, no speed...
	calla	ground_player		; ...anchor on the floor line...
	clr	a0
	move	@hhesc_v_drop,a1,w
	calla	multi_adjust_xy		; ...and the ball down onto the floor

	movi	act_kano,a0
	move	a0,*a13(p_action),w	; a rolling ball, as far as anyone knows

	movk	3,a9
	calla	get_char_ani2
	calla	find_part2		; (the tuck-in part)
	calla	find_part2		; a9 ---> a_hh_escape_roll
	move	@hhesc_v_roll,a0,w
	calla	init_anirate

	pullp	a2			; touchdown speed
	pullp	a0			; the dive's direction...
	move	@hhesc_v_rollspd,a1,l
	move	@hhesc_v_rollcarry,a3,w
	jreq	hhesc_rc		; roll at its own speed
	cmp	a2,a1
	jrle	hhesc_rc		; no faster than he landed
	move	a2,a1
hhesc_rc
	move	a0,a0			; (movi set the flags - retest the sign)
	jrnn	hhesc_r0
	neg	a1			; ...at roll speed
hhesc_r0
	move	a1,a0
	calla	set_x_vel
	move	a0,*a8(oxvel),l

	move	@hhesc_v_rolltix,a10,w
hhesc_r1
	calla	next_anirate
	move	@hhesc_v_rolldec,a3,l
	move	@hhesc_v_rollmin,a4,l
	callr	hhesc_ease		; the roll runs down instead of stopping dead
	move	*a13(p_store1),a0,l
	jrne	hhesc_r1s		; the dive already met someone
	movi	hh_stk_escape,a0
	calla	strike_check_a0		; rolled into him ?
	jrc	hhesc_hit
hhesc_r1s
	sleep	1
	dsj	a10,hhesc_r1
	jruc	hhesc_up

hhesc_hit
	move	b2,b2			; blocked ?
	jrne	hhesc_up		; yes - an escape just stops and gets up
	movk	hhesc_after,a10		; bowled over: roll on through a little
hhesc_r2
	calla	next_anirate
	sleep	1
	dsj	a10,hhesc_r2

hhesc_up
	calla	stop_me
	calla	ground_player
	calla	face_opponent
	jauc	do_backup
*
* Refused (not out of a back flip in a corner): finish the flip he was in -
* velocity, gravity and his place in the flip lane (a9) are all still his -
* then land the way do_angle_jump does and return through reaction_exit,
* which airborn_xfer left on his stack.
*
hhesc_refused
	movi	dont_touch,a0		; keep x speed...
	move	a0,a1			; ...y speed...
	move	a0,a2			; ...and gravity
	movk	3,a3			; the flip's own rate
	clr	a6			; no per-tick routine
	jsrp	flight_call		; a9 < 0: lane already running
	movi	act_land,a1
	move	a1,*a13(p_action),w
	calla	face_opponent
	movi	007h,a9
	calla	get_char_ani
	calla	do_next_a9_frame	; his landing frame
	sleep	3
	retp

*
* hhesc_hold - sleep hhesc_v_rate ticks.  `sleep` takes an immediate, so a knob-driven
* hold is a loop of one-tick sleeps.  a11 carries the count because a7-a12 survive a
* sleep and a10 is the dive's own floor-wait counter.
*
*
* IT SLEEPS, SO IT IS A PROCESS ROUTINE - jsrp in, retp out.  As a plain callr the return
* address sat on the shared system stack, did not survive prcdsp, and the board RESET two
* ticks into the dive (measured 2026-09-23).  Same rule the escape's own notes carry for
* soul_kin_part and friends.
*
hhesc_tuckhold
	move	@hhesc_v_tuck,a11,w
	jrle	hht_done
hht_1	sleep	1			; (jsrp/retp, as hhesc_hold below)
	move	*a8(oyvel),a0,l
	move	@hhesc_v_vcap,a1,l
	cmp	a1,a0
	jrle	hht_2
	move	a1,*a8(oyvel),l		; keep the fall on the cap
hht_2	dsj	a11,hht_1
hht_done
	retp

hhesc_hold
	move	@hhesc_v_rate,a11,w
	jrle	hhh_done		; 0 = no hold at all
hhh_1	sleep	1
	dsj	a11,hhh_1
hhh_done
	retp
