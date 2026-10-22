# Editing a first-person move in Blender

Step by step, from opening the scene to seeing the change in the game. How the pipeline works and
why: `docs/blender_animation.md`.

## 1. Open the scene

- Blender: `D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe`.
- File → Open → `herald-of-oblivion\animation_sources\fp_arms\fp_arms.blend`.
- Over the 3D view: **Z → Material Preview** for the game's textures (if the arm is grey).

## 2. Pick the move

- Change an area to the **Dope Sheet** (the area-type menu at its top left), set its mode to
  **Action Editor**, pick the action (`swing_down`). `hold` is the idle stance: don't edit it.
- Set the timeline's **End** to the action's last frame (`swing_down`: 37).

`swing_down`'s frames:

| Frames | Part                                   |
| ------ | -------------------------------------- |
| 1      | the idle hold (keep it as it is)       |
| 2-6    | wind-up (no keys yet: shape it)        |
| 7-23   | the copied stroke (cock, strike, hold) |
| 24-36  | recovery (no keys yet: shape it)       |
| 37     | the idle hold again (keep it as it is) |

## 3. Watch it as in the game

- **Numpad 0**: through the eye camera (again to leave).
- Timeline → Playback → Sync: **Frame Dropping** (real speed).
- **Space** plays (it loops), **←** / **→** one frame, or drag the frame number.
- Smoother, like 60 fps (optional): Output Properties → Frame Rate **60**, Time Stretching
  Old **30** / New **60**. Slower: a lower Frame Rate (e.g. 12). The export always uses 30 and
  puts your setting back, so there is nothing to undo before exporting.

### Ghosts (onion skin)

- **N** over the 3D view → the **FP Arms** tab → **Ghosts**: see-through copies of the arm and
  the sword a few frames before (blue) and after (orange) the current one, fainter further away.
- **Show** draws them around the current frame, **Clear** removes them. They are frozen: press
  Show again after moving to another frame or changing a pose.
- *Frames before / after* (3 each), *Every n frames* (1 = each frame, 2 = every other one...).
- They never reach the game. If the tab is missing after opening the file, Blender blocked the
  file's scripts: allow them (the bar at the top), or run `tools\blender\fp_arms\ghosts.py` once
  from the Scripting tab.
- Bones' paths instead: Armature properties → Motion Paths → Calculate.

## 4. Pose

- Click the arm, **Ctrl+Tab** → Pose Mode.
- Go to the frame, select a control, change it:

| Control         | Colour | What it does                                    | Keys                            |
| --------------- | ------ | ----------------------------------------------- | ------------------------------- |
| `CTRL_hand`     | red    | the hand: the arm follows                       | **G** move, **R** turn          |
| `CTRL_elbow`    | blue   | which way the elbow points                      | **G**                           |
| `Weapon`        | orange | the sword in the fist (the handle's turn)       | **R** (G slides it in the hand) |
| `Eyes`          | yellow | the head's nod / turn / tilt, added to the view | **R**                           |
| `CTRL_shoulder` | green  | where the arm hangs from                        | **G** (rarely)                  |

- Typed values work too: **R X 20 Enter** turns 20 deg about X; **G Z 0.05 Enter** moves 5 cm up.
- Fingers can be posed, but **the game ignores them for now** (it closes its own fist).
- **Alt+G / Alt+R** clears a move by mistake; **Ctrl+Z** undoes.

## 5. Key it

- **I** keys the selected controls on this frame. Or turn on auto-keying (the record dot in the
  timeline header) and every change is keyed.
- Key `CTRL_hand`, `CTRL_elbow` and `Weapon` together on a frame you pose, or the ones left out
  keep their old curve and drift against the new pose.
- The copied stroke (7-23) has a key on nearly every frame. A change on one frame there gives a
  bump: for a bigger change, delete the keys around it first (Dope Sheet, select, **X**) and
  key only the poses that matter -- or ask Claude to thin them to the extremes.

## 6. Timing

- Dope Sheet: select keys (click, **B** box, **Alt+click** a column), **G** slides them in time,
  **S** scales a selection in time (with the frame under the playhead as the pivot).
- Faster strike = its keys closer together. A longer wind-up = slide everything from frame 7 on
  later.
- Easing: change the area to the **Graph Editor** (the curves); **T** sets a key's
  interpolation, **V** its handle type.
- **If the clip's length changes** (its last key is no longer frame 37) or the strike moves,
  tell Claude: the game's entry (`swing_down_blender` in `scripts/player_body.gd`) has the clip's
  length (`clip_to`), when a click can chain (`chain`) and when the blade can hit (`hit`).

## 7. Save and export

1. **Ctrl+S**.
2. The **Scripting** tab → Text → Open → `herald-of-oblivion\tools\blender\fp_arms\export_clips.py`
   → **Run Script** (▶). (Once opened, it stays in the file: next time just pick it and run.)
   Or ask Claude to run it.
3. Click into the Godot editor: it reimports `fp_arms.glb` when it gets focus.
4. Play: left click. The Body's **Swings From Blender** (Combat group) must be on.

## 8. After changing the stance in Godot

When you move the WeaponStance's markers (the hand, the elbow, the sword's turn in the fist), the
moves still start and end on the old stance. To bring them over, keeping your edits:

1. Ask Claude to re-run step 1 (it writes the new stance from the game), or run
   `export_arm_source.gd` yourself (`docs/blender_animation.md`, the pipeline table).
2. In Blender, the Scripting tab: open `tools\blender\fp_arms\update_stance.py` → **Run Script**.
   It replaces only the keys that are the old stance (`hold`, a move's first and last frame, the
   fingers) and lays the sword on the new grip; your keys are left alone. A turn of the sword
   in the stance carries through the whole move.
3. Export (section 7).

## Don't

- **Don't run `build_scene.py`**: it rebuilds the moves from the copied clips and throws your
  edits away.
- Don't edit `hold` or move frame 1 / the last frame off the stance: the game blends into and out
  of the clip in only 0.05 s, so a start or end away from the stance jumps.
- Don't rename `FPArms`, its bones or the actions: the game finds them by name.

## If something looks wrong

| Seen                                               | Why / what to do                                                                              |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| The arm grey                                       | Z → Material Preview.                                                                         |
| The arm pointing straight past the hand control    | the IK lost its bend: the elbow joint must sit a little behind the straight arm. Tell Claude. |
| Bones far from the arm (a hand's worth of fingers) | the viewport did not redraw: hover over it; if they stay, tell Claude.                        |
| The change does not show in game                   | did the export run (Scripting tab, Run Script)? Godot reimports only a changed file.          |
| The sword jumps at the start or end of a swing     | frame 1 or the last frame is no longer the stance.                                            |
