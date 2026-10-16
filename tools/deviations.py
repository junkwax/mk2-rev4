#!/usr/bin/env python3
"""
deviations.py - generate doc/DEVIATIONS.md.

The project's purpose is a tournament build, which means straying from the
arcade on purpose. That is only defensible if every departure can be pointed
at and explained: what the arcade does, what this build does instead, what
evidence says the change is right, and what it costs.

This is that page. The switch VALUES are read from MAINEQU.ASM at generation
time so the document cannot claim one thing while the ROM does another; the
reasoning is curated here beside each one.

Retail behaviour is quoted from the read-only source at
Workplace/mk2-readonly/mk2-main - not inferred from our own switches being 0.
Rows marked "verified" were checked by reading that tree.

  python tools/deviations.py > doc/DEVIATIONS.md
"""
import importlib.util
import os
import pathlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
TICK_MS = 1000.0 / 54.7068


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BA = _load("ba", os.path.join(ROOT, "tools", "box_align_audit.py"))


def val(txt, name):
    m = re.search(r"^%s\s+\.set\s+(\S+)" % re.escape(name), txt, re.M)
    return m.group(1).strip() if m else None


# name, retail behaviour, what we do, why, evidence, cost / how to revert
ENTRIES = [
    ("dmgscale",
     "Every hit of a juggle does full damage. There is no scaling at all.",
     "The first hit of a string is full, then 3/4, then 1/2, then 1/4 for the "
     "fourth and beyond. A real hit never scales away to nothing.",
     "Rounds that end to one interaction are the complaint, and unscaled "
     "juggles are the mechanism. It resets on landing or blocking, so it "
     "limits juggles rather than taxing a whole round.",
     "Measured over 22 battles (`sweep_addon_phit.lua`): strings average "
     "2.1-3.4 hits and reach 5 in twenty of them. At a median non-boss hit of "
     "20 damage a five-hit string is 100 HP - 62% of the 161 bar - and 55, or "
     "34%, with the curve.",
     "`dmgscale 0` restores retail."),

    ("lkzapair",
     "Liu Kang's fireball is the one airborne reaction that does not apply "
     "the anti-juggle separation. Its handler `ar_lkzap` is "
     "`generic_airborn_hit`'s body minus the `no_unlimited_airhits` call.",
     "It calls it, like the other 43 airborne-checked reactions.",
     "The rule is applied at a funnel, not per reaction: "
     "`reaction_start_abc` raises a flag and `rst5` jumps an airborne victim "
     "to the handler in `a5`, the reaction's own script never running. "
     "`ar_lkzap` is retail's copy of the generic handler with one line "
     "missing - same velocities, same `flight`, same `land_on_my_back`, only "
     "the gravity deliberately different (`07000h` against `08000h`, which "
     "is left alone).",
     "Audited mechanically by `tools/extract_dev_comments.py --src src` "
     "(`audit_airborne`): 43 of 44 airborne-checked reactions separate, and "
     "this was the single gap. EXPECTED TO RARELY FIRE - `p_hit` is a juggle "
     "counter cleared on landing, on block and in `back_to_normal`, so it "
     "seldom reaches the 3 the routine tests. This is a consistency fix, not "
     "a balance lever, and is listed here as a deviation because the "
     "omission is retail's.",
     "`lkzapair 0` restores retail."),

    ("jaxzappid",
     "Jax's energy wave - ground and air - is spawned as `pid_proj1` "
     "whoever throws it, so a player-2 Jax's wave is a PLAYER-1 projectile.",
     "The wave goes in its thrower's own projectile slot, picked off the "
     "thrower's `oid` with `p1p2_pick`, like every other projectile in the "
     "game.",
     "Every other projectile takes its pid per player through "
     "`spawn_proj_proc` and `p1p2_proj_pids`, and two things key off that "
     "class. The CPU's scan (`get_his_proj_proc`) masks `procid & 0ff00h`, "
     "so a P1 CPU looking for `0800h` never saw a P2 Jax's wave - "
     "`wait_proj_spawn` timed out after 32 ticks and it stood up wherever "
     "the wave was. And Jade's boomerang and Noob's shadow and portal refuse "
     "a throw while their own EXACT slot is live, so a P2 wave in flight "
     "sat in P1's slot and locked a P1 Jade or Noob out of their projectile "
     "- human against human included, which is the netplay case. Not "
     "`spawn_proj_proc` itself: it rewrites `p_store1` with the thrower's "
     "object, and `jax_zap_proc` reads it as the thrower's proc.",
     "Found mining the leak's comments: retail's own note above the oid "
     "list - 'when adding more proc's for projectiles make sure you update "
     "wait_for_prj routine' - names a routine that no longer exists in "
     "either tree. The masked scans replaced it, and these two spawns are "
     "the only projectile spawns that never moved onto the per-player "
     "table (all 20 `p1p2_proj_pids` rows are 07xx/08xx). A P1 Jax was "
     "always tagged correctly and is unchanged; only a P2 Jax moves. "
     "Reptile's air spit is NOT affected - his row is `pid_orb1/2` (0702h).",
     "`jaxzappid 0` restores retail."),

    ("drnflipp",
     "The CPU's jump-in is always a flip kick. A `drone_flip_punch` exists in "
     "the leaked MKDRONE.ASM, commented out and called by nothing.",
     "A jump-in can carry a flip punch instead, on a per-difficulty roll "
     "(`rpt_flip_punch`, 0 at the two easiest levels up to 45% at the "
     "hardest), followed on landing by `dlf_press` - the sweep if it "
     "connected, otherwise walk in.",
     "Midway wrote the routine as a line-for-line twin of `drone_flip_kick` "
     "and shelved it, and the numbers say why: a flip punch is 16 where the "
     "kick is 26, and a jump punch is only worth throwing for what follows "
     "it. Retail's drone could not follow anything - an air move ends in "
     "`do_land_animation` and never returns to its caller. This build can "
     "(`drone_land_next`), so the punch arms the same landing follow-up the "
     "air projectiles use. It is a player's move with a player's follow-up; "
     "no drone-only physics. Two things are this tree's, not Midway's: it "
     "never swings while rising, and it asks the real strike box "
     "(`does_stk_reach`, stk 0ch) instead of their 128px constant, which is "
     "~48px past the punch's reach.",
     "Lives in MKDRNEW.ASM because MKDRONE.ASM is at GSPA's memory ceiling; "
     "MKDRONE's whole share is one `calla` and two names on an existing "
     "`.global` line, test-assembled in a scratch copy first. Kintaro and "
     "Shao Kahn are excluded (no flip punch in their strike tables), and the "
     "scripted juggles, which are built around a kick, never reach the roll.",
     "`drnflipp 0` restores retail's kick-only jump-in."),

    ("colwidth",
     "The hit column is the width `sq_punch`'s shifts leave: "
     "W - 2*((W>>3)+(W>>2)).",
     "The same width, measured out from the anipoint.",
     "Anchoring the column (see `anchorcol`) also changed its width, which was "
     "never the intent - `sq_punch`'s own comment claims the two branches keep "
     "the same quarter width, and truncation means they do not.",
     "Measured over every pose in the build: 757 of 869 (87%) got a NARROWER "
     "column than retail, mean 2.52px and up to 5, and not one got a wider "
     "one. So the anchoring fix also made the whole cast harder to hit - the "
     "opposite of its purpose. `tools/box_model_lab.py` puts the correction at "
     "3.16% of all hit/miss verdicts.",
     "`colwidth 0` restores the narrowed column."),

    ("backblock",
     "The block BUTTON is the only way to guard.",
     "Holding the stick away from the opponent guards as well, in addition to "
     "the button. Away+down guards low.",
     "It is PROXIMITY block, hooked into the question the strike path asks at "
     "the moment of contact and deliberately not into the stance loop - "
     "hooking the latter would make holding away enter the block pose instead "
     "of walking, which deletes backward walking from the game.",
     "Unblockables, airborne, low-block requirements and the CPU's own block "
     "path are all untouched, and when the button already says yes the new "
     "code does not run.",
     "`backblock 0` restores retail. Note it interacts with `blockspecial` "
     "below: holding the BUTTON kills every special-move motion, holding AWAY "
     "does not, so back-blocking is currently the only guard that leaves your "
     "specials available."),

    ("joyskip",
     "Every step of a special-move motion must match the very next stick "
     "input, with nothing in between.",
     "A step may walk over up to 2 non-matching inputs before giving up.",
     "The switch queue is EVENT based - one entry per switch closure - so a "
     "diagonal does not make a diagonal, it makes TWO entries. The spare one "
     "lands between the pattern's steps and kills the motion, which is why a "
     "sloppy roll drops a move that a clean one lands.",
     "Measured (`sweep_addon_droprate.lua`, A/B in one session): tapping Down "
     "between the two forwards of a Forward,Forward came out 0/4 before and "
     "4/4 after, with the control unchanged at 3/4 on both sides. Holding a "
     "direction was always free - a held direction makes no second entry.",
     "`joyskip 0` restores retail. The first step is anchored - it may not "
     "skip - and Shang's skulls are ordered longest-first, both because "
     "without them a short pattern reaches past the head of a longer one and "
     "wins; `tools/combo_collision_audit.py` is the gate and Phase D fails the "
     "build on any new collision."),

    ("socdfix",
     "Whatever the encoder sends reaches the game. Left+Right and Up+Down are "
     "undefined, because a lever cannot produce them.",
     "Latched once a tick and resolved: Back+Forward to neutral, Up+Down to "
     "Up.",
     "Leverless controllers can produce both, and what happened then was "
     "whatever the hardware did. In the ROM rather than the driver because the "
     "netplay layer transmits the port - a driver fix protects one cabinet, "
     "this protects the match.",
     "It also closes a real hazard: the port is hardware and was re-read on "
     "every access, so two processes in the same tick could see different "
     "stick states. Covers BOTH halves: the held stick through `p_joyport`, "
     "and the motions, because MKINIT's switch scan resolves the port before "
     "it diffs against last tick - so the closures that build the "
     "special-move queue are resolved too. The scan resolves for itself "
     "rather than reading the latch, because the latch is refreshed by the "
     "dispatcher and could be a tick behind it, which would put a frame of "
     "latency on every closure.",
     "`socdfix 0` restores the raw port."),

    ("blockspecial",
     "Holding BLOCK stops every special coming out - measured 0 of 4 against "
     "4 of 4 clean.",
     "Block is dropped from the button mask, so holding it no longer rejects "
     "a special-move motion. Measured after: 3 of 4, matching the control "
     "exactly.",
     "It was off because a block that cancels into a special is stronger than "
     "what the game ships with - true when written, and untrue the moment "
     "`backblock` shipped. Holding AWAY guards and never reaches button_mask, "
     "so that capability already exists. All this does is stop the block "
     "BUTTON being strictly worse than the stick, which is a trap rather than "
     "a design: players would simply stop pressing the one input that is "
     "unambiguous about wanting to block.",
     "The restriction is an artifact, not a rule. button_mask exists because "
     "combo_look_lr matches queue entries by exact state and a held button "
     "disturbs that - the same class of artifact `joyskip` fixes on the "
     "direction side. Nothing ever chose 'you may not special while "
     "blocking'. `hk_held` stays 0 of 4, so only block came out of the mask.",
     "`blockspecial 0` restores retail, and pairs with `backblock 0`."),

    ("saicool",
     "Mileena's sai has NOTHING between throws. fn2_hp_open checks that HP was "
     "HELD for 022h ticks and nothing else, and a hold requirement is not a "
     "rate limit - hold six tenths of a second, release, repeat.",
     "A cooldown of 040h*2 ticks, the same one Kitana's fan has carried all "
     "along twenty lines below it in the same file.",
     "It was the only projectile in the game with no limiter of any kind, and "
     "it was reported from play as easy to spam.",
     "UMK3 is the obvious place to look and its answer was different: recovery "
     "there is 37 ticks against our 32 - five ticks, not the nerf - while the "
     "INPUT goes through secret_move_search(sm_mil_hpo), a real motion, "
     "instead of a hold-and-release. That is the better fix and was not taken: "
     "changing the input is a control change, and held-HP is also how Kitana's "
     "and Jade's boomerangs are thrown here. A cooldown reaches the same rate "
     "limit while touching no animation, speed or recovery.",
     "`saicool 0` restores retail."),

    ("anchorcol",
     "The quarter-width hit column is centred on the victim's multipart "
     "BOUNDING BOX, which travels with his own limbs.",
     "Centred on his ANIPOINT (`oxpos`), which is stable under animation.",
     "The retail centre moves when the victim's arms do, so whether a move "
     "connects depends on the frame the *victim* happens to be showing. "
     "Retail already patches around this with a special case for "
     "`jade_nitro`; anchoring on the anipoint removes the cause instead of "
     "the symptom.",
     "Kept switchable so \"did this stop a move connecting?\" is a diff of two "
     "hit-ledger runs rather than an argument.",
     "`anchorcol 0` restores retail."),

    ("combo_slack",
     "No slack. A special-move motion must finish inside the window its "
     "combo record names.",
     "**Online only** (`combo_slack_online 1`): +6 ticks on every window while "
     "`f_netplay` is set. Offline and on a cabinet the build is retail-exact.",
     "Netplay adds input delay that the arcade never had. The compensation is "
     "for the wire, not for the player.",
     "This was previously a bare `addi 6,a9` with a comment saying \"netplay\" "
     "and **no test of f_netplay at all** - so cabinets and local matches got "
     "it too. Measured across the 90 combo records it is not uniform: +11% on "
     "the 56-tick windows most moves use, but **+38%** on the seven that use "
     "16 ticks, i.e. it helped most exactly where execution was meant to be "
     "hard. Gating it made the code do what its comment always claimed.",
     "`combo_slack_online 0` applies it everywhere - a deliberately more "
     "lenient build, which should then be stated in the move list."),

    ("twobtn_slack",
     "Two buttons \"at once\" must land within **2 ticks (37 ms)** and the "
     "partner must be the *immediately* previous entry in the switch queue. "
     "(verified)",
     "A 4-tick (73 ms) window, and the partner may sit up to `twobtn_depth` "
     "entries back.",
     "This is the only input in the game that is genuinely tight. Everything "
     "else measured is generous: a roll accepts up to 183 ms between "
     "inputs, a double-tap up to 293 ms. Two-button moves - Kitana's fan "
     "throw, Reptile's forceball - were the one place a normal hand fails.",
     "`tools/sweep_addon_twobtn.lua`, measured before and after: retail comes "
     "out 3/3 at a separation of 0-2 ticks and **0/3 at 3 or more**; with the "
     "change, 3/3 out to 4 and 0/3 at 5. The depth part matters as much as "
     "the window - one stray queue entry between the presses used to kill the "
     "input even inside 2 ticks.",
     "A wider window makes an LP->HP string thrown while holding forward "
     "likelier to come out as a fan. 2 ticks was chosen as roughly double "
     "retail rather than the largest number that felt good. `twobtn_slack 0` "
     "restores retail exactly."),

    ("secretwalk",
     "Smoke, Noob and Jade keep boss walk speed whoever is playing them - "
     "4.5 / 4.0 / 4.5 px per tick against 2.5 for most of the cast.",
     "A HUMAN playing them walks at the speed of the character they share a "
     "strike table with; the CPU keeps boss speed.",
     "Smoke and Noob share `nj_strikes` **byte for byte** with the ninjas "
     "(all 32 records) and Jade shares `fn_strikes` with the female ninjas "
     "(all 26). Identical moves plus strictly better movement, with nothing "
     "in the data paying for it. Boss scaling exists to make a secret "
     "OPPONENT hard, not to hand one player an edge in a two-player match.",
     "The damage half of exactly this was already gated by retail's own "
     "`xlate_secret`, which applies the 3/4 scaling only when the CPU is "
     "playing them. `get_walk_info_f`/`_b` had no such test at all. This "
     "mirrors a fix Boon had already made on the other axis.",
     "`secretwalk 0` restores retail."),

    ("rdshockai",
     "Raiden's electrocute grab (hold HP ~1.25s, release within 060h of a "
     "standing, non-blocking opponent) is refused outright unless the other "
     "player is a joystick. `rd_hp_open` calls `is_he_joy` and branches to "
     "`death` on a drone, so `do_raiden_shocker` is never reached in single "
     "player. **verified** - the two lines are in the leak, unchanged since "
     "the initial commit, comment and all: `; no zap on drones`.",
     "The joy test is compiled out. The move resolves against a CPU opponent "
     "on exactly the terms it resolves against a human.",
     "It reads as a bug to anyone without the source open: one of Raiden's "
     "specials silently does not exist in single player, with no whiff, no "
     "animation and no feedback saying why. Whatever the 1993 reason was - "
     "the `; sorry jeff !!` gate on the next line suggests a loop being "
     "papered over - that loop is closed by its own test, which stays.",
     "The move is self-limiting without the exemption. `do_raiden_shocker` "
     "checks blocking, airborne and x-distance (060h) and drops to "
     "`useless_shock` on any of them, which parks Raiden in `act_shocker_sd` "
     "- sd_punish_tier 3 in MKDRONE, so the drone punishes a whiff. The "
     "victim half was already exercised: `act_shock_sd` is reaction 613 in "
     "the drone table because the electrocute FATALITY reaches it (MKDEATH "
     "`raiden_post_shock`), and fatalities were never joy-gated.",
     "`rdshockai 0` restores retail. The re-shock guard below it "
     "(`act_shock_sd` -> `death`) is outside the switch and stays in both "
     "states."),

    ("hitbox",
     "No collision overlay exists.",
     "`f_colbox` compiles in a CPU-drawn hit/hurt box overlay.",
     "A development and dispute-resolution tool. It draws nothing unless "
     "`f_colbox` is written at runtime, so it does not affect play.",
     "Documented in doc/HITBOX_MODEL.md and doc/UNUSED_GRAPHICS_PRIMITIVES.md.",
     "Not a gameplay deviation. `hitbox 0` compiles it out entirely."),
    ("colnarrow",
     "A quarter of the victim's width is hittable. `sq_punch` squeezes the "
     "column on 205 of 223 strike records, so this is not an edge case - it "
     "is how the game normally decides a hit, and the rest of the fighter is "
     "scenery.",
     "A half. Same anchor, same everything else; the divisor moves 4 -> 2.",
     "The point-blank dead zone. Retail's uppercut starts 41px away for Jax "
     "and Cage, so standing ON someone and pressing down+HP whiffs - the "
     "column is behind the strike box's front edge. Losing a reversal because "
     "you were too CLOSE reads as the game breaking, not as spacing.",
     "Minimum connecting distance for the uppercut, retail -> now: Jax and "
     "Cage 41->28, Kung Lao 32->19, Baraka 23->19, Liu Kang 22->9, Raiden and "
     "the male ninjas 19->6, Shang 15->2, the female ninjas 9->0. Only the "
     "female ninjas lose the dead zone entirely; everyone else keeps a "
     "smaller one, which is why this is a dial and not `perpiece`. Far reach "
     "moves at most 1px. Over every move against every defender's stance and "
     "duck lanes at every distance - 10,968,880 comparisons - the quarter to "
     "a half moves 4.32% of verdicts, and it is PURELY ADDITIVE: 473,711 hits "
     "gained, 0 lost. Nothing that connected stops connecting. The high/low "
     "game is untouched, which was the risk worth checking: the same 119 of "
     "199 moves whiff over a crouch under both, with the same median window. "
     "One behaviour-lock case flipped, and it is the one "
     "this is for: `uppercut_point` at dist=12 went dmg=0 (no reaction at "
     "all) to dmg=40 with the same 0503h launch `uppercut_mid` produces. "
     "Reproduce with: box_model_lab.py ranges --models retail build --move "
     "duckpunch.",
     "`colnarrow 4` restores retail's quarter."),

    ("chipfloor",
     "Chip damage can kill - and it is worse than that. When chip WOULD be "
     "lethal, `strike_blocked` jumps to `block_is_useless` and throws the "
     "block away, so the victim takes the CLEAN hit instead. Retail's own "
     "comment on the branch is \"block or no ---> he's screwed!\".",
     "Chip cannot take the last point of health. The block holds, and the "
     "victim lives at 1.",
     "Not the usual chip-death argument. Retail does not just allow a chip "
     "kill, it makes blocking actively worse than standing there at exactly "
     "the moment blocking matters most - the same input that would have "
     "saved you at 20 HP kills you faster at 2. A tournament ruleset can "
     "argue either way about chip deaths; it cannot want the defensive "
     "option to be a trap.",
     "No behaviour-lock case blocks, so all 10 are unchanged, and the 25 "
     "battle stability sweep is clean. The change is one comparison on the "
     "lethal path - it cannot reach an unblocked hit.",
     "`chipfloor 0` restores retail, `block_is_useless` included."),

    ("crossfix",
     "A motion is judged in whatever facing is true when the MATCH runs. "
     "The queue stores raw physical directions, each combo carries two "
     "patterns (a face-right copy and a face-left copy 16*6 apart), and "
     "`combo_look_lr` picks one from a single live `is_he_right` at match "
     "time - so every entry is re-read in the current facing, including "
     "entries made before a crossup.",
     "Each entry is judged in the facing it was MADE in. The physical "
     "verdict is stamped into the entry at write time and each entry is "
     "canonicalised to the face-right pattern using its own stamp, so the "
     "match-time `is_he_right` disappears along with the face-left pick.",
     "This is the crossup drop, and it is worse than it sounds because the "
     "fighter has not turned round when it happens and will not for a "
     "while: `turn_around` is an ~8 tick animation that disables buttons, "
     "and it is only ever attempted from the stance loop, walking or "
     "blocking - nothing even tries while airborne or mid-move. So the two "
     "facings disagree for the whole arc of a crossup, and a motion entered "
     "before the cross is judged after it. Jumping over someone and "
     "throwing a special is core fighting-game vocabulary; MK2 drops it.",
     "It is a NO-OP unless facing changes mid-motion: if every entry "
     "carries the same stamp, canonicalising them all is identical to "
     "picking that pattern once, which is what retail does. Only a motion "
     "SPANNING a cross behaves differently - that is both the point and the "
     "whole risk surface. Only the joystick CLOSE queues are stamped: "
     "`switch_queue_a0` serves the button queues too and `two_button_check` "
     "recovers a button with a bare `srl 16`, so a stamp there would break "
     "Kitana's fan and Reptile's forceball. `previous_q_entry` is left "
     "exactly as documented - two_button_check and get_last_button rely on "
     "the raw value and on it touching only a0/a6/a7 - and the transform "
     "lives in a wrapper only `combo_look_lr` calls. Stability sweep 25/25 "
     "and behaviour.lock unchanged at 10 cases. The crossup behaviour "
     "itself is NOT yet verified: no rig exercises a crossup.",
     "`crossfix 0` restores retail, face-left pattern and all."),

    ("deferhit",
     "The first fighter whose strike_check runs in a tick wins any "
     "simultaneous exchange outright, and nothing ever trades. A connect "
     "calls `react_xfer_him`, which moves the victim into a reaction "
     "BEFORE that fighter's own process has run - so the loser's "
     "strike_check never executes at all.",
     "`react_xfer_him` records the reaction instead of applying it, and "
     "`apply_pending_hits` (JOY.ASM) runs them once the dispatcher has "
     "walked every process. Both fighters' strike_check therefore runs "
     "before either is moved, and a genuine simultaneous exchange becomes "
     "a TRADE - which MK2 has never had. Damage is NOT deferred, only the "
     "transfer: `bar_reducer` still runs inline, so hit counts, chip and "
     "the round-end tests are untouched.",
     "It is player TWO who wins, always, and it is structural rather than "
     "incidental. Proved from source: `getprc` links a new process after "
     "its creator (a13 is only dereferenced there, never written, and "
     "`xferprc0` touches a2/a12 but not a13); `setup_players` creates P1 "
     "then P2 from the same running process, so the list becomes "
     "[C, P2, P1] - the SECOND player created ends up FIRST - and "
     "`prcdsp` walks forward from `active`. Side assignment therefore "
     "decides close exchanges, which is disqualifying for tournament use. "
     "Swapping the creation order would not fix it, it would hand the same "
     "advantage to P1; deferring does not pick a winner, it stops the "
     "winner being picked by list order.",
     "Measured as a controlled A/B on one build pair, same rig, same "
     "mirror match (Baraka vs Baraka, both human, pinned at symmetric "
     "distances, both pressing High Kick on the same frame): with it OFF, "
     "P2 won 4 of 4 scored exchanges and nothing traded; with it ON, all 4 "
     "traded and neither side won any. Complete separation. The sample is "
     "narrow - four distances, one move, one matchup - so treat it as "
     "proof that the mechanism works, not as a survey. Earlier runs that "
     "reported 'trades favour nobody' were on a rig that drove P1's stick "
     "during fights; that fault is fixed (ADDON_OWNS). NOTE it cannot fix "
     "THROWS: a throw takes the victim through `takeover_him`, never "
     "through `react_xfer_him`, so nothing in the throw path is deferred. "
     "IT DOES NOT FIX THE KILLING BLOW, and that limit was found by testing "
     "for double KOs. Traced frame by frame in a mirror match at 82px: at 100 "
     "HP both bars drop 32 on the SAME tick (100/100 -> 68/68) - a true "
     "simultaneous trade. At 8 HP the same exchange gives 8/8 -> 0/8: P1 "
     "dies, P2 is untouched. The cause is `bar_reducer` (JOY.ASM), which "
     "opens by refusing to apply ANY damage once either bar is already zero "
     "(`jreq bred5`, 'zero already ---> mute point'), and it runs INLINE - "
     "deferhit defers the transfer, not the damage. So P2's check reduces P1 "
     "to zero first and P1's check is then short-circuited. The result is "
     "that ordinary exchanges are now even and the DECIDING one is not: at "
     "match point a simultaneous exchange still goes to P2, every time. "
     "Fixing that means letting both reductions land before testing for "
     "zero, which creates real double KOs - and `its_a_tie` (MAIN.ASM) is a "
     "bare `retp` that sets no winner_status and awards no round. So it is a "
     "chain of work, not a switch. Rig: tools/sweep_addon_dko.lua.",
     "`deferhit 0` restores retail, P2 advantage and all."),

    ("dko",
     "A lethal simultaneous exchange is not simultaneous: `bar_reducer` "
     "refuses to apply ANY damage once either bar is zero (`jreq bred5`, "
     "'zero already ---> mute point'), and it runs inline. So whichever "
     "fighter's strike_check runs first takes the other to zero and the "
     "second is short-circuited - and P2 runs first, by construction. The "
     "killing blow always goes to P2.",
     "The guard is narrowed to what it is for. `ko_tick` stamps the tick a "
     "bar reached zero; a reduction carrying that same tick is the other "
     "half of one exchange and is let through, while anything from a later "
     "tick is refused exactly as retail refuses it. A lethal simultaneous "
     "exchange therefore kills BOTH - a real double KO.",
     "`deferhit` evened ordinary exchanges and left the deciding one "
     "untouched, which is the worst place for it to survive: at match "
     "point, side assignment still decided the round. Refusing damage after "
     "the round is decided is correct; refusing the other half of the SAME "
     "TICK is not, and the two were the same test.",
     "Traced frame by frame, mirror match at 82px (tools/sweep_addon_dko.lua). "
     "Before: 8/8 -> 0/8, P1 dead and P2 untouched. After: 8/8 -> 0/0, both "
     "dead on the same tick. The outcome lands on `round_is_over`'s existing "
     "tie path - equal bars means `round_tied` - so it makes an EXISTING "
     "state reachable rather than inventing one (a timeout at equal health "
     "gets there today). Watched 600 frames hands-off afterwards: both bars "
     "refill, neither player is awarded the round, `winner_status` is "
     "untouched, and the round replays. No hang. Note `gstate` stays 2 "
     "throughout and no round is awarded - a draw produces neither signal, "
     "so do not read those as a stall.",
     "`dko 0` restores retail: the first fighter resolved wins outright."),

    ("rollpunish",
     "Mileena's ball roll (`do_fn2_kano`, MKPROP.ASM - Khameleon borrows it) "
     "is safe on block, and not because of its strike record: `stk_kano` and "
     "every `stk_*uppercut` are the retail values to the digit. What does it "
     "is the recoil in `kano_blocked`. Blocking costs 8 ticks of stun, so the "
     "guard is actionable on tick 9 - but the recoil throws her 73px up for "
     "46 ticks and `away_x_vel 0a000h` walks the gap from 76px to 104px. An "
     "uppercut reaches a standing Mileena at 94px and misses from 96px, so "
     "the punish fails twice over: swing early and the box goes live under a "
     "woman already 40-70px off the floor, wait for her to land and she is "
     "10px past the end of the swing.",
     "The recoil is retuned so the whole of her recovery is in range. "
     "`rollpush` cuts the horizontal drift (0a000h -> 03000h), landing her at "
     "~82px instead of 104px; `rollgrav` brings her down harder (06000h -> "
     "08000h), dropping the apex from 73px to 55px and the airtime from 46 "
     "ticks to 34. She still pops off the guard just as hard - the launch "
     "speed is untouched. Nothing about the roll on HIT changes.",
     "A special that a correct block does not pay for is the one thing a "
     "tournament build cannot leave alone, and this is the only one in the "
     "game. Both halves are needed and each fixes a different whiff: with "
     "the drift alone, 6 of 8 characters connected at every timing and Liu "
     "Kang and Kitana each had ONE dead tick - the swing that goes live at "
     "the top of her apex, right on the top edge of the uppercut's 64px "
     "band. Gravity is the lever rather than launch speed because apex = "
     "v*T/4: cutting the pop costs exactly as much recovery window as it "
     "buys, while raising gravity keeps the kick and shortens the fall.",
     "tools/run_mileena_roll_punish_test.ps1 - scripted roll, crouch-blocked, "
     "then an uppercut swept across the recovery. Crouch-block is the best "
     "case for the punish on purpose (a standing blocker has to duck first), "
     "so a whiff there is a whiff everywhere. Before: 0/7 timings connected, "
     "and the range control shows why - the uppercut reaches 94px and she "
     "lands at 104px. After: 99/99 across 11 characters at 9 timings each "
     "(delays 12-52 ticks after the block), plus 7/7 in the Mileena mirror. "
     "The secret fighters are untested here - they cannot be force-selected "
     "(only the select cheat reaches them) - but they swing the same "
     "`stk_njuppercut`/`stk_fnuppercut` records as Sub-Zero and Kitana.",
     "`rollpunish 0` restores retail: the roll is safe on block again. "
     "`rollpush` and `rollgrav` tune the two halves independently."),

    ("airswing",
     "The drone swings standing attacks at an airborne opponent without ever "
     "asking how high he is, in two places. `rt_airborn_close` (MKDRONE.ASM) "
     "is the stalk loop's answer to \"he is in the air and he is close\": "
     "pick one of high kick / roundhouse / jab string and throw it, with no "
     "test of any kind. `air_rhouse_check`, the wait behind `rh_ooa` and "
     "`hk_ooa`, is the whole roster's fallback answer to a jump-in and tests "
     "his CLOSEST POINT only - an outstretched leg is inside 040h while the "
     "man is 100px up - and it swings when its patience runs out as readily "
     "as when the test passes. Every move behind both is pinned at head "
     "height and none of them travels up.",
     "The two kick paths ask `get_his_dog <= aa_kick_height` first (and `rt_airborn_close` "
     "`get_x_dist <= aa_kick_reach` as well), reusing the constants the "
     "anti-air styles were already measured onto. A no at "
     "`rt_airborn_close` puts the guard up and waits him down, exactly as "
     "`stalk_airborn_med` does one band further out; a no at "
     "`air_rhouse_check`, including its patience running out, is now simply "
     "no swing.",
     "A whiffed roundhouse is the most punishable thing the drone can hand "
     "back, and it was handing one back for free. Reported against Kung "
     "Lao's BLOCKED dive kick, which is where it is most visible rather than "
     "where it is worst: `super_rep_blocked` (MKPROP.ASM) parks the victim "
     "airborne at gap 0 for the best part of forty ticks, so it meets "
     "`rt_airborn_close`'s entry condition every single time, for a third of "
     "a second. The intended punish there is fine - `c_hh_sd` walks in and "
     "uppercuts - and the roundhouse is a second, unrelated swing on top of "
     "it.",
     "tools/run_divep_ab.ps1 does one side each (set the equate, rebuild, "
     "package, sweep 8 seeds) with tools/run_drone_divepunish_test.ps1 "
     "driving the dive and scoring HIT/WHIFF on the bar actually moving. "
     "Scorpion diff 9. In the blocked-dive window: 1 whiff in 17 swings off, "
     "0 in 93 on. Across every swing at an airborne man the roundhouse goes "
     "from 0 of 2 connecting to 6 of 7 - and the UPPERCUT went 15 of 15 and "
     "90 of 90 in the same runs, which is the point: its box rises through "
     "the swing and a kick's does not. The change can only remove swings, so "
     "the difficulty ladder is untouched: run_drone_antiair_test.ps1 -Diff 0 "
     "must still score zero, and does.",
     "`airswing 0` restores retail, and it is kept deliberately rather than "
     "as decoration - the thing being measured is a MISS, and a miss is "
     "invisible unless the gate can be turned off and watched to come back. "
     "The switch also covers the SWEEP (`drone_sweep`), the third place: a "
     "low attack gated on `does_stk_reach` alone, which tests X. With the "
     "kick gates in, 52 of the 54 remaining airborne whiffs were sweeps. A "
     "height ceiling was measured and rejected - the misses sat LOWER than "
     "the hits (23 at dog 27, rising off a blocked dive) - so a man on the "
     "floor sweeps as before and an airborne one must be FALLING and no "
     "higher than aa_kick_height: all 13 measured hits were oyvel +4..+5 at "
     "dog 48-66, and that rule refuses all 33 measured whiffs. On the final "
     "build the 8-seed rig saw 3 airborne sweeps, 3 hits, 0 whiffs. "
     "`airsweep 0` takes the sweep half out on its own."),

]

OFF = [
    ("airzap_once",
     "limit air projectiles to one per airborne state",
     "built, wired to Mileena's sai, and reverted",
     "It constrained nothing. Reported from play: a player could never throw "
     "more than one air projectile per jump anyway, so the rule had no work to "
     "do. The sai is spammable because of its input, not because of jumping - "
     "see `saicool`."),

    ("throwbtn",
     "give the throw its own input - Low Punch + High Kick - so a close Low "
     "Punch on its own is a jab and the throw becomes a decision",
     "built and measured; the behaviour lock caught it exactly as designed, "
     "`throw_close` going from dmg=34 act=0507h (body slam) to dmg=8 "
     "act=0102h (low punch)",
     "It is the PREREQUISITE for charging a whiffed throw, not a goal - and "
     "that cost was never built, so with it on the build paid the whole price "
     "and collected none of the benefit. Two of the three original complaints "
     "about throws turned out to be false as well: the tech already existed, "
     "and the P2 throw advantage was a rig defect. A proximity throw is "
     "simple but it does not punish good play, which is the line drawn for "
     "what should change. Turn it on alongside the whiff cost, not before."),

    ("airland_recover",
     "make an air projectile cost something on landing, by playing the landing "
     "animation slower - safe thrown from range, punishable thrown up close",
     "built as a rate for `mframew` in `air_land_animation` (MOVES.ASM), used "
     "by the tail every air projectile lands through",
     "Tried at 7 ticks per frame against retail's 3 and REPORTED FROM PLAY as "
     "still feeling wrong, and as not helping much with what it was for. An "
     "earlier attempt that slept after a normal-speed landing was worse - it "
     "froze the fighter on the last crouched frame and read as a hang. "
     "`airzap_once` is the half that actually addresses the spam and stays on. "
     "A landing cost is worth revisiting with a clearer idea of what it should "
     "feel like; 7 was a guess inside a recommended band, and a band is not "
     "evidence."),


    ("airzap_minheight",
     "refuse an air projectile thrown too close to the ground, killing the "
     "instant-air version",
     "built into `air_zap_gate` and measured in pixels above the thrower's own "
     "ground line",
     "`airzap_once` and `airland_recover` both landed on the same day and "
     "neither has been played. A third unplayed change on the same move would "
     "make an unwanted result impossible to attribute."),

    ("firstactive",
     "decide a simultaneous exchange by which attack's active window opened "
     "first, rather than by which process runs first",
     "built, and wrong in three separate ways - it gates on `p_action`, which "
     "covers recovery too, so it silently deletes whiff punishing",
     "Beta playtest found it. It should probably be retired rather than "
     "repaired: what it implements is not what its name says, and `deferhit` "
     "above is a different and better-founded mechanism."),

    ("perpiece",
     "test the strike box against each of the victim's sprite PIECES instead "
     "of one collapsed box narrowed to a quarter of its width",
     "built and measured, and the measurement is why it is off",
     "It is 99% 'remove the squeeze'. Against a no-squeeze model - the whole "
     "silhouette as one box - per-piece differs on 1.02% of verdicts; against "
     "the shipping model it differs on 13.66%. So 98% of what it does is "
     "widen the target, and the limb precision it was wanted for is the "
     "remaining 1%. It also adds ~32px of reach to every move and DELETES the "
     "point-blank dead zone across the cast (headband/hikick goes 18..101 to "
     "0..133), which would mean re-cutting all 233 strike records to "
     "compensate. Reproduce with: box_model_lab.py flips --models nosqueeze "
     "perpiece."),

    ("stkphase",
     "let a move's hitbox change shape partway through its ACTIVE window",
     "built and inert. Keyed on the striker's a10 countdown, with descending "
     "`.word threshold, move_index` pairs; it needs no new process RAM and "
     "costs nothing while no move declares phases. One is authored as a "
     "worked example - `stk_lklokick_early`, appended at index 17 of "
     "`lk_strikes` so indices 0-16 are untouched, giving Liu Kang's low kick "
     "56px of reach for the first half of its window instead of 104.",
     "IT IS NOT WHAT THE 'BOXES ARE ACTIVE TOO EARLY' COMPLAINT WANTS. Those "
     "moves already have real startup with no hitbox at all: striker and "
     "striker_2 play part one through act_mframew FIRST and only then hold "
     "the contact pose for a10 ticks of strike_check, so nothing is "
     "checking for a hit during the windup. Phasing splits the ACTIVE "
     "window, not the startup, and the art does not change during it - the "
     "hold is a single static pose. Measured across the 23 handlers in "
     "doc/FRAME_DATA.md section B that report a numeric window: 7 run 1-3 "
     "ticks and cannot be meaningfully split, 12 run 4-6 (a 2/2 or 3/3 "
     "split), and the only 4 long enough to be interesting - 15 and 16 "
     "ticks - are do_flip_kick, do_flip_punch, do_jumpup_kick and "
     "do_jumpup_punch. All four are air_strike. A jump attack's box is live "
     "for the whole descent because the fighter is committed and "
     "travelling, so that length is structural, and phasing it would punch "
     "a dead spot into the middle of a jump arc. The long windows are the "
     "ones that must NOT be split, and the splittable ones yield 2-3 tick "
     "phases."),
]


# Every ruleset switch the balance lock tracks must be described here, or
# this page quietly goes stale - which is exactly what happened: it claimed
# `firstactive = 1` long after the switch went to 0, because the switch VALUE
# is read from source but the switch LIST was hand-maintained. Values could
# not drift; coverage could.
def coverage_gap():
    lock = pathlib.Path(__file__).with_name("balance_lock.py").read_text()
    m = re.search(r"SWITCHES = \[(.*?)\]", lock, re.S)
    if not m:
        return []
    tracked = re.findall(r'"([a-z_]+)"', m.group(1))
    described = {e[0] for e in ENTRIES} | {e[0] for e in OFF}
    # sub-parameters are covered inside their parent's entry
    described |= {"combo_slack_online", "twobtn_depth", "rollpush", "rollgrav"}
    return [s for s in tracked if s not in described]


def main():
    gap = coverage_gap()
    if gap:
        sys.stderr.write(
            "deviations.py: no entry for %s - add one, or this page goes "
            "stale while still looking authoritative.\n" % ", ".join(gap))
        sys.exit(1)
    eq = BA.read(os.path.join(SRC, "MAINEQU.ASM"))
    P = print

    P("# How this build differs from the arcade, and why\n")
    P("Generated by `tools/deviations.py`. **Switch values are read from")
    P("MAINEQU.ASM at generation time**, so this page cannot claim one thing")
    P("while the ROM does another.\n")
    P("This is a tournament build, so straying from the arcade is the point -")
    P("but every departure should be answerable. Each entry below says what")
    P("the arcade does, what this build does instead, what evidence says the")
    P("change is right, and what it costs. Anything marked **verified** was")
    P("checked by reading the retail source at")
    P("`Workplace/mk2-readonly/mk2-main`, not inferred from our own switches.\n")
    P("One tick is %.2f ms.\n" % TICK_MS)

    P("## Active departures\n")
    for name, retail, ours, why, evidence, cost in ENTRIES:
        v = val(eq, name)
        P("### `%s` = %s\n" % (name, v))
        P("**The arcade:** %s\n" % retail)
        P("**This build:** %s\n" % ours)
        P("**Why:** %s\n" % why)
        P("**Evidence:** %s\n" % evidence)
        P("**Cost / reverting:** %s\n" % cost)

    P("## Available, and deliberately OFF\n")
    P("These are built and measured but ship matching the arcade, because")
    P("each needs a ruling rather than a fix. The measurement is done so the")
    P("ruling can be made on numbers.\n")
    for name, would, evidence, why_off in OFF:
        v = val(eq, name)
        P("### `%s` = %s (arcade behaviour)\n" % (name, v))
        P("**Would:** %s\n" % would)
        P("**What is actually there:** %s\n" % evidence)
        P("**Why it is still off:** %s\n" % why_off)

    P("## What this page does not cover\n")
    P("Added *content* - new moves, characters, stages, fatalities - is a")
    P("separate category and is documented per feature in `doc/`. It changes")
    P("the game by addition rather than by altering existing behaviour, and a")
    P("tournament ruleset would want to list it separately: which characters")
    P("are legal, which moves exist that an arcade player will not know.\n")
    P("Also not here: anything measured only in motion. The retail tree is")
    P("source and **does not build** (the leak is missing its build tooling,")
    P("DIAGCMOS primitives, several labels and 33 of 34 IRW files), so")
    P("behaviour that needs a running retail ROM to compare against - the P2")
    P("side advantage, throw priority - is measured on this build only and")
    P("says so where it is reported.")


if __name__ == "__main__":
    main()
