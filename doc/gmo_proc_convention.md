# `gmo_proc` Register Convention

## The trap

After calling `gmo_proc`, the natural assumption is:
- `a0` = the new overlay object (return value)
- `a8` = unchanged (still your player/character object)

**Both are wrong.**

After `gmo_proc` returns successfully:
- `a0` = the dummy *process* it spawned (for multipart RAM storage)
- `a8` = the new overlay *object* it allocated

`gmo_proc` calls `getprc` (result in a0), then internally calls `object_setup` which calls
`getobj` and stores the result in a8, overwriting whatever was there.

## What to do right after `gmo_proc`

```asm
    ; save player object before calling
    move    a8,a11              ; keep player object in a11 (or push to sp before)

    calla   get_char_ani2       ; a9 = overlay animation
    calla   gmo_proc            ; a8 = new overlay obj, a0 = dummy proc
    move    a8,a10              ; save overlay object
    move    a0,*a8(oslink),l    ; link proc -> overlay obj (kmo_proc needs this)
    move    a11,a8              ; restore player object
    calla   match_ani_points    ; position overlay (a0=overlay) rel to player (a8)
    ...
    move    a10,a0
    calla   insobj              ; insert overlay into display list
```

The canonical example in the codebase is `victory_lighting` in `MKCANNED.ASM`.

## `kmo_proc` cleanup

When you're done with the overlay, pass the overlay *object* (not the process) in `a2`:

```asm
    move    a10,a2
    calla   kmo_proc        ; kills dummy proc via a2(oslink), then deletes object
```

`kmo_proc` reads `*a2(oslink)` to find the process, kills it, then kills the object.
The oslink connection is established by `move a0,*a8(oslink),l` immediately after
`gmo_proc` (where a8 is the new overlay object and a0 is the dummy proc).

## How this crash manifested

In `do_hh_elbow_glow` (MOVES.ASM), the line was:

```asm
    move    a0,a10          ; BUG: a0 is the dummy process, not the overlay object
```

`a10` then held a process pointer. `double_next_a9` used `a10` as the second display
object, calling `ani2` on it. `ani2` reads `*a8(oimg)` to get the multipart RAM
pointer, then reads SAG values from it. Process RAM at those offsets contains garbage,
producing a SAG like `0x0600da22` — just past the end of the 12 MB video ROM — causing
MAME's `dma_draw` to ACCESS VIOLATION.

The fix: `move a8,a10` (capture the new overlay object, not the process).

## `delete_slave` must be safe against stale pointers and kill the dummy proc

`delete_slave` (MKUTIL.ASM) is called by `back_to_normal` whenever a character exits a move
(hit reaction, round end, etc.). The original version called `delobjp` directly:

```asm
; ORIGINAL — leaked the dummy proc and crashed on stale pointers:
delete_slave
    move    *a13(p_slave),a0,l
    jreq    dels2
    callr   delobjp             ; frees the object but NOT the gmo dummy proc
```

Any slave created via `get_proj_obj_m` / `gmo_proc` has a dummy process linked through
`oslink`. Original `delete_slave` left the dummy proc running in the active list forever.

More critically, during round transitions, `MAIN.ASM` calls `dallobj`, which removes all objects from `objlst` and frees them. However, it does NOT clear the `p_slave` pointer in the character process blocks. The next time `back_to_normal` is called, `delete_slave` attempts to call `delobjp` on an object that is no longer in `objlst`. When `delobj` fails to find the object in `objlst`, it calls `lockup` which eventually triggers a system restart (`jauc recovery`) causing a visible crash in the middle of a game (often jumping the PC to unexpected places like `FF8E8650`).

**Fix** — Safely verify both the object and the dummy process still exist before deleting:

```asm
delete_slave
    move    *a13(p_slave),a0,l    ; slave object ?
    jreq    dels_done              ; nope

    movi    objlst,a4,l            ; safe walk - is it still in objlst?
dels_obj_loop
    move    *a4,a4,l
    jreq    clear_slave_ram        ; NOT found (freed by dallobj) - just clear p_slave
    cmp     a4,a0
    jrne    dels_obj_loop

    ; object is in objlst - kill linked proc safely, then delete
    move    *a0(oslink),a1,l      ; linked gmo dummy proc?
    jreq    dels_delete_obj
    movi    active,a4,l            ; safe walk - is the proc still alive?
dels_proc_loop
    move    *a4,a4,l
    jreq    dels_delete_obj        ; proc already dead/freed - skip kill
    cmp     a4,a1
    jrne    dels_proc_loop
    move    a1,a0
    calla   kill                   ; proc found in active list - kill it
    move    *a13(p_slave),a0,l    ; reload a0 (kill trashes it)
dels_delete_obj
    calla   delobjp               ; remove object from objlst and free
clear_slave_ram
    clr     a0
    move    a0,*a13(p_slave),l    ; clear slave lw
dels_done
    rets
```

This prevents the process pool from exhausting over time and prevents `delobj` from locking up on stale pointers left behind by `dallobj`.

### How this manifested as the Reptile air acid spit crash

Reptile's `do_rp_airspit` creates a face overlay via `get_proj_obj_m` (gmo_proc internally),
inserts it into `objlst`, and animates it for ~8 ticks while winding up. If the CPU Reptile
is hit during that window, `fastxfer` redirects the character process to a hit reaction.
`back_to_normal` → `delete_slave` frees the face overlay *object* but leaves the dummy proc
alive. Additionally, if a round transition happens while the face overlay is active, `dallobj` frees the object but leaves `p_slave` populated, leading to a system lockup crash in round 2 when `back_to_normal` is finally called. The CPU does air spits on nearly every jump and is frequently hit mid-windup, making it highly susceptible to both the leak and the crash.


## `get_proj_obj_m` does it correctly

`MKZAP.ASM:get_proj_obj_m` is the reference implementation for projectile overlays:

```asm
get_proj_obj_m
    push    a8                      ; save thrower
    calla   gmo_proc                ; a8 = new obj, a0 = proc
    move    a8,a10                  ; a10 = overlay object  ← correct
    jreq    gpo_m_fail
    move    a0,*a8(oslink),l        ; oslink = proc
    pull    a8                      ; restore thrower
    ...
```
