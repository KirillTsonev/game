# First-person moves animated in Blender

(2026-10-22) How a first-person move of the sword arm is animated in Blender and played in the
game. Kirill's choice: the moves themselves are authored as clips (Claude generates them in
Blender, Kirill adjusts them there); the adaptive layers (view-follow, breathing, step bob,
keep-off, the elbow's hinge, feet) stay in code. Playback is glTF + AnimationTree.

**The pilot:** the down slash (`swing_down_blender`), built from the copied ArmClip down slash.
On a round trip with nothing edited it plays like the copied one (numbers below). **Not judged in
game yet.** Moves not moved over yet: the rising slash, the dodges, the fidgets, the lantern
action, the shield arm.

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

- Steps 1 and 2 are needed only for a new scene: after the stance changes (re-run 1, then 2),
  or for a new weapon. **Step 2 clears the open scene and rebuilds every action listed in its
  `SWINGS` from the ArmClips: hand edits are lost.** Once a move has been adjusted by hand, take
  it out of that list.
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
  - The fingers: plain bones, rotate them. **The game ignores them for now** (it closes the
    stance's fist on the handle).
- Textured as in the game in Material Preview (Z): `tools/blender/fp_arms/game_materials.py`
  copies the game's materials (albedo, normal, packed roughness / metallic, each times the
  material's value -- the rogue's metallic is 0, the sword's 1) onto the arm and the sword, the
  project's texture files referenced, not copied. `build_scene.py` runs it; run it alone to
  refresh. Blender's own studio light, not the game's lighting, fog, grade or post effects.
- Actions: `hold` (the stance, one frame: a reference to start a move from) and the moves.
  30 frames a second; frame 1 is the start. A new move = a new action (the Action editor's
  New, the armature selected). The exporter writes every action the armature has had.

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
6. A Godot-exported glb drops leaf bones with no weights (`weapon_r`, some twist helpers);
   nothing uses them.

## Open

- Not judged in game: `swing_down_blender`, and how editing in Blender feels.
- The fingers of a clip are not played (the stance's fist is). Playing them = reading their turns
  the same way and blending them in `_hold_weapon`.
- A clip is made for this sword: `socket` is the stance's grip with this sword. Another weapon
  needs the scene rebuilt (steps 1-2) or a correction on top.
- Chaining one rig clip into another (the tree's cross-fade) is written but untested: only one
  rig clip exists.
- Only the right arm. The shield arm needs its own chain and controls in the scene.
