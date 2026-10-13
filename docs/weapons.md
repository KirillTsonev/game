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
  shield's mesh box, so it works for any shield.
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

**Right hand, with a sword in it (`armed`).** The sword comes along; the fist's knuckles
nudge the lantern, the blade pointing ahead (Kirill's idea, after three others failed):

| Tried | Measured |
|---|---|
| Palm against the lantern, as the open hand | Sword 8-13 cm in the body, 5 cm in the lantern. |
| Palm against it, hand turned to aim the blade (10 directions) | The same: the handle is in the palm. Wrist 72-86 deg. |
| Back of the hand against it | Body clear, lantern still 4-5 cm in, wrist 100-170 deg. |
| Forearm against it, fist past it | Numbers clean, but the "contact" was with the wire handle: Kirill, "nothing touches the lantern". |
| Pommel against it, blade ahead | No pose found. |
| **Knuckles against its body, blade ahead** | Sword 0-2 cm clear of the body, crossguard about 3 cm into the lantern's top end, blade within 1 cm of the shield's edge. "Looks great." |

How it runs:

- The shoulder goes back onto the body for the reach (the lantern is out of reach from the
  stance's shoulder). The wrist stays as the stance has it; `toggle_armed_roll` rolls the
  forearm, which is what points the blade; `toggle_armed_elbow` is the elbow's side.
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
| `lantern_armed_search.gd` | `SEARCH` | Thousands of fist places, elbow sides and rolls at the knob's turn, one per tiny frame, kept where the blade points ahead and the knuckles (or pommel) touch the lantern's body. |
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
| `toggle_armed_fist`, `_fist_hanging`, `_around`, `_elbow`, `_roll` | Blade length, crossguard width (the guard is what meets the lantern). |
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
- The shield clips a thigh in sideways jogs when sheathed.
- Shadow hands stop at `weapon_shadow_reach` during the lantern reach.
- The lantern action with weapons was measured standing only.
- The crossguard reads about 3 cm into the lantern's top end; the knuckles are about 5 cm
  short of it for the first part of the push.
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
