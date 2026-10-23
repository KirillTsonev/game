# First-person moves animated in Blender

(2026-10-22) How a first-person move of the sword arm is animated in Blender and played in the
game. Kirill's choice: the moves themselves are authored as clips (Claude generates them in
Blender, Kirill adjusts them there); the adaptive layers (view-follow, breathing, step bob,
keep-off, the elbow's hinge, feet) stay in code. Playback is glTF + AnimationTree.

**The pilot:** the down slash (`swing_down_blender`), built from the copied ArmClip down slash.
On a round trip with nothing edited it plays like the copied one (numbers below). **Not judged in
game yet.** Moves not moved over yet: the rising slash, the dodges, the fidgets, the lantern
action. The shield arm is in the scene and the down slash since 2026-10-23 ("The shield arm" below).

Editing a move step by step (for Kirill): `docs/editing_animations_in_blender.md`.

## The pipeline

| Step | Run | Writes |
|---|---|---|
| 1. The arm out of the game | `Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/blender/fp_arms/export_arm_source.gd` | `animation_sources/fp_arms/arm_source.glb` + `.json` |
| 2. The scene | `tools/blender/fp_arms/build_scene.py` in Blender | `animation_sources/fp_arms/fp_arms.blend` |
| 3. Animate | Kirill in Blender, or Claude through the Blender MCP | the `.blend` |
| 4. Export | `tools/blender/fp_arms/export_clips.py` in Blender | `assets/animations/first_person/fp_arms.glb` + `fp_arms_rig.json` |
| 5. Into Godot | rescan (the editor's FileSystem, or the Godot MCP's `rescan_filesystem`) | the import |
| 6. Use it | a `SWINGS` entry with `"rig": &"<action>"` in `scripts/player_body.gd` | |

- Steps 1 and 2 are needed only for a new scene or a new weapon. **Step 2 clears the open scene
  and rebuilds every action listed in its `SWINGS` from the ArmClips: hand edits are lost.** Once
  a move has been adjusted by hand, take it out of that list.
- **After the stance changes in Godot** (the WeaponStance markers): step 1, then
  `tools/blender/fp_arms/update_stance.py` in Blender, then step 4. It keeps hand edits: it
  replaces only the keys that hold the OLD stance (every channel equal to the old `hold`'s,
  quaternions either sign: `hold` itself, a move's first and last frame, the fingers' key), moves
  the Weapon bone's rest onto the new grip and lays the Sword object on it. A turn of the sword in
  the stance then turns it through every move, the keyed turns on top (the game draws the sword
  from the socket the export writes). First used 2026-10-22 on Kirill's Grip turned 14 deg: the
  arm unchanged, the sword 14.1 deg turned on every frame, the swing starting and ending on the
  new stance. Its maths is `build_scene.py`'s: keep the two the same.
- The Blender scripts run in the open Blender (the Blender MCP's `execute_blender_code`:
  `exec(compile(open(path).read(), path, "exec"), {"__file__": path})`, or the Text editor) or
  in the background (`blender.exe -b ... --python ...`, full path: CLAUDE.md "Local tooling").
- `animation_sources/` has a `.gdignore`: Godot would otherwise import the `.blend` itself.
  `*.blend1` (Blender's backup) is in `.gitignore`.

## The scene (`fp_arms.blend`)

- **The world is the eyes' space**: origin at the eyes, +Y ahead, +Z up (the game's -Z ahead,
  +Y up). The camera `EyesCamera` sits there with the game's field of view (75 deg vertical),
  1920 x 1080; the 3D view looks through it.
- `FPArms`: the rogue's skeleton with only the right arm's meshes (the rest of the shirt and
  gloves cut away, as the game shrinks it into the shoulder). Bone collections: Controls and
  Fingers shown; Arm (the bones the IK drives) and Body hidden. Bones drawn octahedral: B-bones
  came out as boxes thicker than the arm and hid it.
- **What to move** (the Controls collection):
  - `CTRL_hand` (red): the hand. Move it AND turn it; the arm follows by IK.
  - `CTRL_elbow` (blue): where the elbow points (the IK's pole).
  - `CTRL_shoulder` (green): where the arm hangs from (the game's drawn-apart shoulder). Usually left.
  - `Weapon` (orange): the sword's grip in the fist. Turn it to turn the handle in the hand.
  - `Eyes` (yellow): the head. Its turn is added to the view during the move (`swing_head_follow`).
  - The fingers: plain bones, rotate them. The game plays them during a Blender swing (outside
    one the stance's fist); `wrap_fingers.py` keys them round the handle on every frame and
    replaces hand edits, so edit them after running it ("The fist closes on the handle", below).
- Textured as in the game in Material Preview (Z): `tools/blender/fp_arms/game_materials.py`
  copies the game's materials (albedo, normal, packed roughness / metallic, each times the
  material's value -- the rogue's metallic is 0, the sword's 1) onto the arm and the sword, the
  project's texture files referenced, not copied. `build_scene.py` runs it; run it alone to
  refresh. Blender's own studio light, not the game's lighting, fog, grade or post effects.
- Actions: `hold` (the stance, one frame: a reference to start a move from) and the moves.
  30 frames a second; frame 1 is the start. A new move = a new action (the Action editor's
  New, the armature selected). The exporter writes every action the armature has had.

## The shield arm (2026-10-23)

Kirill: the shield hand and the shield in the Blender animation, animated there, played by the
game. Added to the existing scene, not by rebuilding it (the sword arm's hand edits stay):

| Step | Run | Writes |
|---|---|---|
| 1. Record | `Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/blender/fp_arms/export_shield_source.gd` | `animation_sources/fp_arms/shield_source.glb` + `.json` |
| 2. Add / re-key | `tools/blender/fp_arms/add_shield_arm.py` in the open Blender | the open scene (save it) |
| 3. Export, rescan | `export_clips.py`, as for the sword arm | `fp_arms.glb` |
| 4. Check | `--script res://tools/weapon_probes/shield_rig_check.gd` | prints the arm against the recording |

- **The controls:** `CTRL_hand_l` (the wrist: MOVE it to move the shield arm; TURN it about the
  forearm to roll the forearm and the shield on it), `CTRL_elbow_l` (which way the elbow points),
  `CTRL_shoulder_l` (where the arm hangs from). The shield (object `Shield`) is fixed to the left
  forearm, as in the game; the hand and fingers are keyed once (the game keeps the stance's grip
  on the handle). The left arm's meshes are `*_left`.
- **The rig:** the IK solves hidden `MCH_upper_l` / `MCH_lower_l`; the real arm copies them and the
  forearm then turns toward `CTRL_shield_face_l` (a helper on the hand control) about its own
  length (Locked Track). Blender's IK solver runs after the chain bones' own constraints, so a
  roll on the IK's own forearm was lost (the shield 6.4 deg off through the whole swing).
- **The forearm's roll is spread along it** (same day, Kirill: the shield arm's elbow "looks kind
  of twisted and clipping"). The stance rolls the forearm about 108 deg to turn the shield, and it
  all sat on `LeftLowerArm`, which the sleeve and elbow pad hang from: the skin was wrung at the
  elbow, in the game as in Blender. Now the roll is on `forearm_roll_l` (a copy of the lower arm
  parented to it, with the Locked Track; it carries `LeftHand` and the `Shield`), `LeftLowerArm`
  stays on the elbow's hinge, and the twist bones copy the roll by where they sit
  (`lowerarm_twist_02_l` 0.34, `_01_l` 0.67; Copy Rotation, target space Local with Owner
  Orientation, because their own axes lie 95 deg off the forearm's). `add_shield_arm.py`'s
  `spread_twist()`; the shield, hand and fingers did not move on any frame (0 mm, 0 deg). The
  bone is marked deforming (no weights) so the exporter keeps it, and the game reads the
  forearm's turn from it (`_rig_left_pose`). In the game the solver still rolls the body's
  `LeftLowerArm` (everything that places the shield reads it); only the drawn copy of the arm and
  the shadow's get the spread (`WeaponHold.spread_forearm_twist`, the Body's
  `shield_forearm_twist_spread`, on by default). `shield_rig_check.gd` prints the drawn forearm's
  roll at the elbow: 112.5 deg with `-- --no-spread`, 0.0 with it.
- **The shield in the down slash, animated** (same day, Kirill: the recorded counterweight was
  "just down and up"). The shield arm moves as the chest turns, about a vertical line 10 cm
  behind the eyes (shoulder, elbow pole and wrist control turned together): 5 deg to the right in
  the cock (the shield 6 cm toward the middle, 2 up, its face 6.5 deg right: it covers the chest
  while the sword arm is up), back past the stance from frame 16, ahead of the blade's fastest
  frames (the body leads), to 9 deg left by frame 25 with the arm drawn in (the shield 10 cm left,
  10 back, 3.5 down, its face 13 deg left, its top tipped 7 deg forward-left: a lane for the
  blade), then back over the whole recovery (Kirill: the return over 26-32 was too quick; it is
  now an even ease, 0.3-0.6 m/s, keys at 83 / 50 / 17 % of the peak on 28 / 31 / 34), 0.6 cm
  past the stance on frame 36, the stance on 38. Keys on 0, 6, 11, 14, 16, 19, 22, 25, 28, 31,
  34, 36, 38 on the three left controls, made from `hold` by a script through the
  Blender MCP (not in a tool file: they are hand-editable keys now, and replaced the recording's).
  Measured: the blade passes the shield 24 cm away at the nearest (19 cm before), the wrist
  control at most 0.383 m from the shoulder (the arm 0.565), the elbow's twist 0. In the game
  (`shield_rig_check.gd -- --frames`) the rig's wrist moves as in Blender. Not judged in game.
- **What it was keyed from:** the game's arm through the swing before the clip had a shield arm
  (the stance plus the swing's `"shield"` counterweight, 2-4 cm): step 1 records it with
  `shield_arm_from_rig` off. Re-running step 2 on a scene that has the shield arm REPLACES the
  shield arm's keys in the recorded swings (hand edits of it there are lost, the sword arm's are
  not); the first run adds everything.
- **How the game plays it** (`PlayerBody._hold_shield`, a swing with `"shield_from_rig"`, the
  Body's `shield_arm_from_rig` on): as changes from the clip's `hold` (read once, `_rig_left_hold`),
  which is the stance -- the shoulder moved as the clip's; the fist carried with the clip's
  forearm turn; the hand's turn given that turn, so the solver gives the forearm (and the shield)
  the clip's roll; the elbow pointed where the clip's is. Faded with the swing (`_clip_weight`);
  the keep-off and the view-follow still on top. With `shield_arm_from_rig` off the `"shield"`
  counterweight plays instead (switch to compare).
- **Measured** (step 4, nothing edited): the arm and the shield within 5 mm and 0.7 deg of the
  recording, the most on frame 1 (the counterweight's 0.05 s ease in, which the thinned keys make
  a straight line); in Blender the keys within 0.5 mm of it.
- **Rule from it: record from the eyes as they are on each frame.** The camera follows the head,
  which moves up to 1.6 cm during the down slash, and the game places both arms from the eyes every
  frame. Recorded from the eyes before the swing, that move came into the clip as a shoulder move
  and the game added it a second time (1.6 cm off).

## The chest (2026-10-23)

Kirill: try a chest turn with the attack (the plan: stage 1 the turn in the down slash, judged in
game; stage 2 a right-leaning variant of the slash blended by lean, because leans from -8.6 to +20
deg put the arm through the torso -- the lean turns the whole move rigidly, shoulder included).

- **Rig:** `CTRL_chest` (purple, Controls) on the body's spine line (`UpperChest`: 3 cm left, 17 cm
  behind the eyes), upright, parent of `CTRL_shoulder` and `CTRL_shoulder_l`: turning it carries
  both shoulders round the spine; the hand controls are not under it, so the sword's and the
  shield's paths stay as keyed and the arms reach for them by IK. Added by
  `tools/blender/fp_arms/add_chest.py` (nothing moved: 0 mm, 0 deg on every frame). Marked
  deforming (no weights) so the exporter keeps it.
- **Keys in `swing_down`** (second version, the same day; the first, 5 deg right / 9 left, the
  turn the shield's keys imitated, could not be seen in game -- Kirill asked for the shoulder line
  to twist and turn as a body does in an attack). On the shield's frames:
  - `CTRL_chest`: twisted 12 deg right and tilted 8 deg sword shoulder up by frame 14 (the cock),
    back from 16, 25 deg left and 8 deg sword shoulder down at 25, an even return, a hair past
    rest on 36, rest on 38. Its twist and tilt are the shoulder line's; the camera stays out of it.
  - `CTRL_shoulder` (the sword's clavicle, on top of the chest): up 4 cm and back 2 in the cock,
    forward 5 and down 1 at the peak; keys on 17 and 18 bring it forward ahead of the strike
    (between 16 and 19 it lagged and the hand went 1.1 cm out of reach: the elbow locked straight
    and snapped 23 cm in a frame). `CTRL_shoulder_l`: a smaller opposite move (forward 1.5 cm,
    down 1 in the cock; back 2, up 1 at the peak).
  - Measured in Blender: the sword hand at most 0.530 m from its shoulder (the arm 0.565), the
    elbow never under 41 deg of bend, at most 16 cm a frame in the strike (the wrist 28); the
    sword's path within 1.1 cm of before; the shield, whose hand path is as keyed, turned up to
    8.3 deg further by its shoulder swinging 16 cm back with the chest (its face more open at the
    peak); the blade 24 cm from it at the nearest, the shield 47 cm from the eyes at the nearest.
  - `hold` has the chest keyed at rest.
- **Game:** `_rig_sample` reads the chest's turn ("chest", a quaternion in the eyes' space: twist
  and tilt), `_clip_swing_pose` weights it with the swing (`_clip_weight`) into `_swing_chest`, and
  `_turn_chest_with_swing` turns Spine / Chest / UpperChest by a third of it each the NEXT frame, before the eyes
  are found (the clip is sampled after them), the head's turn kept. The drawn arms come from the
  clip's shoulders anyway: this turns only the body seen looking down and its shadow. The Body's
  `swing_chest_from_rig` (on) switches it. (`weapon_body_toward_weapon`, the stance's own chest
  turn, has been off since 2026-10-13: in the stance the chest is the idle clip's, 13 deg right.)
- **Measured** (`tools/weapon_probes/chest_turn.gd`, a fresh Player per run so both runs stand at
  the same moment of the idle; the heading read from the body's shoulder line -- the chest bone's
  facing leans forward in the idle, and the tilt then reads as 4-5 deg of extra twist): the
  shoulder line from 18.5 deg right to 30.5 in the cock and 6 deg left at frame 24, tilted from
  +1.4 to +8.3 and -5.8 deg; the camera's eyes and the sword's tip at most 1.7 cm from the run
  without it (the recovery, frames 24-33: the tilted body carries the head a little). The clip's
  turn read back in the game: exactly the keys' (12 / 8, 25 / 8). `slash_lean.gd` unchanged (each
  lean within 0.2 deg, the tip within 1.4 deg of straight). Not judged in game.

## The right-leaning cut, the body as a reference, looking down (2026-10-23)

- **Looking down in Blender** (Kirill: the body looked "farther away from the arms when I look down
  than in-game"): in the game the arms follow the view down (`weapon_follows_view` 0.8; the sword's
  wrist and hand held to `swing_view_down_limit` during the stroke) and the body does not, so
  looking down the arms come nearer the body; a clip is posed for a level view. The 3D view's
  sidebar -> FP Arms -> **Looking down / Looking straight** (one toggle) shows it as the game does: helper bones at the eyes,
  `VIEW_arms` (parent of `CTRL_chest`, `CTRL_elbow` and the shield arm's controls), `VIEW_hand`
  (`CTRL_hand`) and `VIEW_camera` (`Eyes`, and so the camera), turned on every frame by
  `tools/blender/fp_arms/view_preview.py` (a text block registered on load, as the ghosts; its
  `VIEW_CAPS` must follow the swings' "view_cap" and "time"). Not keyed, deforming nothing:
  adding them moved nothing, and at 60 deg the camera turns 60, the arms 48, the sword hand 48 in
  the hold and 10 in the stroke (checked). Down is 80.2 deg, the furthest the game lets the Player
  look down (player.gd clamps the pitch to 1.4 rad); it is on by default (Kirill: a toggle, not
  numbers). `export_clips.py`, `wrap_fingers.py`, `add_shield_arm.py` and `update_stance.py` switch it
  off while they run and back after; a new script that reads places from the scene must do the same. The
  Blender IK solves the previewed arm, the game its own solver: the elbow can differ by millimetres.
  **The swing line** (same panel, debug only): the path of the sword's tip through the downward cut
  of the move FPArms plays (the run of frames in which the tip keeps falling that drops it furthest,
  found looking straight: frames 18-25 in both slashes; not the wind-up nor the return), every
  frame, as the view is set -- `SwingLine` in the collection "Debug" (not under
  FPArms, not selectable, drawn in front). Rebuilt on every switch of the view; "Update the swing
  line" after editing keys or changing the action.

- **`swing_down_right`** (an action with a fake user): the start of a second down slash for a
  cut leaned +20 deg, to be blended with `swing_down` by lean in the game (not wired in yet). Made
  as an exact copy of what the game plays at +20 (Kirill: "just copy the exact same swing we have now
  in game when we set it to +20"): `swing_down` with the sword arm's three controls (`CTRL_shoulder`,
  `CTRL_elbow`, `CTRL_hand`) turned about the eyes' forward axis by the game's lean on every frame
  (28.6 deg at full, faded in and out over the swing's "lean_at" as `PlayerBody._ease` does); the
  chest, the shield arm, the head, `Weapon` and the fingers as in `swing_down`. Those three controls
  are keyed on every frame. To be reworked by hand: the turned whole arm is what put the arm "growing
  out of the middle of the torso" and, looking down, into it. Procedural fixes tried the same day and
  taken back (the shoulder left unturned, kept out of the picture, put on the body; a keep-off; a
  lean limit looking down): each bent the wrist or the elbow, or moved the problem elsewhere.
- **The body as a reference** (Kirill: "we need the body and legs to properly ascertain"):
  `tools/blender/fp_arms/export_body_source.gd` (headless) records the body as the game draws it
  through `swing_down` -- torso, belts, legs, boots; not the head and hood; its own arms shrunk into
  the shoulders as the game leaves them -- from the eyes on every frame (`body_source.glb` + `.json`);
  `tools/blender/fp_arms/add_body_reference.py` imports it as the armature `BodyRef` with its meshes
  (`*_body`, the game's materials) in the collection "Body reference", not under FPArms (the clip
  export leaves it out), unselectable, its bones hidden, keyed on every frame by each bone's change
  from its rest (checked: every bone where the game has it, 0 mm). Hide it with the collection's eye.
  The legs stand still (the idle).
  **The torso follows `CTRL_chest` live** (Kirill: rotating the shoulder line "doesn't rotate the
  torso"): the recording leaves the swing's chest turn out (`swing_chest_from_rig` off while
  recording), and the reference's Spine / Chest / UpperChest each copy a third of `CTRL_chest`'s own
  turn (Copy Rotation, owner Local, target Local with Owner Orientation, Before Original), as the
  game shares it; and `view_preview.py`'s `_hold_head` moves `BodyRef` after every update so its head
  stays where the recording has it (the game keeps the camera at the eyes and moves the body under
  it -- without it the body stood up to 4 cm off sideways). Against a recording with the game's own
  chest turn: chest, neck and shoulders within 0.3-1.4 cm and 1.7-3.9 deg (the game turns the chest a
  game frame late), hips within 2.8 cm. So any edit of `CTRL_chest`, in either slash, shows at once.

## How the game reads it (`PlayerBody._rig_ready` / `_rig_sample`)

- `fp_arms.glb` is instanced hidden under the Body (`BlenderArmRig`), with an AnimationTree:
  a state machine of its clips, cross-fading `rig_crossfade` (0.1 s) when one rig clip is chained
  into another. The tree is advanced by hand to the swing's time; scrubbed back (the animation
  panel), it restarts the clip.
- Nothing of the rig is drawn. Each frame `_rig_sample` reads it as an ArmClip frame
  (shoulder, elbow, wrist, the hand's turn, the sword in the hand, the head's turn) and
  `_clip_swing_pose` plays that exactly as it plays a copied clip: turned with the view, blended
  in from the stance and out to it, the elbow folded about the stance's hinge, keep-off.
- **Everything is read as a turn from the rig's rest, in the eyes' space**: Blender turns every
  bone's own axes its own way on import, so a bone's axes are never compared across the two
  programs. The hand's turn is that change applied to the game's own hand rest
  (`fp_arms_rig.json`'s `hand_rest`); the sword's, to the grip the scene was built with (`socket`).
- The Body's `swings_from_blender` (Combat group, on by default) puts `swing_down_blender` in
  the click order in place of `swing_down`. Switch it off to compare.

## Measured (round trip, nothing edited)

`tools/weapon_probes/rig_swing.gd` (the rig against the ArmClip it was built from, every 1/30 s):
wrist within 2 mm, hand and sword turns 0.0 deg, grip within 1 mm, head within 0.2 deg, the
elbow's way within 5 deg (the clip's arm is shorter than ours). `combat.gd -- --only=swing_down`:
tip path within 1-6 deg of the copied swing's, wrist within 2 deg, tip 47.6 m/s (46.1),
sword to eyes / body / shield 0.15 / 0.11 / 0.065 m (0.15 / 0.10 / 0.08). `--only=combo`: joins
2.7-3.0 cm (as the copied swings'). An edit (the recovery 6 frames later) came through as a clip
0.2 s longer. `tools/weapon_probes/fp_rig_inspect.gd` prints the imported rig's bones and clips.

The keys of a built move are thinned (`LOCATION_TOLERANCE` / `ROTATION_TOLERANCE` in
`build_scene.py`), but a fast curved stroke keeps most of them: the down slash's hand and elbow
keep 16-17 of 17. Fewer, cleaner keys (at the extremes) are for later, once editing has been tried.

## The wind-up is in the clip (same day)

Kirill: animate how the arm gets from the idle hold to the cock rather than leave it to the blend.
The copied window starts mid-cock (blade down the back): the game's 0.2 s blend carried about 170
deg of blade travel in a straight line. Now `swing_down` starts on frame 1 in `hold` (the stance)
and reaches the copied window on frame 7 (`build_scene.py`'s wind-up frames, 6): 23 frames,
0.733 s. What Blender interpolates in between is a DRAFT to shape by hand. The game's entry:
`blend_in` 0.05 s (only breathing, view-follow and small stance edits to cover),
`chain_blend_in` 0.15 s (chained from another swing, which does not end in the hold: with 0.05 the
join from the rising slash jumped 6.3 cm in a frame), every time 0.2 s later. Measured: the elbow
at most 9.7 cm a frame (13.7 with the code blend), the wrist 58 deg at most in the wind-up, combo
joins 2.9 / 0.4 / 3.0 cm. Games do it this way too: the anticipation is part of the attack's clip,
and the engine's blend only hides small differences. **A clip that starts in `hold` is tied to the
stance**: after a real stance change re-run steps 1-2 and adjust the wind-up.

**The recovery too** (same day, Kirill): the clip goes back into `hold` on frame 37, 14 frames
(0.47 s, what the blend out took) after the stroke's last (`build_scene.py`'s recovery frames):
1.2 s in all, `clip_to` 1.2, `time` 1.25 (0.05 s blend out). `chain` stays 0.7: a chained click
cuts the recovery off, so in a combo it is never seen (the rising slash starts low, where the
stroke ends). Measured: it ends within 3 cm and 2 deg of where it started, combo joins unchanged.

## Smoothed and retimed (same day, after Kirill's own edit)

Measured by sampling the sword's tip (the `sword` mesh's vertex furthest along +Z) every frame in
Blender, with the hand control's distance from the shoulder against the arm's length (0.565 m).
Fixed one at a time, each tried on a snapshot of the keys first:

- **The arm locked straight at the bottom** (CTRL_hand 17.4 cm out of reach on frame 20, then a
  0 -> 55 deg elbow bend in three frames): the frame-20 key moved 19.5 cm toward the shoulder.
- **The wind-up started at full speed** (12.8 m/s on its first frame): the frame-1/2 keys were far
  from the stance on frame 0; moved later (deleting them instead lost the pose and threw the elbow
  out to 97 deg).
- **A jolt early in the cock and a wrist snap in the strike** (15 -> 1 -> 13 deg in two frames):
  CTRL_hand's rotation keys there set to the mean of their neighbours. The cause was the hand's
  turn both times, not its place or the elbow.
- **Retimed** (Kirill: more frames where it was rushed; length free): wind-up 0-11 (was 0-8, it
  peaked faster than the strike), cock 11-16 (was 8-14, resampled with an ease at both ends),
  strike 16-22 (unchanged), a new follow-through key on 25 (the wrist carries on one frame of its
  strike turn, the hand half a frame of its travel: a whole frame locked the arm again), recovery
  25-38. 38 frames, 1.267 s; the tip now slows 16.8 -> 10.9 -> 5.6 -> 2.0 -> 0.6 m/s past the
  bottom instead of stopping in one frame. The game's entry was moved to match (`clip_to`, `time`,
  `chain`, `hit`, `view_cap`, `bounds`, a "follow through" stage).

Tried after this and reverted the same day (Kirill): holding the strike to the screen's centre
line by script (first the tip, then the whole blade on a vertical plane, which bent the wrist up
to 72 deg; a line leaning about 6 deg toward the lower right eased it to 64). The aim was never a
vertical line: **the cut is to be a straight line on screen through the centre, inside a cone of
about +-20 deg from vertical** (Kirill drew it as an hourglass over the eyes camera's view). Kirill
then edited the keys by hand to that: the tip crosses the top of the picture about 3 deg left of
centre (frame 19.4), the centre within a few pixels (20.7) and the bottom about 3 deg right
(22.4), a line leaning about 9 deg, within 1 deg of straight over frames 19-25. The blade still
lies 8-14 deg across that line (the guard right of the tip); not visible in play. Check a cut
from the eyes camera (numpad 0) with the ghosts, not from the side.

**Every swing leans at random** (2026-10-23, Kirill: "every slash random within that hourglass"):
`PlayerBody.swing_lean_range` (default -20..+20 deg, + = the cut's top right) picks the cut's lean
per swing, and `_clip_swing_pose` turns the whole move about the eyes' forward axis by the
difference from the clip's own (`"lean"` in SWINGS: -8.6 measured in game), full from the
wind-up's end and back over the recovery (`"lean_at"`). Turning about that axis keeps a line
through the picture's middle straight and through it, so ONE clip gives every lean. Measured by
`tools/weapon_probes/slash_lean.gd` (headless; prints where the tip crosses the top, the middle's
height and the bottom): each lean within 0.6 deg of the one asked, the tip within 1.3 deg of
straight, the middle crossed 1.6 deg left of centre at every lean, the hand never past reach. A
new swing that is to lean needs its "lean" measured by that probe (at `--leans=` its own value,
the line's lean is printed) and its "lean_at".

Rule from it: **after moving the hand control, check its distance from the shoulder on every
frame**. Blender's IK only stretches the arm straight when the control is out of reach; nothing
warns, and it shows as a locked elbow and a sudden bend after it.

## Rules learnt, each from a fault

1. **The rogue's skin is bound in the FBX's A-pose, its rest is the T-pose** ("fix silhouette").
   Blender took the bind pose as the rest (bones up to 0.62 m off the game's), and without that
   the mesh stayed in the A-pose on T-pose bones. `export_arm_source.gd` skins the meshes into the
   rest and binds them there (`_bind_at_rest`); the build checks the rest (0.0000 m).
2. **Blender's IK cannot bend a perfectly straight chain**: it pointed the T-pose arm past the
   target. A pose rotation as a pre-bend worked until the first export reset the pose bones in the
   open scene. The bend is in the REST now: the elbow joint is `ELBOW_BEND` (1.5 cm) behind the
   line, which nothing can reset. Signs of a straight chain: the wrist off by the arm's full
   reach, the hand's turn still right.
3. **Blender's first frame is 1**: exported as is, every clip started 1/30 s late (`hand` 0 deg
   off but the wrist up to 39 cm). `export_anim_slide_to_zero`.
4. **`export_reset_pose_bones` off**: it resets the open scene's unkeyed pose bones.
5. **Godot reimports only when the file's content changes** (it compares md5): an export that
   writes the same bytes is not reimported, so an unchanged probe result can mean an unchanged
   export, not a missed rescan.
6. **The export takes the clip's timing from the scene's frame rate**: lowered to 12 to watch
   the move slowly, it made the 1.2 s swing 3.0 s long. `export_clips.py` sets 30 for the export
   and puts the scene's own back.
7. A Godot-exported glb drops leaf bones with no weights (`weapon_r`, some twist helpers);
   nothing uses them.
8. **The glTF exporter (ACTIONS mode) takes every action in the file**, an armature's or not
   (2026-10-23): the body reference's `body_reference` came into `fp_arms.glb` as a clip, and while
   sampling it the exporter posed FPArms' bones of the same names with it and, with
   `export_reset_pose_bones` off, left them so -- `RightUpperArm` kept the body's arm shrink
   (scale 0.001), the sword arm collapsed into its shoulder in the scene, and the next export gave
   the game a swing whose cuts all leant 6.6 deg further right. `export_clips.py` now keeps only
   the actions with FPArms' slot (the exporter's `gltf_action_filter`). Fixed by setting every
   FPArms bone no action keys back to rest (45 of them). After any export, the game's swing can be
   checked against the committed file with `slash_lean.gd` (the cut's line at each lean).

## Open

- Not judged in game: `swing_down_blender`, and how editing in Blender feels.
- **The fist closes on the handle where it is; the clip's fingers are played** (2026-10-23,
  Kirill: in the swing "the palm is not actually gripping the hilt tightly"; then "keep single
  source of truth"). The `Weapon` keys of `swing_down` turn the sword in the hand up to 52 deg and
  move it 3 cm (a looser grip that spares the wrist: holding the sword fixed in the fist instead,
  tried and taken back the same day, bent the wrist up to 88 deg in the cock), and the stance's
  fixed fist then stood open round the handle (the thumb's and forefinger's tips 7 cm from its
  middle, 4.2 in the idle).
  - In Blender: `tools/blender/fp_arms/wrap_fingers.py` keys the right hand's fingers on every frame
    of every action, each wrapped round the handle (the `Weapon` bone's line) in three stages until
    it touches (all three joints, then the outer two, then the last: with the first stage alone
    the middle joint touched first and the finger made a ring, not a grip). Re-run it after
    changing a move's hand or `Weapon` keys; it replaces the finger keys.
  - In the game: `PlayerBody._play_clip_fingers` plays the clip's fingers during a Blender swing
    (`swing_fingers_from_rig`, on), read as each finger's turn from its rest against the hand's and
    blended with the swing; outside one the stance's posed fist is kept. A first version worked the
    wrap out in the game itself (`_wrap_fingers_round_handle`, removed the same day for this).
  - Measured (`tools/weapon_probes/grip_fingers.gd`, tip from the handle's middle; the handle's
    radius 2.2 cm): the four fingers 3.1-4.0 cm through the swing (4-7 before), the game within
    0.1-0.3 cm of Blender on the same frames; the thumb 5.7-6.3 (7.1). Measured on the glove mesh in
    Blender the fingers touch the handle or lie up to 2 cm into it on some swing frames (the wrap
    works from the bones). Not judged in game.
- A clip is made for this sword: `socket` is the stance's grip with this sword. Another weapon
  needs the scene rebuilt (steps 1-2) or a correction on top.
- Chaining one rig clip into another (the tree's cross-fade) is written but untested: only one
  rig clip exists.
- Only the right arm. The shield arm needs its own chain and controls in the scene.
