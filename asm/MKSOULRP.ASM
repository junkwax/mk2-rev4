**************************************************************************
*											     *
*  video game project:	mortal kombat 2							*
*											     *
*  module: mksoulrp.asm - SHAO KAHN'S SOUL RIP					*
*											     *
*  He wins the match, stands over the beaten man, hauls him back onto his  *
*  feet without touching him and pulls his SOUL out of him.  The soul	     *
*  leaves the body green and flies into Kahn.					     *
*											     *
*  The choreography is the user's IMGTOOL project data/SHAOSOULSUCK.WAX:   *
*											     *
*    slot 0  Shao Kahn  SHASOULRIP1-9   (NEWSHAO.IMG, data/SKSOUL1-5.LOD)  *
*    slot 5  the victim  knockdown -> stumble -> flipped -> soul-suck pose *
*    slot 1  the soul    the victim's own SUCK_* strips, in green	     *
*											     *
*  ksr_script below is that project, step for step, and is GENERATED -     *
*  rerun tools/kahn_soulrip_wax_import.py after any save of the WAX.	     *
*											     *
*  NO NEW ART BUT KAHN'S.  The victim's poses are frames every fighter	     *
*  already has (the throat slam's a_??_kslammed reads the same ones), and  *
*  the soul is the lane Mileena's inhale fatality draws - a_??_sucked_in,  *
*  MKDIE.ASM - drawn in a green ramp out of src/SKSOULP.ASM instead of his *
*  colours.  That is what the user authored in data/MKSUCK.IMG: CAGE1-7    *
*  re-pointed at a green CAGE1_P.						     *
*											     *
*  WHERE IT FIRES.  Shao Kahn has no FINISH HIM - finish_him_sequence	     *
*  (MAIN.ASM) returns immediately when either fighter is ft_final_boss - so *
*  his other two finishers (the Portal Punch and the hammer smash) are hits *
*  that land mid-fight.  This one is the OTHER shape of Kahn fatality: it  *
*  is what he does when he has just won the match by ordinary means, and	     *
*  it hooks the same place Shang's souls do, at the top of		     *
*  finish_him_sequence, through kahn_soulrip_due.  The round is already	     *
*  over when we get here, so unlike kahn_hammer_try_fatal there is no life  *
*  bar to hold open: nothing can end the round underneath us.		     *
*											     *
*  HOW THE TWO FIGHTERS ARE DRIVEN.  winner_status 5 (JOY.ASM		     *
*  status_jumps) takes each man's own process into kahn_soulrip_status.    *
*  Kahn walks to the body and then runs the whole lane from HIS process,   *
*  posing and placing the victim every tick off ksr_script - the throat	     *
*  slam's arrangement exactly (kahn_slam_place, MKBOSS.ASM), and for its   *
*  reason: every entry of the WAX changes the victim's pose AND his offset, *
*  so he cannot be handed a lane of his own and left to walk it.		     *
*											     *
*  copyright (c) 1993 midway manufacturing						*
*											     *
**************************************************************************
	.file	"mksoulrp.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	imgtbl.glo
	.ref	drain_pal_fix		; MKFX.ASM
	.text

	.if	ksoulrip

;
; He walks to the body before the lane starts.  The WAX puts it 21-65 px off
; his anipoint, so a Kahn who won the round from across the stage would
; teleport it to him; instead he stops where step 0 wants him.
;
ksr_slack	.set	4		; he stops within the first step's own
					; offset plus this - his walk covers
					; ~3.5 px a tick, so he lands on it.
					; (It was a flat 80 px, and the body
					; jumped 58 px when the lane began.)
ksr_walk_ticks	.set	0100h		; ...and how long he will walk for
ksr_down_wait	.set	0060h		; how long to wait for the body to settle
ksr_settle	.set	010h		; a beat between arriving and the taunt
ksr_suck_gap	.set	6		; Mileena's suck ($c9) -> his scream
ksr_scream_gap	.set	6		; his scream -> Shang's soul sound ($c1)
ksr_soul_lead	.set	6		; Shang's soul sound -> the soul leaves
ksr_point_gap	.set	12		; between the two points (kahn_victory
					; uses 10 + rand 6)
ksr_taunt_pause	.set	014h		; after the taunt, before he walks in
ksr_taunt_back	.set	040h		; how much further off the body than the
					; lane's first step he stands to taunt
					; ("a few steps" - his walk is ~3.5 px a
					; tick, so ~18 ticks to close it)
ksr_line_len	.set	061h		; "ALL TOO EASY" is 1.789 s = 97.2 ticks
					; (track $04A9, measured off the built
					; sound ROM); the sting's sound-kill
					; waits this long after the line starts.
					; The line's audio is done at 1.720 s, so
					; the sting lands 65 ms clear of its tail
					; - tight, but it does not cut the line.
					; History: 074h for the 2.02 s custom
					; read, then 09eh for $4f's 2.91 s.
ksr_jingle_hold	.set	01eh		; bent over him, hands on him, while the
					; arena goes dark and the fatality sting
					; plays - then the lift
ksr_tail	.set	020h		; the soul is gone - how long he holds it
ksr_husk_wait	.set	0180h		; Kahn waits this long, at most, for the
					; husk to hit the floor

;
; ksr_script row, eight words:
;
;   kadv    1 = step Kahn's own frame this row, 0 = hold the one he is on
;   pose    row of the victim's a_??_ksoulrip list (see ksr_victim_poses)
;   vdx,vdy his anipoint's offset from Kahn's, straight off the WAX and
;           already relative to Kahn's own slot offset
;   srow    row of his a_??_sucked_in lane for the soul, or -1 for NO SOUL
;           ON SCREEN.  The WAX carries the soul parked on its first frame
;           for the first fifteen ticks as a timing buffer; only the last
;           of those ticks shows it, which is the user's own instruction -
;           "the green sprite shouldnt show until the very last tick before
;           the CAGESOUL2 plays".
;   sdx,sdy and where that soul sits, same convention as vdx/vdy
;   hold    ticks this row is held for
;
ksr_kadv	.set	0
ksr_pose	.set	16
ksr_vdx		.set	32
ksr_vdy		.set	48
ksr_srow	.set	64
ksr_sdx		.set	80
ksr_sdy		.set	96
ksr_hold	.set	112
ksr_rowsize	.set	128

;>>>WAX BEGIN - generated by tools/kahn_soulrip_wax_import.py, do not edit
;
; data/SHAOSOULSUCK.WAX - 22 steps, 82 ticks
;
;      Kahn slot 0    victim slot 5              soul slot 1
;
ksr_script
	.word	1,0,21,-13,-1,0,0,4		; step  0  SHASOULRIP1  KNOCKDOWN7
	.word	1,0,21,-13,-1,0,0,4		; step  1  SHASOULRIP2  KNOCKDOWN7
	.word	1,0,21,-13,-1,0,0,4		; step  2  SHASOULRIP3  KNOCKDOWN7
	.word	1,1,58,-60,-1,0,0,6		; step  3  SHASOULRIP4  KNOCKDOWN2
	.word	1,2,54,-48,-1,0,0,6		; step  4  SHASOULRIP5  STUMBLE3
	.word	1,3,61,-21,-1,0,0,6		; step  5  SHASOULRIP6  STUMBLE2
	.word	1,4,52,8,-1,0,0,6		; step  6  SHASOULRIP7  STUMBLE1
	.word	1,5,62,32,-1,0,0,6		; step  7  SHASOULRIP8  FLIPPED1
	.word	1,6,65,15,-1,0,0,6		; step  8  SHASOULRIP9  SOULSUCK1
	.word	0,6,65,15,-1,0,0,1		; step  9  (held)       SOULSUCK1
	.word	0,6,65,15,-1,0,0,1		; step 10  (held)       SOULSUCK1
	.word	0,6,65,15,-1,0,0,1		; step 11  (held)       SOULSUCK1
	.word	0,6,65,15,-1,0,0,1		; step 12  (held)       SOULSUCK1
	.word	0,6,65,15,-1,0,0,1		; step 13  (held)       SOULSUCK1
	.word	0,6,65,15,-1,0,0,1		; step 14  (held)       SOULSUCK1
	.word	0,6,65,15,0,-45,25,4		; step 15  (held)       CAGE1
	.word	0,6,65,15,1,-46,1,4		; step 16  (held)       CAGE2
	.word	0,6,65,15,2,-50,-19,4		; step 17  (held)       CAGE3
	.word	0,6,65,15,3,-50,-20,4		; step 18  (held)       CAGE4
	.word	0,6,65,15,4,-52,-18,4		; step 19  (held)       CAGE5
	.word	0,6,65,15,5,-50,-20,4		; step 20  (held)       CAGE6
	.word	0,6,65,15,6,-48,-18,4		; step 21  (held)       CAGE7
	.word	0,0,0,0,0,0,0,0			; end of script
;<<<WAX END

;
; ksr_victim_poses - ochar -> that fighter's pose list for this sequence.
; 0 for the bosses: kahn_soulrip_due refuses a boss victim, so these rows
; are filler that cannot be read.  19 rows, 0-18 - tools/audit_char_tables.py
; holds it to that.
;
ksr_victim_poses
	.long	a_hh_ksoulrip	;  0 - kung lao
	.long	a_lk_ksoulrip	;  1 - liu kang
	.long	a_jc_ksoulrip	;  2 - johnny cage
	.long	a_sa_ksoulrip	;  3 - baraka
	.long	a_fn_ksoulrip	;  4 - kitana
	.long	a_fn_ksoulrip	;  5 - mileena
	.long	a_st_ksoulrip	;  6 - shang tsung
	.long	a_rd_ksoulrip	;  7 - raiden
	.long	a_nj_ksoulrip	;  8 - sub-zero
	.long	a_nj_ksoulrip	;  9 - reptile
	.long	a_nj_ksoulrip	; 10 - scorpion
	.long	a_jx_ksoulrip	; 11 - jax
	.long	0		; 12 - kintaro
	.long	0		; 13 - shao kahn
	.long	a_nj_ksoulrip	; 14 - smoke
	.long	a_nj_ksoulrip	; 15 - noob
	.long	a_fn_ksoulrip	; 16 - jade
	.long	a_nj_ksoulrip	; 17 - ermac (reptile's art)
	.long	a_fn_ksoulrip	; 18 - khameleon (jade's row)
	.long	a_nj_ksoulrip		; 19 - rain (clone of Scorpion)
	.if	wunit	; WOLF FIGHTERS
	.ref	kn_a_ksoulrip
	.long	a_fn_ksoulrip,a_fn_ksoulrip,kn_a_ksoulrip,a_lk_ksoulrip,a_nj_ksoulrip	; 20 sonya=4, 21 sindel=4, 22 kano, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS

	.bss	f_ksoulrip,16,1		; 0 idle / 1 running / -1 finished
	.bss	ksr_vic_down,16,1	; 1 = the beaten man is flat and parked
	.bss	ksr_soul_obj,32,1	; the soul, while it is on screen
	.bss	ksr_vic_done,16,1	; 1 = the husk is done withering
	.bss	ksr_line_tick,16,1	; @tick when the taunt line started
	.bss	f_ksr_quiet,16,1	; 1 = bonus_count skips Kahn's "I WIN"
*
* The soul's shape RAM.  A PLAIN .BSS BUFFER, not a gmo_proc process block,
* for the reason MKZAP's fistpulp_mpram is one - and here for a second
* reason as well: these are a PLAYER's frame records, and object_setup reads
* a palette off the frame (*a5(icmap)) that only PON> records carry.  The
* soul is built by hand instead, the way MKSOULS builds its Kintaro.
*
	.bss	ksr_soul_mpram,mp_ramsize,1

**************************************************************************
*											     *
*  kahn_soulrip_due - carry set when this match ends in Shao Kahn taking   *
*  the loser's soul.									     *
*											     *
*  Called at the top of finish_him_sequence (MAIN.ASM), so the loser is    *
*  the side whose bar is empty and the match is already decided.	     *
*											     *
*  Trashes a0-a2.									     *
*											     *
**************************************************************************
kahn_soulrip_due
	clr	a0
	move	a0,@f_ksr_quiet,w	; a stale one must never silence an
					; ordinary win - set again below only
					; when the soul rip actually runs
	move	@f_death,a0,w
	jrne	ksrd_no			; the Portal Punch or the hammer already
					; finished him - one fatality a round
	move	@p1_bar,a0,w
	jrne	ksrd_p2
	move	@p2_char,a1,w		; p1 lost, so p2 won
	move	@p1_char,a2,w
	jruc	ksrd_test
ksrd_p2	move	@p2_bar,a0,w
	jrne	ksrd_no			; nobody lost ?!
	move	@p1_char,a1,w
	move	@p2_char,a2,w
ksrd_test
	cmpi	ft_final_boss,a1
	jrne	ksrd_no			; the winner is not Shao Kahn
	cmpi	ft_final_boss,a2
	jreq	ksrd_no			; ...and the loser must not be
	cmpi	ft_goro,a2
	jreq	ksrd_no			; no pose list for a boss victim
	calla	count_active_players
	cmpi	1,a0
	jrne	ksrd_no			; one-player game only
	setc
	rets
ksrd_no	clrc
	rets

**************************************************************************
*											     *
*  kahn_soulrip_sequence - the master process, in place of FINISH HIM.	     *
*  Reached by jauc from finish_him_sequence, which was itself jsrp'd, so   *
*  this ends in retp and the caller carries on declaring the winner.	     *
*											     *
*  It owns the flags and the sting; the sequence itself runs in Kahn's	     *
*  own process (kahn_soulrip_status below), which raises f_ksoulrip to -1  *
*  when the body is on the floor and the soul is gone.			     *
*											     *
**************************************************************************
kahn_soulrip_sequence
	clr	a0
	move	a0,@ksr_vic_down,w
	move	a0,@ksr_vic_done,w
	move	a0,@ksr_soul_obj,l
	move	a0,@f_death2,w		; not a babality
	movk	1,a0
	move	a0,@f_ksoulrip,w
	move	a0,@f_ksr_quiet,w	; no "I WIN" over this one (the user)
	movk	5,a0
	move	a0,@winner_status,w	; soul-rip mode (JOY.ASM status_jumps)
*
* The sting and the arena going dark, the way both of his other finishers
* do it: death_blow_fader is what init_death_blow creates for every stock
* fatality, and make_db_tone is the dun-dun-dunnnn (it kills the music
* first, which is the point - see kahn_hammer_try_fatal).
*
* fs_fatality, not a plain fatality number: death_blow_complete sends its
* own tune for every other value and that lands on the same frame as the
* round-end speech.  Nothing here calls death_blow_complete anyway - the
* flip to -1 is done below, when the sequence is over.
*
	movi	fs_fatality,a0
	move	a0,@f_death,w		; flag: death blow in progress
					; (the fade and the sting are NOT here -
					; they wait for Kahn to lift him, see
					; ksrk_dim; on the killing hit the round
					; just ends as any other does)
*
* Now it is his show.  The ceiling is there in case he never reaches the
* body - a stage edge, a victim who cannot be taken over - so that a round
* can always end.
*
	movi	0c00h,a10
ksrs_wt	sleep	1
	move	@f_ksoulrip,a0,w
	cmpi	-1,a0
	jreq	ksrs_done
	dsj	a10,ksrs_wt
ksrs_done
	clr	a0
	move	a0,@f_ksoulrip,w
	movi	-1,a0
	move	a0,@f_death,w		; death blow COMPLETE: win7 in bonus_count
					; (MAIN.ASM) is what drips FATALITY, and
					; it reads exactly this
	retp

**************************************************************************
*											     *
*  kahn_soulrip_status - winner_status 5, from check_winner_status	     *
*  (JOY.ASM) in either fighter's process.  Like finish_him, it never	     *
*  returns.										     *
*											     *
**************************************************************************
kahn_soulrip_status
	pull	a1			; no retreat / no return
	move	@p1_bar,a1,w
	move	*a13(procid),a0,w
	cmpi	pid_p1,a0
	jreq	ksrst1
	move	@p2_bar,a1,w
ksrst1	move	a1,a1
	jreq	ksr_victim_begin	; my bar is empty: I am the beaten man
	jruc	ksr_kahn_begin

**************************************************************************
*											     *
*  ksr_victim_begin - the loser's own process, and only when he is still   *
*  ON HIS FEET.									     *
*											     *
*  A man who was knocked down by the killing blow never arrives here:	     *
*  check_stay_down (MKREACT.ASM) parks him in wait_forever where he lies,   *
*  and raises ksr_vic_down on the way past so Kahn knows he is settled.    *
*  So reaching this means the round ended with him standing - put him on   *
*  the floor first, because the lane opens on his KNOCKDOWN7.		     *
*											     *
**************************************************************************
ksr_victim_begin
	calla	stop_me
	calla	disable_all_buttons
	calla	set_no_block
	move	a8,a0
	calla	clear_inviso

	movk	00fh,a9
	calla	get_char_ani		; his knockdown - dizzy_dude's own fall
	movk	4,a0
	jsrp	mframew			; part 1 - he goes down
	calla	shake_n_sound
	movk	4,a0
	jsrp	mframew			; part 2 - flat on his back

	movk	1,a0
	move	a0,@ksr_vic_down,w	; Kahn may come and take him
	jauc	wait_forever		; ...he poses me from here on

**************************************************************************
*											     *
*  ksr_kahn_begin - Shao Kahn's own process.  a8 = him, a13 = his proc.    *
*											     *
**************************************************************************
ksr_kahn_begin
	calla	stop_me
	calla	disable_all_buttons
	calla	face_opponent
*
* 0. He laughs over the killing blow first (the user: "have him laugh on the
*    last hit before walking to taunt ... just make the laugh sound no need
*    for the animation").  kahn_victory's laugh (MKCANNED.ASM klaf3) - a
*    random one of his two ($49/$4a) - and he walks straight on.
*
	movi	00049004ah,a1
	calla	randsnd2
*
* 1. Walk to the body - but stop a few steps short of it: he taunts from
*    there (the user: "have him back a few steps on the taunt"), and only
*    then walks in to where the lane's first step wants him.  If the round
*    ended with him standing on top of the man, ksr_walk_to backs him off
*    to that distance instead.
*
	movi	ksr_taunt_back,a0
	jsrp	ksr_walk_to
*
* 2. Wait for the man to be flat.  Either he was knocked down by the
*    killing blow and check_stay_down parked him, or he was on his feet and
*    ksr_victim_begin has just put him there; both raise ksr_vic_down.
*
	movi	ksr_down_wait,a10
ksrk_wait
	move	@ksr_vic_down,a0,w
	jrne	ksrk_have
	sleep	1
	dsj	a10,ksrk_wait
ksrk_have
	movi	ksr_settle,a10
ksrk_beat
	sleep	1
	dsj	a10,ksrk_beat
*
* 2b. The taunt, first (the user: "before he picks him up have him taunt
*     cage with the eat-die finger point").  It is his victory taunt,
*     kahn_victory's (MKCANNED.ASM) to the frame: "EAT SHIT AND DIE"
*     (triple_sndtab2 $63) over a_sk_talkdown, the point DOWN at a man on
*     the floor (sk_anitab1 019h), twice.  Repell off already - he is
*     standing over the body.
*
	movi	040h*40,a0
	move	a0,@f_norepell,w
	move	@tick,a0,w
	move	a0,@ksr_line_tick,w	; when the line started - the sting
					; waits for it to finish (ksrk_step)
	movi	04eh,a0
	calla	triple_sound2		; "ALL TOO EASY" (retail).  Deliberately NOT the
					; $4f the victory pose says, so the two beats are
					; different lines.  Was the
					; custom $63 read until the user had that clip
					; taken out of the ROM (stlaugh_patch.txt note
					; 41); kahn_victory (MKCANNED.ASM) moved to the
					; same retail line.  $63 is a dead table row now,
					; so leaving it here was 2 s of silence with the
					; sequence still holding for it.
	movi	019h,a9
	calla	get_char_ani		; a_sk_talkdown
	movk	3,a0
	jsrp	mframew			; point
	sleep	ksr_point_gap
	movk	3,a0
	jsrp	mframew			; ...and again
	sleep	ksr_taunt_pause		; a beat...
	clr	a0
	jsrp	ksr_walk_to		; ...then in to the body, to reach down
*
* 3. He is mine.  takeover_him parks his process in wait_forever; every
*    pose and every pixel of his position from here comes from ksr_place,
*    in THIS process, once a step.
*
*    REPELL OFF FIRST.  The lane puts him inside Kahn's own box on almost
*    every step, and repell (MAIN.ASM) - the per-frame shove that keeps two
*    fighters from overlapping - answered that by writing Kahn's oxpos:
*    measured with a write tap, 375 -> 10751 on the first step, both men
*    thrown off the stage.  Every stock fatality that holds a man in
*    reach does the same (disable_repell, MKDEATH.ASM).  It is a countdown,
*    and this outlasts the round.
*
	movi	040h*40,a0
	move	a0,@f_norepell,w
	movi	wait_forever,a7
	calla	takeover_him
	calla	me_in_back		; the WAX draws him over Kahn (slot 5
	callr	ksr_refront		;   sorts after slot 0)

	movk	01ch,a9			; sk_anitab2[1ch] = a_sk_soulrip
	calla	get_char_ani2
	clr	a0
	move	a0,*a13(p_store4),l	; step 0
	move	a0,*a13(p_store5),l	; he is not withering yet
	move	a0,*a13(p_store3),l	; ...and the arena has not gone dark

ksrk_step
	callr	ksr_row			; a0 = this step's row
	move	a0,a0
	jreq	ksrk_last		; the terminator - the lane is done
*
* The reach is done and he is about to LIFT him (the first step whose victim
* pose is off the floor - row 0 is flat on his back).  Before that step
* draws anything: the arena goes dark and the fatality sting plays, and he
* HOLDS, bent over him on the last reach frame, while it does.  The user:
* "reach down to pick up, hold for a few ticks as the fatality jingle
* starts then pick up".  The same two procs both his other finishers create
* on their connect - and not on the killing hit, which ends like any round.
*
	move	*a13(p_store3),a0,l
	jrne	ksrk_lit		; already dark
	callr	ksr_row
	move	*a0(ksr_pose),a0,w
	jreq	ksrk_lit		; still reaching
	movk	1,a0
	move	a0,*a13(p_store3),l
*
* ...but not over his own line.  make_db_tone opens by killing EVERY sound
* (it sends 0 before the sting), and "EAT SHIT AND DIE" is 2.02 s - it was
* cut off after 1.2 (the user: "it doesnt play the whole eat sound wav").
* So he stays bent over the man until the line has had ksr_line_len ticks.
*
ksrk_line
	move	@tick,a0,w
	move	@ksr_line_tick,a1,w
	sub	a1,a0
	zext	a0,w			; ticks since the line (16-bit wrap safe)
	cmpi	ksr_line_len,a0
	jrhs	ksrk_line9
	sleep	1
	jruc	ksrk_line
ksrk_line9
	push	a9
	create	pid_fade,death_blow_fader
	create	pid_fx,make_db_tone
	pull	a9
	movi	ksr_jingle_hold,a10
ksrk_jingle
	sleep	1
	dsj	a10,ksrk_jingle
ksrk_lit
	callr	ksr_row
	move	*a0(ksr_kadv),a1,w
	jreq	ksrk_placed
	calla	do_next_a9_frame	; Kahn's own frame
ksrk_placed
	callr	ksr_place		; the victim, posed and placed
*
* The soul is due this step and is not out yet: the sounds go first (the
* user: "have her suck sound play first before tsungs soul sound and a few
* ticks after the sound to have the soul leave").  Mileena's inhale - the
* sound do_body_suck opens her fatality with ($c9) - then Shang's own soul
* pull (green_soul's $c1), then the soul.  Here in the step loop and not in
* ksr_soul, because it sleeps and ksr_soul runs inside an mmtm.
*
	move	@ksr_soul_obj,a0,l
	jrne	ksrk_nosnd		; already out
	callr	ksr_row
	move	*a0(ksr_srow),a0,w
	jrn	ksrk_nosnd		; not due yet
	tsound	0c9h			; Mileena's suck
	sleep	ksr_suck_gap
	movi	rsnd_death_voice,a0	; ...and HE cries out as it takes hold -
	calla	calla_for_him		;   the short fatality scream, in his own
					;   voice (the user: "a small scream
					;   before soul leaves the body")
	sleep	ksr_scream_gap
	tsound	0c1h			; Shang's soul
	sleep	ksr_soul_lead
ksrk_nosnd
	callr	ksr_soul		; the soul, if this step has one
*
* The first step with the soul on screen is where the man stops being
* posed off the WAX and starts DYING - Shang's soul suck, do_drain's victim
* half, run in his own process (ksr_victim_wither).  The lane goes on
* without him: Kahn holds SHASOULRIP9 and the soul flies, and ksr_place
* stands down from here (p_store5).
*
	move	*a13(p_store5),a0,l
	jrne	ksrk_nowither		; already withering
	callr	ksr_row
	move	*a0(ksr_srow),a0,w
	jrn	ksrk_nowither		; no soul yet
	movk	1,a0
	move	a0,*a13(p_store5),l
	push	a9			; takeover_him owes nothing to a9, and
	movi	ksr_victim_wither,a7	;   a9 is Kahn's place in his lane
	calla	takeover_him
	pull	a9
ksrk_nowither

	callr	ksr_row
	move	*a0(ksr_hold),a10,w
	jrgt	ksrk_hold
	movk	1,a10
ksrk_hold
	sleep	1
	dsj	a10,ksrk_hold

	move	*a13(p_store4),a0,l
	addk	1,a0
	move	a0,*a13(p_store4),l
	jruc	ksrk_step

ksrk_last
*
* 4. The soul is in him.  Hold the pose and take the soul off the screen,
*    then wait for the husk: the man is withering, turning to a corpse and
*    dropping in his own process (ksr_victim_wither), on do_drain's clock,
*    which is a good deal longer than the soul's flight.
*
	tsound	0c2h			; the soul into his hand - Shang's
					; own, green_soul's closing sound
	callr	ksr_soul_delete		; ...and gone the moment its last frame
					; has had its hold (the user: "the last
					; soul frame should hide after its
					; finished" - it used to sit on Kahn for
					; another ksr_tail ticks)
	movi	ksr_tail,a10
ksrk_tail
	sleep	1
	dsj	a10,ksrk_tail

	movi	ksr_husk_wait,a10
ksrk_husk
	sleep	1
	move	@ksr_vic_done,a0,w
	jrne	ksrk_husk9
	dsj	a10,ksrk_husk
ksrk_husk9
	movi	ksr_tail,a10
ksrk_tail2
	sleep	1
	dsj	a10,ksrk_tail2

	callr	ksr_unfront
	movi	-1,a0
	move	a0,@f_ksoulrip,w	; the master process may declare the winner
*
* And he stays as he is - SHASOULRIP9, the husk held up in front of him -
* until the round tears down.  No check_winner_status: that would take him
* to player_1_wins / kahn_victory, he would let go to celebrate, and the
* husk would be left hanging in the air with nobody holding it.
*
	jauc	wait_forever

**************************************************************************
*											     *
*  ksr_victim_wither - the beaten man's own process from the tick his soul *
*  comes out.  a8 = him, a13 = his process.				     *
*											     *
*  This IS Shang Tsung's soul suck, his half of it: do_drain (MKDEATH.ASM) *
*  - the drained palette, his own MKSOUL.IMG wither frames off drain_table *
*  (DRAIN1-3, then DRAIN2,1,2,3) and the CORPSE husk, on the same numbers *
*  (6 and 8 a frame, 10 between, 030h on the husk).  do_drain drives them  *
*  from Shang's process through mframew_him; they are HIS lanes, so here   *
*  he runs them himself.  Unlike do_drain the husk does NOT drop - Kahn    *
*  keeps holding it.								     *
*											     *
**************************************************************************
ksr_victim_wither
*
* The drained palette - drain_table's first frame carries it (a PON>
* record), and the man on the OTHER side gets the alternate set, exactly
* as do_drain picks it: there it is "am I, Shang, player 1".
*
	movi	drain_table,a0
	calla	get_char_long		; a0 = my a_??drained
	move	a0,a9
	move	*a0,a0,l
	move	*a0,a0,l
	move	*a0(icmap),a0,l		; the drained palette
	move	*a13(p_otherguy),a1,l
	move	*a1(oid),a1,w
	cmpi	oid_p1,a1		; is Kahn player 1 ?
	jrne	ksrw3
	movi	alternate_suck_pals,a0
	calla	get_char_long		; ...then the right-side set
ksrw3	move	*a8(ochar),a1,w
	calla	drain_pal_fix		; Kitana blue / Mileena purple, either side
	calla	swpal

	movk	6,a0
	jsrp	mframew			; DRAIN1-3 - the wither
	sleep	10
	movk	8,a0
	jsrp	mframew			; DRAIN2,1,2,3 - still going
*
* The husk.  a_final_drain is CORPSE1A on CORPSE_P, one for everybody.
*
	movi	a_final_drain,a9
	move	*a9,a0,l
	move	*a0,a0,l
	move	*a0(icmap),a0,l
	calla	swpal
	calla	do_next_a9_frame
	sleep	030h
*
* ...and he STAYS IN KAHN'S GRIP.  do_drain lets its husk fall (a_corpse_drop);
* this one does not - the user's call: Kahn keeps holding what is left of
* him, up where the WAX's last victim offset hung him, through the round end.
* Nothing lowers him: ksr_place stood down when the wither began, and this
* process parks here.
*
	movk	1,a0
	move	a0,@ksr_vic_done,w
	jauc	wait_forever

**************************************************************************
*											     *
*  ksr_row - a0 = the current step's row of ksr_script, or 0 at the end.   *
*  Read from p_store4 every time rather than carried in a register: a	     *
*  pointer held across a calla is the runaway in				     *
*  [[reference_loop_counter_across_calls]].					     *
*											     *
**************************************************************************
ksr_row
	mmtm	sp,a1
	move	*a13(p_store4),a0,l
	sll	7,a0			; ksr_rowsize = 128 bits a row.  A SHIFT,
					; not an mpyu: that one lands its product
					; in the ODD register of the pair, which
					; is a standing trap in this codebase
	addi	ksr_script,a0
	move	*a0(ksr_hold),a1,w	; the terminator is an all-zero row, and
	jrne	ksrr9			; a hold of 0 is what marks it
	clr	a0
ksrr9	mmfm	sp,a1
	rets

**************************************************************************
*											     *
*  ksr_place - pose the victim for this step and put him where the WAX	     *
*  put him: his anipoint at Kahn's, plus the row's offset.		     *
*											     *
*  Posed every step, not once, and the pose comes first: match_ani_points  *
*  copies the anchor outright, so where the pose left him does not matter. *
*  The same shape, and the same sign rule, as kahn_slam_place (MKBOSS.ASM) *
*  - adjust_him_xy negates x itself when he is mirrored, so -dx / -dy is   *
*  what goes in.  See doc/IMGTOOL_LANE_CONVERSION.md section 5.		     *
*											     *
**************************************************************************
ksr_place
	mmtm	sp,a0,a1,a2,a3,a9,a10,a11
	move	*a13(p_store5),a0,l
	jrne	ksrp9			; he is withering in his own process
	callr	ksr_row
	move	a0,a3
	jreq	ksrp9

	movi	ksr_victim_poses,a0
	calla	get_his_char_long	; a0 = his pose list
	move	a0,a9
	jreq	ksrp9			; a boss - refused long before this
	move	*a3(ksr_pose),a1,w
	sll	5,a1
	add	a1,a9			; ...this step's row of it
	push	a3
	calla	do_his_next_a9_frame
	calla	match_him_with_me_f	; turned round to face me - every entry
					; of the WAX's victim slot is mirrored
	pull	a3			; ...and a3 held across BOTH calls:
					; match_ani_points uses a1-a3 as scratch,
					; and a row pointer it had rewritten threw
					; him 21,000 px off the stage (write tap)
	move	*a3(ksr_vdx),a0,w
	neg	a0
	move	*a3(ksr_vdy),a1,w
	neg	a1
	calla	adjust_him_xy
ksrp9	mmfm	sp,a0,a1,a2,a3,a9,a10,a11
	rets

**************************************************************************
*											     *
*  ksr_soul - the green soul, for the steps that have one.		     *
*											     *
*  It is the victim's own a_??_sucked_in lane (MKDIE.ASM) - the frames	     *
*  Mileena's inhale fatality draws - in a green palette.  Built by hand	     *
*  rather than through gmo_proc for MKSOULS' reason: these are PLAYER	     *
*  frame records with no palette long on the end, and object_setup reads   *
*  one.										     *
*											     *
**************************************************************************
ksr_soul
	mmtm	sp,a0,a1,a2,a3,a4,a5,a9,a10,a11
	callr	ksr_row
	move	a0,a11
	jreq	ksrsl9

	move	*a11(ksr_srow),a0,w
	jrn	ksrsl_none		; -1: no soul on screen this step

	movi	sucked_in_anis,a0
	calla	get_his_char_long	; a0 = his suck lane
	move	a0,a10
	jreq	ksrsl9
	move	*a11(ksr_srow),a0,w
	sll	5,a0
	add	a0,a10
	move	*a10,a10,l		; a10 = this step's shape list
	jreq	ksrsl9

	move	@ksr_soul_obj,a0,l
	jrne	ksrsl_have
	callr	ksr_soul_build		; first visible step - make it
	move	@ksr_soul_obj,a0,l
	jreq	ksrsl9			; no object free - the rip plays without
					; the soul rather than not at all
ksrsl_have
	push	a8
	move	a0,a8			; ani2 and the placement want it in a8
	move	a10,a0
	calla	ani2			; lay this frame into ksr_soul_mpram
	pull	a8

	move	@ksr_soul_obj,a0,l
	calla	match_ani_points	; my anchor, and my facing
	push	a8
	move	@ksr_soul_obj,a8,l
	calla	flip_multi		; ...then turned round, like the WAX
	move	*a11(ksr_sdx),a0,w
	neg	a0
	move	*a11(ksr_sdy),a1,w
	neg	a1
	calla	multi_adjust_xy
	pull	a8
	jruc	ksrsl9

ksrsl_none
	callr	ksr_soul_delete
ksrsl9	mmfm	sp,a0,a1,a2,a3,a4,a5,a9,a10,a11
	rets

;
; ksr_soul_build - a10 = frame one's shape list.  Leaves the object in
; @ksr_soul_obj, or 0 if the pool is empty.
;
ksr_soul_build
	mmtm	sp,a0,a1,a2,a4,a5,a8,a9,a10
	calla	getobj
	move	a0,a9
	jreq	ksrsb_fail

	move	a10,a5
	move	*a5,a5,l		; its first piece
	move	*a5(icontrol),a4,w
	ori	dmago,a4
	ori	dmawnz,a4
	move	a4,*a9(oflags),w
	movi	ksr_soul_mpram,a0
	move	a0,*a9(oimg),l
	movi	m_multipart,a0
	move	a0,*a9(oflags2),w	; FRESH - a recycled slot could carry a
					; previous owner's m_shadow, and a soul
					; does not cast one
	movi	ksr_soul_pals,a0
	calla	get_his_char_long	; the green ramp for HIS art
	calla	getfpal
	jreq	ksrsb_nopal		; pool exhausted - a0 is garbage
	move	a0,*a9(opal),w
ksrsb_nopal
	movi	oid_fx,a0
	move	a0,*a9(oid),w
	move	*a8(ochar),*a9(ochar),w
	movi	front_z+2,a0
	move	a0,*a9(ozval),l		; in front of both of us

	move	a9,a8			; ani2 wants the object in a8
	move	a10,a0
	calla	ani2
	move	a8,a0
	calla	insobj
	move	a8,@ksr_soul_obj,l
	mmfm	sp,a0,a1,a2,a4,a5,a8,a9,a10
	rets
ksrsb_fail
	clr	a0
	move	a0,@ksr_soul_obj,l
	mmfm	sp,a0,a1,a2,a4,a5,a8,a9,a10
	rets

;
; ksr_soul_delete - take it off the screen, if it is on.
;
ksr_soul_delete
	mmtm	sp,a0
	move	@ksr_soul_obj,a0,l
	jreq	ksrsd9
	calla	delobjp
	clr	a0
	move	a0,@ksr_soul_obj,l
ksrsd9	mmfm	sp,a0
	rets

**************************************************************************
*											     *
*  ksr_walk_to - JSRP.  Walk (or back off) until the two anipoints are the  *
*  lane's first-step offset + a0 apart, then stand in stance1.		     *
*  a8 = Kahn, a13 = his process.  The target lives in p_store2 (free until *
*  ksr_refront takes it), because a register owes nothing across the	     *
*  animator.  His own walk lanes, not kahn_stalk_a11 / kahn_backup_a11:    *
*  those call drone_beware, which calls check_winner_status - which is	     *
*  where this is running from.						     *
*											     *
**************************************************************************
ksr_walk_to
	movi	ksr_script,a1
	move	*a1(ksr_vdx),a1,w
	addk	ksr_slack,a1
	add	a0,a1
	move	a1,*a13(p_store2),l	; the distance to stand at
	calla	face_opponent
	callr	ksr_x_dist
	move	*a13(p_store2),a1,l
	cmp	a1,a0
	jrhi	kwt_fwd			; too far - walk in
	addk	8,a0
	cmp	a1,a0
	jrhs	kwt_stop		; close enough either way - stay put
	calla	drone_walkb_setup	; too close - back off
	movi	ksr_walk_ticks,a10
kwt_back
	sleep	1
	calla	next_anirate
	callr	ksr_x_dist
	move	*a13(p_store2),a1,l
	cmp	a1,a0
	jrhs	kwt_stop
	dsj	a10,kwt_back
	jruc	kwt_stop
kwt_fwd
	calla	drone_walkf_setup
	movi	ksr_walk_ticks,a10
kwt_walk
	sleep	1
	calla	next_anirate
	callr	ksr_x_dist
	move	*a13(p_store2),a1,l
	cmp	a1,a0
	jrls	kwt_stop
	dsj	a10,kwt_walk
kwt_stop
	calla	stop_me
	clr	a9
	calla	get_char_ani
	calla	do_next_a9_frame	; stance1 BY HAND - nothing else redraws
					; him out of the walk (see kbigp_whiff)
	retp

**************************************************************************
*											     *
*  ksr_x_dist - a0 = how far apart the two anipoints are, unsigned.	     *
*											     *
**************************************************************************
ksr_x_dist
	mmtm	sp,a1
	move	*a13(p_otherguy),a1,l
	move	*a1(oxpos),a0,w
	move	*a8(oxpos),a1,w
	sub	a1,a0
	jrge	ksrxd9
	neg	a0
ksrxd9	mmfm	sp,a1
	rets

**************************************************************************
*											     *
*  ksr_refront / ksr_unfront - the victim is drawn OVER Kahn for the whole *
*  lane (the WAX's slot 5 sorts after slot 0).  me_in_back's ozval is	     *
*  inert on a live object - insobj links by z at insert time only - so	     *
*  both have to be re-linked, which is kahn_slam_refront's finding.	     *
*											     *
**************************************************************************
ksr_refront
	mmtm	sp,a0,a1,a2
	move	*a8(ozval),a0,l
	move	a0,*a13(p_store1),l	; the order the round had...
	move	*a13(p_otherguy),a0,l
	move	*a0(ozval),a1,l
	move	a1,*a13(p_store2),l	; ...for both of us
	move	a8,a0
	movi	back_z,a1
	callr	ksr_obj_set_z		; me underneath
	move	*a13(p_otherguy),a0,l
	movi	front_z,a1
	callr	ksr_obj_set_z		; ...the man in front
	mmfm	sp,a0,a1,a2
	rets

ksr_unfront
	mmtm	sp,a0,a1,a2
	move	*a13(p_store1),a1,l
	move	a8,a0
	callr	ksr_obj_set_z
	move	*a13(p_store2),a1,l
	move	*a13(p_otherguy),a0,l
	callr	ksr_obj_set_z
	mmfm	sp,a0,a1,a2
	rets

;
; ksr_obj_set_z - a0 = object, a1 = new z.  Re-links it, because ozval on
; its own is inert once an object is on the list.
;
; Unlinked BY HAND rather than through delobj / delobjp, which is
; kahn_obj_set_z's (MKBOSS.ASM) finding and matters here for the same
; reason: both of those push the block onto the free stack, and these are
; PLAYER objects - still pointed at by p1_obj/p2_obj and walked by the
; shadow pass.  Freeing one hands a live object to the next allocator.
;
ksr_obj_set_z
	mmtm	sp,a2,a3,a4
	movi	objlst,a4
ksrz_walk
	move	a4,a3			; a3 = prev
	move	*a4,a4,l
	jreq	ksrz_done		; not on this list - leave it alone
	cmp	a4,a0
	jrne	ksrz_walk

	move	a0,a2
	move	*a2,*a3,l		; unlink - and do NOT free the block
	move	a1,*a2(ozval),l
	calla	insobj			; back on, sorted to the new z
ksrz_done
	mmfm	sp,a2,a3,a4
	rets

	.endif			; ksoulrip

	.end
