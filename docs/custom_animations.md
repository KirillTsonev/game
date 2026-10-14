# Custom animations for the player's body

How to add an action the animation packs do not have (the first one: turning the lantern on
and off, L). Written 2026-10-12 from building that one; every rule below is something that
went wrong once. The code is in `scripts/player_body.gd`; `CLAUDE.md` ("The player's body")
has the facts about the body itself.

**The aim is realism: life-like movement** (Kirill, 2026-10-14, for the fidgets and every
other animation). Judge every timing by what a real person does: nobody holds a pose, waits
for one part to finish before the next starts, or moves at an even pace. Moves start a
little quicker than they settle (`_ease`), parts overlap (T4), two hands working together
move together, and nothing that is held stands perfectly still for long.

The actions made this way are **not keyframed**. Each frame, after the clip has posed the
body, code moves a few bones: arms are solved to reach points, hands are turned, fingers are
set. So an action runs over any clip (the legs go on walking) and follows things that move
(the lantern swings).

## 1. Decide what kind of animation it is

| Kind | Examples | How |
|---|---|---|
| A clip that exists | walk, run, sword swing, roll | Take it from the packs: one line in `CLIPS` (`player_body.gd`), and in `ANIMATION_FILES` (`tools/blender/import_rogue_character.py`) if the file is new. |
| A change to a clip | cut the first half of a landing, mirror, retime | Edit the `Animation` when it is loaded (`_ready`), as `_add_missing_tracks` does. |
| Hands going to things | the lantern's knob, a door handle, a lever, picking something up | This document. |
| Whole-body motion with weight | a walk cycle, an attack, a stumble | Do not build it by hand: it comes out robotic. Find a clip. |

## 2. Write the action down before any code

Four lists. Agree them with Kirill first; they are the design.

1. **What the player sees.** Where the camera looks (how far down, turned, tilted) and
   whether the thing acted on is in that view at all (rule V1 below).
2. **What the body does.** Any bend of the spine, and which way.
3. **Where each hand goes.** Named points on real objects, and which part of the hand
   touches: the palm, or the finger pads.
4. **The order.** Parts with a start and an end, as shares of the whole
   (`TOGGLE_REACH := [0.03, 0.2]`), plus the moment the game state changes.

Things to settle with him: may the player keep moving (so far: yes), and is the camera
taken over (so far: partly, never while sprinting).

## 3. Find the real points

**Measure, do not guess.** A guessed knob position was 2 cm off and on the wrong part.

- **A point on a prop.** Load the `.glb` in Blender (background mode), print the mesh's
  outline per band of height, and look for what sticks out. The lantern's knob was found as
  "the only thing reaching 0.04 m from the middle line at that height". Splitting the mesh
  into separate parts does not work on these models: vertices are split at every UV seam
  (4,563 "parts"), and after welding the lantern is one piece. Render close-ups from four
  sides to confirm what the numbers found. Axes: Godot (x, y, z) = Blender (x, z, -y).
- **A point on the body.** Compute the skinned mesh in a script (each vertex = the sum over
  its bones of weight x bone pose x bind pose x vertex) and read where the surface is. The
  belt's outer face and the trousers' radius came from this.
- **A point on the hand.** `_setup_arms` reads them from the rest pose (a T-pose, palms
  down): `palm`, `middle` (of the hand), and the per-finger joints with the axis each
  closes about. Add new ones there, in the hand bone's own axes.

Write every found number into the setting's comment with how it was found.

## 4. Build it from the existing pieces

All in `scripts/player_body.gd`.

| Piece | What it does |
|---|---|
| `toggle_lantern()` / `_advance_toggle()` | The pattern for an action: a clock (`_toggle_at`), ignored while already running, state changed at a set moment. |
| `_part(through, [from, to])` | 0 before a part, 1 after, eased between. Multiply by `1 - _part(...)` of the leaving part to get a weight that rises and falls. |
| `view_offset()` | What the action adds to the camera's rotation; the Player's own `pitch` is untouched. The Player ignores the mouse while `has_the_view()` is true. |
| The bend in `_advance_toggle` | Turns `Spine` and `Chest`, before the eyes are found, so the camera follows the head. |
| `_reach(arm, point, bones, target, weight, elbow, palm_toward, ...)` | Solves one arm so a point of the hand is at a target. Options: `around` (bow the path out toward a place), `fingers_toward` + `aim` (point a line of the hand a given way), `roll`, `given` (the hand's turn outright). |
| `_set_fingers(arm, closed, weight, thumb_in)` | Replaces the clip's fingers: radians per joint for thumb, forefinger, middle, ring, little. |
| `_place_lantern` | Where the action's hand code is called: after the clip, the bend and the eyes. |

Order inside one frame matters and is fixed: clip -> body bend -> eyes and model shift ->
right hand -> lantern -> left hand (which needs the lantern's new place) -> light.

Every tunable becomes an `@export` on the `Body` node with a comment saying what it does
and what was tried. Kirill tunes in the Inspector while the game runs; he does not use
launch arguments.

## 5. Rules, each from a fault Kirill saw or a check caught

### View

- **V1. Check the target is in the picture.** The camera's half-height is 37.5 degrees.
  The lantern at the hip is almost straight below the eyes: a 38-degree dip never showed
  it. Compute the angle between the view's centre line and the target.
- **V2. Do not bend the body forward toward something at the hip.** It carries the eyes
  past the thing, which is then behind the camera. Bend sideways: the head comes over it.
- **V3. Keep the camera move short and skip it while sprinting.** It is done often.

### Arms

- **A1. Check the reach.** Upper arm 0.28 m, forearm 0.28 m; the shoulders are about
  0.25 m behind the eyes. A target "in front of the chest" had both arms at full stretch
  (elbow 173 degrees) and one hand 5 cm short. Aim for elbows near 100-130 degrees.
- **A2. A hand crossing the body must go round it.** A straight line from the left side
  to the right hip is a line through the belly: give `_reach` an `around` point in front.
- **A3. The elbow decides where the forearm lies.** With the hand routed correctly but
  the elbow pointing back, the forearm still lay through the abdomen. For a reach across
  the front, the elbow goes forward and outward (`TOGGLE_LEFT_ELBOW`).
- **A4. Measure clearance from the trunk's middle line** (hips to upper chest): the
  surface is 0.13-0.15 m out. Hand, forearm midpoint and elbow should all stay beyond it.

### Hands

- **H1. Set the hand's turn, not only its place.** With the turn left to the clip, a
  hand reads as a fist passing by. `palm_toward` makes it a hand placed on the thing.
- **H2. Limit the wrist** (`TOGGLE_WRIST_MAX`, about 45 degrees). Pushing forward with
  the forearm pointing at the thing asked for 70.
- **H3. For a closed grip, point the line from the hand's middle to the fingertips at the
  thing, not the fingers' own line.** With curled fingers the knuckles lead, and they went
  into the mesh.
- **H4. Aim the finger pads, not the fingertips.** The pad's middle is 1.6 cm from the
  last joint (`FINGERTIP`). Aiming 3 cm out left the pads that much short.
- **H5. A turning grip: find the grip once, then only roll it** (`_pinch_grip`, passed to
  `_reach` as `given`). Worked out afresh every frame, the grip shifted with the forearm
  as the hand went round, and a 90-degree turn swung the hand through 180-220.
- **H6. The wrist alone turns it**, since the forearm does not roll yet: keep a turn to
  about 50 degrees. At 90 the hand folded more than 100 degrees back on the forearm.

### Fingers

- **F1. The clips hold the hands as fists** (77 degrees a joint standing, 105 running).
  Any action with visible hands must set the fingers for its whole length.
- **F2. Open on the way, close on arrival, one finger after another** (a 0.015 share of
  delay each). All at once reads as a clamp.
- **F3. A pinch needs the thumb's second movement.** Closing alone never brought thumb
  and forefinger nearer than 3 cm; swinging the thumb in toward the fingers (`thumb_in`)
  does. Settings that meet on this model: fingers 1.0 rad a joint, thumb 0.5, thumb in
  0.4 -> pads touching, 1-2 cm between the three.
- **F4. Search for finger settings by measuring**, not by eye: loop over the values in a
  script and print the distance between the pads.

### Timing and state

- **T1. Anything under about 0.3 s reads as a flick.** A 0.2 s "turn" with the light
  snapping over half-way looked like a switch. 0.4 s reads as a turn.
- **T2. Let the game state follow the motion** where the real thing would: the lantern's
  light rises and falls with the knob (`level` in `lantern_flicker.gd`), it does not jump.
- **T3. Opposite actions go opposite ways** (lighting and putting out turn the knob in
  opposite directions).
- **T4. Overlap the parts.** Looking down, acting and looking up played one after another
  read as three separate actions and took 2.0 s. Start the hands as the view starts down,
  bring the second hand in while the first is still working, and start the view back as
  the main action ends: 1.5 s, and one motion. Each part still needs what it depends on
  finished first (a grip must be closed before it turns). The same again in the strap
  fidget (2026-10-14), each one Kirill's: the right hand reached for the shield only once it
  was up, then took longer than the arm raising it; the grip had a stage of its own and a
  hold before the tug; and letting go, the fingers opened fully before the hand moved and
  the hand was gone before the shield came down. Now the hand and the shield go up together
  and the grip closes as the shield stops, the tug follows at once, the fingers loosen as the
  tug ends and the hand is already leaving while they open, and the shield lowers with it.
  Releasing is not "open, then move": a hand lets go as it leaves.

### Things that are moved

- **M1. A thing on a hook stays on the hook** unless the story says otherwise. Taking the
  lantern off the belt each time "doesn't seem logical" (Kirill).
- **M2. Lead a moved thing back to where it was.** Swung forward and let go, the lantern
  came down in front of the thigh and stayed leaning on it.
- **M3. A swinging thing needs a speed limit and a tilt limit**, or a leg's hit sends it
  over its own handle.

## 6. Check it without opening the game

Kirill judges how it looks; do not launch the game to judge that. What can be checked is
whether it does what was meant, with a script run headless:

```
Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script <check.gd>
```

The script extends `SceneTree`, instantiates `scenes/player.tscn`, switches the Player's
physics off, drives the body by hand and prints numbers:

```gdscript
extends SceneTree

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var player: Node3D = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	root.add_child(player)
	var body: PlayerBody = player.get_node("Body")
	player.set_physics_process(false) # no world here
	await process_frame
	for i in 60: # let the idle clip settle
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		await process_frame
	body.toggle_lantern()
	for i in int(body.toggle_time * 60.0):
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		await process_frame
		# measure here, print every few frames
	quit()
```

- **Run it with a time limit.** A script error never reaches `quit()` and the process
  hangs.
- **Run each check standing, running forward and strafing.** Running leans the body and
  was the weak case every time.
- **Measure on the mesh when it is about touching.** Bones said the pinch was 1 cm from
  the knob while the glove's surface was 2-4 cm away. Skin the vertices in the script (see
  section 3) and measure from the surface.
- **A check that plays clips one after another must give every bone a track**, or a bone
  keeps the last clip's pose and the numbers are wrong (`_add_missing_tracks`).

What to print, by the question asked:

| Question | Number |
|---|---|
| Is it in view? | angle between the camera's forward and the direction to the target; under 37.5 degrees is in the picture |
| Can the arm reach? | elbow angle; distance from the hand's point to its target |
| Does it go through the body? | least distance of hand, forearm midpoint and elbow from the hips-to-chest line |
| Does it go into the prop? | least distance of the glove's vertices from the prop's middle line, against the prop's thickness there |
| Does the grip close? | distance between the pads' vertices |
| Does it touch? | least distance from the glove's vertices to the target point |
| Is the wrist sane? | angle between the hand's finger line and the forearm |
| Does it turn as asked? | angle of the hand's across-the-knuckles axis about the turn's axis, from the turn's start |
| Is the state right? | the light's `visible` and `light_energy` over time |
| Did anything break? | `is_finite()` on every position printed |

## 7. Hand it over and iterate

Tell Kirill what the numbers say, what could still look wrong, and which settings on the
`Body` node move what. He runs it and names one fault; fix that one and measure again.
Expect several rounds: the lantern action took eight.

Faults he named, in the order they came, as a sense of what to expect:
the target is not in view -> taking it off the belt is not logical -> palms should be open
and fingers should move -> the hand goes through the body -> it looks like flipping a
switch (twice) -> fingers go through the mesh, the pinch is too wide -> the grip does not
touch the knob.

When it is accepted, add what was learnt to section 5 and to `CLAUDE.md`.

## Not built yet

- The forearm does not roll with the hand (the rogue's twist bones get no tracks), so
  large hand turns strain the wrist and may pinch the sleeve.
- No upper-body / lower-body split: an action overrides the arms by weight, which works
  for reaching but not for playing an upper-body clip over the legs.
- The spine does not bend with the camera's pitch outside an action.
- Feet are not placed on slopes.

## With a sword and a shield in the hands

(2026-10-14) The lantern action runs with both held: the left hand stays in the shield's
strap and pinches with three fingers, the sword fist comes in behind the lantern and pushes
it with its knuckles. What was tried, the values, the probes and the rules are in
`docs/weapons.md`, sections 6, 7 and 10.
