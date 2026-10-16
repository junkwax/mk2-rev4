**************************************************************************
*											     *
*  module: mkdrnew.asm --- the CPU's use of the NEW player specials	     *
*											     *
*  Moves a player's fighter has that the CPU never threw, each given to the *
*  drone with the player handler's own limits.  The drone tables that name  *
*  them (ochar_punish, ochar_propells) stay in MKDRONE.ASM.		     *
*											     *
*  ITS OWN OBJECT because MKDRONE.ASM is at GSPA's ceiling: adding the Kung *
*  Lao spin to it aborted the assembler with "Out of memory" (see		     *
*  reference_gspa_out_of_memory - it tracks symbols and content, not lines). *
*  So nothing here may callr/jrXX into MKDRONE: exits are jauc reaction_exit *
*  and every helper is a global calla.					     *
*											     *
**************************************************************************
	.file	"mkdrnew.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.globl	drone_sc_fwdtele,drone_cage_punish,drone_kl_spin,drone_kl_spin_now
	.globl	drone_fn2_mix,boss_react,drone_fp_try,drone_kl_pdive
	.globl	drone_hidden_finish,drone_er_decoy,drone_dives
	.globl	drone_hk_guard
	.global	does_stk_reach		; MKDRONE.ASM - the real strike box
	.global	drone_kano_jump		; MKDRONE.ASM - her roll combo
	.global	do_hh_spin		; MOVES.ASM

kspin_taps	.set	010h	; LK taps the CPU keeps up, one every 4 ticks (~1.2s)
kspin_reach	.set	050h	; the spin does not travel: stk_hhspin connects to ~77-82

	.text

*
* drone_cage_punish - Cage's long-range punish (ochar_punish row 2).  It was the
* shadow kick alone; his CEILING UPPERCUT (F,F,B+HP, do_jc_ceiling, propell 0fh)
* is a player move the CPU never threw, and it answers the same question - he
* leaves the screen and comes down next to the man, so the distance is no object.
* The player handler has no limit on it (jchip3: combo, then restricted_xfer),
* so neither does this.  50% ceiling (35% measured 2 of 18), otherwise the kick as before.  Also his
* far-range special (ochar_propells row 2), where it is how he comes in.
*
drone_cage_punish
	movi	500,a0
	calla	randper
	jrnc	dcpn_kick		; the kick, exactly as before
	movi	00fh,a0			; propell 0fh = do_jc_ceiling
	jsrp	do_body_propell		; jsrp + exit, drone_shadow's shape: it is
	jauc	reaction_exit		; also reached from ochar_propells, which
					; pushes no return frame
dcpn_kick
	movk	8,a0			; propell 8 = the shadow kick, as drone_shadow
	jsrp	do_body_propell
	jauc	reaction_exit

*
* drone_sc_fwdtele - Scorpion's FORWARD teleport punch (D,F+LP, sc_lp_fwdtele) as his
* long-range punish (ochar_punish row 10): it flies TOWARDS the man and its strike box
* is live from the first tick, so a man recovering in front of him is punched on the
* way past - exactly the "crosses distance fast" move that table wants, and the slot
* was empty. Refused, as the handler refuses it, inside the l_decoy cooldown it shares
* with the backward teleport (060h); dec_takeoff stamps l_decoy itself. punish_from_
* range has already pushed reaction_exit, so a refusal is just a retp.
*
drone_sc_fwdtele
	movi	l_decoy,a0
	calla	get_tsl			; a1 = ticks since either teleport
	cmpi	060h,a1
	jrlo	dsft_no			; too soon - sc_lp_fwdtele's own number
	movi	016h,a0			; propell 16h = do_fwd_decoy
	jauc	do_body_propell
dsft_no
	retp

*
* drone_kl_spin - Kung Lao's SPIN (Forward,Forward + LK, do_hh_spin) as his
* long-range punish (ochar_punish row 0).  The spin's box only goes live while
* LK keeps being TAPPED - hhspin4 asks get_tsl l_lk for a press inside 00eh
* ticks - and a drone presses nothing, so a CPU spin could never hit
* (reference_drone_tap_gated_moves: the gotcha grab and the throw slam had the
* same hole).  So it taps: kl_spin_tapper stamps this player's l_lk every 4
* ticks for kspin_taps taps, which is a player mashing LK through the spin -
* no faster, and no longer than a hand keeps it up.  The tapper is its own
* process (pid_fx, swept with the round) because do_hh_spin owns this one.
* The player's handler (hhlk_spin) has no limit beyond the input.
*
* THE SPIN DOES NOT TRAVEL - neither here nor in retail (do_hh_spin sets no
* velocity) - so it only hits a man inside stk_hhspin's 77-82 px.  The first
* cut used it as the long-range punish and measured 5 spins, 0 landed, begun
* 114-202 px out.  So the punish entry (drone_kl_spin, reaction_exit frame
* already pushed - a refusal is a retp) spins only inside kspin_reach, and the
* close-range pick (close_hhbackfist) takes drone_kl_spin_now outright.
*
drone_kl_spin
	calla	get_x_dist		; a3 = how far
	cmpi	kspin_reach,a3
	jrhi	dkls_no			; out of the box's reach - not this
drone_kl_spin_now
	movi	kspin_taps,a10		; a8 = my object rides into the tapper
	create	pid_fx,kl_spin_tapper
	jauc	do_hh_spin		; ends in reaction_exit
kl_spin_tapper
	movi	l_lk,a0
	calla	update_tsl		; "pressed LK now", for the man in a8
	sleep	4
	dsj	a10,kl_spin_tapper
	jauc	sucide
dkls_no	retp

*
* drone_fn2_mix - Mileena's TELEPORT KICK (Forward,Forward + LK, fn2_lo_kick ->
* do_fn2_teleport, propell 1) beside her roll, in her far-range special
* (ochar_propells row 5) and her long-range punish (ochar_punish row 5).  The
* also as her answer to a projectile from range (ochar_avoid_pro row 5 - she
* sinks under it, as Kung Lao teleports through one).  The
* CPU had it only as an anti-air answer (close_out_of_air) and a round opener,
* and threw it ZERO times in 164k fighting frames.  The handler has no limit
* beyond the input, so neither does this; 75% teleport, else the roll combo as
* before (40% measured 1 teleport to 33 rolls: the roll also comes from the
* crouch answer and the juggle, so these two slots are its minority).  Safe from both tables: jsrp + jauc reaction_exit needs no frame,
* and drone_kano_jump was already in both rows.
*
drone_fn2_mix
	movi	750,a0
	calla	randper
	jrnc	dfm_roll
	movk	1,a0			; propell 1 = do_fn2_teleport
	jsrp	do_body_propell
	jauc	reaction_exit
dfm_roll
	jauc	drone_kano_jump

*
* boss_react - THE BOSSES KEEP THE STOCK REACTION SPEED.  drone_beware calls this
* with a0 = @diff*16; for Kintaro and Shao Kahn it answers carry set and a0 = the
* retail delay (6..3 ticks), and the caller arms it with no prediction step - the
* human-speed floor would only slow them.  Everyone else: carry clear, a0 as given.
* Why: drnhuman (8..14 ticks) reaches the bosses through the same drone_beware,
* and it took Shao Kahn from 0 to 40% against the same frozen fly - rom35 0/86,
* rom37 30/74, rom37 with drnhuman=0 0/83.  The bosses are meant to be unfair;
* the twelve fighters stay human-speed.  Here, not in MKDRONE, because MKDRONE
* is at GSPA's ceiling (two labels there aborted the assembly).
*
boss_react
	move	*a8(ochar),a2,w
	cmpi	ft_goro,a2
	jreq	br_boss
	cmpi	ft_final_boss,a2
	jreq	br_boss
	clrc
	rets
br_boss
	addi	boss_react_ticks,a0
	move	*a0,a0,w
	setc
	rets
boss_react_ticks
	.word	6,6,5,5,4,4,4,3,3,3	; retail's drone_react_delay, diff 0-9

*
* drone_fp_try / drone_flip_punch - THE JUMP-IN PUNCH MIDWAY WROTE AND SHELVED
* (drnflipp, MAINEQU.ASM).
*
* The leak carries a `drone_flip_punch` in MKDRONE.ASM, commented out and
* called by nothing - not even a commented table row.  It is a line-for-line
* twin of drone_flip_kick: the same forward flip, with do_flip_punch at the
* end instead of do_flip_kick.  So retail's CPU only ever jumps in with a kick.
*
* Why it was shelved is readable off the numbers.  A flip punch is 16 where
* the kick is 26, and a jump punch is only worth throwing for what comes
* AFTER it - it does not knock him down, so the man who landed it is standing
* next to somebody in hit-stun.  Retail's drone had no way to act on that: an
* air move ends in do_land_animation and never returns to its caller.  This
* build does (drone_land_next), so the punch arms dln_press - land, and if it
* connected take the sweep "every player takes there" (dlf_press).
*
* Two things are NOT Midway's, both this tree's own fixes to the kick:
*   - never swing while rising, unless about to land (their scan fired on the
*     way up, foot above his head);
*   - ask the real strike box (does_stk_reach, stk #0ch) instead of their
*     080h = 128px, where the punch reaches ~80: with that constant the kick
*     landed 0 of 7 here and the punch would have whiffed the same way.
*
* drone_fp_try is called from drone_flip_kick after its own gates (he is not
* airborne, the air-projectile roll passed, the jump-in pacing timer is spent)
* and before the takeoff.  It RETURNS for a kick and never returns for a punch.
* NOT reached by the juggle entries (drone_flip_kick_now), which are scripted
* around a kick.
*
klpdive		.set	1	; Kung Lao: air punch -> dive kick (drone_kl_pdive)
fp_floor	.set	028h	; = flipk_floor (MKDRONE.ASM) - a .set does not cross objects
fp_press	.set	011h	; = dln_press   (MKDRONE.ASM) - same reason

drone_fp_try
	.if	drnflipp
	move	*a8(ochar),a0,w
	cmpi	ft_goro,a0
	jreq	dfpt_no			; 9-row strike table: there is no 0ch
	cmpi	ft_final_boss,a0
	jreq	dfpt_no			; his 0ch is the hammer
	movi	rpt_flip_punch,a0
	calla	ask_mr_diff
	jrnc	dfpt_no
	pull	a0			; drop our return - prcdsp never reloads sp
	jruc	drone_flip_punch
	.endif
dfpt_no	rets

drone_flip_punch
	calla	stop_me			; (= drone_stop_me)
	calla	face_opponent
	movk	7,a9			; ani = forward flip
	movi	-040000h,a0
	movi	drone_fp_call,a6
	movi	-0a0000h,a1		; initial y vel (upwards)
	movi	angle_grav,a2
	movk	3,a3			; animation speed
	jsrp	flight_call		; the same jump drone_flip_kick makes
	jauc	drone_land

drone_fp_call
	calla	next_flip_whoosh
	calla	distance_off_ground	; a0 = height off the floor
	cmpi	fp_floor,a0
	jrls	dfpc_range		; about to land: now or never
	move	*a8(oyvel),a0,l
	jrn	dfpc_no			; still rising - never swing on the way up
dfpc_range
	movk	0ch,a0			; stk #0ch = the flip punch, every fighter
	calla	does_stk_reach
	jrnc	dfpc_no			; not there yet - stay in the arc
	pull	a0			; leave the flight exactly as dajc_kick does
	pull	a0
	calla	reset_proc_stack
	move	@diff,a0,w		; easy AI takes the one poke and leaves,
	cmpi	4,a0			; as it does with the kick
	jrlo	dfpc_go
	movi	fp_press,a0		; ARMED HERE, immediately before the move
	move	a0,*a13(p_juggle_step),w	; that carries it (drone_arm_land)
dfpc_go	jsrp	do_flip_punch
	jauc	reaction_exit		; drone-unreachable: do_flip_punch ends in
					; do_land_animation -> drone_land
dfpc_no	rets

**************************************************************************
*											     *
*  drone_hidden_finish - A CPU JADE, ERMAC OR RAIN FINISHES WITH THEIR OWN   *
*  FATALITY.  drone_finish_him (MKDRONE) sent every ochar from 12 up to the  *
*  uppercut, because db1_table / db2_table are twelve rows; these three	     *
*  fatalities are not reached through those tables at all, so it jsrp's     *
*  here first (a0 = ochar, after the same 1-in-10 audit the stock twelve    *
*  pass).  Each is the human's own fatality routine with the human's own    *
*  range: Jade's impale inside jdi_maxdist, Ermac's slam inside UMK3's	     *
*  q_fatal_dist BAND (not point blank), Rain's bolts inside rnf_maxdist.    *
*  The walk and the dizzy wait are drone_finish_him's (fatality_align,	     *
*  wait_for_dizzy), copied because MKDRONE is at GSPA's ceiling.	     *
*  Returns (retp) when there is nothing to do - the uppercut follows; never  *
*  returns when it finishes.						     *
*											     *
**************************************************************************
drone_hidden_finish
	callr	dhf_entry		; a1 -> my row
	jreq	dhf_no			; none: the uppercut
	move	@f_no_blood,a0,w
	jrne	dhf_no			; fatality_xfer refuses it a player too
	calla	get_x_dist		; a3 = how far
	move	*a1(16),a11,w		; where to stand
	move	*a1(32),a0,w		; nearest the move allows
	cmp	a0,a3
	jrlo	dhf_back
	jsrp	drone_approach
	jruc	dhf_wait
dhf_back
	jsrp	drone_retreat
dhf_wait
	movi	dhf_dizzy,a11
	movi	030h,a10
	jsrp	stance_wait_yes		; wait_for_dizzy, word for word
	move	a10,a10
	jreq	dhf_no			; he came round
	callr	dhf_entry		; a1 again: the walk ate it
	calla	get_x_dist
	move	*a1(32),a0,w
	cmp	a0,a3
	jrlo	dhf_no			; fatality_xfer_close's tests, as the
	move	*a1(48),a0,w		; player's handler applies them
	cmp	a0,a3
	jrhi	dhf_no
	move	*a1(64),a0,l		; the fatality
	pullp	a1			; drone_finish_him's frame: from here the
	jump	a0			; stack is the stock jauc do_fatality_2's
dhf_no	retp

dhf_entry
	move	*a8(ochar),a0,w
	movi	dhf_table,a1
dhfe1	move	*a1,a2,w
	jrn	dhfe_none		; -1 ends the table
	cmp	a0,a2
	jreq	dhfe_yes
	addi	96,a1
	jruc	dhfe1
dhfe_none
	clr	a1			; Z = no row
	rets
dhfe_yes
	move	a1,a1			; NZ = a1 is the row
	rets

dhf_dizzy
	move	*a13(p_otherproc),a0,l
	move	*a0(pwake),a0,l
	cmpi	dizzy,a0
	jreq	dhfd_y
	clrc
	rets
dhfd_y	setc
	rets

*  ochar, stand at, nearest, farthest, fatality
dhf_table
	.if	jadeimpale
	.word	ft_jade,040h,0,jdi_maxdist
	.long	do_jade_impale
	.endif
	.if	ermac_fatal_slam_enable
	.word	ft_ermac,090h,erm_tksf_mindist,erm_tksf_maxdist
	.long	do_ermac_fatal_slam
	.endif
	.if	rainfatal
	.word	ft_rain,080h,0,rnf_maxdist
	.long	do_rain_fatal
	.endif
	.word	-1

*
* drone_er_decoy - ERMAC'S TELEPORT PUNCH (Down,Back + HP, ermac_hi_punch ->
* do_ermac_decoy, propell 11h) as his long-range punish (ochar_punish row 17,
* which was 0: the CPU Ermac only ever threw his fireball).  Refused, as the
* handler refuses it, inside the 060h l_decoy cooldown.  punish_from_range has
* pushed reaction_exit, so a refusal is a retp.  drone_sc_fwdtele's shape.
*
drone_er_decoy
	movi	l_decoy,a0
	calla	get_tsl			; a1 = ticks since his last teleport
	cmpi	060h,a1
	jrlo	dered_no		; too soon - ermac_hi_punch's own number
	movi	011h,a0			; propell 11h = do_ermac_decoy
	jauc	do_body_propell
dered_no
	retp

*
* drone_dives - carry SET for a fighter whose CPU takes the air DIVE KICK out
* of a jump-in (drone_ajump_call, MKDRONE): Reptile, and NOOB, whose dive is
* Reptile's own (noob_hi_kick, noobdive).  a0 = ochar, preserved - Kung Lao
* is still tested after this.  A calla here instead of a second cmpi/jreq in
* MKDRONE, which is at GSPA's ceiling.
*
drone_dives
	cmpi	ft_reptile,a0
	jreq	ddv_yes
	.if	noobdive
	cmpi	ft_noob,a0
	jreq	ddv_yes
	.endif
	clrc
	rets
ddv_yes	setc
	rets

**************************************************************************
*											     *
*  drone_kl_pdive - KUNG LAO: AIR PUNCH, THEN STRAIGHT INTO THE DIVE KICK  *
*											     *
*  Called from fly_punch_hit (MOVES.ASM) after the hit pause of a flip    *
*  punch that CONNECTED.  For a CPU Kung Lao on the harder levels it	     *
*  dives at once - the human's own input, Up,Down + HK (hh_hi_kick):	     *
*  the button table reaches it mid-punch and airborn_xfer only refuses a  *
*  man reacting, mid-special or a sitting duck, none of which the punch   *
*  is.  hh_hi_kick's own gate is copied: 0a0h off the floor or nothing.   *
*  Returns if it does not take it; never returns if it does.		     *
*											     *
**************************************************************************
drone_kl_pdive
	.if	klpdive
	calla	am_i_joy
	jrc	dklp_no			; a human dives himself or not at all
	move	*a8(ochar),a0,w
	cmpi	ft_hathead,a0
	jrne	dklp_no
	calla	distance_from_ground
	cmpi	0a0h,a0
	jrlo	dklp_no			; hh_hi_kick's height gate
	movi	rpt_kl_pdive,a0
	calla	ask_mr_diff
	jrnc	dklp_no
	pull	a0			; drop our return - prcdsp never reloads sp
	clr	a0
	move	a0,*a13(p_juggle_step),w	; the punch's landing follow-up is moot
	calla	reset_proc_stack
	movk	3,a0			; propell 3 = do_reptile_superk, the dive
	jsrp	do_body_propell
	jauc	reaction_exit
	.endif
dklp_no	rets

*  Odds per difficulty, per thousand, of a jump-in carrying the punch.  Under
*  the air projectile's own roll (rpt_air_zap) on purpose: the kick stays the
*  usual answer and the punch is what makes the jump a question.
rpt_flip_punch
	.word	0,0,100,150,200,250,300,350,400,450

*  Kung Lao's dive off a connected air punch (drone_kl_pdive), per thousand
*  by difficulty: "on harder difficulties" - from the middle up, near certain
*  at the top.  AFTER rpt_flip_punch: the flip rig finds that table by the
*  rets in front of it.
rpt_kl_pdive
	.word	0,0,0,0,0,400,600,800,900,1000

*
* drone_hk_guard - THE CPU CAN GUARD A STANDING HIGH KICK.  Called from
* is_he_blocking (JOY.ASM) when the CPU defender is NOT already guarding.
*
* The kick lands 6 ticks after act_hikick is stamped; the CPU notices nothing for
* 8-14 (drnhuman) and its reaction loops are not even running while it stands or
* idles, so no CPU ever blocked one (0%, measured, bosses included).  Making it
* NOTICE faster was built and measured first and changed nothing (Baraka 7/40
* clean vs 9/40, Kintaro 12/24 vs 13/24, Kahn 13/24 vs 9/24): the answer never
* comes out in time.  A person who guards this kick is not reacting either - he
* is already holding block - so it is decided HERE, at contact, by odds.
*
* Carry set = he guards it.  Only: the attacker is in act_hikick, the strike does
* not need a low guard (a5 bit 1), the defender is standing free - idle (0),
* act_stance, either walk or act_postattack, never jumping, ducking, landing or
* mid-move (a list, not "03xx": 03xx holds both jumps) - and the round is open.
* None of those is airborne, so no airborne test: am_i_airborn misfires on a
* boss stranded above p_ganiy (memory: boss airborne false positive).
* b_noblock is NOT read: on a CPU it
* is stale (moves set it, only a hit or back_to_normal clears it - measured set on
* every idle Kahn and Baraka at contact), and the CPU's own guard path above never
* reads it either.  block_shake then draws the guard itself, so he snaps into it
* and shakes like any blocked hit.
*
* in: a0 = defender proc, a13 = attacker proc, a5 = strike flags.  Keeps a0-a2.
* drnhkguard 0 zeroes the odds: retail behaviour, nothing else changes.
*
drnhkguard	.set	1
drone_hk_guard
	mmtm	sp,a0,a1,a2
	move	*a13(p_action),a1,w
	cmpi	act_hikick,a1
	jrne	dhg_no
	btst	1,a5
	jrne	dhg_no			; a low-guard strike - not this
	move	*a0(p_action),a1,w
	jreq	dhg_free		; 0 = idle (act_mframew_z clears it)
	cmpi	act_stance,a1
	jreq	dhg_free
	cmpi	act_walkf,a1
	jreq	dhg_free
	cmpi	act_walkb,a1
	jreq	dhg_free
	cmpi	act_postattack,a1
	jrne	dhg_no			; jumping, ducking, landing, getting up,
dhg_free				;   mid-move, reacting: not ready
	move	@winner_status,a1,w
	jrne	dhg_no			; round decided - FINISH HIM's dizzy man stays open
	movi	rpt_hk_guard,a0
	calla	ask_mr_diff		; carry set = he was ready for it
	mmfm	sp,a0,a1,a2		; mmfm leaves the carry alone
	rets
dhg_no
	mmfm	sp,a0,a1,a2
	clrc
	rets

rpt_hk_guard				; per mille, diff 0-9
	.word	0*drnhkguard,50*drnhkguard,100*drnhkguard,200*drnhkguard,300*drnhkguard
	.word	350*drnhkguard,400*drnhkguard,500*drnhkguard,600*drnhkguard,700*drnhkguard

	.end
