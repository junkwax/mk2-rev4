# Freeplay / FBNeo Refactoring Notes

This repo's ROM changes should optimize for deterministic FBNeo/libretro
integration before broad arcade-engine rewrites. FBNeo already runs MK2 fast
enough; most "smoothness" wins come from making address drift, crashes, object
storms, and custom-content hooks easier to diagnose.

## Implemented Guardrails

### Freeplay address export

`python tools/export_freeplay_addresses.py` reads `src/mk2.map` and writes:

- `tmp/freeplay_addresses.json`
- `tmp/freeplay_addresses.rs`

The Rust file contains FBNeo `RETRO_MEMORY_SYSTEM_RAM` offsets for Freeplay:
health, score, gstate, netplay sync, lab reset coordinates, and perf-probe list
anchors. `build.py` runs this as Phase E after a successful link.

Freeplay should consume the generated values through `src/mk2_addrs.rs` instead
of duplicating literal MK2 RAM offsets in its trainer, netplay checksum, score,
replay, lab, and drone modules.

The current Freeplay integration also includes a read-only `mk2_perf` sampler
that walks MK2's active/free process lists, the three foreground object lists,
and the eight background object lists. When the net-stats overlay is visible,
it adds rows for process pressure, foreground/background object pressure, free
object blocks, named list-walk warnings, and the MK2 `overload` counter.

The manifest also exports existing MK2 visual-cost flags for a deterministic
low-FX profile:

- `NO_BLOOD_FLAG_ADDR` (`f_no_blood`)
- `NO_VIOLENCE_FLAG_ADDR` (`f_no_violence`)
- `SHADOWS_FLAG_ADDR` (`f_shadows`)
- `GROUND_SKEW_FLAG_ADDR` (`f_skew`)

Use this instead of hand-walking `RAM.ASM` whenever `RAM.ASM` or BSS layout
changes. To copy directly into a Freeplay checkout after validation:

```powershell
python tools\export_freeplay_addresses.py --rom rom\mk2.zip --rust-out ..\freeplay-gametalk\src\mk2_addrs.rs
copy /y rom\mk2.zip ..\freeplay-gametalk\mk2.zip
```

Do not update Freeplay constants from a ROM that has not been rebuilt and tested.

`--rom` is not optional in practice: it records `SOURCE_ROM_FNV`, which
`mk2_addr_check` compares against the player's zip, and which
`netcore::set_netplay_flag` consults before writing `f_netplay`. Without it
the pairing goes unchecked. The hash changes on **every** `mamerom.py` run
- `crc_spoof` rewrites four padding bytes per program chip each repackage -
so export the table and copy the zip together, as the last step of a build.
The client lives in `Workplace/freeplay-gametalk`; `Workplace/freeplay` is a
retired v0.7 tree.

### Safe fatality prop palette pattern

Fatality props should use explicit palette assignment after object creation.
Do not copy another object's full `oflags2` onto a single-sprite prop; that word
contains non-palette state such as `m_multipart`, `m_shadow`, and `m_inviso`.

Current local helper in `MKDEATH.ASM`:

```asm
* input: a5 = image header, a0 = palette label
gso_dmawnz_pal
	push	a0
	calla	gso_dmawnz
	pull	a0
	jauc	swpal
```

Use that pattern for single fatality props that need a fixed palette.

## Crash Reporting To GitHub Issues

The Freeplay client already writes local crash logs and can upload incidents to
the signaling server. A public client should not create GitHub issues directly,
because that would require shipping a GitHub token.

Safe path:

1. Client writes a local crash log and uploads an incident to the backend.
2. Backend stores full logs privately.
3. Backend deduplicates crashes by app version, ROM hash, panic location, and
   stack fingerprint.
4. Backend or a GitHub Action creates/updates a GitHub issue using a repository
   secret.
5. Public issue includes only sanitized details:
   - app version/build date/git hash
   - ROM hash, not ROM data
   - panic summary/location
   - incident id
   - short redacted log tail
   - repro breadcrumbs when available

Never publish ROM contents, savestates, user tokens, full config files, relay
credentials, private endpoints, or player IP addresses in GitHub issues.

## Next Refactors

- Commit the generated Freeplay `src/mk2_addrs.rs` and `src/mk2_perf.rs`
  integration so it survives checkout/cleanup operations.
- Add a negotiated Freeplay low-FX toggle that sets both peers to the same
  values for blood/shadow flags before netplay starts.
- Route new custom fatality/projectile props through small helpers that make
  ownership validation and explicit palettes the default.
- Add optional FX density caps only after perf traces show object pressure
  during real FBNeo/freeplay sessions.

## Avoid

- Moving `yzsort` relative to the display interrupt.
- Changing process/object struct offsets.
- Copying full `oflags2` between unrelated object types.
- Direct client-to-GitHub issue creation with a bundled token.
