	.file	"mkboltg.asm"
	.title	"ambient body-bolt geometry"
	.width	132
	.option	b,d,l,t
	.mnolist

	.include	sysequ.asm
	.include	dispequ.asm
	.include	mainequ.asm
	.include	macros.hdr

	.ref	random

* Instrumentation for wiring up the lightning path.  Write-only.
	.bss	bolt_flash,16		; times the flash block was entered
	.bss	bolt_tick,16		; times a tick emitted geometry
	.bss	bolt_post,16		; ticks that survived the sleep
	.bss	bolt_shut,16		; times lgt_shutdown was reached
	.bss	bge_col,32		; colour for the pass being emitted
	.bss	bolt_g1,16		; lgt_can_flash: passed the gstate check
	.bss	bolt_g2,16		; lgt_can_flash: rejected at lgt_airborne
	.bss	bolt_g3,16		; lgt_can_flash: rejected on gstate
	.global	bolt_flash,bolt_tick,bolt_post,bolt_shut
	.global	bolt_g1,bolt_g2,bolt_g3
	.ref	geo_count,geo_list

* Ambient body-bolt geometry, MEASURED from the running game.
*
* Captured with tools/sweep_addon.lua by walking the multipart RAM of the
* live RN*BOLT objects and recording each piece's box relative to Raiden's
* anchor.  This is not derived from the anipoints in MKBOLTS.TBL - those
* are relative to the sprite, not to Raiden, and the multipart deltas are
* what actually place the art.
*
* Per style: .word nframes, then per frame .word npieces, then per piece
* .word dx,dy,w,h.  dy is POSITIVE DOWNWARD from the anchor (which sits
* near the head; the floor is about 113 below it).
** Raiden's ambient body bolts - MEASURED PATHS, not generated noise.
*
* Two sources, both from the real thing:
*   - the per-piece box offset relative to Raiden's anchor, captured at
*     runtime by walking the live multipart RAM (tools/sweep_addon.lua)
*   - the stroke centreline and its thickness, traced out of the decoded
*     sprite pixels (tools/extract_bolt_paths.py, 291/291 frames decoded)
*
* These bolts are a SMOOTH DETERMINISTIC ANIMATION, not electrical noise.
* An earlier version scribbled a random zigzag inside each box; it looked
* like static and did not follow the shape the art actually draws.  The
* joints below ARE the shape.  Do not re-randomise them.
*
* Per style: .word nframes, then per frame .word npieces, then per piece
*   .word dx,dy       box origin relative to Raiden's anchor (+y = DOWN)
*   .word thick       stroke weight in pixels, from the art
*   .word njoints
*   .word px,py       each joint, relative to the box origin
*
* Raiden's ambient body bolts - MEASURED PATHS, not generated noise.
*
* Sources, both from the real thing and both reproducible:
*   - box offset relative to Raiden's anchor, captured at runtime by walking
*     the live multipart RAM (MKBOLTS.TBL anipoints are sprite-relative and
*     are NOT the right source)
*   - stroke centreline and thickness, traced out of the decoded sprite
*     pixels by tools/extract_bolt_paths.py
*
* Each STRAND of a piece is its own entry with the same dx,dy - several of
* these frames are forked, and one centreline through a fork wanders through
* empty space.  The emitter needs no special case for that.
*
* These bolts are a SMOOTH DETERMINISTIC ANIMATION, not electrical noise.
* The joints below ARE the shape.  Do not re-randomise them.
*
* Per style: .word nframes, then per frame .word nentries, then per entry
*   .word dx,dy  box origin relative to Raiden's anchor (+y = DOWN)
*   .word thick  stroke weight in pixels, from the art
*   .word njoints
*   .word px,py  each joint, relative to the box origin
*
	.data

bolt_geo_tab
	.long	bolt_geo_1
	.long	bolt_geo_2
	.long	bolt_geo_3
	.long	bolt_geo_4
	.long	bolt_geo_5
	.long	bolt_geo_6

* RN1BOLT - 7 frames
bolt_geo_1
	.word	7
	.word	1		; frame 1  (6 segments)
	.word	-12,19,3,2	; RN1BOLT1A
	.word	0,1
	.word	13,4
	.word	2		; frame 2  (24 segments)
	.word	-17,20,3,3	; RN1BOLT2A
	.word	0,1
	.word	7,5
	.word	13,6
	.word	-3,19,3,3	; RN1BOLT2B
	.word	0,7
	.word	6,6
	.word	12,1
	.word	2		; frame 3  (12 segments)
	.word	-24,20,3,2	; RN1BOLT3A
	.word	0,1
	.word	13,3
	.word	-10,19,3,2	; RN1BOLT3B
	.word	0,4
	.word	12,1
	.word	1		; frame 4  (18 segments)
	.word	-33,17,3,4	; RN1BOLT4A
	.word	0,4
	.word	12,3
	.word	14,1
	.word	26,3
	.word	2		; frame 5  (12 segments)
	.word	-40,16,3,2	; RN1BOLT5A
	.word	0,5
	.word	14,1
	.word	-25,16,3,2	; RN1BOLT5B
	.word	0,1
	.word	11,4
	.word	2		; frame 6  (12 segments)
	.word	-48,17,3,2	; RN1BOLT6A
	.word	0,4
	.word	12,1
	.word	-32,18,3,2	; RN1BOLT6B
	.word	0,1
	.word	10,2
	.word	2		; frame 7  (8 segments)
	.word	-55,19,2,2	; RN1BOLT7A
	.word	0,3
	.word	5,1
	.word	-34,19,2,2	; RN1BOLT7B
	.word	0,1
	.word	6,1

* RN2BOLT - 9 frames
bolt_geo_2
	.word	9
	.word	3		; frame 1  (28 segments)
	.word	-23,32,4,3	; RN2BOLT1A
	.word	0,4
	.word	3,1
	.word	11,8
	.word	-11,23,3,2	; RN2BOLT1B
	.word	5,0
	.word	3,11
	.word	-11,23,3,2	; RN2BOLT1B
	.word	0,18
	.word	5,20
	.word	2		; frame 2  (52 segments)
	.word	-26,34,3,3	; RN2BOLT2A
	.word	0,1
	.word	6,3
	.word	12,8
	.word	-13,21,4,6	; RN2BOLT2B
	.word	5,0
	.word	4,6
	.word	8,19
	.word	7,21
	.word	3,22
	.word	18,40
	.word	3		; frame 3  (104 segments)
	.word	-14,22,6,4	; RN2BOLT3A
	.word	5,0
	.word	3,4
	.word	5,5
	.word	7,11
	.word	-27,35,3,3	; RN2BOLT3B
	.word	0,0
	.word	10,9
	.word	17,12
	.word	-9,34,4,8	; RN2BOLT3C
	.word	3,0
	.word	7,4
	.word	8,11
	.word	7,13
	.word	3,14
	.word	15,23
	.word	17,27
	.word	16,35
	.word	2		; frame 4  (160 segments)
	.word	-22,42,4,3	; RN2BOLT4A
	.word	1,0
	.word	2,5
	.word	7,10
	.word	-14,25,6,13	; RN2BOLT4B
	.word	3,0
	.word	6,6
	.word	4,7
	.word	14,23
	.word	14,25
	.word	4,26
	.word	17,32
	.word	18,34
	.word	18,37
	.word	13,39
	.word	16,42
	.word	8,48
	.word	3,59
	.word	4		; frame 5  (138 segments)
	.word	-31,56,4,5	; RN2BOLT5A
	.word	18,15
	.word	11,33
	.word	4,40
	.word	6,42
	.word	1,52
	.word	-31,56,4,3	; RN2BOLT5A
	.word	2,1
	.word	9,8
	.word	18,12
	.word	-19,42,7,7	; RN2BOLT5B
	.word	13,0
	.word	17,8
	.word	14,11
	.word	14,14
	.word	20,22
	.word	10,30
	.word	18,32
	.word	-19,42,3,2	; RN2BOLT5B
	.word	0,8
	.word	2,8
	.word	3		; frame 6  (196 segments)
	.word	-46,53,6,13	; RN2BOLT6A
	.word	13,0
	.word	15,3
	.word	13,8
	.word	28,18
	.word	16,28
	.word	13,37
	.word	8,42
	.word	10,44
	.word	6,45
	.word	9,46
	.word	7,47
	.word	9,52
	.word	3,58
	.word	-15,51,6,5	; RN2BOLT6B
	.word	8,0
	.word	10,3
	.word	9,6
	.word	14,13
	.word	1,21
	.word	-15,51,2,2	; RN2BOLT6B
	.word	2,2
	.word	3,5
	.word	3		; frame 7  (184 segments)
	.word	-43,52,5,7	; RN2BOLT7A
	.word	0,10
	.word	4,10
	.word	5,3
	.word	6,10
	.word	7,6
	.word	13,17
	.word	21,17
	.word	-14,58,4,3	; RN2BOLT7B
	.word	7,0
	.word	10,6
	.word	3,12
	.word	-50,75,6,10	; RN2BOLT7C
	.word	20,0
	.word	11,8
	.word	13,18
	.word	6,22
	.word	13,23
	.word	4,24
	.word	12,26
	.word	6,27
	.word	13,29
	.word	5,35
	.word	6		; frame 8  (140 segments)
	.word	-46,52,6,5	; RN2BOLT8A
	.word	6,0
	.word	12,8
	.word	11,10
	.word	6,11
	.word	13,16
	.word	-46,52,2,2	; RN2BOLT8A
	.word	17,17
	.word	20,17
	.word	-15,63,3,2	; RN2BOLT8B
	.word	3,6
	.word	8,4
	.word	-53,77,5,7	; RN2BOLT8C
	.word	15,16
	.word	13,18
	.word	14,21
	.word	12,22
	.word	14,30
	.word	6,32
	.word	10,35
	.word	-53,77,3,4	; RN2BOLT8C
	.word	11,6
	.word	12,10
	.word	5,22
	.word	5,26
	.word	-53,77,2,2	; RN2BOLT8C
	.word	12,2
	.word	17,1
	.word	6		; frame 9  (44 segments)
	.word	-46,52,3,3	; RN2BOLT9A
	.word	4,1
	.word	9,2
	.word	13,6
	.word	-46,52,3,2	; RN2BOLT9A
	.word	0,11
	.word	9,15
	.word	-11,66,2,2	; RN2BOLT9B
	.word	0,1
	.word	3,1
	.word	-53,88,3,3	; RN2BOLT9C
	.word	0,21
	.word	7,25
	.word	13,24
	.word	-53,88,3,2	; RN2BOLT9C
	.word	10,4
	.word	5,15
	.word	-53,88,2,2	; RN2BOLT9C
	.word	14,19
	.word	14,22

* RN3BOLT - 10 frames
bolt_geo_3
	.word	10
	.word	1		; frame 1  (32 segments)
	.word	10,35,4,5	; RN3BOLT1A
	.word	7,0
	.word	4,5
	.word	5,8
	.word	1,11
	.word	2,13
	.word	1		; frame 2  (60 segments)
	.word	10,29,6,6	; RN3BOLT2A
	.word	11,0
	.word	8,4
	.word	13,5
	.word	3,11
	.word	1,16
	.word	2,19
	.word	3		; frame 3  (52 segments)
	.word	10,25,5,5	; RN3BOLT3A
	.word	13,0
	.word	6,5
	.word	10,7
	.word	3,14
	.word	1,23
	.word	24,24,3,2	; RN3BOLT3B
	.word	0,8
	.word	7,5
	.word	24,24,3,2	; RN3BOLT3B
	.word	0,2
	.word	7,1
	.word	2		; frame 4  (92 segments)
	.word	10,24,4,5	; RN3BOLT4A
	.word	8,0
	.word	3,8
	.word	6,11
	.word	2,17
	.word	1,24
	.word	19,23,6,6	; RN3BOLT4B
	.word	0,9
	.word	5,6
	.word	6,3
	.word	7,6
	.word	10,4
	.word	17,4
	.word	2		; frame 5  (68 segments)
	.word	10,26,7,5	; RN3BOLT5A
	.word	14,0
	.word	7,5
	.word	11,8
	.word	6,12
	.word	1,22
	.word	26,26,6,2	; RN3BOLT5B
	.word	0,6
	.word	11,1
	.word	2		; frame 6  (92 segments)
	.word	10,29,6,4	; RN3BOLT6A
	.word	11,0
	.word	6,7
	.word	9,9
	.word	2,18
	.word	23,26,7,5	; RN3BOLT6B
	.word	10,0
	.word	6,2
	.word	5,4
	.word	8,6
	.word	0,14
	.word	2		; frame 7  (78 segments)
	.word	4,31,7,4	; RN3BOLT7A
	.word	14,0
	.word	6,8
	.word	9,11
	.word	3,16
	.word	19,27,6,4	; RN3BOLT7B
	.word	8,0
	.word	4,5
	.word	7,7
	.word	0,16
	.word	3		; frame 8  (76 segments)
	.word	0,33,4,4	; RN3BOLT8A
	.word	12,0
	.word	11,3
	.word	3,10
	.word	3,14
	.word	0,33,2,2	; RN3BOLT8A
	.word	7,14
	.word	9,13
	.word	13,27,6,5	; RN3BOLT8B
	.word	11,0
	.word	4,6
	.word	8,7
	.word	9,10
	.word	1,18
	.word	2		; frame 9  (34 segments)
	.word	6,35,2,2	; RN3BOLT9A
	.word	3,4
	.word	9,0
	.word	17,27,5,4	; RN3BOLT9B
	.word	8,0
	.word	4,5
	.word	7,8
	.word	1,15
	.word	3		; frame 10  (16 segments)
	.word	18,27,4,2	; RN3BOLT10A
	.word	7,0
	.word	7,6
	.word	18,27,2,2	; RN3BOLT10A
	.word	1,3
	.word	1,5
	.word	18,27,2,2	; RN3BOLT10A
	.word	4,9
	.word	6,9

* RN4BOLT - 7 frames
bolt_geo_4
	.word	7
	.word	1		; frame 1  (40 segments)
	.word	-1,93,5,5	; RN4BOLT1A
	.word	0,2
	.word	3,4
	.word	8,4
	.word	10,8
	.word	12,8
	.word	2		; frame 2  (46 segments)
	.word	-6,86,3,2	; RN4BOLT2A
	.word	1,0
	.word	5,11
	.word	0,87,5,5	; RN4BOLT2B
	.word	3,0
	.word	2,1
	.word	5,6
	.word	3,10
	.word	10,15
	.word	2		; frame 3  (62 segments)
	.word	-17,72,5,4	; RN4BOLT3A
	.word	1,0
	.word	2,4
	.word	8,8
	.word	14,22
	.word	-2,77,4,5	; RN4BOLT3B
	.word	4,0
	.word	4,4
	.word	2,6
	.word	3,18
	.word	12,25
	.word	3		; frame 4  (120 segments)
	.word	-27,55,3,4	; RN4BOLT4A
	.word	1,0
	.word	4,7
	.word	4,12
	.word	12,25
	.word	-14,60,4,5	; RN4BOLT4B
	.word	3,0
	.word	5,3
	.word	2,8
	.word	2,17
	.word	10,35
	.word	-3,71,5,8	; RN4BOLT4C
	.word	13,0
	.word	18,1
	.word	16,3
	.word	2,9
	.word	2,17
	.word	4,21
	.word	3,25
	.word	13,31
	.word	5		; frame 5  (94 segments)
	.word	-28,57,3,3	; RN4BOLT5A
	.word	1,0
	.word	2,14
	.word	11,23
	.word	-16,61,4,5	; RN4BOLT5B
	.word	4,0
	.word	8,1
	.word	2,8
	.word	3,21
	.word	10,33
	.word	-5,72,5,3	; RN4BOLT5C
	.word	1,12
	.word	6,5
	.word	23,1
	.word	-5,72,4,4	; RN4BOLT5C
	.word	4,18
	.word	4,21
	.word	2,22
	.word	5,26
	.word	-5,72,3,2	; RN4BOLT5C
	.word	11,29
	.word	15,30
	.word	7		; frame 6  (104 segments)
	.word	-29,57,4,3	; RN4BOLT6A
	.word	2,0
	.word	2,16
	.word	11,24
	.word	-17,61,4,7	; RN4BOLT6B
	.word	6,0
	.word	9,1
	.word	2,8
	.word	4,17
	.word	7,19
	.word	3,23
	.word	5,25
	.word	-17,61,2,2	; RN4BOLT6B
	.word	9,28
	.word	9,32
	.word	-17,61,2,2	; RN4BOLT6B
	.word	0,18
	.word	0,21
	.word	-4,72,4,4	; RN4BOLT6C
	.word	0,8
	.word	4,3
	.word	11,5
	.word	22,1
	.word	-4,72,2,2	; RN4BOLT6C
	.word	0,23
	.word	4,21
	.word	-4,72,2,2	; RN4BOLT6C
	.word	11,30
	.word	14,30
	.word	6		; frame 7  (72 segments)
	.word	-30,57,3,2	; RN4BOLT7A
	.word	3,0
	.word	1,11
	.word	-30,57,3,2	; RN4BOLT7A
	.word	1,15
	.word	5,16
	.word	-30,57,3,2	; RN4BOLT7A
	.word	8,20
	.word	10,20
	.word	-19,61,4,2	; RN4BOLT7B
	.word	5,6
	.word	15,2
	.word	-19,61,3,2	; RN4BOLT7B
	.word	4,11
	.word	4,15
	.word	-1,72,4,6	; RN4BOLT7C
	.word	0,3
	.word	7,3
	.word	8,6
	.word	10,2
	.word	12,4
	.word	19,1

* RN5BOLT - 9 frames
bolt_geo_5
	.word	9
	.word	1		; frame 1  (24 segments)
	.word	22,42,4,4	; RN5BOLT1A
	.word	6,0
	.word	3,6
	.word	5,9
	.word	3,13
	.word	2		; frame 2  (62 segments)
	.word	13,49,3,3	; RN5BOLT2A
	.word	5,0
	.word	1,7
	.word	2,8
	.word	19,42,5,6	; RN5BOLT2B
	.word	9,0
	.word	4,8
	.word	6,9
	.word	6,13
	.word	2,20
	.word	2,25
	.word	2		; frame 3  (64 segments)
	.word	9,49,4,4	; RN5BOLT3A
	.word	11,0
	.word	3,6
	.word	1,10
	.word	2,12
	.word	17,42,4,6	; RN5BOLT3B
	.word	11,0
	.word	7,7
	.word	9,8
	.word	10,13
	.word	3,24
	.word	1,34
	.word	2		; frame 4  (80 segments)
	.word	5,49,4,4	; RN5BOLT4A
	.word	17,0
	.word	16,3
	.word	3,12
	.word	1,19
	.word	16,42,4,8	; RN5BOLT4B
	.word	12,0
	.word	10,6
	.word	13,11
	.word	13,20
	.word	4,35
	.word	3,40
	.word	6,43
	.word	6,49
	.word	2		; frame 5  (88 segments)
	.word	0,43,4,4	; RN5BOLT5A
	.word	21,0
	.word	20,7
	.word	12,12
	.word	2,25
	.word	11,42,4,9	; RN5BOLT5B
	.word	12,0
	.word	14,23
	.word	12,31
	.word	6,37
	.word	8,38
	.word	3,40
	.word	7,41
	.word	8,43
	.word	6,50
	.word	2		; frame 6  (96 segments)
	.word	-7,43,4,3	; RN5BOLT6A
	.word	22,0
	.word	19,12
	.word	2,25
	.word	4,43,4,11	; RN5BOLT6B
	.word	13,0
	.word	13,5
	.word	15,8
	.word	15,27
	.word	14,32
	.word	8,35
	.word	7,37
	.word	9,38
	.word	3,39
	.word	10,41
	.word	7,49
	.word	3		; frame 7  (64 segments)
	.word	-16,53,3,3	; RN5BOLT7A
	.word	0,14
	.word	7,14
	.word	21,0
	.word	-5,48,4,7	; RN5BOLT7B
	.word	16,7
	.word	17,11
	.word	14,27
	.word	11,31
	.word	4,35
	.word	10,36
	.word	7,44
	.word	-5,48,2,2	; RN5BOLT7B
	.word	14,0
	.word	15,5
	.word	2		; frame 8  (44 segments)
	.word	-23,57,3,3	; RN5BOLT8A
	.word	0,10
	.word	5,11
	.word	18,1
	.word	-12,65,4,5	; RN5BOLT8B
	.word	15,6
	.word	14,12
	.word	6,18
	.word	11,20
	.word	7,27
	.word	2		; frame 9  (68 segments)
	.word	-31,65,3,4	; RN5BOLT9A
	.word	0,2
	.word	4,4
	.word	11,4
	.word	13,1
	.word	-20,79,5,6	; RN5BOLT9B
	.word	0,4
	.word	5,5
	.word	6,11
	.word	9,10
	.word	11,5
	.word	13,5

* RN6BOLT - 12 frames
bolt_geo_6
	.word	12
	.word	1		; frame 1  (6 segments)
	.word	-25,107,3,2	; RN6BOLT1A
	.word	4,0
	.word	1,9
	.word	1		; frame 2  (12 segments)
	.word	-13,102,3,3	; RN6BOLT2A
	.word	8,0
	.word	2,6
	.word	1,14
	.word	1		; frame 3  (48 segments)
	.word	-1,99,6,5	; RN6BOLT3A
	.word	14,0
	.word	5,6
	.word	8,7
	.word	2,12
	.word	1,18
	.word	3		; frame 4  (50 segments)
	.word	11,98,4,5	; RN6BOLT4A
	.word	10,0
	.word	5,5
	.word	6,8
	.word	2,11
	.word	1,18
	.word	22,97,3,3	; RN6BOLT4B
	.word	0,2
	.word	3,1
	.word	10,3
	.word	22,97,3,2	; RN6BOLT4B
	.word	0,8
	.word	7,8
	.word	1		; frame 5  (42 segments)
	.word	23,99,7,4	; RN6BOLT5A
	.word	0,15
	.word	6,5
	.word	19,4
	.word	21,6
	.word	1		; frame 6  (48 segments)
	.word	35,99,6,5	; RN6BOLT6A
	.word	0,16
	.word	9,6
	.word	14,6
	.word	18,3
	.word	21,6
	.word	1		; frame 7  (72 segments)
	.word	47,99,6,7	; RN6BOLT7A
	.word	0,16
	.word	7,9
	.word	8,10
	.word	10,8
	.word	11,10
	.word	18,5
	.word	21,6
	.word	2		; frame 8  (70 segments)
	.word	59,107,5,3	; RN6BOLT8A
	.word	0,8
	.word	5,4
	.word	12,4
	.word	72,99,5,6	; RN6BOLT8B
	.word	7,0
	.word	4,4
	.word	5,6
	.word	3,7
	.word	4,11
	.word	1,14
	.word	2		; frame 9  (54 segments)
	.word	67,106,5,4	; RN6BOLT9A
	.word	0,9
	.word	7,6
	.word	10,7
	.word	14,3
	.word	82,99,4,4	; RN6BOLT9B
	.word	5,0
	.word	3,4
	.word	3,12
	.word	0,16
	.word	2		; frame 10  (46 segments)
	.word	65,105,5,4	; RN6BOLT10A
	.word	0,10
	.word	2,8
	.word	8,8
	.word	12,4
	.word	78,99,4,3	; RN6BOLT10B
	.word	3,0
	.word	2,12
	.word	0,15
	.word	3		; frame 11  (20 segments)
	.word	63,105,2,2	; RN6BOLT11A
	.word	6,0
	.word	1,7
	.word	63,105,2,2	; RN6BOLT11A
	.word	2,10
	.word	6,9
	.word	70,99,3,3	; RN6BOLT11B
	.word	3,0
	.word	3,11
	.word	0,15
	.word	1		; frame 12  (4 segments)
	.word	62,99,2,2	; RN6BOLT12A
	.word	4,0
	.word	3,12

	.text
	.global	bolt_geo_emit,bolt_geo_frames

*
* Bolt stroke colours, as geo_pass wants them: [colour map | pen].
*
*   bits 0-7    pen index within the map (only the low PSIZE=8 bits are used)
*   bits 16-31  the colour map, written to dmacmap for the segment
*
* These used to be 0FFFFFFFFh and 09C9C9C9Ch on the theory that the frame
* buffer holds a raw 6-bit index into whatever costume palette is loaded, so
* 62/63 would follow the alternate costumes for free.  It does not: a CPU
* pixel is OR-ed with the DMA colour-map latch on its way to VRAM, so the
* palette a bolt landed in was simply whichever sprite the blitter drew last
* that frame.  That is why they came out solid white regardless of the value
* here - 0FFh is not in any 64-entry map, and the map itself was a lottery.
*
* Map 0 (boonpal) is pinned for the life of the machine and holds named
* colours, so the pair is now explicit and deterministic: white core, blue
* border, matching the RADBOLT art it replaced.  Following the COSTUME
* palette is still possible - put Raiden's opal in the high half instead -
* but it has to be read from his object and plumbed through here, not
* assumed.
*
BGEO_COL	.set	00000000eh	; core stroke  - map 0, bpal_white
BGEO_OUT	.set	00000000bh	; outer stroke - map 0, bpal_blue
GEO_LIMIT	.set	248		; leave headroom under MKDISP's GEO_MAX

	.bss	bge_rx,16		; Raiden screen x for this emit
	.bss	bge_ry,16		; Raiden screen y for this emit
	.global	bge_rx,bge_ry		; exported so a harness can see whether
					;   the bolt is really tracking him

**************************************************************************
*												*
* bolt_geo_emit - draw one frame of one ambient bolt style			*
*												*
* Walks the MEASURED joint list for that frame and strokes it.  There is	*
* no randomness anywhere in here on purpose: the six styles are smooth	*
* deterministic animations and the joints in the table ARE the shape the	*
* art draws.  An earlier version scribbled a random zigzag inside each	*
* box, which read as static rather than as a bolt travelling a path.	*
*												*
* in:  a0 = style 0..5, a1 = frame index, a2 = Raiden screen x,		*
*      a3 = Raiden screen y (his anchor; boxes run +y DOWNWARD)		*
* out: geo_count / geo_list filled.  a0-a8 destroyed; a9-a13 preserved.	*
*												*
**************************************************************************
bolt_geo_emit
	mmtm	sp,a9,a10,a11,a12,a13
	move	a2,@bge_rx,w
	move	a3,@bge_ry,w

	sll	5,a0
	addi	bolt_geo_tab,a0
	move	*a0,a4,l		; a4 -> style block
	move	*a4+,a5,w		; frame count
	cmp	a5,a1
	jrhs	bge_none

	move	a1,a6
	jrz	bge_at
bge_fskip
	move	*a4+,a5,w		; pieces in the frame we are skipping
bge_pskip
	move	*a4+,a0,w		; dx
	move	*a4+,a0,w		; dy
	move	*a4+,a0,w		; thick
	move	*a4+,a0,w		; njoints
	sll	5,a0			; 2 words per joint
	add	a0,a4
	dsj	a5,bge_pskip
	dsj	a6,bge_fskip
bge_at
	move	*a4+,a6,w		; a6 = pieces this frame
	jrz	bge_none
	movi	geo_list,a12
	clr	a11

bge_piece
	move	*a4+,a0,w		; dx
	sext	a0,0
	move	@bge_rx,a1,w
	sext	a1,0
	add	a1,a0
	move	a0,a7			; a7 = box origin x
	move	*a4+,a0,w		; dy
	sext	a0,0
	move	@bge_ry,a1,w
	sext	a1,0
	add	a1,a0
	move	a0,a8			; a8 = box origin y
	move	*a4+,a10,w		; a10 = stroke thickness
	move	*a4+,a9,w		; a9 = joint count

	move	*a4+,a0,w		; first joint -> current point
	add	a7,a0
	move	*a4+,a1,w
	add	a8,a1
	dec	a9			; segments = joints - 1
	jrle	bge_pnext
bge_seg
	move	*a4+,a2,w
	add	a7,a2
	move	*a4+,a3,w
	add	a8,a3
	callr	bge_thick
	move	a2,a0
	move	a3,a1
	dsj	a9,bge_seg
bge_pnext
	dsj	a6,bge_piece

	move	a11,@geo_count,w
	mmfm	sp,a9,a10,a11,a12,a13
	rets

bge_none
	clr	a0
	move	a0,@geo_count,w
	mmfm	sp,a9,a10,a11,a12,a13
	rets


**************************************************************************
*												*
* bge_thick - stroke (a0,a1)-(a2,a3) a10 pixels wide				*
*												*
* The offsets go across the segment, not always in y: a near-vertical	*
* piece offset vertically would still draw one pixel wide.  RN4 in		*
* particular is 11x36 pieces, so this matters.				*
*												*
* Two colour passes, outer then core, the way the art is painted.		*
*												*
**************************************************************************
bge_thick
	mmtm	sp,a0,a1,a2,a3,a4,a5,a6,a13

	move	a2,a4
	sub	a0,a4
	abs	a4			; |dx|
	move	a3,a5
	sub	a1,a5
	abs	a5			; |dy|
	cmp	a5,a4
	jrlt	bt_xaxis		; steeper than wide -> offset in x

* offset in y
	move	a10,a6			; loop count
	move	a10,a5
	srl	1,a5
	neg	a5			; a5 = first offset
bt_ylp
	cmpi	GEO_LIMIT,a11
	jrhs	bt_x
	move	a1,a13
	add	a5,a1
	add	a5,a3
	callr	bge_put1
	sub	a5,a3
	move	a13,a1
	inc	a5
	dsj	a6,bt_ylp
	jruc	bt_x

* offset in x
bt_xaxis
	move	a10,a6
	move	a10,a5
	srl	1,a5
	neg	a5
bt_xlp
	cmpi	GEO_LIMIT,a11
	jrhs	bt_x
	move	a0,a13
	add	a5,a0
	add	a5,a2
	callr	bge_put1
	sub	a5,a2
	move	a13,a0
	inc	a5
	dsj	a6,bt_xlp
bt_x
	mmfm	sp,a0,a1,a2,a3,a4,a5,a6,a13
	rets

*
* bge_put1 - one segment (a0,a1)->(a2,a3), outer pass then core pass.
* Writes [colour, start y:x, dy:dx] triples exactly as geo_pass expects.
*
bge_put1
	mmtm	sp,a4,a5
	movi	BGEO_OUT,a4
	move	a4,@bge_col,l
	callr	bge_put_one
	movi	BGEO_COL,a4
	move	a4,@bge_col,l
	callr	bge_put_one
	mmfm	sp,a4,a5
	rets

bge_put_one
	cmpi	GEO_LIMIT,a11
	jrhs	bpo_x
	move	@bge_col,a4,l
	move	a4,*a12+,l		; colour

	move	a1,a4			; start, packed y:x
	sll	16,a4
	move	a0,a5
	andi	0ffffh,a5
	or	a5,a4
	move	a4,*a12+,l

	move	a3,a4			; delta, packed dy:dx
	sub	a1,a4
	sll	16,a4
	move	a2,a5
	sub	a0,a5
	andi	0ffffh,a5
	or	a5,a4
	move	a4,*a12+,l

	inc	a11
bpo_x
	rets

*
* bolt_geo_frames - a0 = number of frames in style a0 (0..5)
*
bolt_geo_frames
	sll	5,a0
	addi	bolt_geo_tab,a0
	move	*a0,a0,l
	move	*a0,a0,w
	rets

