**************************************************************************
*                                                                        *
*  video game project:  Mortal Kombat 2                                  *
*                                                                        *
*  module: Raiden's lift fatality - the victim scripts and pose tables    *
*                                                                        *
**************************************************************************
*
*  SPLIT OUT OF MKDEATH.ASM (2026-09-28) BECAUSE IT RAN GSPA OUT OF MEMORY.
*  This is 800-odd lines of pure DATA - one script entry per step for the
*  default project and each of the nine victim families, plus the per-ochar
*  pose tables - and MKDEATH is the module sitting closest to the assembler's
*  ceiling.  Lengthening the electrocution loop by two passes (LOOP_EXTRA
*  3 -> 5) added ~200 lines and aborted it with ">> Out of memory" on PASS 2.
*  Every row here is GENERATED; the code that walks it stays in MKDEATH.
*
*  It needs nothing of its own: all 80 art labels the tables name are already
*  .global in MAINEQU.ASM, so including that is the whole import list.
*
	.file	"mkrdlif.asm"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	dispequ.asm
	.include	sysequ.asm
	.include	macros.hdr
	.include	mainequ.asm

	.globl	rd_lift_vic_scripts
	.globl	rd_lift_buzz
	.ref	player_shock_buzz_pal	; MKGUYS.ASM
	.ref	shock_next_lift_beat	; MKGUYS.ASM

*
*  THE X-RAY FLASHES - each fighter's skeleton in the current, out of
*  MKSHOCK.IMG: Liu Kang's in data/LUBUZZ.LOD (bank 0), the other twelve in
*  data/XRAY1-9.LOD (XRAY5 in bank 0, the rest bank 1).  One-piece wrappers, so a family script names
*  them as his frame like any other (tools/raiden_lift_wax_import.py finds a
*  wrapper by its one piece).  Generated scripts set flag bit 8 on every
*  step that draws one.
*
	.include	lubuzz.tbl
	.include	xray1.tbl
	.include	xray2.tbl
	.include	xray3.tbl
	.include	xray4.tbl
	.include	xray5.tbl
	.include	xray6.tbl
	.include	xray7.tbl
	.include	xray8.tbl
	.include	xray9.tbl
	.globl	LUBUZZ2W,KLBUZZ2W,SZBUZZ2W,KNBUZZ2W
	.globl	LIBUZZ2W,SBBUZZ2W,TSBUZZ2W,RDBUZZ2W
LUBUZZ2W	.long	LUBUZZ2,0	; Liu Kang
KLBUZZ2W	.long	KLBUZZ2,0	; Kung Lao, hat and all
SZBUZZ2W	.long	SZBUZZ2,0	; Johnny Cage's project
KNBUZZ2W	.long	KNBUZZ2,0	; Baraka's, the ninjas', Jax's
LIBUZZ2W	.long	LIBUZZ2,0	; the Kitana family's
SBBUZZ2W	.long	SBBUZZ2,0	; ...and their second one
TSBUZZ2W	.long	TSBUZZ2,0	; Shang Tsung's
RDBUZZ2W	.long	RDBUZZ2,0	; Raiden's
;  The other five - packed so every X-ray in MKSHOCK.IMG is in the ROM; no
;  WAX names them yet (data/XRAY5-9.LOD).
	.globl	JXBUZZ2W,SGBUZZ2W,INBUZZ2W,OBBUZZ2W,TRBUZZ2W
JXBUZZ2W	.long	JXBUZZ2,0
SGBUZZ2W	.long	SGBUZZ2,0
INBUZZ2W	.long	INBUZZ2,0
OBBUZZ2W	.long	OBBUZZ2,0
TRBUZZ2W	.long	TRBUZZ2,0

	.text

*
*  rd_lift_buzz - EVERY STEP'S SHOCK PALETTE, painted on the tick the pose
*  and the bolt change.  Bit 8 of the entry = his X-RAY FLASH.
*
*  ONE PAINTER, ON THE STEP CLOCK (the user's, 2026-10-04: "make sure all the
*  ticks of the electricity and the shock animation line up").  The victim's
*  own process used to flicker the electrocution cycle on ITS clock, which
*  ran exactly one tick behind Raiden's: measured, the bolt and pose changed
*  on 1805, 1809, 1813... and his palette on 1806, 1810, 1814..., and round an
*  X-ray step both processes painted, a one-tick blip of one beat before the
*  other.  So rd_lifted_victim (MKDEATH.ASM) no longer paints at all, and this
*  steps the cycle once per step - a beat a pose.
*
*  The X-rays are drawn in NONE of his palettes: MKSHOCK.IMG draws them in
*  BUZBLUE, BUZRED and BUZZER, and which one is Raiden's costume - the same
*  pairing as the bolt and the ELEC beat (player_shock_buzz_pal, MKGUYS.ASM).
*  So on a bit-8 step he is swapped onto that palette, and his own process
*  (rd_lifted_victim, MKDEATH.ASM), which flickers the electrocution cycle
*  every 4 ticks, is told to stand aside through its p_store1 - otherwise it
*  would repaint the skeleton in FREZ/ELEC/WHITE/BLACK, palettes laid out for
*  his COSTUME art.
*
*  HIS SHADOW GOES OFF FOR THE FLASH.  Seven of the eight X-rays are in BANK 1
*  (no bank-0 run holds them), and shadow_p1p2 walks a body frame with a CPU
*  read that has no video bank select - a bank-1 frame shreds the shadow.  He
*  hangs with the camera raised, so it is off screen on most stages anyway;
*  on one whose camera does not climb (THE TOWER) this is a short blink
*  instead of a smear.  p_store1: bit 0 = flashing, bit 1 = he HAD a shadow,
*  so only a shadow that was there is given back (rd_lift_unshadow).
*

*  Runs in RAIDEN's process (rd_lift_pose_victim): a8 = victim, a9 = the
*  entry, a13 = Raiden's process.  Trashes a0-a2.
*
rd_lift_buzz
	move	*a13(p_otherproc),a2,l	; a2 = the victim's process
	move	*a9(64),a0,w
	btst	8,a0
	jreq	rlb_beat
	move	*a2(p_store1),a0,w
	jrne	rlb_on			; already flashing - shadow already off
	movk	1,a0
	move	*a8(oflags2),a1,w
	btst	b_shadow,a1
	jreq	rlb_noshad
	movk	3,a0			; bit 1: give it back afterwards
	andni	m_shadow,a1
	move	a1,*a8(oflags2),w
rlb_noshad
	move	a0,*a2(p_store1),w	; flashing (bit 1: had a shadow)
rlb_on
	movi	player_shock_buzz_pal,a1
	jruc	rlb_paint
rlb_beat
	move	*a2(p_store1),a0,w
	jreq	rlb_next		; no flash to end
	callr	rd_lift_unshadow
rlb_next
*
*  ELEC, FREZ, WHITE, his own colours - no solid black up here (see
*  shock_next_lift_beat, MKGUYS).  An X-ray tick does not step the phase, so
*  the rotation resumes on the beat it was due after the skeleton.
*
	calla	shock_next_lift_beat	; a1 = the cycle's next beat
rlb_paint
	mmtm	sp,a3,a4,a5,a6,a7,a8,a9,a10,a11,a13	; player_normpal (the 4th
					; beat) runs the whole costume resolver
	move	a2,a13			; as him - zappal_change's swap
	call	a1
	mmfm	sp,a3,a4,a5,a6,a7,a8,a9,a10,a11,a13
	rets

*
*  rd_lift_unshadow - end a flash: his shadow back if he had one, p_store1
*  clear.  Also called by rd_lift_upright (MKDEATH.ASM) on BOTH ways out of
*  the fatality, so a fizzle in the middle of a flash cannot leave him
*  without a shadow for the rest of the round (rd_cacell_victum puts his
*  palette back itself).  a8 = victim, a13 = Raiden's process.  Trashes a0-a2.
*
	.globl	rd_lift_unshadow
rd_lift_unshadow
	move	*a13(p_otherproc),a2,l
	move	*a2(p_store1),a0,w
	btst	1,a0
	jreq	rlu_clear
	move	*a8(oflags2),a1,w
	ori	m_shadow,a1
	move	a1,*a8(oflags2),w
rlu_clear
	clr	a0
	move	a0,*a2(p_store1),w
	rets


; GENERATED by tools/raiden_lift_wax_import.py from data/RAIDELEC*.WAX - re-run
; it after editing a WAX instead of editing these rows.
;
; rd_lift_vic_scripts - the victim script for each ochar: his family's project
; if he has one, otherwise the default (data/RAIDELEC.WAX, authored on Liu Kang).
;
; One script entry per step: .long frame, .word X, Y, flags, hold in ticks.
; flags: bit 0 = mirrored, bit 1 = start the smoke (rd_lift_smoke),
;        bit 2 = he screams (disturbing_scream, off by default),
;        bit 3 = his death voice (rsnd_death_voice) - do_raiden_shocker's,
;        bit 4 = the long IS his frame (a family project), else a per-fighter pose
;        table get_char_long picks his frame from (the default project).
;        bit 5 = check the Up + HP mash when this step ends (rd_lift_mash_ok).
;        bit 6 = drawn upside down (flip_multi_v) - RAIDELECLIUFRONT hangs him.
;        bit 7 = re-send the super zap (tsound 0c7h), as do_raiden_fry does.
;        bit 8 = his X-RAY (an MKSHOCK.IMG frame): rd_lift_buzz puts him on the
;        BUZ palette Raiden's costume names and holds the shock flicker off.
; X/Y are already Raiden-facing anchor offsets (see rd_lift_pose_victim); the
; comment keeps the raw WAX numbers.  A 0 long ends a script.
rd_lift_vic_scripts
	.long	rd_lift_vic_script_tm	;  0 - kung lao
	.long	rd_lift_vic_script_lk	;  1 - liu kang
	.long	rd_lift_vic_script_jc	;  2 - johnny cage
	.long	rd_lift_vic_script_ug	;  3 - baraka
	.long	rd_lift_vic_script_kt	;  4 - kitana
	.long	rd_lift_vic_script_kt	;  5 - mileena
	.long	rd_lift_vic_script_st	;  6 - shang tsung
	.long	rd_lift_vic_script_rn	;  7 - raiden
	.long	rd_lift_vic_script_nj	;  8 - sub-zero
	.long	rd_lift_vic_script_nj	;  9 - reptile
	.long	rd_lift_vic_script_nj	; 10 - scorpion
	.long	rd_lift_vic_script_jx	; 11 - jax
	.long	rd_lift_vic_script_nj	; 12 - kintaro
	.long	rd_lift_vic_script_nj	; 13 - shao kahn
	.long	rd_lift_vic_script_nj	; 14 - smoke
	.long	rd_lift_vic_script_nj	; 15 - noob saibot
	.long	rd_lift_vic_script_kt	; 16 - jade
	.long	rd_lift_vic_script_nj	; 17 - ermac
	.long	rd_lift_vic_script_kt	; 18 - khameleon
	.long	rd_lift_vic_script_nj	; 19 - rain
	.if	wunit	; WOLF FIGHTERS
	.ref	kn_rd_lift_script
	.long	rd_lift_vic_script_kt,rd_lift_vic_script_kt,kn_rd_lift_script,rd_lift_vic_script_lk,rd_lift_vic_script_nj	; 20 sonya=4, 21 sindel=4, 22 kano, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS

; data/RAIDELEC.WAX (victim slot 3) - everyone without a family of their own
rd_lift_vic_script
	.long	rd_lift_stumble1_tbl
	.word	78,-44,9,4		; step  1  WAX 0  dA  78, 44  mirrored DEATH
	.long	rd_lift_flipped2_tbl
	.word	79,-57,1,4		; step  2  WAX 1  dA  79, 57  mirrored
	.long	rd_lift_flipped2_tbl
	.word	61,-77,1,4		; step  3  WAX 2  dA  61, 77  mirrored
	.long	rd_lift_bb3_tbl
	.word	26,-140,0,4		; step  4  WAX 3  dA -26,140
	.long	rd_lift_kd7_tbl
	.word	-3,-180,130,4		; step  5  WAX 4  dA   3,180  SMOKE ZAP
	.long	rd_lift_bb3_tbl
	.word	-3,-130,0,4		; step  6  WAX 5  dA   3,130
	.long	rd_lift_kd7_tbl
	.word	-2,-181,0,4		; step  7  WAX 6  dA   2,181
	.long	rd_lift_bb3_tbl
	.word	-2,-139,0,4		; step  8  WAX 7  dA   2,139
	.long	rd_lift_kd7_tbl
	.word	-6,-181,0,4		; step  9  WAX 8  dA   6,181
	.long	rd_lift_kd7_tbl
	.word	-3,-180,128,4		; step 10  WAX 4  dA   3,180  ZAP loop 1
	.long	rd_lift_bb3_tbl
	.word	-3,-130,0,4		; step 11  WAX 5  dA   3,130  loop 1
	.long	rd_lift_kd7_tbl
	.word	-2,-181,0,4		; step 12  WAX 6  dA   2,181  loop 1
	.long	rd_lift_bb3_tbl
	.word	-2,-139,0,4		; step 13  WAX 7  dA   2,139  loop 1
	.long	rd_lift_kd7_tbl
	.word	-6,-181,0,4		; step 14  WAX 8  dA   6,181  loop 1
	.long	rd_lift_kd7_tbl
	.word	-3,-180,160,4		; step 15  WAX 4  dA   3,180  ZAP MASH loop 2
	.long	rd_lift_bb3_tbl
	.word	-3,-130,0,4		; step 16  WAX 5  dA   3,130  loop 2
	.long	rd_lift_kd7_tbl
	.word	-2,-181,0,4		; step 17  WAX 6  dA   2,181  loop 2
	.long	rd_lift_bb3_tbl
	.word	-2,-139,0,4		; step 18  WAX 7  dA   2,139  loop 2
	.long	rd_lift_kd7_tbl
	.word	-6,-181,0,4		; step 19  WAX 8  dA   6,181  loop 2
	.long	rd_lift_kd7_tbl
	.word	-3,-180,160,4		; step 20  WAX 4  dA   3,180  ZAP MASH loop 3
	.long	rd_lift_bb3_tbl
	.word	-3,-130,0,4		; step 21  WAX 5  dA   3,130  loop 3
	.long	rd_lift_kd7_tbl
	.word	-2,-181,0,4		; step 22  WAX 6  dA   2,181  loop 3
	.long	rd_lift_bb3_tbl
	.word	-2,-139,0,4		; step 23  WAX 7  dA   2,139  loop 3
	.long	rd_lift_kd7_tbl
	.word	-6,-181,0,4		; step 24  WAX 8  dA   6,181  loop 3
	.long	rd_lift_kd7_tbl
	.word	-3,-180,160,4		; step 25  WAX 4  dA   3,180  ZAP MASH loop 4
	.long	rd_lift_bb3_tbl
	.word	-3,-130,0,4		; step 26  WAX 5  dA   3,130  loop 4
	.long	rd_lift_kd7_tbl
	.word	-2,-181,0,4		; step 27  WAX 6  dA   2,181  loop 4
	.long	rd_lift_bb3_tbl
	.word	-2,-139,0,4		; step 28  WAX 7  dA   2,139  loop 4
	.long	rd_lift_kd7_tbl
	.word	-6,-181,0,4		; step 29  WAX 8  dA   6,181  loop 4
	.long	rd_lift_kd7_tbl
	.word	-3,-180,160,4		; step 30  WAX 4  dA   3,180  ZAP MASH loop 5
	.long	rd_lift_bb3_tbl
	.word	-3,-130,0,4		; step 31  WAX 5  dA   3,130  loop 5
	.long	rd_lift_kd7_tbl
	.word	-2,-181,0,4		; step 32  WAX 6  dA   2,181  loop 5
	.long	rd_lift_bb3_tbl
	.word	-2,-139,0,4		; step 33  WAX 7  dA   2,139  loop 5
	.long	rd_lift_kd7_tbl
	.word	-6,-181,0,4		; step 34  WAX 8  dA   6,181  loop 5
	.long	rd_lift_kd7_tbl
	.word	0,-181,32,4		; step 35  WAX 9  dA   0,181  MASH
	.long	rd_lift_kd7_tbl
	.word	5,-179,0,4		; step 36  WAX 10 dA  -5,179
	.long	0

; data/RAIDELECLAO.WAX (victim slot 4) - kung lao
rd_lift_vic_script_tm
	.long	TMSTUMBLE1
	.word	75,-36,25,4		; step  1  WAX 0  dA  75, 36  mirrored DEATH
	.long	HHDRAIN0
	.word	77,-32,17,4		; step  2  WAX 1  dA  77, 32  mirrored
	.long	TMFLIPPED1
	.word	49,-63,17,4		; step  3  WAX 2  dA  49, 63  mirrored
	.long	TMFLIPPED5
	.word	37,32,80,4		; step  4  WAX 3  dA -37, 32  UPSIDEDOWN
	.long	TMKNOCKDOWN6
	.word	-10,78,210,4		; step  5  WAX 4  dA  10, 78  UPSIDEDOWN SMOKE ZAP
	.long	TMKNOCKDOWN5
	.word	-11,70,80,4		; step  6  WAX 5  dA  11, 70  UPSIDEDOWN
	.long	TMKNOCKDOWN7
	.word	-20,87,80,4		; step  7  WAX 6  dA  20, 87  UPSIDEDOWN
	.long	KLBUZZ2W
	.word	-24,-76,272,4		; step  8  WAX 7  dA  24, 76  XRAY
	.long	TMKNOCKDOWN7
	.word	-18,89,80,4		; step  9  WAX 8  dA  18, 89  UPSIDEDOWN
	.long	TMKNOCKDOWN6
	.word	-10,78,208,4		; step 10  WAX 4  dA  10, 78  UPSIDEDOWN ZAP loop 1
	.long	TMKNOCKDOWN5
	.word	-11,70,80,4		; step 11  WAX 5  dA  11, 70  UPSIDEDOWN loop 1
	.long	TMKNOCKDOWN7
	.word	-20,87,80,4		; step 12  WAX 6  dA  20, 87  UPSIDEDOWN loop 1
	.long	KLBUZZ2W
	.word	-24,-76,272,4		; step 13  WAX 7  dA  24, 76  XRAY loop 1
	.long	TMKNOCKDOWN7
	.word	-18,89,80,4		; step 14  WAX 8  dA  18, 89  UPSIDEDOWN loop 1
	.long	TMKNOCKDOWN6
	.word	-10,78,240,4		; step 15  WAX 4  dA  10, 78  UPSIDEDOWN ZAP MASH loop 2
	.long	TMKNOCKDOWN5
	.word	-11,70,80,4		; step 16  WAX 5  dA  11, 70  UPSIDEDOWN loop 2
	.long	TMKNOCKDOWN7
	.word	-20,87,80,4		; step 17  WAX 6  dA  20, 87  UPSIDEDOWN loop 2
	.long	KLBUZZ2W
	.word	-24,-76,272,4		; step 18  WAX 7  dA  24, 76  XRAY loop 2
	.long	TMKNOCKDOWN7
	.word	-18,89,80,4		; step 19  WAX 8  dA  18, 89  UPSIDEDOWN loop 2
	.long	TMKNOCKDOWN6
	.word	-10,78,240,4		; step 20  WAX 4  dA  10, 78  UPSIDEDOWN ZAP MASH loop 3
	.long	TMKNOCKDOWN5
	.word	-11,70,80,4		; step 21  WAX 5  dA  11, 70  UPSIDEDOWN loop 3
	.long	TMKNOCKDOWN7
	.word	-20,87,80,4		; step 22  WAX 6  dA  20, 87  UPSIDEDOWN loop 3
	.long	KLBUZZ2W
	.word	-24,-76,272,4		; step 23  WAX 7  dA  24, 76  XRAY loop 3
	.long	TMKNOCKDOWN7
	.word	-18,89,80,4		; step 24  WAX 8  dA  18, 89  UPSIDEDOWN loop 3
	.long	TMKNOCKDOWN6
	.word	-10,78,240,4		; step 25  WAX 4  dA  10, 78  UPSIDEDOWN ZAP MASH loop 4
	.long	TMKNOCKDOWN5
	.word	-11,70,80,4		; step 26  WAX 5  dA  11, 70  UPSIDEDOWN loop 4
	.long	TMKNOCKDOWN7
	.word	-20,87,80,4		; step 27  WAX 6  dA  20, 87  UPSIDEDOWN loop 4
	.long	KLBUZZ2W
	.word	-24,-76,272,4		; step 28  WAX 7  dA  24, 76  XRAY loop 4
	.long	TMKNOCKDOWN7
	.word	-18,89,80,4		; step 29  WAX 8  dA  18, 89  UPSIDEDOWN loop 4
	.long	TMKNOCKDOWN6
	.word	-10,78,240,4		; step 30  WAX 4  dA  10, 78  UPSIDEDOWN ZAP MASH loop 5
	.long	TMKNOCKDOWN5
	.word	-11,70,80,4		; step 31  WAX 5  dA  11, 70  UPSIDEDOWN loop 5
	.long	TMKNOCKDOWN7
	.word	-20,87,80,4		; step 32  WAX 6  dA  20, 87  UPSIDEDOWN loop 5
	.long	KLBUZZ2W
	.word	-24,-76,272,4		; step 33  WAX 7  dA  24, 76  XRAY loop 5
	.long	TMKNOCKDOWN7
	.word	-18,89,80,4		; step 34  WAX 8  dA  18, 89  UPSIDEDOWN loop 5
	.long	TMBACKBREAK2
	.word	-12,32,112,4		; step 35  WAX 9  dA  12, 32  UPSIDEDOWN MASH
	.long	TMKNOCKDOWN7
	.word	-17,93,80,4		; step 36  WAX 10 dA  17, 93  UPSIDEDOWN
	.long	0

; data/RAIDELECLIUFRONT.WAX (victim slot 3) - liu kang
rd_lift_vic_script_lk
	.long	LKSTUMBLE1
	.word	78,-44,25,4		; step  1  WAX 0  dA  78, 44  mirrored DEATH
	.long	LKDRAIN0
	.word	85,-39,17,4		; step  2  WAX 1  dA  85, 39  mirrored
	.long	LKFLIPPED2
	.word	54,-70,17,4		; step  3  WAX 2  dA  54, 70  mirrored
	.long	LKBACKBREAK2
	.word	34,7,80,4		; step  4  WAX 3  dA -34,  7  UPSIDEDOWN
	.long	LUBUZZ2W
	.word	-14,-57,402,4		; step  5  WAX 4  dA  14, 57  XRAY SMOKE ZAP
	.long	LKBACKBREAK3
	.word	-11,42,80,4		; step  6  WAX 5  dA  11, 42  UPSIDEDOWN
	.long	LKKNOCKDOWN7
	.word	-1,79,80,4		; step  7  WAX 6  dA   1, 79  UPSIDEDOWN
	.long	LKBACKBREAK3
	.word	-15,32,80,4		; step  8  WAX 7  dA  15, 32  UPSIDEDOWN
	.long	LUBUZZ2W
	.word	-16,-63,272,4		; step  9  WAX 8  dA  16, 63  XRAY
	.long	LUBUZZ2W
	.word	-14,-57,400,4		; step 10  WAX 4  dA  14, 57  XRAY ZAP loop 1
	.long	LKBACKBREAK3
	.word	-11,42,80,4		; step 11  WAX 5  dA  11, 42  UPSIDEDOWN loop 1
	.long	LKKNOCKDOWN7
	.word	-1,79,80,4		; step 12  WAX 6  dA   1, 79  UPSIDEDOWN loop 1
	.long	LKBACKBREAK3
	.word	-15,32,80,4		; step 13  WAX 7  dA  15, 32  UPSIDEDOWN loop 1
	.long	LUBUZZ2W
	.word	-16,-63,272,4		; step 14  WAX 8  dA  16, 63  XRAY loop 1
	.long	LUBUZZ2W
	.word	-14,-57,432,4		; step 15  WAX 4  dA  14, 57  XRAY ZAP MASH loop 2
	.long	LKBACKBREAK3
	.word	-11,42,80,4		; step 16  WAX 5  dA  11, 42  UPSIDEDOWN loop 2
	.long	LKKNOCKDOWN7
	.word	-1,79,80,4		; step 17  WAX 6  dA   1, 79  UPSIDEDOWN loop 2
	.long	LKBACKBREAK3
	.word	-15,32,80,4		; step 18  WAX 7  dA  15, 32  UPSIDEDOWN loop 2
	.long	LUBUZZ2W
	.word	-16,-63,272,4		; step 19  WAX 8  dA  16, 63  XRAY loop 2
	.long	LUBUZZ2W
	.word	-14,-57,432,4		; step 20  WAX 4  dA  14, 57  XRAY ZAP MASH loop 3
	.long	LKBACKBREAK3
	.word	-11,42,80,4		; step 21  WAX 5  dA  11, 42  UPSIDEDOWN loop 3
	.long	LKKNOCKDOWN7
	.word	-1,79,80,4		; step 22  WAX 6  dA   1, 79  UPSIDEDOWN loop 3
	.long	LKBACKBREAK3
	.word	-15,32,80,4		; step 23  WAX 7  dA  15, 32  UPSIDEDOWN loop 3
	.long	LUBUZZ2W
	.word	-16,-63,272,4		; step 24  WAX 8  dA  16, 63  XRAY loop 3
	.long	LUBUZZ2W
	.word	-14,-57,432,4		; step 25  WAX 4  dA  14, 57  XRAY ZAP MASH loop 4
	.long	LKBACKBREAK3
	.word	-11,42,80,4		; step 26  WAX 5  dA  11, 42  UPSIDEDOWN loop 4
	.long	LKKNOCKDOWN7
	.word	-1,79,80,4		; step 27  WAX 6  dA   1, 79  UPSIDEDOWN loop 4
	.long	LKBACKBREAK3
	.word	-15,32,80,4		; step 28  WAX 7  dA  15, 32  UPSIDEDOWN loop 4
	.long	LUBUZZ2W
	.word	-16,-63,272,4		; step 29  WAX 8  dA  16, 63  XRAY loop 4
	.long	LUBUZZ2W
	.word	-14,-57,432,4		; step 30  WAX 4  dA  14, 57  XRAY ZAP MASH loop 5
	.long	LKBACKBREAK3
	.word	-11,42,80,4		; step 31  WAX 5  dA  11, 42  UPSIDEDOWN loop 5
	.long	LKKNOCKDOWN7
	.word	-1,79,80,4		; step 32  WAX 6  dA   1, 79  UPSIDEDOWN loop 5
	.long	LKBACKBREAK3
	.word	-15,32,80,4		; step 33  WAX 7  dA  15, 32  UPSIDEDOWN loop 5
	.long	LUBUZZ2W
	.word	-16,-63,272,4		; step 34  WAX 8  dA  16, 63  XRAY loop 5
	.long	LKBACKBREAK3
	.word	-4,37,112,4		; step 35  WAX 9  dA   4, 37  UPSIDEDOWN MASH
	.long	LKKNOCKDOWN7
	.word	-3,84,80,4		; step 36  WAX 10 dA   3, 84  UPSIDEDOWN
	.long	0

; data/RAIDELECCAGE.WAX (victim slot 3) - johnny cage
rd_lift_vic_script_jc
	.long	JCSTUMBLE1
	.word	74,-41,25,4		; step  1  WAX 0  dA  74, 41  mirrored DEATH
	.long	JCFLIPPED1
	.word	63,-64,17,4		; step  2  WAX 1  dA  63, 64  mirrored
	.long	JCKNOCKDOWN6
	.word	49,102,80,4		; step  3  WAX 2  dA -49,102  UPSIDEDOWN
	.long	JCBACKBREAK2
	.word	20,23,80,4		; step  4  WAX 3  dA -20, 23  UPSIDEDOWN
	.long	SZBUZZ2W
	.word	2,-58,402,4		; step  5  WAX 4  dA  -2, 58  XRAY SMOKE ZAP
	.long	JCBACKBREAK2
	.word	-16,33,80,4		; step  6  WAX 5  dA  16, 33  UPSIDEDOWN
	.long	JCKNOCKDOWN7
	.word	-19,76,80,4		; step  7  WAX 6  dA  19, 76  UPSIDEDOWN
	.long	JCBACKBREAK3
	.word	1,40,80,4		; step  8  WAX 7  dA  -1, 40  UPSIDEDOWN
	.long	JCBACKBREAK2
	.word	-14,24,80,4		; step  9  WAX 8  dA  14, 24  UPSIDEDOWN
	.long	SZBUZZ2W
	.word	2,-58,400,4		; step 10  WAX 4  dA  -2, 58  XRAY ZAP loop 1
	.long	JCBACKBREAK2
	.word	-16,33,80,4		; step 11  WAX 5  dA  16, 33  UPSIDEDOWN loop 1
	.long	JCKNOCKDOWN7
	.word	-19,76,80,4		; step 12  WAX 6  dA  19, 76  UPSIDEDOWN loop 1
	.long	JCBACKBREAK3
	.word	1,40,80,4		; step 13  WAX 7  dA  -1, 40  UPSIDEDOWN loop 1
	.long	JCBACKBREAK2
	.word	-14,24,80,4		; step 14  WAX 8  dA  14, 24  UPSIDEDOWN loop 1
	.long	SZBUZZ2W
	.word	2,-58,432,4		; step 15  WAX 4  dA  -2, 58  XRAY ZAP MASH loop 2
	.long	JCBACKBREAK2
	.word	-16,33,80,4		; step 16  WAX 5  dA  16, 33  UPSIDEDOWN loop 2
	.long	JCKNOCKDOWN7
	.word	-19,76,80,4		; step 17  WAX 6  dA  19, 76  UPSIDEDOWN loop 2
	.long	JCBACKBREAK3
	.word	1,40,80,4		; step 18  WAX 7  dA  -1, 40  UPSIDEDOWN loop 2
	.long	JCBACKBREAK2
	.word	-14,24,80,4		; step 19  WAX 8  dA  14, 24  UPSIDEDOWN loop 2
	.long	SZBUZZ2W
	.word	2,-58,432,4		; step 20  WAX 4  dA  -2, 58  XRAY ZAP MASH loop 3
	.long	JCBACKBREAK2
	.word	-16,33,80,4		; step 21  WAX 5  dA  16, 33  UPSIDEDOWN loop 3
	.long	JCKNOCKDOWN7
	.word	-19,76,80,4		; step 22  WAX 6  dA  19, 76  UPSIDEDOWN loop 3
	.long	JCBACKBREAK3
	.word	1,40,80,4		; step 23  WAX 7  dA  -1, 40  UPSIDEDOWN loop 3
	.long	JCBACKBREAK2
	.word	-14,24,80,4		; step 24  WAX 8  dA  14, 24  UPSIDEDOWN loop 3
	.long	SZBUZZ2W
	.word	2,-58,432,4		; step 25  WAX 4  dA  -2, 58  XRAY ZAP MASH loop 4
	.long	JCBACKBREAK2
	.word	-16,33,80,4		; step 26  WAX 5  dA  16, 33  UPSIDEDOWN loop 4
	.long	JCKNOCKDOWN7
	.word	-19,76,80,4		; step 27  WAX 6  dA  19, 76  UPSIDEDOWN loop 4
	.long	JCBACKBREAK3
	.word	1,40,80,4		; step 28  WAX 7  dA  -1, 40  UPSIDEDOWN loop 4
	.long	JCBACKBREAK2
	.word	-14,24,80,4		; step 29  WAX 8  dA  14, 24  UPSIDEDOWN loop 4
	.long	SZBUZZ2W
	.word	2,-58,432,4		; step 30  WAX 4  dA  -2, 58  XRAY ZAP MASH loop 5
	.long	JCBACKBREAK2
	.word	-16,33,80,4		; step 31  WAX 5  dA  16, 33  UPSIDEDOWN loop 5
	.long	JCKNOCKDOWN7
	.word	-19,76,80,4		; step 32  WAX 6  dA  19, 76  UPSIDEDOWN loop 5
	.long	JCBACKBREAK3
	.word	1,40,80,4		; step 33  WAX 7  dA  -1, 40  UPSIDEDOWN loop 5
	.long	JCBACKBREAK2
	.word	-14,24,80,4		; step 34  WAX 8  dA  14, 24  UPSIDEDOWN loop 5
	.long	SZBUZZ2W
	.word	1,-68,304,4		; step 35  WAX 9  dA  -1, 68  XRAY MASH
	.long	JCKNOCKDOWN7
	.word	-7,79,80,4		; step 36  WAX 10 dA   7, 79  UPSIDEDOWN
	.long	0

; data/RAIDELECUGMO.WAX (victim slot 4) - baraka
rd_lift_vic_script_ug
	.long	UGSTUMBL1E1
	.word	71,-25,25,4		; step  1  WAX 0  dA  71, 25  mirrored DEATH
	.long	SADRAIN0
	.word	85,-46,17,4		; step  2  WAX 1  dA  85, 46  mirrored
	.long	UGFLIPPED1
	.word	64,-77,17,4		; step  3  WAX 2  dA  64, 77  mirrored
	.long	UGBACKBREAK1
	.word	28,-3,80,4		; step  4  WAX 3  dA -28, -3  UPSIDEDOWN
	.long	UGBACKBREAK2
	.word	-7,15,210,4		; step  5  WAX 4  dA   7, 15  UPSIDEDOWN SMOKE ZAP
	.long	UGBACKBREAK3
	.word	1,28,80,4		; step  6  WAX 5  dA  -1, 28  UPSIDEDOWN
	.long	KNBUZZ2W
	.word	-18,-65,272,4		; step  7  WAX 6  dA  18, 65  XRAY
	.long	UGKNOCKDOWN6
	.word	-16,85,80,4		; step  8  WAX 7  dA  16, 85  UPSIDEDOWN
	.long	KNBUZZ2W
	.word	-16,-65,272,4		; step  9  WAX 8  dA  16, 65  XRAY
	.long	UGBACKBREAK2
	.word	-7,15,208,4		; step 10  WAX 4  dA   7, 15  UPSIDEDOWN ZAP loop 1
	.long	UGBACKBREAK3
	.word	1,28,80,4		; step 11  WAX 5  dA  -1, 28  UPSIDEDOWN loop 1
	.long	KNBUZZ2W
	.word	-18,-65,272,4		; step 12  WAX 6  dA  18, 65  XRAY loop 1
	.long	UGKNOCKDOWN6
	.word	-16,85,80,4		; step 13  WAX 7  dA  16, 85  UPSIDEDOWN loop 1
	.long	KNBUZZ2W
	.word	-16,-65,272,4		; step 14  WAX 8  dA  16, 65  XRAY loop 1
	.long	UGBACKBREAK2
	.word	-7,15,240,4		; step 15  WAX 4  dA   7, 15  UPSIDEDOWN ZAP MASH loop 2
	.long	UGBACKBREAK3
	.word	1,28,80,4		; step 16  WAX 5  dA  -1, 28  UPSIDEDOWN loop 2
	.long	KNBUZZ2W
	.word	-18,-65,272,4		; step 17  WAX 6  dA  18, 65  XRAY loop 2
	.long	UGKNOCKDOWN6
	.word	-16,85,80,4		; step 18  WAX 7  dA  16, 85  UPSIDEDOWN loop 2
	.long	KNBUZZ2W
	.word	-16,-65,272,4		; step 19  WAX 8  dA  16, 65  XRAY loop 2
	.long	UGBACKBREAK2
	.word	-7,15,240,4		; step 20  WAX 4  dA   7, 15  UPSIDEDOWN ZAP MASH loop 3
	.long	UGBACKBREAK3
	.word	1,28,80,4		; step 21  WAX 5  dA  -1, 28  UPSIDEDOWN loop 3
	.long	KNBUZZ2W
	.word	-18,-65,272,4		; step 22  WAX 6  dA  18, 65  XRAY loop 3
	.long	UGKNOCKDOWN6
	.word	-16,85,80,4		; step 23  WAX 7  dA  16, 85  UPSIDEDOWN loop 3
	.long	KNBUZZ2W
	.word	-16,-65,272,4		; step 24  WAX 8  dA  16, 65  XRAY loop 3
	.long	UGBACKBREAK2
	.word	-7,15,240,4		; step 25  WAX 4  dA   7, 15  UPSIDEDOWN ZAP MASH loop 4
	.long	UGBACKBREAK3
	.word	1,28,80,4		; step 26  WAX 5  dA  -1, 28  UPSIDEDOWN loop 4
	.long	KNBUZZ2W
	.word	-18,-65,272,4		; step 27  WAX 6  dA  18, 65  XRAY loop 4
	.long	UGKNOCKDOWN6
	.word	-16,85,80,4		; step 28  WAX 7  dA  16, 85  UPSIDEDOWN loop 4
	.long	KNBUZZ2W
	.word	-16,-65,272,4		; step 29  WAX 8  dA  16, 65  XRAY loop 4
	.long	UGBACKBREAK2
	.word	-7,15,240,4		; step 30  WAX 4  dA   7, 15  UPSIDEDOWN ZAP MASH loop 5
	.long	UGBACKBREAK3
	.word	1,28,80,4		; step 31  WAX 5  dA  -1, 28  UPSIDEDOWN loop 5
	.long	KNBUZZ2W
	.word	-18,-65,272,4		; step 32  WAX 6  dA  18, 65  XRAY loop 5
	.long	UGKNOCKDOWN6
	.word	-16,85,80,4		; step 33  WAX 7  dA  16, 85  UPSIDEDOWN loop 5
	.long	KNBUZZ2W
	.word	-16,-65,272,4		; step 34  WAX 8  dA  16, 65  XRAY loop 5
	.long	UGBACKBREAK2
	.word	-6,10,112,4		; step 35  WAX 9  dA   6, 10  UPSIDEDOWN MASH
	.long	UGKNOCKDOWN6
	.word	2,80,80,4		; step 36  WAX 10 dA  -2, 80  UPSIDEDOWN
	.long	0

; data/RAIDELECKAT.WAX (victim slot 4) - kitana, mileena, jade, khameleon
rd_lift_vic_script_kt
	.long	KTSTUMBLE1
	.word	81,-25,25,4		; step  1  WAX 0  dA  81, 25  mirrored DEATH
	.long	FNDRAIN0
	.word	89,-45,17,4		; step  2  WAX 1  dA  89, 45  mirrored
	.long	KTKNOCKDOWN4
	.word	55,69,80,4		; step  3  WAX 2  dA -55, 69  UPSIDEDOWN
	.long	KTBACKBREAK3
	.word	24,14,80,4		; step  4  WAX 3  dA -24, 14  UPSIDEDOWN
	.long	KTKNOCKDOWN6
	.word	-11,75,210,4		; step  5  WAX 4  dA  11, 75  UPSIDEDOWN SMOKE ZAP
	.long	LIBUZZ2W
	.word	-7,-62,272,4		; step  6  WAX 5  dA   7, 62  XRAY
	.long	KTKNOCKDOWN6
	.word	-14,71,80,4		; step  7  WAX 6  dA  14, 71  UPSIDEDOWN
	.long	KTBACKBREAK3
	.word	-7,21,80,4		; step  8  WAX 7  dA   7, 21  UPSIDEDOWN
	.long	SBBUZZ2W
	.word	-13,-58,272,4		; step  9  WAX 8  dA  13, 58  XRAY
	.long	KTKNOCKDOWN6
	.word	-11,75,208,4		; step 10  WAX 4  dA  11, 75  UPSIDEDOWN ZAP loop 1
	.long	LIBUZZ2W
	.word	-7,-62,272,4		; step 11  WAX 5  dA   7, 62  XRAY loop 1
	.long	KTKNOCKDOWN6
	.word	-14,71,80,4		; step 12  WAX 6  dA  14, 71  UPSIDEDOWN loop 1
	.long	KTBACKBREAK3
	.word	-7,21,80,4		; step 13  WAX 7  dA   7, 21  UPSIDEDOWN loop 1
	.long	SBBUZZ2W
	.word	-13,-58,272,4		; step 14  WAX 8  dA  13, 58  XRAY loop 1
	.long	KTKNOCKDOWN6
	.word	-11,75,240,4		; step 15  WAX 4  dA  11, 75  UPSIDEDOWN ZAP MASH loop 2
	.long	LIBUZZ2W
	.word	-7,-62,272,4		; step 16  WAX 5  dA   7, 62  XRAY loop 2
	.long	KTKNOCKDOWN6
	.word	-14,71,80,4		; step 17  WAX 6  dA  14, 71  UPSIDEDOWN loop 2
	.long	KTBACKBREAK3
	.word	-7,21,80,4		; step 18  WAX 7  dA   7, 21  UPSIDEDOWN loop 2
	.long	SBBUZZ2W
	.word	-13,-58,272,4		; step 19  WAX 8  dA  13, 58  XRAY loop 2
	.long	KTKNOCKDOWN6
	.word	-11,75,240,4		; step 20  WAX 4  dA  11, 75  UPSIDEDOWN ZAP MASH loop 3
	.long	LIBUZZ2W
	.word	-7,-62,272,4		; step 21  WAX 5  dA   7, 62  XRAY loop 3
	.long	KTKNOCKDOWN6
	.word	-14,71,80,4		; step 22  WAX 6  dA  14, 71  UPSIDEDOWN loop 3
	.long	KTBACKBREAK3
	.word	-7,21,80,4		; step 23  WAX 7  dA   7, 21  UPSIDEDOWN loop 3
	.long	SBBUZZ2W
	.word	-13,-58,272,4		; step 24  WAX 8  dA  13, 58  XRAY loop 3
	.long	KTKNOCKDOWN6
	.word	-11,75,240,4		; step 25  WAX 4  dA  11, 75  UPSIDEDOWN ZAP MASH loop 4
	.long	LIBUZZ2W
	.word	-7,-62,272,4		; step 26  WAX 5  dA   7, 62  XRAY loop 4
	.long	KTKNOCKDOWN6
	.word	-14,71,80,4		; step 27  WAX 6  dA  14, 71  UPSIDEDOWN loop 4
	.long	KTBACKBREAK3
	.word	-7,21,80,4		; step 28  WAX 7  dA   7, 21  UPSIDEDOWN loop 4
	.long	SBBUZZ2W
	.word	-13,-58,272,4		; step 29  WAX 8  dA  13, 58  XRAY loop 4
	.long	KTKNOCKDOWN6
	.word	-11,75,240,4		; step 30  WAX 4  dA  11, 75  UPSIDEDOWN ZAP MASH loop 5
	.long	LIBUZZ2W
	.word	-7,-62,272,4		; step 31  WAX 5  dA   7, 62  XRAY loop 5
	.long	KTKNOCKDOWN6
	.word	-14,71,80,4		; step 32  WAX 6  dA  14, 71  UPSIDEDOWN loop 5
	.long	KTBACKBREAK3
	.word	-7,21,80,4		; step 33  WAX 7  dA   7, 21  UPSIDEDOWN loop 5
	.long	SBBUZZ2W
	.word	-13,-58,272,4		; step 34  WAX 8  dA  13, 58  XRAY loop 5
	.long	KTKNOCKDOWN6
	.word	-4,78,112,4		; step 35  WAX 9  dA   4, 78  UPSIDEDOWN MASH
	.long	KTKNOCKDOWN3
	.word	-14,30,80,4		; step 36  WAX 10 dA  14, 30  UPSIDEDOWN
	.long	0

; data/RAIDELECTSUNG.WAX (victim slot 2) - shang tsung
rd_lift_vic_script_st
	.long	STSTUMBLE1
	.word	77,-35,25,4		; step  1  WAX 0  dA  77, 35  mirrored DEATH
	.long	STDRAIN0
	.word	84,-40,17,4		; step  2  WAX 1  dA  84, 40  mirrored
	.long	STFLIPPED2
	.word	59,-83,17,4		; step  3  WAX 2  dA  59, 83  mirrored
	.long	STBACKBREAK2
	.word	31,2,80,4		; step  4  WAX 3  dA -31,  2  UPSIDEDOWN
	.long	TSBUZZ2W
	.word	-10,-70,402,4		; step  5  WAX 4  dA  10, 70  XRAY SMOKE ZAP
	.long	STBACKBREAK2
	.word	-5,22,80,4		; step  6  WAX 5  dA   5, 22  UPSIDEDOWN
	.long	STBACKBREAK3
	.word	-13,23,80,4		; step  7  WAX 6  dA  13, 23  UPSIDEDOWN
	.long	TSBUZZ2W
	.word	-5,-81,272,4		; step  8  WAX 7  dA   5, 81  XRAY
	.long	STKNOCKDOWN7
	.word	-8,85,80,4		; step  9  WAX 8  dA   8, 85  UPSIDEDOWN
	.long	TSBUZZ2W
	.word	-10,-70,400,4		; step 10  WAX 4  dA  10, 70  XRAY ZAP loop 1
	.long	STBACKBREAK2
	.word	-5,22,80,4		; step 11  WAX 5  dA   5, 22  UPSIDEDOWN loop 1
	.long	STBACKBREAK3
	.word	-13,23,80,4		; step 12  WAX 6  dA  13, 23  UPSIDEDOWN loop 1
	.long	TSBUZZ2W
	.word	-5,-81,272,4		; step 13  WAX 7  dA   5, 81  XRAY loop 1
	.long	STKNOCKDOWN7
	.word	-8,85,80,4		; step 14  WAX 8  dA   8, 85  UPSIDEDOWN loop 1
	.long	TSBUZZ2W
	.word	-10,-70,432,4		; step 15  WAX 4  dA  10, 70  XRAY ZAP MASH loop 2
	.long	STBACKBREAK2
	.word	-5,22,80,4		; step 16  WAX 5  dA   5, 22  UPSIDEDOWN loop 2
	.long	STBACKBREAK3
	.word	-13,23,80,4		; step 17  WAX 6  dA  13, 23  UPSIDEDOWN loop 2
	.long	TSBUZZ2W
	.word	-5,-81,272,4		; step 18  WAX 7  dA   5, 81  XRAY loop 2
	.long	STKNOCKDOWN7
	.word	-8,85,80,4		; step 19  WAX 8  dA   8, 85  UPSIDEDOWN loop 2
	.long	TSBUZZ2W
	.word	-10,-70,432,4		; step 20  WAX 4  dA  10, 70  XRAY ZAP MASH loop 3
	.long	STBACKBREAK2
	.word	-5,22,80,4		; step 21  WAX 5  dA   5, 22  UPSIDEDOWN loop 3
	.long	STBACKBREAK3
	.word	-13,23,80,4		; step 22  WAX 6  dA  13, 23  UPSIDEDOWN loop 3
	.long	TSBUZZ2W
	.word	-5,-81,272,4		; step 23  WAX 7  dA   5, 81  XRAY loop 3
	.long	STKNOCKDOWN7
	.word	-8,85,80,4		; step 24  WAX 8  dA   8, 85  UPSIDEDOWN loop 3
	.long	TSBUZZ2W
	.word	-10,-70,432,4		; step 25  WAX 4  dA  10, 70  XRAY ZAP MASH loop 4
	.long	STBACKBREAK2
	.word	-5,22,80,4		; step 26  WAX 5  dA   5, 22  UPSIDEDOWN loop 4
	.long	STBACKBREAK3
	.word	-13,23,80,4		; step 27  WAX 6  dA  13, 23  UPSIDEDOWN loop 4
	.long	TSBUZZ2W
	.word	-5,-81,272,4		; step 28  WAX 7  dA   5, 81  XRAY loop 4
	.long	STKNOCKDOWN7
	.word	-8,85,80,4		; step 29  WAX 8  dA   8, 85  UPSIDEDOWN loop 4
	.long	TSBUZZ2W
	.word	-10,-70,432,4		; step 30  WAX 4  dA  10, 70  XRAY ZAP MASH loop 5
	.long	STBACKBREAK2
	.word	-5,22,80,4		; step 31  WAX 5  dA   5, 22  UPSIDEDOWN loop 5
	.long	STBACKBREAK3
	.word	-13,23,80,4		; step 32  WAX 6  dA  13, 23  UPSIDEDOWN loop 5
	.long	TSBUZZ2W
	.word	-5,-81,272,4		; step 33  WAX 7  dA   5, 81  XRAY loop 5
	.long	STKNOCKDOWN7
	.word	-8,85,80,4		; step 34  WAX 8  dA   8, 85  UPSIDEDOWN loop 5
	.long	STBACKBREAK3
	.word	-7,27,112,4		; step 35  WAX 9  dA   7, 27  UPSIDEDOWN MASH
	.long	STKNOCKDOWN7
	.word	-5,87,80,4		; step 36  WAX 10 dA   5, 87  UPSIDEDOWN
	.long	0

; data/RAIDELECRAD.WAX (victim slot 4) - raiden
rd_lift_vic_script_rn
	.long	RNSTUMBLE1
	.word	80,-39,25,4		; step  1  WAX 0  dA  80, 39  mirrored DEATH
	.long	RDDRAIN0
	.word	92,-49,17,4		; step  2  WAX 1  dA  92, 49  mirrored
	.long	RNFLIPPED2
	.word	56,-77,17,4		; step  3  WAX 2  dA  56, 77  mirrored
	.long	RNBACKBREAK3
	.word	23,23,80,4		; step  4  WAX 3  dA -23, 23  UPSIDEDOWN
	.long	RDBUZZ2W
	.word	-70,-18,402,4		; step  5  WAX 4  dA  70, 18  XRAY SMOKE ZAP
	.long	RNBACKBREAK3
	.word	-15,46,80,4		; step  6  WAX 5  dA  15, 46  UPSIDEDOWN
	.long	RNKNOCKDOWN7
	.word	-33,86,80,4		; step  7  WAX 6  dA  33, 86  UPSIDEDOWN
	.long	RNBACKBREAK2
	.word	-25,13,80,4		; step  8  WAX 7  dA  25, 13  UPSIDEDOWN
	.long	RDBUZZ2W
	.word	-73,-22,272,4		; step  9  WAX 8  dA  73, 22  XRAY
	.long	RDBUZZ2W
	.word	-70,-18,400,4		; step 10  WAX 4  dA  70, 18  XRAY ZAP loop 1
	.long	RNBACKBREAK3
	.word	-15,46,80,4		; step 11  WAX 5  dA  15, 46  UPSIDEDOWN loop 1
	.long	RNKNOCKDOWN7
	.word	-33,86,80,4		; step 12  WAX 6  dA  33, 86  UPSIDEDOWN loop 1
	.long	RNBACKBREAK2
	.word	-25,13,80,4		; step 13  WAX 7  dA  25, 13  UPSIDEDOWN loop 1
	.long	RDBUZZ2W
	.word	-73,-22,272,4		; step 14  WAX 8  dA  73, 22  XRAY loop 1
	.long	RDBUZZ2W
	.word	-70,-18,432,4		; step 15  WAX 4  dA  70, 18  XRAY ZAP MASH loop 2
	.long	RNBACKBREAK3
	.word	-15,46,80,4		; step 16  WAX 5  dA  15, 46  UPSIDEDOWN loop 2
	.long	RNKNOCKDOWN7
	.word	-33,86,80,4		; step 17  WAX 6  dA  33, 86  UPSIDEDOWN loop 2
	.long	RNBACKBREAK2
	.word	-25,13,80,4		; step 18  WAX 7  dA  25, 13  UPSIDEDOWN loop 2
	.long	RDBUZZ2W
	.word	-73,-22,272,4		; step 19  WAX 8  dA  73, 22  XRAY loop 2
	.long	RDBUZZ2W
	.word	-70,-18,432,4		; step 20  WAX 4  dA  70, 18  XRAY ZAP MASH loop 3
	.long	RNBACKBREAK3
	.word	-15,46,80,4		; step 21  WAX 5  dA  15, 46  UPSIDEDOWN loop 3
	.long	RNKNOCKDOWN7
	.word	-33,86,80,4		; step 22  WAX 6  dA  33, 86  UPSIDEDOWN loop 3
	.long	RNBACKBREAK2
	.word	-25,13,80,4		; step 23  WAX 7  dA  25, 13  UPSIDEDOWN loop 3
	.long	RDBUZZ2W
	.word	-73,-22,272,4		; step 24  WAX 8  dA  73, 22  XRAY loop 3
	.long	RDBUZZ2W
	.word	-70,-18,432,4		; step 25  WAX 4  dA  70, 18  XRAY ZAP MASH loop 4
	.long	RNBACKBREAK3
	.word	-15,46,80,4		; step 26  WAX 5  dA  15, 46  UPSIDEDOWN loop 4
	.long	RNKNOCKDOWN7
	.word	-33,86,80,4		; step 27  WAX 6  dA  33, 86  UPSIDEDOWN loop 4
	.long	RNBACKBREAK2
	.word	-25,13,80,4		; step 28  WAX 7  dA  25, 13  UPSIDEDOWN loop 4
	.long	RDBUZZ2W
	.word	-73,-22,272,4		; step 29  WAX 8  dA  73, 22  XRAY loop 4
	.long	RDBUZZ2W
	.word	-70,-18,432,4		; step 30  WAX 4  dA  70, 18  XRAY ZAP MASH loop 5
	.long	RNBACKBREAK3
	.word	-15,46,80,4		; step 31  WAX 5  dA  15, 46  UPSIDEDOWN loop 5
	.long	RNKNOCKDOWN7
	.word	-33,86,80,4		; step 32  WAX 6  dA  33, 86  UPSIDEDOWN loop 5
	.long	RNBACKBREAK2
	.word	-25,13,80,4		; step 33  WAX 7  dA  25, 13  UPSIDEDOWN loop 5
	.long	RDBUZZ2W
	.word	-73,-22,272,4		; step 34  WAX 8  dA  73, 22  XRAY loop 5
	.long	RNKNOCKDOWN7
	.word	-23,87,112,4		; step 35  WAX 9  dA  23, 87  UPSIDEDOWN MASH
	.long	RNKNOCKDOWN7
	.word	-20,89,80,4		; step 36  WAX 10 dA  20, 89  UPSIDEDOWN
	.long	0

; data/RAIDELECNJ.WAX (victim slot 1) - sub-zero, reptile, scorpion, kintaro, shao kahn, smoke, noob saibot, ermac, rain
rd_lift_vic_script_nj
	.long	NJSTUMBLE1
	.word	88,-36,25,4		; step  1  WAX 0  dA  88, 36  mirrored DEATH
	.long	NJDRAIN0
	.word	84,-39,17,4		; step  2  WAX 1  dA  84, 39  mirrored
	.long	NJFLIPPED2
	.word	62,-71,17,4		; step  3  WAX 2  dA  62, 71  mirrored
	.long	NJGETUP4
	.word	29,33,80,4		; step  4  WAX 3  dA -29, 33  UPSIDEDOWN
	.long	KNBUZZ2W
	.word	-15,-61,402,4		; step  5  WAX 4  dA  15, 61  XRAY SMOKE ZAP
	.long	NJBACKBREAK2
	.word	-6,22,80,4		; step  6  WAX 5  dA   6, 22  UPSIDEDOWN
	.long	NJBACKBREAK1
	.word	-21,5,80,4		; step  7  WAX 6  dA  21,  5  UPSIDEDOWN
	.long	NJBACKBREAK3
	.word	-13,19,80,4		; step  8  WAX 7  dA  13, 19  UPSIDEDOWN
	.long	KNBUZZ2W
	.word	-11,-68,272,4		; step  9  WAX 8  dA  11, 68  XRAY
	.long	KNBUZZ2W
	.word	-15,-61,400,4		; step 10  WAX 4  dA  15, 61  XRAY ZAP loop 1
	.long	NJBACKBREAK2
	.word	-6,22,80,4		; step 11  WAX 5  dA   6, 22  UPSIDEDOWN loop 1
	.long	NJBACKBREAK1
	.word	-21,5,80,4		; step 12  WAX 6  dA  21,  5  UPSIDEDOWN loop 1
	.long	NJBACKBREAK3
	.word	-13,19,80,4		; step 13  WAX 7  dA  13, 19  UPSIDEDOWN loop 1
	.long	KNBUZZ2W
	.word	-11,-68,272,4		; step 14  WAX 8  dA  11, 68  XRAY loop 1
	.long	KNBUZZ2W
	.word	-15,-61,432,4		; step 15  WAX 4  dA  15, 61  XRAY ZAP MASH loop 2
	.long	NJBACKBREAK2
	.word	-6,22,80,4		; step 16  WAX 5  dA   6, 22  UPSIDEDOWN loop 2
	.long	NJBACKBREAK1
	.word	-21,5,80,4		; step 17  WAX 6  dA  21,  5  UPSIDEDOWN loop 2
	.long	NJBACKBREAK3
	.word	-13,19,80,4		; step 18  WAX 7  dA  13, 19  UPSIDEDOWN loop 2
	.long	KNBUZZ2W
	.word	-11,-68,272,4		; step 19  WAX 8  dA  11, 68  XRAY loop 2
	.long	KNBUZZ2W
	.word	-15,-61,432,4		; step 20  WAX 4  dA  15, 61  XRAY ZAP MASH loop 3
	.long	NJBACKBREAK2
	.word	-6,22,80,4		; step 21  WAX 5  dA   6, 22  UPSIDEDOWN loop 3
	.long	NJBACKBREAK1
	.word	-21,5,80,4		; step 22  WAX 6  dA  21,  5  UPSIDEDOWN loop 3
	.long	NJBACKBREAK3
	.word	-13,19,80,4		; step 23  WAX 7  dA  13, 19  UPSIDEDOWN loop 3
	.long	KNBUZZ2W
	.word	-11,-68,272,4		; step 24  WAX 8  dA  11, 68  XRAY loop 3
	.long	KNBUZZ2W
	.word	-15,-61,432,4		; step 25  WAX 4  dA  15, 61  XRAY ZAP MASH loop 4
	.long	NJBACKBREAK2
	.word	-6,22,80,4		; step 26  WAX 5  dA   6, 22  UPSIDEDOWN loop 4
	.long	NJBACKBREAK1
	.word	-21,5,80,4		; step 27  WAX 6  dA  21,  5  UPSIDEDOWN loop 4
	.long	NJBACKBREAK3
	.word	-13,19,80,4		; step 28  WAX 7  dA  13, 19  UPSIDEDOWN loop 4
	.long	KNBUZZ2W
	.word	-11,-68,272,4		; step 29  WAX 8  dA  11, 68  XRAY loop 4
	.long	KNBUZZ2W
	.word	-15,-61,432,4		; step 30  WAX 4  dA  15, 61  XRAY ZAP MASH loop 5
	.long	NJBACKBREAK2
	.word	-6,22,80,4		; step 31  WAX 5  dA   6, 22  UPSIDEDOWN loop 5
	.long	NJBACKBREAK1
	.word	-21,5,80,4		; step 32  WAX 6  dA  21,  5  UPSIDEDOWN loop 5
	.long	NJBACKBREAK3
	.word	-13,19,80,4		; step 33  WAX 7  dA  13, 19  UPSIDEDOWN loop 5
	.long	KNBUZZ2W
	.word	-11,-68,272,4		; step 34  WAX 8  dA  11, 68  XRAY loop 5
	.long	NJKNOCKDOWN6
	.word	-20,74,112,4		; step 35  WAX 9  dA  20, 74  UPSIDEDOWN MASH
	.long	NJBACKBREAK2
	.word	-5,12,80,4		; step 36  WAX 10 dA   5, 12  UPSIDEDOWN
	.long	0

; data/RAIDELECJAX.WAX (victim slot 4) - jax
rd_lift_vic_script_jx
	.long	JXSTUMBLE1
	.word	81,-29,25,4		; step  1  WAX 0  dA  81, 29  mirrored DEATH
	.long	JXDRAIN0
	.word	83,-42,17,4		; step  2  WAX 1  dA  83, 42  mirrored
	.long	JXFLIPPED2
	.word	68,-87,17,4		; step  3  WAX 2  dA  68, 87  mirrored
	.long	JXBACKBREAK3
	.word	0,16,80,4		; step  4  WAX 3  dA   0, 16  UPSIDEDOWN
	.long	KNBUZZ2W
	.word	-16,-62,402,4		; step  5  WAX 4  dA  16, 62  XRAY SMOKE ZAP
	.long	JXKNOCKDOWN3
	.word	-18,24,80,4		; step  6  WAX 5  dA  18, 24  UPSIDEDOWN
	.long	JXKNOCKDOWN7
	.word	-24,90,80,4		; step  7  WAX 6  dA  24, 90  UPSIDEDOWN
	.long	JXKNOCKDOWN6
	.word	-14,77,80,4		; step  8  WAX 7  dA  14, 77  UPSIDEDOWN
	.long	JXKNOCKDOWN7
	.word	-25,89,80,4		; step  9  WAX 8  dA  25, 89  UPSIDEDOWN
	.long	KNBUZZ2W
	.word	-16,-62,400,4		; step 10  WAX 4  dA  16, 62  XRAY ZAP loop 1
	.long	JXKNOCKDOWN3
	.word	-18,24,80,4		; step 11  WAX 5  dA  18, 24  UPSIDEDOWN loop 1
	.long	JXKNOCKDOWN7
	.word	-24,90,80,4		; step 12  WAX 6  dA  24, 90  UPSIDEDOWN loop 1
	.long	JXKNOCKDOWN6
	.word	-14,77,80,4		; step 13  WAX 7  dA  14, 77  UPSIDEDOWN loop 1
	.long	JXKNOCKDOWN7
	.word	-25,89,80,4		; step 14  WAX 8  dA  25, 89  UPSIDEDOWN loop 1
	.long	KNBUZZ2W
	.word	-16,-62,432,4		; step 15  WAX 4  dA  16, 62  XRAY ZAP MASH loop 2
	.long	JXKNOCKDOWN3
	.word	-18,24,80,4		; step 16  WAX 5  dA  18, 24  UPSIDEDOWN loop 2
	.long	JXKNOCKDOWN7
	.word	-24,90,80,4		; step 17  WAX 6  dA  24, 90  UPSIDEDOWN loop 2
	.long	JXKNOCKDOWN6
	.word	-14,77,80,4		; step 18  WAX 7  dA  14, 77  UPSIDEDOWN loop 2
	.long	JXKNOCKDOWN7
	.word	-25,89,80,4		; step 19  WAX 8  dA  25, 89  UPSIDEDOWN loop 2
	.long	KNBUZZ2W
	.word	-16,-62,432,4		; step 20  WAX 4  dA  16, 62  XRAY ZAP MASH loop 3
	.long	JXKNOCKDOWN3
	.word	-18,24,80,4		; step 21  WAX 5  dA  18, 24  UPSIDEDOWN loop 3
	.long	JXKNOCKDOWN7
	.word	-24,90,80,4		; step 22  WAX 6  dA  24, 90  UPSIDEDOWN loop 3
	.long	JXKNOCKDOWN6
	.word	-14,77,80,4		; step 23  WAX 7  dA  14, 77  UPSIDEDOWN loop 3
	.long	JXKNOCKDOWN7
	.word	-25,89,80,4		; step 24  WAX 8  dA  25, 89  UPSIDEDOWN loop 3
	.long	KNBUZZ2W
	.word	-16,-62,432,4		; step 25  WAX 4  dA  16, 62  XRAY ZAP MASH loop 4
	.long	JXKNOCKDOWN3
	.word	-18,24,80,4		; step 26  WAX 5  dA  18, 24  UPSIDEDOWN loop 4
	.long	JXKNOCKDOWN7
	.word	-24,90,80,4		; step 27  WAX 6  dA  24, 90  UPSIDEDOWN loop 4
	.long	JXKNOCKDOWN6
	.word	-14,77,80,4		; step 28  WAX 7  dA  14, 77  UPSIDEDOWN loop 4
	.long	JXKNOCKDOWN7
	.word	-25,89,80,4		; step 29  WAX 8  dA  25, 89  UPSIDEDOWN loop 4
	.long	KNBUZZ2W
	.word	-16,-62,432,4		; step 30  WAX 4  dA  16, 62  XRAY ZAP MASH loop 5
	.long	JXKNOCKDOWN3
	.word	-18,24,80,4		; step 31  WAX 5  dA  18, 24  UPSIDEDOWN loop 5
	.long	JXKNOCKDOWN7
	.word	-24,90,80,4		; step 32  WAX 6  dA  24, 90  UPSIDEDOWN loop 5
	.long	JXKNOCKDOWN6
	.word	-14,77,80,4		; step 33  WAX 7  dA  14, 77  UPSIDEDOWN loop 5
	.long	JXKNOCKDOWN7
	.word	-25,89,80,4		; step 34  WAX 8  dA  25, 89  UPSIDEDOWN loop 5
	.long	JXBACKBREAK3
	.word	-22,25,112,4		; step 35  WAX 9  dA  22, 25  UPSIDEDOWN MASH
	.long	KNBUZZ2W
	.word	-16,-62,272,4		; step 36  WAX 10 dA  16, 62  XRAY
	.long	0
; Per-fighter poses (by ochar), authored against Liu Kang: LKSTUMBLE1 (KANG5),
; LKFLIPPED2 (KANG6), LKBACKBREAK3 (KANG10), LKKNOCKDOWN7 (KANG5).
rd_lift_stumble1_tbl
	.long	TMSTUMBLE1,LKSTUMBLE1,JCSTUMBLE1,UGSTUMBL1E1	; (sic) MKSA.ASM
	.long	KTSTUMBLE1,KTSTUMBLE1,STSTUMBLE1,RNSTUMBLE1
	.long	NJSTUMBLE1,NJSTUMBLE1,NJSTUMBLE1,JXSTUMBLE1
	.long	NJSTUMBLE1,NJSTUMBLE1,NJSTUMBLE1,NJSTUMBLE1,KTSTUMBLE1
	.long	NJSTUMBLE1		; 17 - ermac (clone of Reptile)
	.long	KTSTUMBLE1		; 18 - khameleon (female ninja, Jade's row)
	.long	NJSTUMBLE1		; 19 - rain (clone of Scorpion)
	.if	wunit	; WOLF FIGHTERS
	.ref	KNSTUMBLE1
	.long	KTSTUMBLE1,KTSTUMBLE1,KNSTUMBLE1,LKSTUMBLE1,NJSTUMBLE1	; 20 sonya=4, 21 sindel=4, 22 kano, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS

rd_lift_flipped2_tbl
	.long	TMFLIPPED2,LKFLIPPED2,JCFLIPPED2,UGFLIPPED2
	.long	KTGETFLIPPED2,KTGETFLIPPED2,STFLIPPED2,RNFLIPPED2
	.long	NJFLIPPED2,NJFLIPPED2,NJFLIPPED2,JXFLIPPED2
	.long	NJFLIPPED2,NJFLIPPED2,NJFLIPPED2,NJFLIPPED2,KTGETFLIPPED2
	.long	NJFLIPPED2		; 17 - ermac (clone of Reptile)
	.long	KTGETFLIPPED2		; 18 - khameleon (female ninja, Jade's row)
	.long	NJFLIPPED2		; 19 - rain (clone of Scorpion)
	.if	wunit	; WOLF FIGHTERS
	.ref	KNFLIPPED2
	.long	KTGETFLIPPED2,KTGETFLIPPED2,KNFLIPPED2,LKFLIPPED2,NJFLIPPED2	; 20 sonya=4, 21 sindel=4, 22 kano, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS

rd_lift_bb3_tbl
	.long	TMBACKBREAK3,LKBACKBREAK3,JCBACKBREAK3,UGBACKBREAK3
	.long	KTBACKBREAK3,KTBACKBREAK3,STBACKBREAK3,RNBACKBREAK3
	.long	NJBACKBREAK3,NJBACKBREAK3,NJBACKBREAK3,JXBACKBREAK3
	.long	NJBACKBREAK3,NJBACKBREAK3,NJBACKBREAK3,NJBACKBREAK3,KTBACKBREAK3
	.long	NJBACKBREAK3		; 17 - ermac (clone of Reptile)
	.long	KTBACKBREAK3		; 18 - khameleon (female ninja, Jade's row)
	.long	NJBACKBREAK3		; 19 - rain (clone of Scorpion)
	.if	wunit	; WOLF FIGHTERS
	.ref	KNBACKBREAK3
	.long	KTBACKBREAK3,KTBACKBREAK3,KNBACKBREAK3,LKBACKBREAK3,NJBACKBREAK3	; 20 sonya=4, 21 sindel=4, 22 kano, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS

; the female ninjas' knockdown lane ends on 6 - it is their flat frame
rd_lift_kd7_tbl
	.long	TMKNOCKDOWN7,LKKNOCKDOWN7,JCKNOCKDOWN7,UGKNOCKDOWN7
	.long	KTKNOCKDOWN6,KTKNOCKDOWN6,STKNOCKDOWN7,RNKNOCKDOWN7
	.long	NJKNOCKDOWN7,NJKNOCKDOWN7,NJKNOCKDOWN7,JXKNOCKDOWN7
	.long	NJKNOCKDOWN7,NJKNOCKDOWN7,NJKNOCKDOWN7,NJKNOCKDOWN7,KTKNOCKDOWN6
	.long	NJKNOCKDOWN7		; 17 - ermac (clone of Reptile)
	.long	KTKNOCKDOWN6		; 18 - khameleon (female ninja, Jade's row)
	.long	NJKNOCKDOWN7		; 19 - rain (clone of Scorpion)
	.if	wunit	; WOLF FIGHTERS
	.ref	KNKNOCKDOWN7
	.long	KTKNOCKDOWN6,KTKNOCKDOWN6,KNKNOCKDOWN7,LKKNOCKDOWN7,NJKNOCKDOWN7	; 20 sonya=4, 21 sindel=4, 22 kano, 23 nightwolf=1, 24 rsmoke=14
	.endif		; WOLF FIGHTERS
