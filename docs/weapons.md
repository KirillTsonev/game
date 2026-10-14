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
| `lantern_armed_search.gd` | `SEARCH` | Thousands of fist places, elbow sides and rolls at the knob's turn, one per tiny frame, kept where the blade points ahead and the knuckles (or pommel) touch the lantern's body. `-- --under`: fist places under the lantern with blade aims, kept where any part of the hand touches its underside. |
| `fidgets.gd` | `FIDGET` | Every fidget, either foot forward: per tenth the sword's room to the eyes, body and shield, the arm's to the trunk, the fist from the eyes and the blade's way; the tip's fastest move; then one starting by itself and a key ending it. |
| `sheathed_fidgets.gd` | `SHEATHED` | The sheathed fidgets, lantern lit, either foot: the view's dip and turn, where the palm is in the picture (and whether it is in a 16:9 picture of the camera's fov), the arm's room to the body, the palm to the lantern's body and its lift. |
| `animation_panel_check.gd` | `PANEL` | The panel's body side: the stages listed, a driven pose held still through a key press and past the end, released back to the stance; the panel builds. |
| `breathing.gd` | `BREATH` | Standing still, weapons up, both idles, breathing on and off: how far the chest, the sword's grip and the shield move against the eyes, and the largest step a frame. |
| `shield_backward.gd` | `SHIELD` | Jogging in six directions, weapons up and down, looking straight down and level: the least room between the shield's vertices and the trunk's and legs' capsules, and how far the keep-off pushed. |
| `lantern_under_trace.gd` | `TRACE` | For fist places under the swung lantern and four rolls: where palm, wrist and knuckles end up, and where the blade points. |
| `lantern_feet.gd` | `LANTERN` | The action with the shield, weapons down and up, either foot: does each hand arrive, does the left hand stay in the strap, shield against body. |
| `arm_against_trunk_mesh.gd` | | The left arm against the trunk's own skinned mesh. |
| `lantern_end_jump.gd` | `JANK` | Frame-by-frame steps of sword, shield, hands, eyes at the action's end. |
| `draw_from_back.gd` | | The draw and the sheathing: the sword's mesh through it, the fist in the view. |

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
