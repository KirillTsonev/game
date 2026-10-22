# Weapons in hands

(2026-10-13 / 14) How a sword and a shield are held in first person, drawn, sheathed and
kept out of the body; how to add or swap one; how to check a change without looking; what
is still fitted to the one sword and one shield, and the plan to change that.

Everything here was judged in game by Kirill unless a line says otherwise. The code is in
`scripts/player_body.gd` (group "Weapon held" on the Body node) and `scripts/weapons/`.

## Contents

1. The pieces
2. Workflows: add a weapon, add a shield, edit a stance, give a weapon to another body
3. How the arms are shown in first person
4. Sheathing on the back and the draw
5. The shield
6. The lantern action with weapons
7. Checking a change headless
8. What is generic and what is fitted to this sword and shield
9. Plan: per-weapon setups and a fit button
10. Rules learnt, each from a fault
11. Open items
12. References: Skyrim, the Mixamo pack
13. Attack and defence (2026-10-21)

## 1. The pieces

| Piece | File | What it is |
|---|---|---|
| `WeaponData` | `scripts/weapons/weapon_data.gd` | One resource per weapon or shield: `scene` (the model), `grip` (where the fist's middle goes, +Y toward the blade, +X toward the leading edge), `grip_radius` (the handle's thickness), `on_forearm` (a shield strapped to the forearm). |
| `WeaponHold` | `scripts/weapons/weapon_hold.gd` | Static helpers: the hand's socket worked out from the hand's bones (`socket`), the forearm's socket for a shield (`forearm_socket`), a fist closed for a handle's thickness (`fist_curls`, `close_fist`), a two-bone arm solver with an elbow side (`solve_arm`), `attach` for bodies that are not the player. |
| `WeaponStance` | `scripts/weapons/weapon_stance.gd` | A `@tool` node under the Body in `scenes/player_body.tscn`, one per hand: `WeaponStance` (right, `holds = &"weapon"`) and `ShieldStance` (left, `holds = &"shield"`). Its child markers (Shoulder, Elbow, Hand, Hand/Grip, fifteen finger joints) are moved with the editor's gizmos; the game reads them every frame. |
| `PlayerBody` | `scripts/player_body.gd` | Holds both (`_hold_weapon`, `_hold_shield`), draws the arms apart from the body, the draw from the back, the shield's keep-off, the lantern action. `equip(data)` / `equip_shield(data)` swap at run time. |
| `ArmClip` | `scripts/weapons/arm_clip.gd` | A reference arm clip read from a file (`weapon_arm_from_reference`, off). A try, kept. |

Two places are laid on each other: the weapon's `grip` and the hand's socket. The socket
comes from the hand's bones, so a weapon fits any body on the humanoid skeleton with
nothing set up per pair. **The socket never poses the arm**: where a weapon points is the
arm's pose, which is the stance.

Left hand: the marker convention is mirrored (+X is the palm). `WeaponHold.solve_arm`
handles it through `palm_side`.

Keys (`scripts/player.gd`): Q raises / lowers the weapons (not while the lantern is being
turned), left click = `attack()`, L = `toggle_lantern()`.

## 2. Workflows

### Add a weapon

1. The model as `.glb`. Any origin and axes, the handle straight. **Find its axes on its
   mesh** (see rule R1): the sword's mesh node is turned 90 degrees inside `sword.glb`, its
   own long axis is its Y, and in the scene the blade runs along +Z.
2. A `WeaponData` beside it (`assets/models/weapons/sword/sword.tres` is the pattern): `scene`,
   `grip` (origin on the handle's middle line where the fist's middle goes; the sword's is
   0.0735 m above the handle's middle, which leaves the hand's upper edge 1.5 cm under the
   guard), `grip_radius`.
3. Set it as `weapon` on the Body of `scenes/player_body.tscn`. The editor shows the arm in
   the stance with the weapon in the fist. Change `grip` until it sits right.
4. If its handle is clearly thicker or thinner than the sword's, the hand-posed fingers will
   not fit (they are stored on the stance, shared by every weapon -- section 8). Either pose
   them again or press "Reset the fingers to the plain fist" on the stance, which closes the
   hand from `grip_radius`.
5. Run the checks of section 7. The numbers of section 8's "fitted" list were found for the
   sword and must be found again for a weapon of another length or guard.

### Add a shield

1. Run the model through `tools/blender/import_shield.py` (Blender in background mode, full
   path to `blender.exe`). It bakes transforms, puts the origin on the forearm's line at the
   hand strap, and **reshapes the straps to the arm** (`STRAPS`: reach, low, high per strap;
   `STANDOFF` = how far the arm rest stands off the board). For a new model those numbers are
   measured on it; see rule R9 for what went wrong measuring the first.
   In Godot: +Y top, +Z face, hand at -X.
2. A `WeaponData` with `on_forearm = true` (`assets/models/weapons/shield/shield.tres`;
   `grip = Transform3D(0, -1, 0, 0, 0, -1, 1, 0, 0, 0, 0, 0)`).
3. `mcp__godot__rescan_filesystem` after re-exporting, then **reload the scene**: a
   re-imported held model can leave a second preview in the open scene until then (Kirill
   saw two shields).
4. Set it as `shield` on the Body. Move `ShieldStance`'s markers until the forearm lies on
   the arm rest and the palm is in the hand strap. The socket is `WeaponStance.forearm_socket`:
   in the LowerArm bone's axes, +X out of the back of the hand, +Y along the forearm toward
   the hand, origin on the forearm's line at the fist.

### Edit a stance

- Open `scenes/player_body.tscn`, select the stance, move Shoulder / Elbow / Hand / Grip and
  the finger joints with the gizmos. Kirill wants gizmos, not typed numbers.
- Buttons on the stance: reset the fingers, "Fit the hand to the sword" (moves the hand
  nearer the body for a relaxed shoulder; right hand only) and its undo.
- Saving resets only the stance's OWN arm to the rest pose (`_reset_own_arm`), after keeping
  the posed fingers. It used to reset the whole skeleton, which wiped the other hand's
  fingers on every save and every F5.
- The editor's preview shows the stance only: not the arms drawn apart, the view-following,
  the shield's keep-off or the relaxed carry.
- **Values Kirill set by hand are in the scene** (marker transforms, and on the Body
  `shield_body_clearance = 0.12`, `shield_clearance_return = 0.1`, `weapon_follows_view = 0.7`).
  Never overwrite the scene from a default.

### Give a weapon to another body

`WeaponHold.attach(skeleton, "Right", data)` puts the model on a BoneAttachment3D; the
body's clips pose the arm. Close the fingers after its clips each frame
(`WeaponHold.close_fist(skeleton, side, WeaponHold.fist_curls(...))`) or they stay as the
clip has them. Not used yet.

## 3. How the arms are shown in first person

The problem, measured: standing, the eyes are about 0.36 m ahead of the shoulders, the arm
is 0.565 m long, and a stance that looks right has the fist about 0.94 m from the body's
own shoulder. So a hand on the body's arm sits under the picture and only the blade shows.

What was tried, in order, and why each went:

| Tried | Result |
|---|---|
| "Fit the hand to the sword" (hand nearer the body) | Kept as a button; not enough by itself. |
| Arm drawn apart, fixed in the view | "It's just floating in the air" (Kirill). |
| Slide the hold onto the body when looking down (`weapon_on_body_slide`) | "The sword visibly shifts back and forth." Off, kept. |
| Turn the body toward the weapon (`weapon_body_toward_weapon`, chest turn, collar forward) | Off since the next row, kept. |
| **Arms apart, turning with the view** | "Looks the best so far." This is what runs. |

How it works now (`weapon_arm_drawn_apart`):

- Each arm is an extra copy of the model (`Rogue{Side}Arm`, meshes `ARM_APART_MESHES`) with
  its own skeleton, posed from the stance. The body's own arms are shrunk to `ARM_APART_SHRINK`
  at the very end of `advance()` (`_draw_arm_apart`), so **nothing may read the body's arm
  after that**, and a probe reads the arm from `body._apart[side]["skeleton"]`.
- The stance is rotated about the eyes by `weapon_follows_view` of the view's pitch (0.8 by
  default, 0.7 in the scene), which is what Skyrim's IFPV mod does (0.8).
- **Breathing** (2026-10-14; Kirill: the chest breathed while the weapons stood still in the
  picture): `_breathe` takes the upper chest's place against the eyes less its average over
  `breathing_average` (3 s), and each stance moves by its share (`weapon_breathing` 0.8,
  `shield_breathing` 0.6), capped at `breathing_limit`, faded out as the step bob comes in.
  On the idle: the chest moves 1.4 cm up and down and 1.8 cm front to back; the sword's grip
  1.1 / 1.4 cm, the shield 0.8 / 1.1 cm; at most 0.9 mm a frame (`breathing.gd`). After the
  idle switches to its mirror image the average takes a few seconds to settle, so the
  weapons drift about a centimetre sideways meanwhile.
- **Fidgets** (2026-10-14, not judged in game yet): standing still with the weapons up for
  `fidget_after` + up to `fidget_after_random` s, the sword arm plays one of `FIDGETS` (never
  the same twice running): `inspect` (4.5 s: to the middle of the picture, tip up, the flat
  the stance shows, turned part way toward the edge and back) and `wrist_roll` (3.5 s: two
  circles of the blade; one motion -- the circling runs over the whole time, the tilt grows
  in and dies out while it goes on: tilt, circles and tilt back eased each on its own
  stopped the tip at both joins). A key's edge must be on the stance's side (its LEFT) for the first
  and last key: opening on the other flat turned the hand over 130 deg outward on the way in
  (Kirill: "spins outwards into the proper position"). A turn about the upright blade is
  nearly all WRIST (the forearm points ahead; only a roll about its own line goes into it):
  edge-on bent it 82 deg, the other flat 151 with the fist folded into the forearm ("too
  drastic"); turning the elbow's side with the hand made it worse (117-144). Now at most
  47 deg (the stance has 33). A keyed fidget is ONE curve (`_through`) from the stance through
  every key and back, eased once over the whole (the keys' shares are of the eased time):
  eased key to key it stopped at each, and the way back from the last read as "a separate
  animation" (Kirill). `fidgets.gd --roll-trace` prints the forearm's roll, the
  elbow's turn and the wrist's bend through each fidget. A fidget is
  keys of [share of the time, fist from the eyes, blade's way, edge's way], turned with the
  view; `_fidget_pose` turns the stance's hand so the blade and its edge (the grip's +Y, +X)
  lie as asked, and the arm is solved as for the stance. Any key or mouse button
  (`interrupt_fidget`, from `player.gd`) or moving off ends it in `fidget_cancel_time`.
  Measured (`fidgets.gd`): the sword stays 0.30 m or more from the eyes, 0.27 from the body,
  0.13 from the shield in `inspect`. **I opens the animation panel**
  (`scripts/debug/animation_panel.gd`): pick a fidget, play one stage (between keys) or all,
  scrub with the time slider, slow it down, loop, hold at the end, Release. It drives the body
  through `PlayerBody.debug_animations` / `debug_drive` / `debug_release`; a fidget gets its
  stage names from `"stages"` in `FIDGETS`. Another kind of animation is added in those
  three functions, not in the panel.
- **A fidget needs room** (2026-10-15; Kirill: "if we stand right in front of a wall/tree we
  shouldn't be able to play the shield brush"; tested headless only, not judged in game). Every fidget, drawn
  or sheathed, has a box in `PlayerBody.FIDGET_ROOMS`: the space it sweeps through, from the
  eyes in the Player's axes. `_fidget_has_room` tests it against the world's collision (walls,
  cliffs, rocks, tree trunks; grass and bushes have none) with one shape query, excluding the
  Player. When the wait is over only fidgets with room are picked; none has room -> another
  try in `fidget_room_retry` s. While one plays it is checked every frame and, once blocked,
  ends as by a key (Kirill chose this over checking only at the start: the drawn fidgets go
  on while the mouse turns the body). Knobs on the Body: `fidget_needs_room`,
  `fidget_room_margin` (0.05 m all round), `fidget_room_floor` (0.3 m), `fidget_room_retry`.
  - **The boxes are MEASURED, not set by hand** (`tools/weapon_probes/fidget_room.gd`, about
    10 min): every fidget, either foot, standing, crouched (drawn) and looking 0.6 rad down
    and up (drawn); the arms to the finger tips, the held sword, the shield and the lantern,
    each sample counted only once it is more than 12 cm from where it was as the fidget
    started. **After changing a fidget, re-run it and paste the block it prints.** At 4 cm
    the box took in the shield hanging on the back (the idle sways it 9 cm) and the whole rim
    of a shield tipped a few cm, and reached behind the Player and down to the feet in every
    fidget. Measured only at pitch 0, the shield fidgets came 0.2 m outside looking down: the
    shield does not follow the view as the sword does.
  - Drawn fidgets' boxes are turned with the view's pitch as the stance is (`_look_pitch *
    weapon_follows_view`) and the query takes the upright box round that. Looking about
    50 deg down (0.9 rad), `shield_settle` / `shield_glance` still reach 17-25 cm outside;
    within 0.6 rad all stay within 2 cm.
  - The box is cut off `fidget_room_floor` above the feet: crouched, the shield's rim comes
    down near the ground and every box would hit the floor. Steep ground or a mountain face
    ahead still blocks.
  - `tools/weapon_probes/fidget_room_wall.gd` (a ground slab and a wall or a 0.3 m trunk):
    a wall 0.5 m ahead (10 cm off the body) blocks all but `lantern_look` (it only lifts the
    lantern at the hip, so it never meets a wall in front); 0.8 m ahead it blocks the drawn
    ones, not `brush_off` or `strap` (they work close to the chest); 1.2 m blocks only crouched
    `shield_glance`; a trunk 0.7 m ahead blocks all drawn ones and `brush_off`. `strap` and
    `brush_off` are also blocked by a wall 0.5 m BEHIND or to the left: their boxes start where
    the shield hangs at the side, a little behind the body. A playing `brush_off` ended 0.2 s
    after a wall appeared in front.
- **`shoulder_tap`** (2026-10-14, not judged in game yet): the blade swung up and back over
  onto the BODY'S right shoulder (`"rest"` in `FIDGETS`, `_fidget_pose`), tapped four times (0.35 s each; 3.25 s in all)
  by the wrist (identical taps: Kirill, "there's rhythm to it"), and back; the view and the
  shield arm stay. The touch is placed from the body's shoulder joint each frame, so it holds
  on either idle foot. The fist does NOT come in toward the body: it rises 27 cm, comes
  11 cm back and only 15 cm left from its place in the stance (`"hand"`; with no move left
  it rested 57 deg right of the view's middle, just past the picture's edge at 54 -- only
  the pommel showed), the elbow is steered out (`"elbow"`),
  and the blade lies diagonally from the fist back onto the shoulder -- a sword carried on
  the shoulder (Kirill's reference picture; the first version moved the fist 0.3 m in toward
  the middle, its forearm upright). The wrist alone cannot do it: from the stance's fist the
  shoulder is 0.94 m away (the tip is 0.87) and the blade would have to lie almost along the
  forearm. The keep-off (`weapon_body_clearance`) is let go while the blade rests
  (`_fidget_rest`). The blade is turned onto the shoulder the shortest way, not rolled onto
  its flat (Kirill: "the taps are light enough for it not to matter"). Measured: the fist
  resting 0.44 m right of the eyes and 0.40 ahead (48 deg off the middle, inside the
  picture), the elbow 7 cm further out than the fist, the touch 8.5 cm above the shoulder
  joint and 15-21 cm before the tip, each tap lifts it about 5 cm, the wrist 52-59 deg, the
  blade at least 0.22 m from the eyes. The blade itself runs back past the camera from the
  fist: little of it can be in the picture with the view kept still.
  2026-10-15, 3.5 s (Kirill: the sword raised onto the shoulder and lowered slower): up 0-1.06 s and
  back 2.45-3.5 (were 0.9 and 0.96 s), the four taps kept in seconds (1.06-2.45). Written while
  Kirill's game was running: NOT run in `fidgets.gd` / `sword_fidget_shield.gd` yet.
- **The guard sags in the sword fidgets** (2026-10-15; Kirill agreed: lower the shield a little
  during `inspect`, `wrist_roll` and `shoulder_tap`, relaxed moments): `"shield_rest"` in those
  entries -- the stance's hand (`"hand"`, m, the stance's axes) and shoulder moved, the forearm
  drooped (`"tip"`, degrees, - = the wrist down), in over `"in"` and back over `"out"` (shares of
  the fidget: it settles just after the sword sets off and is up again a little before it), read
  in `_hold_shield` where the shield fidgets' keys are. The shield's middle lies well out from the
  elbow, so the droop adds to the drop: the first values gave 7.4 / 4.3 / 11 cm, and moving the
  shield toward the middle in `inspect` brought it to 8.5 cm of the sword (13 before). Measured
  (`tools/weapon_probes/sword_fidget_shield.gd`, `SAG`): the shield's middle 4.6 cm lower at most
  in `inspect`, 2.8 in `wrist_roll`, 7.3 in `shoulder_tap`; its room to the trunk and legs 0.42 m
  or more (the stance 0.43-0.45); the sword at least 13 cm from it in `inspect`. Not judged in
  game yet.
- **The fidgets' easing** (2026-10-14; Kirill: they looked "kind of robotic"): every move in
  them goes through `PlayerBody._ease` (used as smoothstep is), whose speed goes as
  x^2 (1 - x)^3 -- at rest at both ends with no jolt, fastest at 40 % of the way, so it sets off
  quicker and settles longer than smoothstep's mirrored S. The sword fidgets' keys also slow the
  pace as they pass (`_key_paced`, `FIDGET_KEY_ACCENT` 0.35: down to 65 % at a key and up to
  135 % between, never stopping). New fidget code uses `_ease`, not smoothstep. With it the
  strap's fingers had to close later and open earlier (`grip`: 0.39-0.47, 0.59-0.65). Next
  steps proposed: overshoot on arrival with the wrist and fingers trailing, and a very slow
  millimetre drift in holds.
- **Shield fidgets, weapons drawn** (2026-10-14, not judged in game yet): `shield_settle`
  (re-seating the shield, 1.55 s, back down from 1.0 s while the last roll swing is still going
  -- after it, it "came separate after a pause" (Kirill). Since: 3 bounces and 4 roll swings at
  up to +-18 deg ("with more force"), no two swings alike in length (0.08-0.25 s) or size, and
  a new pattern on every play (`_irregular_wave`, `_fidget_seed`; Kirill: "make them all
  irregular times so they're not identical"), and a 0.15 s pause between the shake and the
  roll (1.9 s in all; "a small pause between shakes and rolls"), the arm sagging 1.5 cm
  through it (`"sag"`; held still, "the arm is frozen during pause"), and FOUR FULL rolls
  (Kirill counts a roll as one back-and-forth: "there are 2 rolls, I said 4") over 1.2 s, the
  fidget 2.5 s. The elbow rises with the shield (`"elbow_lift"` 5 cm: the upper arm swung up
  from the shoulder, the forearm turned back so the wrist stays where it was solved to -- the
  solver set the wrist and left the elbow nearly where it was) and through the shake and roll
  the elbow and wrist each drift +-1.5 cm on their own, slowly and out of step (`"drift"`;
  Kirill: a forearm held at one slant "seems unrealistic"). Then a quarter slower (still
  "uncanny"): 3 shakes in 1.0 s, 4 rolls in 1.6 s, 3.1 s in all. And the left hand's grip
  eased off through the shake and roll (`"loosen"`: fingers to 0.45 rad a joint, thumb 0.2,
  loose by 0.37 s, tight again 2.64-3.1 s; Kirill: "we're still clutching the shield handle
  while we do all that"). The probe's left-finger test (thick fingers against the board)
  found fingertips touching the board, loosened or not -- the hand's wrist bend, fixed below. Then the shake and the roll
  became ONE motion, four times (Kirill: "combine shake and roll into one motion ... 4 of
  those"): each jostle bounces and rolls together on one irregular pace (`"together"`, the roll
  `"roll_lag"` 0.1 cycle behind), 0.14-1.64 s; the pause and the sag are gone; 1.85 s in all.
  Then "a little less force": bounce 1.8 cm, roll 12 deg, seesaw 3.5 deg (were 2.5, 18, 5).
  2026-10-15, the forearm hinging at the elbow through the jostles (Kirill: "move the forearm
  from the elbow up and down while we shake and roll"): `"seesaw"` 3.5 -> 7 deg, the hand's
  bounce 1.8 -> 1.4 cm (the force about the same, more of it from the elbow). The probe: no
  fingers in the board, the middle's speed changing at most 0.58-0.71 m/s in a frame (was
  0.52-0.59). Then each jostle as a ripple down the arm (`"ripple"`: [metres, cycles]; Kirill
  chose it over an even sine of the forearm's own): the elbow rises 1.5 cm on the bounce
  (the wrist held, so the forearm first tips down) and the forearm's tip follows 0.35 cycle
  behind, lifting the wrist; the hand's own bounce 0.6 cm. Measured (heights against their
  moving average): elbow peaks at 0.25 / 0.60 / 1.07 / 1.40 s, wrist peaks 0.07-0.18 s after
  each (0.32 / 0.78 / 1.20 / 1.48); the first jostle about 1.9 cm, the later ones 0.3-0.8;
  the middle's speed changing at most 0.33-0.37 m/s in a frame. Then "a bit slower": the four
  jostles over 1.8 s (0.14-1.94; were 1.5), the lift, the start of the way down (1.6 s, in the
  last jostle) and the look kept in seconds, 2.15 s in all (was 1.85). Measured: elbow peaks
  0.28 / 0.72 / 1.07 / 1.47 s, the wrist's 0.10-0.18 s after each (0.42 / 0.82 / 1.18 / 1.65),
  the later jostles 0.5-1.2 cm; the middle's speed changing at most 0.24-0.32 m/s in a frame.
  Then "raise and lower the shield at the start and end of animation slower": up over 0.6 s
  (was 0.34), down over 0.8 s from 1.6 (was 0.55), the jostles kept in seconds (0.14-1.94, so the
  first now comes while the shield still rises), the look in by 0.5 s and back by 2.3; 2.4 s in
  all (was 2.15). Measured: no fingers in the board, the middle's speed changing at most
  0.31-0.35 m/s in a frame (at the first jostle).
  Then the raise matched to the lowering (Kirill): 0.8 s (`"lift_in"` 0.333), nothing else moved.
  Measured: no fingers in the board, the middle's speed changing at most 0.26-0.32 m/s in a frame.
  Then "increase both more, to reach 3 seconds": up over 1.1 s, down over 1.1 s from 1.9 (3.0 s
  in all), the jostles 0.3 s later (0.44-2.24; the lowering still starts in the last), the look in
  by 0.6 s and back 1.8-2.9, the grip loosened by 0.6 s and tight again with the lowering.
  Measured: no fingers in the board, the middle's speed changing at most 0.26-0.36 m/s in a frame.
  Then 3.5 s: up over 1.35 s, down over 1.35 s from 2.15, the jostles 0.69-2.49, the look in by
  0.75 s and back 2.05-3.4, the grip loosened by 0.75 s. Measured: no fingers in the board, the
  middle's speed changing at most 0.26-0.29 m/s in a frame.
  Then "if I look at the sky, the shield settle animation brings the camera down and then back
  up ... that makes the fake floating arms visible": `"view"`'s dip was a look DOWN TO 12 deg below
  level, so from 60 deg up it pulled the view 72 deg down, while the drawn arms (which `"dip_alone"`
  keeps from following the dip) stayed posed for the sky. With `"dip_alone"` the dip is now a NOD of
  that much from wherever the Player looks, never past 85 deg down (`_fidget_view`). Checked: a 12
  deg nod looking 60 up, level and 60 down; 5 deg looking 80 down. The sheathed fidgets' looks
  (the body's own arms) are unchanged.
  2026-10-15: a look at it (`"view"` in the entry): the view turns 0 deg left (Kirill set it; 10, 7, 5 before), 12 down and
  tilts 3 as the shield lifts (by 0.4 s), held to 1.2 s, back by 1.8 s. (First a 6 deg glance
  with no dip; then "look down and focus on the arm a bit more": 10 left, 12 down; then the
  turn "a bit smaller", 7, then 5.) `"dip_alone"`: the drawn weapons do NOT follow this dip, though they
  follow the view's pitch otherwise (`weapon_follows_view`) -- with them following, a dip
  hardly moved the shield in the picture, which is why `shield_glance` has none. Measured (10
  left): the shield's middle 31-38 deg below the picture's middle during the look (the bottom
  edge is 37.5), 55 at rest; its top edge 10-17 deg above the middle. Since it has the view,
  moving the mouse ends it (`looked()`); before, it went on.
  Same day, the swings' lengths (`_irregular_progress`, used by `_irregular_wave`): they were
  a drift of two sine waves on the pace, and on about a fifth of the seeds two swings came out
  within 5 % of each other (0.43 / 0.43 / 0.26 / 0.38 s; Kirill: "make sure they are always
  irregular"). Now each swing gets its own length from an even spread (`IRREGULAR_SPREAD`,
  longest about 1.7 x the shortest), shuffled and jittered by the play's seed, with the pace
  easing smoothly between them. Over 2,000 seeds: the closest two swings of a play 13 % apart,
  all 24 orders used, the pace never under 70 % of the average.
- **In every shield fidget the hand is kept on the forearm as in the stance**
  (`_shield_hand_in_stance`; the shield is fixed to the forearm): turned as the solver asked,
  the wrist bent against the shield once the arm moved -- the back of the hand in the board
  through most of the glance, the palm's lower edge through the handle in the settle's jostles
  (Kirill asked about the latter), fingertips touching the board in both (first blamed on the
  stance's grip: the stance alone has none). `tools/weapon_probes/shield_palm.gd` tests the
  palm (three lines wrist to knuckles, at its surface, middle and back) against the shield.
  First version: lifted 8 cm with a shrug, jostled up and down 2.5 cm in 2.5
  dying bounces with the forearm tipping 5 deg about the elbow a quarter cycle behind, then
  rolled back and forth +-10 deg in 2 dying cycles, the roll starting as the shake fades --
  `"shake"`, `_dying_wave`; the first version, one slow lift and dip, was "very lackluster",
  and Kirill sketched the shake and the roll. The 8 cm lift brings the board's middle only
  from 55 to 50 deg below the middle of the view: it hangs below the forearm, so mostly its top
  edge shows) and `shield_glance` (the shield brought up and
  in, its face rolled 124 deg toward the eyes, held, and back: 1.3 s in, 0.9 s held, 0.9 s back
  -- Kirill: slower in, no drifting "look" stage, just a hold at the peak; `"hold"` makes the
  one key a peak eased in, held and eased out, since two equal keys on one curve still bulge
  between them). Through the hold it turns slowly about the line along its length through its
  middle, the side facing the eyes moving right (`"twist"`, 12 deg; the face swings about 16
  deg in the picture, the middle and the board's slant in the picture stay put): the forearm
  turned about that line (`_shield_length`, the board's longest side), then the whole arm moved
  back by what that moved the board's middle. Kirill asked for it for "an examining vibe";
  turned from the elbow about the way to the eyes it slid 2 cm aside ("not a translate"), and
  turned about the face's axis it spun flat in the picture ("I meant along the shield's length
  in the middle"). Unwound on the way back. Since: held 0.4 s before the twist, the twist in
  0.4 s, held turned 0.77 s (3.77 s in all; "rotate it a bit quicker and hold it rotated a bit
  longer", then "hold the shield both before and after rotation a bit longer", then held
  turned 1.4 s -> 1.1 -> 0.77, "30% less"), and the head
  looks at it ("slight head tilts/turns to show that the MC is examining"): `"view"` turned 8
  deg left with no dip (a dip would move the drawn weapons, which follow the view's pitch),
  `"view_tilt"` 3 deg going to 5 as the twist turns (`_fidget_tilt`, + = left ear down; a
  "view" dip of 0 now leaves the pitch alone), the head in by 0.3 and back from 0.7, both
  ahead of the shield. With "view" the glance is ended by moving the mouse (`looked()`). `"shield_keys"` move the stance's hand and
  shoulder and roll the forearm (`_shield_fidget_pose`, in `_hold_shield`); the sword stays in
  its stance. The roll is put on the forearm bone about its own line AFTER the solve: as a turn
  of the asked hand about the stance's forearm line, part of it went into the wrist once the
  hand had moved and the face stopped turning at about 70 deg. Which way turns the face toward
  the eyes is read from the stance (`_read_glance_axes`, `_glance_sign`), so any shield gets
  it. The stance's shield sits about 55 deg below the middle of the view: rolled alone it
  stayed out of the picture, so the glance also lifts it 16 cm and brings it 10 cm in; at the
  look its face is 31 deg off the way to the eyes (from 123), its middle 26 deg left and 21
  below the middle of the view, 12 cm from the body, 20 from the eyes. While a shield fidget
  plays the shield's seat on the forearm is not read again from the arm. Probe:
  `tools/weapon_probes/shield_fidgets.gd`.
- **`inspect` timing** (2026-10-14): `"key_times"` set when each key is reached (the flat at
  1.4 s, the edge at 2.9, back by 4.0), joined by one smooth monotone curve
  (`_smooth_through`, at rest at both ends, never stopping at a key). Eased once over the whole,
  the keys came at 1.3 and 1.9 s and the last 2.1 s were the way back (Kirill: "keep inspecting
  it longer and hurry the moving to idle up"). The way back now takes 1.1 s, the tip at most
  1.1 m/s.
- **Checked against the realism aim** (2026-10-14, `docs/custom_animations.md`): `inspect` and
  `wrist_roll` were already one motion each. `lantern_look` waited -- the lift began as the
  hand arrived and the turn as the lift ended, and its last 0.8 s nothing moved: now the lift
  starts as the hand settles, the turn as the lift ends, and it is 3.45 s (was 4.5). Its
  timings are entries (`"reach"`, `"lift"`, `"turn_at"`, `"let_go"`, `"view_in"`).
- **`strap` at 3.5 s** (2026-10-15; Kirill: "let's do the same for strap check animation, 3.5
  total", as for `shield_settle`): the raise and the lowering about 1.35 s each (were about 1.0), the
  grip and the tugs kept in seconds -- raise and reach 0-1.35 (the hand from 0.11, the fingers
  closing 1.15-1.35, the thumb 0.38-0.76), two tugs 1.39-1.89, the fingers opening 1.83-2.06, hand
  and shield down 1.93-3.28, the thumb opening 2.52-2.90, the view in by 1.19 and back 2.36-3.45.
  Measured (`sheathed_fidgets.gd`, `strap_path.gd`): the shield's room to the body +4.7 / +5.1 cm;
  the little finger's tip at skin depth on the rim through the grip and tugs, no bone in the board;
  the palm's speed changing at most 0.39 m/s in a frame (setting off down), 0.16-0.22 slowing into
  the grip; the grip steady in a hold; the elbow back where it was.
- **Fidgets with the weapons sheathed** (2026-10-14, not judged in game yet; `"when":
  sheathed` in `FIDGETS`, picked only when they fit -- `_fidget_fits`): `strap` (the left arm
  brings the shield up in front of the belly, the right hand grips its RIM at the spot Kirill
  marked on a screenshot (`"grip": rim`, `"rim_at"` = a way in the view, 6 deg right, 7 up),
  tugs once and lets go. (In between it went back to the strap on the left forearm, still
  there as `"grip": strap`.) The rim was missing the shield's SIDES until the outline was
  taken per angle slice round the board's middle: keeping the outer 8 % by distance from the
  middle kept only the top corners and the bottom tip of a board taller than wide, so every
  try landed on the top edge or the far tip. The marked spot was 10 cm out of reach until
  `"shield_arm"` moved 7 cm toward the middle and 4 cm nearer. Then (Kirill: the right hand
  rose "like hailing a cab" through the shield, and shifted with the breathing): the hand comes
  in with the shield and grips the edge as the shield stops (`"reach"` 0.02-0.25, the raise
  0-0.25, the fingers closed by 0.26 -- Kirill wanted both at once, then "still much slower"
  arriving at 0.38, then the grip in sync with the shield's stop; the thumb closes earlier with
  it, `"rim_thumb"`, `"grip_close"`), half way to the eased pace along its curve
  (`_even_on_curve`, `"reach_even"` 0.5: with the weight as the curve's own parameter the hand
  slowed to 0.6 m/s at the bend and sped up again; at an even pace it took the bend at full
  speed). Quick, it reached the arm's full length at the bend and the solver stopped the elbow
  dead there (the hand's way turned in a frame): `_reach`'s `soft` (`"reach_soft"` 0.03 m)
  eases into full length instead; at 0.05 the grip drifted with the breathing. Since the same
  day: 2.8 s, three stages (raise and grip, tug, let go and lower -- Kirill: the grip stage
  and the hold before the tug were not needed), two quick small tugs straight after the grip
  (`"tugs"` 2 in 0.5 s, `"tug"` 1.2 cm, the shield moving 0.7; one tug of 3 cm over 0.8 s was
  too big -- Kirill: "two quick small tugs" that "barely move the shield"), and the hand
  leaving as the shield goes down (`"lower"`, `"reach_out"`; it used to be gone before the
  shield moved), already on its way while the fingers open (`"grip_open"` 0.54-0.61 against
  the hand from 0.57; they opened fully first -- Kirill: "nobody holding something waits until
  the fingers are off to remove their hands"; see the realism aim in `custom_animations.md`). The shield's own timings are `strap` entries now (`"raise_to"`, `"view_in"`,
  `"tug_at"`, `"grip_open"`). Lowering, the board went 1.3-2.4 cm into the thigh (the fidget
  poses the arm after the relaxed carry's keep-off): it has that keep-off of its own on the way
  down (`_swing_shield_off_body`, `_fidget_shield_push`), faded in as it lowers -- on the way
  up it moved the board under the arriving hand, and switched on at once it threw the board
  21 cm in a frame. Along one
  curve bowed toward a place to the RIGHT of the edge in the view (`"rim_around"`: 0.4 m
  right, 0.08 up; at 0.2 / 0.03 it passed 1 cm from the board's lower corner). Bowed toward a
  place in front of the edge it rose straight up through the board; a place out from the
  board's middle lay ABOVE this edge; two straight moves (up beside the edge, then across)
  turned a corner (Kirill: "an angular pattern"). Two things moved the grip with each breath: the rim point was picked afresh every frame
  and flipped between neighbouring vertices (now kept once the shield is up, `_rim_pick`), and
  the shoulder's 2 cm rise and fall swung the forearm and board 3.5 deg. The left forearm is
  now held still against the eyes once up (`_forearm_held`; the upper arm is turned to it and
  takes the 0-2.7 cm difference at the elbow). That moves the lower arm bone's own POSITION,
  which no clip has a track for: it stayed, and the upper arm came out 4 cm shorter after each
  run (Kirill: the shield "changes its position permanently"). It is put back at the start of
  the next frame (`_elbow_restore`). Any script that sets a bone's position must do the same.
  Drawing the board still and leaving the forearm
  to move put the forearm 2-3.5 cm off the board's back, in view. With the hand setting off while
  the shield rises, the pick (re-made each frame until the shield is up) crept 1-2 cm a frame
  and at times flipped 10-22 cm along the rim: the hand jerked to 4.4 m/s for a frame (Kirill:
  "sometimes the right hand jitters"). The point now follows the pick on the board through a
  damped spring (`_rim_local`, `RIM_GLIDE`); an eased follow still turned the hand's way in one
  frame each time the pick changed. The thumb went through the board both ways (Kirill): the
  hand arrived open with the thumb's tip 4 cm past the far face, and it crossed as it closed
  and as it opened. It now closes while the hand is still off to the side and opens once it is
  off again (`"rim_thumb"`), and the grip sits 1 cm toward the near face (`"rim_across"`; at
  2 cm the forefinger's tip went through the far face in the tug). The probe tests each finger
  bone against the board's triangles (CLIP lines). Later the same day (Kirill's screenshot: a
  finger in the board during the grip) the probe tests each finger as THICK (its line and four
  lines `FINGER_RADIUS` 9 mm off it): the thumb's last joint and tip were in the near face all
  through the grip while its line stayed out. Closing it more fixed it (`"rim_thumb_closed"`
  1.1, was 0.9: its tip 1.7 cm off the grip point on the near side, from 0.3; at 0.6 it stopped
  on the far side and went through, at 1.3 it stood off the face). Left: a fingertip's skin
  touching for one frame now and then. Probe:
  `tools/weapon_probes/strap_path.gd`. Earlier rim notes: the right
  hand grips its RIM, tugs once -- the
  shield moves 0.6 of the tug, `_shield_tug` -- and lets go; only with a shield on the
  forearm. The rim is any model's own vertices on its outer edge, `_shield_rim`, read at
  `equip_shield`; the point gripped is the one on the board's RIGHT side -- its way from the
  board's middle most nearly the Player's right ("just a rim on the right") -- with
  penalties for being out of reach or out of a 30 deg cone round the view. Kirill: "grab by shield's edge instead, seems more universal for
  different models". On the way: an ellipse fitted to the board's box missed the mesh by
  7 cm and aimed at the wrong side; the rim nearest the shoulder was the top edge, level with
  the eyes, because the shield was held too high -- now lower and nearer the middle,
  `"shield_arm"` (0.25, -0.32, -0.4)) and `lantern_look`
  (only while lit: the palm behind the lantern as in the lantern action, swung 65 deg forward,
  turned once 70 deg about its own long axis and back -- `_lantern_spin`; a sideways swing one
  way and the other read as "shake twice" -- let back). The palm is on the lantern's SIDE so
  the hand carries the turn ("the lantern turns without the hand moving"); letting go, the
  hand leaves outward first and the fingers open before going back to the clip's (the thumb
  went 3 cm through the lantern), overlapping the lowering (it rested on the lantern first:
  "a pause before letting go"). The clip's hand rests only about 8 cm from the lantern, so
  the view starts back up as the hand lets go (`"view_out"` 0.6): with the view still dipped,
  the hand at rest beside the lantern read as "hover"; now it leaves the picture moving.
  The view is back up by 0.82 (`"view_back"`). Lifted, the lantern also LEANS 50 deg away
  from the body's middle (`"lean_degrees"`): turning, its top cap (by the hook on the hip)
  swung 2.2 cm into the belly with the left foot forward; a bigger lift only raised the cap
  toward the belly, and turning the other way clipped with either foot. After Kirill moved
  the hook onto the belt (`LanternHook` in `scenes/player_body.tscn`, 1.4 cm nearer the
  middle, 2026-10-14) the lean went from 35 to 50 deg and the lift from 65 to 50 (35 as
  reached). The lantern action, the armed lift and the shield measured the same as before
  the move. Re-run `sheathed_fidgets.gd`, `lantern_feet.gd` and `lantern_armed_action.gd`
  after moving the hook again. The body's own arm cannot bring the hand into the
  picture looking ahead, so these DIP THE VIEW to what they look at (`"view"`, as the lantern
  action does, never lower than the Player looks), and moving the mouse ends them
  (`looked()`, from `player.gd`; it also restarts the wait). Their arm is `_fidget_sheathed`,
  called from `_place_lantern`. Measured (`sheathed_fidgets.gd`): the palm in the picture
  while held (strap about 25 deg left and 15 below the middle, the shield near the middle;
  lantern_look about 30 below); the lantern's first set (palm under its bottom, 35 deg lift)
  put the forearm 11 cm into the body by the left thigh and the palm never in view. `strap`
  replaced `hand_flex` (the hand in front of the chest opening and closing a finger at a
  time; "doesn't look good", Kirill). Its first set (shield lower and nearer, straight up,
  the strap mid-forearm, the right elbow down and back) put the right palm out of view, the
  right forearm 18 cm into the trunk and the shield 7 cm through it on the way: now the
  shield higher and further out, up by way of `"shield_around"`, the strap near the wrist
  (`"strap_along"`), the right elbow out to the right and its way in bowed out in front --
  every reading within a hanging arm's 3 cm, the shield 7.6 cm clear.
- **`brush_off`** (2026-10-15, weapons sheathed, not judged in game yet): the right hand
  brushes dust off the shield's face, or with no shield (or one held in the hand: it does not
  play then) off the left forearm's sleeve -- three strokes of irregular length, each pulled
  along the surface with the finger pads and brought back lifted 3 cm, the last sweeping on
  past the edge and lifting off (the flick), the hand leaving from there
  (`_fidget_brush`, `"brush"` in `FIDGETS`). The left arm's raise for the shield is the strap's,
  shared now (`_raise_shield`; the strap's probe output is identical to before), plus a roll of
  the forearm turning the face toward the eyes (`"face_to_eyes"` 0.65, `_roll_shield_face_to_eyes`).
  The shield is a flat board (its face rises under 1 cm off a plane, no boss; 0.44 x 0.96 m),
  so the hand follows the face's plane. What the search found (`brush_off.gd -- --search`):
  turned fully face up with the forearm across the chest, the board's top end goes 16 cm behind
  the eyes into the trunk; strokes run out from the board's middle end 0.65-0.96 m from the
  right shoulder whatever the hold (the arm reaches about 0.6 to the palm). So the strokes
  first PULLED toward the right hand, from the middle to the face's point nearest the right
  shoulder (`"edge_margin"` inside the board's box), and flicked off that edge. Since the same
  day (Kirill drew it on a screenshot) they run ACROSS the board near the right hand and PUSH
  away: crossing that old line `"cross_back"` (0.11 m) back from its end, from the near edge to
  the far one (`"edge_margin"` inside each, at most `"length"` 0.3 m), the flick off the far
  edge by the notch -- "away" is toward the left wrist (fixed on the board; judged by the way
  from the eyes it flipped while the board rose and the hand jumped at 14 m/s). The line is
  placed from the board's own box, so another shield model gets it too. Measured with it: the
  face 46 deg off the eyes, the palm 3-26 deg below the picture's middle through the strokes,
  fingertips at most 0.7 cm in, the palm at most 3.6 m/s. The view dips 68 and turns 8 right.
  Then (Kirill: "a little slower", bent fingers "look like we're scratching the shield", "the
  start of the brush should be slower and faster at the end"): the strokes take 1.55 s (were
  1.25; the fidget 2.9 s), the fingers are flat (`"curl"` 0.05 / 0, no `"drag"`), and on the
  surface a stroke goes as x^2 -- from rest, fastest at the end -- then lifts while still moving
  and runs on through the air before coming back (a cubic leaving the end at the stroke's
  speed); the last runs on `"flick_on"` (0.5 of the line) as it lifts. The far end was at the
  arm's limit (1.9 m/s to 0.2 in about 0.07 s): `"reach_soft"` 0.04 and the shield held nearer the right hand
  (`"shield_arm"` (0.22, -0.31, -0.45); at (0.26, -0.3, -0.42) the board went 5.8 cm into the
  body). The flat hand read 1.6-2.8 cm off the face: the palm point is about 1.5 cm below the
  palm's skin, so `"above"` is -0.01 (laying the fingers along the surface changed nothing).
  Measured: a stroke 0.4 -> 1.1 -> 1.7 -> 2.4 m/s to its end, on 12-15 % of the line past it,
  the flick 26 %; the finger bones' line 0.7-1.8 cm off the face (pads on it); the shield's room
  0.0 / -3.3 cm (left / right foot forward); shoulder to the line's ends 0.33-0.39 / 0.51-0.58 m.
  Then ("raise the shield slower and add a little pause between brushes"): the raise, the
  hand's reach and the view's dip take 1.1 s (were 0.78), and after each stroke but the last
  the hand rests at the start about 0.15 s (`"pause"`, a share of the stroke; the strokes
  themselves as fast as before): the strokes 1.07-2.92 s, the fidget 3.5 s. Measured: the palm
  still (under 0.1 m/s) 0.15-0.2 s between strokes, at most 4.0 m/s, nothing else changed.
  Then "some of the brushes are too fast": the strokes' lengths in time are spread +-12 %
  (`"spread"`; at the shared `IRREGULAR_SPREAD` 0.26 the shortest was 1.7 x quicker than the
  longest -- `_irregular_progress` takes the spread now) and the strokes take 2.1 s with the
  pauses (were 1.85), the fidget 3.75 s. Measured on one seed: the three strokes peak at 2.45,
  2.10 and 1.90 m/s at their ends (were up to 2.6-3.3), the lifted way back up to 2.5 m/s.
  Then "the return stroke of the brushes seems very quick and robotic" (an even sin^2 lift of
  3 cm straight back over the line in 0.29 s, to the same start each time): the way back takes
  about 0.45 s (the strokes 2.6 s, the fidget 4.25 s), rises quickly off the end and settles
  slowly onto the start (sin^2 of pi u^0.6: the top a third of the way back, `"lift"` 5 cm),
  bows 2.5 cm to one side (`"return_aside"`), ends at a start up to 2 cm off the last one's
  (`"jitter"`, new each play), and the fingers curl a little in the air (`"lift_curl"` 0.25).
  Measured: the way back 1.4-2.0 m/s at most (was 2.5), the strokes as before.
  Then "the arm movements are choppy and not fluid enough". The probe now ranks JERK (how
  suddenly the acceleration changes, m/s^3, from the third difference of the palm's and the
  right elbow's places a frame apart; acceleration alone is high in any quick loop and says
  nothing). The worst, 3,300 (elbow), had three causes: (1) the pieces of each stroke met with
  the same speed but not the same change of speed (x^2 then a cubic, and a lift that started
  with a kink) -- now 2x^3 - x^4 on the surface, a quintic back (`glide` in `_fidget_brush`),
  bumps u^3 (1-u)^5 and (u (1-u))^3 for the lift and the bow, smootherstep for the shift;
  (2) the far end with the arm all but straight (the elbow swings there) -- the strokes stop
  `"far_margin"` 8 cm inside the far edge, 0.26 m long, `"flick_on"` 0.35, `"reach_soft"`
  0.08, faded out with the reach (at full softness it held the hanging hand off the clip's and
  it snapped back when the reach let go); (3) the hand leaving at 2.5 m/s in 0.63 s -- now
  0.86 s, the fidget 4.5 s. Measured: the worst jerk 1,100 (palm, at a stroke's end), the leave
  under 760, the palm at most 2.3 m/s.
  Then "there should be some space before the brushes, but they also have to be one continuous
  fluid motion": the pause is a SETTLE, not a rest. The way back ends `"settle_creep"` (0.06 of
  the line) short of the start and `"settle_lift"` (1.5 cm) above it, already sinking; there it
  turns from going back to going forward while moving down, so the hand never stands still;
  through the pause it lowers onto the surface while setting off forward, and the next stroke
  starts from that creep (`glide` takes an end speed now). Asked to arrive moving forward, the
  way back overshot that place and came back -- two near-stops of 0.08 m/s. Measured: the palm
  0.10-0.2 m/s for about 0.2 s between strokes, touching down near the end, then speeding up;
  the worst jerk about as before (1,375).
  Then "the shield's top part is an irregular shape, so currently the hand flies off way past
  the actual edge": the line's ends were found on the board's BOX, and its top has a notch
  20 cm deep (the top edge at model y 0.32 right of x -0.01, 0.12 left of it); the line ended
  3 cm into the notch's air and the palm went 14-19 cm past the real edge. Now the line is cut
  with the real outline (`_shield_outline`: `_shield_rim` on the face, sorted round the middle
  and joined into edges at `equip_shield` -- the rim points are the mesh's vertices, and the
  notch's straight wall has none along it, so "points near the line" found nothing). The
  strokes are 0.18 m now (the notch's wall bounds them). The flick ends `"flick_past"` (3 cm)
  past the real edge (`_brush_flick`, in lines): a quintic over the whole flick from about
  2 m/s overshot to 15 cm past the line's end and came back, so it now slows along the line
  only over the share of the time it can without overshooting (m <= 2.5 d) and the lift rises
  over the first half; the hand leaves from 3.22 s, as the flick ends (from 3.54 it hovered at
  the edge 0.35 s), up and away (`"leave_around"` 0.25 m up; at 0.12 it sank back to the edge).
  Measured (probe `EDGE` line, `-- --no-outline` for the box): the palm at most 1.7-2.2 cm past
  the real edge, 13 cm above the face as it leaves, the worst jerk 715.
  Then "the hand seems to hover a bit at the end of the last stroke" (it stopped along the board
  at the edge and rose 9 cm at 0.45-0.58 m/s for 0.3 s before a separately eased leave took it):
  THE FLICK AND THE LEAVE ARE ONE MOVE now. From the instant the last stroke ends (worked out
  between two frames, `_brush_p_before`; started at the frame itself, the hand stuck for a frame,
  2,100 m/s^3) the hand keeps its speed along one curve of quintic pieces (no change of speed at
  the joins; as cubics, 2,600 m/s^3 at the flick) through a place `"flick_past"` beyond the real
  edge and `"flick_lift"` up (`"flick_time"` 0.15 s), back over the board to `"leave_over"`
  (0.16 m) above a place `"leave_clear"` (0.1 m) out past the near edge (`"over_time"` 0.3 s;
  straight from the flick to the hip it went through the board, and above the line's start
  itself the drop cut its near part), and down to where the clip holds the palm at the hip
  (`"leave_time"` 0.55 s), arriving at rest; placed in the Player's space. From the flick's top
  to half way down the palm turns to face the way the clip's palm does and the brushing roll
  fades (still facing the board, the clip's palm place was out of the straightening arm's reach
  and the hand swung 6 cm off for two frames, 4-5 m/s with no shield; steering the elbow to the
  clip's side did not help, handing back earlier moved the elbow under the moving hand); the
  reach's weight lets go over the last half of the last piece (`"leave_turn"`). With no shield
  the "over" place is on the way from the flick to the hip. `"reach_out"` and `"leave_around"`
  are gone. Also: the way in bows further out (`"around"` (0.3, 0.05, -0.15), `"come_from"`
  0.3), the right hand sets off at 0.3 s (`"reach"`), and the shield rises by way of
  (-0.1, -0.3, -0.55) (`"shield_around"`): the rising board met the hand on its way in.
  The probe now plays fixed seeds (`-- --seed <n>`, 1 by default: each fidget draws its seed
  from the global random numbers, so runs differed), traces the palm's speed from the last
  stroke (`LEAVE`) and tests the right hand's palm, wrist and finger ends against the board's
  real outline and thickness (`INSIDE`, with how deep; the palm point counts only 2.5 cm under
  the face, finger ends get 5 mm). Measured (seeds 1-3): the flick turns at about 0.4 m/s for an
  instant and the hand never stops on its way to the hip (2.9 m/s at most), the worst jerk about
  1,060 m/s^3, no shield at most 2.5 m/s. STILL OPEN: the rising board's edge goes through the
  right hand's fingers for 2-3 frames at about 0.6 s (2.2 cm in with the left foot forward, 4.7
  with the right), and the fingers touch its near part for 1-2 frames at about 3.7 s.
  Then "the right hand leaves by going up towards the left shoulder, doesn't make sense": the
  "over" place was 11 cm LEFT of the eyes and only 13 cm below them -- the flick goes off the
  board's edge on the right, ahead, and the hip is below on the right. The detour had been added
  because the hand seemed to go through the board on the straight way, read off the board's box
  (before the outline check existed). Now the hand drops: the middle place is `"leave_over"`
  (0.4) of the way from the flick's top to the hip, `"leave_out"` (6 cm) further right, and the
  flick runs 5 cm past the edge (`"flick_past"`; at 3 cm the thumb clipped the board's right
  edge, 3.8 cm in, as the hand dropped past it). `"leave_clear"` is gone. Measured (seeds 1, 3):
  the places from the eyes -- flick ends (0.16, -0.38, -0.07), its top (0.25, -0.37, -0.16), the
  middle (0.29, -0.51, 0.06), the hip (0.20, -0.73, 0.37); the palm 6.6-10 cm past the real edge
  at most; at most 1 fingertip frame in the board on the way out; the arm's room to the body
  -0.02 / 0.00 (was -0.16); the worst jerk about 1,000 m/s^3.
  Then Kirill drew the way he wants it on a screenshot: not up and sharply down through the
  middle of the picture, but one wide arc -- on ahead past the edge, curving out to the RIGHT and
  out of the picture there. The middle place is now `"leave_out"` (0.3, -0.03, 0.05) m from the
  flick's top (the Player's axes); `"leave_over"` is gone. Measured (seed 1, left foot): the
  places from the eyes -- the flick's top (0.26, -0.38, -0.16), the middle (0.56, -0.41, -0.11);
  the palm in the picture 22 right / 18 down -> 29 / 3 -> 40 / 1 -> 50 / 9 -> out past the right
  edge at about 3.6 s, where it slows to about 0.5 m/s as it turns down toward the hip (out of
  sight from there: the view comes back up); nothing in the board on the way out; the worst jerk
  under 1,000 m/s^3.
  Then "the wrist bend down/forward on the end of the exit doesn't look natural" (Kirill's
  screenshot: the arm out to the right, the hand drooping): the palm still faced the board's
  way, which with the forearm reaching out to the side bends the wrist down toward its limit.
  The leave now turns the hand in two steps: it RELAXES first -- palm to facing down, the roll
  fading, the fingers loosening into a curl (`"leave_curl"` 0.3) -- from the flick's start to
  half way out; facing down, the palm lies square to the outstretched forearm and the wrist
  runs straight on. Then from half way out to half way down to the hip it turns on to the
  clip's way. Measured (probe `LEAVE`: the wrist's bend and the palm's way): through the sweep
  out the wrist bent 4-16 deg, the palm facing down (0, -1, 0); 26 deg at most while turning
  to the clip's, the clip's own 17 at the end; no jumps, the worst jerk under 1,000 m/s^3.
  Then Kirill marked the sideways part on a screenshot: after the last stroke "the hand moves
  laterally ... and then leaves back to idle. can we remove the [lateral part] and start the
  leave to idle in one smooth motion after final brush". So the waypoints are gone: from the
  last stroke's end the hand follows ONE quintic to the clip's palm place at the hip
  (`"leave_time"` 0.8 s), starting at the stroke's speed and way, carrying on past the edge by
  that speed and bending round; `"leave_lift"` (6 cm, u^2 (1-u)^6, the top a quarter of the way)
  lifts it off the face early. The hand relaxes by `"leave_relax_by"` (0.3 of the way), turns to
  the clip's way by `"leave_turn_by"` (0.72), and hands back over the last `"leave_turn"` (0.3).
  Gone: `"flick_*"`, `"over_time"`, `"leave_out"`, `_brush_flick`, the apex and middle places.
  Measured (seeds 1, 3): the palm 1.3 m/s at the stroke's end, about 0.7 as it turns, up to
  1.6, at rest by about 3.8 s; 9.5-12 cm past the real edge at most; nothing in the board on
  the way out; the wrist up to 36 deg while it turns; the worst jerk 1,350-1,540 m/s^3 (the
  elbow as the hand arrives at the hip).
  That went "back to the arm going straight down after the final brush" -- Kirill wants the arc,
  "just without the straight lateral movement" (his second screenshot: up, a rounded top, then
  down and out to the lower right). So: an ARCH through two places (quintic pieces, Catmull-Rom
  speeds, as before): a top `"arch_ahead"` (0.1 m) on along the stroke's way and `"arch_up"`
  (0.07) off the face (`"arch_time"` 0.2 s), then `"arch_down"` (0.22, -0.15, 0.12) m from the
  top -- out to the right AND lower, which is what removes the straight sideways part (the
  earlier middle place was at the top's height) -- (`"down_time"` 0.3 s), then the hip
  (`"leave_time"` 0.45 s). `"leave_lift"` is gone (the top lifts the hand). Measured (seeds 1,
  3): in the picture the palm 22 right / 18 down -> 28 / 4 -> the top 33 / 0 -> 41 / 9 -> 45 /
  28 -> out at the bottom right; about 0.5 m/s at the top and 0.8 coming down through the middle
  place, never stopping; nothing in the board on the way out; the wrist 1-19 deg; the worst jerk
  under 1,000 m/s^3.
  Then Kirill found the lift at the top unnatural and set `"arch_up"` to 0; with no lift the
  hand cut through the board (the top only 2 cm past the edge with the palm's middle, its heel
  still over the board), so he set `"arch_ahead"` to 0.5, which carries it well past the edge
  first. `"arch_up"` was then removed. Not measured with the probe since.
  Then "as we brush the shield, the entire shield shift up and down just a couple of cm, can we
  tilt/rotate the top part up and down a little instead": `"press"` moved the held forearm
  bodily into the face under each stroke (the probe's `BOARD` line: the whole board 6.5 mm up
  and down, 5 mm front to back, no turn). On the shield the board now TIPS: the held forearm
  rolls about its own line by `"press_tilt"` (2 deg at the hardest press) the way that moves the
  place being pressed (`_brush_press_at`, the hand's goal) into the face (`_raise_shield`'s
  `tilt`); `"press"` is only the forearm's give without a shield now. Measured: the face turns
  1.7 deg; the brushed part near the top dips 7.5 mm, the middle moves 5 mm (it is off the
  forearm's line), the far tip rises 1.8 cm; the fingertips on the face as before.
  Then "every stroke follows the same line each time, can we make it a cone of possible lines
  instead, but I guess the last one is always the same" -- "relatively tight ... just for some
  visual variety": every stroke but the last is turned about the face's normal by its own angle,
  up to `"cone"` (6 deg) either way, new each play, about the strokes' common start; each at most
  as long as the last and ended `"far_margin"` short of where it leaves the outline (the outline
  cut is a function now, `outline_exits` in `_fidget_brush`). The line keeps each stroke's end
  (`_brush_line[3]`); on the way back and through the settle the hand goes over from one
  stroke's line to the next's as the shift does. The last stroke keeps the line it had. Written
  while Kirill's game was running: NOT run in the probe yet.
  The hand is rolled 0.5 rad about its fingers (`"roll"`; without it the forefinger's tip was
  1.6 cm in the board, the little finger's 2 cm off). Leaving, the hand's goal is held where
  the flick ended once the shield lowers, and it leaves up and right (`"leave_around"`):
  following the board it chased it down at 5.8 m/s, and leaving toward the hip the lowering
  board's corner swung 4-10 cm into it. Measured: face 33 deg off the eyes, the palm inside the
  picture through the strokes (up to 41 deg below the middle at a stroke's near end with the
  sleeve), fingertips at most 0.7 cm into the surface (skin contact), the shield's room to the
  body +1.2 / -2.1 cm (left / right foot forward; the strap's was +7.6), the right forearm's
  room -0.07 to -0.09 on the way in (out of the picture; a hanging arm reads -0.03), the palm
  at most 3.3-3.6 m/s leaving. Each stroke pushes the board / forearm in 8 mm (`"press"`) and
  bends the fingers a little (`"drag"`).
- **Shadows** come from a hidden third copy of the whole body (`RogueShadow`) with its own
  arm pose (`_pose_shadow_arms`): the hands brought in to `weapon_shadow_reach` from the
  shoulders and the elbows turned down by `weapon_shadow_elbows_down`. Without that the
  shadow was a T-pose. The copy's head and hood are hidden, not set to cast nothing (they
  are shadows-only meshes; switching casting off made them drawn).

## 4. Sheathing on the back and the draw

Why the back: a sheath on the hip needs a sheath model per sword and a clip that fits each
blade into it (Kirill). The shield stays on the arm.

- `weapon_sheath_on_back`, `weapon_draw_time` (0.8 s), `weapon_draw_grab` (0.4: the share of
  the time up to the grip on the back). `_weapon_up` runs 0-1; below the grab share the sword
  is on the back (`_weapon_on_back`, placed by `_back_socket()` on the upper chest:
  `weapon_back_offset`, `weapon_back_slant`, `weapon_back_turned_over`).
- `_draw_arm`, two parts:
  1. To the back, on the BODY'S shoulder: the fist goes from the clip's pose along a curve
     through `weapon_draw_arc` and `weapon_draw_arc_up` (`_through`, a curve through points)
     to the grip; the wrist stays relaxed until `weapon_draw_arc_at.x`.
  2. Into the stance: the shoulder becomes the stance's AT ONCE at the grab moment, and the
     fist goes grab -> `weapon_draw_out` -> `weapon_draw_via` -> stance, the blade turned by
     way of `DRAW_BLADE_OVER`.
- The view leans left through it (`weapon_draw_head_tilt` 4 deg, `weapon_draw_head_turn`
  3 deg, most at the grab; added to the mouse's look in `view_offset()`; camera only, the
  shadow's head does not lean).
- `shield_raise_from` delays the shield so it does not come into view before the sword.

What each part fixed (all seen by Kirill looking straight down or ahead):

- Looking down, the sword seemed drawn "directly into the head": the blade passed 1 cm from
  the eyes. The middle blade direction and the outward via-point give 0.29-0.32 m.
- "Reaching into their ear and then pulling the sword out half a metre to the right": the two
  arm states (body's shoulder, stance's shoulder) are swapped in one frame at the grab, when
  both poses are out of the picture. A blend between them is seen.
- The hand went straight up and came down further out: the reach goes round through set
  points instead (the arc he drew in red).
- The Mixamo clip `D:\Downloads\Sheath A Great Sword 1.fbx` was looked at as a reference
  for the motion; nothing of it is in the project.

## 5. The shield

- **Combat hold**: `_hold_shield` solves the left arm to `ShieldStance`, turned with the view
  like the sword arm.
- **Keep-off looking down** (`_shield_off_body`): the shield is slid along
  `shield_clear_toward` until a set of body points is outside the shield's own box grown by
  `shield_body_clearance`; `shield_clearance_ease` / `_return` smooth it. It reads the
  shield's mesh box, so it works for any shield. The legs have their own clearance,
  `shield_leg_clearance` (0.1; it was half of `shield_body_clearance`, which the scene sets
  to 0.12): at 0.06 the left thigh reached the board jogging back looking straight down
  (Kirill, 2026-10-14).
  **Turned before it is moved** (2026-10-19, Kirill: moved alone, the arm came out of the
  picture's left edge looking down; he drew it kept near the trunk with the shield turned):
  `_shield_turn_off_body` swings the forearm about the elbow round the Player's up
  (`shield_clear_swing_max`, 35) and rolls it about its own line (`shield_clear_roll_max`,
  45), picking the turn with the least remaining move + `shield_clear_turn_cost` (0.05 m per
  full turn per axis); the slide clears only what is left. The search tries a step
  (`shield_clear_turn_step`, 3 deg) round the last turn found plus a coarse 5 x 5 grid over the whole
  range: with only the steps it got stuck at 3-6 deg. Measured looking straight down with weapons up (`shield_backward.gd`,
  `--no-turn` for the old way): move 0.25-0.28 -> 0.01-0.18 m, turned 23-35 / 44-45 deg;
  least room to the body 0.03-0.12 m (was 0.03-0.10; jogging left 0.05 -> 0.03, right 0.03 -> 0.12).
  Both maxima 0 = moved only. Not judged in game; cost per frame not measured (about 34 box tests).
  It twitched with the breathing looking far down (Kirill, same day): the face rolled +45 and
  -45 cleared about as well and the choice flipped 42 times a second
  (`tools/weapon_probes/shield_turn_twitch.gd`). Now the turn held is kept unless another beats
  it by `shield_clear_turn_hold` (0.02 m), the coarse grid never offers the other side of a
  turn under way, and the turn changes at most `shield_clear_turn_speed` (120 deg/s). Measured:
  no change at all held straight down, at most 2 deg a frame tipping down; jogging looking down
  the least room is 0.085-0.126 m.
  Crouched, left foot forward, a quick look down put the board 4.3 cm into the left shin
  (Kirill, same day): the speed limit held the turn back while the move was sized for the
  finished turn. The move is now worked out for the turn the arm has (`_shield_slide_at`) and
  `shield_clearance_ease` is 0.04 (was 0.08; at 0.02 the roll flipped sides once).
  `tools/weapon_probes/shield_quick_look.gd` (looks in 0.1 / 0.25 / 0.5 s, either foot):
  least room 0.034 m (was -0.043). After a quick look the board stands up to 0.21 m off the
  leg for a moment and comes back to 0.10 over about a second, as the turn catches up.
- **The weapon keeps off the body too** (2026-10-14; Kirill, looking straight down in the
  inspect fidget: "pommel clips through body" -- 17 cm in): `weapon_body_clearance` (0.18) /
  `weapon_leg_clearance` (0.1), the box of the weapon's model (`_weapon_low` / `_high`, read at
  `equip`), the whole arm moved FORWARD level with the ground (Kirill's choice over moving it
  right). Runs on every held pose: stance and fidgets. The weapon is measured as a CAPSULE
  along its box's longest side (`_weapon_off_body`, the smallest forward move found by
  halving) and the push follows on a damped spring (`weapon_clearance_smoothing`, 0.15 s): it
  first used the shield's box test (`_keep_off_body`) and easing, whose wanted push jumped
  2-3 cm a frame as the sword turned (a sawtooth, and 18 cm -> 0 in one frame) -- "choppy"
  (Kirill). Now smooth, up to about 25 cm forward looking straight down in inspect; there the
  sword is 1 cm into the body's capsules for a moment as the push starts (the spring's lag),
  then 4-12 cm clear; level: no push. A first fix that capped how far a fidget follows the view down was dropped for this
  ("so it works with all weapons").
- **Keep-off in the relaxed carry** (`_keep_relaxed_off_body`, 2026-10-14): the same test on
  the shield as carried, the arm swung out from its own shoulder by the push (shortest of
  left, left-forward, left-back). Before it the backward jogs put the sheathed shield 8-9 cm
  into the left thigh. `tools/weapon_probes/shield_backward.gd` measures every jog direction
  weapons up and down, looking down and level.
- **Relaxed carry, weapons down** (`shield_relaxed_carry`, `_relax_shield_arm`): the clip's
  arm, with the forearm rolled so the shield faces `shield_relaxed_faces` (away from the
  trunk, parallel to the body) and the hand set to the turn it has in the stance
  (`_shield_hand_in_stance`), so the palm stays in the strap. Kirill's words: a "relaxed"
  sheath state, the combat state being the stance. It rolls the forearm about 85-98 degrees
  from the clip.
- **Mirrored idle**: standing right foot forward clipped the shield arm into the body where
  left foot forward did not (the torso is turned the other way). `_mirrored(animation,
  legs_only = true)` mirrors the legs only and turns the spine part-way
  (`idle_mirror_torso`, 0.5: "clip is not visible like that, good enough"). A full torso
  mirror "looks kind of weird".

## 6. The lantern action with weapons

The action itself is in `docs/custom_animations.md`. What weapons add (`_place_lantern`):

**Left hand, in a shield's strap (`strapped`), weapons up or down.** Kirill's decision: the
hand stays in the handle; ring and little finger keep their hold, thumb, forefinger and
middle finger pinch the knob and roll it between them (`toggle_knob_roll_strapped`); the
wrist does not turn (the palm would go through the straps). `_reach` gets the hand's turn
on the forearm as a `Quaternion` (`given`), which locks the wrist. Then the forearm's roll
about the elbow-to-pinch line is searched each frame (24 rolls, body points with
`TOGGLE_TRUNK` / `TOGGLE_LEG` radii, 0.03 of hysteresis) to keep the shield off the body.
`toggle_strapped_elbow` is the best of 27 elbow sides tried.

**Right hand, with a sword in it (`armed`).** The sword comes along; since 2026-10-14 the
fist goes in behind the hanging lantern and LIFTS it forward from under it, the blade ahead
and a little down (Kirill: in the knuckles version below the fist sat above the lantern's
middle -- `toggle_armed_fist` had +Y -- and "the sword lands on top of the lantern"). The
history first:

| Tried | Measured |
|---|---|
| Palm against the lantern, as the open hand | Sword 8-13 cm in the body, 5 cm in the lantern. |
| Palm against it, hand turned to aim the blade (10 directions) | The same: the handle is in the palm. Wrist 72-86 deg. |
| Back of the hand against it | Body clear, lantern still 4-5 cm in, wrist 100-170 deg. |
| Forearm against it, fist past it | Numbers clean, but the "contact" was with the wire handle: Kirill, "nothing touches the lantern". |
| Pommel against it, blade ahead | No pose found. |
| Knuckles against its body, blade ahead | Sword 0-2 cm clear of the body, crossguard about 3 cm into the lantern's top end, blade within 1 cm of the shield's edge. "Looks great" (2026-10-13); the next day: the sword lands on top of the lantern. |
| Fist under it, wrist as the stance has it | The roll only spins the blade about the forearm (`lantern_under_trace.gd`): roll 0 = ahead but 25-35 deg up through the lantern, roll 70-80 = level but pointing right. No pose with the blade ahead. |
| Fist under it, wrist bent to aim the blade (`toggle_armed_blade`), first set | Sword up to 3 cm into the lantern's underside, forearm 3-4 cm into its handle end. "Very good, but the lantern clips through the right forearm slightly and I think the sword hilt does too." |
| **The same, searched for room to the lantern first** | Over the whole action: sword 0-3 cm clear of the lantern, forearm on its surface (0-1 cm), sword 1-2 cm into the body's capsules, shield 2-12 cm clear, arm 1-3 cm into the trunk's. At the knob's turn the palm is 12-13 cm under the lantern's middle. A fist higher than `toggle_armed_fist`'s -0.08 puts the sword into the lantern. |

How it runs:

- The shoulder goes back onto the body for the reach (the lantern is out of reach from the
  stance's shoulder). `toggle_armed_roll` rolls the forearm (which side of the fist faces
  up), then the wrist bends the blade toward `toggle_armed_blade` (at most
  `TOGGLE_ARMED_WRIST_MAX`, 60 deg); `toggle_armed_elbow` is the elbow's side.
- While the lantern still hangs the blade is aimed out to the right and down
  (`toggle_armed_blade_hanging`) and the fist is to the lantern's right: a fist behind the
  hanging lantern with the blade ahead ran the blade 5 cm through it. The aim turns to
  `toggle_armed_blade` with the swing.
- The fist's place is set from the lantern's middle wherever that is:
  `toggle_armed_fist_hanging` before the swing, `toggle_armed_fist` once swung, between the
  two by the swing. It comes in round the back by way of `toggle_armed_around`, so it is
  BEHIND the hanging lantern before that moves and is seen to push it (first version: the
  lantern set off by itself and the hand met its front half-way).
- Its own timing: `TOGGLE_REACH_ARMED`, `TOGGLE_SWING_ARMED` (the lantern sets off later,
  the arm has further to come), `TOGGLE_RELEASE_ARMED`.
- The blade goes from upright to pointing ahead in about a tenth of a second on the way in
  and out. Kirill accepted it; it was 40 % faster before the timing was stretched.

Removed at Kirill's word, do not bring back without asking: a visible chest turn toward
the lantern ("we turn too much", "I can still see the turn"), swinging the lantern leftward
toward the left hand ("it clips through body now"), moving the shield hand away while the
weapons are down. Also removed: a "virtual shoulder turn" (never applied).

`_reach`'s elbow side comes in with the weight (`elbow_now.lerp(pole, weight)`): taken whole
from the first sliver of weight it threw the forearm round, and the sword's tip jumped
0.42 m in the frame the action ended.

## 7. Checking a change headless

Kirill judges how things look; a probe answers what cannot be seen (does it clip, does a
hand arrive, does something jump). **Check `mcp__godot__is_playing` first** and do not launch
over his session.

```
cd D:/Downloads/Godot_v4.7.2-stable_win64.exe
timeout 200 ./Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion \
  --script herald-of-oblivion/tools/weapon_probes/<probe>.gd 2>&1 < /dev/null | grep -E "<TAG>|ERROR"
```

The probes (`tools/weapon_probes/`, kept out of the editor's scan by `.gdignore`):

| Probe | Tag | What it tells |
|---|---|---|
| `lantern_armed_action.gd` | `ACTION` | Weapons up, the whole lantern action at 60 frames a second, either foot forward: least room of each kind (sword against body, lantern, shield, left arm, eyes; arm against body and lantern; knuckles' gap; fist behind the lantern) per tenth of the action, and the fastest move of the blade's tip. `-- --hanging=x,y,z --around=x,y,z` try values. |
| `fidget_room.gd` | `ROOM` | The space each fidget sweeps through (what moves more than 12 cm from its start: arms, held sword, shield, lantern), from the eyes, either foot, standing / crouched / looking 0.6 rad down and up; prints the block for `PlayerBody.FIDGET_ROOMS`. **Re-run and paste after changing a fidget.** About 10 min. |
| `fidget_room_wall.gd` | `WALL` | `_fidget_has_room` against real collision: per fidget, room or BLOCKED with a wall 0.5 / 0.8 / 1.2 m ahead, behind, left, right, and a trunk ahead; a fidget playing is ended when a wall appears; none starts by itself in front of one. |
| `lantern_crouched_screen.gd` | `SCREEN` | Weapons up, crouched, the lantern action: where the fist and the blade's middle and tip are on a 1280 x 720 screen every 3 frames, with the view's dip, turn and tilt. A path the player sees (the view moves too), not one in the body's space. `-- --mirrored`: right foot forward. |
| `lantern_armed_search.gd` | `SEARCH` | Thousands of fist places, elbow sides and rolls at the knob's turn, one per tiny frame, kept where the blade points ahead and the knuckles (or pommel) touch the lantern's body. `-- --under`: fist places under the lantern with blade aims, kept where any part of the hand touches its underside. |
| `fidgets.gd` | `FIDGET` | Every fidget, either foot forward: per tenth the sword's room to the eyes, body and shield, the arm's to the trunk, the fist from the eyes and the blade's way; the tip's fastest move; then one starting by itself and a key ending it. |
| `brush_off.gd` | `BRUSH` | `brush_off` with the shield and with none, either foot, a fixed seed (`-- --seed <n>`): per 1/20 the palm in the picture, the palm's and fingertips' height off the brushed surface (only over the board), how far along the stroke line, the arm's and the shield's room to the body; the palm's fastest move and when; `STROKE` / `LEAVE` the palm's speed through the strokes and the leave; `JERK` the twelve sharpest changes of acceleration of palm and elbow; `EDGE` how far past the board's real edge the hand goes; `INSIDE` hand points inside the board (outline and thickness), when, which and how deep. `-- --search`: shield holds x face turns, held at the first stroke: room, the face's angle off the eyes, the right shoulder's distance to the line, the line in the picture. `-- --no-outline`: the line placed from the board's box. |
| `sword_fidget_shield.gd` | `SAG` | The sword fidgets with `"shield_rest"`, weapons up, either foot: how far the shield's middle drops below the stance and when, its least room to the trunk and legs against the stance's, the sword's least room to the shield. |
| `sheathed_fidgets.gd` | `SHEATHED` | The sheathed fidgets, lantern lit, either foot: the view's dip and turn, where the palm is in the picture (and whether it is in a 16:9 picture of the camera's fov), the arm's room to the body, the palm to the lantern's body and its lift. |
| `animation_panel_check.gd` | `PANEL` | The panel's body side: the stages listed, a driven pose held still through a key press and past the end, released back to the stance; the panel builds. |
| `breathing.gd` | `BREATH` | Standing still, weapons up, both idles, breathing on and off: how far the chest, the sword's grip and the shield move against the eyes, and the largest step a frame. |
| `shield_backward.gd` | `SHIELD` | Jogging in six directions, weapons up and down, looking straight down and level: the least room between the shield's vertices and the trunk's and legs' capsules, and how far the keep-off pushed. |
| `lantern_under_trace.gd` | `TRACE` | For fist places under the swung lantern and four rolls: where palm, wrist and knuckles end up, and where the blade points. |
| `lantern_feet.gd` | `LANTERN` | The action with the shield, weapons down and up, either foot: does each hand arrive, does the left hand stay in the strap, shield against body. |
| `arm_against_trunk_mesh.gd` | | The left arm against the trunk's own skinned mesh. |
| `lantern_end_jump.gd` | `JANK` | Frame-by-frame steps of sword, shield, hands, eyes at the action's end. |
| `draw_from_back.gd` | | The draw and the sheathing: the sword's mesh through it, the fist in the view. |
| `combat.gd` | `COMBAT`, `COMBO` | Section 13: the swings, the block, the bash and the blows, either foot, per 1/20: sword's room to eyes, body, shield; shield's to eyes and body; the right forearm's to the trunk; wrist bend and forearm roll; tip and shield in the picture; the fastest tip and elbow step. Then a chained combo: the tip's step at each join. `-- --only=<text>`. |
| `swing_search.gd` | `SEARCH` | REMOVED 2026-10-22 with the hand-keyed swings (in git before): it fitted each swing key's fist, elbow way and edge turn. |
| `arm_lengths.gd` | `ARMS` | Our right arm's lengths, against the mod's (`tools/skyrim_reference/arm_lengths.py`). |
| `stance_numbers.gd` | `STANCE` | Both stances in numbers: grip, shoulders, reach, blade, edge, palm, the shield's middle and face, where they are in the picture. |

How a probe is built:

- `extends SceneTree`; instance `scenes/player.tscn`, switch the Player's processing off,
  then drive it: `body.set_motion(Vector3.ZERO, true, false, false, delta)` and
  `body.advance(delta, 0.0)` per frame. Private state through `body.get("_name")`.
- **Many candidates per run**: while the action holds still (the knob's turn), every frame
  is a full solve from the clip, so set a candidate, step a tiny `delta`, measure. 6,480
  poses took about 20 s. Then run the best through the whole action: the way there can
  clip where the held pose does not.
- Either foot forward: `body.set("_idle_mirrored", true)`.
- Write probes and patch scripts with the Write tool: a bash heredoc with apostrophes or
  backslashes fails.
- A script error never reaches `quit()`: always a time limit.

What the measures mean:

- Bone capsules for the trunk (0.17 / 0.15 m) and legs (0.10 / 0.07 m) are generous. **A
  hanging arm reads 3-4 cm "inside"** by them and by the trunk-mesh measure; that is the
  baseline for "touching", not a fault.
- The lantern: its handle's top is its origin, its body lies 0.14-0.28 m along -Y at about
  0.055 m radius (mesh box: 0.13 wide, 0.10 deep, 0.30 long). Count contact against the
  BODY only (rule R4).

## 8. What is generic and what is fitted

**Works for any model by design** (but only ever run with one sword and one shield):
the hand's socket, the fist closed for a handle's thickness, the shield's keep-off (reads
its mesh box), the forearm-roll search in the lantern action, `equip` / `equip_shield`.

**Fitted to the body, not the weapon**: arms apart and view-following, shadow arms,
mirrored idle and torso half-turn, relaxed carry.

**Fitted to THIS sword and THIS shield** (wrong for another length, guard or size):

| Value | Depends on |
|---|---|
| Stance markers and the fifteen hand-posed fingers (one stance per hand, shared) | Handle thickness and shape, the weapon's weight and look. |
| `weapon_back_offset`, `_slant`, `_turned_over` | Blade length (does the tip clear the hip, the hilt the head). |
| `weapon_draw_arc*`, `weapon_draw_out`, `weapon_draw_via`, `DRAW_BLADE_OVER` | Blade length: the room to the head and eyes. |
| `toggle_armed_fist`, `_fist_hanging`, `_around`, `_elbow`, `_roll`, `_blade`, `_blade_hanging` | Blade length, crossguard width (the guard is what meets the lantern). |
| `toggle_strapped_elbow`, `shield_body_clearance`, `shield_relaxed_faces` | The shield's size and outline. |
| `import_shield.py`'s `STRAPS`, `STANDOFF` | That shield model. |

## 9. Plan: per-weapon setups and a fit button

Agreed as the direction with Kirill (2026-10-14), nothing built:

1. **A weapon may carry its own stance and fingers** (an optional field on `WeaponData`),
   falling back to the body's. Posed once per weapon TYPE (sword, axe, dagger), not per
   weapon.
2. **Move the fitted numbers of section 8 into the weapon's resource**, with the body's as
   defaults.
3. **A "fit this weapon" button in the editor** that runs the searches of section 7 and
   saves the result into the resource, still editable by hand.

Not every frame: the searches take seconds, and a live search makes the arm jitter (the
forearm-roll search already needs hysteresis).

Also open from before: combat clips (the Mixamo pack is third-person, section 12), the
left hand's part in an attack, two-handed weapons.

## 10. Rules learnt, each from a fault

- **R1. Find a model's axes on its mesh, never from a note, the scene's root or a guess.**
  The sword's blade runs along its MESH's own +Y and the scene's +Z. Twice a probe read the
  wrong axis: on the first day every grip was fitted to an axis the blade was not on, and
  on 2026-10-13 a probe reported "the blade points to your right" from the mesh node's Z.
  Print the mesh's box once and take the long axis from it.
- **R2. A check must measure what a wrong result would change.** "Blade within 5 degrees of
  the direction asked" passed for every grip because the solver made it so. What showed the
  fault: the forearm's roll, which way the palm faces, the wrist's bend.
- **R3. Measure on surfaces, not bones.** A grip 3 cm clear of every bone went through the
  palm. Sample the glove's faces; for the trunk use its skinned mesh's outline.
- **R4. "Touching" needs the right target.** The forearm version scored as touching the
  lantern because the measure took the whole lantern as one fat line, wire handle included.
  Count contact against the part that reads as the thing.
- **R5. A held pose that is clean says nothing about the way to it.** Measure the whole
  action per frame: the fist and pommel sat where the lantern hangs and it swung through
  them; the blade passed 1 cm from the eyes during the draw.
- **R6. Watch the speed of the far end.** A blade is a 1 m lever: a pose change that is
  smooth at the wrist can whip the tip. Print the tip's largest move in a frame (0.08 m
  is calm, 0.25 was accepted for a quarter-turn, 0.42 in one frame read as a jump).
- **R7. An elbow side near the line from shoulder to hand flips the elbow** (the tip moved
  2 m in a frame). Keep the pole well off that line, and ease it in with the weight.
- **R8. Do not swap arm states where it can be seen.** Body-shoulder and stance-shoulder
  poses are swapped in one frame when both are out of the picture; a blend is seen from above.
- **R9. Survey a model before reshaping it.** The shield's straps were first taken for its
  arm rest (3.3 cm against a real 7 mm); then only stretched outward; then scaled whole,
  ends included; then the hand strap sized round the thumb became a hoop. Size the standing
  part of each strap only, and the hand strap to the palm.
- **R10. In the editor a body stands in the T-pose, palms down**: a rightly held weapon lies
  level there. Judge a grip only in the stance's preview.
- **R11. Tool buttons survive a script reload only with a getter**:
  `@export_tool_button(...) var x: Callable: get: return _func`. A plain assignment gave
  "The value of property "fit_hand" is Nil, but Callable was expected".
- **R12. Kirill's taste, so it is not tried again**: no visible body or chest turn added to
  an action; do not move the sword to solve a view problem; a thing must touch what it
  moves and be behind it when it pushes; real hands may keep a grip with two fingers and
  work with three.

## 11. Open items

- With the weapons up the shield dips about 6-9 cm into the left thigh for a moment at the
  start of the lantern action (the view's dip; his clearance is 0.12).
- Sheathed, jogging left: the shield still grazes the left thigh by up to 1.6 cm for a moment
  each stride (the leg swings out the way the shield is pushed, and the push eases in).
  Sheathed, the arm is swung out up to 0.28 m (back-left / back-right) and 0.37 m (sideways)
  by the keep-off: not judged in game yet.
- Shadow hands stop at `weapon_shadow_reach` during the lantern reach.
- The lantern action with weapons was measured standing only.
- The lift from under (2026-10-14): second set, after the first clipped forearm and hilt.
  Not judged in game yet. If the hand looks like it hovers under the lantern rather than
  carrying it, that is the price of the room: no fist place both touches and clears.
- The thumb is not closed by the automatic fist (closed, its surface goes into the handle);
  curls for another handle thickness are an estimate (`CURL_PER_METRE`).
- A second preview can appear after a held model is re-imported, until the scene is reloaded.
- Licences unchecked: the sword (`raw-assets/models/wapons/human_sword_lv1.blend`), the
  shield (`raw-assets/models/shields/medieval_shield_gltf`).

## 12. References

### Skyrim (measured, nothing copied)

`tools/skyrim_reference/`: `bsa.py` (a file out of the game's archives, read-only; the game
is at `E:\Games\The Elder Scrolls 5 Skyrim Anniversary Edition`), `hkx.py` (Havok 2010
64-bit: the skeleton, a spline-compressed clip sampled per frame, its events), `measure.py`
(hand, grip and blade from the camera through a clip), `export_arm_clip.py` (a clip's arm
as a file `ArmClip` reads).

- **The arms are placed for the camera, not on a body.** Skyrim's right shoulder is
  0.15-0.2 m right of the camera, 0.17-0.32 below and only 0.05-0.09 BEHIND it (ours: 0.36).
  Their fist rests 0.39-0.52 m ahead of the camera.
- Two mods that show a body in first person (in `D:\Downloads\skyrim`): Joy of Perspective
  keeps two skeletons in one file, the arms under the camera's look node on a dummy spine
  and the body separate, 20 cm back; IFPV shows the normal first-person arms and turns them
  with the view (`NormalFirstPersonArmsRotateRatio = 0.8`), moving the camera down and
  forward when looking down. Section 3 is that idea.
- At rest the grip is about (+0.22 right, +0.4 ahead, -0.2 to -0.3 up from the camera). The
  blade: Skyrim's own idle 57 deg above level; the "Stances" mod's mid stance 21 deg, low
  44, neutral 70, high back over the shoulder.
- Skyrim's own right attack (1.47 s): 0-0.27 s the hand out to the right; 0.27-0.5 s the
  cut across at camera height, tip up to 34 m/s; to 0.9 s the follow-through down left; back
  by 1.47 s. The camera turns 10 deg with it.

### Mixamo's sword and shield pack (a try, off)

`raw-assets/animations/Pro Sword and Shield Pack`: 51 clips, every one with a shield on the
left arm and a combat crouch. Three are in the project and only their right arm is used
(`ARM_CLIPS`, `weapon_arm_from_clips`, off). The pack is made to be seen from outside: its
idle holds the sword hand 0.2-0.4 m BEHIND the eyes, and the sword passes 0.15-0.2 m from
them. Not usable as it is for first person.

## 13. Attack and defence (2026-10-21)

Kirill: "let's do some attack and defence animation", with the Sigma first-person shield clips
(`raw-assets/animations/Skyrim - Shield animations - 1st person`) as the reference. His choices:
keyed and measured (not the clips played), all four moves in the first pass, animation only (no
hits yet). **Nothing here is judged in game yet.**

### Controls

- Left click: a swing, in the order of `SWING_ORDER` (since 2026-10-22 the vertical slashes:
  down, then rising). A click from a swing's `"chain"` on starts the next at once from where the
  blade is; an earlier one waits for that moment; a click with no swing playing always starts
  with the first (the rising slash starts low, where the down slash ends).
- Right mouse held: the block (`PlayerBody.blocking`, set by `player.gd`). Left click while
  blocking: the bash.
- Z (PerfDebug): a blow on the shield while blocking (`block_hit`). For enemy hits later.
- While anything of this is on (`combat_busy`): no Q, no lantern, no fidgets.
- The animation panel (I) lists the swings (`swing_down`, `swing_up`, `swing_up_diagonal`), `bash` (block held up) and
  `block_hit_0..2`.

### The reference, measured (`hkx.py`, nothing copied)

The Sigma pack is 9 Skyrim clips for the shield arm only. From the camera:

| Clip | What it does |
|---|---|
| Block idle | Shield's middle 0.45 m ahead, 18 deg left and 37 below the picture's middle, face ahead. |
| Block anticipate | Pulls 10 cm toward the body over 0.5 s. |
| Block hit (3) | Knocked 9 cm back and 4 down in 0.07 s, back by 0.8 s; variant A to the left and rolled, B down and in. Camera 1-2 deg. |
| Bash (and power bash, the same clip) | Out to 60 deg left, edge-on, by 0.47 s; thrust to 0.65 m ahead in 0.13 s; held 0.1 s; back by 0.8 s. Camera about 3 deg. |

The sword attacks came from Skyrim's own right attack (section 12): out to the right 0-0.27 s, cut
across 0.27-0.5, follow-through to 0.9, back by 1.47. The one-handed stance mod (now in
`raw-assets/animations/Skyrim - One handed sword`; `measure.py`'s path fixed for it) has only two-hit
combat flourishes with spins, not single cuts.

### How it runs (`scripts/player_body.gd`)

- `SWINGS`: keys of [seconds, fist from the eyes, blade's way, edge's way, shoulder moved, view
  turn / tilt, elbow way], the Player's axes, turned with the view's pitch as the stance is.
  `_swing_pose` makes one smooth curve from the stance (or, chained, from `_combat_from`) through
  them and back; the hand's turn goes through the keys as quaternions (`_through_turn`).
  `_hold_weapon` adds it to the stance and solves the arm as usual (keep-off included), then
  `_limit_swing_wrist` holds the wrist within `swing_wrist_max` of the stance's.
- `BLOCK`, `BASH`, `BLOCK_HITS`: offsets of the shield stance's hand / shoulder, the forearm's roll
  and the sword hand (the sword drawn back while blocking), summed each frame by
  `_update_combat` and added in `_hold_shield` (as the shield fidgets' are). The block comes up
  over `block_raise_time`, down over `block_lower_time`. A blow is an impulse peaking at
  `"peak"` s, faded out over `"time"`.
- The view's share (`_combat_pitch / _turn / _tilt`) is added in `view_offset()` only: the
  camera turns a few degrees with a swing, a bash and a blow; the arms do not follow it.

### What went wrong on the way (each found by `combat.gd`)

- **Keyed by the blade alone, the wrist bent 50-140 deg**: the blade lay along the forearm. A hand
  holds a blade at about 50-115 deg to the forearm; what moves it is the elbow's place. A
  per-frame steering of the elbow (the point on its circle where the wrist bends least) fixed the
  wrist but flipped the elbow 0.45 m in a frame and spun the forearm over 250 deg; made
  continuous it no longer reached the keyed blades. So the fist, the edge and the elbow way of
  every key are FOUND by `swing_search.gd` for the keyed blade, and keyed.
- **Blade and edge interpolated as two vectors** ran nearly parallel on the way back from the
  follow-through: the frame flipped and the tip jumped 1.4 m in a frame. Now one turn.
- **The forehand's follow-through down to the left (as Skyrim's) cut through the shield's upper
  half.** It ends level, 30 deg left of ahead, in front of the board (3.6 cm clear), and the
  shield gives way 12 cm down and in (`"shield"`).
- **A chained swing started 0.1 s into its curve** skipped the start of its way: the tip jumped
  0.35-0.4 m at each join. Its clock now starts at `"chain_into"` with the curve there.
- **"During swing backhand the elbow is bent the wrong way"** (Kirill, same day; the first thing
  judged in game). Three causes, each measured by `combat.gd` (`hinge`, `twist`, `--trace=`):
  1. `WeaponHold.solve_arm` turns the upper arm the shortest way and never rolls it, so the
     forearm can fold about the elbow's hinge from the wrong side: 166 deg off the stance's hinge
     in the backhand's wind-up (45 deg in the forehand). `_align_swing_elbow` rolls the upper arm
     about its own line after each swing solve so the elbow folds about the stance's hinge, the
     forearm and hand left where they were.
  2. The keyed elbow ways were interpolated as directions; between two keys the way passed along
     the shoulder-fist line and the elbow flipped 0.39 m in a frame. It now goes round that line
     as an angle (`_elbow_angle` / `_elbow_way`), and a turn of more than 120 deg between keys
     goes round the outside (to the right): the nearer way took the elbow across in front of the
     chest, the shoulder turning the upper arm through 180 deg.
  3. The backhand itself was palm down, the edge leading. With the blade ahead a palm-down right
     hand needs the forearm across to the left: every pose the search found for it either swung
     the elbow from over the shoulder to under the arm in 0.07 s, turned the upper arm 165 deg in
     the shoulder, or the forearm over 120-160 deg. It is now the forehand's way run back, palm
     up, the back edge leading (the sword is double-edged), wound up with the hand in front of the
     chest and the blade cocked up to the left. Measured: hinge 0-2 deg off throughout, the
     shoulder's turn of the upper arm -21..+26 deg (the forehand's up to 72), the elbow at most
     6 cm a frame, the wrist at most 57 deg, sword to shield 2 cm, to body 8 cm, to eyes 0.30 m;
     the shield gives way 14 cm down (`"shield"`) as the blade passes over its top edge.
  `swing_search.gd` now also scores the shoulder's turn of the upper arm (`twist`, against the
  stance's), a folded arm (bend over 135 deg) and the elbow way's change from the last key scaled
  by how far the elbow is off the shoulder-wrist line; options `--previous=`, `--wide-edges`,
  `--blade-cone=`, `--hard`, `--continuity=`, `--key=<swing>` (all its keys in order).

### Measured (`combat.gd`, either foot)

| Move | Tip fastest | Wrist | Sword to eyes / body / shield | Shield's middle |
|---|---|---|---|---|
| Forehand (1.1 s) | 19.5 m/s | 50 deg at most (stance 33) | 0.26 / 0.10 / 0.035 m | gives way to 51 left / 54 below |
| Backhand (1.1 s; since the elbow fix) | 19.1 m/s | 57 | 0.30 / 0.08 / 0.02 | gives way 14 cm down |
| Block | | | | 11 left / 36 below (stance 33 / 50), face ahead |
| Bash (0.85 s) | | | | wound to 36 left, thrust to 3 left / 23 below, 0.60 m from the eyes |
| Blows | | | | knocked about 5 deg, back within 0.6 s |
| Combo joins | 1.6-2.1 cm in the join's frame | | | |

The elbow moves at most 6 cm a frame in either swing. The right forearm comes within 0.27 m of
the trunk's capsules (a hanging arm reads -0.03).

### The vertical slashes (later the same day)

Kirill: the combat is upgradeable -- first one enemy at a time (vertical slashes), then up to
three (diagonal strikes), then all (wide horizontal ones), the stroke picked by how many enemies
are in front. The forehand / backhand above "looked like hitting with a stick" and "scooping";
`tools/skyrim_reference/attack_analysis.py` measured why against the Stances mod (raw-assets/
animations/Skyrim - One handed sword): the mod's cuts lead with the true edge (+0.98..1.00),
the arm drives the blade (the pivot 0.2-0.5 m behind the hand), the blade near the forearm's
line (26-67 deg), a 0.08-0.2 s strike at 30-42 m/s and a hard stop; ours turned about the wrist
(pivot 0.07 m), the blade square to the forearm (95 deg), the flat leading half the time. Run it
on ours with `combat.gd -- --dump=<file>` and `attack_analysis.py --ours <file>`.

- `swing_down` from the high stance's right attack (S_H_C/1hm_attackright), `swing_up` from the
  second hit of S_M_C/_variants_1hm_attackleft/1hm_attackleft_3 (Kirill: combos may be broken
  into single slashes); `SWING_ORDER` = down, up. Kirill: down then rising; hold 0.15 s.
- The rising one leads with the BACK edge (a rising false-edge cut): the true edge would need the
  hand turned over about 180 deg after the down slash.
- **The handle turns in the fist** (`_grip_turn`, a key's 8th entry, `_socket_with_grip_turn`;
  Kirill chose it over a more bent wrist, shallower slashes or re-posing the stance): our stance
  holds the blade square to the forearm, so with the blade low ahead the wrist bent 52-88 deg.
  60 deg at the bottom of both slashes; 0 elsewhere.
- Every key fitted by `swing_search.gd` (`--hard --blade-cone --pivots`); the fist comes down
  12-16 cm right of the middle (20-29 cm read as a diagonal: a vertical plane off to the side
  looks slanted from the eyes; nearer the middle the cocked blade passes too close to the eyes).
- Measured (`combat.gd`, either foot): down -- strike 0.12 s, 40 m/s, edge +0.92, plane 67 deg
  (the mod's 88: the tip passes 21 deg right at the top of the arc, about 50 deg up, above the
  picture), ends in the middle 46 deg down; sword to eyes 0.23 m, body 0.16, shield clear; the
  shoulder turns the upper arm up to -77 deg at the hold. Up -- strike 0.11 s, 30 m/s, edge
  -0.92 (back edge), plane 86 deg, 5-10 deg right of the middle; eyes 0.48, body 0.35. Combo
  joins 0.5-7 cm.
- Faults found on the way: the search's keyed-pose print failed when `--pivots` left out the
  key's own turn and the headless run hung for an hour (now guarded; kill leftover Godot processes
  after a timed-out probe -- `timeout` stops only the console wrapper); an edge carried over
  pre-turned from an earlier search let the flat lead; a chained swing started at its first key's
  own time skipped to that key (1.18 m in a frame) -- the start is now kept 0.05 s before it.

### The vertical slashes as copied clips (2026-10-22)

The keyed slashes raised the elbow over a hanging forearm at the bottom (Kirill's screenshots:
"bends the elbow the wrong way", for both): the search had bought the wrist's comfort with it, and
no probe measured it. `combat.gd` now prints `elbow_up` (cm the elbow is above the higher of
shoulder and wrist; + = that look). Kirill then asked why not copy the mod's strokes, and the
reasons against did not hold: our arms are drawn apart too (placed for the camera, the shoulder
free), and the mod's first-person arm hardly stretches in these clips (upper arm 0.284-0.301 m,
forearm 0.233-0.251, against our 0.285 / 0.280; `tools/skyrim_reference/arm_lengths.py`,
`tools/weapon_probes/arm_lengths.gd`). Licence: fine (Kirill).

- A SWINGS entry with `"clip"` plays an ArmClip window (`_clip_swing_pose`): shoulder, elbow's
  way, wrist (scaled by our arm's length over the clip's), hand turn and the sword in the hand
  from the clip, turned with the view; blended in from the stance or the last swing and out to the
  stance; the elbow folded about the stance's hinge. Converted with `export_arm_clip.py` into
  `assets/animations/first_person/stances_*.json`.
- `swing_down`: S_H_C/1hm_attackright 0.27-0.82 s. `swing_up`: S_H_P/1hm_attackpowerforwardsprint
  0.85-1.08 s -- Kirill pointed at the power attacks: that clip is the down slash, a dip and a
  vertical rising cut with the back edge leading, ending with the blade upright. The keyed ones
  stay as `swing_down_keyed` / `swing_up_keyed`; the mod's diagonal rising cut (true edge, 47 deg)
  as `swing_up_diagonal` for the diagonal upgrade (its hold passes 12 cm from the eyes).
- Measured against the mod (`attack_analysis.py --ours`): down -- 173 deg behind -> middle -> 50
  below, plane 89 deg (mod 88), edge +1.00, pivot 0.17 m behind the hand (0.19), 46 m/s (36);
  rising -- 33 below -> 34 above, 21-26 deg right, plane 86 (86), edge -1.00 (-1.00), 18 m/s (19).
  `elbow_up` below zero throughout both. Sword to eyes: down 0.15 m while cocked (the blade
  behind the head; the camera does not see it, the body's shadow might), up 0.59; body 0.10 /
  0.20; shield clear. Chain joins 3 cm.

**Removed the same day (Kirill):** the hand-keyed swings (`swing_down_keyed`, `swing_up_keyed`,
`swing_forehand`, `swing_backhand`) with what only they used -- `_swing_pose`, the handle turn in
the fist, the elbow-angle interpolation, the keyed swings' wrist limit (`swing_wrist_max`) and
`tools/weapon_probes/swing_search.gd`. All in git before 2026-10-22. The notes above about them are
history. Kept: the elbow's fold about the stance's hinge (`_align_swing_elbow`, used by the clip
swings) and the idle hold's wrist (`_stance_wrist`, held through a dodge).

**The head with the swings (same day; Kirill: "a head tilt when swinging sword, similar to how we
do for shield bash and block"):** copied from the mod too. `export_arm_clip.py` records the
camera's turn, nod and tilt against the clip's first frame (`"view"` per frame; `ArmClip.sample`
returns it), and `_clip_swing_pose` adds it to the view (`_combat_pitch` / `_turn` / `_tilt`, as
the bash and the blows do), blended in and out with the arm and from one swing into the next.
`swing_head_follow` (1.0) scales it. Measured (`combat.gd`, the "view nods ..." line): down -- up
2.7 deg while cocking, down 3.8 through the strike, tilt about 1 each way, turn under 1; rising --
up from -2.4 to +0.9, tilt 0.3; diagonal -- turn 5, tilt 2.5; never more than 0.94 deg in a frame
(the diagonal 1.7).

**The down slash animated in Blender (same day):** `swing_down_blender`, a SWINGS entry with
`"rig"` instead of `"clip"`, played from `fp_arms.glb` through an AnimationTree and read back as an
ArmClip frame, so everything above applies to it. `swings_from_blender` (on) puts it in the click
order in place of `swing_down`. The pipeline and its checks: `docs/blender_animation.md`.

### The arms in a dodge (2026-10-22)

Kirill: "add the dodge/dash animations to the sword, the ones we have on double tap", "a dodge
from idle holding into idle holding". With the weapons drawn, a dash also plays the mod's
first-person dodge (`dodge_neutral`: back, left, right; forward = its forward roll's arms) on both
arms, as a CHANGE on our idle hold (`DODGE_ARMS`, `_dodge_delta`): the clip's wrist move, hand turn
and elbow turn since its first frame. `dodge_arm_time` 0.7 s (the clips 1.0 / 1.17 s; the dash
0.4). The block, a bash or a blow fade the shield arm's share out in 0.1 s, a swing the sword
arm's. Converted with `export_arm_clip.py` (`--left` for the shield arm) into
`assets/animations/first_person/dodge/`. `combat.gd -- --only=dodge`.
- The wrist is held as in the idle hold through a dodge: the clip's hand turn added whole bent our
  wrist 33 -> 87 deg (the mod's straightens 44 -> 3-22: its hand turn is mostly the forearm
  swinging); split into forearm and wrist shares by shortest turns it reached 110 and the blade
  came 7 cm from the eyes.
- Measured, either foot: the blade dips 10-23 deg in the picture and back, the sword 0.66 m or more
  from the eyes, 0.30 from the body, the shield clear; lands within 1-3 cm of where it left. The
  tip moves up to 0.26 m in a frame as the hop starts; the elbow rises up to 7 cm over the shoulder
  for a moment in the right dodge.

### Open

- Not judged in game: the arms' dodges.
- Not judged in game: the copied vertical slashes. The keyed ones' handle turn is no longer played.
- Not judged in game: the vertical slashes; the handle turning 60 deg in the fist may show at the
  fist's edges at the bottom.
- Not judged in game: how the swings, the block and the bash look and feel; their timings
  (`"time"`, key seconds) are first guesses from Skyrim's.
- No hits: `"hit"` in `SWINGS` / `BASH` marks when the blade or board could hit, for the next step
  (a sweep test against `scripts/enemies/`).
- A chained swing starts from rest (its curve is flat at its start), so a combo has a short
  beat at each join instead of carrying the speed on.
- The swings have no room test (`FIDGET_ROOMS`): a wall in front does not stop a swing.
- Moving while blocking is as fast as without.
- Fitted to this sword and shield (section 8): every key's fist, edge and elbow way, the block's
  offsets, the forehand's follow-through.
