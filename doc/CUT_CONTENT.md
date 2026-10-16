# MK2 Cut Content — Restoration Notes

Two fully-stubbed moves that were disabled before shipping. Both have working
animation tables, infrastructure, and partial code already in the source.

---

## 1. Raiden Superman Dive

### What it was

A propelled flight move for Raiden — he launches forward in a horizontal dive
pose toward the opponent, hitting them in mid-air or on landing. Named
"Superman dive" in the animation table comment.

### Evidence in source

**MOVES.ASM ~2253** — the MOVES.ASM entry point, commented out:
```asm
;do_raiden_dive
;   movk    00ch,a0
;   jruc    do_propell_a0
```

**MKPROP.ASM line 49** — `propell_table[0x0C]` slot reserved but dead:
```asm
.long   reaction_exit   ; c   ← was do_raiden_dive
```

The slot exists between `do_square_wave` (0x0B) and `do_raiden_melt` (0x0D),
which is exactly where this comment-out sits in MOVES.ASM.

### Animation — fully defined, in video ROM

`rd_anitab2[0]` = `a_superman` ("Raiden Superman dive"), in `src/MKRD.ASM`:
```asm
rd_anitab2
    .long   a_superman    ; 0 - Raiden Superman dive
```

The animation is fully defined at MKRD.ASM ~1509:
```
a_superman
    .long   RNFLY1        ; wind-up / horizontal launch pose (3 sprites)
    .long   RNFLY2        ; extended flight (5 sprites)
    .long   0             ; ← mframew exits here (end of launch phase)
    .long   RNFLY3        ; recovery / landing
    .long   RNFLY4
    .long   0
```

`RNFLY1–4` are multi-part sprites (A/B/C layers) in the video ROM —
identical structure to the rest of Raiden's moves. The art is already
built and shipped in the retail ROM.

### What wiring it up requires

The `do_raiden_dive` stub in MOVES.ASM calls `do_propell_a0(0x0C)`, which
dispatches through `propell_table`. There is currently no implementation
behind that slot. Full wiring needs four changes:

**1. Write the implementation in `src/MKPROP.ASM`** (main work, ~30-50 lines)

Model on `do_reptile_superk` (index 0x3) — same pattern: air init, set
action code, get anitab2 animation, `flight_call` with x/y/gravity/scan.
Skeleton:
```asm
do_rn_dive
    calla   air_init_special

    movi    act_rn_dive,a1          ; need new action equate in MAINEQU.ASM
    move    a1,*a13(p_action),w

    clr     a9
    calla   get_char_ani2           ; a9 → a_superman (anitab2[0])

    movi    <x_vel>,a0              ; toward opponent
    movi    <y_vel>,a1              ; slight downward arc
    movi    <gravity>,a2
    movk    <duration>,a3
    movi    rn_dive_scan,a6
    jsrp    flight_call

    jsrp    do_land_animation
    jruc    local_reaction_exit

rn_dive_scan
    ; check strike during flight — model on super_reptile_scan
    ...
```

Suggested flight parameters (tune in MAME):
- x toward: `0x80000`
- y down: `0x30000`
- gravity: `0x6000`
- duration: `3` ticks

**2. Point `propell_table[0x0C]` at the implementation** (MKPROP.ASM line 49):
```asm
; before:
.long   reaction_exit       ; c
; after:
.long   do_rn_dive          ; c
```

**3. Uncomment the MOVES.ASM stub** (~line 2253):
```asm
do_raiden_dive
    movk    00ch,a0
    jruc    do_propell_a0
```

**4. Add input combo and call in Raiden's move handler** (MOVES.ASM)

Add a new `scom_*` entry to the combo table (down-back + HP is the
obvious candidate — mirrors real MK3 Raiden). In Raiden's hi-punch
handler, add a `restricted_xfer` call to `do_raiden_dive` after a
`combo_look_lr` check:
```asm
    movi    scom_rn_dive,a11
    callr   combo_look_lr
    jrnc    <next_check>
    movi    do_raiden_dive,a7
    jruc    restricted_xfer
```

**5. Add `act_rn_dive` action equate** (MAINEQU.ASM)

Pick the next available `act_*` value and add it alongside the other
Raiden action codes.

### Feasibility

High. The animation art exists. The propell slot exists. The infrastructure
(`flight_call`, `do_land_animation`, strike scan pattern) is all present.
The implementation itself is ~30-50 lines modelled directly on
`do_reptile_superk`. No new art or image build needed — `a_superman` is
already in the video ROM.

---

## 2. Generic Head-Pop Reaction (`r_head_pop`)

### What it was

A **victim reaction handler** that decapitates any character — not just via
JC's fatality, but as a reaction any move could trigger. The victim switches
to their bloody palette, their head flies off as a `pid_head` process, and
the body freezes in the decap pose.

The existing JC fatality path (`r_hat_decap` → `cage_poped_fall` →
`decap_fall` → `tongued_fall`) is a full sequential animation with wobble,
kneel, and collapse. `r_head_pop` was an instant reaction: pose → bloody pal
→ detach head → freeze.

### Evidence in source

**MKDEATH.ASM ~1892** — commented-out reaction routine:
```asm
;r_head_pop
;   movi    03ch,a9             ; a_decapfall (slot 0x3C in all anitab1s)
;   calla   get_char_ani
;   calla   do_next_a9_frame    ; snap to first decap frame
;   calla   change_to_bloody_pal
;   create  pid_head,decapped_head
;   move    a8,*a0(pa10),l      ; pass body object to head proc
;   jauc    wait_forever        ; body freezes in decap pose
```

**MAINEQU.ASM line 479** — `decapped_head` global export commented out:
```asm
.global back_to_shang_form,tongued_fall,dizzy_dude  ;,decapped_head
```
This is the smoking gun — `decapped_head` is in MKCANNED.ASM but needs to
be globally exported for `r_head_pop` in MKDEATH.ASM to call it
cross-OBJ. When the reaction was disabled, the export was also commented.

### Animation tables — fully present in all characters

Animation slot `0x3C` = `a_decapfall` and slot `0x3D` = `a_head` exist in
every character's `anitab1`. Confirmed in `rd_anitab1`, `lk_anitab1`, and
all others:

```asm
.long   a_decapfall     ; 3c - decapitated dude fall
.long   a_head          ; 3d - decapitated head
```

The `decapped_head` process (MKCANNED.ASM ~510) uses `anitab1[0x3D]` to
get the per-character rolling-head animation, positions it at the neck via
`lineup_1pwm`, and runs it through `gravity_ani` — bounce, half-bounce,
second bounce — then `wait_forever`. It already respects `p_store1` for
the high-launch flag (Shang flip fatality variant).

Every character's art for both the headless-body fall (`a_decapfall`) and
the rolling head (`a_head`) is already in the video ROM.

### What wiring it up requires

**1. Uncomment `r_head_pop`** in MKDEATH.ASM (~line 1892) — 7 lines.

**2. Uncomment `,decapped_head`** in MAINEQU.ASM line 479 — one character:
```asm
; before:
.global back_to_shang_form,tongued_fall,dizzy_dude    ;,decapped_head
; after:
.global back_to_shang_form,tongued_fall,dizzy_dude    ,decapped_head
```

**3. Wire a move to use `r_head_pop` as its reaction**

The reaction is triggered by a move's `strike_routine` field in the strike
table (MKSTK.ASM). Set the target move's `strike_routine` to call
`r_head_pop`. The reaction system (`MKREACT.ASM`) dispatches victim
reactions through `rs_calls` per character, but `r_head_pop` is a hard
reaction — it would likely be triggered by the attacker's process calling
`xfer_otherguy` with `r_head_pop` as the target, similar to how
`tongued_fall` is called from `do_tongue_snag`.

Minimal viable test: add a call to `r_head_pop` from an existing fatal
move handler using `xfer_otherguy`:
```asm
movi    r_head_pop,a7
calla   xfer_otherguy
```

### Differences vs. existing decap path

| | `r_head_pop` (cut) | `decap_fall` (live) |
|---|---|---|
| Trigger | Any move via reaction system | JC fatality only |
| Body animation | Snap to pose, freeze | Wobble → kneel → collapse |
| Head | Same `decapped_head` process | Same `decapped_head` process |
| Duration | Instant freeze | ~6 seconds of animation |
| `change_to_bloody_pal` | Yes | Yes (in `tongued_fall`) |

### Feasibility

Very high. Only two uncomments needed before it compiles. The third step
(wiring it to a move) is one `xfer_otherguy` call. The art, the head
physics, and the bloody palette switch all exist and work. The only design
question is which move(s) should trigger it.

---

## Quick-start checklist

### Raiden dive
- [ ] Write `do_rn_dive` in MKPROP.ASM (~30-50 lines, model on `do_reptile_superk`)
- [ ] Add `act_rn_dive` equate to MAINEQU.ASM
- [ ] Point `propell_table[0x0C]` → `do_rn_dive` (MKPROP.ASM line 49)
- [ ] Uncomment `do_raiden_dive` stub (MOVES.ASM ~2253)
- [ ] Add `scom_rn_dive` combo + Raiden hi-punch handler check (MOVES.ASM)
- [ ] Build, test flight arc, tune x/y/gravity values in MAME

### Generic head-pop
- [ ] Uncomment `r_head_pop` body (MKDEATH.ASM ~1892)
- [ ] Uncomment `,decapped_head` export (MAINEQU.ASM line 479)
- [ ] Wire a move to call `r_head_pop` via `xfer_otherguy`
- [ ] Build and test
