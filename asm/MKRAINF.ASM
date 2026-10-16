**************************************************************************
*											     *
*  video game project:	mortal kombat 2							*
*											     *
*  module: mkrainf.asm - RAIN'S LIGHTNING FATALITY				*
*											     *
*  Down, Down, Back, Forward + HIGH KICK in FINISH HIM (rain_hi_kick,	     *
*  MOVES.ASM) - MK Trilogy's own input for his second fatality, sm_rain_hkc *
*  -> do_fatality_2 -> rain_bolt_strikes (MKFATAL.C, N64 source).	     *
*											     *
*  TWO VERSIONS, picked by rnf_geo (MAINEQU.ASM):			     *
*    0 (DEFAULT, 2026-09-22) - Trilogy's own: its N64 SPRITE bolts, one to  *
*      strike him and 13 more ever faster (THE SPRITE BOLTS, rnf_salvo).    *
*    1 (SHELVED, compiled out) - the CPU-drawn single bolt described next.  *
*  Both keep the lit stage, the jolt and the split below.		     *
*											     *
*  The shelved version: Trilogy's shape, reduced to ONE bolt built the way a high-speed camera  *
*  sees real lightning (Saba et al. 2022, GRL, doi:10.1029/2022GL101482):  *
*  a stepped leader comes down out of the dark, branching, with a streamer  *
*  brush at every tip; upward leaders reach up off the man, off RAIN and    *
*  off the ground to meet it; only his connects, every other one aborts,   *
*  and the return stroke lights the channel and splits him.  THE BOLT, below,*
*  says how.  Every line of it is CPU-DRAWN with geo_seg, in RAINLT_P's    *
*  blues because each segment carries the bolt object's colour map.  No    *
*  painted lightning at all.						     *
*											     *
*  The rest of the picture:						     *
*    * THE STAGE LIGHTS UP.  init_death_blow's dim leaves every palette at    *
*      RNF_LT_REST; the storm takes the BACKGROUND ones on down to 1/8	     *
*      (bpalram only, bgnd_dim's walk) and the strike re-fades them with     *
*      multipliers above 128, so the scenery flares brighter than it was	     *
*      authored and sinks back into the dark - light from the bolt, not a    *
*      white sheet.  The fighters live in fpalram and stay lit.  When the    *
*      last bolt is done the stage comes back to RNF_LT_REST, so the ending  *
*      is lit like every other fatality's.				     *
*    * THE SKY BEHIND IT pulses blue-white (irqskye, white_flash's knob).    *
*    * THE STRIKE strobes the play area (flash_pass, flash_back 0) and the   *
*      ground shakes; the joined channel is drawn heavy for its afterglow.   *
*    * THE MAN JOLTS from the tick the first bolt LANDS - never before it:    *
*      shocked frames (shocker_info, the ones Raiden's fry uses), the	     *
*      electrified palette, a jitter.					     *
*											     *
*  THE SPLIT is the user's IMGTOOL project data/RAINSPLIT.WAX - legs and     *
*  torso thrown apart and landing - authored on the ninja and played on	     *
*  every victim in HIS OWN art: the generated templates below carry	     *
*  placeholders that rnf_build swaps for his frames out of rows 039h and    *
*  041h, which every fighter module has in the same shape (the importer's   *
*  --check proves it).  Rerun tools/rain_split_wax_import.py after a save.  *
*											     *
*  Processes: Rain's own is the director.  The bolt, its scorch, the	     *
*  strobe and the sky pulse are pid_rainfx processes that end themselves;   *
*  the victim *
*  is takeover_him'd into rnf_victim.  Only a8-a11 survive a sleep, and a   *
*  routine that sleeps is jsrp/retp.					     *
*											     *
**************************************************************************
	.file	"mkrainf.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	imgtbl.glo
	.text

	.ref	RAINLT_P			; IMGPAL6.ASM - the bolt's blue ramp
	.ref	flash_ticks,flash_col,flash_back	; MKDISP.ASM - the block-fill flash
	.ref	rain_obj_set_z			; MKZAP.ASM - re-link an object at a new z

	.def	do_rain_fatal

*
* Timing, in ticks (18.28ms).
*
RNF_GATHER	.set	018h	; arms up, stage fading to black, before the bolt
RNF_STEP	.set	6	; ticks between the leader's steps, 6..9 at random -
				;   the irregular pause IS what makes it a stepped leader
RNF_LIFE	.set	0180h	; ticks before the leader is made to connect
RNF_WAIT	.set	0200h	; the director's ceiling on waiting for the strike
RNF_GLOW	.set	010h	; the joined channel's afterglow
RNF_AFTER	.set	050h	; the split plays out under Rain's raised arms
RNF_OUTRO	.set	030h	; after he lowers them
RNF_ZAP		.set	060h	; ticks he jolts once the field reaches him - through
				;   to the strike
RNF_JIT		.set	3	; px the jolt shakes him sideways
RNF_PUFFS	.set	00ch	; smoke off each half after the split ...
RNF_PUFF_GAP	.set	5	; ... one every this many ticks
RNF_MAXCOLS	.set	94	; fadeproc builds in its pdata (UTIL, bgdim_cols)
RNF_LT_REST	.set	40	; where the STOCK fatality dim leaves every palette:
				;   fadeout_tab entry 10, which is as far as
				;   death_blow_fader's `sleep 10` lets it get
				;   (MKDEATH.ASM).  The storm starts its own dim
				;   here and hands the stage back here
*
* The leader's shape, in pixels.  The screen top is only ~80 px above a
* standing man's head, so it steps SHORT and starts well off to one side:
* the build-up is in the pauses and the wander, not in the height.
*
RNF_HEAD	.set	8	; below his anchor, where the connection sits
RNF_TOP		.set	36	; the cloud base: just under the life bars, so the
				;   leader is not drawn across the HUD.  Never above
				;   the page - geo_pass's page guard drops any
				;   segment with an end off it (geo_dropped)
RNF_OFFSIDE	.set	80	; the cloud is 80..112 px off to one side: with
				;   ~70 px between the screen top and his head, the
				;   build-up has to be a long DIAGONAL, as real bolts
				;   so often are
RNF_DROP	.set	2	; a step drops 2..5
RNF_LEAN	.set	8	; and leans at most this far towards him
RNF_NOBRANCH	.set	10	; no branches within this of his head
RNF_BRDX	.set	5	; a branch heads this far sideways a step ...
RNF_BRDY	.set	6	; ... and drops 6..9: branches are where the bolt gets
				;   its SIZE - they spread down past the fighters'
				;   heads while only the main channel connects
RNF_LAUNCH	.set	110	; the ground's and Rain's upward leaders launch with
				;   the tip this close (|dx|+|dy| to his head) - early,
				;   so they are seen reaching for it
RNF_LAUNCH_HIM	.set	70	; ...and his own, last, this close
RNF_NEAR	.set	40	; further than this from him sideways, the leader
				;   mostly TRAVELS (drops 2..3): a long slant in
RNF_ATTACH_X	.set	20	; it must be this nearly over him to connect
RNF_GROUNDUP	.set	4	; ground leaders stand up this far off the floor
RNF_UPDY	.set	4	; an upward leader climbs 4..7 a step
RNF_ATTACH_Y	.set	10	; the leader meets his at this separation
RNF_BRUSH	.set	5	; streamer filaments at the leader's tip
RNF_UPBRUSH	.set	2	; ...and at each upward leader's
RNF_BRUSHLEN	.set	5	; a filament reaches 5..12
*
* The channels.  Branches and upward leaders sit in slabs of 8 joints a
* slot (256 bits) so a slot is a shift away - see rnf_slot.
*
RNF_MAIN_MAX	.set	34	; joints in the main channel
RNF_BR_N	.set	5	; branches
RNF_BR_MAX	.set	8	; joints a branch slot holds (MUST stay 8: rnf_slot)
RNF_BR_GROW	.set	6	; joints one actually grows to - pixels cost
RNF_UP_N	.set	7	; upward leaders (rnf_up_origins has 7 rows)
RNF_UP_MAX	.set	8	; joints a slot holds (MUST stay 8: rnf_slot)
RNF_UP_GROW	.set	6	; joints one actually climbs to - see THE BUDGET

	.bss	rnf_zap,16,1		; ticks of jolt owed to the victim
	.bss	rnf_split,16,1		; 1 = it has struck: come apart
	.bss	rnf_struck,16,1		; 1 = the leader has connected
	.bss	rnf_bolts,16,1		; strikes so far (THE SPRITE BOLTS, below).
					;   Declared up here with the rest of the state
					;   do_rain_fatal clears
	.bss	rnf_pal_armed,16,1	; 0 = the next rnf_light records the storm's
					;   palette set rather than re-driving it
	.bss	rnf_pal_snap,numpal*32,1  ; that set: the palid rnf_light took in
					;   each slot, 0 = not the storm's to light
	.bss	rnf_cx,16,1		; his body centre, world x, at the start
	.bss	rnf_vic_obj,32,1	; his object
	.bss	rnf_tx,16,1		; where it connects - his head, world
	.bss	rnf_ty,16,1
	.bss	rnf_rx,16,1		; Rain's head, world
	.bss	rnf_ry,16,1
	.bss	rnf_offx,16,1		; this tick's world-to-screen offset
	.bss	rnf_offy,16,1
	.bss	rnf_i,16,1		; a slot walk's index (see rnf_draw_branches)
	.bss	rnf_main,RNF_MAIN_MAX*32,1	; [y:x] world joints
	.bss	rnf_main_n,16,1
	.bss	rnf_br,RNF_BR_N*256,1
	.bss	rnf_br_n,RNF_BR_N*16,1
	.bss	rnf_up,RNF_UP_N*256,1
	.bss	rnf_up_n,RNF_UP_N*16,1
	.bss	rnf_up_state,RNF_UP_N*16,1	; 0 idle 1 growing 2 connected ffff aborted
	.global	rnf_struck,rnf_main_n,rnf_up_state	; for the rig
	.global	rnf_bolts			; for the rig
	.global	rnf_zap,rnf_split,rnf_cx,rnf_vic_obj	; so a rig can watch it

**************************************************************************
*											     *
*  do_rain_fatal - Rain's process, reached through fatality_xfer_close   *
*											     *
**************************************************************************
do_rain_fatal
	movk	1,a0			; fade = yes
	movk	2,a1			; fatality #
	calla	init_death_blow

	movi	040h*40,a0
	move	a0,@f_norepell,w	; disable_repell (MKDEATH.ASM)
	calla	stop_me
	calla	face_opponent

	clr	a0
	move	a0,@rnf_zap,w
	move	a0,@rnf_split,w
	move	a0,@rnf_struck,w
	move	a0,@rnf_bolts,w		; ...and the strike COUNT.  rnf_salvo
					;   clears it too, but not until after the
					;   arms are up and RNF_GATHER has run,
					;   and rnf_victim is already watching by
					;   then: left at the last fatality's 14
					;   he started frying on the first tick of
					;   the second one, before a bolt existed
	move	a0,@rnf_pal_armed,w	; ...and re-record the storm's palette set:
					;   a stage, and a victim, that the LAST one
					;   lit is nothing to do with this one

	move	a8,a4
	move	*a13(p_otherguy),a8,l
	calla	mpart_bounds		; a2 = his left, a3 = his right
	add	a3,a2
	sra	1,a2
	move	a2,@rnf_cx,w		; the middle of him
	move	a2,@rnf_tx,w
	move	*a8(oypos),a0,w
	sext	a0,0
	addi	RNF_HEAD,a0
	move	a0,@rnf_ty,w		; ...at his head: where it connects
	move	a4,a8

	move	a8,a4			; Rain's own head - an upward leader comes
	calla	mpart_bounds		;   off HIM too, and loses
	move	a4,a8
	add	a3,a2
	sra	1,a2
	move	a2,@rnf_rx,w
	move	*a8(oypos),a0,w
	sext	a0,0
	addi	RNF_HEAD,a0
	move	a0,@rnf_ry,w

	movi	rnf_victim,a7
	calla	takeover_him

	movi	(rain_bolt_wind<<16)|9,a9
	jsrp	animate2_a9		; arms up - his B,B+HP cast, Ermac's slam
	tsound	0a3h			; the rumble under it
	movk	2,a0
	calla	triple_sound2		; distant thunder
*
* THE DARK.  init_death_blow's own fade is only a dim - death_blow_fader kills
* its fadeprocs after 10 of their 16 ticks, at RNF_LT_REST - so the storm owns
* its darkness and takes the BACKGROUND on down to 1/8, where every flare
* settles back to.  The scenery stays just visible, the way a stage looks at
* night.  It starts from RNF_LT_REST, not from the authored brightness: by the
* time the arms are up the stock dim has already run, and re-fading from the
* top threw the whole stage back up to near daylight first.  What the storm
* takes it gives back - rnf_lt_rest, after the last bolt.
*
	movi	rnf_lt_dark,a0
	callr	rnf_light
	sleep	RNF_GATHER

	.if	rnf_geo
	create	pid_rainfx,rnf_leader_proc
*
* Wait for the strike.  Bounded: the leader forces its attachment at the
* end of its own budget, and this is the belt to that braces.
*
	movi	RNF_WAIT,a0
	move	a0,*a13(p_store6),l
rnf_wait
	sleep	1
	move	@rnf_split,a0,w
	jrne	rnf_after_strike
	move	*a13(p_store6),a0,l
	dec	a0
	move	a0,*a13(p_store6),l
	jrne	rnf_wait
	movk	1,a0
	move	a0,@rnf_split,w		; give the man his ending regardless

rnf_after_strike
	sleep	RNF_AFTER
	.else
	jsrp	rnf_salvo		; Trilogy's bolts, under his raised arms
	.endif
*
* THE STORM PASSES.  The sprite salvo brings the stage back up itself, at
* rsv_tail, so that the gore is never lit against a stage the storm still has
* at 1/8 - see the comment there.  The shelved CPU-drawn version has no salvo,
* so it does it here instead: back up out of the storm's darkness to
* RNF_LT_REST, the level death_blow_fader leaves every other fatality at, over
* the outro below.
*
	.if	rnf_geo
	movi	rnf_lt_rest,a0
	callr	rnf_light
	.endif
*
* ONE FRAME BACK, then the victory pose.  backwards_ani2 walked the whole
* casting lane down - ERTELESLAM3, ERHIPUNCH7, ERELBO2, NJELBO1 - so he
* lowered his arms all the way and stood there before celebrating.  He now
* ticks back exactly ONE frame out of the extended-arm pose and holds that:
* the arm is still up when victory_animation takes him.
*
	movk	9,a9
	calla	get_char_ani2		; a9 ---> the casting lane
rnf_owind
	addi	32,a9
	move	*a9,a0,l
	jrne	rnf_owind		; a9 ---> the 0 terminator
	subi	64,a9			; back two entries: past the last frame (the
					;   extended arm) to the one before it
	move	*a9,a0,l
	calla	ani2
	sleep	RNF_OUTRO
	calla	death_blow_complete
	jauc	victory_animation

**************************************************************************
*											     *
*  THE SPRITE BOLTS - rnf_geo 0 (MAINEQU.ASM), the default since	     *
*  2026-09-22.  Trilogy's rain_bolt_strikes / launch_bolt /		     *
*  fatal_bolt_proc (MKFATAL.C, N64 source) with its own RAINLT art - the    *
*  frames his B,B+HP bolt draws (data/RAINBOLT.LOD):			     *
*											     *
*    raise arms, 0x20		-> the director's arms up + RNF_GATHER	     *
*    launch_bolt(1)		-> the first bolt: it strikes him	     *
*    takeover_him(r_rain_bolts)	-> the first strike holds him on STUMBLE1  *
*				   and sets him smoking; he stays there,   *
*				   buzzing 1 px each side, in Raiden's	     *
*				   grab's FREZ/ELEC/WHITE/BLACK cycle	     *
*				   (rnf_victim)				     *
*    13 more, randu(3*ta10)+6	-> rnf_salvo, ta10 counting 13 down to 1,   *
*      ticks apart, all on him	   so they come faster and faster	     *
*    backwards_ani2, victory	-> the director, after RNF_S_TAIL	     *
*											     *
*  Each bolt (fatal_bolt_proc): at his middle on the floor (the art is	     *
*  anchored on its strike point), over everybody (FRONT_Z+50), mirrored at  *
*  random; the forks 4, the crack, the strike 4+4, shake(12,6) and the	     *
*  boom, 3, ring and scorch at 5, gone.					     *
*											     *
*  Where Trilogy's man explodes (FX_SWAT_BEXP - Stryker's bomb, no MK2	     *
*  art), ours uses MK2's own: the LAST strike (RNF_S_SPLIT) is the return  *
*  stroke - the stage lit, the sky white, the strobe, the ground shaking -  *
*  and he bursts on r_shocker_pop (RAINSPLIT.WAX if rnf_explode is 0).  Every*
*  other strike flares the stage (rnf_lt_flash).			     *
*											     *
**************************************************************************
RNF_S_N		.set	13	; ta10 = 13: the bolts after the first
RNF_S_SPLIT	.set	RNF_S_N+1	; the LAST strike blows him apart - every one
				;   before it lands on a man held on one
				;   frame, frying (rnf_victim)
RNF_S_ZAP	.set	0200h	; he jolts from the first strike until the split
RNF_S_GAP	.set	5	; randu(3*ta10) + this: MK2's randu is 1-based,
				;   Trilogy's randu(n)+6 has its 0 - the same range
RNF_S_TAIL	.set	040h	; after the last launch: the ceiling on waiting
				;   for it to strike
RNF_S_POP	.set	040h	; then the burst plays out before the arms come
				;   down (Raiden's lift waits the same)
RNF_S_RELIGHT	.set	018h	; ...and this far into that tail the stage comes back
				;   up (rnf_lt_rest).  AFTER rnf_lt_final's 19-tick
				;   flare, so the return stroke still lands; BEFORE
				;   the burst has finished, so the GORE is never
				;   lit against a stage the storm still has at 1/8

*
* rnf_salvo - the director's half, in Rain's process.  jsrp / retp: it sleeps.
* The count rides in p_store6 across the sleeps.
*
rnf_salvo
	clr	a0
	move	a0,@rnf_bolts,w
	callr	rnf_launch		; launch_bolt(1): the one that strikes him
	movk	RNF_S_N,a0
	move	a0,*a13(p_store6),l	; ta10
rsv_lp
	move	*a13(p_store6),a0,l
	move	a0,a1
	sll	1,a1
	add	a1,a0			; 3 * ta10
	calla	randu			; 1 .. 3*ta10
	addk	RNF_S_GAP,a0
	calla	prcslp
	callr	rnf_launch
	move	*a13(p_store6),a0,l
	dec	a0
	move	a0,*a13(p_store6),l
	jrne	rsv_lp

	movi	RNF_S_TAIL,a0		; the last bolt still has to come down
	move	a0,*a13(p_store6),l
rsv_wait
	sleep	1
	move	@rnf_split,a0,w
	jrne	rsv_tail
	move	*a13(p_store6),a0,l
	dec	a0
	move	a0,*a13(p_store6),l
	jrne	rsv_wait
	movk	1,a0			; belt and braces: he comes apart whatever
	move	a0,@rnf_split,w		;   happened to the bolts (a full pool)
rsv_tail
*
* THE BURST, THEN THE LIGHTS.  The chunks r_shocker_pop throws are drawn in
* the victim's BLOODY palette (exp_burst -> change_to_bloody_pal, MKDIE.ASM),
* and whether that palette is in death_fade_excludes is a PER-FIGHTER choice
* made for the stock fader (BLOOD_STAYS_LIT = Kitana and the three ninjas,
* tools/make_costume_palettes.py).  So with the stage still at the storm's
* 1/8 the same fatality gave two different pictures: a ninja's bones stayed
* at full brightness and read as white cut-outs pasted on a black wood, and
* everyone else's dropped to 16/128 and could not be seen at all.
*
* Neither is this routine's business to arbitrate.  The storm's extra
* darkness simply ENDS WITH THE STORM, here rather than 40 ticks later, so
* everything after the last bolt - the burst, the gore, the victory pose -
* sits in exactly the light every other fatality in the game has, and gore
* keeps whatever relationship to it retail gave that fighter.  The wait is
* split, not shortened: RNF_S_RELIGHT + the rest still totals RNF_S_POP.
*
	sleep	RNF_S_RELIGHT		; let rnf_lt_final's flare land first
	movi	rnf_lt_rest,a0
	callr	rnf_light
	sleep	RNF_S_POP-RNF_S_RELIGHT	; the burst plays out under his raised arms
	retp

rnf_launch
	mmtm	sp,a0,a1,a7
	create	pid_rainfx,rnf_sbolt_proc	; a8 = Rain, handed down
	mmfm	sp,a0,a1,a7
	rets

*
* rnf_sbolt_proc - one bolt: fatal_bolt_proc.  a8 = Rain on entry (the
* thrower get_proj_obj_m lines it up on), the bolt after.
*
rnf_sbolt_proc
	movk	7,a9
	calla	get_char_ani2		; a_rain_fork - a frame for the object
	calla	get_proj_obj_m		; a10 = the bolt
	move	a10,a10
	jrz	rsb_die			; no object: no bolt, the rest go on
	move	@rnf_cx,a0,w
	move	a0,*a10(oxpos),w	; his middle ...
	move	@ground_y,a0,w
	move	a0,*a10(oypos),w	; ... on the floor: the strike point
	movi	front_z+50,a0
	move	a0,*a10(ozval),l	; FRONT_Z+50 - in front of everybody
	move	a10,a0
	calla	insobj
	move	a10,a8			; a8 = the bolt from here on
	movi	RAINLT_P,a0
	calla	getfpal			; getfpal and store, never swpal - see
	jreq	rsb_nopal		;   ermac_zap_proc (MKZAP.ASM)
	move	a0,*a8(opal),w
rsb_nopal
	calla	random			; if (random() & 0x8000) flip_multi(obj)
	btst	15,a0
	jreq	rsb_noflip
	calla	flip_multi		; mirrored about its anchor, the strike point
rsb_noflip
	movk	7,a9
	calla	get_char_ani2
	movk	rain_bolt_fork,a0
	jsrp	mframew			; the forks gathering - mframew(4)

	tsound	057h			; the crack (Trilogy borrows Nightwolf's)
	movk	8,a9
	calla	get_char_ani2		; a_rain_strike
	calla	do_next_a9_frame	; RNBOLT3 + RNBOLT5: shaft AND ground burst
	callr	rnf_sbolt_hit		;   on one row now - see MKNJ.ASM
	sleep	rain_bolt_live
	calla	do_next_a9_frame	; RNBOLT4 + RNBOLT6
	sleep	rain_bolt_live

	movi	0000c0006h,a11
	calla	shake_a11		; shake_a11(12,6)
	tsound	058h			; the boom - Raiden's bolt contact
	sleep	3

*
* The shaft is done; what is left is the ground wake, so this bolt drops
* BEHIND both fighters - the same rule rain_bolt_proc's rbp_after follows.
* The STRIKE stays at front_z+50 above: fourteen bolts coming down on the man
* is the whole shot, and only the rings they leave on the floor go under him.
*
	move	a8,a0
	movi	back_z-1,a1
	calla	rain_obj_set_z

	movi	0ah,a9
	calla	get_char_ani2		; a_rain_after - the ring, then the scorch
	movk	rain_bolt_aft,a0
	jsrp	mframew
	jauc	delete_proj_and_die
rsb_die	die

*
* rnf_sbolt_hit - what a strike does to the scene.  The first starts his
* jolt; the RNF_S_SPLIT'th is the return stroke and splits him; the rest
* flare the stage.  A plain callr: it never sleeps.
*
rnf_sbolt_hit
	mmtm	sp,a0,a1,a7,a9,a10,a11
	move	@rnf_bolts,a0,w
	inc	a0
	move	a0,@rnf_bolts,w
	cmpi	RNF_S_SPLIT,a0
	jreq	rsh_split
	cmpi	1,a0
	jrne	rsh_flare
	movk	1,a0
	move	a0,@rnf_struck,w
	movi	RNF_S_ZAP,a0
	move	a0,@rnf_zap,w		; he jolts from now until the split
	movk	4,a0
	calla	triple_sound2		; the strike
rsh_flare
	movi	rnf_lt_flash,a0
	callr	rnf_light
	clr	a0
	callr	rnf_skypulse
	jruc	rsh_x
rsh_split
	movk	4,a0
	calla	triple_sound2		; the strike
	movi	rnf_lt_final,a0
	callr	rnf_light
	movk	1,a0
	callr	rnf_skypulse
	create	pid_rainfx,rnf_strobe
	movi	0000c0014h,a11
	calla	shake_a11
	movk	1,a0
	move	a0,@rnf_split,w		; he comes apart on this strike
rsh_x	mmfm	sp,a0,a1,a7,a9,a10,a11
	rets


**************************************************************************
*											     *
*  THE CPU-DRAWN BOLT - rnf_geo (MAINEQU.ASM), SHELVED 2026-09-22.  The    *
*  stepped leader, its branches, the upward leaders and every geo_seg that  *
*  draws them, from here to rnf_light.  Compiled out while rnf_geo is 0;    *
*  set it to 1 to bring the whole thing back unchanged (MKZAP's rgeo_*	     *
*  helpers come back with it).						     *
*											     *
**************************************************************************
	.if	rnf_geo
*
* Where the upward leaders come from: .word x offset from him, kind (0 his
* head - the one that wins, 1 Rain's head, 2 the ground).  Slot 0 MUST be
* his: rnf_try_attach and rnf_attach_now only ever connect slot 0.
*
rnf_up_origins
	.word	0,0
	.word	0,1
	.word	-150,2
	.word	-86,2
	.word	-40,2
	.word	66,2
	.word	128,2

**************************************************************************
*											     *
*  THE BOLT								     *
*											     *
*  One flash, built the way the high-speed camera in Saba et al. (2022,	     *
*  Geophysical Research Letters, doi:10.1029/2022GL101482) sees one:	     *
*											     *
*    * a NEGATIVE LEADER steps down out of the cloud - short jagged steps  *
*      with pauses between - and BRANCHES as it goes.  A branch is a real   *
*      attempt that dies: it grows for RNF_BR_MAX joints and stops, while   *
*      the main channel carries on;					     *
*    * every growing tip wears its STREAMER ZONE - the fine brush of short  *
*      filaments ahead of it that the paper resolves.  Re-rolled every	     *
*      tick, so it shimmers;						     *
*    * when the leader is close, the field lifts UPWARD POSITIVE LEADERS    *
*      off every high point under it (the paper counted 31 off the	     *
*      neighbouring buildings).  Here: off the man's head, off RAIN's head, *
*      and off the ground either side of him, each with a brush of its own; *
*    * exactly one connects - his - and at that instant every other one     *
*      ABORTS and is gone, which is the paper's central picture;	     *
*    * then the RETURN STROKE lights the whole joined channel at once.	     *
*											     *
*  The channels are joint lists in WORLD coordinates, converted per tick,   *
*  so a shaking camera moves the bolt with the scenery rather than sliding  *
*  it across the sky.  All of it is geo_seg in the bolt object's own colour *
*  map (its opal) - which is what keeps it RAINLT_P blue.		     *
*											     *
**************************************************************************
rnf_leader_proc
	movk	7,a9
	calla	get_char_ani2		; a_rain_fork - a frame for the object
	calla	get_proj_obj_m		; a10 = the bolt
	move	a10,a10
	jrz	rlp_die
	move	@rnf_cx,a0,w
	move	a0,*a10(oxpos),w
	move	@ground_y,a0,w
	move	a0,*a10(oypos),w
	move	a10,a0
	calla	insobj
	move	a10,a8			; a8 = the bolt from here on
	callr	rnf_bolt_setup		; its colour map, hidden, its seed
	callr	rnf_chan_init

	movi	RNF_LIFE,a0
	move	a0,*a13(p_store5),l	; ticks before it is made to connect
rlp_tick
	callr	rnf_grow_maybe
	callr	rnf_draw_all
	sleep	1
	move	@rnf_struck,a0,w
	jrne	rlp_strike
	move	*a13(p_store5),a0,l
	dec	a0
	move	a0,*a13(p_store5),l
	jrne	rlp_tick
	callr	rnf_attach_now		; out of time: connect where it is
*
* THE RETURN STROKE, then its afterglow.
*
rlp_strike
	callr	rnf_return_stroke
	movk	RNF_GLOW,a10
rlp_glow
	callr	rnf_draw_bright
	sleep	1
	dsj	a10,rlp_glow
	jauc	delete_proj_and_die
rlp_die	die

*
* rnf_bolt_setup - a8 = a new bolt object: its own colour map, hidden, and
* a seed.  One draw from @rand: it runs identically on both netplay peers,
* and everything after it is a private generator.
*
rnf_bolt_setup
	movi	RAINLT_P,a0
	calla	getfpal			; getfpal and store, never swpal - see
	jreq	rbs_nopal		;   ermac_zap_proc (MKZAP.ASM)
	move	a0,*a8(opal),w
rbs_nopal
	move	a8,a0
	calla	set_inviso		; the sprite itself is never drawn
	calla	random
	ori	1,a0			; an xorshift state is never 0
	move	a0,*a13(p_store6),l
	clr	a0
	move	a0,*a13(p_store4),l	; step on the first tick
	rets

*
* rnf_chan_init - the cloud base: one joint over the top of the screen,
* well off to one side of him, and every other channel empty.
*
rnf_chan_init
	mmtm	sp,a0,a1,a2,a3,a5,a10,a11
	clr	a0
	move	a0,@rnf_main_n,w
	movi	rnf_br_n,a11
	movk	RNF_BR_N,a10
rci_br	move	a0,*a11+,w
	dsjs	a10,rci_br
	movi	rnf_up_n,a11
	movk	RNF_UP_N,a10
rci_up	move	a0,*a11+,w
	dsjs	a10,rci_up
	movi	rnf_up_state,a11
	movk	RNF_UP_N,a10
rci_us	move	a0,*a11+,w
	dsjs	a10,rci_us

	move	*a13(p_store6),a5,l
	calla	rgeo_jit		; a0 = -16..15
	move	a5,*a13(p_store6),l
	move	a0,a2			; -16..15: the sign picks the side, the
	jrnn	rci_pos			;   size adds up to 32 px to RNF_OFFSIDE
	neg	a2
	sll	1,a2
	addi	RNF_OFFSIDE,a2
	neg	a2
	jruc	rci_x
rci_pos	sll	1,a2
	addi	RNF_OFFSIDE,a2
rci_x	move	@rnf_tx,a0,w
	sext	a0,0
	add	a2,a0			; a0 = where it starts, world x
	move	@worldtly,a1,l
	sra	16,a1
	addi	RNF_TOP,a1		; a1 = just over the top of the screen
	callr	rnf_pack
	move	a3,@rnf_main,l
	movk	1,a0
	move	a0,@rnf_main_n,w
	mmfm	sp,a0,a1,a2,a3,a5,a10,a11
	rets

*
* rnf_pack / rnf_unpack - a joint is [y:x], two signed words in a long.
*
rnf_pack				; a0 = x, a1 = y  ->  a3 (a2 goes)
	move	a1,a3
	sll	16,a3
	move	a0,a2
	zext	a2,w
	or	a2,a3
	rets

rnf_unpack				; a3  ->  a0 = x, a1 = y
	move	a3,a0
	sll	16,a0
	sra	16,a0
	move	a3,a1
	sra	16,a1
	rets

*
* rnf_tip - a11 = a channel's joints, a10 = how many: a0/a1 = its tip, and
* a11 left pointing AT the tip.  a2/a3 go.
*
rnf_tip
	move	a10,a2
	dec	a2
	sll	5,a2
	add	a2,a11
	move	*a11,a3,l
	jruc	rnf_unpack

*
* rnf_slot - a9 = which, a11 = the base of a slab of 8-joint channels:
* a11 -> that one's joints.  (8 joints = 256 bits a slot, so a shift - no
* mpyu, whose answer lands in a register PAIR.)
*
rnf_slot
	mmtm	sp,a2
	move	a9,a2
	sll	8,a2
	add	a2,a11
	mmfm	sp,a2
	rets

*
* rnf_grow_maybe - the leader steps on an irregular beat, not every tick:
* the pause between steps is what a stepped leader IS.
*
rnf_grow_maybe
	mmtm	sp,a0
	move	*a13(p_store4),a0,l
	dec	a0
	jrgt	rgm_wait
	callr	rnf_step_all
	move	*a13(p_store6),a0,l	; the next pause: RNF_STEP..RNF_STEP+3,
	srl	13,a0			;   off the generator the step just rolled
	andi	3,a0
	addk	RNF_STEP,a0
rgm_wait
	move	a0,*a13(p_store4),l
	mmfm	sp,a0
	rets

*
* One step of everything.  a5 is the generator, loaded here and written
* back at the end; the steppers carry it and do NOT save it.
*
rnf_step_all
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a9,a10,a11
	move	*a13(p_store6),a5,l
	callr	rnf_step_main
	callr	rnf_step_branches
	callr	rnf_try_launch
	callr	rnf_step_ups
	callr	rnf_try_attach
	move	a5,*a13(p_store6),l
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a9,a10,a11
	rets

*
* rnf_step_main - one step down: leaning at him, wandering, and now and
* then throwing a branch that will not make it.
*
rnf_step_main
	mmtm	sp,a0,a1,a2,a3,a4,a6,a7,a9,a10,a11
	move	@rnf_main_n,a10,w
	cmpi	RNF_MAIN_MAX,a10
	jrhs	rsm_x			; as long as it is allowed to get
	movi	rnf_main,a11
	callr	rnf_tip			; a0/a1 = the tip, a11 -> it
	move	a0,a6
	move	a1,a7

	move	@rnf_tx,a4,w		; lean towards him ...
	sext	a4,0
	sub	a6,a4
	sra	3,a4
	cmpi	RNF_LEAN,a4
	jrle	rsm_l1
	movk	RNF_LEAN,a4
rsm_l1	cmpi	-RNF_LEAN,a4
	jrge	rsm_l2
	movk	RNF_LEAN,a4
	neg	a4
rsm_l2	calla	rgeo_jit		; ... but wander (a0 = -16..15)
	sra	1,a0
	add	a4,a0
	add	a6,a0			; a0 = the next x

	move	@rnf_tx,a2,w		; how far off to the side is it ?
	sext	a2,0
	sub	a0,a2
	abs	a2
	calla	rgeo_xs
	move	a5,a1
	srl	5,a1
	cmpi	RNF_NEAR,a2
	jrls	rsm_near
	andi	1,a1			; far out: it mostly travels (drops 2..3)
	addk	2,a1
	jruc	rsm_dy
rsm_near
	andi	3,a1
	addk	RNF_DROP,a1		; over him: it comes down
rsm_dy	add	a7,a1			; a1 = the next y, always down

	callr	rnf_pack
	addk	32,a11
	move	a3,*a11,l
	inc	a10
	move	a10,@rnf_main_n,w
*
* A branch, sometimes - never so low it would reach the ground first,
* which is not what branches do.
*
	move	@rnf_ty,a2,w
	sext	a2,0
	subi	RNF_NOBRANCH,a2
	cmp	a2,a1
	jrgt	rsm_x			; too low now
	move	a5,a2
	andi	3,a2
	jrne	rsm_x			; one step in four
	callr	rnf_new_branch		; at a0/a1
rsm_x	mmfm	sp,a0,a1,a2,a3,a4,a6,a7,a9,a10,a11
	rets

*
* rnf_new_branch - start one at a0/a1, in the first free slot.
*
rnf_new_branch
	mmtm	sp,a2,a3,a9,a10,a11
	clr	a9
rnb_find
	movi	rnf_br_n,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	move	*a11,a2,w
	jrz	rnb_got
	inc	a9
	cmpi	RNF_BR_N,a9
	jrlo	rnb_find
	jruc	rnb_x			; every slot is in use
rnb_got
	movk	1,a2
	move	a2,*a11,w		; one joint so far
	movi	rnf_br,a11
	callr	rnf_slot
	callr	rnf_pack
	move	a3,*a11,l		; joint 0: where it leaves the channel
rnb_x	mmfm	sp,a2,a3,a9,a10,a11
	rets

*
* rnf_step_branches - each live branch grows sideways and down until it has
* its RNF_BR_MAX joints, and then stops for good.  Even slots go right, odd
* slots left.
*
rnf_step_branches
	mmtm	sp,a0,a1,a2,a3,a4,a6,a7,a9,a10,a11
	clr	a9
rsb_lp	movi	rnf_br_n,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	move	*a11,a10,w
	jrz	rsb_next		; never started
	cmpi	RNF_BR_GROW,a10
	jrhs	rsb_next		; finished growing
	movi	rnf_br,a11
	callr	rnf_slot
	callr	rnf_tip			; a0/a1 = its tip, a11 -> it
	move	a0,a6
	move	a1,a7
	movk	RNF_BRDX,a4
	btst	0,a9
	jreq	rsb_dx
	neg	a4
rsb_dx	calla	rgeo_jit
	sra	2,a0
	add	a4,a0
	add	a6,a0			; a0 = the next x
	calla	rgeo_xs
	move	a5,a1
	srl	7,a1
	andi	3,a1
	addk	RNF_BRDY,a1
	add	a7,a1			; a1 = the next y
	callr	rnf_pack
	addk	32,a11
	move	a3,*a11,l
	movi	rnf_br_n,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	inc	a10
	move	a10,*a11,w
rsb_next
	inc	a9
	cmpi	RNF_BR_N,a9
	jrlo	rsb_lp
	mmfm	sp,a0,a1,a2,a3,a4,a6,a7,a9,a10,a11
	rets

*
* rnf_try_launch - as the leader closes in (|dx|+|dy| to his head), the
* high points under it answer: the ground and Rain first, his own last.
* They all reach; only his will be met.
*
rnf_try_launch
	mmtm	sp,a0,a1,a2,a3,a4,a6,a9,a10,a11
	movi	rnf_main,a11
	move	@rnf_main_n,a10,w
	callr	rnf_tip			; a0/a1 = the leader's tip
	move	@rnf_tx,a2,w
	sext	a2,0
	sub	a0,a2
	abs	a2
	move	@rnf_ty,a3,w
	sext	a3,0
	sub	a1,a3
	abs	a3
	add	a3,a2
	move	a2,a6			; a6 = how close it is, |dx|+|dy|

	clr	a9
rtl_lp	movi	rnf_up_state,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	move	*a11,a3,w
	jrne	rtl_next		; this one is already up (or over)
	movi	RNF_LAUNCH,a3
	move	a9,a9
	jrne	rtl_thr
	movi	RNF_LAUNCH_HIM,a3	; his own answers last
rtl_thr	cmp	a3,a6
	jrhs	rtl_next		; not close enough for this one yet

	movi	rnf_up_origins,a11
	move	a9,a2
	sll	5,a2
	add	a2,a11
	move	*a11,a4,l		; [kind : x offset]
	move	a4,a0
	sll	16,a0
	sra	16,a0			; a0 = the x offset
	sra	16,a4			; a4 = the kind
	jrne	rtl_notvic
	move	@rnf_tx,a2,w		; 0: his head
	sext	a2,0
	add	a2,a0
	move	@rnf_ty,a1,w
	sext	a1,0
	jruc	rtl_seed
rtl_notvic
	cmpi	1,a4
	jrne	rtl_ground
	move	@rnf_rx,a2,w		; 1: Rain's head
	sext	a2,0
	add	a2,a0
	move	@rnf_ry,a1,w
	sext	a1,0
	jruc	rtl_seed
rtl_ground
	move	@rnf_tx,a2,w		; 2: the ground either side of him
	sext	a2,0
	add	a2,a0
	move	@ground_y,a1,w
	sext	a1,0
	subk	RNF_GROUNDUP,a1
rtl_seed
	movi	rnf_up,a11
	callr	rnf_slot
	callr	rnf_pack
	move	a3,*a11,l		; joint 0: where it stands up from
	movi	rnf_up_n,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	movk	1,a3
	move	a3,*a11,w
	movi	rnf_up_state,a11
	add	a2,a11
	move	a3,*a11,w		; growing
	move	a9,a9
	jrne	rtl_next
*
* His own is up: he feels it before it arrives, and the air crackles.
*
	movi	RNF_ZAP,a0
	move	a0,@rnf_zap,w
	tsound	0c7h
rtl_next
	inc	a9
	cmpi	RNF_UP_N,a9
	jrlo	rtl_lp
	mmfm	sp,a0,a1,a2,a3,a4,a6,a9,a10,a11
	rets

*
* rnf_step_ups - the upward leaders climb, leaning at the descending tip.
*
rnf_step_ups
	mmtm	sp,a0,a1,a2,a3,a4,a6,a7,a9,a10,a11
	movi	rnf_main,a11
	move	@rnf_main_n,a10,w
	callr	rnf_tip
	move	a0,a4			; a4 = the leader's x, to lean at

	clr	a9
rsu_lp	movi	rnf_up_state,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	move	*a11,a3,w
	cmpi	1,a3
	jrne	rsu_next		; not growing
	movi	rnf_up_n,a11
	add	a2,a11
	move	*a11,a10,w
	cmpi	RNF_UP_GROW,a10
	jrhs	rsu_next		; as far as it gets
	movi	rnf_up,a11
	callr	rnf_slot
	callr	rnf_tip			; a0/a1 = its tip, a11 -> it
	move	a0,a6
	move	a1,a7
	move	a4,a2
	sub	a6,a2
	sra	4,a2			; lean at the leader, gently
	calla	rgeo_jit
	sra	2,a0
	add	a2,a0
	add	a6,a0			; a0 = the next x
	calla	rgeo_xs
	move	a5,a1
	srl	9,a1
	andi	3,a1
	addk	RNF_UPDY,a1
	neg	a1			; upward, always
	add	a7,a1
	callr	rnf_pack
	addk	32,a11
	move	a3,*a11,l
	movi	rnf_up_n,a11
	move	a9,a2
	sll	4,a2
	add	a2,a11
	inc	a10
	move	a10,*a11,w
rsu_next
	inc	a9
	cmpi	RNF_UP_N,a9
	jrlo	rsu_lp
	mmfm	sp,a0,a1,a2,a3,a4,a6,a7,a9,a10,a11
	rets

*
* rnf_try_attach - has the leader come down to the one rising off his
* head ?  It must be nearly over him AND down to that tip - or, failing
* that, already at his head height, which forces it: a leader never passes
* the man it is going for.
*
rnf_try_attach
	mmtm	sp,a0,a1,a2,a3,a6,a7,a10,a11
	move	@rnf_up_state,a0,w
	cmpi	1,a0
	jrne	rta_x			; his has not launched, or it is over
	movi	rnf_main,a11
	move	@rnf_main_n,a10,w
	callr	rnf_tip
	move	a0,a6
	move	a1,a7			; a6/a7 = the leader's tip
	move	@rnf_ty,a2,w		; down at his head already ?  Then it
	sext	a2,0			;   connects whatever the gap - a leader
	subk	4,a2			;   never passes the man it is going for
	cmp	a2,a7
	jrge	rta_go
	movi	rnf_up,a11
	move	@rnf_up_n,a10,w
	callr	rnf_tip			; a0/a1 = his upward leader's tip
	move	a6,a2
	sub	a0,a2
	abs	a2
	cmpi	RNF_ATTACH_X,a2
	jrhi	rta_x			; not over him yet
	subi	RNF_ATTACH_Y,a1
	cmp	a1,a7
	jrlt	rta_x			; not down to it yet
rta_go	callr	rnf_attach_now
rta_x	mmfm	sp,a0,a1,a2,a3,a6,a7,a10,a11
	rets

*
* rnf_attach_now - the connection.  His upward leader's tip is joined to
* the channel, and every other one ABORTS - dozens reach up, one is
* answered.
*
rnf_attach_now
	mmtm	sp,a0,a1,a2,a3,a10,a11
	move	@rnf_up_n,a10,w
	jrz	rtn_mark		; nothing launched: it strikes as it is
	movi	rnf_up,a11
	callr	rnf_tip			; a0/a1 = where it joins
	move	@rnf_main_n,a10,w
	cmpi	RNF_MAIN_MAX,a10
	jrhs	rtn_mark		; no room to write the joining step
	move	a10,a2
	sll	5,a2
	movi	rnf_main,a11
	add	a2,a11
	callr	rnf_pack
	move	a3,*a11,l
	inc	a10
	move	a10,@rnf_main_n,w
rtn_mark
	movk	2,a0
	move	a0,@rnf_up_state,w	; his: connected
	movi	rnf_up_state+16,a11
	movk	RNF_UP_N-1,a10
	movi	0ffffh,a0
rtn_ab	move	a0,*a11+,w		; the rest: aborted, and gone this tick
	dsjs	a10,rtn_ab
	movk	1,a0
	move	a0,@rnf_struck,w
	mmfm	sp,a0,a1,a2,a3,a10,a11
	rets

*
* rnf_return_stroke - the flash.  Everything at once, because that is what
* it looks like: the channel lights end to end, the stage is lit by it, the
* sky goes white, the ground shakes and the man comes apart.
*
rnf_return_stroke
	mmtm	sp,a0,a1,a7,a9,a10,a11
	tsound	057h			; the crack
	movk	4,a0
	calla	triple_sound2		; the strike
	movi	rnf_lt_final,a0
	callr	rnf_light
	movk	1,a0
	callr	rnf_skypulse
	create	pid_rainfx,rnf_strobe
	movi	0000c0014h,a11
	calla	shake_a11
	movk	1,a0
	move	a0,@rnf_split,w		; he comes apart on this tick
	create	pid_rainfx,rnf_scorch_proc
	mmfm	sp,a0,a1,a7,a9,a10,a11
	rets

*
* rnf_scorch_proc - the splash and the scorch it leaves on the floor, his
* B,B+HP bolt's own ground art.  a8 = the bolt object (inherited): it is the
* thrower here, and gives the new object its ochar and its facing.
*
rnf_scorch_proc
	movi	0bh,a9
	calla	get_char_ani2		; a_rain_strike_g - the splash
	calla	get_proj_obj_m
	move	a10,a10
	jrz	rscp_die
	move	@rnf_tx,a0,w
	move	a0,*a10(oxpos),w
	move	@ground_y,a0,w
	move	a0,*a10(oypos),w
	move	a10,a0
	calla	insobj
	move	a10,a8
	movi	RAINLT_P,a0
	calla	getfpal
	jreq	rscp_nopal
	move	a0,*a8(opal),w
rscp_nopal
	movi	0bh,a9
	calla	get_char_ani2
	movk	rain_bolt_live,a0
	jsrp	mframew
	movi	0ah,a9
	calla	get_char_ani2		; a_rain_after - the ring, then the scorch
	movk	rain_bolt_aft,a0
	jsrp	mframew
rscp_die
	die				; the scorch stays where it burned

**************************************************************************
*											     *
*  DRAWING								     *
*											     *
*  Every channel is walked once a tick and queued on geo_list in the bolt's *
*  colour map - a9 carries that map in its high half and rgeo_seg ORs it    *
*  into each colour.  rgeo_seg takes a8 as its sideways shift, so a8 (the   *
*  object) is only read before the walk and put back after it.		     *
*											     *
*  THE BUDGET.  geo_list holds GEO_MAX (192) segments a frame, it is	     *
*  SHARED - hudtext draws the HUD's words through it - and geo_seg drops    *
*  what does not fit, silently.  At 7 fingers with 3-filament brushes and a *
*  two-strand-glow leader this ran past it and the HUD lost letters ("01    *
*  WINS" drawn as "01").  So while it grows: the leader is core plus ONE    *
*  glow strand, branches and fingers one strand, fingers climb 6 joints,   *
*  brushes 5 and 2 filaments - about 120 segments at the worst tick.  The   *
*  return stroke is heavy (weight 3), but by then the fingers are gone.     *
*											     *
**************************************************************************
rnf_draw_all
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	callr	rnf_draw_setup		; a9 = colour map, offsets, a5, dint
	clr	a4			; one strand while it grows - geo_pass plots
					;   every pixel in software with interrupts
					;   off, and pixels are what tip the frame
					;   over; the weight is saved for the stroke
	movi	rnf_main,a11
	move	@rnf_main_n,a10,w
	callr	rnf_draw_chain
	clr	a4
	callr	rnf_draw_branches
	callr	rnf_draw_ups
	move	@rnf_struck,a0,w
	jrne	rda_x			; connected: the brushes are over
	callr	rnf_draw_brushes
	move	a5,*a13(p_store6),l	; so the brushes shimmer, tick to tick
rda_x	eint
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	rets

*
* rnf_draw_bright - the return stroke and its afterglow: the joined channel
* only, heavy, no brushes.
*
rnf_draw_bright
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	callr	rnf_draw_setup
	movk	3,a4			; core, glow, and two more strands out
	movi	rnf_main,a11
	move	@rnf_main_n,a10,w
	callr	rnf_draw_chain
	movk	1,a4
	move	@rnf_up_state,a0,w
	cmpi	2,a0
	jrne	rdb_x
	movi	rnf_up,a11
	move	@rnf_up_n,a10,w
	callr	rnf_draw_chain		; the one that answered, lit with it
rdb_x	eint
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11
	rets

*
* rnf_draw_setup - the colour map, this tick's world-to-screen offsets, and
* interrupts off for the whole queue: geo_pass runs in the display
* interrupt and would otherwise draw half a bolt.
*
rnf_draw_setup
	move	*a8(opal),a9,w
	sll	16,a9
	move	@worldtlx,a0,l
	sra	16,a0
	move	a0,@rnf_offx,w
	move	@worldtly,a0,l
	sra	16,a0
	move	a0,@rnf_offy,w
	move	*a13(p_store6),a5,l
	dint
	rets

*
* rnf_draw_chain - a11 = joints, a10 = how many, a4 = weight (0 core only,
* 1 core + one glow strand, 3 the return stroke: 5 strands, white core,
* blue glow, deep-blue outline).  a9 = the colour map.  All but a8 kept.
*
rnf_draw_chain
	mmtm	sp,a0,a1,a2,a3,a6,a7,a10,a11
	cmpi	2,a10
	jrlo	rdc_x
	move	*a11+,a3,l
	callr	rnf_unpack
	callr	rnf_to_screen
	move	a0,a6
	move	a1,a7
	dec	a10
rdc_seg
	move	*a11+,a3,l
	callr	rnf_unpack
	callr	rnf_to_screen
	clr	a8
	movi	rgeo_core,a2
	or	a9,a2
	calla	rgeo_seg		; the white core
	move	a4,a4
	jrz	rdc_next		; weight 0: that is all
	cmpi	3,a4
	jreq	rdc_heavy
	movi	rgeo_glow,a2		; weight 1: one glow strand beside it
	or	a9,a2
	movk	1,a8
	calla	rgeo_seg
	jruc	rdc_next
*
* Weight 3, the return stroke: the white core, light blue either side of
* it, and RAINLT_P's deepest blue as an OUTLINE.  Five strands, not the
* seven first tried: seven put geo_list over GEO_MAX for the whole glow
* (geo_full +90) and the HUD's own words paid for it.  Against a stage the
* flash has just lit, white and light blue alone vanish into a pale wall;
* the dark edge is what keeps the channel reading as the brightest thing.
*
rdc_heavy
	movi	rgeo_glow,a2
	or	a9,a2
	movk	1,a8
	calla	rgeo_seg
	neg	a8
	calla	rgeo_seg
	movi	rgeo_branch,a2
	or	a9,a2
	movk	2,a8
	calla	rgeo_seg
	neg	a8
	calla	rgeo_seg
rdc_next
	move	a0,a6
	move	a1,a7
	dsj	a10,rdc_seg
rdc_x	mmfm	sp,a0,a1,a2,a3,a6,a7,a10,a11
	rets

rnf_to_screen				; a0/a1 world -> a0/a1 screen
	mmtm	sp,a2
	move	@rnf_offx,a2,w
	sext	a2,0
	sub	a2,a0
	move	@rnf_offy,a2,w
	sext	a2,0
	sub	a2,a1
	mmfm	sp,a2
	rets

*
* The slabs are walked with the slot number in @rnf_i: a9 is the colour
* map and every other register is spoken for by the chain draw.
*
rnf_draw_branches
	mmtm	sp,a0,a2,a10,a11
	clr	a0
	move	a0,@rnf_i,w
rdbr_lp	move	@rnf_i,a0,w
	movi	rnf_br_n,a11
	move	a0,a2
	sll	4,a2
	add	a2,a11
	move	*a11,a10,w
	movi	rnf_br,a11
	sll	4,a2			; slot * 256
	add	a2,a11
	callr	rnf_draw_chain		; fewer than 2 joints draws nothing
	move	@rnf_i,a0,w
	inc	a0
	move	a0,@rnf_i,w
	cmpi	RNF_BR_N,a0
	jrlo	rdbr_lp
	mmfm	sp,a0,a2,a10,a11
	rets

rnf_draw_ups
	mmtm	sp,a0,a2,a3,a10,a11
	clr	a0
	move	a0,@rnf_i,w
rdup_lp	move	@rnf_i,a0,w
	move	a0,a2
	sll	4,a2
	movi	rnf_up_state,a11
	add	a2,a11
	move	*a11,a3,w
	cmpi	1,a3
	jreq	rdup_draw
	cmpi	2,a3
	jrne	rdup_next		; idle, or aborted at the attachment
rdup_draw
	movi	rnf_up_n,a11
	add	a2,a11
	move	*a11,a10,w
	movi	rnf_up,a11
	sll	4,a2			; slot * 256
	add	a2,a11
	callr	rnf_draw_chain
rdup_next
	move	@rnf_i,a0,w
	inc	a0
	move	a0,@rnf_i,w
	cmpi	RNF_UP_N,a0
	jrlo	rdup_lp
	mmfm	sp,a0,a2,a3,a10,a11
	rets

*
* rnf_draw_brushes - THE STREAMER ZONE.  A fan of short filaments ahead of
* every growing tip, re-rolled every tick - the fine structure the paper
* resolved, and why a leader tip reads as a brush rather than a point.
*
rnf_draw_brushes
	mmtm	sp,a0,a1,a2,a3,a4,a10,a11
	movi	rnf_main,a11
	move	@rnf_main_n,a10,w
	callr	rnf_tip
	callr	rnf_to_screen
	movk	RNF_BRUSH,a4
	movk	1,a3			; downward
	callr	rnf_brush_at

	clr	a0			; the upward leaders wear them too - the
	move	a0,@rnf_i,w		;   "fingers" the paper counts
rdbs_up	move	@rnf_i,a0,w
	move	@tick,a3,w		; half of them a tick, alternately: the
	xor	a0,a3			;   brushes are shimmer anyway, and all of
	btst	0,a3			;   them every tick is what tipped the frame
	jrne	rdbs_next		;   over (overload 3 once the fingers were up)
	move	a0,a2
	sll	4,a2
	movi	rnf_up_state,a11
	add	a2,a11
	move	*a11,a3,w
	cmpi	1,a3
	jrne	rdbs_next
	movi	rnf_up_n,a11
	add	a2,a11
	move	*a11,a10,w
	movi	rnf_up,a11
	sll	4,a2
	add	a2,a11
	callr	rnf_tip
	callr	rnf_to_screen
	movk	RNF_UPBRUSH,a4
	clr	a3			; upward
	callr	rnf_brush_at
rdbs_next
	move	@rnf_i,a0,w
	inc	a0
	move	a0,@rnf_i,w
	cmpi	RNF_UP_N,a0
	jrlo	rdbs_up
	mmfm	sp,a0,a1,a2,a3,a4,a10,a11
	rets

*
* rnf_brush_at - a0/a1 = the tip on screen, a4 = how many filaments, a3 = 1
* for a brush reaching down, 0 for one reaching up.  a5 rolls.
*
rnf_brush_at
	mmtm	sp,a0,a1,a2,a4,a6,a7,a10,a11
	move	a0,a10			; a10/a11 = the tip, for every filament
	move	a1,a11
rba_lp	calla	rgeo_jit		; a0 = -16..15
	sra	1,a0
	add	a10,a0			; the far end's x
	calla	rgeo_xs
	move	a5,a1
	srl	11,a1
	andi	7,a1
	addk	RNF_BRUSHLEN,a1		; how far ahead
	move	a3,a3
	jrne	rba_down
	neg	a1
rba_down
	add	a11,a1			; the far end's y
	move	a10,a6
	move	a11,a7			; from the tip
	clr	a8
	movi	rgeo_branch,a2
	or	a9,a2
	calla	rgeo_seg
	dsj	a4,rba_lp
	mmfm	sp,a0,a1,a2,a4,a6,a7,a10,a11
	rets
	.endif				; rnf_geo - end of the shelved CPU bolt

**************************************************************************
*                                                                        *
*  rnf_light - light the stage.  a0 = a fade table (multiplier/128 per   *
*  tick, 0ffffh ends it).  A new flash kills the last one's fadeprocs    *
*  first.  No budget, because light has to arrive on one tick - the tables*
*  end on repeated values so a transfer the palette queue drops is retried*
*  rather than leaving a palette at the wrong brightness.                *
*                                                                        *
*  IT WALKS ALL OF palram, NOT bpalram.  A stage is not only its background*
*  BLOCKS: setup_floor_info (BGND.ASM) takes the FLOOR's palette from    *
*  getfpal, and every background-list prop is a gso_dmawnz object, so those*
*  are fpalram too.  Walking bpalram alone took the trees to 1/8 and left*
*  the ground and the props at the stock dim - on THE LIVING FOREST, a   *
*  glowing floor and a bright square of bark (a mad-tree face, drawn as an*
*  opaque rectangle over a trunk) hanging in a black wood.               *
*                                                                        *
*  AND IT LIGHTS ONLY THE STAGE THAT WAS THERE WHEN THE STORM BEGAN.     *
*  rnf_pal_snap is that set, recorded on the first call and re-driven by *
*  every call after it; a slot that was empty then, or has been re-let   *
*  since, is not the storm's to touch.  This is what makes the storm behave*
*  like the stock dim, and it is NOT an optimisation - it is the whole   *
*  difference between the two:                                           *
*                                                                        *
*    death_blow_fader (MKDEATH.ASM) is a ONE-SHOT.  It fades, sleeps 10, *
*    dallprc's every pid_fade and dies, so from tick ~10 of ANY other    *
*    fatality in the game nothing dims anything ever again.  GORE is     *
*    created hundreds of ticks later - exp_burst -> change_to_bloody_pal *
*    (MKDIE.ASM) - so getfpal queues it from ROM at FULL brightness and it*
*    stays there.  That is what a finisher's body parts look like.       *
*                                                                        *
*    rnf_light is not a one-shot: it runs on the dark, on all 14 bolt    *
*    flashes and on the relight, every one of them AFTER the split.  Re- *
*    walking the live palette set therefore caught the chunks and dragged*
*    them to RNF_LT_REST, and the body parts came out dim in a way they do*
*    in no other fatality.  Reported twice from play before it was found,*
*    because against a stage at the same 40/128 it reads as consistent.  *
*                                                                        *
*  The exclusion scan (death_fade_excludes - the game's own answer to what*
*  must stay lit in a finisher, and the list death_blow_fader already    *
*  trusts) therefore runs on the FIRST call only, and the snapshot carries*
*  it forward.  The fighters, the bars, the amulets and boonpal are skipped*
*  by name; the floor and the props move with the stage.                 *
*                                                                        *
**************************************************************************
rnf_light
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a11
	move	a0,a11
	movi	pid_fade,a0
	movi	0ffffh,a1
	calla	kilall			; the last flash stops where it is
	move	@rnf_pal_armed,a5,w	; 0 = first call: record the storm's set
	movi	palram,a2		; fpalram's slot 0, and bpalram after it
	movi	rnf_pal_snap,a6
	movi	numpal,a3
	clr	a9
rlt_slot
	move	*a2(palid),a8,l		; what is in the slot NOW
	move	a5,a5
	jrne	rlt_later
*
* The first call: decide once, and remember what we decided.
*
	move	a8,a8
	jrz	rlt_none		; empty
	movi	death_fade_excludes,a4
rlt_skip
	move	*a4+,a0,l
	jrz	rlt_size		; end of the list: this one is ours to light
	cmp	a0,a8
	jrne	rlt_skip
	jruc	rlt_none		; excluded: it stays exactly where it is
rlt_size
	move	*a8,a0,w		; colour count (the top bits are flags)
	sll	23,a0
	srl	23,a0
	jrz	rlt_none
	cmpi	RNF_MAXCOLS,a0
	jrhi	rlt_none		; fadeproc cannot stage it - see its own guard
	move	a8,*a6,l		; ours, for the rest of the storm
	jruc	rlt_make
rlt_none
	clr	a0
	move	a0,*a6,l
	jruc	rlt_next
*
* Every call after it: the recorded set, and only while the slot still
* holds the same palette.  Anything born during the storm - the gore above
* all - is left at the brightness getfpal gave it, exactly as a stock
* fatality leaves it.
*
rlt_later
	move	*a6,a0,l
	jrz	rlt_next		; not ours
	cmp	a0,a8
	jrne	rlt_next		; re-let since: not ours either
rlt_make
	create	pid_fade,fadeproc	; a8 = source, a9 = slot, a11 = table
rlt_next
	addi	palrsiz,a2
	addi	32,a6
	inc	a9
	dsj	a3,rlt_slot
	movk	1,a0
	move	a0,@rnf_pal_armed,w	; the set is recorded from here on
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a11
	rets

*
*  THE STORM'S DARKNESS PICKS UP WHERE THE STOCK DIM ENDS.  This used to open
*  at 120/128 - all but the authored brightness - which was a bug you could
*  see: init_death_blow's death_blow_fader has ALREADY walked every palette
*  down fadeout_tab and stopped at entry 10 (40/128) by the time the arms are
*  up, so re-fading from 120 shot the whole stage back up to near daylight for
*  half a second before it fell again.  Measured off the rig's own capture,
*  the dominant scale over the scenery went 128 -> 108 -> 91 -> 66 -> *116* ->
*  79 -> 46 -> 24 -> 11.  It now starts at RNF_LT_REST, where the stock fader
*  left it, so the storm only ever takes light AWAY.
*
rnf_lt_dark				; down to the storm's darkness, and hold
	.word	40,38,36,34,32,30,28,26,24,23,22,21,20,19,18,17,16,16,16,16,0ffffh
rnf_lt_flash				; one of the salvo's bolts: a shorter,
					;   dimmer flare, back to the darkness
	.word	150,130,110,90,70,52,40,30,24,20,16,16,16,0ffffh
rnf_lt_final				; the return stroke, back to the darkness -
					;   NOT to 0: the stage is still there.  Peak
					;   200, not 255: bleach the wall and the bolt
					;   has nothing to stand out against
	.word	200,200,180,200,170,150,130,112,96,80,64,50,40,30,24,20,16,16,16,0ffffh
*
*  rnf_lt_rest - THE STORM PASSES.  Back up from the storm's darkness to
*  RNF_LT_REST, the level death_blow_fader leaves every other fatality at, so
*  the stage matches the props and the gore standing on it again.  Without it
*  the background stayed at 16/128 while everything in fpalram sat at 40 - a
*  two-and-a-half times mismatch that read as the scenery having lost its
*  palette, and it held there through the burst, the victory pose and the win
*  banner, every one of the ~340 ticks to the round tearing down.
*
rnf_lt_rest
	.word	17,19,21,24,27,30,33,36,38,40,40,40,40,0ffffh

*
* rnf_skypulse - a0 = 0 a bolt, 1 the last bolt: the colour behind the
* whole stage pulses blue-white and goes back to black.
*
rnf_skypulse
	mmtm	sp,a0,a1,a7,a9
	movi	rnf_sky_small,a9
	move	a0,a0
	jrz	rsk_go
	movi	rnf_sky_big,a9
rsk_go	create	pid_rainfx,rnf_sky_proc
	mmfm	sp,a0,a1,a7,a9
	rets

rnf_sky_proc				; a9 = the colours, 0 ends it
	move	*a9+,a0,w
	move	a0,@irqskye,w
	jrz	rskp_x
	sleep	1
	jruc	rnf_sky_proc
rskp_x	die

rnf_sky_small
	.word	04a9fh,02d5bh,01453h,00c2ah,0
rnf_sky_big
	.word	07fffh,06f7fh,05a9fh,04a9fh,0395bh,02d5bh,01c53h,01453h,00c2ah,0

*
* rnf_strobe - the last bolt's flash over the whole play area: the block
* fill (flash_pass), OVER the art, in boonpal white and blue.
*
rnf_strobe
	movi	rnf_strobe_tab,a9
rst_lp	move	*a9+,a0,w		; colour, 0 ends it
	jrz	rst_x
	move	*a9+,a10,w		; ticks lit
	move	*a9+,a11,w		; ticks dark after
	move	a0,@flash_col,w
	clr	a0
	move	a0,@flash_back,w	; over the art - the bolt is in your face
	move	a10,@flash_ticks,w	; the latch, LAST
	add	a11,a10
	move	a10,a0
	calla	prcslp
	jruc	rst_lp
rst_x	die

rnf_strobe_tab
	.word	bpal_white,2,2
	.word	bpal_white,1,3
	.word	bpal_blue,1,4
	.word	bpal_white,1,0
	.word	0

**************************************************************************
*											     *
*  rnf_victim - the man it is done to, in his own process		     *
*											     *
*  HE IS HELD, NOT ANIMATED.  The first strike stands him on the FIRST	     *
*  frame of his own stumble lane (row 023h, STUMBLE1 - the lane every	     *
*  fighter carries) where he stood, and there he stays for the whole	     *
*  salvo: no further frames, and he is never turned round.  What moves is  *
*  the current in him - his palette runs the ELECTROCUTION CYCLE Raiden's  *
*  grab uses (shock_next_beat, MKGUYS.ASM): FREZ, ELEC, WHITE,		     *
*  BLACK, continuously from the first strike - and a 1 px BUZZ each side   *
*  of where he stood, every tick.  He SMOKES from the first strike too	     *
*  (rnf_body_smoke).  The last strike blows him apart (rnf_split).	     *
*											     *
*  It used to stumble him a frame at a time and flip_multi him on every    *
*  strike, which read as the man flailing about rather than being fried.   *
*											     *
*  a9  = the stumble lane (set once by rv_stand, never walked)		     *
*  a11 = scratch - the smoke process's subject at the create		     *
*  p_store1/2 = where he stood (oxpos/oypos) - the pose's anchor, and what *
*               the buzz is measured from				     *
*  p_store3 = the buzz's phase: 0 = 1 px left, 1 = 1 px right		     *
*  p_store5 = 1 once the first bolt has landed (0 = not struck yet)	     *
*  p_store6 = ticks to the next beat					     *
*  p_store8 = 1 while he is off his own palette				     *
*											     *
**************************************************************************
RNF_CYC_BEAT	.set	3	; ticks a beat of the cycle - twice the grab's 6:
				;   the late strikes come only 6-8 ticks apart
RNF_JIT_X	.set	1	; px each side of where he stood: the buzz
RNF_BSMOKE_GAP	.set	5	; ticks between puffs off the body while he fries

rnf_victim
	calla	stop_me
	move	a8,@rnf_vic_obj,l
	move	*a8(oxpos),a0,w
	sext	a0,0
	move	a0,*a13(p_store1),l
	move	*a8(oypos),a0,w
	sext	a0,0
	move	a0,*a13(p_store2),l
	clr	a0
	move	a0,*a13(p_store3),l
	move	a0,*a13(p_store5),l
	move	a0,*a13(p_store6),l
	move	a0,*a13(p_store8),l
	calla	shock_cycle_reset	; the current opens on the cycle's first beat
	clr	a9
	clr	a11

rv_lp	sleep	1
	move	@rnf_split,a0,w
	jrne	rv_split
*
* HAS A BOLT LANDED YET ?  rnf_struck, not the strike COUNT: it is the one-shot
* the first strike sets (rnf_sbolt_hit), and do_rain_fatal clears it on the way
* in.  Reading a count and acting on any CHANGE meant a count left over from
* the last fatality read as a strike on this one's first tick, and he fried
* through the arms going up with nothing in the sky.  Until a bolt lands he
* stands in his daze - no pose, no buzz, no current, no smoke.
*
	move	@rnf_struck,a0,w
	jrz	rv_lp
	move	*a13(p_store5),a1,l
	jrne	rv_same			; already frying: the other thirteen land on a
					;   man already held there - no new frame, and
					;   he is never turned round
*
* THE FIRST STRIKE - the only one that changes anything he is doing.
*
	move	a0,*a13(p_store5),l	; a0 = 1: struck
	callr	rv_stand		; STUMBLE1, where he stood: the pose he
	move	a8,a11			;   holds for the rest of it
	create	pid_rainfx,rnf_body_smoke
*
* Held: the buzz and the current.  a11 survives the create (getprc hands
* a7-a11 down and leaves the parent's), but nothing here needs it again.
*
rv_same	callr	rv_jitter		; 1 px each side of where he stood
*
* The palette - running from the first strike to the split, never his own
* colours in between: the cycle IS the electrocution.
*
*
*  The beats come from shock_next_beat (MKGUYS.ASM), which is where Raiden's
*  grab, his bolt, and both his fatalities get theirs too - one table for the
*  whole game, so a recolour of the cycle cannot reach four electrocutions and
*  miss the fifth.  This block used to carry a second copy of it and step its
*  own phase in p_store4.
*
rv_cyc	move	*a13(p_store6),a0,l
	dec	a0
	move	a0,*a13(p_store6),l
	jrgt	rv_lp
	movk	RNF_CYC_BEAT,a0
	move	a0,*a13(p_store6),l
	calla	shock_next_beat		; a1 = this beat's palette routine
	call	a1			; a8 = him
	movk	1,a0
	move	a0,*a13(p_store8),l
	jruc	rv_lp

rv_ownpal
	move	*a13(p_store8),a0,l
	jreq	rvop_x
	calla	player_normpal
	clr	a0
	move	a0,*a13(p_store8),l
rvop_x	rets

*
* rv_nudge - move him a0 across, a1 down.  oxpos IS oxval's top half
* (DISPEQU: 080h/090h), so the 16.16 add is the whole move.
*
rv_nudge
	sll	16,a0
	move	*a8(oxval),a2,l
	add	a0,a2
	move	a2,*a8(oxval),l
	sll	16,a1
	move	*a8(oyval),a2,l
	add	a1,a2
	move	a2,*a8(oyval),l
	rets

*
* rv_jitter - THE BUZZ.  1 px each side of where he stood, a side a tick.
* Measured from p_store1 every time rather than added to, so it cannot
* drift over the ~200 ticks the salvo lasts.
*
rv_jitter
	move	*a13(p_store3),a1,l
	xori	1,a1
	move	a1,*a13(p_store3),l
	movk	RNF_JIT_X,a0
	move	a1,a1
	jrne	rvj_right
	neg	a0			; phase 0 = 1 px left, 1 = 1 px right
rvj_right
	move	*a13(p_store1),a1,l
	add	a1,a0			; where he should be this tick
	move	*a8(oxpos),a2,w
	sext	a2,0
	sub	a2,a0			; ...so move him this far
	clr	a1
	jruc	rv_nudge

*
* rv_stand - his stumble's first frame, where he stood.  a9 = the stumble
* lane at its next frame.
*
rv_stand
	movi	023h,a9
	calla	get_char_ani		; his stumble
	calla	do_next_a9_frame
	move	*a8(oxpos),a2,w
	sext	a2,0
	move	*a13(p_store1),a0,l
	sub	a2,a0
	move	*a8(oypos),a2,w
	sext	a2,0
	move	*a13(p_store2),a1,l
	sub	a2,a1
	jruc	rv_nudge

*
* rv_settle - on his feet where he stood, in his own colours
*
rv_settle
	callr	rv_ownpal
	jruc	rv_stand

*
* THE SPLIT.  His legs become their own object, standing where he stands -
* 039h part 6, the standing legz r_sai_split cuts him to - and he is the
* torso.  Both then play their half of RAINSPLIT.WAX in their own process.
*
rv_split
	.if	rnf_explode
*
* THE EXPLOSION - Trilogy's r_rain_bolts ends set_inviso +
* create_fx(FX_SWAT_BEXP), Stryker's bomb burst, which MK2 has no art for.
* MK2's own body pop is r_shocker_pop (MKDIE.ASM), the end of Raiden's
* electrocution: the BOOM, white_flash, set_inviso, kiss_explode's blood and
* the exp_burst chunk shower over a shaken camera.  It is a reaction, run in
* the victim's own process with a8 = his object - which is where this is -
* so, as r_ermac_fatal_slam does, the last line is a jump into it.  Put the
* jolt's shift and palette back first: the chunks start off his position.
*
	callr	rv_settle
	calla	stop_me
	calla	rsnd_death_voice	; Trilogy's death_scream
	jauc	r_shocker_pop		; never comes back (wait_forever)
	.endif
	callr	rv_settle
	calla	stop_me
	move	*a8(oflags2),a0,w
	andni	m_shadow,a0		; a torso thrown this high would float a
	move	a0,*a8(oflags2),w	;   shadow up into the scenery
	calla	rsnd_death_voice
	tsound	056h			; crunch

	move	a8,a10			; a10 = him, the torso from here on
	movi	039h,a9
	calla	get_char_ani
	movk	6,a14
	calla	find_part_a14		; a9 = standing legz
	calla	gmo_proc		; a8 = the legs
	move	a8,a8
	jreq	rvs_torso		; object pool empty: the torso still flies
	move	*a10(ochar),*a8(ochar),w
	move	*a10(oid),*a8(oid),w
	move	*a10(oflags2),*a8(oflags2),w
	calla	change_to_bloody_pal
	push	a8
	move	a8,a0			; a0 = the legs
	move	a10,a8			; a8 = him
	calla	match_ani_points	; same anchor, same facing
	pull	a8
	movi	front_z+1,a0
	move	a0,*a8(ozval),l
	calla	insobja8

	movk	7,a0
	calla	create_blood_proc	; torso_ripped_blood, off the cut
	jreq	rvs_b1
	move	a8,*a0(pa11),l
rvs_b1	movi	019h,a0
	calla	create_blood_proc	; sai_waist_blood: the spray off the waist
	jreq	rvs_b2
	move	a8,*a0(pa11),l
rvs_b2
	movi	rnf_legs_tpl,a0
	movi	rnf_legs_ram,a1
	move	a10,a2
	callr	rnf_build
	move	a8,a11
	create	pid_rainfx,rnf_smoker
	movi	rnf_legs_ram,a9
	movi	rnf_legs_holds,a11
	create	pid_rainfx,rnf_half_proc	; a8 = the legs

rvs_torso
	move	a10,a8
	calla	change_to_bloody_pal
	movi	front_z+2,a0
	move	a0,*a8(ozval),l
	movi	rnf_torso_tpl,a0
	movi	rnf_torso_ram,a1
	move	a8,a2
	callr	rnf_build
	move	a8,a11
	create	pid_rainfx,rnf_smoker
	movi	rnf_torso_ram,a9
	movi	rnf_torso_holds,a11
	jsrp	rnf_walk
	movi	000040004h,a11
	calla	shake_a11
	calla	rsnd_ground
	jauc	wait_forever

rnf_half_proc				; a8 = the legs, a9 = lane, a11 = holds
	jsrp	rnf_walk
	calla	rsnd_ground
	die

*
* rnf_walk - a9 = a built lane, a11 = its holds: every flip and offset is
* the animator's own (do_next_a9_frame), one frame per call.
*
rnf_walk
	calla	do_next_a9_frame
	jreq	rwk_x
	move	*a11+,a0,w
	calla	prcslp
	jruc	rnf_walk
rwk_x	retp

*
* rnf_smoker - a11 = an object: smoke off it for a while
*
rnf_smoker
	movk	RNF_PUFFS,a9
rsm_lp	clr	a10
	create	pid_1_puff,smoke_a_1
	sleep	RNF_PUFF_GAP
	dsj	a9,rsm_lp
	die

*
* rnf_body_smoke - a11 = the victim's object: smoke off him from the first
* strike until he comes apart.  A man being held in a lightning strike is
* cooking, so one stock puff (smoke_a_1) every RNF_BSMOKE_GAP ticks - the
* same puff the two halves get afterwards (rnf_smoker), and the same
* density as smoke_a_guy (MKFX.ASM).
*
* IT CHECKS HE IS STILL A LIVE FIGHTER before every puff, the way
* rain_bolt_smoke (MKZAP.ASM) does: smoke_a_1 walks a11's multipart chain,
* and this outlives its subject - rnf_split hands the body to r_shocker_pop,
* which sets it inviso and bursts it.  p1_obj / p2_obj are the live pair and
* are re-read each time.
*
rnf_body_smoke
	move	@rnf_split,a0,w
	jrne	bsm_die			; he has come apart: rnf_smoker takes over
	move	@p1_obj,a0,l
	cmp	a0,a11
	jreq	bsm_puff
	move	@p2_obj,a0,l
	cmp	a0,a11
	jrne	bsm_die			; his object is gone - stop
bsm_puff
	clr	a10			; smoke_a_1: no squeeze routine
	create	pid_1_puff,smoke_a_1
	sleep	RNF_BSMOKE_GAP
	jruc	rnf_body_smoke
bsm_die	die

*
* rnf_build - copy template a0 to RAM a1, with every placeholder swapped
* for the frame it names in object a2's own lanes.  ani_adjustxy's word
* pair is copied without a look - it can be any value.
*
rnf_build
	mmtm	sp,a0,a1,a3,a4
	move	a0,a3
	move	a1,a4
rbd_lp	move	*a3+,a0,l
	move	a0,*a4+,l
	jrz	rbd_x			; the terminator
	cmpi	ani_adjustxy,a0
	jrne	rbd_ph
	move	*a3+,a0,l
	move	a0,*a4+,l		; its dx,dy
	jruc	rbd_lp
rbd_ph	cmpi	0100h,a0
	jrlo	rbd_lp			; a flip - verbatim
	cmpi	0300h,a0
	jrhs	rbd_lp
	callr	rnf_lookup
	subi	32,a4
	move	a0,*a4+,l		; his frame, over the placeholder
	jruc	rbd_lp
rbd_x	mmfm	sp,a0,a1,a3,a4
	rets

*
* rnf_lookup - a0 = placeholder, a2 = the object whose art: a0 = the frame
*
rnf_lookup
	mmtm	sp,a1,a2,a8,a9,a14
	move	a2,a8
	move	a0,a1
	andi	0ffh,a1			; a1 = n
	cmpi	0200h,a0
	jrhs	rlk_torso
	dec	a1
	sll	5,a1
	addi	rnf_legpos,a1
	move	*a1+,a2,w		; the part
	move	*a1,a1,w		; the row
	movi	039h,a9
	jruc	rlk_go
rlk_torso
	dec	a1			; the row
	movk	1,a2			; the part
	movi	041h,a9
rlk_go	calla	get_char_ani		; a9 = the lane (a0/a14 go)
	move	a2,a14
	calla	find_part_a14
	sll	5,a1
	add	a1,a9
	move	*a9,a0,l
	mmfm	sp,a1,a2,a8,a9,a14
	rets

;>>>WAX BEGIN rainsplit
* GENERATED from data/RAINSPLIT.WAX by tools/rain_split_wax_import.py.
* Legs = slot 5, torso = slot 6.  Edit the project, not this block.
* 0100h|n = his DECAPLEGn, 0200h|n = his RIPTORSOn, swapped in by rnf_build.
*
RNF_TPL_LONGS	.set	32		; the longer template, terminator included

rnf_legpos				; DECAPLEGn -> part (find_part_a14), row, in 039h
	.word	6,0			; DECAPLEG1
	.word	7,0			; DECAPLEG2
	.word	7,1			; DECAPLEG3
	.word	8,0			; DECAPLEG4
	.word	9,1			; DECAPLEG5
	.word	9,2			; DECAPLEG6
	.word	9,3			; DECAPLEG7

rnf_legs_tpl
	.long	ani_adjustxy
	.word	81,218
	.long	ani_flip
	.long	ani_flip_v
	.long	00106h		; NJDECAPLEG6 - HIS, looked up at run time
	.long	ani_flip		; back to base facing for the adjust
	.long	ani_adjustxy
	.word	-27,-35
	.long	ani_flip
	.long	00105h		; NJDECAPLEG5 - HIS, looked up at run time
	.long	ani_flip		; back to base facing for the adjust
	.long	ani_adjustxy
	.word	-61,-35
	.long	ani_flip
	.long	00102h		; NJDECAPLEG2 - HIS, looked up at run time
	.long	ani_flip		; back to base facing for the adjust
	.long	ani_adjustxy
	.word	-118,-148
	.long	ani_flip_v
	.long	00105h		; NJDECAPLEG5 - HIS, looked up at run time
	.long	00105h		; NJDECAPLEG5 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	4,0
	.long	00106h		; NJDECAPLEG6 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	1,0
	.long	00107h		; NJDECAPLEG7 - HIS, looked up at run time
	.long	0
rnf_legs_holds
	.word	4,4,4,4,4,4,4

rnf_torso_tpl
	.long	ani_adjustxy
	.word	-17,31
	.long	ani_flip
	.long	00201h		; NJRIPTORSO1 - HIS, looked up at run time
	.long	ani_flip		; back to base facing for the adjust
	.long	ani_adjustxy
	.word	-35,43
	.long	ani_flip_v
	.long	00204h		; NJRIPTORSO4 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	11,-41
	.long	00203h		; NJRIPTORSO3 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	8,-7
	.long	00203h		; NJRIPTORSO3 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	6,20
	.long	00203h		; NJRIPTORSO3 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	21,59
	.long	00202h		; NJRIPTORSO2 - HIS, looked up at run time
	.long	ani_adjustxy
	.word	47,-54
	.long	ani_flip
	.long	ani_flip_v
	.long	00205h		; NJRIPTORSO5 - HIS, looked up at run time
	.long	ani_flip		; back to base facing for the adjust
	.long	ani_adjustxy
	.word	14,10
	.long	ani_flip
	.long	00206h		; NJRIPTORSO6 - HIS, looked up at run time
	.long	0
rnf_torso_holds
	.word	4,4,4,4,4,4,4,4
;<<<WAX END rainsplit

	.bss	rnf_legs_ram,RNF_TPL_LONGS*32,1
	.bss	rnf_torso_ram,RNF_TPL_LONGS*32,1

	.end
