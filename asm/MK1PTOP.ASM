**************************************************************************
*											     *
*  video game project:	Mortal Kombat 2							*
*											     *
*  module: mk1ptop.asm  --- THE PIT (MK1), curback 01Ah			     *
*											     *
*  MK1's Pit, whole: the bridge the fighters stand on, the spiked pillars   *
*  all the way down, the pit floor with its impaled heads, and the night    *
*  sky over it - moon, drifting clouds, a rock outcrop and the silhouette   *
*  that sometimes crosses the moon.  An uppercut in FINISH HIM throws the   *
*  loser off the bridge and the camera rides him down the shaft, 700 rows,  *
*  onto the spikes.  No cut: MK1 never cut either (worldtly 45 -> 752,	     *
*  measured off the real thing by tools/run_mk1_pit_capture.ps1).	     *
*											     *
*  Where it all comes from - read, not remembered - is in the header of     *
*  tools/make_mk1pit.py.  In short:					     *
*    bridge + shaft  data/KUNGFU5.BDB/.BDD, MK1's own Pit background, the   *
*                    blocks above what THE PIT BOTTOM (curback 00Ah)	     *
*                    already carries: MK1PTOPBMOD, generated		     *
*    pit floor       THE PIT BOTTOM's own three modules, laid under it at   *
*                    the offset their pixels fit KUNGFU5 at		     *
*    sky             MK1 rev 5.0's calla FFCB8950, out of mk.zip:	     *
*                    data/MK1PSKY.IMG / MK1PFLY.IMG and the tables in       *
*                    src/MK1PTOPB.ASM					     *
*    layout          MK1's stage record FFCB8690: ground 264, camera y 45,  *
*                    x 264, limits 18..744, every module at 020000h	     *
*										     *
*  Change a number in tools/make_mk1pit.py and rerun --apply; the tool's   *
*  --preview renders the screen from the same constants.		     *
*										     *
*  Back to front:							     *
*    mk1p_sky_lst  the sky, m_noscroll: nailed to the screen the way MK1    *
*                  kept it, so the shaft wall slides up over it on the way  *
*                  down.  ozpos orders it: moon, silhouette, clouds, rocks  *
*    baklst1       bridge + shaft (MK1PTOPBMOD)			     *
*    baklst4       the pit's walls and floor (MK1PITBGBMOD)		     *
*    fighters								     *
*    baklst2/3     the pit's front spike row and its gore, IN FRONT of the  *
*                  fighters - the same order THE PIT BOTTOM uses, which is  *
*                  what puts the body BEHIND the spike tips when he lands   *
*										     *
*  Its own object for MK3CAVE.ASM's reason: BGND.ASM is near GSPA's	     *
*  out-of-memory point, and only lists mk1ptop_mod in table_o_mods.	     *
*										     *
**************************************************************************
	.file	"mk1ptop.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm
	.include	mk1ptopb.asm		; GENERATED - tools/make_mk1pit.py
	.include	mk1psk1.tbl		; the sky's records, dealt by size across
	.include	mk1psk2.tbl		;   five packs - which table a label lands
	.include	mk1psk3.tbl		;   in can change on a re-deal, so all
	.include	mk1psk4.tbl		;   five are included
	.include	mk1psk5.tbl
	.include	mk1pfly.tbl		; the silhouettes

	.globl	mk1ptop_mod		; BGND.ASM table_o_mods, entry 01Ah
	.globl	mk1p_moon		; MK1WSHR.ASM - THE WARRIOR SHRINE's calla
	.globl	r_fall_down_mk1pit	; MKREACT.ASM r_upcutted
	.global	mk1p_sky_lst		; RAM.ASM's list block - see there
	.globl	MK1PITBGBMOD,MK1PITFSBMOD,MK1PITGOREBMOD,TPLPALS
	.globl	objs_available		; MKFX.ASM
	.if	wunit
	.globl	lair_fall_in_lava	; UMK3LAIR.ASM
	.endif
	.globl	ss_20000,ss_20000_neg	; BGND.ASM - one table step of x scroll,
					;   the speed the Pit II's own fall pans at
	.text

mk1ptop_mod
	.word	mk1p_erase		; autoerase colour - MK1's night sky
	.word	mk1p_ground		; ground y - the bridge deck
	.word	mk1p_worldy		; initial world y
	.word	mk1p_start		; initial worldx

	.word	mk1p_left		; scroll left limit
	.word	mk1p_right		; scroll right limit

	.long	mk1ptop_calla
	.long	mk1ptop_scroll		; scroll table
	.long	dlists_mk1ptop

	.long	bak1mods
	.long	MK1PTOPBMOD		; baklst1 = bridge + shaft
	.word	mk1p_top_x,mk1p_top_y
	.long	MK1PITFSBMOD		; baklst2 = the pit's front spike row
	.word	mk1p_fs_x,mk1p_fs_y
	.long	MK1PITGOREBMOD		; baklst3 = its gore overlay
	.word	mk1p_fs_x,mk1p_fs_y
	.long	MK1PITBGBMOD		; baklst4 = the pit's walls and floor
	.word	mk1p_bg_x,mk1p_bg_y
	.long	skip_bakmod		; baklst5 \
	.long	skip_bakmod		; baklst6  \ never inherit the previous
	.long	skip_bakmod		; baklst7  / stage's modules
	.long	skip_bakmod		; baklst8 /
	.long	0ffffffffh

mk1ptop_scroll
	.long	0			; 8
	.long	0			; 7
	.long	0			; 6
	.long	0			; 5
	.long	020000h			; 4 - pit walls + floor
	.long	020000h			; 3 - gore
	.long	020000h			; 2 - spike row
	.long	020000h			; 1 - bridge, shaft, players
	.long	0			; 0

dlists_mk1ptop
	.long	mk1p_sky_lst,worldtlx8+16	; the sky (m_noscroll - x is unused)
	.long	baklst1,worldtlx+16		; bridge + shaft
	.long	baklst4,worldtlx4+16		; the pit's walls and floor
	.long	-2				; shadows
	.long	ghost_lst,worldtlx+16		; fighter afterimages (ghost_rec)
	.long	objlst,worldtlx+16
	.long	baklst2,worldtlx2+16		; spike row, in front of him
	.long	baklst3,worldtlx3+16		; ...and its gore
	.long	objlst2,worldtlx+16
	.long	0

mk1ptop_calla
	clr	a0
	move	a0,@mk1p_sky_lst,l	; the object pool is rebuilt between
					; stages - never inherit a list head, and
					; not even for the one tick before the sky
					; process first runs
	create	pid_bani,mk1p_sky	; pid_bani, not pid_fx, for peak_rain's
	create	pid_bani,mk1p_flyer	;   reason: killfx sweeps every pid_fx
					;   process on a fatality, and this stage's
					;   fatality is the one that shows the sky
	movi	mk1p_shad_hi,a0		; the shadow stays ON the deck, the way THE
	move	a0,@shad_hi,w		;   DEAD POOL keeps it on its walkway: above
	movi	mk1p_shad_lo,a0		;   the deck is sky and below it the pillar
	move	a0,@shad_lo,w		;   capitals.  Rows measured off the art by
					;   tools/make_mk1pit.py (deck_band)
	movi	mk1p_shad_bias,a0	; ...with its foot row on the boots' last row -
	move	a0,@shad_bias,w		;   measured (SHADOW_BIAS in the tool)
	movk	2,a0			; fast compressed shadows; legacy raw pieces -
	move	a0,@shad_fast,w		;   shadf clips to the same band
	rets

**************************************************************************
*										     *
*  mk1p_sky - the moon, the rock outcrop and ten drifting clouds	     *
*										     *
*  MK1 builds its clouds as multipart objects (FFCB9C90); here every piece  *
*  is its own object at `anchor - anipoint`, MK1's anipoints kept verbatim, *
*  and all the pieces of one cloud share its oxvel - so they move as one    *
*  shape without a multipart record.  The wrap is MK1's too: every	     *
*  mk1p_cloud_tick ticks, a cloud whose ANCHOR is past mk1p_cloud_wrap_x    *
*  goes back mk1p_cloud_wrap_dx.  The anchor is re-derived per piece from   *
*  its own record (oxpos + anix), so every piece of a cloud gives the same  *
*  answer and the shape never tears across the wrap.			     *
*										     *
*  All or nothing: if the pool cannot hold the whole sky it takes none of   *
*  it, and the stage shows MK1's plain night colour.			     *
*										     *
**************************************************************************
MK1P_Z_MOON	.set	0		; ozpos, back to front - insobj_v keeps the
MK1P_Z_FLY	.set	1		;   list sorted on it
MK1P_Z_CLOUD	.set	2
MK1P_Z_ROCK	.set	3

mk1p_sky
	movi	mk1p_sky_objs,a0
	calla	objs_available
	jrnc	mks_none

	movi	PITMOON,a5
	movi	mk1p_moon_x,a0
	movi	mk1p_moon_y,a1
	movi	MK1P_Z_MOON,a2
	clr	a6
	callr	mk1p_piece

	movi	mk1p_rocks,a9
mks_rock
	move	*a9+,a5,l
	jrz	mks_clouds
	movi	mk1p_rock_x,a0
	movi	mk1p_rock_y,a1
	movi	MK1P_Z_ROCK,a2
	clr	a6
	callr	mk1p_piece
	jruc	mks_rock

mks_clouds
	movi	mk1p_clouds,a9
mks_cloud
	move	*a9+,a7,l		; a7 = this cloud's piece list
	jrz	mks_tick
	move	*a9+,a10,w
	sext	a10,w			; a10 = anchor x - MK1 starts some of
	move	*a9+,a11,w		;   them off the left edge
	sext	a11,w			; a11 = anchor y
	move	*a9+,a6,l		; a6 = its drift, 16.16
mks_piece
	move	*a7+,a5,l
	jrz	mks_cloud
	move	a10,a0
	move	a11,a1
	movi	MK1P_Z_CLOUD,a2
	callr	mk1p_piece
	jruc	mks_piece

mks_tick
	sleep	mk1p_cloud_tick
	movi	mk1p_sky_lst,a8		; nothing is carried across the sleep -
mkst1	move	*a8,a8,l		;   walk the list from its head
	jrz	mks_tick
	move	*a8(ozpos),a0,w
	cmpi	MK1P_Z_CLOUD,a0
	jrne	mkst1
	move	*a8(oimg),a5,l
	move	*a5(ianioff),a2,l
	sll	16,a2
	sra	16,a2			; a2 = anix
	move	*a8(oxpos),a0,w
	sext	a0,w
	add	a2,a0			; a0 = this cloud's anchor x
	cmpi	mk1p_cloud_wrap_x,a0
	jrle	mkst1
	move	*a8(oxpos),a0,w
	subi	mk1p_cloud_wrap_dx,a0
	move	a0,*a8(oxpos),w		; round the back again
	jruc	mkst1

mks_none
	die

*
*  mk1p_moon - the moon alone, on mk1p_sky_lst.  MK1's FFCB8E40: THE PIT's
*  calla CALLRs it, and it is THE WARRIOR SHRINE's whole calla (MK1WSHR.ASM),
*  so the shrine gets the same record in the same place.  The caller zeroes
*  mk1p_sky_lst first.
*
mk1p_moon
	movk	1,a0
	calla	objs_available
	jrnc	mkm_die
	movi	PITMOON,a5
	movi	mk1p_moon_x,a0
	movi	mk1p_moon_y,a1
	movi	MK1P_Z_MOON,a2
	clr	a6
	callr	mk1p_piece
mkm_die
	die

*
*  mk1p_piece - one m_noscroll sky object, placed at anchor - anipoint and
*  filed on mk1p_sky_lst.
*
*  in:  a5 = image record, a0 = anchor x, a1 = anchor y, a2 = ozpos,
*       a6 = oxvel (16.16)
*  out: a8 = the object.  Everything else preserved.
*
mk1p_piece
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a9,a10,a11
	mmtm	sp,a0,a1,a2
	calla	gso_dmawnz_ns
	mmfm	sp,a0,a1,a2
	move	*a8(oimg),a5,l		; re-read: nothing promises gso kept a5
	move	*a5(ianioff),a3,l	; a3 = y:x anipoint
	move	a3,a4
	sll	16,a4
	sra	16,a4			; a4 = anix
	sra	16,a3			; a3 = aniy
	sub	a4,a0
	sub	a3,a1
	move	a0,*a8(oxpos),w
	move	a1,*a8(oypos),w
	move	a2,*a8(ozpos),w
	move	a6,*a8(oxvel),l
	move	a8,a0
	movi	mk1p_sky_lst,b4		; insobj_v only READS b4
	calla	insobj_v
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a7,a9,a10,a11
	rets

**************************************************************************
*										     *
*  mk1p_flyer - the silhouette that crosses the moon			     *
*										     *
*  MK1's FFCB8F10, beat for beat: wait mk1p_fly_first ticks, pick one of    *
*  eight - a sleigh and reindeer, a witch, a UFO, a rocket, a blimp... -    *
*  start it off the left edge at the moon's height, drift it right at 2px   *
*  a tick until it is off the right edge, rest mk1p_fly_gap ticks, and do   *
*  it once more.  Then it is parked past the right edge for the round.     *
*										     *
*  MK1 rolls randu(8) for the pick.  This takes battle+round instead: @rand *
*  reseeds identically every round, so a roll would pick the same one every *
*  round anyway, and a draw here would shift the fight's random stream.     *
*										     *
**************************************************************************
mk1p_flyer
	sleep	mk1p_fly_first
	movk	1,a0
	calla	objs_available
	jrnc	mkf_die

	move	@battle_num,a0,w
	move	@round_num,a1,w
	add	a1,a0
	andi	7,a0
	sll	5,a0			; -> a .long table.  Bit addresses: 32/long
	addi	mk1p_flyers,a0
	move	*a0,a5,l		; a5 = tonight's silhouette

	movi	mk1p_fly_x,a0
	movi	mk1p_fly_y,a1
	movi	MK1P_Z_FLY,a2
	movi	mk1p_fly_xvel,a6
	callr	mk1p_piece		; a8 = it
	movi	mk1p_fly_passes,a10

mkf1	sleep	1
	move	*a8(oxpos),a0,w
	sext	a0,w
	cmpi	mk1p_fly_end_x,a0
	jrlt	mkf1			; still crossing

	dec	a10
	jrz	mkf_park
	movi	mk1p_fly_restart_x,a0
	move	a0,*a8(oxpos),w		; back off the left edge...
	clr	a0
	move	a0,*a8(oxvel),l
	sleep	mk1p_fly_gap		; ...and wait
	movi	mk1p_fly_xvel,a0
	move	a0,*a8(oxvel),l
	jruc	mkf1

mkf_park
	clr	a0
	move	a0,*a8(oxvel),l		; parked past the right edge: clipped,
mkf_die					;   and never moves again
	die

**************************************************************************
*										     *
*  THE PIT (MK1)'s stage fatality - off the bridge and down the shaft	     *
*										     *
*  r_fall_down_mk1pit is the victim's side, reached from r_upcutted's	     *
*  act_mk1pit_fall test (MKREACT.ASM); do_down_the_mk1pit (MKDEATH.ASM) is  *
*  the winner's.  It is YOTEIGAI TOR's r_fall_off_mountain in shape - the   *
*  same launch, the same scroller hand-off, the same camera clamp - because *
*  it is the same problem: the art below the bridge is real, so the camera  *
*  just keeps going and the modules stream their own blocks in.		     *
*										     *
*  What differs:							     *
*    - no aiming at a target.  The pit floor runs the whole width of the    *
*      stage on the fighters' own plane, so anywhere he falls is over it.   *
*      What he must not do is land OFF THE SCREEN, and the CAMERA does that *
*      job first: mk1p_fall_scroll follows him sideways for the length of   *
*      the fall, exactly as the Pit II's own does (pit_scroll, BGND.ASM).   *
*      mk1p_hold_on_screen is only the fallback for when the stage runs     *
*      out - the camera parked on a scroll limit with the body still        *
*      drifting off the edge - and leans him back inside screen x 100..300. *
*    - he lands on spikes, not in water: flat on his back, the pit's front  *
*      spike row drawn over him (baklst2 is after objlst), a thud, a shake  *
*      and the uppercut's blood spray off the spikes, as in MK1.	     *
*										     *
**************************************************************************
mk1p_fall_drop	.set	mk1p_floor_y-mk1p_ground	; feet: deck -> pit floor
mk1p_settle_vel	.set	040000h		; 4px a tick onto the clamp once he is down
mk1p_hold_lft	.set	100		; screen x he is settled back inside on the
mk1p_hold_rgt	.set	300		;   way down.  He LANDS flat on his back,
					;   ~80px either side of his anipoint - 340
					;   left the body half off the right edge
mk1p_throw_vel	.set	010000h		; the uppercut's own drift - MK1's 1px a
					;   tick (FFCD1720), not r_upcutted's 2.
					;   Named because mk1p_hold_on_screen eases
					;   BACK to it, so the two cannot drift apart

r_fall_down_mk1pit
	.if	wunit
	move	@curback,a0,w
	cmpi	01fh,a0			; SCORPION'S LAIR (UMK3): into the lava
	jaeq	lair_fall_in_lava	; (UMK3LAIR.ASM)
	.endif
	movi	pid_master,a0
	calla	existp
	jreq	rfmp3			; a0 = master proc
	move	*a0(pwake),a1,l
	cmpi	fatality_waiting,a1	; still counting down the window ?
	jrne	rfmp3
	movi	0100h,a2
	move	a2,*a0(pa11),l		; hold it open - this one is long

rfmp3
;
;  NO nosounds here.  It was copied from r_fall_down_pit, which needs it
;  because it tears the whole screen down; this does not, and it cut off
;  both the death-blow chime (make_db_tone's 034h, a few ticks old) and the
;  uppercut's own hit sound - so the hit landed silent but for the scream.
;  THE DEAD POOL (r_fall_in_slime) never calls it and plays the same
;  monster-hit pair; this now does what it does.
;
	movk	1,a0
	calla	create_blood_proc
	movi	0001b001ch,a1
	calla	randsnd			; either of these monster hit sounds
	calla	disturbing_scream	; ahhh !!!
	movi	000060006h,a11
	calla	shake_a11		; shake upon contact
	sleep	1			; the tick nosounds used to take - keeps the fall's timing
	clr	a0
	move	a0,@f_shadows,w		; p_ganiy is about to point 700 rows down,
					;   and a shadow placed off it floats above
					;   the deck.  start_shadows puts them back
					;   next round
*
*  Repell, hands off the fall.  It is the fatality's business who is where
*  now, and repell has three separate ways of disagreeing - all three were
*  measured on the real machine at victim x 1080:
*
*    - the body passes THROUGH the winner on its way down (they are 55px
*      apart and 700 rows is a long way to fall), so for the ~7 ticks their
*      sprites overlap repell_now shoves them apart at 3px a tick.  The body
*      jogged 21px back out towards the edge in the middle of its own fall
*      and the winner slid 35px along the bridge in his victory pose.
*    - rep8's "i'm pushing him ---> 1/2 speed" halves whatever this fatality
*      asked for while they are close, so the lean below came out at 1.5px
*      a tick for eight ticks and then 3 again.
*    - stuff_a6a7 teleports both oxpos towards each other once they are
*      more than screen_distance apart, which is the wrong rule entirely
*      for a man 700 rows below the other one.
*
*  Every other fatality in the game already does this (disable_repell,
*  MKDEATH.ASM, 040h*40 ticks); it is a countdown and round_init_words
*  (MAIN.ASM) zeroes it at the next round, so nothing has to hand it back.
*
*  stuff_velocities still runs while it is disabled - only the ADJUST is
*  gated on the flag - so p?_xvel is still copied onto oxvel every tick and
*  mk1p_hold_on_screen still has to write both.
*
	movi	040h*40,a0
	move	a0,@f_norepell,w	; disable_repell (MKDEATH.ASM)
*
*  Take the camera before the floor moves (r_fall_off_mountain's reason:
*  flight snaps oypos onto p_ganiy, and the scroller has to be watching).
*
	clr	a1
	not	a1
	movi	pid_scroll,a0
	calla	existp
	movi	mk1p_fall_scroll,a7
	calla	fastxfer		; scroller ---> ride him down
	move	a8,*a0(pa11),l		; pass my object

	move	*a13(p_ganiy),a0,w
	addi	mk1p_fall_drop,a0
	move	a0,*a13(p_ganiy),w	; floor = the bottom of the pit

	movi	mk1p_throw_vel,a0	; a0 = initial x vel
	movi	-0c0000h,a1		; a1 = initial y vel
	movi	06000h,a2		; a2 = gravity
	movk	5,a3			; a3 = ani speed
	movi	00fh,a9			; a9 = ani offset
	movi	mk1p_hold_on_screen,a6
	jsrp	flight_call
*
*  Down.
*
	calla	stop_me
	tsound	0cfh			; impact at bottom of pit
	movi	0ccccccceh,a1
	calla	ochar_sound		; wham !!
	movi	00008000ch,a11		; MK1's landing shake (FFCD1CB0)
	calla	shake_a11

	movi	00fh,a9
	calla	get_char_ani
	calla	find_part2
	calla	find_part2
	calla	find_last_frame
	calla	do_next_a9_frame	; flat on his back, on the spikes

	movi	018h,a0
	calla	create_blood_proc	; MK1's fountain off the spikes -
					;   mk1pit_fountain (MKBLOOD.ASM), its
					;   FFDE4B40 frame for frame

*
*  Close the fatality out PROPERLY, the way PIT II's landing does (fall7,
*  MKFALL.ASM) and the way MK1's own pit does (send_code_a3 09Ch at FFCD1A00,
*  right after the landing grunt).  death_blow_complete raises f_death to -1
*  AND sends 035h, the death-blow-over tune.
*
*  Writing f_death by hand - copied from THE DEAD POOL and YOTEIGAI TOR, which
*  are the two that do it - is only half of it, and on THIS stage the other
*  half WAS load bearing: rfmp3's nosounds (since removed) silenced the 034h death-blow
*  tone make_db_tone started, and nothing ever started anything again.  The
*  Dead Pool gets away with it because it never calls nosounds at all (its
*  tone plays straight through the drop); here the fall, the impact and the
*  whole wait for the round to tear down ran dead silent.
*
	calla	death_blow_complete	; f_death = -1 + the death blow over tune
	jauc	wait_forever

*
*  mk1p_hold_on_screen - flight_call's every-tick hook.  a8 = the body.
*
*  Keep him landing in shot without the player ever seeing the hand that
*  does it.  Three rules:
*
*    rising   - NOTHING.  This half of the arc is the uppercut, and it is
*               the only half the player can see it in.
*    camera   - NOTHING, while mk1p_fall_scroll can still pan the way he is
*      free     going.  Moving the VIEW is free and moving the BODY is not,
*               so the lean is the last resort and not the first: anywhere
*               but hard against a scroll limit the stage simply opens out
*               ahead of him and he keeps the line the uppercut gave him.
*               Without this test the two fought each other - the camera
*               was nailed down for the whole fall and the hook hauled him
*               back in from the edge instead, which is what a mid-bridge
*               uppercut looked like.
*    falling  - lean towards the band at mk1p_steer_acc a tick, capped at
*               mk1p_steer_max; inside the band, lean back to the throw's
*               own mk1p_throw_vel.  Never assign a velocity outright.
*
*  Both rules are the measured arc, not taste.  Traced tick by tick at
*  victim x 1080 with the camera on its right scroll limit (MP_FALLTRACE=1
*  in tools/mk1pit_stage_fatality_test.lua), the version this replaces read:
*
*    rel 002  thrown, 1px a tick out               screen x 339
*    rel 003  outward speed ZEROED - 31 ticks of climb with no knockback
*    rel 034  apex: -3px a tick, straight from 0   the pull-back starts
*    rel 047  42px back - PAST where he was thrown from
*    rel 048  0px a tick, dead stop                8 ticks straight down
*    rel 056  +3px a tick (repell_now, see above)  21px back out
*    rel 063  -1.5px a tick (rep8 halving us)
*    rel 070  -3px a tick                          and stop again at 073
*
*  Seven changes of direction in one fall, four of them instant.  The first
*  is the one that shows: a cornered man starts OUTSIDE the band, so the
*  old rising rule took the knockback away on the tick after contact and
*  the uppercut launched him vertically, which is the thing it must never
*  look like.  It bought nothing, either - he is off the top of the screen
*  from rel ~013 to rel ~057 (the camera holds at mk1p_worldy until he is
*  060h rows into it), so the whole climb and the first third of the fall
*  are unwatched.  There is no reason to correct him there and every reason
*  not to correct him at the one moment he IS being watched.
*
*  So the correction now happens where it is free, and it happens as an
*  acceleration: 1/4 px a tick per tick reaches the 3px cap in 12 ticks,
*  which reads as a tumbling body carrying momentum rather than as a wall.
*  Worst case is the corner - 36px outside standing, plus ~32px of climb
*  the throw now keeps - and 68px costs 12 ticks of lean plus 17 at the cap
*  against the ~70 ticks between the apex and the floor.
*
*  A one-way barrier instead of a push is still not enough, and that has
*  not changed: at the right end of the bridge the camera sits on its
*  scroll limit and a fighter can already STAND at screen x ~336, so
*  merely stopping him still lands a body that lies 80px either side of
*  its anipoint half off the screen (measured: victim x 1080, landed 351).
*
mk1p_steer_max	.set	030000h		; 3px a tick, the fastest the lean gets
mk1p_steer_acc	.set	04000h		; 1/4 px a tick per tick
mk1p_hold_on_screen
	mmtm	sp,a0,a1,a2,a3
	move	*a8(oyvel),a0,l
	jrn	mkh9			; still RISING - the uppercut owns this
					;   half of the arc and it is the half
					;   the hit is read from.  See above

	move	*a8(oxpos),a0,w
	move	@worldtlx+16,a1,w
	sub	a1,a0			; a0 = his screen x
	move	*a8(oxvel),a2,l		; a2 = what he is doing now

	cmpi	mk1p_hold_rgt,a0
	jrgt	mkh_pull_left
	cmpi	mk1p_hold_lft,a0
	jrlt	mkh_pull_right
*
*  Inside the band: aim at the throw's own drift, signed the way he is
*  already going.  A fall that was never corrected is then asking for
*  exactly what it already has and nothing is written at all; one that was
*  eases out of the lean over twelve ticks instead of stopping dead, and
*  keeps 1px a tick of drift the rest of the way down.
*
	move	a2,a1
	abs	a1
	cmpi	mk1p_throw_vel,a1
	jrle	mkh_sign		; already at or under it
	movi	mk1p_throw_vel,a1
mkh_sign
	move	a2,a2
	jrnn	mkh_step
	neg	a1
	jruc	mkh_step

*
*  Outside the band - but the camera gets first refusal.  worldtlx short of
*  right_edge means mk1p_fall_scroll still has stage to pan into, so leave
*  his velocity completely alone and let the view follow him out.  Only a
*  camera already parked on the limit hands the job back here.
*
mkh_pull_left
	move	@right_edge,a1,w
	move	@worldtlx+16,a3,w
	cmp	a1,a3
	jrlt	mkh9			; room left ---> the camera takes it
	movi	-mk1p_steer_max,a1
	jruc	mkh_step
mkh_pull_right
	move	@left_edge,a1,w
	move	@worldtlx+16,a3,w
	cmp	a1,a3
	jrgt	mkh9			; room left ---> the camera takes it
	movi	mk1p_steer_max,a1
*
*  One step of mk1p_steer_acc towards a1, and never past it.
*
mkh_step
	move	a1,a3
	sub	a2,a3			; a3 = how far off the target he is
	jreq	mkh9			; on it - leave him alone entirely
	jrn	mkh_step_down
	cmpi	mk1p_steer_acc,a3
	jrle	mkh_set			; last step - land exactly on a1
	move	a2,a1
	addi	mk1p_steer_acc,a1
	jruc	mkh_set
mkh_step_down
	cmpi	-mk1p_steer_acc,a3
	jrge	mkh_set
	move	a2,a1
	subi	mk1p_steer_acc,a1

mkh_set	move	a1,*a8(oxvel),l
	move	a1,a0
	calla	set_x_vel		; stuff_velocities copies p?_xvel onto
mkh9	mmfm	sp,a0,a1,a2,a3		;   oxvel every tick even with repell
	rets				;   disabled, so the request has to move too

*
*  mk1p_fall_scroll - the scroller for the length of the fall.
*
*  VERTICAL is YOTEIGAI TOR's peak_fall_scroll with this stage's numbers:
*  chase him down once he is 060h rows into the screen, clamp at
*  mk1p_fall_cam BEFORE the chase (terminal velocity overshoots a test made
*  after), and settle onto the clamp at 4px a tick once he has stopped.
*
*  HORIZONTAL is the Pit II's own fall, pit_scroll (BGND.ASM), line for
*  line: centre on the falling body with a 6px deadzone, one table step of
*  scroll a tick, and stop dead at the stage's scroll limits.  YOTEIGAI TOR
*  does not need it - its stage fatality aims the body at one fixed target
*  and the camera is meant to sit still over it - and this was written from
*  that one, so it inherited a stop_scrolling that was never taken back.
*  Locked x is only ever RIGHT at a scroll limit.  Anywhere else it fights
*  mk1p_hold_on_screen: the body is thrown out over a view that cannot
*  follow, reaches the edge of the band, and gets leaned back in - which
*  from mid-bridge reads as the body bouncing off the side of the screen
*  instead of the screen opening out ahead of it.  So the camera goes
*  first and the lean is the fallback (see its header).
*
*  a11 = the falling object, passed in through pa11.
*
mk1p_cam_dead	.set	6		; pit_scroll's own deadzone, in px
mk1p_fall_scroll
	calla	stop_scrolling
	clr	a0
	move	a0,@scrolly,l
*
*  The background updater streams blocks every 8 ticks (background, BGND.ASM).
*  At ~27 rows a tick the camera outruns that by ~200 rows and the pit's own
*  modules arrive late - a band of sky shows under the shaft wall for a few
*  frames.  pit_scroll has always turned it up to every tick for the Pit II's
*  fall; this one needs it for the same reason.
*
	clr	a1
	not	a1
	movi	pid_backg,a0
	calla	existp
	jrz	mkfs1			; no updater ?  nothing to speed up
	movk	1,a1
	move	a1,*a0(pa10),l		; background updater = every tick

mkfs1	sleep	1
*
*  x - centre on him while the stage has anything left to show that way.
*  a5 carries the speed routine so that the "no room" answer and the
*  "already centred" answer cost nothing extra, as in pit_scroll.
*
	move	*a11(oxpos),a0,w
	move	@worldtlx+16,a1,w
	addi	scrrgt/2,a1		; a1 = world x of the middle of the screen

	movi	stop_scrolling,a5

	move	a0,a3
	sub	a1,a3
	abs	a3
	cmpi	mk1p_cam_dead,a3
	jrlo	mkfs_xgo		; centred ---> hold the view still

	cmp	a1,a0
	jrhi	mkfs_xright
	jrlo	mkfs_xleft
mkfs_xgo
	call	a5
*
*  y
*
	move	@worldtly,a1,l
	movi	mk1p_fall_cam*010000h,a2
	cmp	a2,a1
	jrlt	mkfs2			; still above the floor
	move	a2,@worldtly,l		; pin it to the bottom of the pit
	clr	a0
	move	a0,@scrolly,l
	jruc	mkfs1

mkfs2	move	*a11(oyvel),a6,l
	jrn	mkfs3			; heading up ---> dont scroll y
	jrz	mkfs_settle		; stopped falling - close the last rows

	move	*a11(oypos),a0,w
	move	@worldtly+16,a1,w
	sub	a1,a0
	cmpi	060h,a0
	jrlt	mkfs3			; not far enough down the screen yet

	move	a6,@scrolly,l		; follow him down the shaft
	jruc	mkfs1

mkfs_settle
	move	*a11(oypos),a0,w
	cmpi	mk1p_ground+200,a0
	jrlt	mkfs3			; still up top - he has not been thrown yet
	movi	mk1p_settle_vel,a0
	move	a0,@scrolly,l
	jruc	mkfs1

mkfs3	clr	a0
	move	a0,@scrolly,l
	jruc	mkfs1

*
*  The two x answers.  a5 is still stop_scrolling on the way in, so a stage
*  that has run out simply falls through to it and the view locks - which
*  is the one case mk1p_hold_on_screen is there for.
*
mkfs_xright
	move	@right_edge,a3,w
	move	@worldtlx+16,a1,w
	cmp	a3,a1
	jrge	mkfs_xgo		; too far right ---> no scroll
	movi	ss_20000,a5
	jruc	mkfs_xgo

mkfs_xleft
	move	@left_edge,a3,w
	move	@worldtlx+16,a1,w
	cmp	a3,a1
	jrle	mkfs_xgo		; too far left ---> no scroll
	movi	ss_20000_neg,a5
	jruc	mkfs_xgo

	.end
