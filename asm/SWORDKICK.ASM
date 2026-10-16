; IMGTOOL World View fatality sequence draft
; One lane is one actor/object animation table.
; Delay ticks are encoded by repeating that frame label.
; Hidden entries export as 0 until their Show@ preview tick.
; Each *_local_anipts table is aligned 1:1 with the .long rows.
; Run these lanes at the same animation sleep/FPS used in the preview.

; Slot 1  [0] UGMO9.IMG  11 frames  stop-on-final
a_imgtool_slot1_ugmo9
	.long	UGSTANCE1	; UGSTANCE1 delay x1 dAX=157 dAY=-6
	.long	UGSWORDKICK1	; UGSWORDKICK1 delay x1 dAX=169 dAY=-5
	.long	UGSWORDKICK2	; UGSWORDKICK2 delay x1 dAX=168 dAY=-4
	.long	UGSWORDKICK3	; UGSWORDKICK3 delay x1 dAX=178 dAY=-47
	.long	UGSWORDKICK4	; UGSWORDKICK4 delay x1 dAX=166 dAY=-59
	.long	UGSWORDKICK6	; UGSWORDKICK6 delay x3 dAX=65 dAY=-47
	.long	UGSWORDKICK6
	.long	UGSWORDKICK6
	.long	UGSWORDKICK5	; UGSWORDKICK5 delay x1 dAX=132 dAY=-50
	.long	UGSWORDKICK2	; UGSWORDKICK2 delay x1 dAX=168 dAY=-4
	.long	UGSWORDKICK3	; UGSWORDKICK3 delay x1 dAX=178 dAY=-47
	.long	UGSWORDKICK1	; UGSWORDKICK1 delay x1 dAX=169 dAY=-5
	.long	UGSTANCE1	; UGSTANCE1 delay x1 dAX=157 dAY=-6
	.long	0	; stop on final frame

a_imgtool_slot1_ugmo9_local_anipts
	.word	157,-6	; tick 0 UGSTANCE1
	.word	169,-5	; tick 1 UGSWORDKICK1
	.word	168,-4	; tick 2 UGSWORDKICK2
	.word	178,-47	; tick 3 UGSWORDKICK3
	.word	166,-59	; tick 4 UGSWORDKICK4
	.word	65,-47	; tick 5 UGSWORDKICK6
	.word	65,-47	; tick 6 UGSWORDKICK6
	.word	65,-47	; tick 7 UGSWORDKICK6
	.word	132,-50	; tick 8 UGSWORDKICK5
	.word	168,-4	; tick 9 UGSWORDKICK2
	.word	178,-47	; tick 10 UGSWORDKICK3
	.word	169,-5	; tick 11 UGSWORDKICK1
	.word	157,-6	; tick 12 UGSTANCE1

; Slot 2  [1] HATHED9.IMG  11 frames  stop-on-final
; Preview mirror is enabled; spawn/draw this object mirrored in routine code.
a_imgtool_slot2_hathed9
	.long	TMSTANCE1	; TMSTANCE1 delay x5
	.long	TMSTANCE1
	.long	TMSTANCE1
	.long	TMSTANCE1
	.long	TMSTANCE1
	.long	TMSTANCE1	; TMSTANCE1 delay x1 dAX=0 dAY=-11
	.long	TMSTANCE1	; TMSTANCE1 delay x1
	.long	TMSTANCE1	; TMSTANCE1 delay x1 dAX=0 dAY=-11
	.long	TMFLIPPED1	; TMFLIPPED1 delay x1 dAX=-104 dAY=-2
	.long	TMFLIPPED2	; TMFLIPPED2 delay x1 dAX=-179 dAY=-18
	.long	TMFLIPPED3	; TMFLIPPED3 delay x1 dAX=-261 dAY=-57
	.long	TMFLIPPED4	; TMFLIPPED4 delay x1 dAX=-290 dAY=-51
	.long	TMFLIPPED5	; TMFLIPPED5 delay x1 dAX=-298 dAY=-39
	.long	TMFLIPPED5	; TMFLIPPED5 delay x1 dAX=-296 dAY=-28
	.long	TMFLIPPED5	; TMFLIPPED5 delay x1 dAX=-298 dAY=-39
	.long	0	; stop on final frame

a_imgtool_slot2_hathed9_local_anipts
	.word	0,0	; tick 0 TMSTANCE1
	.word	0,0	; tick 1 TMSTANCE1
	.word	0,0	; tick 2 TMSTANCE1
	.word	0,0	; tick 3 TMSTANCE1
	.word	0,0	; tick 4 TMSTANCE1
	.word	0,-11	; tick 5 TMSTANCE1
	.word	0,0	; tick 6 TMSTANCE1
	.word	0,-11	; tick 7 TMSTANCE1
	.word	-104,-2	; tick 8 TMFLIPPED1
	.word	-179,-18	; tick 9 TMFLIPPED2
	.word	-261,-57	; tick 10 TMFLIPPED3
	.word	-290,-51	; tick 11 TMFLIPPED4
	.word	-298,-39	; tick 12 TMFLIPPED5
	.word	-296,-28	; tick 13 TMFLIPPED5
	.word	-298,-39	; tick 14 TMFLIPPED5

