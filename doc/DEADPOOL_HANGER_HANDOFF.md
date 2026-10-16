# Dead Pool Hanging Bodies Handoff

Date: 2026-06-02

This is the handoff for the Dead Pool hanging-body / acid-pool animation work.

## Current User-Visible Problem

The pull-up still has a huge visible chain gap. The chain needs to visually stay connected behind the body/skeleton during the pull-up, while still stopping at the same hard Y line where the body sections disappear into the acid.

The latest user direction:

- Pull-up jumps too far visually.
- Chain needs to go down to the same hard Y axis where the body/subframes stop.
- Bubble graphics should appear in front of the body while it is going into the acid so the subframe cutoff does not look like a hard line.
- Do not hide the whole body at once. The sprites are sectioned/subframed; lower sections should disappear progressively.

## Files Actively Edited For This Work

Only this source file is the active code-change target:

- `src/MKHANG.ASM`

Other dirty files currently in the tree should be treated as pre-existing/user/other-agent changes unless proven otherwise:

- `data/HATHED9.IMG`
- `data/MK1SHANG.IMG`
- `data/imgui.ini`
- `src/BGNDTBL.ASM`
- `src/DIAGMENU.ASM`
- `src/SWORDKICK.ASM` untracked

Do not revert those unrelated files.

## Current MKHANG Areas To Inspect

Important constants near the top of `src/MKHANG.ASM`:

```asm
hbody_chain_ofs        .equ -211
acid_pull_line_y       .equ 068h
acid_lower_mask_y      .equ acid_pull_line_y
acid_body_hide_y       .equ 0a8h
acid_fx_y              .equ 0b8h
acid_ripple_y          .equ 0b8h
acid_simmer_loops      .equ 5
rise_step              .equ 2
rise_ticks             .equ 4
lower_bubble_mask      .equ 03h
acid_rise_start        .equ 0c0h
acid_rise_stop         .equ 090h
acid_skel_show_y       .equ acid_rise_start
acid_hook_clamp_y      .equ acid_pull_line_y
hanger_fx_enable       .equ 1
hanger_drip_enable     .equ 0
hanger_rise_ripple_enable .equ 0
hanger_rise_bubble_enable .equ 0
```

Important routines:

- `hp_update_chain`
- `hp_place_skel_pull`
- `hp_maybe_show_skel`
- `hp_lower_section_shape`
- `hp_lower_bubble_fx`
- `hp_lift_bubble_fx`
- `ripple_proc`
- `a_pooldrip`

Current `hp_update_chain` uses `longchain`, `TINCHAIN4`, and `TINHOOK`. The short `TINCHAIN4` connector fills the pull-up gap while `TINHOOK` remains hidden until it can clear the acid/floor lip.

## Current Chain Behavior

`longchain` is 211 pixels tall according to `src/MKCHUNKS.TBL`, so `hbody_chain_ofs = -211` was chosen to make:

```text
chain_bottom = acid_pull_line_y
chain_top    = acid_pull_line_y - 211
```

The latest all-drop log showed examples like:

```text
chain=(277,-107,-9)
```

Since `-107 + 211 = 104`, and `acid_pull_line_y = 0x68 = 104`, the math says the chain bottom is exactly on the hard acid line. The visual gap means the chain probably needs a different visual treatment during pull-up, not just different math.

Likely next fix target:

- Keep chain X locked to the original drop/pickup anchor.
- Keep chain bottom at the hard acid line.
- Keep the `TINCHAIN4` connector behind the rising skeleton/body without letting the chain or hook drift.
- Keep `TINHOOK` hidden until it will not appear on the floor or pull the chain out of center.
- Do not move the skeleton/body to chase the hook; keep the acid-body X/Y locked to the drop anchor.

## Current Body/Subframe Behavior

The old bad behavior was hiding the whole body at once. Do not return to that.

`hp_lower_section_shape` now rebuilds the multipart body and terminates the multipart RAM after the visible top strips. This makes the lower strips disappear progressively as the body lowers into the acid.

The body should stop bleeding through the floor/walkway before it reaches the floor. Current relevant values:

```asm
acid_lower_mask_y .equ acid_pull_line_y
acid_body_hide_y  .equ 0a8h
```

## Current Bubble/Ripple Behavior

Lowering bubbles were increased so the hard line is masked better:

- `lower_bubble_mask .equ 03h` means a boil every 4 lowering steps.
- `hp_lower_bubble_fx` spawns a centered shallow bubble plus a staggered side bubble.

Rise-loop ripple/bubble effects are currently disabled:

```asm
hanger_rise_ripple_enable .equ 0
hanger_rise_bubble_enable .equ 0
```

Reason: live rise-loop `pooldrip` / `BUBL` child processes previously stalled the parent hanger process during pull-up. With those disabled, all drops completed in the harness.

Drips are also currently disabled:

```asm
hanger_drip_enable .equ 0
```

## Lua/MAME Scripts Used

Main/current harness:

- `tmp/dp/all_drop_visual.lua`
  - Logs to `tmp/dp/all_drop_visual.log`
  - Last successful run ended with `ALL_DONE ok`

Other Dead Pool temp harnesses/probes in `tmp/dp`:

- `all_drop_stress.lua`
- `all_hangers_probe.lua`
- `chain_contact_capture.lua`
- `drip_tune_capture.lua`
- `fx_capture.lua`
- `fx_probe.lua`
- `jeff_probe.lua`
- `layout_sweep_capture.lua`
- `lift_tail_capture.lua`
- `min_autoboot.lua`
- `persist_probe.lua`
- `rise_debug.lua`
- `single_drop_stress.lua`
- `visual_tune_capture.lua`

Older tool-side Dead Pool scripts:

- `tools/deadpool_chain_test.lua`
- `tools/dp_capture_drop_screens.lua`
- `tools/dp_codex_drop_probe.lua`
- `tools/dp_layout_capture.lua`
- `tools/dp_snap.lua`
- `tools/dp_stagger_probe.lua`

## Latest Test Artifacts

- `tmp/dp/all_drop_visual.log`
- `tmp/dp/all_drop_contact_pullfix.png`

The latest all-drop test passed mechanically, but the visual chain gap still needs tuning.

## Build And Test Commands

Assembler/program rebuild:

```powershell
python build.py --asm-only
python makerom.py
python mamerom.py
```

MAME command used for the all-drop harness:

```powershell
C:\MAME\mame.exe -rompath C:\MAME\roms mk2 -window -nomaximize -keyboardprovider win32 -skip_gameinfo -autoboot_script C:/Users/you/Workplace/mk2-main/tmp/dp/all_drop_visual.lua
```

If the MAME info dialog does not dismiss, use forced focus plus Win32 keyboard provider. Previous successful approach used `-keyboardprovider win32` and injected space after focusing the MAME window with `AttachThreadInput`.

## Address Debugging Note

For this MAME/TMS34010 Lua setup, reads used raw bit addresses from `mk2.map`, not byte-address divided values. Earlier diagnostics were wrong until this was corrected.

Examples from prior probing:

- `gstate` bit address `0x01129DC0`
- `curback` bit address `0x0112B6C0`

## Current Recommendation For Next Agent

Start with the visual chain gap. Do not change the whole acid sequence at once.

Suggested approach:

1. Capture pull-up frames for one hanger with `tmp/dp/all_drop_visual.lua` or `tmp/dp/chain_contact_capture.lua`.
2. Inspect `hp_update_chain` and confirm whether the gap is because `TINHOOK` is hidden and `longchain` alone does not visually reach the head/neck.
3. Try a minimal connection fix:
   - Keep chain X locked.
   - Keep chain bottom on `acid_pull_line_y`.
   - Keep chain behind the body/skeleton.
   - Avoid reintroducing floor hooks.
4. Rebuild and rerun all drops.
5. Confirm `ALL_DONE ok` and visually inspect `tmp/dp/all_drop_contact_pullfix.png` or a new contact sheet.

Do not regress the progressive subframe disappearance. That is the main thing the user explicitly called out.
