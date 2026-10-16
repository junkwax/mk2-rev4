**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
* 											     *
*  module: mksouls.asm ---  Shang Tsung defeated: the souls escape	     *
* 											     *
**************************************************************************
	.file	"mksouls.asm"
	.width	132
	.option	b,d,l,t
	.mnolist
*
* get the system stuff
*
	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	imgtbl.glo
	.text
	.ref	flash_col,flash_ticks,flash_back	; MKDISP.ASM block-fill flash
	.ref	MK1FIRE_P				; IMGPAL6.ASM
	.ref	SOULSMK_P,SOULNOB_P,SOULERM_P,SOULJAD_P,SOULKHM_P	; SOULPAL.ASM

**************************************************************************
*											     *
*  MK1's ending, rebuilt on MK2's Shang.  In the one-player game the CPU    *
*  Shang is fought in KAHN'S ARENA, right before Kintaro and Shao Kahn,	     *
*  and when he loses the deciding round there is no FINISH HIM.  Instead:   *
*											     *
*    1. he is Kintaro for a moment (MK1's Shang lost as Goro), then turns   *
*       back into himself through retail's own Shang<->Kintaro poof	     *
*    2. he shakes on the lane authored in data/TSHANGEND.WAX - his own    *
*       MK2 stumble and low-hit poses - as the arena's wall flashes	     *
*    3. every 27 ticks a copy of him peels off, drifts clear, runs his	     *
*       ordinary MORPH into the next fighter on the roster, and is that	     *
*       fighter: stumble back, knocked flat, burnt away by the MK1 flame    *
*    4. when the last one is ash: six flashes, and he goes down		     *
*											     *
*  MK1 builds its souls the same way - there is no "soul" sprite in either  *
*  game, only a Shang copy, his morph lane and the fighter's reactions.     *
*  Every number below is MK1's own, read out of mk.zip by		     *
*  tools/mk1_shang_souls_extract.py.  doc/MK2_SHANG_SOUL_ESCAPE.md has the  *
*  whole story; doc/MK1_SHANG_SOUL_ESCAPE.md has the original.		     *
*											     *
*  Control: finish_him_sequence (MAIN.ASM) asks soul_escape_due, and on a   *
*  yes jumps to soul_escape_sequence instead of running FINISH HIM.  That   *
*  sets winner_status = 4, which check_winner_status (JOY.ASM) dispatches   *
*  to soul_escape_status in BOTH fighters' processes: the loser (Shang)	     *
*  runs the show, the winner stands and watches until the master process   *
*  declares him the winner the ordinary way.				     *
*											     *
**************************************************************************

soul_cadence	.set	27		; ticks between souls	(MK1 FFDD32D0)
soul_hold	.set	8		; stance copy, before it turns (FFDD3560)
soul_morph_t	.set	6		; per blend frame	(FFDD35D0)
soul_stumble	.set	000040004h	; [4 ticks, 4 frames]	(FFDD3700)
soul_fall_t	.set	3		; knockdown speed	(FFDD37F0)
soul_fire_t	.set	5		; flame speed		(FFDD41A0)
soul_speed_rng	.set	030000h		; x speed 2.0 + rand(3.0) px/tick
soul_speed_min	.set	020000h		;			(FFDD3B30/3B90)
soul_tail	.set	110		; last soul's life after it is spawned
soul_flashes	.set	6		; screen flashes	(FFDD2990)
kintaro_hold	.set	40		; ticks he stands as Kintaro
soul_pool_n	.set	4		; souls (and flames) alive at once, at most
*
* Where the flame sits on a soul that has just been knocked flat, in px
* toward his FEET from his anchor (the knockdown lanes lay the body out
* behind the anchor, the direction he is facing away from).
*
soul_fire_dx	.set	0
*
* Kintaro's arrival, once Shang is face down.
*
					; of them - they end the stomp all but
					; standing on each other
soul_victory_rate .set	6		; ticks a frame for the winner's victory
					; while he watches (029h) - 6 is what
					; generic_victory_ani plays it at
soul_kin_wait	.set	0100h		; ticks to wait for the arena prop to leap
soul_kin_top	.set	00c0h		; where he drops in from, above the frame
*
* He comes down, stomps three times and pounces away.  The stomp is
* goro_psycho_stomp (MKBOSS.ASM) whole - the teleport-and-drop he does in a
* fight - picked up where the player can actually see it: 087h and the long
* roar 0b1h, he is gone, and he comes back down over the body on TIGERJUMP5
* at its own 040000h under 010000h, landing on goro_psycho_land_frame's
* pose with shake_a11 0000a000fh and 0b2h.
*
* The climb is NOT played.  The move sets ograv negative and drives him to
* 0110h off the ground - 272 px, off the top of a 254-line screen - so on
* screen it already IS a disappearance; drawing it as an arc instead just
* made him jump absurdly high.
*
soul_kin_rate	.set	3		; ticks a row on the stomp lane - the
					; 00003000ah animate_a9 rate
soul_kin_drop_v	.set	040000h		; flight_call's own initial y ...
soul_kin_grav	.set	010000h		; ... and its gravity, so he comes down
					; at the rate the move drops him.
					; The DISPLAY walker adds oyvel to oyval
					; for every object (dclipl, MKDISP.ASM),
					; but nothing adds ograv for a bare one,
					; so the drop loop does that itself
soul_kin_hang	.set	8		; ticks held at the top before he comes
					; down - the move's own sleep 8
soul_kin_stomps	.set	3		; landings before he pounces away
soul_kin_land_t	.set	4		; ticks a frame on the ground rows
soul_kin_bail_up .set	-0f0000h	; the leap OUT is harder than a stomp
					; hop: he has to clear the frame rather
					; than come back down in it
soul_kin_bail_t	.set	040h		; ticks to let him get gone before the
					; object is deleted regardless
soul_kin_ground	.set	096h		; ochar_ground_offsets[ft_goro] - his
					; grounded anchor, the same number
					; ground_ochar would put on him
soul_burst_lift	.set	018h		; px above the body's own bottom edge
					; that the burst goes off - it sprays UP
					; and out, so a point right on the floor
					; puts half of it under the stone
* The burst under the stomp is Ermac's: soul_stomp_blood (MKBLOOD.ASM),
* blood_procs slot 01bh, which is ermac_splash_blood's three BLDXPD splats
* with the step laid sideways for a body that is already on the floor.
* Everything about it lives there, so there is no second copy to drift.
soul_kin_warp_snd .set	087h		; he is in the stands, then he is here:
					; the teleport sound the in-fight stomp
					; opens with (goro_psycho_stomp, MKBOSS)
soul_kin_launch_snd .set 0b1h		; the long goro roar the in-fight stomp
					; launches on, same place in its beat
soul_kin_quake_snd .set	0b2h		; ...and its quake, on each landing
soul_kin_roar_snd .set	0adh		; goro_roar's own sound
soul_kin_roar_t	.set	3		; ticks per TIGERROAR row - animate_a9
					; 000030007h, goro_roar's rate
soul_kin_roar_hold .set	00ah		; held at full stretch, as goro_roar does
*
* Where the three pieces land, in px along the floor from the LEFT EDGE of
* the body as it lay - mpart_bounds measures that, and it comes back in the
* same space as oxpos, so the pieces can be placed outright.  He goes down
* head first, so the order along the stone is head, torso, legs.
*
soul_part_head	.set	-024h		; out past where his head was
soul_part_torso	.set	0000h		; the torso on the spot
soul_part_legs	.set	0050h		; and the legs kicked clear of it
soul_part_lift	.set	0018h		; px to pull them back UP off that
					; bottom edge.  mpart_bounds measures the
					; RECORDS, and the prone frame's strips
					; run about this far past his last drawn
					; row, so resting a piece on the raw
					; number puts it through the stone and
					; off the bottom of the screen.  It is
					; the same overshoot soul_burst_lift
					; corrects for the explosion

	.bss	f_soulesc,16,1		; 0 idle / 1 running / -1 finished
	.bss	soul_shang,32,1		; Shang's object
	.bss	soul_done,16,1		; spawner finished: every soul is ash
	.bss	soul_bg_stop,16,1	; tell the sky flash to put the sky back
	.bss	soul_winchar,16,1	; the winner's fighter (mirror palette)
	.bss	soul_pool,32*soul_pool_n,1	; soul objects
	.bss	soul_fire,32*soul_pool_n,1	; flame objects
	.bss	f_soul_kintaro,16,1	; 0 idle / 1 leap / 2 he has left the stands
	.bss	f_soul_knock,16,1	; 1 = the winner is standing in the stomp
	.bss	f_soul_silent,16,1	; 1 = this match ended in the souls, so
					; bonus_count prints no "X WINS" line -
					; Kintaro is standing over the body and
					; the next battle IS him, so a victory
					; banner between the two reads wrong
	.bss	soul_kintaro,32,1	; the foreground Kintaro
	.bss	f_soul_kahnup,16,1	; 1 = Shao Kahn is already on his feet in
					; the arena for the next match - he stood
					; up for the souls and does not sit back
					; down between them and Kintaro
	.bss	soul_part_dx,16,1	; ...and the one being placed
	.bss	soul_part_y,16,1	; the floor the three pieces lie on, and
	.bss	soul_part_x,16,1	;   the left edge they are spaced from
	.bss	soul_alive,16,1		; soul processes still running
	.bss	f_soul_noladder,16,1	; skip the mountain before the NEXT battle:
					; survives end_of_match_chores, which is
					; why it is not f_soul_silent
*
* The dropping Kintaro's shape RAM.  A PLAIN .BSS BUFFER, not a gmo_proc
* process block, and for two reasons.
* a_goro_stomp is a PLAYER lane, and player frame records are 112 bits -
* geometry, SAG, control - with NO palette long on the end.  gmo_proc's
* object_setup reads one (*a5(icmap)) because the lanes it was written for,
* like a_arena_goro_idle's gorostd1a, are PON> records with `.long
* GOROBRE_p' on them.  Hand it a player lane and it takes the next record's
* first two words as a palette pointer and lays every piece at the wrong
* stride - Kintaro arrives as confetti.  So he is built the way the pulp
* here is: getobj, our own buffer, and the palette named outright.  And a
* process block only holds 13 pieces (pdata..prcsiz, 112 bits each), which
* the widest stomp frames would write straight past.
*
	.bss	soul_kin_mpram,mp_ramsize,1

**************************************************************************
*											     *
*  soul_escape_due - carry set when this match ends in the souls	     *
*  escaping: the one-player CPU Shang just lost it.			     *
*											     *
*  Called at the top of finish_him_sequence (MAIN.ASM), so the loser is    *
*  the side whose bar is empty.  p?_char is the SELECTED fighter, so a	     *
*  Shang wearing somebody else's form still reads ft_st here.		     *
*											     *
*  Trashes a0-a2.							     *
*											     *
**************************************************************************
soul_escape_due
	move	@p1_bar,a0,w
	jrne	sed_p2
	move	@p1_char,a1,w		; p1 lost
	move	@p1_state,a2,w
	jruc	sed_test
sed_p2	move	@p2_bar,a0,w
	jrne	sed_no			; nobody lost ?!
	move	@p2_char,a1,w		; p2 lost
	move	@p2_state,a2,w
sed_test
	cmpi	ft_st,a1
	jrne	sed_no			; the loser is not Shang
	cmpi	ps_active,a2
	jreq	sed_no			; a human Shang - ordinary FINISH HIM
	calla	count_active_players
	cmpi	1,a0
	jrne	sed_no			; one-player game only
	setc
	rets
sed_no	clrc
	rets

**************************************************************************
*											     *
*  soul_escape_sequence - the master process, in place of FINISH HIM.	     *
*  Reached by jauc from finish_him_sequence, which was itself jsrp'd, so   *
*  this ends in retp and the caller carries on declaring the winner.	     *
*											     *
**************************************************************************
soul_escape_sequence
	clr	a0
	move	a0,@soul_done,w
	move	a0,@soul_bg_stop,w
	movk	1,a0
	move	a0,@f_soulesc,w		; running - nothing lands now (JOY.ASM)
*
* The winner's fighter, for the one soul that is his own: it wears the
* mirror-match palette, as the second of him on screen (MK1 does the same).
*
	move	@p1_char,a1,w
	move	@p1_bar,a0,w
	jrne	ses_win
	move	@p2_char,a1,w
ses_win	move	a1,@soul_winchar,w

*
* The blow that finished him throws the winner clear before any of this
* starts.  Same beat, and the same mechanism, as the stomp landing at the
* other end (soul_kintaro_knock): raise the flag and let the winner take
* r_quake in his OWN process, out of soul_escape_status's idle loop, which
* is the first thing that loop does.  Unconditional here - he has just
* landed a hit, so he is standing in it by definition.
*
	movk	1,a0
	move	a0,@f_soul_knock,w
	movk	1,a0
	move	a0,@f_soul_silent,w	; no "X WINS" when this match ends
	movk	1,a0
	move	a0,@f_soul_noladder,w	; and no mountain before the next one
	movk	4,a0
	move	a0,@winner_status,w	; souls mode (JOY.ASM status_jumps)
*
* MK1 opens on six flashes while the loser lies there (FFDD2990).  Shang
* picks up winner_status 4 as soon as he is back on his feet, whenever that
* is, so these run on their own clock.
*
	movk	soul_flashes,a10
ses_fl	callr	soul_screen_flash
	sleep	8
	dsj	a10,ses_fl
*
* Now it is Shang's show.  Wait for him to lie down, with a ceiling in case
* he is somehow never back on his feet to see status 4.
*
	movi	0c00h,a10
ses_wt	sleep	1
	move	@f_soulesc,a0,w
	cmpi	-1,a0
	jreq	ses_done
	dsj	a10,ses_wt
ses_done
	clr	a0
	move	a0,@f_soulesc,w
	retp

**************************************************************************
*											     *
*  soul_screen_flash - one MK1 screen flash: the block fill, white, OVER   *
*  the art, four ticks (MKDISP flash_pass).  The HUD is left alone.	     *
*											     *
**************************************************************************
soul_screen_flash
	.if	srtflash
	movi	bpal_white,a0
	move	a0,@flash_col,w
	clr	a0
	move	a0,@flash_back,w
	movk	4,a0
	move	a0,@flash_ticks,w
	.endif
	rets

**************************************************************************
*											     *
*  soul_escape_status - winner_status 4, from check_winner_status (JOY.ASM) *
*  in either fighter's process.  Like finish_him, it never returns.	     *
*											     *
**************************************************************************
soul_escape_status
	pull	a1			; no retreat / no return
	move	@p1_bar,a1,w
	move	*a13(procid),a0,w
	cmpi	pid_p1,a0
	jreq	ses3
	move	@p2_bar,a1,w
ses3	move	a1,a1
	jreq	soul_shang_begin	; my bar is empty: I am the beaten Shang
*
* The winner stands and watches.  When the master process puts
* winner_status back to 1 or 2, check_winner_status takes him to his
* victory the ordinary way.
*
	calla	stop_me
	calla	disable_all_buttons
	calla	face_opponent
*
* He takes his VICTORY and KEEPS it - through the souls, the stomp and the
* silent round end, up to the Kintaro match, where the new round starts him
* on his stance.  va_soul_stand (MKCANNED.ASM) holds whatever pose he is in
* rather than replaying or standing him up.  Ani 029h is the victory lane
* and every anitab1 carries it (generic_victory_ani reaches it the same
* way); animate_a9 plays it once and leaves him on its last pose.
*
* NOT while a fall is still owed him.  He is thrown down TWICE here - by the
* blow that finishes Shang, and by Kintaro's landing - and both come back
* through this branch afterwards.  Taking the pose only once f_soul_knock is
* clear means he celebrates AFTER getting up, both times; taking it on
* arrival instead meant he celebrated, was knocked out of it, and stood in
* his fighting stance for the rest of the sequence.
*
	move	@f_soul_knock,a0,w
	jrne	sesw			; a fall is owed - take it first
	movi	(soul_victory_rate*010000h)+029h,a9
	jsrp	animate_a9		; his victory, and he holds it
sesw	sleep	1
*
* Kintaro landed on top of him.  r_quake wants to be entered in the
* VICTIM's own process, which is exactly where this loop is running, and it
* leaves through reaction_exit - so he comes back through
* check_winner_status and lands back here, still watching.
*
	move	@f_soul_knock,a0,w
	jreq	sesw2
	clr	a0
	move	a0,@f_soul_knock,w
	jauc	r_quake
sesw2	move	@winner_status,a0,w
	cmpi	4,a0
	jreq	sesw
	calla	check_winner_status	; -> player_1_wins / player_2_wins
	jauc	wait_forever

**************************************************************************
*											     *
*  soul_shang_begin - the beaten Shang's own process from here on.	     *
*  a8 = his object, a13 = his process.					     *
*											     *
**************************************************************************
soul_shang_begin
	move	a8,@soul_shang,l
	calla	stop_me
	calla	disable_all_buttons
	calla	set_no_block
	move	a8,a0
	calla	clear_inviso
	calla	face_opponent
	movi	act_stunned,a0
	move	a0,*a13(p_action),w
*
* 1. He has to be HIMSELF for this: the CPU Shang is usually wearing somebody
*    else when he goes down.  If he is, retail's own transformation - the
*    flash and flame poof of do_kintaro_fatal - covers the change back.  If
*    he already lost as Shang there is nothing to hide, so nothing plays.
*
	callr	soul_screen_flash
	create	pid_fx,baby_flash
	create	pid_fx,baby_poof
	move	a8,*a0(pa10),l
	tsound	08dh			; the morph sound (shang_morph)
	sleep	0bh
*
* Make him HIMSELF, unconditionally, under that poof.
*
* Not just when his ochar says he is someone else: losing the round puts a
* morphed Shang's ochar back to ft_st on its own and does NOT put his
* COLOURS back, so he stands there as Shang drawn in Sub-Zero's palette -
* measured, pal=SUB_P with ochar=6, and his soul copies inherit it.
* player_normpal picks by ochar, so with ochar set first it is right
* whatever he was wearing.
*
	movi	ft_st,a0
	move	a0,*a8(ochar),w
*
* ...and player_normpal only restores anything when pm_alt_pal is up
* (pnorm_check_temp_alt: "not using an alternate palette - dont switch").
* shang_morph put Sub-Zero's colours on him THROUGH player_normpal, which
* clears that flag, so on its own this call sees "already normal" and leaves
* SUB_P where it is.  Raise it the way player_swpal does, then restore.
*
	move	*a13(p_flags),a0,w
	ori	pm_alt_pal,a0
	move	a0,*a13(p_flags),w
	calla	player_normpal
	calla	ground_ochar
	move	*a8(oypos),*a13(p_ganiy),w
	clr	a9
	calla	get_char_ani
	calla	do_next_a9_frame	; his own stance again
	move	a8,a0
	calla	clear_inviso
	sleep	8
*
* 2. The souls.  Objects first (a fixed pool - see soul_pool_init), then
*    the spawner and the sky flash, and he shakes until the last is ash.
*
	callr	soul_pool_init
	create	pid_soul,soul_spawner
	create	pid_soulbg,soul_bg_flash

*
* One frame, one hold, round and round until the last soul is ash.  Both
* the lane and soul_shake_rate come out of data/TSHANGEND.WAX
* (tools/shang_end_wax_import.py) - the project is the choreography.
*
* No +/-7 px nudge any more.  That was MK1's (FFDD3030) and the lane it
* went with had FOUR steps, so it cancelled; this project authors dx = 0 on
* every frame, and with SEVEN it would not cancel - he would walk 7 px
* sideways every time the lane wrapped.
*
	movi	a_soul_shake,a9
ssh1	calla	do_next_a9_frame
	sleep	soul_shake_rate
	move	@soul_done,a0,w
	jreq	ssh1
*
* 4. It is over.  Sky back, six flashes, and down he goes - his own
*    knockdown lane, the way dizzy_dude drops him when FINISH HIM runs out.
*
	movk	1,a0
	move	a0,@soul_bg_stop,w
	movi	pid_soul,a0
	movi	0ffffh,a1
	calla	kilall			; the spawner, and any straggler
	callr	soul_pool_hide

	movk	soul_flashes,a10
ssf1	callr	soul_screen_flash
	sleep	8
	dsj	a10,ssf1

	movk	00fh,a9
	calla	get_char_ani		; a_stkdown
	movk	4,a0
	jsrp	mframew			; part 1 - he falls
	calla	shake_n_sound
	movk	4,a0
	jsrp	mframew			; part 2 - flat on his back

	sleep	020h
	jsrp	soul_kintaro_finish	; ...and Kintaro comes down on him

	movi	-1,a0
	move	a0,@f_soulesc,w		; the master process can declare the winner
	jauc	wait_forever

**************************************************************************
*											     *
*  soul_kintaro_finish - the Kintaro prop in the stands leaps out of the   *
*  arena wall and lands on the body.					     *
*											     *
*  Runs in Shang's own process (a8 = his object) and ends with him gone,   *
*  so it is jsrp'd, not created: nothing else should declare the winner    *
*  until the stomp has landed.						     *
*											     *
*  Two halves, two scales.  The prop leaps at ITS size - SMTIGERJUMP1-4,   *
*  drawn for it (data/SMTIGER.LOD) - because it lives on baklst8 at the	     *
*  back of the arena, and it goes clean off the top of the screen: the two  *
*  Kintaros must never share a frame.  What comes down is the fight-size    *
*  one on his own stomp lane, a_goro_stomp, which MK4MIL already carries.   *
*											     *
*  He comes down, stomps THREE times and pounces away.  The stomp is	     *
*  goro_psycho_stomp (MKBOSS.ASM) - the teleport-and-drop - played from the *
*  point the player sees it: the bang, and him coming back down over the    *
*  body on TIGERJUMP5.  He arrives that way too, because the prop in the    *
*  stands did the first disappearance for him.				     *
*											     *
**************************************************************************
soul_kintaro_finish
	movk	1,a0
	move	a0,@f_soul_kintaro,w	; BGND.ASM: leap, prop
	movi	soul_kin_wait,a10
skf_wait
	sleep	1
	move	@f_soul_kintaro,a0,w
	cmpi	2,a0
	jreq	skf_drop
	dsj	a10,skf_wait
	retp				; no prop on this stage - nothing to drop
*
* He comes down where the body is, from above the frame.
*
skf_drop
	tsound	soul_kin_warp_snd	; gone from the stands, here instead
	callr	soul_kin_pounce		; a9 = part two - the pounce he comes
	callr	soul_kin_build		;   down on, the way the in-fight stomp
					;   holds it over the victim
	move	a8,a8
	jreq	skf_done		; no object free - skip him
	move	a8,@soul_kintaro,l
	move	@soul_shang,a0,l
	move	*a0(oxval),a1,l
	move	a1,*a8(oxval),l		; over the body
	move	@worldtly+16,a1,w
	subi	soul_kin_top,a1
	move	a1,*a8(oypos),w		; and well above the top of the screen
	movi	front_z-1,a0
	move	a0,*a8(ozval),l		; in the fighters' plane, under the flame
	move	a8,a0
	calla	insobj
	sleep	1			; let oxpos catch up with the oxval above,
	callr	soul_align_x		;   then centre him on the body - he is
					;   still above the frame, so the slide
					;   costs nothing to look at
*
* THE RIGGED STOMP.  This is goro_psycho_stomp (MKBOSS.ASM) three times
* over, not a lane written here: a_goro_stomp part one is the crouch and the
* take-off, part two is the two airborne poses, the landing frame is the one
* goro_psycho_land_frame picks, and he leaves the ground on his own
* -0a0000h and comes back on flight_call's gravity.  The only thing done by
* hand is integrating that gravity, because the display walker adds oyvel to
* oyval for a bare object but nothing adds ograv to oyvel for one.
*
* He arrives in the air, so the first beat is a fall with no take-off in
* front of it - the prop in the stands did that part (arena_goro_leap,
* ARENAKIN.ASM).
*
	jsrp	soul_kin_fall
*
* STOMP ONE, and the only one the winner feels.  Kintaro landing on the
* floor beside him is Jax's ground pound as far as he is concerned, so he
* takes the pound's own reaction and comes out of his victory pose for it
* (soul_kintaro_knock -> f_soul_knock -> r_quake, which is what do_quake
* hands its victim).
*
	jsrp	soul_kin_land
	callr	soul_kintaro_knock
*
* STOMP TWO, and STOMP THREE - the one that takes him apart.  Unrolled
* because they are not the same beat: the first is the only one the winner
* feels, and the third is the only one the body does.
*
	jsrp	soul_kin_hop
	jsrp	soul_kin_hop
*
* What is left of him bursts: Ermac's own blood explosion (BLDXPD1-13,
* a_blood_splash) rather than Shao Kahn's fist pulp, laid out SIDEWAYS -
* soul_stomp_blood (MKBLOOD.ASM) is ermac_splash_blood's three splats with
* the step moved out of the [Y:X] high half into the low one, because the
* body it is bursting is lying down, not standing up.
*
* WHERE is measured, not constant.  Ermac's splats hang off the victim's
* own anchor because his victim is upright; a fighter face down on the
* floor still carries the standing origin, which is 80-odd px in the air,
* so the burst went off over Kintaro's chest.  mpart_bounds gives the body's
* real bottom and the point is taken off that.
*
	move	@soul_shang,a8,l
	calla	mpart_bounds		; a0 top a1 bottom a2 left a3 right
	move	*a8(oypos),a0,w
	sub	a0,a1			; a1 = the floor under him, as an offset
					;   off the anchor the splats line up on
	subi	soul_burst_lift,a1
	sll	16,a1			; [Y:X], X = 0 - the spread is ssb_dx's
	move	a1,a9
	movi	blood_slot_soul_stomp,a0
	calla	create_blood_proc
*
* ...and he does not simply vanish under it: what the stomp left goes down
* on the floor in three pieces.
*
	move	@soul_shang,a8,l
	callr	soul_shang_parts
*
* Then he roars over the mess and pounces out of the frame the way he came
* into it, and the next match opens on the stage's own marks with him
* walking in as an ordinary opponent.
*
	move	@soul_kintaro,a8,l
	callr	soul_kin_face		; turn on the man he is about to fight
	jsrp	soul_kin_roar
	jsrp	soul_kin_bail
	movk	1,a0
	move	a0,@f_soul_kahnup,w	; Kahn stays standing for the next one
skf_nowin
skf_done
	retp


*
* soul_kin_roar - a8 = Kintaro.  What he does in a fight when he has won an
* exchange: goro_roar (MKBOSS.ASM), beat for beat - its sound, its rate, and
* its hold at full stretch - but walked with ani2, because this is a bare
* object and goro_roar animates a PLAYER off his process.
*
* a_goro_roar is in two parts: TIGERROAR1-8 out, a terminator, then the same
* rows back again.  Both are walked, so he comes down out of it and is
* standing straight for the take-off that carries him out of the frame.
*
* It SLEEPS, so it is a process subroutine of the caller's process, not a
* callr with its own stack - see arena_goro_leap (ARENAKIN.ASM) for what
* that mistake looks like.
*
soul_kin_roar
	movi	go_anitab1+(07h*32),a0
	move	*a0,a9,l		; a9 = a_goro_roar
	tsound	soul_kin_roar_snd
skr_out	move	*a9+,a0,l
	jreq	skr_held		; end of part one - he is at full stretch
	calla	ani2
	sleep	soul_kin_roar_t
	jruc	skr_out
skr_held
	sleep	soul_kin_roar_hold
skr_back
	move	*a9+,a0,l
	jreq	skr9			; end of part two - standing again
	calla	ani2
	sleep	soul_kin_roar_t
	jruc	skr_back
skr9	retp

*
* soul_kin_build - a9 = a player animation lane.  Returns a8 = a bare
* multipart object wearing frame one of it, or 0.
*
* This is get_multi_obj's job, and it cannot do it: it reads a palette off
* the frame record (*a5(icmap)), which only the PON> background records
* carry.  Everything else here is the same work by hand.
*
soul_kin_build
	mmtm	sp,a1,a2,a4,a5,a9,a10
	move	*a9,a2,l		; frame one's shape list
	move	a2,a2
	jreq	skb_fail
	calla	getobj
	move	a0,a10
	jreq	skb_fail
	move	a2,a5
	move	*a5,a5,l		; its first piece
	move	*a5(icontrol),a4,w
	ori	dmago,a4
	ori	dmawnz,a4
	move	a4,*a10(oflags),w
	movi	soul_kin_mpram,a0
	move	a0,*a10(oimg),l
	movi	m_multipart,a0
	move	a0,*a10(oflags2),w	; FRESH, like the pulp's - see there
	movi	TIGERDK_P,a0
	calla	getfpal
	jreq	skb_nopal		; pool exhausted - a0 is garbage
	move	a0,*a10(opal),w
skb_nopal
	movi	oid_soul,a0		; not oid_fx - bonus_count sweeps that
	move	a0,*a10(oid),w
	movi	ft_goro,a0
	move	a0,*a10(ochar),w	; ground_ochar reads this
	move	a10,a8
	move	a2,a0
	calla	ani2			; lay frame one into soul_kin_mpram
	mmfm	sp,a1,a2,a4,a5,a9,a10
	rets
skb_fail
	clr	a8
	mmfm	sp,a1,a2,a4,a5,a9,a10
	rets

**************************************************************************
*											     *
*  soul_align_x - a8 = Kintaro, on screen with his pieces laid.  Slide	     *
*  him until he is centred on what is left of Shang.			     *
*											     *
*  MEASURED, not a constant.  mpart_bounds gives the true extent of both    *
*  objects, so the stomp lands on the body whichever way he fell.	     *
*											     *
*  Reads oxpos, which is derived from oxval a frame behind, so the caller   *
*  must have let a tick pass since it placed him.  He moves in OXVAL, the   *
*  field skf_drop placed him with - writing oxpos instead does not error,   *
*  it silently teleports him off screen.				     *
*											     *
*  X ONLY.  Y is ground_ochar's, and the burst under him does its own	     *
*  placement off the body's anipoints (fist_pulp_place, MKZAP.ASM).	     *
*											     *
**************************************************************************
soul_align_x
	clr	a4			; Kintaro: oxval, the field skf_drop used
	mmtm	sp,a1,a2,a3,a5,a6,a7,a8,a9
	move	a8,a9			; a9 = me
	move	@soul_shang,a8,l
	move	a8,a8
	jreq	sal9
	calla	mpart_bounds		; a0 top a1 bottom a2 left a3 right
	move	a2,a6
	add	a3,a6
	sra	1,a6			; a6 = the body's middle
	move	a1,a7			; a7 = the body's bottom
	move	a9,a8
	calla	mpart_bounds
	move	a2,a5
	add	a3,a5
	sra	1,a5			; a5 = my middle
	sub	a5,a6			; a6 = how far sideways I must go
	sub	a1,a7			; a7 = and how far down (a1 = my bottom)
	move	*a9(oxval),a0,l
	move	a6,a2
	sll	16,a2			; oxval is 16.16
	add	a2,a0
	move	a0,*a9(oxval),l
sal9	mmfm	sp,a1,a2,a3,a5,a6,a7,a8,a9
	rets

*
* soul_kin_face - a8 = Kintaro.  Turn him to the winner, who is the man the
* next battle puts in front of him.  face_opponent is no use here: it works
* off a player process, and this is a bare object, so the flip is done by
* hand the way ARENAKIN's arena_goro_set_flip does it.
*
soul_kin_face
	mmtm	sp,a0,a1,a2,a3
	callr	soul_winner_obj
	move	a0,a0
	jreq	skfc9			; nobody left standing - leave him be
	move	*a0(oxpos),a1,w
	move	*a8(oxpos),a2,w
	clr	a3			; a3 = 1 if he should be flipped
	cmp	a1,a2			; a2-a1 > 0: the winner is to my LEFT
	jrle	skfc1
	movk	1,a3
skfc1	move	*a8(oflags),a0,w
	btst	b_fliph,a0
	jreq	skfc2
	move	a3,a3			; already flipped
	jrne	skfc9
	calla	flip_multi
	jruc	skfc9
skfc2	move	a3,a3			; not flipped
	jreq	skfc9
	calla	flip_multi
skfc9	mmfm	sp,a0,a1,a2,a3
	rets

*
* a_goro_stomp, the lane the in-fight stomp plays, read out of the table
* rather than through get_char_ani: he is a bare object with no player
* process behind him.  It is in two parts -
*
*     TIGERJUMP1 2 3 4 | 0 | TIGERJUMP5 6 2 | 0
*
* part one the crouch and the take-off, part two the airborne poses.
*
* soul_kin_lane1 -> a9 = part one, row 0.  Trashes a0.
*
soul_kin_lane1
	movi	go_anitab1+(0ah*32),a9
	move	*a9,a9,l
	rets

*
* soul_kin_pounce -> a9 = part two, row 0 (TIGERJUMP5 - the pounce).
*
soul_kin_pounce
	callr	soul_kin_lane1
skp1	move	*a9+,a0,l
	jrne	skp1			; past part one's terminator
	rets

*
* soul_kin_frame - a8 = him, a9 = a row of that lane.  Wear it.
*
* ani2, not do_next_a9_frame, for the reason he was built by hand: the
* animator wants a PLAYER with a process and ochar tables behind it.  It
* hands back everything but a0, because the fall loop carries its floor in
* a10/a11 across this and a calla owes them nothing.
*
soul_kin_frame
	mmtm	sp,a1,a2,a3,a4,a5,a6,a7,a10,a11
	move	*a9,a0,l
	calla	ani2			; preserves a9
	mmfm	sp,a1,a2,a3,a4,a5,a6,a7,a10,a11
	rets

*
* soul_kin_part - a8 = him, a9 = a row.  Play rows to the end of that part
* at soul_kin_rate and leave a9 ON the terminator, so the caller can step
* over it into the next part.  jsrp/retp: it sleeps.
*
soul_kin_part
skpt1	move	*a9,a0,l
	jreq	skpt9
	callr	soul_kin_frame
	addi	32,a9
	sleep	soul_kin_rate
	jruc	skpt1
skpt9	retp

*
* soul_kin_fall - a8 = him, above the frame over the body.  The second half
* of goro_psycho_stomp: TIGERJUMP5 - the pounce - held the whole way down,
* because the move's flight_call passes never_ani and does not animate
* through the fall either, at its own 040000h under 010000h.  a11 is his
* grounded anchor, ground_y less ochar_ground_offsets[ft_goro], the line
* ground_ochar puts him on too.
*
* jsrp/retp: it sleeps.
*
soul_kin_fall
	pushp	a11
	callr	soul_kin_pounce
	callr	soul_kin_frame		; TIGERJUMP5, the pounce
	movi	soul_kin_drop_v,a0
	move	a0,*a8(oyvel),l
	move	@ground_y,a11,w
	subi	soul_kin_ground,a11
skfl1	move	*a8(oyvel),a0,l
	addi	soul_kin_grav,a0
	move	a0,*a8(oyvel),l		; dclipl adds this to oyval for us
	sleep	1
	move	*a8(oypos),a0,w
	cmp	a11,a0
	jrlt	skfl1
	clr	a0
	move	a0,*a8(oyvel),l		; down: stop him dead, ground_ochar
	move	a0,*a8(ograv),l		;   puts him on the line exactly
	pullp	a11
	retp

*
* soul_kin_hop - a8 = him, on the floor.  The FRONT half of the same move,
* which is a teleport: 087h and the long roar, and he is not there any more
* - he is back above the frame over the body, where the climb to 0110h off
* the ground would have put him.  None of that climb is played, because
* none of it is on screen; what the player sees of goro_psycho_stomp is the
* bang, the pause, and him coming back down.
*
* jsrp/retp: it sleeps.
*
soul_kin_hop
	tsound	soul_kin_warp_snd	; 087h, the teleport it opens with
	tsound	soul_kin_launch_snd	; 0b1h, the long goro roar
	move	@worldtly+16,a0,w
	subi	soul_kin_top,a0
	move	a0,*a8(oypos),w		; gone from the floor, up out of frame
	sleep	soul_kin_hang		; its own sleep 8 at the top
	jsrp	soul_kin_fall
	jsrp	soul_kin_land
	retp

*
* soul_kin_land - one landing.  Ground him, quake, shake the screen and
* hold goro_psycho_land_frame's own pose - the FIRST row of the lane, which
* is also where the next take-off starts from.
*
* a11 belongs to shake_a11, so nothing may carry a floor across this.
*
* jsrp/retp: it sleeps.
*
soul_kin_land
	calla	ground_ochar
	tsound	soul_kin_quake_snd
	movi	0000a000fh,a11
	calla	shake_a11
	callr	soul_kin_lane1
	callr	soul_kin_frame
	sleep	soul_kin_land_t
	retp

*
* soul_kin_bail - the same take-off, harder, and he does not come back.
* He goes out the way the prop in the stands came out: straight up and off
* the top of the frame.  The object is deleted once he is clear, so the
* next match opens on the stage's own marks with him walking in as an
* ordinary opponent.
*
* jsrp/retp: it sleeps.
*
soul_kin_bail
	pushp	a10
	callr	soul_kin_lane1
	jsrp	soul_kin_part
	tsound	soul_kin_warp_snd	; he is going back where he came from
	tsound	soul_kin_launch_snd
	movi	soul_kin_bail_up,a0
	move	a0,*a8(oyvel),l		; NOT the jump's -0a0000h, and no
					; gravity: this one has to clear the
					; frame rather than come back down in it
	callr	soul_kin_pounce
	callr	soul_kin_frame		; TIGERJUMP5, extended, on his way up
	move	@worldtly+16,a11,w
	subi	soul_kin_top,a11	; a11 = clear of the top of the frame
	movi	soul_kin_bail_t,a10
skb1	sleep	1
	move	*a8(oypos),a0,w
	cmp	a11,a0
	jrlt	skb9
	dsj	a10,skb1
skb9	move	a8,a0
	calla	delobj
	clr	a0
	move	a0,@soul_kintaro,l
	pullp	a10
	retp

**************************************************************************
*											     *
*  soul_shang_parts - a8 = the body.  The third stomp does not make him    *
*  disappear; it takes him apart.					     *
*											     *
*  Three of his OWN gore records, no new art: STDECAPLEG7A and	     *
*  STDECAPTORSO7 are NJDECAP7, the last frame of his decapitation fall -    *
*  already a body lying flat on the floor, already cut at the waist - and   *
*  STHEAD1 is the head off a_head.  Put down a little apart, they read as   *
*  head, torso and legs where the body was.				     *
*											     *
*  gso_dmawnz, not a multipart build: each of these is ONE image record,    *
*  so there is no piece list and no shape RAM to find for it.		     *
*											     *
*  z is front_z.  The burst over them is front_z+1 and Kintaro is	     *
*  front_z-1, so the pieces lie on the floor in front of him and UNDER the  *
*  explosion, which is what was asked for.				     *
*											     *
**************************************************************************
soul_shang_parts
	mmtm	sp,a0,a1,a2,a3,a5,a10
	calla	mpart_bounds		; a0 top a1 bottom a2 left a3 right
	move	a1,@soul_part_y,w	; the floor he is lying on
	move	a2,@soul_part_x,w	; ...and where he starts along it
	movi	STHEAD1,a5
	movi	soul_part_head,a10
	callr	soul_part
	movi	STDECAPTORSO7,a5
	movi	soul_part_torso,a10
	callr	soul_part
	movi	STDECAPLEG7A,a5
	movi	soul_part_legs,a10
	callr	soul_part
	move	a8,a0
	calla	set_inviso		; the body itself is those three now
	mmfm	sp,a0,a1,a2,a3,a5,a10
	rets

*
* soul_part - a5 = an image record, a8 = the body, a10 = px along the floor
* from soul_part_x.  Returns with a8 still the body.
*
* PLACED OUTRIGHT, not lined up on the body.  mpart_bounds reports in oxpos
* space and a single-part object's oxpos/oypos ARE its top-left corner (see
* its own single-part branch), so the two measured numbers put each piece on
* the floor exactly, whichever way he fell and wherever the camera is.
* lineup_1pwm + multi_adjust_xy - decapped_head's contract - was tried first
* and is the wrong tool here: it works off the STANDING anipoint of a body
* that is lying down, and left the head hanging in mid air.
*
* The offsets are read back out of .bss rather than carried in a register
* because gso_dmawnz and change_to_bloody_pal are both calla's.
*
* change_to_bloody_pal reads *a8(ochar), so the ochar is set first and the
* pieces come out in Shang's gore colours.
*
soul_part
	mmtm	sp,a0,a1,a2,a3,a4,a6,a7,a9
	move	a8,a7			; a7 = the body
	move	a10,@soul_part_dx,w
	calla	gso_dmawnz		; a8 = the piece
	move	a8,a8
	jreq	spt9			; object pool empty - one less piece
	movi	ft_st,a0
	move	a0,*a8(ochar),w
	calla	change_to_bloody_pal
	movi	oid_soul,a0
	move	a0,*a8(oid),w		; not oid_fx - bonus_count sweeps that
	move	@soul_part_x,a0,w
	move	@soul_part_dx,a1,w
	add	a1,a0
	sll	16,a0
	move	a0,*a8(oxval),l		; oxval is the master; oxpos is its
					;   top half and the display rederives
					;   it every pass
	move	@soul_part_y,a0,w
	subi	soul_part_lift,a0
	move	*a8(osizey),a1,w
	sub	a1,a0			; rest its bottom edge on his floor
	sll	16,a0
	move	a0,*a8(oyval),l
	movi	front_z,a0
	move	a0,*a8(ozval),l		; the burst is front_z+1 and Kintaro
					;   front_z-1: the pieces lie in front
					;   of him and UNDER the explosion
	calla	insobja8
spt9	move	a7,a8			; a8 = the body again, for the caller
	mmfm	sp,a0,a1,a2,a3,a4,a6,a7,a9
	rets

*
* soul_kintaro_knock - 400 pounds of Kintaro just hit the floor.  r_quake is
* the game's own answer to a shockwave through it, and r_quake is exactly
* what do_quake (MOVES.ASM) hands the man on the receiving end of Jax's
* ground pound - so the winner takes the pound's own reaction and comes out
* of his victory pose for it.
*
* NO RANGE TEST.  It had one, and at the distance the two of them actually
* finish the souls apart - 120-odd px - it never fired.  do_quake has none
* either: the pound is a shockwave through the whole floor, not a hit box.
*
* It is raised as a FLAG rather than a takeover: the winner is parked in
* soul_escape_status's idle loop in his OWN process, which is exactly where
* a reaction wants to be entered from.
*
soul_kintaro_knock
	mmtm	sp,a0
	callr	soul_winner_obj
	move	a0,a0
	jreq	skk9			; nobody left standing
	movk	1,a0
	move	a0,@f_soul_knock,w
skk9	mmfm	sp,a0
	rets

*
* a0 = the winner's object (the one whose bar is not empty), 0 if neither
*
soul_winner_obj
	move	@p1_bar,a0,w
	jreq	swo_p2
	move	@p1_obj,a0,l
	rets
swo_p2	move	@p2_bar,a0,w
	jreq	swo_none
	move	@p2_obj,a0,l
	rets
swo_none
	clr	a0
	rets

*
* The shake: his whole stumble (TSUNG6.IMG STSTUMBLE1-6), over and over -
* thrown back, arms up, back to his guard, and thrown back again as the
* next soul tears out.  MK1's shake is three reeling poses in a four-step
* cycle; the four ticks a frame and the +/-7 px nudge on every step are
* MK1's (FFDD30B0 / FFDD3030), the frames are MK2's full reaction.
*

;>>>WAX BEGIN
* GENERATED from data/TSHANGEND.WAX by tools/shang_end_wax_import.py.
* Edit the project, not this block.  Shang's own MK2 frames, out of
* TSUNG6.IMG; the three the project calls STHITLO<n> are the composite
* names for the strips the ROM carries as STLOHIT<n>.
*
soul_shake_rate	.set	4		; ticks a frame (every frame_delay in the project)

a_soul_shake
	.long	STSTUMBLE6
	.long	STSTUMBLE2
	.long	STSTUMBLE1
	.long	STLOHIT1		; STHITLO1
	.long	STLOHIT2		; STHITLO2
	.long	STLOHIT3		; STHITLO3
	.long	STSTUMBLE5
	.long	ani_jump,a_soul_shake
;<<<WAX END

**************************************************************************
*											     *
*  soul_pool_init - build the soul and flame objects, once.		     *
*											     *
*  Sixteen souls and sixteen flames are too many to create and delete one  *
*  at a time: hand-deleting gmo objects is the thing that wedged Kahn's	     *
*  glow (safe_delobj, MKUTIL), and the safe unlink leaks a palette ref	     *
*  each time.  So four of each are made here, kept on objlst invisible,	     *
*  and recycled round-robin - a soul lives ~95 ticks and they come every   *
*  27, so no more than four are ever up.  swpal on them is a clean swap,   *
*  so their palettes never pile up.  Round teardown owns them.		     *
*											     *
*  Each is built from Shang's stance so the first getfpal is a real	     *
*  palette; its looks are set when it is used.  Souls sit one z behind	     *
*  him, flames in front of everybody.					     *
*											     *
*  a8 = Shang's object on entry and on exit.				     *
*											     *
**************************************************************************
soul_pool_init
	mmtm	sp,a9,a10,a11
	clr	a0			; no stale pointers from an earlier match
	movk	soul_pool_n,a2
	movi	soul_pool,a1
	movi	soul_fire,a3
spi0	move	a0,*a1+,l
	move	a0,*a3+,l
	dsj	a2,spi0
	clr	a10
spi1	callr	spi_make		; a8 = new object, 0 if the pool ran dry
	jreq	spi9			; (the spawner skips an empty slot)
	move	@soul_shang,a0,l
	move	*a0(ozval),a0,l
	dec	a0
	move	a0,*a8(ozval),l		; just behind Shang
	calla	insobja8
	move	a8,a0
	calla	set_inviso
	move	a10,a1
	sll	5,a1
	addi	soul_pool,a1
	move	a8,*a1,l

	callr	spi_make
	jreq	spi9
	movi	front_z+1,a0
	move	a0,*a8(ozval),l		; over everybody
	calla	insobja8
	move	a8,a0
	calla	set_inviso
	move	a10,a1
	sll	5,a1
	addi	soul_fire,a1
	move	a8,*a1,l

	inc	a10
	cmpi	soul_pool_n,a10
	jrlo	spi1
spi9	move	@soul_shang,a8,l
	mmfm	sp,a9,a10,a11
	rets

spi_make
	move	@soul_shang,a8,l
	clr	a9
	calla	get_char_ani		; Shang's stance lane (his ochar)
	calla	gmo_proc		; a8 = the new multipart object
	move	a8,a8
	jreq	spim9			; out of processes or objects
	movi	ft_st,a0
	move	a0,*a8(ochar),w
	move	a8,a8			; z clear = made one
spim9	rets

soul_pool_hide
	mmtm	sp,a1,a2
	movi	soul_pool,a1
	callr	sph0
	movi	soul_fire,a1
	callr	sph0
	mmfm	sp,a1,a2
	rets

sph0	movk	soul_pool_n,a2
sph1	move	*a1+,a0,l
	jreq	sph2
	calla	set_inviso
sph2	dsj	a2,sph1
	rets

**************************************************************************
*											     *
*  soul_spawner - one soul every soul_cadence ticks down the roster,	     *
*  alternating sides, then waits out the last one and says so.	     *
*											     *
**************************************************************************
soul_spawner
	clr	a10			; roster index
sps1	move	a10,a0
	sll	4,a0
	addi	soul_roster,a0
	move	*a0,a9,w		; the fighter this one becomes
	move	a10,a1
	andi	soul_pool_n-1,a1
	sll	5,a1
	move	a1,a2
	addi	soul_pool,a1
	move	*a1,a8,l		; a8 = its object
	addi	soul_fire,a2
	move	*a2,a11,l		; a11 = its flame
	move	a8,a8
	jreq	sps2			; pool never built - skip it
	incm	@soul_alive,w
	create	pid_soul,soul_proc	; a8-a11 go with it
sps2	sleep	soul_cadence
	inc	a10
	cmpi	soul_roster_n,a10
	jrlo	sps1

*
* Wait for the LAST SOUL TO BE ASH, not for a fixed tail.  soul_tail was an
* estimate of how long the last one needs, and Shang shakes until this flag
* goes up - so whenever the estimate ran long he kept flapping at an empty
* screen.  Each soul counts itself out as it dies; the tail is only the
* ceiling now, in case one is never created and never dies.
*
	movi	soul_tail,a10
sps3	sleep	1
	move	@soul_alive,a0,w
	jreq	sps4
	dsj	a10,sps3
sps4	movk	1,a0
	move	a0,@soul_done,w
	die

*
* The twelve main fighters in select-grid order, less Shang himself - he is
* the one losing them.  The secrets (Smoke, Noob, Jade, Ermac, Khameleon)
* are deliberately out: they are hidden encounters, not souls of the
* tournament.  Their blend palettes stay built (SOULPAL.ASM) so putting one
* back is a line in this table.
*
soul_roster
	.word	ft_kang,ft_hathead,ft_cage,ft_reptile
	.word	ft_subzero,ft_fn1,ft_jax,ft_fn2
	.word	ft_sa,ft_scorpion,ft_raiden
soul_roster_n	.set	11

**************************************************************************
*											     *
*  soul_proc - one soul, beginning to end.				     *
*											     *
*  a8 = its object, a9 = the fighter it becomes, a10 = roster index (bit 0  *
*  picks the side), a11 = its flame object.				     *
*											     *
*  p_store1 = the fighter	p_store2 = the flame				     *
*  p_store3 = x step, 16.16	p_store4 = the soul object		     *
*  p_store5 = where the flame's lane is up to				     *
*											     *
**************************************************************************
soul_proc
	move	a9,*a13(p_store1),l
	move	a11,*a13(p_store2),l
	move	a8,*a13(p_store4),l
	movi	soul_speed_rng,a0
	calla	randu
	addi	soul_speed_min,a0
	btst	0,a10
	jreq	sp_side
	neg	a0
sp_side	move	a0,*a13(p_store3),l
*
* A copy of Shang, where he stands, in his own colours.
*
	move	a8,a0
	move	@soul_shang,a8,l
	calla	match_ani_points	; onto his anchor, his facing
	move	*a13(p_store4),a8,l
	movi	ft_st,a0
	move	a0,*a8(ochar),w
*
* His colours, off the man himself.  character_palettes_1[ft_st] is NOT what
* he is wearing - a fighter's live palette depends on side and on what
* player_normpal picked - and a copy in the wrong one comes out as a pale
* blue ninja with pink legs.  Read the id back out of the colour map his
* object actually holds, so the copy is him whatever he is wearing.
*
	move	@soul_shang,a0,l
	callr	soul_live_pal
	jrne	sp_pal
	movi	character_palettes_1+(ft_st*32),a0	; only if he has no map
	move	*a0,a0,l
sp_pal	calla	swpal
	clr	a9
	calla	get_char_ani
	calla	do_next_a9_frame	; STSTANCE1
	callr	soul_face
	move	a8,a0
	calla	clear_inviso
	calla	clear_shadow_bit	; souls cast no shadow blob
*
* Its scream - the fighter it is about to become (MK1: FFDB8190[char]).
*
	move	*a13(p_store1),a0,l
	move	a0,*a8(ochar),w
	calla	disturbing_scream
	movi	ft_st,a0
	move	a0,*a8(ochar),w

	movk	soul_hold,a10
sp1	callr	soul_drift
	sleep	1
	dsj	a10,sp1
*
* Shang's morph into it: the three blend frames, still drifting.
*
	move	*a13(p_store1),a0,l
	callr	soul_blend_lane		; a9 = blend frame 1, a0 = their palette
	calla	swpal
sp2	calla	do_next_a9_frame
	movk	soul_morph_t,a10
sp3	callr	soul_drift
	sleep	1
	dsj	a10,sp3
	move	*a9,a0,l		; the blend frames end where the lane's
	cmpi	ani_nosleep,a0		; ani_nosleep does: three of them, but
	jrne	sp2			; Baraka's has two (STUGLY2-3)
*
* It IS that fighter now: his colours, his stance height, and it reels
* back from Shang - stumble, then knocked flat.
*
	move	*a13(p_store1),a0,l
	move	a0,*a8(ochar),w
	callr	soul_fighter_pal
	calla	swpal
	calla	ground_ochar
	callr	soul_face
	movi	023h,a9
	calla	get_char_ani		; a_*stumble
	movi	soul_stumble,a0
	jsrp	animate_a0_frames
	movk	00fh,a9
	calla	get_char_ani		; a_*kdown
	movk	soul_fall_t,a0
	jsrp	mframew			; part 1 - knocked down
	move	a9,*a13(p_store5),l	; part 2 is next
*
* The MK1 flame takes it: onto its anchor, on the floor, over everybody.
*
	move	*a13(p_store2),a0,l
	calla	match_ani_points	; a8 = the soul, a0 = the flame
	move	*a13(p_store2),a8,l
	.if	soul_fire_dx
	move	*a8(oflags),a1,w
	movi	soul_fire_dx*010000h,a0
	btst	b_fliph,a1
	jreq	sp_fdx
	neg	a0
sp_fdx	move	*a8(oxval),a1,l
	sub	a0,a1			; toward his feet: away from his facing
	move	a1,*a8(oxval),l
	.endif
	movi	MK1FIRE_P,a0
	calla	swpal			; MK1FIRE is built POF>
	movi	a_mk1fire,a9
	calla	do_next_a9_frame	; MK1FIRE1
	calla	ground_multi		; all six share one floor anchor
	move	a8,a0
	calla	clear_inviso
	calla	clear_shadow_bit
	tsound	093h			; burning
	move	a9,a11			; a11 = the flame's lane
*
* ...while the soul lands on its back under the burst.
*
	move	*a13(p_store4),a8,l
	move	*a13(p_store5),a9,l
	movk	soul_fall_t,a0
	jsrp	mframew			; part 2 - landing
*
* The burst covers it and it is gone; the column burns down.
*
	move	*a13(p_store2),a8,l
	move	a11,a9
	calla	do_next_a9_frame	; MK1FIRE2
	sleep	soul_fire_t
	move	*a13(p_store4),a0,l
	calla	set_inviso		; the soul is ash
	movi	(soul_fire_t*010000h)+4,a0
	jsrp	animate_a0_frames	; MK1FIRE3-6
	move	a8,a0
	calla	set_inviso
	decm	@soul_alive,w		; the spawner waits on the last of us
	die

*
* a0 = object in, the palette id its colour map was allocated from out
* (0, z set, if it has none).  palram is the allocator's table: one
* palrsiz entry per map, the id first.
*
soul_live_pal
	move	*a0(opal),a1,w
	sll	24,a1
	srl	24,a1			; colour map number
	sll	6,a1			; * palrsiz (040h)
	addi	palram,a1
	move	*a1,a0,l
	rets

*
* x step, while it drifts clear of him
*
soul_drift
	move	*a13(p_store3),a1,l
	move	*a8(oxval),a0,l
	add	a1,a0
	move	a0,*a8(oxval),l
	rets

*
* Face back toward Shang - away from the way it is drifting - so its
* stumble and fall carry it on out.  Unflipped art faces right.
*
soul_face
	move	*a8(oflags),a0,w
	andi	m_fliph,a0
	movi	m_fliph,a1		; drifting right: face left
	move	*a13(p_store3),a2,l
	jrnn	sf3
	clr	a1			; drifting left: face right
sf3	cmp	a0,a1
	jreq	sf9
	calla	flip_multi
sf9	rets

*
* a0 = the palette for the fighter in *a8(ochar): his normal one, or his
* mirror-match one if he is the winner's own fighter.
*
soul_fighter_pal
	move	*a8(ochar),a1,w
	movi	character_palettes_1,a0
	move	@soul_winchar,a2,w
	cmp	a1,a2
	jrne	sfp3
	movi	character_palettes_2,a0
sfp3	sll	5,a1
	add	a1,a0
	move	*a0,a0,l
	rets

**************************************************************************
*											     *
*  soul_blend_lane - a0 = the fighter.  Returns a9 -> the first of Shang's *
*  three blend frames into him, a0 = the palette they are drawn in.	     *
*											     *
*  The frames are his morph lane's (st_anitab2): STSTANCE1, ani_calla	     *
*  morph_swpal, then the three - so they start three longs in, and their   *
*  palette is the first piece's icmap, which is exactly what morph_swpal   *
*  takes.  The five fighters Shang never could morph into borrow the	     *
*  frames of the fighter their art is drawn from, in a palette of their    *
*  own (SOULPAL.ASM, tools/make_soul_blend_pals.py).			     *
*											     *
**************************************************************************
soul_blend_lane
	move	a0,a1
	sll	6,a1
	addi	soul_blend_tab,a1
	move	*a1+,a2,l		; whose blend frames
	move	*a1,a0,l		; palette override, 0 = the frames' own
	sll	5,a2
	addi	st_anitab2,a2
	move	*a2,a9,l
	addi	3*32,a9
	move	a0,a0
	jrne	sbl9
	move	*a9,a0,l		; blend frame 1
	move	*a0,a0,l		; its first piece
	move	*a0(icmap),a0,l
sbl9	rets

*
* One row per fighter (the char-table audit wants all twenty).
*
soul_blend_tab
	.long	ft_hathead,0		;  0 - kung lao
	.long	ft_kang,0		;  1 - liu kang
	.long	ft_cage,0		;  2 - johnny cage
	.long	ft_sa,0			;  3 - baraka
	.long	ft_fn1,0		;  4 - kitana
	.long	ft_fn2,0		;  5 - mileena
	.long	ft_kang,0		;  6 - shang: never a soul
	.long	ft_raiden,0		;  7 - raiden
	.long	ft_subzero,0		;  8 - sub-zero
	.long	ft_reptile,0		;  9 - reptile
	.long	ft_scorpion,0		; 10 - scorpion
	.long	ft_jax,0		; 11 - jax
	.long	ft_kang,0		; 12 - kintaro: never a soul
	.long	ft_kang,0		; 13 - shao kahn: never a soul
	.long	ft_subzero,SOULSMK_P	; 14 - smoke - ninja art
	.long	ft_subzero,SOULNOB_P	; 15 - noob saibot - ninja art
	.long	ft_fn1,SOULJAD_P	; 16 - jade - Kitana's art
	.long	ft_reptile,SOULERM_P	; 17 - ermac - Reptile's art
	.long	ft_fn1,SOULKHM_P	; 18 - khameleon - Kitana's art
	.long	ft_scorpion,0		; 19 - rain: never a soul (not one of the eleven)
	.if	wunit	; WOLF FIGHTERS
	.long	ft_fn1,0,ft_fn1,0,ft_kang,0,ft_kang,0,ft_subzero,SOULSMK_P	; 20 sonya=4, 21 sindel=4, 22 kano=1, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS

**************************************************************************
*											     *
*  soul_bg_flash - MK1 flashed the doorway behind Shang's throne white     *
*  every four ticks for the whole time (FFDD3C80).  Here the PURPLE BACK   *
*  WALL blinks - baklst6, arena5BMOD, the flat wall the crowd stands	     *
*  against - and nothing else.						     *
*											     *
*  It is only that one plane on purpose.  baklst2-4 (the parapet and the   *
*  two distant floors) read as FOREGROUND from the fighters' row down, so  *
*  blinking them looks like the floor is broken rather than like the	     *
*  arena reacting; baklst5 is the crowd, in front of the wall; baklst7 is  *
*  the cloud plane, which was the first cut of this.  baklst1 and baklst8  *
*  are the live actors (Kahn's chair, Kano, Sonya, and the Kintaro prop    *
*  that is about to leap), and whiting THEM out reads as a bug.  A raster  *
*  band cannot do this at all - a display register moves every plane on    *
*  its rows, foreground included (project_kahn_sky_shimmer).		     *
*											     *
*  p_store1-8 = the distinct colour maps found (up to eight)		     *
*											     *
**************************************************************************
soul_bg_flash
	callr	soul_bg_maps		; a10 = how many
ssk_on	movi	soul_white,a11
	callr	soul_sky_set		; white
	sleep	4
	clr	a11
	callr	soul_sky_set		; the arena's own colours
	sleep	4
	move	@soul_bg_stop,a0,w
	jreq	ssk_on
	die

*
* p_store1.. = the distinct colour maps of everything on baklst2-6
*
soul_bg_maps
	mmtm	sp,a6,a7
	move	a13,a5
	addi	p_store1,a5
	clr	a10
	movi	soul_bg_lists,a7
ssm_list
	move	*a7+,a6,l		; next plane's list head
	jreq	ssm9
ssm1	move	*a6,a6,l		; next object on it (onext is cell 0)
	jreq	ssm_list
	move	*a6(opal),a1,w
	sll	24,a1
	srl	24,a1			; colour map number
	move	a5,a3
	move	a10,a4
	jreq	ssm4
ssm2	move	*a3+,a2,l
	cmp	a1,a2
	jreq	ssm1			; have it
	dsj	a4,ssm2
ssm4	move	a1,*a3,l		; new one
	inc	a10
	cmpi	8,a10
	jrlo	ssm1
ssm9	mmfm	sp,a6,a7
	rets

soul_bg_lists
	.long	baklst6			; the purple back wall (arena5BMOD), alone
	.long	0

*
* a11 = source colours (0 = each map's own), a10 = map count
*
soul_sky_set
	move	a10,a4
	jreq	sss9
	move	a13,a5
	addi	p_store1,a5
sss1	move	*a5+,a3,l		; colour map
	move	a3,a1
	sll	6,a1			; * palrsiz (040h)
	addi	palram,a1
	move	*a1,a1,l		; palette id = its data: .word n, colours
	jreq	sss8
	move	*a1,a2,w		; n
	subk	1,a2			; colour 0 stays transparent
	jrle	sss8
	move	a11,a0
	jrne	sss3
	move	a1,a0
	addi	32,a0			; its own colour 1 onward
sss3	move	a3,a1
	sll	8,a1
	inc	a1			; [map : colour 1]
	calla	palset
sss8	dsj	a4,sss1
sss9	rets

soul_white
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh
	.word	07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh,07fffh

	.end
