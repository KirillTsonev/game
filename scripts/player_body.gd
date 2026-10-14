class_name PlayerBody
extends Node3D

## The player's own body, seen from the first-person camera: the rogue model, one clip at a
## time picked from how the Player moves, and the point where the camera belongs (the eyes).
## The root of scenes/player_body.tscn (the model, and the hook the lantern hangs from), which
## is the node "Body" of player.tscn; the Player calls set_motion() every physics frame and
## advance() every frame.
##
## The clips come from two sources with skeletons of their own (Quaternius' Universal Animation
## Library, CC0, and Mixamo's jogs). Each and the rogue are imported onto Godot's humanoid
## bone names, so any clip plays on the rogue:
## tools/blender/import_rogue_character.py.
##
## Not done yet: blending between directions (the nearest of eight is played), an animation
## tree with separate upper and lower body, the spine bending with the camera's pitch, feet
## placed on slopes, the rogue's twist bones (no clip moves them: the wrists may pinch),
## crouch-walking sideways or backward (the forward clip is played, backward in reverse).

const CLIP_DIR := "res://assets/models/characters/rogue/animations/"
const UAL1 := "ual1.glb" ## Universal Animation Library 1: 43 clips in one file
## Clip -> [file, clip in the file ("" = its only one), loops, the speed over the ground (m/s)
## at which its feet match the ground on the rogue at playback speed 1 (0 = not a moving clip)].
## The library's are measured on its root-motion version, times 1.07, the rogue's legs being
## that much longer than its mannequin's. Mixamo's jogs are in place: theirs is the speed of
## a foot against the hips while it is on the ground, measured on the rogue itself with the
## clip playing (the middle value over a cycle). They are jogs of 2.3 to 3.0 m/s and the eight
## differ: at the Player's 3 m/s they play at 1.0 to 1.3 times their pace. (At 4 m/s it was
## 1.3 to 1.6, with right, backward and back-right at the playback limit and 3 to 8 % short.)
const CLIPS := {
	&"idle": [UAL1, "Idle", true, 0.0],
	&"jog_fwd": ["jog_fwd.fbx", "", true, 2.63],
	&"jog_fwd_left": ["jog_fwd_left.fbx", "", true, 2.79],
	&"jog_fwd_right": ["jog_fwd_right.fbx", "", true, 2.9],
	&"jog_left": ["jog_left.fbx", "", true, 3.0],
	&"jog_right": ["jog_right.fbx", "", true, 2.44],
	&"jog_bwd": ["jog_bwd.fbx", "", true, 2.38],
	&"jog_bwd_left": ["jog_bwd_left.fbx", "", true, 2.56],
	&"jog_bwd_right": ["jog_bwd_right.fbx", "", true, 2.31],
	# The library's jog: a long bounding stride, the Player's default pace while that was
	# 6 m/s. (Its "Sprint" covers 8.8 m/s, for the 9.6 m/s the sprint was then.)
	&"sprint": [UAL1, "Jog_Fwd", true, 5.6],
	&"crouch_idle": [UAL1, "Crouch_Idle", true, 0.0],
	&"crouch_fwd": [UAL1, "Crouch_Fwd", true, 0.8],
	&"jump_air": [UAL1, "Jump", true, 0.0],
	&"jump_land": [UAL1, "Jump_Land", false, 0.0],
	# Mixamo's "Standing Dodge" hops, for the dash: see DASH_PARTS.
	&"dash_fwd": ["dodge_fwd.fbx", "", false, 0.0],
	&"dash_bwd": ["dodge_bwd.fbx", "", false, 0.0],
	&"dash_left": ["dodge_left.fbx", "", false, 0.0],
	&"dash_right": ["dodge_right.fbx", "", false, 0.0],
}
## The part of each dash clip that is played, in seconds of the clip: from where its hips set
## off to where they have arrived. A clip is a hop of about a second -- 0.1 to 0.2 s of sinking
## into the knees first, which is left out so that the dash answers the key at once, then the
## travel, then a landing, which the fade to the next clip stands in for. The part is played
## over the dash's own time (the Player's dash_time), so at 0.4 s about 1.5 times its pace.
const DASH_PARTS := {
	&"dash_fwd": [0.23, 0.83],
	&"dash_bwd": [0.2, 0.9],
	&"dash_left": [0.1, 0.87],
	&"dash_right": [0.07, 0.77],
}
## The sword arm's clips (Mixamo's sword and shield pack). ONLY THE RIGHT ARM of each is used,
## shoulder to hand, played by a second AnimationPlayer over whatever the body's clip does; the
## fingers stay as WeaponHold closes them. Clip -> [file, loops]. A try of 2026-10-13: the
## body, the left arm and the camera take no part in a swing yet.
const ARM_CLIPS := {
	&"sword_idle": ["sword_idle.fbx", true],
	&"sword_slash": ["sword_slash.fbx", false],
	&"sword_attack": ["sword_attack.fbx", false],
}
const ARM_BONES: Array[String] = ["RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]
## The swings attack() goes through in turn.
const ARM_SWINGS: Array[StringName] = [&"sword_slash", &"sword_attack"]
## The eight ways to move, clockwise from straight ahead, as they appear in the clips' names.
const DIRECTIONS: Array[String] = ["fwd", "fwd_right", "right", "bwd_right", "bwd", "bwd_left", "left", "fwd_left"]
## Drawn into shadows only: the camera sits inside them.
const HIDDEN_FROM_CAMERA: Array[String] = ["head_geo", "hood_geo"]
## Clothing pieces not worn at all (no picture, no shadow). "mantle_geo" is the cape over one
## shoulder, with its clasp (Kirill, 2026-10-12: "remove that cape thing").
const NOT_WORN: Array[String] = ["mantle_geo"]

## The lantern on the belt (tools/blender/import_lantern.py; its origin is the top of its handle).
const LANTERN_FLAME := Vector3(0.0, -0.18, 0.0) ## the flame's middle, from the handle's top
## The lantern swings from its handle as a pendulum: one point (the middle of its body) on a
## rigid arm, pushed out of the leg it hangs against. Everything is worked out in the Player's
## own space, so walking at a steady pace does not drag it; the hips' own movement and the
## Player's changes of speed are what set it swinging.
const LANTERN_ARM := 0.19 ## m from the handle's top to the middle of the lantern's body
## The lantern's body as a ball: half its thin side (it is 0.13 m wide and 0.10 m deep, and
## hangs with the thin side to the leg).
const LANTERN_RADIUS := 0.05
## What the lantern bumps into: capsules between two bones [from, to, radius in m], on the
## leg of the side the hook is on ("%s" = Left or Right). The thigh's is the trousers'
## measured radius over its upper half (0.11-0.12 m).
const LANTERN_OBSTACLES := [
	["Hips", "%sUpperLeg", 0.09],
	["%sUpperLeg", "%sLowerLeg", 0.11],
	["%sLowerLeg", "%sFoot", 0.065],
]
const LANTERN_GRAVITY := 9.8
## Where the handle's top hangs is the node HipsAttachment/LanternHook of scenes/player_body.tscn:
## move it in the editor (the lantern shown there hangs from it, rigid). It starts on the belt:
## measured on the model, the strap's outside at the left hip is 0.187 m out from the hips bone
## and runs from 0.04 to 0.12 m above it.
## Off: the lantern hangs straight down, rigid.
@export var lantern_swings: bool = true
## How fast a swing dies away (per second): 0 = it never does, 5 = almost at once.
@export var lantern_damping: float = 2.5
## The fastest the lantern's body may move against the Player (m/s). It is what bounds the
## swing: at 1.0 it cannot rise more than about 45 degrees from hanging straight.
@export var lantern_max_speed: float = 1.0
## The furthest the lantern may tilt from hanging straight (degrees), whatever pushes it.
@export var lantern_max_angle: float = 55.0
## Share of its speed the lantern keeps when it hits the leg: 0 = it stops dead, 1 = it bounces off.
@export var lantern_bounce: float = 0.3
## The strongest push (m/s2) a change of the Player's speed gives it. The Player goes from
## standing to full speed in one frame; unlimited, that would throw the lantern over its handle.
@export var lantern_push_limit: float = 12.0
## The Player's lantern light (an OmniLight3D with scripts/lantern_flicker.gd), kept in the flame.
@export var lantern_light_path: NodePath = ^"../Lantern"
## Off: the lantern model throws no shadow, so the light leaves it as if nothing were round the
## flame. On: its frame, cap and base shadow the ground and the body, as a real lantern's do.
@export var lantern_casts_shadow: bool = false

## How far from the lantern (m) the body's shadow in its light reaches; it is full beside the
## light and fades to nothing at this distance. 0 = the body does not shadow the lantern's
## light at all. (The moon's shadow of the body is not touched.) Can be changed while the game runs.
## With the light at the hip, the legs and the arm beside it throw long shadows that sweep the
## ground in front with every step (Kirill, 2026-10-12: annoying). Tried: half-strength shadows
## for the whole light (taken back), no shadow from legs and arms ("too drastic"). A light's
## shadow cannot be made to fade with distance, so it is done with three lights in one place:
## the lantern's own, which the body does not shadow; "NearMinus", a NEGATIVE light of the same
## strength reaching only this far, which takes the near part of that light away again; and
## "NearWithBodyShadow", the same light positive, which puts it back except where the body
## shadows it. Unshadowed, the last two cancel exactly. All three take the world's shadows.
@export_range(0.0, 6.0, 0.05) var body_shadow_reach: float = 1.7
## The render layer (1-20) of the body and the lantern model, which are on it alone. Cameras
## and the other lights take every layer, so nothing else changes for them.
const BODY_LAYER := 12
## The lantern's light on the body itself, as a share of what it gives the world. The light
## hangs a hand's width from the hip and grows stronger the nearer a surface is, so at full
## strength the trousers and belt beside it burn out white (Kirill, 2026-10-12: "still very
## bright"). The lantern's light therefore skips the body, and a second light in the same
## place, with this share of its energy and no shadows, lights the body alone.
@export_range(0.0, 1.0, 0.01) var lantern_light_on_body: float = 0.25
## How strongly the flame in the lantern model glows (its material's emission energy; the
## model came with 4). It is only the picture of the flame -- the light it gives is the Lantern
## node's -- but the bloom and glare effects spread whatever is brighter than their threshold,
## and at 4 it was a white blot at the hip. Can be changed while the game runs.
@export_range(0.0, 8.0, 0.05) var lantern_flame_glow: float = 1.0

## Turning the lantern on or off (L) takes a moment, and the Player can keep moving through it.
## The lantern stays on the belt (Kirill, 2026-10-12: taking it off each time "doesn't seem
## logical"; the first version lifted it before the chest). The view goes down and to the
## right, the body bends that way, the open right hand cups the lantern and swings it forward
## on its hook, the left hand comes across to its knob and tugs, the light changes at the tug,
## and everything goes back. The mouse does nothing to the view while it has it.
## Seconds for the whole of it.
@export var toggle_time: float = 1.5
## Where the view goes: this far below level (degrees; no dip if the Player already looks
## lower), turned this far to the right, and tilted this far (the right ear down). None of it
## while sprinting. The lantern hangs almost straight below the eyes, so it takes a steep look.
@export var toggle_dip_degrees: float = 78.0
@export var toggle_turn_degrees: float = 15.0
@export var toggle_roll_degrees: float = 8.0
## How the body bends toward the lantern (degrees, shared between the spine and the chest):
## sideways to the right, which brings the head over the lantern, and turned to the right,
## which brings the left shoulder forward for its reach. Not forward: that carries the eyes
## past the lantern, which would then be behind them.
@export var toggle_bend_side: float = 15.0
@export var toggle_bend_turn: float = 15.0
## How far forward the right hand swings the lantern on its hook (degrees from hanging straight).
@export var toggle_swing_degrees: float = 75.0
## Where the right palm rests against the lantern, from the middle of the lantern's body in
## the Player's axes (+X right, +Y up, +Z back): behind it and a little outside.
@export var toggle_cup_offset: Vector3 = Vector3(0.03, 0.0, 0.06)
## Where on the lantern the left hand tugs, from the top of its handle in the lantern's axes
## (+Z is the side toward the Player's left and +X toward the back while it hangs straight).
## The default is the end of the wick's rod on the model, a pin just above the tank (found on
## the mesh: nothing else reaches 0.04 m from the middle line at that height).
@export var toggle_knob: Vector3 = Vector3(0.021, -0.242, 0.04)
## How far the pinch turns about the knob's rod (radians): one way to light the lantern, the
## other way to put it out. While it turns the thumb pushes on and the forefinger gives way
## by `toggle_knob_roll` radians a joint, as fingers do rolling a small knob between them.
## About 50 degrees: the wrist alone makes the turn (the forearm does not roll with it), and at
## 90 degrees the hand ended folded more than 100 degrees back on the forearm.
@export var toggle_knob_turn: float = 0.9
@export var toggle_knob_roll: float = 0.05
## The same for a left hand that stays in a shield's handle: it cannot turn at the wrist (the
## palm would go through the straps), so the three fingers alone roll the knob between them,
## by this much a joint (radians) -- Kirill chose this over rolling the whole forearm, which
## would roll the shield with it.
@export var toggle_knob_roll_strapped: float = 0.2
## For that hand's arm: the side its elbow goes to (the Player's axes), and whether the hand
## comes to the knob round the front of the body (toggle_left_around) or straight. The side is
## the best of 27 tried with and without the way round the front, by the least room between
## the shield and the body through the whole action, weapons down and up, either foot forward:
## none kept the shield out of the body in all four (this one: +4, -6, 0 and -2 cm; the side
## used without a shield: +1, -8, -5, -3). Standing right foot forward with the weapons down is
## the bad one whatever the side.
@export var toggle_strapped_elbow: Vector3 = Vector3(0.3, -0.2, -0.8)
@export var toggle_strapped_round_front: bool = true
## A right hand that holds a weapon LIFTS the lantern from UNDER it with the top of its fist,
## the weapon pointing ahead and a little down (Kirill, 2026-10-14: before this the fist sat
## above the lantern's middle and the sword landed on top of it). Where the fist's palm goes,
## from where the middle of the lantern's body is once it is swung forward, in the Player's
## axes (+X right, +Y up, -Z ahead): under it; the side the elbow goes to (the same axes; it
## must not be near the line from the shoulder to the fist, or the elbow flips over); and how
## far the forearm is rolled from how the stance has it (degrees), which turns the side of the
## fist that faces up. From `lantern_armed_search.gd -- --under`, ranked by room to the
## lantern first (Kirill: the first set put the lantern through the forearm and the hilt),
## then checked over the whole action: the sword 0-3 cm clear of the lantern, the forearm on
## its surface (0-1 cm), the sword 1-2 cm into the body's (generous) capsules. Higher and the
## sword touches the lantern. The wrist's bend lowers the palm a further 4-5 cm.
@export var toggle_armed_fist: Vector3 = Vector3(0.06, -0.08, 0.0)
## The same before the swing, from the middle of the lantern as it hangs: behind it and to its
## right, so that the fist is seen to push it forward and the blade passes beside it. And the
## place the fist's way to it bows out toward, from where the lantern's middle hangs: to the
## right and back, so it comes round behind.
@export var toggle_armed_fist_hanging: Vector3 = Vector3(0.12, -0.04, 0.06)
@export var toggle_armed_around: Vector3 = Vector3(0.25, 0.0, 0.15)
@export var toggle_armed_elbow: Vector3 = Vector3(1.0, -0.2, 0.3)
@export var toggle_armed_roll: float = 0.0
## Where the blade points while that fist carries the lantern, in the Player's axes (zero = as
## the forearm's roll leaves it). The hand is bent at the wrist toward it, at most
## TOGGLE_ARMED_WRIST_MAX. Without the bend the roll only spins the blade about the forearm:
## with the fist under the lantern it pointed 25-35 degrees up through it, or out to the right
## (lantern_under_trace.gd; Kirill, 2026-10-14: the sword landed on top of the lantern).
@export var toggle_armed_blade: Vector3 = Vector3(0.0, -0.4, -0.92)
## The same before the swing, while the lantern still hangs: out to the right, or a blade
## pointing ahead from a fist behind the hanging lantern runs straight through it.
@export var toggle_armed_blade_hanging: Vector3 = Vector3(0.6, -0.6, -0.5)
const TOGGLE_ARMED_WRIST_MAX := 1.05 ## radians (60 degrees)
## The left hand's way to the knob and back bows out toward this place, from the hips bone in
## the Player's axes (+X right, +Y up, -Z ahead): in front of the belly. Going straight, it
## passed through the body (Kirill, 2026-10-12). The hand gets about half-way out to it.
@export var toggle_left_around: Vector3 = Vector3(-0.08, 0.0, -0.55)
## The fingers, in radians at each of their three joints (0 = flat): how far they are closed
## while a hand is on its way, open; the right hand's round the lantern; and the left
## forefinger's and middle finger's on the knob (its other two fingers fold further).
@export var toggle_open_curl: float = 0.12
@export var toggle_cup_curl: float = 0.6
@export var toggle_pinch_curl: float = 1.0
## The pinch: how far the left thumb swings in toward the fingers (radians), and how far off
## the rod's end the three fingertips meet (m). With the fingers at 1.0, the thumb at half
## that and swung in 0.4, its tip is 1 cm from the forefinger's and 2 cm from the middle
## finger's (measured on the model); at the first settings (0.6, no swing) they were 7.6 cm apart.
@export var toggle_pinch_thumb_in: float = 0.4
@export var toggle_pinch_gap: float = 0.0
## m from a finger's last joint to the middle of its pad, where it touches what it holds. On the
## glove's mesh the last segment's middle is 1.3-1.9 cm from the joint; at 3 cm (the very tip)
## the pads stopped that much short of the knob.
const FINGERTIP := 0.016
const FINGERS: Array[String] = ["Thumb", "Index", "Middle", "Ring", "Little"]
const TOGGLE_WRIST_MAX := 0.8 ## radians a wrist may bend from the forearm's line (about 45 degrees)
## The parts of it, as shares of toggle_time [from, to]. The arms are solved to reach their
## points each frame (they are not keyframed), over whatever clip is playing, so the legs go
## on walking. Each hand's place, the way its palm faces and its fingers are set.
## They overlap on purpose: the hands set off as the view starts down, the left hand is on its
## way while the right is still swinging the lantern, and the view starts back up as the turn
## ends, while the hands are still letting go. Played one after another (look down, turn the
## knob, look up) it was three separate actions and 2.0 s long (Kirill, 2026-10-12).
const TOGGLE_VIEW_IN := [0.0, 0.2] ## the view and the body's bend
const TOGGLE_REACH := [0.0, 0.18] ## the right hand goes to the lantern
## A right arm with a weapon in its fist: it is behind the lantern before that swings forward
## and leaves it once it hangs again.
const TOGGLE_REACH_ARMED := [0.0, 0.3]
const TOGGLE_SWING_ARMED := [0.22, 0.38] ## the lantern's swing forward for it
const TOGGLE_RELEASE_ARMED := [0.68, 1.0]
const TOGGLE_SWING := [0.14, 0.32] ## and swings it forward
## The left hand comes to the knob, as fast as it later leaves (0.3 s each way). Setting off
## earlier, at 0.08, it took 0.45 s to arrive and pulled away visibly faster than it came.
const TOGGLE_LEFT_IN := [0.18, 0.38]
## The turn of the knob, the light coming up or going down with it: 0.4 s. At 0.2 s, with the
## light snapping over half-way, it read as flipping a switch; 0.55 s was a little slow.
const TOGGLE_TUG := [0.38, 0.64]
const TOGGLE_LEFT_OUT := [0.64, 0.84]
const TOGGLE_BACK := [0.64, 0.86] ## the lantern is let back to hang
const TOGGLE_RELEASE := [0.76, 1.0] ## the right hand returns to the clip
const TOGGLE_VIEW_OUT := [0.58, 1.0]
## Which way the right elbow points while its arm is solved, in the Player's axes: outward,
## down and a little back.
const TOGGLE_ELBOW := Vector3(0.6, -0.7, 0.4)
## The left arm reaches across the front of the body: its elbow goes forward and outward, so
## that the forearm comes at the knob from in front. With the elbow back, as above, the
## forearm lay through the belly and the wrist ended inside it.
const TOGGLE_LEFT_ELBOW := Vector3(-0.5, -0.5, -0.7)

## How shiny the body's cloth and leather are (the materials' "specular": 0.5 is Godot's
## default, 0 = no highlight at all). The lantern is a hand's width from the belt and the
## trousers, and at the default it drew white streaks along them (Kirill, 2026-10-12, looking
## down). Metal parts (buckles) take their shine from their colour and are not changed by this.
## Can be changed while the game runs.
@export_range(0.0, 1.0, 0.01) var body_specular: float = 0.2:
	set(value):
		body_specular = value
		_apply_body_specular()

## Playback speed is the Player's speed over the clip's, kept inside this range. The Player
## crouch-walks at 3 m/s and the crouch clip covers 0.8 m/s: its feet slide.
@export var min_playback_speed: float = 0.6
@export var max_playback_speed: float = 1.6
@export var blend_time: float = 0.2 ## seconds to cross-fade from one clip to the next
@export var dash_blend_time: float = 0.08 ## seconds to fade into a dash's hop (out of it: blend_time)
@export var still_speed: float = 0.3 ## m/s below which the Player counts as standing
## The slowest fall (m/s at touching down) that plays the landing clip, where the body sinks
## into a crouch and rises again. A jump on level ground lands at the Player's jump_velocity
## (4.5 m/s, from 1 m up): at 6 that passes without it, and a drop of 1.8 m or more plays
## it. It plays whatever keys are held: the Player stands still meanwhile (holds_player()).
@export var hard_landing_speed: float = 6.0
## The share of the landing clip for which the Player is held in place (1 = all of it). Below
## 1, movement is given back early and a held direction key cuts the clip's end short.
@export_range(0.0, 1.0) var hard_landing_hold: float = 1.0
## How far the body turns toward the way it sprints when that is diagonally forward (radians;
## 0.785 = 45 degrees, facing where it goes), and how quickly it turns there (per second).
@export var diagonal_turn: float = 0.785
@export var diagonal_turn_rate: float = 10.0

## The eyes' place against the head bone (which sits at the base of the skull), along the
## head's own axes: up the skull and out of the face.
@export var eye_up: float = 0.07
@export var eye_forward: float = 0.1
## The camera stays this close to the Player's axis however far a clip leans: the collision
## capsule's radius is 0.4 m, and a camera outside it sees through walls. Where a clip carries
## the eyes further forward (sprint: 0.5 m, crouch: 0.32 m) the whole model moves back instead.
@export var eye_max_forward: float = 0.3
## How much further forward the camera sits when the Player looks straight down (m), less at
## shallower angles. It keeps the open collar below the bottom of the picture.
@export var eye_look_down_forward: float = 0.15
## Seconds the camera takes to follow the head. Larger = steadier and further behind; it is
## what keeps each step's bob out of the view.
@export var eye_smoothing: float = 0.2
## The furthest the camera may trail the eyes (m), however fast the head moves.
@export var eye_max_lag: float = 0.03

## Standing right foot forward (the idle with its legs mirrored), how far the body from the
## spine up is turned back to the way it faces standing left foot forward: 1 = the same way
## (the chest 13 deg to the right, twisted 28 deg over the hips, which "looks kind of weird" --
## Kirill, 2026-10-13), 0 = it goes round with the mirrored hips (the chest 13 deg to the
## LEFT, the left shoulder 16 cm from where everything fitted to the left arm expects it).
## Read once, when the clip is built.
@export_range(0.0, 1.0, 0.01) var idle_mirror_torso: float = 0.5

## The model, turned half round in the scene: it faces +Z, the Player looks along -Z.
## The feet are put on the ground under them (_place_feet): a clip is made for level ground,
## and the Player's capsule only knows the ground under its middle, so on a slope the uphill
## foot went into the ground and the downhill one hung in the air.
@export var feet_on_ground: bool = true
## The feet follow the ground as it is DRAWN where the terrain's textures are displaced
## (TerrainDisplacement), not only the collision under it. The Player itself still stands on
## the collision: on a bump its legs fold, over a hollow they stretch.
@export var feet_on_drawn_ground: bool = true
@export var feet_max_up: float = 0.35 ## m a foot may be raised above where the clip has it
@export var feet_max_down: float = 0.45 ## m it may be lowered
## m/s at most that a foot follows a change of the ground's height under it. Up to that speed
## it follows at once: easing it instead left a foot swinging forward up a slope 13 cm behind
## the ground it landed on. The limit only softens a step or a stone's edge.
@export var feet_max_speed: float = 5.0
@export var feet_smoothing: float = 0.06 ## seconds a foot takes to follow a change of the ground's slope
@export var feet_blend_time: float = 0.15 ## seconds to fade it out on leaving the ground, and back in
@export var feet_max_tilt: float = 35.0 ## degrees a foot may be tilted to the ground's slope
## A foot is tilted to the slope fully while it is on the ground and not at all once the clip
## has lifted it this far (m).
@export var feet_tilt_lift: float = 0.12
## The share of its full length a leg may be stretched to before the hips come down for it,
## and the seconds the hips take to do so.
@export_range(0.8, 1.0, 0.005) var feet_leg_stretch: float = 0.985
@export var feet_hips_smoothing: float = 0.1
## The model's meshes that have any of the right arm: all the arm's copy draws.
const ARM_APART_MESHES: Array[String] = ["topA_geo", "gloves_geo", "elbowPads_geo", "shoulderPad_geo"]
const FEET_RAY_UP := 0.6 ## m above the Player's feet level from where the ground is looked for
const KNEE_FORWARD := 0.03 ## m: a nearly straight leg bends forward, whichever way the clip's hair of a bend goes

@onready var _model: Node3D = $Rogue
## Where the lantern's handle hangs: a marker under a BoneAttachment3D, placed in the editor.
@onready var _lantern_hook: Node3D = $HipsAttachment/LanternHook
@onready var _lantern: Node3D = $HipsAttachment/LanternHook/LanternModel
## The stance the right arm holds a weapon in, and how the weapon sits in the fist: set by hand
## in the editor (weapon_stance.gd). Without the node the weapon is in the fist as WeaponHold
## works it out and the arm is the clip's.
@onready var _stance: WeaponStance = get_node_or_null("WeaponStance")
## The same for the left arm and the shield on it (a WeaponStance with side Left, holds shield).
@onready var _shield_stance: WeaponStance = get_node_or_null("ShieldStance")
var _shield_node: Node3D ## the carried shield's model
var _shield_bone: int = -1 ## the bone it is carried on: the left lower arm (on_forearm) or the left hand
var _shield_socket: Transform3D ## where it sits IN COMBAT, in that bone's axes (the ShieldStance's Grip marker)
var _shield_now: Transform3D ## where it sits just now (the same as _shield_socket: the relaxed carry turns the ARM, not the shield on it)
var _shield_hand_in_stance: Quaternion = Quaternion.IDENTITY ## the left hand bone's own turn on the forearm with the arm in its stance
var _shield_up: float = 0.0 ## 0-1: how far the left arm is into its stance
var _shield_points: PackedVector3Array = [] ## points round the shield's model, in its own axes (shield_body_clearance)
var _shield_push: Vector3 = Vector3.ZERO ## how far the shield arm is moved off the body just now (the Player's axes)
var _relaxed_push: Vector3 = Vector3.ZERO ## the same for the relaxed carry, where the arm is swung out from the shoulder by it
var _weapon_push: Vector3 = Vector3.ZERO ## how far the weapon arm's stance is moved off the body just now (weapon_body_clearance)
var _weapon_push_wanted: Vector3 = Vector3.ZERO ## how far it would have to move this frame (before easing)
var _weapon_push_speed: Vector3 = Vector3.ZERO ## the push's own speed (its spring, weapon_clearance_smoothing)
var _weapon_low: Vector3 = Vector3.ZERO ## the box the weapon's model fills, in its own axes
var _weapon_high: Vector3 = Vector3.ZERO
var _shield_socket_set: bool = false ## _shield_socket has been worked out with the arm in its stance (not only from the model's data)
var _shield_shoulder_drawn: float = 0.0 ## m the left shoulder was drawn off the body after the fist this frame
var _bob_now: Vector3 = Vector3.ZERO ## the bob of the steps this frame (_weapon_bob): both arms move by it
var _breath_now: Vector3 = Vector3.ZERO ## the chest's breathing this frame, faded (_breathe); each arm moves by its share
var _chest_average: Vector3 = Vector3.ZERO ## the upper chest's place against the eyes, averaged over breathing_average
var _chest_average_valid: bool = false
var _fidget: StringName = &"" ## the fidget playing (FIDGETS), or none
var _fidget_at: float = 0.0 ## seconds into it
var _fidget_fade: float = 1.0 ## 1 while it plays; falls to 0 over fidget_cancel_time once cancelled
var _fidget_cancelled: bool = false
var _fidget_last: StringName = &""
var _fidget_still: float = 0.0 ## seconds stood still, weapons up, since the last fidget or input
var _fidget_wait: float = -1.0 ## seconds to stand still before the next one (picked at random)
var _fidget_driven: bool = false ## the animation debug panel (I) sets its time: it does not run, end or cancel by itself
var _fidget_turn: float = 0.0 ## radians the view is turned right by a fidget that has the view, just now
var _fidget_tilt: float = 0.0 ## radians the view is tilted (+ = left ear down) by such a fidget, just now
var _fidget_hang: Vector3 = Vector3.DOWN ## from the hook to the lantern's middle before lantern_look lifts it
var _lantern_spin: float = 0.0 ## radians the lantern is turned about its own long axis just now (lantern_look)
var _shield_tug: Vector3 = Vector3.ZERO ## how far the strap fidget's tug moves the shield just now (the Player's axes)
var _rim_target: Vector3 = Vector3.ZERO ## where the strap fidget's palm is aimed (the Player's space; for probes)
var _rim_pick := -1 ## the strap fidget's rim point (an index into _shield_rim), kept once the shield is up; -1 = not picked
var _forearm_held: Transform3D = Transform3D() ## the strap fidget's left forearm once the shield is up, against the eyes (the Player's axes, origin less _eye)
var _forearm_held_set := false
var _rim_local := Vector3.INF ## the strap fidget's rim point as it glides to the pick (the board's own axes; INF = none yet)
var _rim_local_speed := Vector3.ZERO ## ... and its speed (the spring's)
const RIM_GLIDE := 0.15 ## seconds: how slowly that point follows the pick
var _fidget_shield_push := Vector3.ZERO ## the strap fidget's own keep-off of the board (as _relaxed_push)
var _shield_forearm_axis := Vector3.ZERO ## the drawn shield's forearm line in the stance (the Player's axes), for the shield fidgets
var _glance_sign := 1.0 ## which way a roll about it turns the shield's face toward the eyes
var _elbow_restore := Vector3.INF ## the left lower arm's own place before the strap fidget moved it this frame (INF = not moved)
var _shield_rim: PackedVector3Array = [] ## the shield model's vertices on its outer edge, in its own axes (equip_shield)
var _shield_rim_middle: Vector3 = Vector3.ZERO ## the middle of its board, in its own axes
var _shield_face: Vector3 = Vector3.FORWARD ## the way its board's face looks (its thinnest side), in its own axes
var _shield_length: Vector3 = Vector3.UP ## the board's length (its longest side), in its own axes
var _weapon_node: Node3D ## the held weapon's model
var _weapon_socket: Transform3D ## the fist's middle in the right hand bone's axes (WeaponHold.socket)
var _weapon_fist: Array[float] = [] ## how far each finger closes round the held weapon
var _weapon_up: float = 0.0 ## 0-1: how far the right arm is into the stance (weapon_raised)
var _look_pitch: float = 0.0 ## the camera's pitch as last told (advance), radians, negative = down
var _weapon_on_back: bool = false ## the weapon lies on the back just now (weapon_sheath_on_back), not in the fist
var _chest_bone: int = -1
## The side the elbow goes to while the hand is at the back (the Player's axes): out to the
## right, up and BEHIND. It was forward at first, and from above the arm then looked like a
## hand put to the ear (Kirill, looking straight down).
const DRAW_ELBOW := Vector3(0.7, 0.35, 0.6)
const DRAW_REACH := 0.6 ## the furthest the fist is held from the shoulder on the way (m)
const DRAW_BLADE_OVER := Vector3(0.25, 0.45, 0.86) ## the way the blade points half-way through the swing: backward and up (the Player's axes, +Z behind)
var _shoulder_drawn: float = 0.0 ## m the right shoulder was drawn off the body after the fist this frame
const POSTURE_SPINE: Array[String] = ["Spine", "Chest", "UpperChest"]
const POSTURE_NECK: Array[String] = ["Neck", "neck_02"]
## Per side ("Right", "Left") a copy of the model that shows that arm alone (weapon_arm_drawn_apart):
## "model", "skeleton" (its Skeleton3D), "chain" (the upper arm and every bone under it, parents first).
var _apart: Dictionary = {}
## THE SHADOW while the arms are drawn apart comes from a third copy of the model that is
## never seen itself: the whole body with both arms ON it, reaching to where the stances hold
## the fists (the shoulders moved after them: the stretch that looked wrong on the body does
## not show in a shadow). Without it the body's shadow had no arms -- they are shrunk into its
## shoulders -- and the arms' own shadows lay apart from it (Kirill: "no arm shadows").
var _shadow_model: Node3D
var _shadow_skeleton: Skeleton3D
var _shadow_on: bool = false ## the copy casts the shadow just now, and the body and the arms' copies do not
var _own_casters: Array = [] ## [mesh, its shadow setting] for every mesh of the body itself
var _weapon_shadow: Node3D ## a copy of the held weapon's model that only casts a shadow, in the shadow body's hand
var _shield_shadow: Node3D ## the same for the shield
## The size everything but the arm is shrunk to in the arm's copy, and the arm on the body.
## Not 0: the arm's bones are sized back up from it, which nothing can be from nothing.
const ARM_APART_SHRINK := 0.001
var _ground_speed: float = 0.0 ## m/s over the ground as last told (set_motion); 0 in the air
var _weapon_bob_stride: float = 0.0 ## how far through a stride the weapon's bob is (0-1, goes round)
var _weapon_bob_amount: float = 0.0 ## 0-1.5: how much of the bob is in just now
var _reference: ArmClip ## the clip of weapon_reference_clip, once read (null: none)
var _reference_path: String = "" ## the file _reference was read from
var _reference_time: float = 0.0 ## seconds into it
var _arm_animations: AnimationPlayer ## plays ARM_CLIPS on the right arm alone
var _swing_next: int = 0 ## which of ARM_SWINGS the next attack() plays

@export_group("Weapon held")
## What the right hand holds at the start (none: empty hands). equip() changes it in play.
@export var weapon: WeaponData
## The right arm's pose comes from the sword pack's clips (ARM_CLIPS): its idle, and a swing on
## attack(). Off: the stance of the WeaponStance node (weapon_raised), and no swings.
@export var weapon_arm_from_clips: bool = false
## Seconds an arm clip fades into the next.
@export var weapon_arm_blend: float = 0.15
## The right arm holds the weapon up before the body, over whatever clip plays, in the stance
## of the WeaponStance node (set by hand in the editor: scripts/weapons/weapon_stance.gd).
## Off, or with no such node: the arm is the clip's, the weapon still in its fist. Off at the
## start: the game begins with the weapons sheathed (Kirill, 2026-10-14); Q raises them.
@export var weapon_raised: bool = false
@export var weapon_raise_time: float = 0.25 ## seconds to bring it up or let it down
## Whether the lantern is lit when the game begins (Kirill, 2026-10-14: off; L lights it).
@export var lantern_lit_at_start: bool = false
## LOWERED, THE WEAPON IS ON THE BACK, and raising it is a draw over the right shoulder: the
## hand goes up behind the shoulder to where the grip lies, takes it there -- behind the head,
## where the camera never looks, so the weapon changes from the back to the fist unseen and no
## scabbard is needed, whatever the weapon -- and swings it down through the picture into the
## stance. Lowering is the same backwards. (Kirill, 2026-10-13: a sheath at the hip would need
## a scabbard model fitted to every sword, and the lantern hangs there.) The hand's path was
## taken from Mixamo's "Sheath A Great Sword 1", measured, not played: up and forward to eye
## height, then back over the shoulder. Off: lowered, the weapon stays in the fist at the side.
@export var weapon_sheath_on_back: bool = true
@export var weapon_draw_time: float = 0.8 ## seconds a draw takes, and a sheathing
## The share of that time the hand takes from the body's side to the grip on the back (the
## rest is the swing down into the stance).
@export_range(0.1, 0.9, 0.01) var weapon_draw_grab: float = 0.4
## How far the view leans left while the weapon is drawn from the back or put back there
## (degrees: left ear down, and turned to the left), as a head does getting out of the way of
## the blade over the right shoulder. Most when the hand is at the grip. 0 = none.
@export var weapon_draw_head_tilt: float = 4.0
@export var weapon_draw_head_turn: float = 3.0
## A place the fist passes near on its way between the back and the stance, from the eyes
## (+X right, +Y up, -Z ahead): what makes the swing an arc through the picture.
@export var weapon_draw_via: Vector3 = Vector3(0.3, 0.05, -0.38)
## The place the fist passes near first, straight off the back: out to the right of the head
## and above the shoulder, from the eyes (it does not turn with the view: it is the body's).
## With the blade held pointing backward there (DRAW_BLADE_OVER) the weapon goes over the
## shoulder OUTSIDE the head: the first version turned the hand the shortest way from the
## back to the stance, which swept the blade through the head -- 1 cm from the eyes, measured
## (Kirill: "it looks like the sword is sheathed and drawn directly into the head").
@export var weapon_draw_out: Vector3 = Vector3(0.45, 0.15, 0.15)
## The two places the fist goes THROUGH on its way from the body's side up to the back, from
## the eyes (+X right, +Y up, +Z behind): first OUT TO THE RIGHT AND STILL LOW, a little
## forward, then up and behind on that side. Seen looking straight down, the hand then sweeps
## out to the right across the picture and leaves it at its lower right, which is where the
## arm with the drawn weapon comes in (Kirill drew it: the hand went straight to the picture's
## bottom, and the weapon came in half a metre to the right of where it had gone). A hand that
## rises toward the eyes' height runs to the picture's edge at once, which is why the first
## place is low; and a curve only drawn TOWARD these places (the first two versions) never
## got near them, which is why it goes through them now.
@export var weapon_draw_arc: Vector3 = Vector3(0.52, -0.55, 0.12)
@export var weapon_draw_arc_up: Vector3 = Vector3(0.62, -0.2, 0.45)
## The shares of the way up at which the fist is at the first and at the second of them.
@export var weapon_draw_arc_at: Vector2 = Vector2(0.45, 0.75)
## Where the grip lies on the back, from the right shoulder joint (m): toward the body's right
## (negative: toward the neck), up, and behind.
@export var weapon_back_offset: Vector3 = Vector3(-0.1, 0.06, 0.15)
## Degrees the blade leans from straight down toward the body's left.
@export var weapon_back_slant: float = 25.0
## Which of the blade's two edges faces the body's right on the back (the weapon turned over).
## On: the hand that takes it there bends 67 deg at the wrist at most; off, it is twisted right
## round (161 deg, measured).
@export var weapon_back_turned_over: bool = true
## What the LEFT arm carries (null: nothing): a WeaponData with on_forearm, a shield. It comes
## up and goes down with the weapon (weapon_raised: combat is both), into the stance set by
## hand in the ShieldStance node; lowered, it stays strapped to the arm as the clips move it.
@export var shield: WeaponData
## The share of a draw from the back (weapon_draw_time) that has passed before the shield
## starts to come up; it is fully up as the draw ends. (On its own quick weapon_raise_time it
## was in the picture well before the sword, whose hand is behind the head for the first part
## of the draw -- Kirill, 2026-10-13.) Sheathing, it is down by this share before the end.
@export_range(0.0, 0.9, 0.01) var shield_raise_from: float = 0.2
## WITH THE WEAPONS DOWN THE SHIELD IS CARRIED RELAXED: the FOREARM is rolled, over whatever
## the clip does with it, until the shield on it lies flat along the body, its face outward
## (Kirill, 2026-10-13: "rotate it so it's parallel to the body ... a relaxed sheath state,
## while the combat state is what we have now"). The shield keeps its one place on the arm
## (the ShieldStance's Grip marker), and the hand keeps the turn on the forearm and the
## fingers it has in the stance, so hand and straps fit as they do in combat: the first
## version turned the shield ON the arm instead, and its strap then crossed the palm wherever
## the clip had the hand (Kirill: "the palm clips with the handle in sheathed state"). Off:
## the arm as the clips have it, which laid the shield across the hip and through it.
@export var shield_relaxed_carry: bool = true
## In the relaxed carry the shield's face looks AWAY FROM THE BODY: level, along the line from
## the trunk's middle (hips to chest) out to the forearm. So it lies flat against whichever
## side of the body the clip has the arm on -- the left side standing, the front where a clip
## swings the arm across the belly (facing straight left it went edge-on into the belly
## there: 14 cm, measured, in the sideways jog). Where the forearm is right at the trunk's
## middle line, it faces this way (the Player's axes: -X is the body's left). The shield can
## only turn about the forearm, so it faces as near all this as that allows.
@export var shield_relaxed_faces: Vector3 = Vector3(-1.0, 0.0, 0.0)
## THE SHIELD KEEPS OFF THE BODY: turned down with the view (weapon_follows_view) its stance
## swings the board into the chest and the legs (Kirill: "the shield clipping through the body
## when looking down"). So wherever the board comes nearer than this (m) to the middle line
## of the trunk (hips to chest), or than half of it to a leg's (hip to knee to ankle), the whole
## shield arm is moved the way shield_clear_toward points until it is clear. 0: off.
@export var shield_body_clearance: float = 0.24
## The same for the legs (m from a leg's middle line). It was half of shield_body_clearance; with
## the scene's 0.12 that let the left thigh reach the board jogging back, looking down (Kirill,
## 2026-10-14; `tools/weapon_probes/shield_backward.gd`). Below 0: half of shield_body_clearance.
@export var shield_leg_clearance: float = 0.1
## The way it is moved (the Player's axes: -X left, -Z forward). To the LEFT, out past the
## body's side: moved FORWARD it cleared the body as well, but took the arm's cut end with it
## into the picture (measured: in view at 60 deg down).
@export var shield_clear_toward: Vector3 = Vector3(-1.0, 0.0, 0.0)
## Seconds the shield takes to move off the body, and to come back once it is clear. It comes
## back slowly on purpose: the legs swing at it with every step, and following each swing
## would rock the shield at the pace of the steps.
@export var shield_clearance_ease: float = 0.08
@export var shield_clearance_return: float = 1.0
## The arm in the stance is DRAWN APART FROM THE BODY, as first-person games do (Skyrim keeps a
## separate pair of arms): where the stance holds the hand, the body's own shoulder is up to
## half a metre away -- the arm is 0.37 m too short for it -- and moving the shoulder there
## stretched the body's cloth after it (Kirill: "the shoulder is very stretched"). So while
## the weapon is up, the body's own right arm is shrunk away into its shoulder, and a second
## copy of the model, everything but its right arm shrunk away into that arm's shoulder, shows
## the arm where the stance has it. Looking down, the arm is not joined to the body. Off: one
## body, its shoulder moved (the stretch). Kirill saw it first WITHOUT weapon_follows_view
## ("it's just floating in the air, the point is to have it on the body"): the arm stood still
## while the view went down, and its end came into the picture. On again with that setting,
## after two Skyrim mods that show a body in first person were read (Joy of Perspective keeps
## the arms on a second skeleton hung from the camera; IFPV hides the body's arms and shows
## the first-person ones, turned 0.8 of the view's pitch): neither joins the arms to the body.
## The left arm with the shield is drawn the same way.
@export var weapon_arm_drawn_apart: bool = true
## How much of the view's pitch the arms' stances take (0 = they stay as they are while the
## Player looks up and down, 1 = they keep their place in the picture whatever the pitch):
## both stances, with what they hold, are turned about the eyes by this share of the pitch.
## It is what keeps the drawn-apart arms' ends below the picture's edge. Kirill liked 0 with
## the arm on the body ("I think I like it the way we do now").
@export_range(0.0, 1.0, 0.01) var weapon_follows_view: float = 0.8
## THE SHADOW'S ARMS ARE ITS OWN: on the shadow's body they set off from the shoulders and
## reach TOWARD where the picture has the fists, but only this far (m; the arm is 0.56 long),
## and the shadow's weapon and shield are in those hands. (Reaching all the way to the fists,
## which the stances hold half a metre out to either side, the shadow stood with its arms
## spread like the rest pose -- Kirill: "the weapons drawn shadow look like a tpose".) The
## weapon and shield in the picture cast no shadow of their own meanwhile.
@export_range(0.2, 0.56, 0.01) var weapon_shadow_reach: float = 0.4
## How far the shadow's elbows are turned from where the picture's arms have them toward
## hanging down beside the body (0 = as in the picture, 1 = straight down).
@export_range(0.0, 1.0, 0.01) var weapon_shadow_elbows_down: float = 0.7
## THE ARM GOES BACK ONTO THE BODY AS THE PLAYER LOOKS DOWN. The stance's shoulder is beside
## and below the camera, so looking ahead neither it nor the cloth stretched after it is in
## the picture; they come into it about 45-50 deg down. Between these two angles (degrees
## below level) the shoulder slides back to the body's own, and the fist comes in with it to
## where the real arm reaches: from..by. Looking further down than `by` the arm is the body's
## own, holding the weapon nearer. The weapon moves in the picture while it slides, and it IS
## in the picture then (the fist only leaves it about 75 deg down): the slide was first set to
## 25..50, inside the angles of ordinary play, and every small move of the view shifted the
## sword (Kirill: "the sword visibly shifts back and forth"). Keep `from` near where the
## shoulder comes into view, which at the camera's 75 deg is about 50.
@export var weapon_on_body_slide: bool = false ## off since weapon_body_toward_weapon (Kirill: "can we not move the sword at all?")
@export var weapon_on_body_from: float = 45.0
@export var weapon_on_body_by: float = 65.0
## THE BODY GOES TO THE WEAPON, not the weapon to the body: the fist stays at its place in the
## stance at every angle of the view, and while the weapon is up the upper body is posed so
## that its own right shoulder comes near enough to hold it there -- upright instead of the
## clip's forward lean (the idle carries the head 0.18 m further ahead of the shoulders than
## the rest pose), the chest turned to bring the sword's side forward, the collar bone pushed
## forward. The head keeps the turn the clip gives it. Off: the body as the clips have it.
## OFF FOR NOW (Kirill, 2026-10-13, with the shield in: "temporarily undo the forward body
## turn we did for the sword"): it turns the shield's shoulder back by as much as the sword's
## forward. weapon_shoulder_on_body went off with it, so both arms set off from their stances'
## Shoulder markers again, which is also what the editor shows.
@export var weapon_body_toward_weapon: bool = false
## 0-1: how far the spine and neck are straightened from the clip's pose to the rest pose's.
@export_range(0.0, 1.0, 0.01) var weapon_body_upright: float = 1.0
## Degrees the chest faces to the LEFT of where the Player looks (which brings the right
## shoulder forward), whatever the clip does with it; the turn is shared by the three spine bones.
@export var weapon_chest_turn: float = 40.0
## Degrees the right collar bone is swung forward.
@export var weapon_collar_forward: float = 25.0
## The arm sets off from the body's OWN shoulder, not from the stance's Shoulder marker; only
## where the fist is still out of reach (the stance's max_reach) is the shoulder drawn after
## it, by what is missing. Off: the shoulder is put at the marker (the stretch of 0.5 m).
@export var weapon_shoulder_on_body: bool = false
## How far from the body's own shoulder the fist may be held before the shoulder is drawn
## after it (m). The fist is about 0.08 m beyond the wrist, so the arm (0.56 m) is straight at
## about 0.64; at the stance's own 0.54 the elbow stayed bent 55 deg with the shoulder 0.15 m
## off the body.
@export_range(0.3, 0.64, 0.005) var weapon_body_reach: float = 0.58
## With the arm on the body, the fist is held at most this far from the body's own shoulder
## (m; the arm is 0.56 long), on the line toward its place in the stance.
@export_range(0.2, 0.56, 0.005) var weapon_on_body_reach: float = 0.46
## The held weapon bobs with the steps: the whole stance (shoulder and fist together) moves
## from the eyes by this much up and down (m, twice a stride) and side to side (m, once a
## stride), at the pace of the clip that plays. (The stance is set from the eyes, so without
## this the weapon stands still in the picture however the body moves. For scale: the grip of
## the Skyrim mod measured in docs/weapons.md moves about 0.05 m each way in its run.)
@export var weapon_bob_height: float = 0.015
@export var weapon_bob_side: float = 0.012
## The speed over the ground (m/s) at which the bob is as large as set; slower, it is smaller
## in proportion, and faster it grows to at most one and a half times.
@export var weapon_bob_full_speed: float = 3.0
## Seconds the bob takes to come in when setting off and to die away when stopping.
@export var weapon_bob_ease: float = 0.2
## Standing still the held weapons rise and fall with the chest's breathing (Kirill,
## 2026-10-14: the chest breathed while the weapons stood still in the picture). The share of
## the upper chest's movement against the eyes that each stance (shoulder and fist together)
## follows: 0 = still in the picture, 1 = as much as the chest. It is the clip's own breathing,
## so another idle brings its own pace; it fades out as the step bob comes in.
@export_range(0.0, 1.5, 0.05) var weapon_breathing: float = 0.8
@export_range(0.0, 1.5, 0.05) var shield_breathing: float = 0.6
## Seconds over which the chest's place is averaged: what the breathing is measured from. Slow
## changes (crouching, the clip changing) go into the average and do not move the weapons.
@export var breathing_average: float = 3.0
## At most this far (m) the breathing moves a stance.
@export var breathing_limit: float = 0.03
## FIDGETS (Kirill, 2026-10-14): standing still with the weapons up, now and then the sword arm
## does something on its own -- looks the blade over, rolls the wrist (FIDGETS). Any key or
## mouse button (interrupt_fidget, from the Player) or moving off cancels it, and the arm goes
## back to the stance in fidget_cancel_time. Looking around does not cancel it.
@export var fidgets_on: bool = true
## Seconds of standing still before one plays, plus up to fidget_after_random more at random.
@export var fidget_after: float = 10.0
@export var fidget_after_random: float = 6.0
@export var fidget_cancel_time: float = 0.2
## THE WEAPON KEEPS OFF THE BODY, as the shield does (shield_body_clearance): wherever the box
## its model fills comes nearer than this (m) to the trunk's middle line (hips to chest), or
## than weapon_leg_clearance to a leg's, the whole weapon arm (shoulder and fist) is moved
## FORWARD, level with the ground, until it is clear; eased in with shield_clearance_ease and
## back with shield_clearance_return. Any weapon: it reads the model's box. Looking straight
## down in the inspect fidget the sword was 17 cm into the body (Kirill, 2026-10-14). 0: off.
@export var weapon_body_clearance: float = 0.18
@export var weapon_leg_clearance: float = 0.1
## Seconds the weapon's keep-off takes to follow (a damped spring, the same both ways). It
## followed at the shield's rates at first -- 0.08 s out, switching rates frame to frame -- and
## looked choppy looking down (Kirill).
@export var weapon_clearance_smoothing: float = 0.15
## TRIAL 2026-10-13. The arm follows a first-person clip converted from another game's arms
## (ArmClip: shoulder, elbow, wrist, the hand's turn and the weapon's place in it, per frame,
## from the eyes) in place of the WeaponStance node's markers. Off, or with no such file: the
## markers, as before. The fingers are the stance's either way.
@export var weapon_arm_from_reference: bool = false
@export_file("*.json") var weapon_reference_clip: String = "res://assets/animations/first_person/sword_neutral_idle.json"
@export_group("")
var _skeleton: Skeleton3D
var _animations: AnimationPlayer
var _head_bone: int = -1
var _hook_bone: int = -1 ## the bone the lantern's hook is attached to
var _hook_offset: Vector3 ## the hook's place in that bone's axes
var _lantern_light: Light3D
var _body_light: OmniLight3D ## the lantern's light for the body alone (lantern_light_on_body)
var _near_minus: OmniLight3D ## see body_shadow_reach
var _near_plus: OmniLight3D
var _lantern_pool: Node3D ## the light's child spot over the Player's head: stays where it was
var _lantern_pool_rest: Vector3
var _lantern_frame_material: BaseMaterial3D
var _lantern_obstacle_bones: Array = [] ## per obstacle: [bone index, bone index, radius]
var _lantern_outward: Vector3 ## away from the body on the hook's side, in the Player's space
var _bob: Vector3 ## the middle of the lantern's body, in the Player's space
var _bob_before: Vector3 ## where it was one step earlier (its speed is the difference)
var _bob_valid: bool = false
var _player_position_before: Vector3
var _player_velocity_before: Vector3
var _eye: Vector3
var _eye_valid: bool = false
var _clip: StringName = &""
var _dash_left: float = 0.0 ## seconds of a dash's hop still to play (start_dash)
var _idle_mirrored: bool = false ## standing with the right foot forward (the idle's mirror image)
var _arms: Dictionary = {} ## "Left" / "Right" -> that arm's bones and hand points (_setup_arms)
var _toggle_at: float = -1.0 ## seconds into turning the lantern on / off, below 0 = not doing it
var _toggle_lighting: bool = false ## the turn under way lights the lantern (false: puts it out)
var _toggle_dips: bool = true
var _view_dip: float = 0.0
var _toggle_hang: Vector3 = Vector3.DOWN ## from the hook to the lantern's middle before the hand swings it
var _pinch_grip: Basis ## the left hand's turn on the knob before it turns it, in the lantern's axes
var _pinch_grip_valid: bool = false
var _toggle_roll_wanted: float = 0.0 ## the roll it is easing toward
var _toggle_shield_roll: float = 0.0 ## radians the left forearm is rolled just now to keep its shield off the body while the hand is at the lantern
const TOGGLE_TRUNK := 0.17 ## how thick the body is taken to be round its middle line for that (m)
const TOGGLE_LEG := 0.1
var _toggle_view: float = 0.0 ## 0-1: how far the view and the body's bend are into their look at the lantern
var _sprinting: bool = false
var _turn: float = 0.0 ## the body's turn away from the Player's facing (radians, + = to the left)
var _turn_wanted: float = 0.0
var _clip_speed: float = 1.0
var _was_on_floor: bool = true
var _landing_left: float = 0.0
var _landing_length: float = 0.0 ## the landing clip's length, set when one starts
var _fall_speed: float = 0.0 ## m/s downward on the last frame in the air
var _hips_bone: int = -1
var _legs: Array[Dictionary] = [] ## per leg: its bones, and how far its foot is moved just now (_setup_legs)
var _feet_weight: float = 0.0 ## 0-1: how far the feet are placed (0 in the air)
var _hips_drop: float = 0.0 ## how far the hips are lowered for the feet just now (the skeleton's units)

func _ready() -> void:
	_skeleton = _model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_head_bone = _skeleton.find_bone("Head")
	for mesh_name in HIDDEN_FROM_CAMERA:
		var mesh := _model.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh:
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	for mesh_name in NOT_WORN:
		var mesh := _model.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh:
			mesh.visible = false

	_apply_body_specular()
	_setup_arms()
	_setup_legs()

	# The hook's place is read once; from then on the lantern is placed by this script, in
	# the same frame as the pose (the attachment node itself follows the bone a frame late).
	var attachment := _lantern_hook.get_parent() as BoneAttachment3D
	_hook_bone = _skeleton.find_bone(attachment.bone_name)
	_hook_offset = _lantern_hook.position
	_lantern.top_level = true
	for mesh: MeshInstance3D in _lantern.find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lantern_casts_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mesh.name == "lantern_frame":
			_lantern_frame_material = mesh.mesh.surface_get_material(0) as BaseMaterial3D
	# In the bone's axes +X is the body's left; in the Player's (the model is turned half
	# round) the body's left is -X.
	var side := "Left" if _hook_offset.x >= 0.0 else "Right"
	_lantern_outward = Vector3.LEFT if _hook_offset.x >= 0.0 else Vector3.RIGHT
	for obstacle in LANTERN_OBSTACLES:
		_lantern_obstacle_bones.append([_skeleton.find_bone((obstacle[0] as String).replace("%s", side)), _skeleton.find_bone((obstacle[1] as String).replace("%s", side)), obstacle[2]])
	_lantern_light = get_node_or_null(lantern_light_path) as Light3D
	if _lantern_light:
		_lantern_light.visible = lantern_lit_at_start
	equip(weapon)
	equip_shield(shield)
	_setup_arm_apart()
	if _lantern_light:
		var body_bit := 1 << (BODY_LAYER - 1)
		for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false) + _lantern.find_children("*", "MeshInstance3D", true, false) + (_apart["Right"]["model"] as Node3D).find_children("*", "MeshInstance3D", true, false) + (_apart["Left"]["model"] as Node3D).find_children("*", "MeshInstance3D", true, false) + _shadow_model.find_children("*", "MeshInstance3D", true, false):
			mesh.layers = body_bit
		# The lantern's own light neither lights the body nor is shadowed by it. (Which meshes
		# a light shadows is its shadow_caster_mask alone, whatever it lights.)
		var world_only := _lantern_light.light_cull_mask & ~body_bit
		_lantern_light.light_cull_mask = world_only
		_lantern_light.shadow_caster_mask &= ~body_bit
		# Children of the lantern's light: they move, and go out (L), with it.
		_body_light = _lantern_companion("OnBody")
		_body_light.light_cull_mask = body_bit
		_body_light.shadow_enabled = false
		_near_minus = _lantern_companion("NearMinus")
		_near_minus.light_negative = true
		_near_minus.light_cull_mask = world_only
		_near_minus.shadow_caster_mask = _lantern_light.shadow_caster_mask
		_near_plus = _lantern_companion("NearWithBodyShadow")
		_near_plus.light_cull_mask = world_only
		_near_plus.shadow_caster_mask = _lantern_light.shadow_caster_mask | body_bit
		_lantern_pool = _lantern_light.get_node_or_null("GroundPool") as Node3D
		if _lantern_pool:
			_lantern_pool_rest = _lantern_light.position + _lantern_pool.position

	var library := AnimationLibrary.new()
	var sources := {} # file -> the AnimationPlayer of its instantiated scene
	for clip: StringName in CLIPS:
		var file: String = CLIPS[clip][0]
		if not sources.has(file):
			var scene := (load(CLIP_DIR + file) as PackedScene).instantiate()
			sources[file] = scene.find_children("*", "AnimationPlayer", true, false)[0]
		var source: AnimationPlayer = sources[file]
		var in_file: String = CLIPS[clip][1]
		var animation := source.get_animation(in_file if in_file != "" else String(source.get_animation_list()[0]))
		animation.loop_mode = Animation.LOOP_LINEAR if CLIPS[clip][2] else Animation.LOOP_NONE
		_add_missing_tracks(animation)
		if CLIPS[clip][2]:
			_take_out_travel(animation)
		elif DASH_PARTS.has(clip):
			_hold_in_place(animation)
		library.add_animation(clip, animation)
	for source: AnimationPlayer in sources.values():
		source.owner.free()
	# The idle stands with the left foot forward; its mirror image is for stopping with the
	# right foot forward (set_motion).
	library.add_animation(&"idle_mirror", _mirrored(library.get_animation(&"idle"), true))
	_animations = AnimationPlayer.new()
	_model.add_child(_animations) # its tracks ("%GeneralSkeleton:<bone>") start at the model's root
	_animations.add_animation_library(&"", library)
	_animations.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL # see advance()
	_play(&"idle", 1.0)
	# The sword arm's own player, run after the body's in advance(): its clips have tracks for
	# the right arm only, so it replaces just that arm in the pose the body's clip gave.
	var arm_library := AnimationLibrary.new()
	for clip: StringName in ARM_CLIPS:
		var scene := (load(CLIP_DIR + (ARM_CLIPS[clip][0] as String)) as PackedScene).instantiate()
		var source := scene.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
		var animation := source.get_animation(source.get_animation_list()[0]).duplicate() as Animation
		for track in range(animation.get_track_count() - 1, -1, -1):
			if animation.track_get_type(track) != Animation.TYPE_ROTATION_3D or not ARM_BONES.has(String(animation.track_get_path(track).get_subname(0))):
				animation.remove_track(track)
		animation.loop_mode = Animation.LOOP_LINEAR if ARM_CLIPS[clip][1] else Animation.LOOP_NONE
		arm_library.add_animation(clip, animation)
		scene.free()
	_arm_animations = AnimationPlayer.new()
	_model.add_child(_arm_animations)
	_arm_animations.add_animation_library(&"", arm_library)
	_arm_animations.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL

## body_specular onto every material of the model (they are shared by its meshes; the files
## are not written).
func _apply_body_specular() -> void:
	if _model == null:
		return
	for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.mesh.surface_get_material(surface) as BaseMaterial3D
			if material:
				material.metallic_specular = body_specular

## Makes a looping clip stay in place: if its hips end somewhere else than they start, that
## travel is taken out evenly over the clip's length (sideways and forward, not the height).
## One of the Mixamo jogs was downloaded without "In Place" and walks 1.5 m off.
func _take_out_travel(animation: Animation) -> void:
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_POSITION_3D or String(animation.track_get_path(track).get_concatenated_subnames()) != "Hips":
			continue
		var keys := animation.track_get_key_count(track)
		if keys < 2:
			return
		var travel: Vector3 = animation.track_get_key_value(track, keys - 1) - animation.track_get_key_value(track, 0)
		travel.y = 0.0
		if travel.length() < 0.02:
			return
		var first := animation.track_get_key_time(track, 0)
		var span := maxf(animation.track_get_key_time(track, keys - 1) - first, 0.001)
		for key in keys:
			var value: Vector3 = animation.track_get_key_value(track, key)
			animation.track_set_key_value(track, key, value - travel * ((animation.track_get_key_time(track, key) - first) / span))
		return

## Takes a clip's travel out altogether: its hips keep the place they start at, sideways and
## forward (not the height). For the dash's hops, which cover 2 m: the Player does the moving.
func _hold_in_place(animation: Animation) -> void:
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_POSITION_3D or String(animation.track_get_path(track).get_concatenated_subnames()) != "Hips":
			continue
		var first: Vector3 = animation.track_get_key_value(track, 0)
		for key in animation.track_get_key_count(track):
			var value: Vector3 = animation.track_get_key_value(track, key)
			animation.track_set_key_value(track, key, Vector3(first.x, value.y, first.z))
		return

## A clip's mirror image, left and right changed over. On the humanoid skeleton the two sides'
## rest poses mirror each other across the plane x = 0, so a bone's turn goes to the bone of
## the other side with its y and z parts negated, and a position with its x negated.
func _mirrored(animation: Animation, legs_only: bool = false) -> Animation:
	var mirror := animation.duplicate(true) as Animation
	# `legs_only`: THE BODY FROM THE SPINE UP STAYS AS THE CLIP HAS IT, turned the same way in
	# the world; only the hips and the legs are mirrored. (The idle's whole mirror image had
	# the chest facing 26 deg the other way and the left shoulder 12 cm further in and 10 cm
	# further back: standing right foot forward, the left arm could not get round the chest
	# to the lantern, and everything fitted to the left-foot stance sat differently -- Kirill,
	# 2026-10-13: "can we turn the torso into same position as left leg then?")
	var above := {} # the spine and every bone under it, by name
	var spine := _skeleton.find_bone("Spine")
	if legs_only and spine >= 0:
		var todo: Array[int] = [spine]
		while not todo.is_empty():
			var bone: int = todo.pop_back()
			above[_skeleton.get_bone_name(bone)] = true
			todo.append_array(_skeleton.get_bone_children(bone))
	var turn_track := {} # bone name -> its rotation track in the clip as it is
	for track in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			turn_track[String(animation.track_get_path(track).get_concatenated_subnames())] = track
	for track in mirror.get_track_count():
		var path := mirror.track_get_path(track)
		var bone := String(path.get_concatenated_subnames())
		if above.has(bone):
			if bone == "Spine" and mirror.track_get_type(track) == Animation.TYPE_ROTATION_3D:
				# The spine's own turn is what carries the rest: on the mirrored hips it is
				# set so that the spine is turned in the skeleton's space as on the hips
				# unmirrored.
				for key in mirror.track_get_key_count(track):
					var carried := Quaternion.IDENTITY # the bones under the spine's, root first
					var chain: Array[int] = []
					var parent := _skeleton.get_bone_parent(spine)
					while parent >= 0:
						chain.push_front(parent)
						parent = _skeleton.get_bone_parent(parent)
					for link in chain:
						var link_name := _skeleton.get_bone_name(link)
						carried = carried * ((animation.rotation_track_interpolate(turn_track[link_name], mirror.track_get_key_time(track, key)) as Quaternion) if turn_track.has(link_name) else _skeleton.get_bone_rest(link).basis.get_rotation_quaternion())
					var carried_mirrored := Quaternion(carried.x, -carried.y, -carried.z, carried.w)
					# idle_mirror_torso of the way there, from the spine carried round by the
					# mirrored hips as it is.
					var own: Quaternion = mirror.track_get_key_value(track, key)
					mirror.track_set_key_value(track, key, own.slerp((carried_mirrored.inverse() * carried * own).normalized(), idle_mirror_torso))
			continue
		if bone.begins_with("Left"):
			bone = "Right" + bone.substr(4)
		elif bone.begins_with("Right"):
			bone = "Left" + bone.substr(5)
		mirror.track_set_path(track, NodePath("%s:%s" % [String(path.get_concatenated_names()), bone]))
		var type := mirror.track_get_type(track)
		for key in mirror.track_get_key_count(track):
			if type == Animation.TYPE_ROTATION_3D:
				var turn: Quaternion = mirror.track_get_key_value(track, key)
				mirror.track_set_key_value(track, key, Quaternion(turn.x, -turn.y, -turn.z, turn.w))
			elif type == Animation.TYPE_POSITION_3D:
				var place: Vector3 = mirror.track_get_key_value(track, key)
				mirror.track_set_key_value(track, key, Vector3(-place.x, place.y, place.z))
	return mirror

## True while the right foot is further forward than the left (the skeleton's +Z is its front).
func _right_foot_ahead() -> bool:
	if _legs.size() < 2:
		return false
	return _skeleton.get_bone_global_pose(_legs[1]["foot"]).origin.z > _skeleton.get_bone_global_pose(_legs[0]["foot"]).origin.z

## A bone a clip has no track for keeps the pose of the clip played before. One pack has two
## spine bones and the other three, so each such bone of the humanoid set gets a track holding
## its rest pose.
func _add_missing_tracks(animation: Animation) -> void:
	var tracked := {}
	var skeleton_path := ""
	for track in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			var path := animation.track_get_path(track)
			tracked[String(path.get_concatenated_subnames())] = true
			skeleton_path = String(path.get_concatenated_names())
	var profile := SkeletonProfileHumanoid.new()
	for i in profile.bone_size:
		var bone_name := String(profile.get_bone_name(i))
		var bone := _skeleton.find_bone(bone_name)
		if bone < 0 or tracked.has(bone_name):
			continue
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("%s:%s" % [skeleton_path, bone_name]))
		animation.rotation_track_insert_key(track, 0.0, _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion())

## The Player starts a dash: its hop is played over `duration` seconds, whatever set_motion()
## hears meanwhile. local_direction: in the Player's axes (-Z forward, +X right), one of the
## four ways.
func start_dash(local_direction: Vector3, duration: float) -> void:
	var clip := &"dash_fwd"
	if absf(local_direction.x) > absf(local_direction.z):
		clip = &"dash_right" if local_direction.x > 0.0 else &"dash_left"
	elif local_direction.z > 0.0:
		clip = &"dash_bwd"
	var part: Array = DASH_PARTS[clip]
	_dash_left = duration
	_turn_wanted = 0.0
	_clip = clip
	_clip_speed = (float(part[1]) - float(part[0])) / maxf(duration, 0.01)
	_animations.play(clip, dash_blend_time, _clip_speed)
	_animations.seek(float(part[0]))

## True while a hard landing holds the Player in place: it ignores the movement keys, the jump
## and the dash until the body has risen again (hard_landing_hold of the clip).
func holds_player() -> bool:
	return _landing_left > _landing_length * (1.0 - hard_landing_hold)

## local_velocity: the Player's velocity in its own axes (-Z forward, +X right).
func set_motion(local_velocity: Vector3, on_floor: bool, crouching: bool, sprinting: bool, delta: float) -> void:
	_ground_speed = Vector2(local_velocity.x, local_velocity.z).length() if on_floor else 0.0
	if _dash_left > 0.0:
		# A dash's hop plays through; only the fall's speed is still followed.
		_dash_left -= delta
		_was_on_floor = on_floor
		_fall_speed = maxf(-local_velocity.y, 0.0) if not on_floor else 0.0
		_landing_left = 0.0
		return
	var flat := Vector2(local_velocity.x, local_velocity.z)
	var speed := flat.length()
	var direction := _direction(flat)
	_turn_wanted = 0.0
	_sprinting = sprinting and speed > still_speed
	# The landing clip (the body sinks into a crouch and rises) only after a fall harder
	# than an ordinary jump's: the speed it was falling at just before it touched down.
	if not on_floor:
		_fall_speed = maxf(-local_velocity.y, 0.0)
	elif not _was_on_floor:
		if _fall_speed >= hard_landing_speed:
			_landing_length = _animations.get_animation(&"jump_land").length
			_landing_left = _landing_length
		_fall_speed = 0.0
	_was_on_floor = on_floor
	_landing_left = maxf(_landing_left - delta, 0.0)

	if not on_floor:
		_landing_left = 0.0
		_play(&"jump_air", 1.0)
	elif _landing_left > 0.0 and (speed < 1.0 or holds_player()):
		# On the frame it touches down the Player still has the speed it fell with.
		_play(&"jump_land", 1.0)
	elif crouching:
		if speed <= still_speed:
			_play(&"crouch_idle", 1.0)
		else:
			# One clip for every direction; moving backward plays it in reverse.
			_play(&"crouch_fwd", _playback_speed(speed, &"crouch_fwd") * (-1.0 if direction.begins_with("bwd") else 1.0))
	elif speed <= still_speed:
		# Coming to a stand, the foot that is forward stays forward: the idle has the left one
		# there, its mirror image the right. (Always the left: stopping on the right foot, the
		# legs changed places.)
		if _clip != &"idle" and _clip != &"idle_mirror":
			_idle_mirrored = _right_foot_ahead()
		_play(&"idle_mirror" if _idle_mirrored else &"idle", 1.0)
	elif sprinting and direction.begins_with("fwd"):
		# There is one sprint clip, straight ahead: sprinting diagonally forward is that clip
		# with the whole body turned the way it goes.
		if direction != "fwd":
			_turn_wanted = diagonal_turn * (1.0 if direction == "fwd_left" else -1.0)
		_play(&"sprint", _playback_speed(speed, &"sprint"))
	else:
		var clip := StringName("jog_" + direction)
		_play(clip, _playback_speed(speed, clip))

## Starts turning the lantern on or off; ignored while one is under way, while in the air, and
## while a weapon is on its way up or down. WITH THE WEAPONS UP OR DOWN ALIKE (Kirill,
## 2026-10-13; for an afternoon it was refused in combat): the left hand does it without
## leaving the shield's handle, and a right hand that holds a weapon steadies the lantern with
## its fist. See _place_lantern.
func toggle_lantern() -> void:
	# Not in the air (a jump, a fall): the press is dropped, nothing happens.
	if _toggle_at >= 0.0 or _lantern_light == null or not _was_on_floor or (_weapon_node != null and _weapon_up > 0.0 and _weapon_up < 1.0):
		return
	_toggle_at = 0.0
	_toggle_shield_roll = 0.0
	_toggle_roll_wanted = 0.0
	_toggle_lighting = not _lantern_light.visible
	_pinch_grip_valid = false
	_toggle_dips = not _sprinting

## True while the lantern is being turned on or off (the hands are at it).
func turning_lantern() -> bool:
	return _toggle_at >= 0.0

## True while a weapon is held up, or still on its way up or down.
func in_combat() -> bool:
	return _weapon_node != null and (weapon_raised or _weapon_up > 0.0)

## True while an action is moving the camera (turning the lantern on / off, unless it was
## started sprinting, when the view is left alone): the Player ignores the mouse meanwhile.
func has_the_view() -> bool:
	return _toggle_at >= 0.0 and _toggle_dips

## What to add to the camera's rotation just now (radians; x = pitch, 0 or below; y = turn,
## negative = to the right; z = tilt, negative = right ear down): the look of toggle_lantern(),
## and the head leaning left out of the way of a weapon drawn from the back or put back there
## (weapon_draw_head_*). The second is added to the mouse's look, which stays the Player's.
func view_offset() -> Vector3:
	var lean := 0.0
	if weapon_sheath_on_back and _weapon_node != null and _stance != null and _weapon_up > 0.0 and _weapon_up < 1.0:
		# Most at the moment the hand grips the weapon on the back.
		lean = smoothstep(0.0, weapon_draw_grab, _weapon_up) * (1.0 - smoothstep(weapon_draw_grab, 1.0, _weapon_up))
	return Vector3(_view_dip, -deg_to_rad(toggle_turn_degrees) * _toggle_view - _fidget_turn + deg_to_rad(weapon_draw_head_turn) * lean,-deg_to_rad(toggle_roll_degrees) * _toggle_view + deg_to_rad(weapon_draw_head_tilt) * lean + _fidget_tilt)

## One frame of turning the lantern on / off: the light, the view, the body's bend.
func _advance_toggle(delta: float, camera_pitch: float) -> void:
	_view_dip = 0.0
	_toggle_view = 0.0
	if _toggle_at < 0.0:
		return
	_toggle_at += delta
	# The light comes up, or goes down, with the turn of the knob, as a wick's flame does:
	# its level (lantern_flicker.gd) follows how far the turn is. It is switched on as the
	# turn starts and off only once it has ended.
	var turned := _part(_toggle_at / maxf(toggle_time, 0.01), TOGGLE_TUG)
	if _toggle_lighting and turned > 0.0:
		_lantern_light.visible = true
	_lantern_light.set(&"level", turned if _toggle_lighting else 1.0 - turned)
	if _toggle_at >= toggle_time:
		_toggle_at = -1.0
		if not _toggle_lighting:
			_lantern_light.visible = false
		_lantern_light.set(&"level", 1.0)
		return
	if _toggle_dips:
		var through := _toggle_at / maxf(toggle_time, 0.01)
		_toggle_view = _part(through, TOGGLE_VIEW_IN) * (1.0 - _part(through, TOGGLE_VIEW_OUT))
		_view_dip = minf(-deg_to_rad(toggle_dip_degrees) - camera_pitch, 0.0) * _toggle_view
		# The spine and the chest each take half of the bend, about the skeleton's own axes:
		# +Z is where the model faces and +X its left, so a turn about +Z leans it to its
		# right and a turn about -Y turns it to its right.
		var bend := Basis(Vector3.UP, -deg_to_rad(toggle_bend_turn) * 0.5 * _toggle_view) * Basis(Vector3.BACK, deg_to_rad(toggle_bend_side) * 0.5 * _toggle_view)
		for bone_name: String in ["Spine", "Chest"]:
			var bone := _skeleton.find_bone(bone_name)
			var pose := _skeleton.get_bone_global_pose(bone)
			pose.basis = bend * pose.basis
			_skeleton.set_bone_global_pose(bone, pose)

## Where the camera belongs, in the Player's own space: the head bone, followed slowly.
func eye_position() -> Vector3:
	return _eye

func has_eye_position() -> bool:
	return _eye_valid

## Moves the clips on by one frame and finds the eyes in the new pose. The Player calls it from
## its _process() and places the camera straight after: left to run by themselves, the Player,
## this node and the AnimationPlayer are processed in that order, and the camera was two frames
## behind the pose -- 15 cm while the body drops into a crouch.
## camera_pitch: the camera's rotation about X (radians, negative = looking down).
func advance(delta: float, camera_pitch: float) -> void:
	var player := get_parent() as Node3D
	if player == null or _head_bone < 0:
		return
	_animations.advance(delta)
	if _elbow_restore.is_finite(): # see _fidget_sheathed
		_skeleton.set_bone_pose_position(_arms["Left"]["lower"], _elbow_restore)
		_elbow_restore = Vector3.INF
	_advance_arm(delta)
	_advance_toggle(delta, camera_pitch)
	_fidget_view(camera_pitch)
	camera_pitch += _view_dip
	_look_pitch = camera_pitch
	# Half a turn (the model faces +Z, the Player looks along -Z) plus the turn into a diagonal.
	_turn = lerp_angle(_turn, _turn_wanted, 1.0 - exp(-delta * diagonal_turn_rate))
	_model.rotation.y = PI + _turn
	_lean_to_weapon(player) # before the eyes are found: it moves the head
	_place_feet(player, delta) # before the eyes are found: it can lower the hips, and the head with them
	# The head bone in the Player's space. On the humanoid skeleton its +Y runs up the skull
	# and its +Z out of the face, so the eyes are found along the head's own axes: a crouched
	# body carries the head tipped far forward, and "up" from the bone is then the back of the
	# skull, from where the camera saw the open neck.
	var head: Transform3D = player.global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_pose(_head_bone)
	var eyes := head.origin + head.basis.y.normalized() * eye_up + head.basis.z.normalized() * eye_forward
	# Looking down, a real head bends forward over the chest; this body does not bend yet, and
	# from the eyes' level place the camera looks straight into the open collar. So the further
	# down the Player looks, the further forward the camera goes.
	eyes.z -= eye_look_down_forward * clampf(sin(-camera_pitch), 0.0, 1.0)
	eyes -= _model.position # where they would be with the model not shifted
	# Further forward than the camera may go: the model moves back by the rest, so the camera
	# is at the eyes all the same.
	_model.position.z = maxf(-eyes.z - eye_max_forward, 0.0)
	# Sideways the camera does not move at all (the head sways with every step, and the
	# sideways run carries it 0.2 m off the axis, over one shoulder): the model moves instead,
	# so the head is always under the camera.
	_model.position.x = -eyes.x
	var target := Vector3(0.0, eyes.y, minf(eyes.z + _model.position.z, 0.0))
	var follow := 1.0 - exp(-delta / maxf(eye_smoothing, 0.001)) if _eye_valid else 1.0
	_eye = _eye.lerp(target, follow)
	# The slow follow is for a step's bob only. When the head moves far and fast (landing from
	# a jump, crouching) the camera must not be left behind it, looking at the neck.
	_eye = target + (_eye - target).limit_length(eye_max_lag)
	_eye_valid = true
	_breathe(player, delta)
	_update_fidget(delta)
	_hold_weapon(player, delta) # before the lantern: the reach to it sets off from this pose
	_hold_shield(player, delta)
	_place_lantern(player, delta)
	# After the lantern: turning it on / off moves the right arm.
	if _weapon_node and _weapon_on_back:
		_weapon_node.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_chest_bone) * WeaponHold.in_hand(_back_socket(), weapon)
	elif _weapon_node:
		_weapon_node.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_arms["Right"]["hand"]) * WeaponHold.in_hand(_weapon_socket, weapon)
	if _shield_node:
		_shield_node.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_shield_bone) * WeaponHold.in_hand(_shield_now, shield)
		if _shield_tug.length_squared() > 0.0:
			_shield_node.global_position += player.global_transform.basis * _shield_tug
	_draw_arm_apart() # last: it shrinks the body's own arm, which nothing may read afterwards

## See weapon_body_toward_weapon. After the clip, before anything reads the pose.
func _lean_to_weapon(player: Node3D) -> void:
	var weight := smoothstep(0.0, 1.0, _weapon_up) if weapon_body_toward_weapon and _weapon_node else 0.0
	if weight <= 0.001:
		return
	var head_turn := _skeleton.get_bone_global_pose(_head_bone).basis
	for bone_name: String in POSTURE_SPINE + POSTURE_NECK:
		var bone := _skeleton.find_bone(bone_name)
		if bone >= 0:
			_skeleton.set_bone_pose_rotation(bone, _skeleton.get_bone_pose_rotation(bone).slerp(_skeleton.get_bone_rest(bone).basis.get_rotation_quaternion(), weapon_body_upright * weight))
	# How far left of the Player's line of sight the chest faces now (the rest pose faces the
	# skeleton's +Z), and the turn about the Player's upright that is still wanted.
	var to_player := (player.global_transform.affine_inverse() * _skeleton.global_transform).basis.orthonormalized()
	var chest_bone := _skeleton.find_bone(POSTURE_SPINE[-1])
	var facing := to_player * (_skeleton.get_bone_global_pose(chest_bone).basis.orthonormalized() * _skeleton.get_bone_global_rest(chest_bone).basis.orthonormalized().inverse() * Vector3.BACK)
	var turn := clampf(wrapf(deg_to_rad(weapon_chest_turn) - atan2(-facing.x, -facing.z), -PI, PI), -1.2, 1.2) * weight
	var upright := (to_player.inverse() * Vector3.UP).normalized()
	for bone_name: String in POSTURE_SPINE:
		var bone := _skeleton.find_bone(bone_name)
		var pose := _skeleton.get_bone_global_pose(bone)
		pose.basis = Basis(upright, turn / POSTURE_SPINE.size()) * pose.basis
		_skeleton.set_bone_global_pose(bone, pose)
	var collar: int = _skeleton.get_bone_parent(_arms["Right"]["upper"])
	var collar_pose := _skeleton.get_bone_global_pose(collar)
	collar_pose.basis = Basis(upright, deg_to_rad(weapon_collar_forward) * weight) * collar_pose.basis
	_skeleton.set_bone_global_pose(collar, collar_pose)
	var head := _skeleton.get_bone_global_pose(_head_bone)
	head.basis = head_turn
	_skeleton.set_bone_global_pose(_head_bone, head)

## The shadow body's arms and what they hold (weapon_shadow_reach). Called with the shadow's
## skeleton just given the body's whole pose, the arms as the picture has them.
func _pose_shadow_arms() -> void:
	var player := get_parent() as Node3D
	var to_skeleton := (player.global_transform.affine_inverse() * _skeleton.global_transform).affine_inverse()
	var to_player := to_skeleton.affine_inverse()
	for side: String in ["Right", "Left"]:
		var arm: Dictionary = _arms[side]
		var held := (_weapon_node != null and _weapon_up > 0.0) if side == "Right" else (_shield_node != null and _shield_up > 0.0)
		if not held:
			continue
		var data := weapon if side == "Right" else shield
		var axes := WeaponHold.hand_axes(_skeleton, side)
		var fist := WeaponHold.socket(_skeleton, side, data.grip_radius, 0.0).origin
		var hand := _skeleton.get_bone_global_pose(arm["hand"])
		# The picture's hand turn, as WeaponHold.solve_arm wants one (the reverse of what it
		# does with it; the left hand is the mirror image).
		var turned := hand.basis.orthonormalized() * Basis(axes["fingers_out"] as Vector3, axes["palm_out"] as Vector3, axes["thumb_side"] as Vector3)
		var palm_side := -1.0 if (axes["fingers_out"] as Vector3).cross(axes["palm_out"] as Vector3).dot(axes["thumb_side"] as Vector3) > 0.0 else 1.0
		var turn := (to_player.basis.orthonormalized() * Basis(turned.y * palm_side, turned.z, -turned.x)).orthonormalized()
		var elbow := (to_player.basis * (_skeleton.get_bone_global_pose(arm["lower"]).origin - _skeleton.get_bone_global_pose(arm["upper"]).origin)).normalized()
		elbow = elbow.lerp(Vector3(0.25 if side == "Right" else -0.25, -1.0, 0.15).normalized(), weapon_shadow_elbows_down)
		# Back on the shadow body's own shoulder; the reach stops short of the picture's fist.
		_shadow_skeleton.set_bone_pose_position(arm["upper"], _shadow_skeleton.get_bone_rest(arm["upper"]).origin)
		WeaponHold.solve_arm(_shadow_skeleton, side, to_skeleton, Vector3.INF, to_player * (hand * fist), elbow, turn, fist, weapon_shadow_reach)
	if _weapon_shadow:
		if _weapon_on_back:
			_weapon_shadow.global_transform = _weapon_node.global_transform
		else:
			_weapon_shadow.global_transform = _shadow_skeleton.global_transform * _shadow_skeleton.get_bone_global_pose(_arms["Right"]["hand"]) * WeaponHold.in_hand(_weapon_socket, weapon)
	if _shield_shadow:
		_shield_shadow.global_transform = _shadow_skeleton.global_transform * _shadow_skeleton.get_bone_global_pose(_shield_bone) * WeaponHold.in_hand(_shield_now, shield)

## The copies of the model that each show one arm alone (weapon_arm_drawn_apart): made once,
## as the model is at the end of _ready's own changes to it. One copy an arm, because all the
## rest of a copy is shrunk into that arm's shoulder.
func _setup_arm_apart() -> void:
	for side: String in ["Right", "Left"]:
		var model := _model.duplicate() as Node3D
		model.name = "Rogue%sArm" % side
		add_child(model)
		model.visible = false
		var chain: PackedInt32Array = []
		var todo: Array[int] = [_arms[side]["upper"]]
		while not todo.is_empty():
			var bone: int = todo.pop_front()
			chain.append(bone)
			todo.append_array(_skeleton.get_bone_children(bone))
		# Only the meshes that have any of the arms are drawn; the head and hood (shadows only
		# on the body) would cast a second shadow from a speck.
		for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
			if not ARM_APART_MESHES.has(String(mesh.name)):
				mesh.visible = false
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF # the shadow's copy casts for them
		_apart[side] = {"model": model, "skeleton": model.find_children("*", "Skeleton3D", true, false)[0], "chain": chain}
	_shadow_model = _model.duplicate() as Node3D
	_shadow_model.name = "RogueShadow"
	add_child(_shadow_model)
	_shadow_model.visible = false
	_shadow_skeleton = _shadow_model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	for mesh: MeshInstance3D in _shadow_model.find_children("*", "MeshInstance3D", true, false):
		if mesh.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		else:
			mesh.visible = false # casts none on the body either: nothing of it to draw
	for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		if mesh.visible:
			_own_casters.append([mesh, mesh.cast_shadow])

## See weapon_arm_drawn_apart. An arm's pose is worked out on the body as ever; here it is
## handed to that arm's copy, and the body's own arm put away. The right arm while the weapon
## is up, the left while the shield is.
func _draw_arm_apart() -> void:
	# The shadow first, while the body still has its arms: the whole pose as it stands goes to
	# the shadow's copy, which casts in place of the body and of the arms' copies.
	var shadow_on := weapon_arm_drawn_apart and ((_weapon_node != null and _weapon_up > 0.0) or (_shield_node != null and _shield_up > 0.0))
	if shadow_on != _shadow_on:
		_shadow_on = shadow_on
		_shadow_model.visible = shadow_on
		# What is held casts from its shadow copy, in the shadow body's hands.
		for held: Node3D in [_weapon_node, _shield_node]:
			if held:
				for mesh: MeshInstance3D in held.find_children("*", "MeshInstance3D", true, false):
					mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if shadow_on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for copy: Node3D in [_weapon_shadow, _shield_shadow]:
			if copy:
				copy.visible = shadow_on
		for caster: Array in _own_casters:
			var mesh: MeshInstance3D = caster[0]
			if caster[1] == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
				mesh.visible = not shadow_on # the head and hood: with their shadow off they would be DRAWN, round the camera
			else:
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if shadow_on else caster[1]
	if shadow_on:
		_shadow_model.transform = _model.transform
		for bone in _skeleton.get_bone_count():
			_shadow_skeleton.set_bone_pose_position(bone, _skeleton.get_bone_pose_position(bone))
			_shadow_skeleton.set_bone_pose_rotation(bone, _skeleton.get_bone_pose_rotation(bone))
			_shadow_skeleton.set_bone_pose_scale(bone, _skeleton.get_bone_pose_scale(bone))
		_pose_shadow_arms()
	for side: String in _apart:
		var copy: Dictionary = _apart[side]
		var model: Node3D = copy["model"]
		var upper: int = _arms[side]["upper"]
		var up := (_weapon_node != null and _weapon_up > 0.0) if side == "Right" else (_shield_node != null and _shield_up > 0.0)
		model.visible = weapon_arm_drawn_apart and up
		if not model.visible:
			continue
		model.transform = _model.transform
		var bones: Skeleton3D = copy["skeleton"]
		var shoulder := _skeleton.get_bone_global_pose(upper)
		# Everything shrunk into the arm's shoulder, so that cloth shared between the arm and
		# the chest closes over the arm's end there instead of trailing off to the body.
		for root_bone in bones.get_parentless_bones():
			bones.set_bone_pose_position(root_bone, shoulder.origin)
			bones.set_bone_pose_scale(root_bone, Vector3.ONE * ARM_APART_SHRINK)
		bones.set_bone_global_pose(upper, shoulder) # full size again, by its own scale
		var chain: PackedInt32Array = copy["chain"]
		for i in range(1, chain.size()):
			var bone := chain[i]
			bones.set_bone_pose_position(bone, _skeleton.get_bone_pose_position(bone))
			bones.set_bone_pose_rotation(bone, _skeleton.get_bone_pose_rotation(bone))
			bones.set_bone_pose_scale(bone, _skeleton.get_bone_pose_scale(bone))
		# The body's own arm: back on its shoulder and shrunk into it (_hold_weapon and
		# _hold_shield undo this at the start of the next frame's work on the arm).
		_skeleton.set_bone_pose_position(upper, _skeleton.get_bone_rest(upper).origin)
		_skeleton.set_bone_pose_scale(upper, Vector3.ONE * ARM_APART_SHRINK)

## The right arm's clip over the body's: the sword idle while a weapon is held, or a swing.
func _advance_arm(delta: float) -> void:
	if _weapon_node == null or not weapon_arm_from_clips:
		if _arm_animations.is_playing():
			_arm_animations.stop() # the body's clip has the arm again from the next frame
		return
	_arm_animations.playback_default_blend_time = weapon_arm_blend
	if not _arm_animations.is_playing():
		_arm_animations.play(&"sword_idle")
	_arm_animations.advance(delta)

## A swing of the held weapon (the Player's left click). One at a time; the arm goes back to
## its idle after it.
func attack() -> void:
	if _weapon_node == null or not weapon_arm_from_clips or _arm_animations.current_animation in ARM_SWINGS:
		return
	_arm_animations.play(ARM_SWINGS[_swing_next % ARM_SWINGS.size()], weapon_arm_blend)
	_arm_animations.queue(&"sword_idle")
	_swing_next += 1

## How far the held weapon's stance is moved from its place just now by the steps (the
## Player's axes). Its pace is that of the clip playing, kept as a count of its own so that a
## change of clip (a turn into another direction) does not make it jump.
func _weapon_bob(delta: float) -> Vector3:
	_weapon_bob_amount = move_toward(_weapon_bob_amount, clampf(_ground_speed / maxf(weapon_bob_full_speed, 0.01), 0.0, 1.5), delta / maxf(weapon_bob_ease, 0.01) * 1.5)
	if _weapon_bob_amount <= 0.001:
		return Vector3.ZERO
	var stride_seconds := _animations.current_animation_length / maxf(absf(_clip_speed), 0.01)
	if stride_seconds > 0.0:
		_weapon_bob_stride = fposmod(_weapon_bob_stride + delta / stride_seconds, 1.0)
	return Vector3(sin(_weapon_bob_stride * TAU) * weapon_bob_side, sin(_weapon_bob_stride * TAU * 2.0) * weapon_bob_height, 0.0) * _weapon_bob_amount

## The chest's breathing against the eyes (see weapon_breathing): its place now less its slow
## average, faded out as the step bob comes in. Sets _breath_now.
func _breathe(player: Node3D, delta: float) -> void:
	if _chest_bone < 0:
		_chest_bone = _skeleton.find_bone("UpperChest")
	var chest := (player.global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_pose(_chest_bone)).origin - _eye
	if not _chest_average_valid:
		_chest_average = chest
		_chest_average_valid = true
	_chest_average = _chest_average.lerp(chest, 1.0 - exp(-delta / maxf(breathing_average, 0.01)))
	_breath_now = (chest - _chest_average).limit_length(breathing_limit) * (1.0 - clampf(_weapon_bob_amount, 0.0, 1.0))

## The fidgets. "keys": [share of the time, where the fist goes from the eyes, the way the
## blade points, the way its leading edge faces], in the Player's axes (+X right, +Y up, -Z
## ahead) and turned with the view as the stance is; the stance itself is before the first key
## and after the last, and the fist eases from key to key. "circle": the blade sweeps round
## the stance's own direction instead (see _fidget_pose). Not judged in game yet.
const FIDGETS := {
	# The sword brought to the middle of the picture, tip up: the flat the stance shows toward
	# the eyes (edge to the left), turned part way toward the edge, back to the flat. The
	# stance holds the edge to the LEFT: opening on the other flat turned the hand over 130 deg
	# outward on the way in (Kirill: "spins outwards into the proper position"). A turn about
	# the upright blade is nearly all wrist (the forearm points ahead, and only a roll about
	# its own line goes into it): edge-on bent it 82 deg and the other flat 151, the fist
	# folding into the forearm (Kirill: "the third roll seems too drastic") -- so no other flat.
	# No key back on the flat after the turn: the sword stood almost still through turn and
	# turn back (three keys in about the same place) and the way to the stance came after a
	# pause (Kirill). From the turn it goes straight back, the edge turning back on the way;
	# the fist drifts nearer during the turn so the arm never stands still.
	# "key_times": when each key is reached (shares of the time) -- the flat at 1.4 s, the edge at
	# 2.9, back by 4.0. (Eased once over the whole, the keys came at 1.3 and 1.9 s and the last
	# 2.1 s were the way back: Kirill, "keep inspecting it longer and hurry the moving to idle
	# up".)
	&"inspect": {"time": 4.0, "stages": ["to the flat", "turn toward the edge", "back to the stance"], "key_times": [0.35, 0.725], "keys": [
		[0.3, Vector3(0.07, -0.27, -0.39), Vector3(0.05, 0.97, -0.25), Vector3(-1.0, 0.0, 0.0)],
		[0.6, Vector3(0.03, -0.23, -0.34), Vector3(0.0, 0.96, -0.3), Vector3(-0.6, 0.2, 0.8)],
	]},
	# WEAPONS SHEATHED ("when"): the body's own right arm, which cannot bring the hand into
	# the picture looking ahead (the shoulder is 0.36 m behind the eyes, the arm 0.56 long), so
	# these take the view down to what is looked at ("view": degrees down, degrees right; it is
	# not dipped further than the Player already looks). Moving the mouse ends them (looked()).
	# "bounds": where the stages meet, shares of the time. Not judged in game yet.
	# Settling the shield: the left arm brings it up in front of the belly ("shield_arm": the
	# left hand from the left shoulder, the Player's axes), the right hand grips it ("grip":
	# &"strap" -- on the left forearm, "strap_along" from elbow to wrist -- or &"rim", its edge,
	# "rim_out" the palm outside it), tugs it once ("tug": metres, the hand) and lets go.
	# ("view": y below 0 turns it LEFT.) It replaced a finger flex in front of the chest, which
	# did not look good (Kirill, 2026-10-14). The rim point: "rim_at" (a way in the view,
	# degrees right / up of its middle: the one Kirill marked on a screenshot), else
	# "rim_side" (a way from the board's middle, the Player's axes), else the right side with
	# reach and view penalties. "shield_arm" was moved 7 cm toward the middle and 4 cm nearer
	# for it: the marked spot was 0.72 m from the right shoulder, 10 cm out of reach.
	# Timed in shares of 2.8 s, as seconds: shield up and the hand on its edge 0-1.0 (they finish
	# together), two quick small tugs straight after the grip 1.04-1.54 ("tugs", "tug" 1.2 cm, the
	# shield moving 0.7), the fingers loosen from 1.48 as they end, and the hand is already
	# leaving (from 1.58, the shield going down with it, to 2.58) while they open; the view back
	# up 1.9-2.78. (Kirill: no stage just to grip, no hold before the tug, hand and shield
	# together both ways, nobody waits for the fingers to open before moving the hand away, and
	# two quick small tugs that barely move the shield, not one big one of 3 cm over 0.8 s.)
	&"strap": {"time": 2.8, "when": &"sheathed", "stages": ["raise and grip", "tug", "let go and lower"], "bounds": [0.371, 0.55],
		"raise_to": 0.357, "view_in": 0.314, "view_out": 0.679, "view_back": 0.993, "tug_at": Vector2(0.371, 0.179), "tugs": 2,
		"lower": Vector2(0.564, 0.921), "reach_out": Vector2(0.564, 0.921), "grip_open": Vector2(0.529, 0.611),
		"view": Vector2(58.0, -10.0), "grip": &"rim", "rim_at": Vector2(6.0, 7.0), "reach": Vector2(0.029, 0.357), "grip_close": Vector2(0.3, 0.371), "reach_even": 0.5, "reach_soft": 0.03, "rim_around": Vector2(0.4, 0.08), "rim_thumb": Vector4(0.1, 0.2, 0.721, 0.821), "rim_thumb_closed": 1.1, "rim_across": -0.01, "shield_arm": Vector3(0.22, -0.16, -0.4), "shield_around": Vector3(-0.05, -0.3, -0.45), "strap_along": 0.8, "rim_out": 0.02, "tug": 0.012},
	# Only while it is lit ("lit"): the palm comes in behind the lantern as in toggle_lantern
	# (toggle_cup_offset), swings it forward on its hook ("lift_degrees") into the picture,
	# turns it ONCE about its own long axis ("turn_degrees") and back, and lets it back. (It
	# swung the lantern sideways one way and the other at first: "more of a shake twice".) (First set: the palm under
	# its bottom and a 35 deg lift -- the bottom hangs by the left thigh, the right forearm went
	# 11 cm into the body, the palm stayed 11-15 cm short and never came into view.)
	# Timed in shares of 3.45 s, as seconds: the view down 0-0.99, the hand to the lantern
	# 0.36-1.26, the lift from 1.08 as the hand settles on it (to 1.8), the turn from 1.62 as the
	# lift ends (to 2.7), lowered from 2.34, let go 2.43-2.79 and the hand away by 3.33, the view
	# back 2.43-3.42. (At 4.5 s the lift waited for the hand to arrive and the turn for the lift
	# to end, and the last 0.8 s nothing moved -- the realism aim, docs/custom_animations.md.)
	&"lantern_look": {"time": 3.45, "when": &"sheathed", "lit": true, "stages": ["look and reach", "lift", "turn it", "lower and let go"], "bounds": [0.313, 0.47, 0.783],
		"view": Vector2(75.0, 15.0), "view_in": 0.287, "view_out": 0.704, "view_back": 0.991, "lift_degrees": 50.0, "lean_degrees": 50.0, "turn_degrees": 70.0,
		"reach": Vector4(0.104, 0.365, 0.757, 0.965), "lift": Vector4(0.313, 0.522, 0.678, 0.835), "turn_at": Vector2(0.47, 0.313), "let_go": Vector2(0.704, 0.809)},
	# WEAPONS DRAWN, THE SHIELD ARM ("shield_keys"; the sword stays in its stance): [share of
	# the eased time, the hand moved (m, the stance's axes: +X right, +Y up, +Z back toward the
	# eyes), the forearm rolled (degrees, + = the shield's face toward the eyes, worked out from
	# the stance: _glance_sign), the shoulder moved (m)]; the stance before the first key and
	# after the last, one eased curve through them as the sword's keys (_key_paced). 2026-10-14,
	# not judged in game yet.
	# A shrug and lift that re-seats the shield on the forearm: up with a little roll, down just
	# past where it was, and back.
	&"shield_settle": {"time": 1.3, "stages": ["shrug and lift", "settle"], "bounds": [0.45], "shield_keys": [
		[0.35, Vector3(0.0, 0.045, 0.01), 4.0, Vector3(0.0, 0.03, 0.0)],
		[0.68, Vector3(0.0, -0.012, 0.0), -2.0, Vector3(0.0, -0.005, 0.0)],
	]},
	# The shield turned in to look at its face: a little toward the middle, up and nearer, its
	# face rolled toward the eyes, held there, and back. "hold": [up by, back from] (shares of
	# the time) -- with "hold" the one key is the peak, eased in, held, eased out. Seconds: in
	# 0-1.3, held to 2.2, back by 3.1. (Kirill: turn it in slower, no "look" stage -- it drifted
	# between two keys -- just held at the peak a little longer.)
	# "twist": [degrees, from, to] -- the shield turned about the line along its length through
	# its middle (positive = the side facing the eyes moves right), slowly through the hold, and
	# unwound on the way back (Kirill: "a little rotation when the shield's at the peak, to
	# really give an examining vibe", "along the shield's length in the middle").
	# Seconds since: in 0-1.3, held 0.4 s, the twist 1.7-2.1, held turned to 2.87, back by 3.77
	# (Kirill: "rotate it a bit quicker and hold it rotated a bit longer", then "hold the shield
	# both before and after rotation a bit longer", then "little less after rotation" (1.4 s ->
	# 1.1), then 30 % less again (0.77 s)); the head in by 1.05, back 2.72-3.52.
	# The head looks at it (Kirill: "slight head tilts/turns to show that the MC is examining the
	# shield"): 8 deg left (the shield's middle is 27 left: the eyes do the rest), tilted 3 deg
	# and then 5 as it turns; the head is in before the shield (1.05 s against 1.3) and leaves
	# first (from 2.72 s, the shield from 2.87). No dip: the drawn weapons follow the view's pitch.
	&"shield_glance": {"time": 3.77, "stages": ["turn it in", "back"], "bounds": [0.761], "hold": Vector2(0.345, 0.761), "twist": Vector3(12.0, 0.451, 0.557),
		"view": Vector2(0.0, -8.0), "view_in": 0.279, "view_out": 0.721, "view_back": 0.934, "view_tilt": Vector2(3.0, 5.0), "shield_keys": [
		[0.5, Vector3(0.1, 0.16, 0.05), 124.0, Vector3(0.0, 0.03, 0.0)],
	]},
	# Two loose circles of the blade round the way it points in the stance.
	# (At 2.2 s the tip moved up to 7.5 cm a frame: quicker than a loose roll.)
	&"wrist_roll": {"time": 3.5, "stages": ["tip in", "two circles", "back"], "circle": {"turns": 2.0, "tilt_degrees": 25.0, "hand": 0.03, "from": 0.3, "to": 0.7}},
}

## Cancels the fidget playing, if any (the Player calls this on any key or mouse button), and
## starts the wait for the next one again.
func interrupt_fidget() -> void:
	_fidget_still = 0.0
	if _fidget != &"" and not _fidget_cancelled and not _fidget_driven:
		_fidget_cancelled = true

## The Player moved the mouse: the wait for the next fidget starts again, and one that has the
## view (FIDGETS' "view") is ended -- the sword fidgets go on while looking round.
func looked() -> void:
	_fidget_still = 0.0
	if _fidget != &"" and not _fidget_cancelled and not _fidget_driven and (FIDGETS[_fidget] as Dictionary).has("view"):
		_fidget_cancelled = true

## Whether a fidget may play now: weapons drawn or sheathed as it asks, the lantern lit if it
## asks that.
func _fidget_fits(fidget_name: StringName) -> bool:
	var fidget: Dictionary = FIDGETS[fidget_name]
	if fidget.get("when", &"drawn") == &"sheathed":
		if _weapon_node != null and (weapon_raised or _weapon_up > 0.0):
			return false
		if bool(fidget.get("lit", false)) and (_lantern_light == null or not _lantern_light.visible):
			return false
		if fidget.has("shield_arm") and (_shield_node == null or shield == null or not shield.on_forearm):
			return false
		return true
	if fidget.has("shield_keys") and (_shield_node == null or shield == null or not shield.on_forearm or _shield_up < 1.0 or _shield_stance == null or weapon_shoulder_on_body):
		return false
	return _weapon_node != null and _weapon_up >= 1.0 and not _weapon_on_back and not weapon_arm_from_clips

## Starts a fidget by name at once (for checks and probes; the game picks them by itself).
func start_fidget(fidget_name: StringName) -> void:
	if FIDGETS.has(fidget_name):
		_fidget = fidget_name
		_fidget_at = 0.0
		_fidget_fade = 1.0
		_fidget_cancelled = false
		_fidget_last = fidget_name
		_rim_pick = -1
		_rim_local = Vector3.INF
		_forearm_held_set = false
		_fidget_shield_push = Vector3.ZERO

func fidget_playing() -> StringName:
	return _fidget

## For the animation debug panel (scripts/debug/animation_panel.gd): what can be shown, each as
## {name, time (s), stages: [[name, from s, to s], ...]}.
func debug_animations() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for fidget_name: StringName in FIDGETS:
		var fidget: Dictionary = FIDGETS[fidget_name]
		var time := float(fidget["time"])
		# Where the stages meet, as shares of the time: the keys (of the eased time, see
		# _fidget_pose) or the circle's start and end.
		var bounds: Array[float] = [0.0]
		if fidget.has("bounds"):
			for bound: float in fidget["bounds"]:
				bounds.append(bound)
		elif fidget.has("key_times"):
			for share: float in fidget["key_times"]:
				bounds.append(share)
		elif fidget.has("keys"):
			for key: Array in fidget["keys"]:
				bounds.append(_uneased(float(key[0])))
		else:
			bounds.append(float((fidget["circle"] as Dictionary)["from"]))
			bounds.append(float((fidget["circle"] as Dictionary)["to"]))
		bounds.append(1.0)
		var names: Array = fidget.get("stages", [])
		var stages: Array = []
		for i in bounds.size() - 1:
			stages.append([names[i] if i < names.size() else "stage %d" % (i + 1), bounds[i] * time, bounds[i + 1] * time])
		list.append({"name": fidget_name, "time": time, "stages": stages})
	return list

## The animation debug panel holds the animation at `seconds` into it: the weapons up or down
## as the fidget asks, and the lantern lit for one that needs it.
func debug_drive(animation: StringName, seconds: float) -> void:
	if not FIDGETS.has(animation):
		return
	var fidget: Dictionary = FIDGETS[animation]
	weapon_raised = fidget.get("when", &"drawn") != &"sheathed"
	if bool(fidget.get("lit", false)) and _lantern_light and not _lantern_light.visible:
		_lantern_light.visible = true
	if _fidget != animation or _fidget_cancelled:
		start_fidget(animation)
	_fidget_driven = true
	_fidget_at = seconds

## ... and lets it go: the arm eases back to the stance.
func debug_release() -> void:
	if _fidget_driven:
		_fidget_driven = false
		_fidget_cancelled = true

## The fidgets' easing, as smoothstep(from, to, x) is used: a reach's speed curve, at rest at
## both ends with no jolt (speed and its change both start and end at 0), fastest at 40 % of the
## way -- quicker away, longer to settle. Its speed goes as x^2 (1 - x)^3. (Every fidget had
## smoothstep, the same mirrored S on every move: "kind of robotic", Kirill, 2026-10-14.)
static func _ease(from: float, to: float, x: float) -> float:
	var t := clampf((x - from) / (to - from), 0.0, 1.0) if to != from else (1.0 if x >= to else 0.0)
	return t * t * t * (20.0 + t * (-45.0 + t * (36.0 - 10.0 * t)))

## How strongly a fidget's keys slow it as it passes them (0 = an even pace through the keys, 1
## = it stops at each): eased once over the whole, the blade moved at much the same pace through
## all of them, with no accent (Kirill: "robotic"); eased key to key it stopped at each.
const FIDGET_KEY_ACCENT := 0.35

## `at` (of the eased time) moved on so the pace dips at each of `times` (the keys) and rises
## between them, the same at the ends of every part however long: its rate is
## 1 - FIDGET_KEY_ACCENT * cos(2 pi * the share of the part).
static func _key_paced(times: Array[float], at: float) -> float:
	var index := 0
	while index < times.size() - 2 and at > times[index + 1]:
		index += 1
	var length := times[index + 1] - times[index]
	if length <= 0.0001:
		return at
	var share := clampf((at - times[index]) / length, 0.0, 1.0)
	share -= FIDGET_KEY_ACCENT / TAU * sin(TAU * share)
	return times[index] + share * length

## The parameter of the curve _reach follows (from `start` bowed toward `bend`, to `end`) at
## which `share` of its length is behind: so a weight eased in time moves the hand along it at
## the eased pace, not faster where the curve's parameter runs ahead.
static func _even_on_curve(start: Vector3, bend: Vector3, end: Vector3, share: float) -> float:
	if share <= 0.0 or share >= 1.0:
		return clampf(share, 0.0, 1.0)
	const STEPS := 24
	var lengths: Array[float] = [0.0]
	var before := start
	for i in range(1, STEPS + 1):
		var w := float(i) / STEPS
		var point := start.lerp(bend, w).lerp(bend.lerp(end, w), w)
		lengths.append(lengths[-1] + before.distance_to(point))
		before = point
	var wanted := share * lengths[-1]
	for i in range(1, STEPS + 1):
		if lengths[i] >= wanted:
			var part := (wanted - lengths[i - 1]) / maxf(lengths[i] - lengths[i - 1], 0.000001)
			return (i - 1 + part) / STEPS
	return 1.0

## A smooth, never-backward curve through the points (xs[i], ys[i]) (xs and ys rising from 0 to
## 1), flat at both ends and at no point between (a monotone cubic: Fritsch and Carlson), at `x`.
static func _smooth_through(xs: Array[float], ys: Array[float], x: float) -> float:
	var n := xs.size()
	var slopes: Array[float] = []
	for i in n - 1:
		slopes.append((ys[i + 1] - ys[i]) / maxf(xs[i + 1] - xs[i], 0.000001))
	var tangents: Array[float] = [0.0]
	for i in range(1, n - 1):
		tangents.append(0.0 if slopes[i - 1] * slopes[i] <= 0.0 else (slopes[i - 1] + slopes[i]) * 0.5)
	tangents.append(0.0)
	for i in n - 1: # no overshoot
		if slopes[i] == 0.0:
			tangents[i] = 0.0
			tangents[i + 1] = 0.0
			continue
		var a := tangents[i] / slopes[i]
		var b := tangents[i + 1] / slopes[i]
		var length := a * a + b * b
		if length > 9.0:
			var scale := 3.0 / sqrt(length)
			tangents[i] = scale * a * slopes[i]
			tangents[i + 1] = scale * b * slopes[i]
	var index := 0
	while index < n - 2 and x > xs[index + 1]:
		index += 1
	var width := maxf(xs[index + 1] - xs[index], 0.000001)
	var t := clampf((x - xs[index]) / width, 0.0, 1.0)
	var t2 := t * t
	var t3 := t2 * t
	return (2.0 * t3 - 3.0 * t2 + 1.0) * ys[index] + (t3 - 2.0 * t2 + t) * width * tangents[index] + (-2.0 * t3 + 3.0 * t2) * ys[index + 1] + (t3 - t2) * width * tangents[index + 1]

## The share of the time at which _ease reaches `eased`.
static func _uneased(eased: float) -> float:
	var low := 0.0
	var high := 1.0
	for i in 30:
		var middle := (low + high) * 0.5
		if _ease(0.0, 1.0, middle) < eased:
			low = middle
		else:
			high = middle
	return (low + high) * 0.5

## Counts the time stood still and starts, runs and ends the fidgets.
func _update_fidget(delta: float) -> void:
	if _fidget_driven:
		_fidget_fade = 1.0
		return
	var still := _ground_speed < still_speed and _was_on_floor and _dash_left <= 0.0 and _toggle_at < 0.0
	if _fidget != &"":
		_fidget_at += delta
		if not still or not _fidget_fits(_fidget):
			_fidget_cancelled = true
		if _fidget_cancelled:
			_fidget_fade = move_toward(_fidget_fade, 0.0, delta / maxf(fidget_cancel_time, 0.01))
		if _fidget_fade <= 0.0 or _fidget_at >= float((FIDGETS[_fidget] as Dictionary)["time"]):
			_fidget = &""
			_fidget_still = 0.0
			_fidget_wait = -1.0
		return
	var fitting: Array = FIDGETS.keys().filter(_fidget_fits)
	if not still or not fidgets_on or fitting.is_empty():
		_fidget_still = 0.0
		return
	if _fidget_wait < 0.0:
		_fidget_wait = fidget_after + randf() * fidget_after_random
	_fidget_still += delta
	if _fidget_still >= _fidget_wait:
		var names: Array = fitting.filter(func(n: StringName) -> bool: return n != _fidget_last)
		if names.is_empty():
			names = fitting
		start_fidget(names[randi() % names.size()])

## How far through the fidget playing is (0-1), and how much of a fidget's look / reach is in
## at that share: in over `from_in`..`to_in`, out over `from_out`..`to_out`, times the fade.
func _fidget_share() -> float:
	return clampf(_fidget_at / float((FIDGETS[_fidget] as Dictionary)["time"]), 0.0, 1.0) if _fidget != &"" else 0.0

func _fidget_in_out(from_in: float, to_in: float, from_out: float, to_out: float) -> float:
	var at := _fidget_share()
	return _ease(from_in, to_in, at) * (1.0 - _ease(from_out, to_out, at)) * _fidget_fade

## A fidget that has the view ("view" in FIDGETS) dips it toward what it looks at, and turns it
## a little right; no lower than the Player already looks. Adds to _view_dip, sets _fidget_turn
## and _fidget_tilt. A dip of 0 leaves the pitch alone. "view_tilt": [degrees, degrees] the head
## tilts (+ = left ear down), the first as it looks, going to the second as the "twist" turns.
func _fidget_view(camera_pitch: float) -> void:
	_fidget_turn = 0.0
	_fidget_tilt = 0.0
	if _fidget == &"" or not (FIDGETS[_fidget] as Dictionary).has("view"):
		return
	var view: Vector2 = FIDGETS[_fidget]["view"]
	var fidget: Dictionary = FIDGETS[_fidget]
	var amount := _fidget_in_out(0.0, float(fidget.get("view_in", 0.22)), float(fidget.get("view_out", 0.78)), float(fidget.get("view_back", 1.0)))
	if view.x > 0.0:
		_view_dip += minf(-deg_to_rad(view.x) - camera_pitch, 0.0) * amount
	_fidget_turn = deg_to_rad(view.y) * amount
	if fidget.has("view_tilt"):
		var tilt: Vector2 = fidget["view_tilt"]
		var turned := 0.0
		if fidget.has("twist"):
			var twist: Vector3 = fidget["twist"]
			turned = _ease(twist.y, twist.z, _fidget_share())
		_fidget_tilt = deg_to_rad(lerpf(tilt.x, tilt.y, turned)) * amount

## The sheathed fidgets' right arm (and the lantern's lift), after the clip and before the
## lantern is placed. `pivot` is the lantern's hook (the Player's space).
func _fidget_sheathed(bones: Transform3D, pivot: Vector3, delta: float) -> void:
	_lantern_spin = 0.0
	_shield_tug = Vector3.ZERO
	if _fidget == &"" or (FIDGETS[_fidget] as Dictionary).get("when", &"drawn") != &"sheathed":
		return
	var fidget: Dictionary = FIDGETS[_fidget]
	var at := _fidget_share()
	var arm: Dictionary = _arms["Right"]
	if fidget.has("shield_arm"):
		if _shield_node == null or not shield.on_forearm:
			return
		var left: Dictionary = _arms["Left"]
		# The left arm: the shield up in front of the belly, the hand kept in its grip as in
		# the stance, and the forearm rolled so the shield's face looks away from the body
		# (the relaxed carry's own roll, _relax_shield_arm).
		# "lower": when the shield goes back down (shares of the time); the right hand leaves with
		# it ("reach_out"): it used to be gone before the shield moved (Kirill: "let's sync this").
		var lower_at: Vector2 = fidget.get("lower", Vector2(0.7, 0.95))
		var raise := _fidget_in_out(0.0, float(fidget.get("raise_to", 0.25)), lower_at.x, lower_at.y)
		var left_shoulder := bones * _skeleton.get_bone_global_pose(left["upper"]).origin
		# Up by way of a place in front ("shield_around"): straight up, the board went 7 cm
		# through the thigh and belly on the way.
		_reach(left, "palm", bones, left_shoulder + (fidget["shield_arm"] as Vector3), raise, Vector3(-0.7, -0.6, 0.2), Vector3.RIGHT, 0.0, left_shoulder + (fidget["shield_around"] as Vector3), Vector3.INF, Vector3.INF, _shield_hand_in_stance)
		if raise > 0.001:
			_relax_shield_arm(left, get_parent() as Node3D)
		# Once up, the forearm (and the board on it) is held still against the eyes where it first
		# stood (_forearm_held), and the upper arm alone takes the breathing: the shoulder's 2 cm
		# rise and fall swung the forearm about 3.5 deg, and the right hand's grip on the board
		# with it (Kirill: "the hand shifts around because of the breathing idle animation"). The
		# board drawn still with the forearm left to move drifted 2-3.5 cm off it, and the
		# forearm lies on the board's back, in view. Let go as it lowers.
		var lower_now := bones * _skeleton.get_bone_global_pose(left["lower"])
		if raise >= 0.999 and not _forearm_held_set:
			_forearm_held = Transform3D(lower_now.basis, lower_now.origin - _eye)
			_forearm_held_set = true
		if _forearm_held_set and raise > 0.001:
			var held := lower_now.interpolate_with(Transform3D(_forearm_held.basis, _forearm_held.origin + _eye), raise)
			var to_skeleton := bones.affine_inverse()
			var lower := to_skeleton * held
			# The upper arm turned to meet the held elbow; the length it is off by (a centimetre or
			# two) goes into the elbow, inside the sleeve.
			var upper := _skeleton.get_bone_global_pose(left["upper"])
			var was := _skeleton.get_bone_global_pose(left["lower"]).origin - upper.origin
			var wants := lower.origin - upper.origin
			if was.length() > 0.001 and wants.length() > 0.001:
				var turn := Quaternion(was.normalized(), wants.normalized())
				upper.basis = Basis(turn) * upper.basis
				_skeleton.set_bone_global_pose(left["upper"], upper)
			# The clips turn the lower arm but have no track for its place: what is set here would
			# stay, and the upper arm came out 4 cm shorter after each run (the shield "changes
			# its position permanently", Kirill). Put back at the start of the next frame.
			if not _elbow_restore.is_finite():
				_elbow_restore = _skeleton.get_bone_pose_position(left["lower"])
			_skeleton.set_bone_global_pose(left["lower"], lower)
			_skeleton.set_bone_pose_rotation(left["hand"], _shield_hand_in_stance)
		# Off the body as the relaxed carry is (_swing_shield_off_body): posed after that keep-off,
		# the board went 1.3-2.4 cm into the thigh half way down. Not while held up (13 cm clear
		# there): swinging the upper arm dragged the held forearm, and the board swung 16 deg.
		# On the way down only, faded in as the shield lowers (switched off at once when the hold
		# set in, the board jumped 21 cm in a frame; on the way up it is clear without it, and
		# there it moved the board as the hand arrived, the fingers grazing it).
		_fidget_shield_push = _swing_shield_off_body(left, get_parent() as Node3D, delta, _fidget_shield_push, 1.0 - raise if _forearm_held_set else 0.0)
		var board := bones * _skeleton.get_bone_global_pose(_shield_bone) * WeaponHold.in_hand(_shield_now, shield)
		var tug_at: Vector2 = fidget.get("tug_at", Vector2(0.45, 0.2)) # starts, lasts (shares of the time)
		# "tugs": how many, back to back in that time, each out and back.
		var tugging := 0.5 - 0.5 * cos(TAU * float(fidget.get("tugs", 1)) * clampf((at - tug_at.x) / tug_at.y, 0.0, 1.0))
		# "reach": [sets off, arrives] (shares of the time); the right hand as quick as the left
		# arm's raise (0-0.25): arriving at 0.38 it was "still much slower" (Kirill).
		var reach_at: Vector2 = fidget.get("reach", Vector2(0.15, 0.38))
		var reach_out: Vector2 = fidget.get("reach_out", Vector2(0.62, 0.85))
		var grip_at := _fidget_in_out(reach_at.x, reach_at.y, reach_out.x, reach_out.y)
		# Closes once the hand is all but there and opens just before it leaves: with _ease the
		# hand takes longer over its last centimetre, and closing from 0.36 the little finger's
		# tip went into the board.
		var grip_close: Vector2 = fidget.get("grip_close", Vector2(0.39, 0.47))
		var grip_open: Vector2 = fidget.get("grip_open", Vector2(0.59, 0.65))
		var grip := _ease(grip_close.x, grip_close.y, at) * (1.0 - _ease(grip_open.x, grip_open.y, at))
		var curl := lerpf(toggle_open_curl, 0.9, grip)
		if fidget.get("grip", &"strap") == &"strap":
			# The right hand to the strap: on the left forearm, near the wrist, on its upper side
			# (Kirill went back to this from the rim, "not quite", 2026-10-14).
			var strap_elbow := bones * _skeleton.get_bone_global_pose(left["lower"]).origin
			var strap_wrist := bones * _skeleton.get_bone_global_pose(left["hand"]).origin
			var strap := strap_elbow.lerp(strap_wrist, float(fidget["strap_along"])) + Vector3.UP * 0.05
			var strap_pull := Vector3(0.5, 0.5, 0.3).normalized() * float(fidget["tug"]) * tugging
			_shield_tug = strap_pull * 0.5 * _fidget_fade
			# The elbow out to the right: down and back (TOGGLE_ELBOW) it tucked into the belly as
			# the hand went across, the forearm reading 7-9 cm into the trunk. It comes by way of
			# a place out in front of the strap (straight from the hip it passed the belly).
			_reach(arm, "palm", bones, strap + strap_pull, grip_at, Vector3(1.0, -0.3, 0.1), Vector3.DOWN, 0.0, strap + Vector3(0.15, 0.05, -0.15))
			_set_fingers(arm, [curl * 0.6, curl, curl, curl, curl], grip_at)
			return
		# "grip": rim -- KEPT, NOT IN USE (Kirill: "don't remove rim code just yet").
		# The right hand to the shield's RIM (Kirill: "grab by shield's edge instead, seems more
		# universal for different models" -- a strap's place depends on the model): the point of
		# the rim nearest the right shoulder, the rim taken as the ellipse that fits the board's
		# box (_shield_points; a round board exactly), the palm toward the board's middle.
		# The rim is the model's own vertices on its outer edge (_shield_rim, read at equip): the
		# one nearest a place the right hand reaches easily ("rim_near": from the right shoulder,
		# the Player's axes -- in front of the chest, toward the middle). (An ellipse fitted to
		# the board's box aimed 63 deg off to the left and 7 cm off the mesh; the rim nearest the
		# right shoulder was the board's top edge, out of the picture; its right-hand edge was
		# 42 cm out of the arm's reach.)
		if _shield_rim.is_empty():
			return
		# The board's near top edge is the only rim in easy reach, and it is off at the picture's
		# upper left: so each rim point is scored by its distance to that place, plus how far
		# it is out of the arm's reach (0.5 m from the shoulder) and outside a 30 deg cone round
		# the middle of the view.
		var shoulder := bones * _skeleton.get_bone_global_pose(arm["upper"]).origin
		var view: Vector2 = fidget["view"]
		var looking := Basis(Vector3.UP, -deg_to_rad(view.y)) * Basis(Vector3.RIGHT, -deg_to_rad(view.x)) * Vector3.FORWARD
		# Kirill: "just a rim on the right" -- the side of the board toward the right hand: the
		# rim point whose way from the board's middle is most nearly the Player's right (and the
		# penalties above). Weighted 0.3 it lost to the reach penalty and gave the upper right.
		var middle_placed := board * _shield_rim_middle
		var rim := Vector3.INF
		var best := INF
		# "rim_at": a way in the view (degrees right, up of its middle) -- the rim point seen most
		# nearly there. Kirill marked the place on a screenshot, 2026-10-14: the board's edge
		# just right of and above the picture's middle (about 6 right, 7 up), the shield held
		# as for the strap.
		var seen_at := Vector3.ZERO
		if fidget.has("rim_at"):
			var at_view: Vector2 = fidget["rim_at"]
			seen_at = Basis(Vector3.UP, -deg_to_rad(view.y) - deg_to_rad(at_view.x)) * Basis(Vector3.RIGHT, -deg_to_rad(view.x) + deg_to_rad(at_view.y)) * Vector3.FORWARD
		# "rim_side": the rim point whose way from the board's middle is most nearly this way
		# (the Player's axes), with no reach penalty -- every rim point is 0.62 m or more from
		# the shoulder with the shield held as for the strap, and with the penalty the board's
		# top edge won every time.
		var side: Vector3 = fidget.get("rim_side", Vector3.ZERO)
		# Picked afresh each frame until the shield is up, then kept (_rim_pick): picked on, the
		# breathing moved the board enough to flip the pick between neighbouring vertices, and
		# the aim jumped 3.5 deg in the picture.
		var picked := _rim_pick if _rim_pick < _shield_rim.size() else -1
		if picked < 0:
			for index in _shield_rim.size():
				var placed := board * _shield_rim[index]
				var score: float
				if side != Vector3.ZERO:
					score = (placed - middle_placed).angle_to(side)
				elif seen_at != Vector3.ZERO:
					# Where it is seen alone (see "rim_side" for why no reach penalty).
					score = seen_at.angle_to(placed - _eye)
				else:
					score = 2.0 * maxf(placed.distance_to(shoulder) - 0.5, 0.0) + 1.5 * (placed - middle_placed).angle_to(Vector3.RIGHT) + maxf(looking.angle_to(placed - _eye) - deg_to_rad(30.0), 0.0)
				if score < best:
					best = score
					picked = index
			if picked < 0:
				return
			if raise >= 0.999:
				_rim_pick = picked
		var rim_wanted: Vector3 = _shield_rim[picked]
		# The point glides to the pick, on the board (so it does not lag the board's own move):
		# while the shield rises the pick creeps 1-2 cm a frame and at times flips to another
		# part of the rim 10-22 cm off, and the hand, already on its way, jerked to 4.4 m/s for a
		# frame (Kirill: "sometimes the right hand jitters as it's moving towards the shield").
		# A damped spring (as _spring), not an eased follow: an eased follow set off at full speed
		# each time the pick changed, and the hand's way turned in one frame.
		if not _rim_local.is_finite():
			_rim_local = rim_wanted
			_rim_local_speed = Vector3.ZERO
		var omega := 2.0 / RIM_GLIDE
		var x := omega * delta
		var decay := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
		var change := _rim_local - rim_wanted
		var temp := (_rim_local_speed + omega * change) * delta
		_rim_local_speed = (_rim_local_speed - omega * temp) * decay
		_rim_local = rim_wanted + (change + temp) * decay
		rim = board * _rim_local
		var inward := board * _shield_rim_middle - rim
		inward -= (board.basis * _shield_face).normalized() * inward.dot((board.basis * _shield_face).normalized())
		var edge := rim - inward.normalized() * float(fidget.get("rim_out", 0.02))
		# Across the board ("rim_across", metres along its face's normal): the thumb, closed on
		# the near face, sat level with the board and grazed it with the palm on the edge's line.
		edge += (board.basis * _shield_face).normalized() * float(fidget.get("rim_across", 0.0))
		_rim_target = edge
		var pull := Vector3(0.3, 0.5, 0.3).normalized() * float(fidget["tug"]) * tugging
		_shield_tug = pull * 0.6 * _fidget_fade
		# The elbow out to the right, and the way in from the SIDE: bowed out past the edge, along
		# the board's face away from its middle ("rim_around", metres), so the hand comes onto the
		# edge from outside the board. Bowed out in front of the edge instead (0.15 right, 0.15
		# ahead), the hand rose from the hip palm out "like hailing a cab" and went through the
		# board's lower right (Kirill).
		# The curve bows toward a place to the RIGHT of the edge as the view sees it
		# ("rim_around": metres right, up), so the hand rises beside the board and curves in onto
		# the edge from the side, and leaves along the same curve. (Out past the edge from the
		# board's middle, that place was mostly ABOVE the edge, which lies up and right of the
		# middle: the hand rose out of the top of the picture. Two moves -- up to the place, then
		# across -- turned a corner, "an angular pattern", Kirill.)
		if fidget.has("rim_around"):
			var bow: Vector2 = fidget["rim_around"]
			var view_right := Basis(Vector3.UP, -deg_to_rad(view.y)) * Vector3.RIGHT
			var beside := edge + view_right * bow.x + Vector3.UP * bow.y
			# Part way to the eased pace along the curve ("reach_even", 0-1): _reach's weight is the
			# curve's own parameter, and most of the way lies before the bend, so the hand slowed to
			# 0.6 m/s at the bend and sped up again (Kirill had asked for a quicker reach); all the
			# way to an even pace it took the bend at full speed, turning 35 deg in a frame. A hand
			# slows somewhat in a bend.
			var from := bones * (_skeleton.get_bone_global_pose(arm["hand"]) * (arm["palm"] as Vector3))
			var along := lerpf(grip_at, _even_on_curve(from, beside, edge + pull, grip_at), float(fidget.get("reach_even", 1.0)))
			_reach(arm, "palm", bones, edge + pull, along, Vector3(1.0, -0.3, 0.1), inward.normalized(), 0.0, beside, Vector3.INF, Vector3.INF, null, float(fidget.get("reach_soft", 0.0)))
		else:
			_reach(arm, "palm", bones, edge + pull, grip_at, Vector3(1.0, -0.3, 0.1), inward.normalized(), 0.0, edge + Vector3(0.15, 0.05, -0.15))
		# The thumb closes while the hand is still off to the side of the board and opens once it
		# is off again ("rim_thumb": shares of the time), so the edge comes in between thumb and
		# fingers. Closing with the fingers it went through the board both ways: open, its tip
		# stood 4 cm past the board's far face, closed 2 cm before the near one (Kirill: "the
		# right thumb clips both on grabbing and letting go").
		var thumb_curl := curl * 0.6
		if fidget.has("rim_thumb"):
			var thumb_at: Vector4 = fidget["rim_thumb"]
			# "rim_thumb_closed": how far it closes (radians a joint, before the thumb's 0.6 share).
			thumb_curl = lerpf(toggle_open_curl, float(fidget.get("rim_thumb_closed", 0.9)), _ease(thumb_at.x, thumb_at.y, at) * (1.0 - _ease(thumb_at.z, thumb_at.w, at))) * 0.6
		_set_fingers(arm, [thumb_curl, curl, curl, curl, curl], grip_at)
	elif fidget.has("lift_degrees"):
		# The lantern: how it hangs just before the hand lifts it, then lifted forward on its
		# hook and turned a little each way, and let back the same way to where it hung.
		# The timings (shares of the time), from the FIDGETS entry: "lift" in and out, "turn_at"
		# start and length, "reach" in and out, "let_go" (the fingers open and the hand moves off
		# the lantern's side).
		var lift_at: Vector4 = fidget.get("lift", Vector4(0.28, 0.42, 0.58, 0.7))
		var turn_at: Vector2 = fidget.get("turn_at", Vector2(0.42, 0.24))
		var reach_at: Vector4 = fidget.get("reach", Vector4(0.08, 0.28, 0.64, 0.8))
		var let_go: Vector2 = fidget.get("let_go", Vector2(0.6, 0.68))
		var lift := _fidget_in_out(lift_at.x, lift_at.y, lift_at.z, lift_at.w)
		if lift <= 0.0:
			_fidget_hang = (_bob - pivot).normalized()
		else:
			var forward := deg_to_rad(float(fidget["lift_degrees"]))
			# Leaned a little away from the body's middle, to the side the hook is on: turning,
			# the lantern's top cap (by the hook, 7-9 cm down it) swung its corner 2.2 cm into
			# the belly, left foot forward (Kirill). A bigger lift only raised the cap toward it,
			# turning the other way clipped with either foot; 20 deg of lean left 1.3 cm, 35
			# left 0.3 (the belly taken as 15 cm round the spine line). With the hook moved onto
			# the belt (1.4 cm nearer the middle, 2026-10-14) 35 left 1.4 cm: now 50 deg of lean
			# and a 50 deg lift (about 35 as reached): the cap 0.7 cm clear through the turn.
			var hips := bones * _skeleton.get_bone_global_pose(_hips_bone).origin
			# A turn about +Z by a positive angle moves the lantern to the RIGHT (+X).
			var away := signf(pivot.x - hips.x) if absf(pivot.x - hips.x) > 0.005 else -1.0
			var lifted := Basis(Vector3.BACK, away * deg_to_rad(float(fidget.get("lean_degrees", 0.0)))) * Vector3(0.0, -cos(forward), -sin(forward))
			_bob = pivot + _fidget_hang.slerp(lifted, lift) * LANTERN_ARM
			_bob_before = _bob
		# One turn about its own long axis and back, starting and ending at rest.
		var turning := clampf((at - turn_at.x) / turn_at.y, 0.0, 1.0)
		_lantern_spin = deg_to_rad(float(fidget["turn_degrees"])) * (0.5 - 0.5 * cos(TAU * turning)) * _fidget_fade
		# The hand leaves while the lantern is still settling: from 0.75 it rested on the hanging
		# lantern a moment first -- "a pause before letting go" (Kirill).
		# And it leaves OUTWARD first, off the lantern's side, and on down to the clip's in one
		# move: dropping straight back toward the hip it dragged the thumb 3 cm through the
		# lantern; and with the way down spread to 0.9 the hand hung by the lantern 4 cm from its
		# rest while the view came up -- "hovering" (Kirill). Both end by 0.8 now.
		var reach := _fidget_in_out(reach_at.x, reach_at.y, reach_at.z, reach_at.w)
		var leave := _ease(let_go.x, let_go.y, at)
		# The hand is what turns it: the palm on the lantern's SIDE (the cup's way squared to the
		# lantern's axis -- lifted, "behind" lies nearly along the axis and turning it there
		# moved the palm 1 deg), and its place and facing go round the axis with it (Kirill:
		# "the lantern turns without the hand moving").
		var cup := toggle_cup_offset if toggle_cup_offset.length_squared() > 0.0001 else Vector3.BACK
		var axis := (pivot - _bob).normalized()
		var outward := cup - axis * cup.dot(axis)
		if outward.length_squared() < 0.0001:
			outward = axis.cross(Vector3.RIGHT)
		outward = outward.normalized()
		var with_spin := Basis(axis, _lantern_spin)
		_reach(arm, "palm", bones, _bob + with_spin * outward * (LANTERN_RADIUS + 0.006 + 0.07 * leave), reach, TOGGLE_ELBOW, with_spin * -outward)
		# Letting go the fingers OPEN first, and go back to the clip's hand only once the hand is
		# mostly away: blended straight from the cup to the clip's near-fist, the thumb closed
		# through the lantern (Kirill). The thumb curls less than in toggle_lantern: with the palm
		# on the lantern's side it wrapped 1.5 cm into it.
		var open := _ease(let_go.x, let_go.y, at)
		var curl := lerpf(toggle_cup_curl, toggle_open_curl, open)
		_set_fingers(arm, [curl * 0.3, curl, curl, curl, curl], _ease(0.0, 0.6, reach))

## The sword arm's fist place and hand turn for the fidget playing, from the stance's (both in
## the Player's space, as WeaponHold.solve_arm takes them). Returns [hand, turn].
func _fidget_pose(hand: Vector3, turn: Basis, held_from: Vector3, with_view: Basis) -> Array:
	var fidget: Dictionary = FIDGETS[_fidget]
	var at := clampf(_fidget_at / float(fidget["time"]), 0.0, 1.0)
	# The blade's and the edge's ways in the hand turn's own axes (the grip's +Y and +X; see
	# WeaponHold.solve_arm for how a turn becomes the hand bone's).
	var axes := WeaponHold.hand_axes(_skeleton, "Right")
	var palm_side := -1.0 if (axes["fingers_out"] as Vector3).cross(axes["palm_out"] as Vector3).dot(axes["thumb_side"] as Vector3) > 0.0 else 1.0
	var to_turn := Basis(Vector3(0, 0, -1), Vector3(palm_side, 0, 0), Vector3(0, 1, 0)) * Basis(axes["fingers_out"] as Vector3, axes["palm_out"] as Vector3, axes["thumb_side"] as Vector3).inverse()
	var blade_in_turn := (to_turn * _weapon_socket.basis.y).normalized()
	var edge_in_turn := (to_turn * _weapon_socket.basis.x).normalized()
	var to_hand := hand
	var to_frame := Basis.IDENTITY # the turn applied to the stance's hand turn
	if fidget.has("keys"):
		# ONE smooth curve from the stance through every key and back to it, eased once over the
		# whole: it starts and ends at rest and does not stop at a key. (Eased key to key it
		# stopped at each, and the way back from the last key read as a separate move -- Kirill,
		# 2026-10-14.) The keys' shares are of the eased time.
		var blade_now := (turn * blade_in_turn).normalized()
		var edge_now := (turn * edge_in_turn).normalized()
		var times: Array[float] = [0.0]
		var places: Array[Vector3] = [hand]
		var blades: Array[Vector3] = [blade_now]
		var edges: Array[Vector3] = [edge_now]
		for key: Array in fidget["keys"]:
			times.append(float(key[0]))
			places.append(held_from + with_view * (key[1] as Vector3))
			blades.append((with_view * (key[2] as Vector3)).normalized())
			edges.append((with_view * (key[3] as Vector3)).normalized())
		times.append(1.0)
		places.append(hand)
		blades.append(blade_now)
		edges.append(edge_now)
		var eased := _ease(0.0, 1.0, at)
		if fidget.has("key_times"):
			# Each key reached at its own moment ("key_times", shares of the time): one smooth
			# curve through them, at rest at both ends, never stopping at a key.
			var at_times: Array[float] = [0.0]
			for share: float in fidget["key_times"]:
				at_times.append(share)
			at_times.append(1.0)
			eased = _smooth_through(at_times, times, at)
		eased = _key_paced(times, eased)
		to_hand = _through(places, times, eased)
		var frame := _blade_frame(_through(blades, times, eased), _through(edges, times, eased))
		to_frame = frame * _blade_frame(blade_now, edge_now).inverse()
	else:
		# ONE motion: the circling runs over the whole time, eased once, and the tilt grows up to
		# "from" and shrinks after "to" while it goes on -- the blade spirals out into the
		# circles and back in. (Tilt, circles and tilt back eased each on its own stopped the
		# tip twice, to 0.06 m/s at the end of the circles -- Kirill, 2026-10-14.)
		var circle: Dictionary = fidget["circle"]
		var amount := _ease(0.0, float(circle["from"]), at) * (1.0 - _ease(float(circle["to"]), 1.0, at))
		var angle := _ease(0.0, 1.0, at) * TAU * float(circle["turns"])
		var blade_now := (turn * blade_in_turn).normalized()
		var across := blade_now.cross(with_view * Vector3.UP)
		if across.length_squared() < 0.0001:
			across = blade_now.cross(with_view * Vector3.BACK)
		across = across.normalized()
		var other := blade_now.cross(across).normalized()
		var axis := (across * cos(angle) + other * sin(angle)).normalized()
		to_frame = Basis(axis, deg_to_rad(float(circle["tilt_degrees"])) * amount)
		to_hand = hand + (with_view * Vector3(cos(angle), sin(angle), 0.0)) * float(circle["hand"]) * amount
	var weight := _fidget_fade
	var turned := (to_frame * turn).orthonormalized()
	return [hand.lerp(to_hand, weight), Basis(turn.get_rotation_quaternion().slerp(turned.get_rotation_quaternion(), weight))]

## A frame from a blade's way (+Y) and its edge's (+X, squared to the blade).
static func _blade_frame(blade: Vector3, edge: Vector3) -> Basis:
	var y := blade.normalized()
	var x := edge - y * edge.dot(y)
	if x.length_squared() < 0.0001:
		x = y.cross(Vector3.BACK)
	x = x.normalized()
	return Basis(x, y, x.cross(y))

## Puts a weapon in the right hand, in place of the one held (null: none). Any WeaponData
## fits: the hand's socket is worked out from its bones (WeaponHold).
func equip(data: WeaponData) -> void:
	if _weapon_node:
		_weapon_node.queue_free()
		_weapon_node = null
	weapon = data
	if data == null or data.scene == null:
		return
	_weapon_socket = WeaponHold.socket(_skeleton, "Right", data.grip_radius)
	_chest_bone = _skeleton.find_bone("UpperChest")
	_weapon_fist = WeaponHold.fist_curls(_skeleton, "Right", data.grip_radius)
	# Placed by this script in the same frame as the pose, like the lantern.
	_weapon_node = data.scene.instantiate() as Node3D
	add_child(_weapon_node)
	_weapon_node.top_level = true
	_weapon_shadow = _shadow_of(data, _weapon_shadow)
	# The box its meshes fill, in its own axes (weapon_body_clearance).
	var first := true
	for mesh: MeshInstance3D in _weapon_node.find_children("*", "MeshInstance3D", true, false):
		var box := mesh.mesh.get_aabb()
		var in_model := _weapon_node.global_transform.affine_inverse() * mesh.global_transform
		for corner in 8:
			var point := in_model * box.get_endpoint(corner)
			_weapon_low = point if first else _weapon_low.min(point)
			_weapon_high = point if first else _weapon_high.max(point)
			first = false
	if _lantern_light:
		for mesh: MeshInstance3D in _weapon_node.find_children("*", "MeshInstance3D", true, false):
			mesh.layers = 1 << (BODY_LAYER - 1)

## A copy of a held thing's model that is never seen and only casts a shadow (in place of
## `old`, which is freed): for the shadow body's hands, see weapon_shadow_reach.
func _shadow_of(data: WeaponData, old: Node3D) -> Node3D:
	if old:
		old.queue_free()
	var copy := data.scene.instantiate() as Node3D
	add_child(copy)
	copy.top_level = true
	copy.visible = false
	for mesh: MeshInstance3D in copy.find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mesh.layers = 1 << (BODY_LAYER - 1)
	return copy

## Puts a shield on the left arm, in place of the one carried (null: none).
func equip_shield(data: WeaponData) -> void:
	if _shield_node:
		_shield_node.queue_free()
		_shield_node = null
	shield = data
	if data == null or data.scene == null:
		return
	if data.on_forearm:
		_shield_bone = _arms["Left"]["lower"]
		_shield_socket = WeaponHold.forearm_socket(_skeleton, "Left")
		_shield_now = _shield_socket
	else:
		_shield_bone = _arms["Left"]["hand"]
		_shield_socket = WeaponHold.socket(_skeleton, "Left", data.grip_radius)
		_shield_now = _shield_socket
	_shield_socket_set = false
	_shield_node = data.scene.instantiate() as Node3D
	add_child(_shield_node)
	_shield_node.top_level = true
	_shield_shadow = _shadow_of(data, _shield_shadow)
	# The corners of its meshes' boxes and the middles of the boxes' edges and faces.
	_shield_points = PackedVector3Array()
	for mesh: MeshInstance3D in _shield_node.find_children("*", "MeshInstance3D", true, false):
		var box := mesh.mesh.get_aabb()
		var in_model := _shield_node.global_transform.affine_inverse() * mesh.global_transform
		for x in 3:
			for y in 3:
				for z in 3:
					_shield_points.append(in_model * (box.position + box.size * Vector3(x, y, z) * 0.5))
	# Its rim, for a hand to grip (the strap fidget): the vertices in the outer 8 % of the board
	# from its middle, measured across the board's face.
	_shield_rim = PackedVector3Array()
	var all_points := PackedVector3Array()
	for mesh: MeshInstance3D in _shield_node.find_children("*", "MeshInstance3D", true, false):
		var in_model := _shield_node.global_transform.affine_inverse() * mesh.global_transform
		for surface in mesh.mesh.get_surface_count():
			for v: Vector3 in mesh.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
				all_points.append(in_model * v)
	if not all_points.is_empty():
		var low := all_points[0]
		var high := all_points[0]
		for point in all_points:
			low = low.min(point)
			high = high.max(point)
		var size := high - low
		var thin := size.min_axis_index()
		_shield_face = Vector3.ZERO
		_shield_face[thin] = 1.0
		_shield_rim_middle = (low + high) * 0.5
		_shield_length = Vector3.ZERO
		_shield_length[size.max_axis_index()] = 1.0
		# The OUTLINE: the board split into 90 slices by angle round its middle, and in each the
		# vertices within 1 cm of the outermost. (Keeping the outer 8 % by distance from the
		# middle kept only the top corners and the bottom tip of a shield taller than it is
		# wide: its sides, where Kirill marked the grip, were never candidates.)
		var a := (thin + 1) % 3
		var b := (thin + 2) % 3
		var slices := 90
		var outermost: Array[float] = []
		outermost.resize(slices)
		outermost.fill(0.0)
		var slice_of := func(point: Vector3) -> int:
			var across := point - _shield_rim_middle
			return int(floor((atan2(across[b], across[a]) + PI) / TAU * slices)) % slices
		var radius_of := func(point: Vector3) -> float:
			var across := point - _shield_rim_middle
			across[thin] = 0.0
			return across.length()
		for point in all_points:
			var slice: int = slice_of.call(point)
			outermost[slice] = maxf(outermost[slice], radius_of.call(point))
		for point in all_points:
			if float(radius_of.call(point)) >= outermost[slice_of.call(point)] - 0.01:
				_shield_rim.append(point)
	if _lantern_light:
		for mesh: MeshInstance3D in _shield_node.find_children("*", "MeshInstance3D", true, false):
			mesh.layers = 1 << (BODY_LAYER - 1)

## The left arm carries the shield: up with the weapon, in the stance set by hand in the
## ShieldStance node (the fist at a place from the eyes, the arm setting off from the body's
## own shoulder as the weapon's does), over whatever clip plays.
func _hold_shield(player: Node3D, delta: float) -> void:
	var arm: Dictionary = _arms["Left"]
	_skeleton.set_bone_pose_position(arm["upper"], _skeleton.get_bone_rest(arm["upper"]).origin)
	_skeleton.set_bone_pose_scale(arm["upper"], Vector3.ONE) # _draw_arm_apart shrank it last frame
	_shield_shoulder_drawn = 0.0
	if _shield_node == null:
		_shield_up = 0.0
		return
	# With a weapon drawn from the back the shield takes the draw's time, not its own quick
	# one, and starts a little into it: it and the weapon settle in the same frame.
	var with_draw := weapon_sheath_on_back and _weapon_node != null
	_shield_up = move_toward(_shield_up, 1.0 if weapon_raised and _shield_stance else 0.0, delta / maxf(weapon_draw_time if with_draw else weapon_raise_time, 0.01))
	var weight := smoothstep(shield_raise_from if with_draw else 0.0, 1.0, _shield_up)
	if shield.on_forearm and _shield_stance and not _shield_socket_set:
		_shield_socket_from_stance(arm, player)
	# The relaxed carry first: what the stance is blended with below is the arm so carried.
	var relaxed := shield_relaxed_carry and shield.on_forearm and _shield_stance != null and _shield_socket_set
	if relaxed:
		_relax_shield_arm(arm, player)
		_keep_relaxed_off_body(arm, player, delta)
	_shield_now = _shield_socket
	if weight <= 0.001:
		_shield_push = _shield_push.lerp(Vector3.ZERO, 1.0 - exp(-delta / maxf(shield_clearance_return, 0.001)))
		if relaxed:
			_shield_stance.pose_fingers(_skeleton, shield.grip_radius)
		return
	var arm_bones: Array[int] = [arm["upper"], arm["lower"], arm["hand"]]
	var in_clip: Array = [_skeleton.get_bone_pose_position(arm["upper"])]
	for bone in arm_bones:
		in_clip.append(_skeleton.get_bone_pose_rotation(bone))
	var to_skeleton := (player.global_transform.affine_inverse() * _skeleton.global_transform).affine_inverse()
	var held_from := _eye + _bob_now + _breath_now * shield_breathing
	var fist := _shield_stance.fist_in_hand(_skeleton, shield.grip_radius)
	if weapon_shoulder_on_body:
		var own_shoulder := _skeleton.get_bone_global_pose(arm["upper"]).origin
		WeaponHold.solve_arm(_skeleton, "Left", to_skeleton, to_skeleton.affine_inverse() * own_shoulder, held_from + _shield_stance.hand_from_eyes(), _shield_stance.elbow_toward(), _shield_stance.hand_turn(), fist, weapon_body_reach)
		_shield_shoulder_drawn = _skeleton.get_bone_global_pose(arm["upper"]).origin.distance_to(own_shoulder)
	else:
		var with_view := Basis(Vector3.RIGHT, _look_pitch * weapon_follows_view)
		# A shield fidget moves the stance's hand and shoulder and rolls the forearm (_shield_fidget_pose).
		var hand_from := _shield_stance.hand_from_eyes()
		var shoulder_from := _shield_stance.shoulder_from_eyes()
		var shield_turn := with_view * _shield_stance.hand_turn()
		var fidgeting := _fidget != &"" and (FIDGETS[_fidget] as Dictionary).has("shield_keys")
		var roll := 0.0
		var twist := 0.0
		if fidgeting:
			var posed := _shield_fidget_pose()
			hand_from += posed[0]
			shoulder_from += posed[1]
			roll = (posed[2] as float) * _glance_sign
			twist = posed[3]
		for attempt in 2:
			var from := held_from + (_shield_push if attempt == 1 else Vector3.ZERO)
			WeaponHold.solve_arm(_skeleton, "Left", to_skeleton, from + with_view * shoulder_from, from + with_view * hand_from,
					with_view * _shield_stance.elbow_toward(), shield_turn, fist, _shield_stance.max_reach)
			if absf(roll) > 0.0001:
				# The forearm rolled about its own line as solved, the hand and the shield with it.
				# (A turn of the asked hand about the stance's forearm line went partly into the
				# wrist once the hand had moved: the face stopped turning at about 70 deg.)
				var lower := _skeleton.get_bone_global_pose(arm["lower"])
				var along := (_skeleton.get_bone_global_pose(arm["hand"]).origin - lower.origin).normalized()
				lower.basis = Basis(along, roll) * lower.basis
				_skeleton.set_bone_global_pose(arm["lower"], lower)
			if absf(twist) > 0.0001:
				# The shield turned about the line along its length through its middle (Kirill:
				# "along the shield's length in the middle"; turned about its face's axis it spun
				# flat, and turned from the elbow it slid aside): the forearm turned that way,
				# then the whole arm moved back by what that moved the shield's middle (the drawn
				# arm's shoulder is placed anyway).
				var lower := _skeleton.get_bone_global_pose(arm["lower"])
				var board := lower * WeaponHold.in_hand(_shield_socket, shield)
				var middle := board * _shield_rim_middle
				var axis := (board.basis * _shield_length).normalized()
				if axis.dot(to_skeleton.basis * Vector3.UP) < 0.0:
					axis = -axis # toward its upper end: a positive twist moves the side facing the eyes to the right
				lower.basis = Basis(axis, twist) * lower.basis
				_skeleton.set_bone_global_pose(arm["lower"], lower)
				var moved := (_skeleton.get_bone_global_pose(arm["lower"]) * WeaponHold.in_hand(_shield_socket, shield)) * _shield_rim_middle - middle
				var upper := _skeleton.get_bone_global_pose(arm["upper"])
				upper.origin -= moved
				_skeleton.set_bone_global_pose(arm["upper"], upper)
			if shield.on_forearm and not fidgeting:
				# Read every frame, with the arm fully in the stance (before the blend with the
				# clip): the Grip marker can be changed while the game runs. Not during a shield
				# fidget, whose arm is not in the stance.
				_shield_socket = _shield_stance.forearm_socket(_skeleton, shield.grip_radius)
				_shield_socket_set = true
				_shield_hand_in_stance = _skeleton.get_bone_pose_rotation(arm["hand"])
			if attempt == 1:
				break
			# The first solve is the stance as set: how far it has to move to clear the body.
			var wanted := _shield_off_body(to_skeleton.affine_inverse(), _shield_socket) if shield_body_clearance > 0.0 else Vector3.ZERO
			_shield_push = _shield_push.lerp(wanted, 1.0 - exp(-delta / maxf(shield_clearance_ease if wanted.length() > _shield_push.length() else shield_clearance_return, 0.001)))
			if _shield_push.length() < 0.001:
				break
			_skeleton.set_bone_pose_position(arm["upper"], in_clip[0] as Vector3)
			for i in arm_bones.size():
				_skeleton.set_bone_pose_rotation(arm_bones[i], in_clip[i + 1] as Quaternion)
	if shield.on_forearm and weapon_shoulder_on_body:
		_shield_socket = _shield_stance.forearm_socket(_skeleton, shield.grip_radius)
	if weight < 0.999:
		_skeleton.set_bone_pose_position(arm["upper"], (in_clip[0] as Vector3).lerp(_skeleton.get_bone_pose_position(arm["upper"]), weight))
		for i in arm_bones.size():
			_skeleton.set_bone_pose_rotation(arm_bones[i], (in_clip[i + 1] as Quaternion).slerp(_skeleton.get_bone_pose_rotation(arm_bones[i]), weight))
	if weight > 0.5 or relaxed:
		_shield_stance.pose_fingers(_skeleton, shield.grip_radius)
	_shield_now = _shield_socket
	if weight >= 0.999 and not weapon_shoulder_on_body and (_fidget == &"" or not (FIDGETS[_fidget] as Dictionary).has("shield_keys")):
		_read_glance_axes(player)

## For the shield fidgets, from the arm in the stance: the forearm's line (the Player's axes) and
## which way a roll about it turns the shield's face toward the eyes (_glance_sign).
func _read_glance_axes(player: Node3D) -> void:
	var arm: Dictionary = _arms["Left"]
	var to_player := player.global_transform.affine_inverse() * _skeleton.global_transform
	var lower := _skeleton.get_bone_global_pose(arm["lower"])
	var wrist := _skeleton.get_bone_global_pose(arm["hand"]).origin
	var forearm := (to_player.basis * (wrist - lower.origin)).normalized()
	var placed := to_player * lower * _shield_socket
	var faces := (to_player.basis * lower.basis.orthonormalized() * _shield_socket.basis.x).normalized()
	var turning := forearm.cross(faces).dot(_eye - placed.origin)
	if forearm.is_finite() and absf(turning) > 0.000001:
		_shield_forearm_axis = forearm
		_glance_sign = signf(turning)

## The shield fidget playing: [the hand moved, the shoulder moved (both in the stance's axes),
## the forearm's roll (radians)], through "shield_keys" as _fidget_pose goes through the sword's.
func _shield_fidget_pose() -> Array:
	var fidget: Dictionary = FIDGETS[_fidget]
	if fidget.has("hold"):
		# One peak (the first key), eased in by "hold".x, held, eased out from "hold".y.
		var hold: Vector2 = fidget["hold"]
		var peak: Array = (fidget["shield_keys"] as Array)[0]
		var amount := _fidget_in_out(0.0, hold.x, hold.y, 1.0)
		var twisted := 0.0
		if fidget.has("twist"):
			# Turned on through the hold, and unwound with the way back.
			var twist: Vector3 = fidget["twist"]
			twisted = deg_to_rad(twist.x) * _ease(twist.y, twist.z, _fidget_share()) * (1.0 - _ease(hold.y, 1.0, _fidget_share())) * _fidget_fade
		return [(peak[1] as Vector3) * amount, (peak[3] as Vector3) * amount, deg_to_rad(float(peak[2])) * amount, twisted]
	var times: Array[float] = [0.0]
	var hands: Array[Vector3] = [Vector3.ZERO]
	var shoulders: Array[Vector3] = [Vector3.ZERO]
	var rolls: Array[Vector3] = [Vector3.ZERO]
	for key: Array in fidget["shield_keys"]:
		times.append(float(key[0]))
		hands.append(key[1] as Vector3)
		rolls.append(Vector3(deg_to_rad(float(key[2])), 0.0, 0.0))
		shoulders.append(key[3] as Vector3)
	times.append(1.0)
	hands.append(Vector3.ZERO)
	shoulders.append(Vector3.ZERO)
	rolls.append(Vector3.ZERO)
	var eased := _key_paced(times, _ease(0.0, 1.0, _fidget_share()))
	return [_through(hands, times, eased) * _fidget_fade, _through(shoulders, times, eased) * _fidget_fade, _through(rolls, times, eased).x * _fidget_fade, 0.0]

## Where the shield sits on the forearm depends on the ShieldStance's Grip marker, which is
## read with the arm in its stance. Until the arm had been there once the shield sat as the
## model's data alone has it (2.5 cm and 39 deg off, measured) -- for the first moments of a
## game, or for as long as the weapons stayed down. So, once: the arm into the stance, the
## place read, the arm back as the clip has it.
func _shield_socket_from_stance(arm: Dictionary, player: Node3D) -> void:
	var arm_bones: Array[int] = [arm["upper"], arm["lower"], arm["hand"]]
	var in_clip: Array = [_skeleton.get_bone_pose_position(arm["upper"])]
	for bone in arm_bones:
		in_clip.append(_skeleton.get_bone_pose_rotation(bone))
	var to_skeleton := (player.global_transform.affine_inverse() * _skeleton.global_transform).affine_inverse()
	_shield_stance.pose(_skeleton, to_skeleton, _eye, _shield_stance.fist_in_hand(_skeleton, shield.grip_radius))
	_shield_socket = _shield_stance.forearm_socket(_skeleton, shield.grip_radius)
	_shield_socket_set = true
	_shield_hand_in_stance = _skeleton.get_bone_pose_rotation(arm["hand"])
	_skeleton.set_bone_pose_position(arm["upper"], in_clip[0] as Vector3)
	for i in arm_bones.size():
		_skeleton.set_bone_pose_rotation(arm_bones[i], in_clip[i + 1] as Quaternion)

## The relaxed carry (shield_relaxed_carry), on the arm as the clip has just posed it: the
## forearm rolled about its own line until the shield's face looks as nearly as it can away
## from the body (see shield_relaxed_faces), and the hand put on the forearm as it is in the
## stance.
func _relax_shield_arm(arm: Dictionary, player: Node3D) -> void:
	var in_player := player.global_transform.affine_inverse() * _skeleton.global_transform
	var lower := _skeleton.get_bone_global_pose(arm["lower"])
	var wrist := _skeleton.get_bone_global_pose(arm["hand"]).origin
	var along := (in_player.basis * (wrist - lower.origin)).normalized() # the forearm's line
	var faces := (in_player.basis.orthonormalized() * (lower.basis.orthonormalized() * _shield_socket.basis.x)).normalized()
	var arm_at := in_player * ((lower.origin + wrist) * 0.5)
	var hips := in_player * _skeleton.get_bone_global_pose(_hips_bone).origin
	var chest := in_player * _skeleton.get_bone_global_pose(_skeleton.find_bone("UpperChest")).origin
	var trunk := chest - hips
	var out := arm_at - (hips + trunk * clampf((arm_at - hips).dot(trunk) / maxf(trunk.length_squared(), 0.0001), 0.0, 1.0))
	out.y = 0.0
	var away := out.normalized() if out.length() > 0.05 else shield_relaxed_faces.normalized()
	var wanted := away - along * away.dot(along)
	var seen := faces - along * faces.dot(along)
	if wanted.length() > 0.05 and seen.length() > 0.05: # else the forearm points the very way the face should look, or the shield's face lies along it: no roll helps
		var roll := seen.normalized().signed_angle_to(wanted.normalized(), along)
		lower.basis = Basis((wrist - lower.origin).normalized(), roll) * lower.basis
		_skeleton.set_bone_global_pose(arm["lower"], lower)
	_skeleton.set_bone_pose_rotation(arm["hand"], _shield_hand_in_stance)

## The relaxed carry is the clip's arm, and the backward jogs swing it into the left thigh (8-9 cm
## measured; Kirill, 2026-10-14: "the shield seems to clip through body ... when sheathed"). The
## same keep-off as the stance's (_shield_off_body, eased the same way), but as the arm hangs
## from the body's own shoulder it is swung out from there by it instead of moved bodily.
func _keep_relaxed_off_body(arm: Dictionary, player: Node3D, delta: float) -> void:
	_relaxed_push = _swing_shield_off_body(arm, player, delta, _relaxed_push)

## The keep-off of _keep_relaxed_off_body: `pushed` is how far the board is moved off the body
## until now (eased); returns it for this frame, the arm swung out by it.
## `amount` scales the swing only, not the push kept.
func _swing_shield_off_body(arm: Dictionary, player: Node3D, delta: float, pushed: Vector3, amount: float = 1.0) -> Vector3:
	var in_player := player.global_transform.affine_inverse() * _skeleton.global_transform
	# The shortest of three ways out: straight left only, the back-left and back-right jogs hold
	# the board facing more ahead than out, and it was swung 0.4 m (34 deg) to clear the leg.
	var wanted := Vector3.ZERO
	if shield_body_clearance > 0.0:
		wanted = Vector3.INF
		for toward: Vector3 in [shield_clear_toward, shield_clear_toward + Vector3.FORWARD, shield_clear_toward + Vector3.BACK]:
			var push := _shield_off_body(in_player, _shield_socket, toward)
			if push.length() < wanted.length():
				wanted = push
	pushed = pushed.lerp(wanted, 1.0 - exp(-delta / maxf(shield_clearance_ease if wanted.length() > pushed.length() else shield_clearance_return, 0.001)))
	if pushed.length() * amount < 0.001:
		return pushed
	var upper := _skeleton.get_bone_global_pose(arm["upper"])
	var shoulder := in_player * upper.origin
	var board := in_player * (_skeleton.get_bone_global_pose(_shield_bone) * WeaponHold.in_hand(_shield_socket, shield)).origin
	var reach := board - shoulder
	var axis := reach.cross(pushed)
	if axis.length_squared() < 0.00000001:
		return pushed
	# Turned about the shoulder so the board's middle moves about as far as the push asks.
	upper.basis = Basis((in_player.basis.inverse() * axis).normalized(), atan2(pushed.length() * amount, reach.length())) * upper.basis
	_skeleton.set_bone_global_pose(arm["upper"], upper)
	return pushed

## How far the shield, as the arm holds it just now, has to be moved along shield_clear_toward
## (the Player's axes) for the body to be clear of it: no point of the trunk's middle line
## (hips to chest) nearer than shield_body_clearance to the shield's box, none of a leg's (hip,
## knee, ankle) nearer than half of that. It is needed because the stance, turned down with the
## view about the eyes, swings back under them, which is where the body is. (Moving it away from the nearest
## point of the body instead left the board cutting through: a board is wide, and the body
## was pushed out on one side of a point and in on the other.) `to_player` brings the
## skeleton's space into the Player's.
func _shield_off_body(to_player: Transform3D, on_arm: Transform3D, toward: Vector3 = Vector3.ZERO) -> Vector3:
	var board := to_player * _skeleton.get_bone_global_pose(_shield_bone) * WeaponHold.in_hand(on_arm, shield)
	if toward.length() < 0.001:
		toward = shield_clear_toward
	var low := _shield_points[0]
	var high := _shield_points[0]
	for point in _shield_points:
		low = low.min(point)
		high = high.max(point)
	return _keep_off_body(to_player, board, low, high, toward, shield_body_clearance, shield_leg_clearance if shield_leg_clearance >= 0.0 else shield_body_clearance * 0.5)

## How far the held weapon placed at `held` (the Player's space) has to be moved FORWARD,
## level with the ground, for the body to be clear of it: the weapon taken as a capsule along
## the longest side of its model's box (_weapon_low.._weapon_high; for a sword, pommel to tip),
## as thick as the box's thinner side, kept weapon_body_clearance from the trunk's middle line
## and weapon_leg_clearance from the legs'. The smallest such move, found by halving. A capsule's
## distance changes smoothly as the weapon turns; the shield's box test (_keep_off_body) jumps
## by centimetres as the side the box leaves by changes, and the push looked choppy (Kirill).
func _weapon_off_body(to_player: Transform3D, held: Transform3D) -> Vector3:
	var size := _weapon_high - _weapon_low
	var axis := size.max_axis_index()
	var middle := (_weapon_low + _weapon_high) * 0.5
	var a := middle
	var b := middle
	a[axis] = _weapon_low[axis]
	b[axis] = _weapon_high[axis]
	var thin := INF
	for other in 3:
		if other != axis:
			thin = minf(thin, size[other] * 0.5)
	var start := held * a
	var end := held * b
	var hips := to_player * _skeleton.get_bone_global_pose(_hips_bone).origin
	var lines: Array = [[hips, to_player * _skeleton.get_bone_global_pose(_skeleton.find_bone("UpperChest")).origin, weapon_body_clearance]]
	for leg: Dictionary in _legs:
		var knee := to_player * _skeleton.get_bone_global_pose(leg["lower"]).origin
		lines.append([to_player * _skeleton.get_bone_global_pose(leg["upper"]).origin, knee, weapon_leg_clearance])
		lines.append([knee, to_player * _skeleton.get_bone_global_pose(leg["foot"]).origin, weapon_leg_clearance])
	var room := func(slide: float) -> float:
		var least := INF
		for line: Array in lines:
			var near := Geometry3D.get_closest_points_between_segments(start + Vector3.FORWARD * slide, end + Vector3.FORWARD * slide, line[0], line[1])
			least = minf(least, near[0].distance_to(near[1]) - thin - (line[2] as float))
		return least
	if room.call(0.0) >= 0.0:
		return Vector3.ZERO
	var low := 0.0
	var high := 1.0
	if room.call(high) < 0.0:
		return Vector3.FORWARD * high
	for i in 16:
		var middle_slide := (low + high) * 0.5
		if room.call(middle_slide) >= 0.0:
			high = middle_slide
		else:
			low = middle_slide
	return Vector3.FORWARD * high

## A damped spring from `now` toward `target` (weapon_clearance_smoothing; _weapon_push_speed
## is its speed): it starts and stops gently, the same both ways.
func _spring(now: Vector3, target: Vector3, delta: float) -> Vector3:
	var omega := 2.0 / maxf(weapon_clearance_smoothing, 0.001)
	var x := omega * delta
	var decay := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := now - target
	var temp := (_weapon_push_speed + omega * change) * delta
	_weapon_push_speed = (_weapon_push_speed - omega * temp) * decay
	return target + (change + temp) * decay

## How far a held thing placed at `item` (the Player's space), whose model fills the box
## `low`..`high` in its own axes, has to be moved along `toward` (the Player's axes) for the
## body to be clear of it: no point of the trunk's middle line (hips to chest) nearer than
## `trunk` to the box, none of a leg's (hip, knee, ankle) nearer than `legs`. The shield's and
## the weapon's keep-off both use it, so it works for any model. `to_player` brings the
## skeleton's space into the Player's.
func _keep_off_body(to_player: Transform3D, item: Transform3D, low: Vector3, high: Vector3, toward: Vector3, trunk: float, legs: float) -> Vector3:
	var to_board := item.affine_inverse()
	var way := toward.normalized() if toward.length() > 0.001 else Vector3.LEFT
	var forward := (to_board.basis * way).normalized() # the way it moves, in the item's own axes
	var hips := _skeleton.get_bone_global_pose(_hips_bone).origin
	var lines: Array = [[hips, _skeleton.get_bone_global_pose(_skeleton.find_bone("UpperChest")).origin, trunk]]
	var leg_clearance := legs
	for leg: Dictionary in _legs:
		var knee := _skeleton.get_bone_global_pose(leg["lower"]).origin
		lines.append([_skeleton.get_bone_global_pose(leg["upper"]).origin, knee, leg_clearance])
		lines.append([knee, _skeleton.get_bone_global_pose(leg["foot"]).origin, leg_clearance])
	# Points along those lines, in the item's own axes, each with its clearance.
	var body_points: Array = []
	for line: Array in lines:
		for step in 6:
			body_points.append([to_board * (to_player * (line[0] as Vector3).lerp(line[1] as Vector3, step / 5.0)), line[2]])
	var slide := 0.0
	for round_index in 4: # a move forward can bring the board onto a point further forward
		var more := 0.0
		for body_point: Array in body_points:
			var at: Vector3 = (body_point[0] as Vector3) - forward * slide # the shield moved forward = the point moved back
			var margin := Vector3.ONE * (body_point[1] as float)
			if at.x <= low.x - margin.x or at.x >= high.x + margin.x or at.y <= low.y - margin.y or at.y >= high.y + margin.y or at.z <= low.z - margin.z or at.z >= high.z + margin.z:
				continue
			# Inside the box grown by its clearance: how far until it is out of it by one side.
			var out := INF
			for axis in 3:
				if forward[axis] > 0.001:
					out = minf(out, (at[axis] - (low[axis] - margin[axis])) / forward[axis])
				elif forward[axis] < -0.001:
					out = minf(out, (at[axis] - (high[axis] + margin[axis])) / forward[axis])
			if out < INF:
				more = maxf(more, out)
		if more <= 0.0:
			break
		slide += more + 0.001
	return way * minf(slide, 1.0)

## The right hand holds the weapon: the fist closed round it always, and (weapon_raised) the
## arm in the stance set by hand in the WeaponStance node, over whatever clip plays -- shoulder
## and fist at places set from the eyes, so the weapon keeps its place in the picture. Where
## the weapon points is what that arm gives it. It does not follow the camera's pitch.
func _hold_weapon(player: Node3D, delta: float) -> void:
	var arm: Dictionary = _arms["Right"]
	# The stance moves the shoulder bodily and no clip has a track that would move it back
	# (measured: a second after lowering the weapon the bone was still 0.3 m off): each frame
	# starts with it at rest on the body.
	_skeleton.set_bone_pose_position(arm["upper"], _skeleton.get_bone_rest(arm["upper"]).origin)
	_skeleton.set_bone_pose_scale(arm["upper"], Vector3.ONE) # _draw_arm_apart shrank it last frame
	_bob_now = Vector3.ZERO
	if _weapon_node == null:
		_weapon_up = 0.0
		return
	if weapon_reference_clip != _reference_path:
		_reference_path = weapon_reference_clip
		_reference = ArmClip.from_file(weapon_reference_clip)
	var reference: ArmClip = _reference if weapon_arm_from_reference else null
	var frame := {}
	if reference:
		_reference_time += delta
		frame = reference.sample(_reference_time)
		# The weapon as the clip has it in the hand. The clip's hand axes (-X the palm, +Y the
		# thumb's side, -Z the fingers) in the hand bone's, as in WeaponStance.socket.
		var grip: Transform3D = frame["grip"]
		var marker := Basis(-(arm["palm_out"] as Vector3), (arm["fingers_out"] as Vector3).cross(arm["palm_out"] as Vector3), -(arm["fingers_out"] as Vector3))
		_weapon_socket = Transform3D(marker * grip.basis * WeaponStance.SOCKET_IN_GRIP, marker * grip.origin)
	elif _stance:
		# Read every frame: the stance can be changed while the game runs (Remote tree ->
		# Body/WeaponStance and its markers).
		_weapon_socket = _stance.socket(_skeleton, weapon.grip_radius)
	# The draw from the back is this arm's own way up and down: it replaces the plain blend.
	var drawing := weapon_sheath_on_back and _stance != null and reference == null and not weapon_shoulder_on_body and not weapon_arm_from_clips
	_weapon_up = move_toward(_weapon_up, 1.0 if weapon_raised and (_stance or reference) and not weapon_arm_from_clips else 0.0, delta / maxf(weapon_draw_time if drawing else weapon_raise_time, 0.01))
	_weapon_on_back = drawing and _weapon_up < weapon_draw_grab
	var weight := smoothstep(0.0, 1.0, _weapon_up)
	if drawing:
		weight = 1.0 if _weapon_up > 0.0 else 0.0 # _draw_arm comes out of the clip's pose by itself
	var clip_fingers: Array[Quaternion] = []
	if drawing:
		for bone in _stance.finger_bones(_skeleton):
			clip_fingers.append(_skeleton.get_bone_pose_rotation(bone) if bone >= 0 else Quaternion.IDENTITY)
	if weight <= 0.001:
		_weapon_push = Vector3.ZERO
		_weapon_push_speed = Vector3.ZERO
	if weight > 0.001:
		# The stance outright, then back toward the clip's arm by what is left of the weight.
		var arm_bones: Array[int] = [arm["upper"], arm["lower"], arm["hand"]]
		var in_clip: Array = [_skeleton.get_bone_pose_position(arm["upper"])]
		for bone in arm_bones:
			in_clip.append(_skeleton.get_bone_pose_rotation(bone))
		var to_skeleton := (player.global_transform.affine_inverse() * _skeleton.global_transform).affine_inverse()
		_bob_now = _weapon_bob(delta)
		var held_from := _eye + _bob_now + _breath_now * weapon_breathing # the eyes, the bob of the steps and the breathing
		if reference:
			# The wrist itself is put where the clip has it (no reach limit: its arm is shorter).
			WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, held_from + (frame["shoulder"] as Vector3), held_from + (frame["wrist"] as Vector3),
					(frame["elbow"] as Vector3) - (frame["shoulder"] as Vector3), frame["hand"] as Basis, Vector3.ZERO, 1.0)
		else:
			var fist := _stance.fist_in_hand(_skeleton, weapon.grip_radius)
			if weapon_shoulder_on_body:
				var own_shoulder := _skeleton.get_bone_global_pose(arm["upper"]).origin
				WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, to_skeleton.affine_inverse() * own_shoulder, held_from + _stance.hand_from_eyes(), _stance.elbow_toward(), _stance.hand_turn(), fist, weapon_body_reach)
				_shoulder_drawn = _skeleton.get_bone_global_pose(arm["upper"]).origin.distance_to(own_shoulder)
			elif drawing and _weapon_up < 1.0:
				_draw_arm(arm, arm_bones, in_clip, to_skeleton, held_from, fist)
			else:
				var with_view := Basis(Vector3.RIGHT, _look_pitch * weapon_follows_view)
				var hand_at := held_from + with_view * _stance.hand_from_eyes()
				var hand_turn := with_view * _stance.hand_turn()
				if _fidget != &"" and (FIDGETS[_fidget] as Dictionary).get("when", &"drawn") == &"drawn" and not (FIDGETS[_fidget] as Dictionary).has("shield_keys"):
					var posed := _fidget_pose(hand_at, hand_turn, held_from, with_view)
					hand_at = posed[0]
					hand_turn = posed[1]
				var shoulder_at := held_from + with_view * _stance.shoulder_from_eyes()
				for attempt in 2:
					var push := _weapon_push if attempt == 1 else Vector3.ZERO
					WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, shoulder_at + push, hand_at + push,
							with_view * _stance.elbow_toward(), hand_turn, fist, _stance.max_reach)
					if attempt == 1:
						break
					# The first solve is the hold as asked: how far it has to move to clear the body.
					var wanted := Vector3.ZERO
					if weapon_body_clearance > 0.0:
						var to_player := to_skeleton.affine_inverse()
						var held := to_player * _skeleton.get_bone_global_pose(arm["hand"]) * WeaponHold.in_hand(_weapon_socket, weapon)
						wanted = _weapon_off_body(to_player, held)
					_weapon_push_wanted = wanted
					_weapon_push = _spring(_weapon_push, wanted, delta)
					if _weapon_push.length() < 0.001:
						break
					_skeleton.set_bone_pose_position(arm["upper"], in_clip[0] as Vector3)
					for i in arm_bones.size():
						_skeleton.set_bone_pose_rotation(arm_bones[i], in_clip[i + 1] as Quaternion)
			# Looking down: toward the same hold with the shoulder left on the body.
			var on_body := smoothstep(weapon_on_body_from, maxf(weapon_on_body_by, weapon_on_body_from + 0.1), rad_to_deg(-_look_pitch)) if weapon_on_body_slide else 0.0
			if on_body > 0.001:
				var in_stance: Array = [_skeleton.get_bone_pose_position(arm["upper"])]
				for bone in arm_bones:
					in_stance.append(_skeleton.get_bone_pose_rotation(bone))
				_skeleton.set_bone_pose_position(arm["upper"], in_clip[0] as Vector3)
				WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, Vector3.INF, held_from + _stance.hand_from_eyes(), _stance.elbow_toward(), _stance.hand_turn(), fist, weapon_on_body_reach)
				if on_body < 0.999:
					_skeleton.set_bone_pose_position(arm["upper"], (in_stance[0] as Vector3).lerp(_skeleton.get_bone_pose_position(arm["upper"]), on_body))
					for i in arm_bones.size():
						_skeleton.set_bone_pose_rotation(arm_bones[i], (in_stance[i + 1] as Quaternion).slerp(_skeleton.get_bone_pose_rotation(arm_bones[i]), on_body))
		if weight < 0.999:
			_skeleton.set_bone_pose_position(arm["upper"], (in_clip[0] as Vector3).lerp(_skeleton.get_bone_pose_position(arm["upper"]), weight))
			for i in arm_bones.size():
				_skeleton.set_bone_pose_rotation(arm_bones[i], (in_clip[i + 1] as Quaternion).slerp(_skeleton.get_bone_pose_rotation(arm_bones[i]), weight))
	if drawing:
		# The fist closes as the hand comes to the grip on the back, and opens as it leaves it.
		var closed := smoothstep(weapon_draw_grab * 0.5, weapon_draw_grab, _weapon_up)
		if closed > 0.001:
			_stance.pose_fingers(_skeleton, weapon.grip_radius)
			if closed < 0.999:
				var bones := _stance.finger_bones(_skeleton)
				for i in bones.size():
					if bones[i] >= 0:
						_skeleton.set_bone_pose_rotation(bones[i], clip_fingers[i].slerp(_skeleton.get_bone_pose_rotation(bones[i]), closed))
	elif _stance:
		_stance.pose_fingers(_skeleton, weapon.grip_radius) # as posed by hand in the editor
	else:
		_set_fingers(arm, _weapon_fist, 1.0)

## A smooth curve through `points`, which it is at when `at` is the matching one of `times`
## (rising, from 0 to 1).
static func _through(points: Array[Vector3], times: Array[float], at: float) -> Vector3:
	var last := points.size() - 1
	var index := 0
	while index < last - 1 and at > times[index + 1]:
		index += 1
	var part := clampf((at - times[index]) / maxf(times[index + 1] - times[index], 0.0001), 0.0, 1.0)
	var before := points[maxi(index - 1, 0)]
	var after := points[mini(index + 2, last)]
	return points[index].cubic_interpolate(points[index + 1], before, after, part)

## Where the weapon's grip lies on the back (weapon_back_*), in the upper chest bone's axes: a
## socket as the hand's is, +Y the way the blade runs and +X its leading edge. Worked out from
## the rest pose's shoulders, so it fits any body on the humanoid skeleton.
func _back_socket() -> Transform3D:
	if _chest_bone < 0:
		_chest_bone = _skeleton.find_bone("UpperChest")
	var right_shoulder := _skeleton.get_bone_global_rest(_arms["Right"]["upper"]).origin
	var to_right := (right_shoulder - _skeleton.get_bone_global_rest(_arms["Left"]["upper"]).origin).normalized()
	var behind := to_right.cross(Vector3.UP).normalized() # the model faces the other way
	var slant := deg_to_rad(weapon_back_slant)
	var blade := (-to_right * sin(slant) - Vector3.UP * cos(slant)).normalized() # down, and toward the left
	var edge := behind.cross(blade).normalized() * (-1.0 if weapon_back_turned_over else 1.0) # the flats lie against the back
	var grip := right_shoulder + to_right * weapon_back_offset.x + Vector3.UP * weapon_back_offset.y + behind * weapon_back_offset.z
	var chest := _skeleton.get_bone_global_rest(_chest_bone)
	return Transform3D(chest.basis.orthonormalized().inverse() * Basis(edge, blade, edge.cross(blade)), chest.affine_inverse() * grip)

## The right arm on its way between the body's side and the stance, by way of the weapon on
## the back (weapon_sheath_on_back): `_weapon_up` is how far along. Up to weapon_draw_grab the
## arm, on the body's own shoulder, goes from the clip's pose to the grip on the back, the hand
## turned to hold the weapon as it lies there -- so the weapon does not move when it changes
## from the back to the fist. From there the fist swings past weapon_draw_via into the stance,
## the hand turning into the stance's turn and the shoulder going to the stance's.
func _draw_arm(arm: Dictionary, arm_bones: Array[int], in_clip: Array, to_skeleton: Transform3D, held_from: Vector3, fist: Vector3) -> void:
	var to_player := to_skeleton.affine_inverse()
	var on_back := _skeleton.get_bone_global_pose(_chest_bone) * _back_socket()
	# The hand's turn, as WeaponHold.solve_arm wants it, that has the weapon's grip in the fist
	# with the weapon lying as a socket's axes say (in the skeleton's space: +Y the blade, +X
	# the leading edge). See WeaponStance.fit_hand_to_sword.
	var holding := func(lying: Basis) -> Basis:
		var hand := lying.orthonormalized() * _weapon_socket.basis.orthonormalized().inverse()
		var turned := hand * Basis(arm["fingers_out"] as Vector3, arm["palm_out"] as Vector3, (arm["fingers_out"] as Vector3).cross(arm["palm_out"] as Vector3))
		return (to_player.basis.orthonormalized() * Basis(-turned.y, turned.z, -turned.x)).orthonormalized()
	var grab_turn: Basis = holding.call(on_back.basis)
	var hand_basis := on_back.basis.orthonormalized() * _weapon_socket.basis.orthonormalized().inverse()
	var grab_at := to_player * (on_back.origin + hand_basis * (fist - _weapon_socket.origin))
	if _weapon_up < weapon_draw_grab:
		# Up to the back, the arm on the body's own shoulder: the fist from where the clip has
		# it round past weapon_draw_arc to the grip, the hand turning from the clip's turn into
		# the hold, the elbow from the clip's side to DRAW_ELBOW.
		var reached := smoothstep(0.0, 1.0, _weapon_up / weapon_draw_grab)
		var clip_hand := _skeleton.get_bone_global_pose(arm["hand"])
		var clip_turned := clip_hand.basis.orthonormalized() * Basis(arm["fingers_out"] as Vector3, arm["palm_out"] as Vector3, (arm["fingers_out"] as Vector3).cross(arm["palm_out"] as Vector3))
		var clip_turn := (to_player.basis.orthonormalized() * Basis(-clip_turned.y, clip_turned.z, -clip_turned.x)).orthonormalized()
		var clip_at := to_player * (clip_hand * fist)
		var clip_elbow := to_player.basis * (_skeleton.get_bone_global_pose(arm["lower"]).origin - _skeleton.get_bone_global_pose(arm["upper"]).origin)
		var fist_at := _through([clip_at, _eye + weapon_draw_arc, _eye + weapon_draw_arc_up, grab_at], [0.0, weapon_draw_arc_at.x, weapon_draw_arc_at.y, 1.0], reached)
		WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, Vector3.INF, fist_at, clip_elbow.normalized().lerp(DRAW_ELBOW.normalized(), reached), clip_turn.slerp(grab_turn, reached), fist, DRAW_REACH)
		# While the arm sweeps out the hand hangs on the forearm as the clip has it (the wrist as
		# it was): turned toward the hold on the back all the way, it was bent 150 deg at the
		# wrist in the middle of the sweep, in full view from above. It turns into the hold
		# only on the last stretch, up behind the shoulder.
		var turning := smoothstep(weapon_draw_arc_at.x, 1.0, reached)
		if turning < 0.999:
			_skeleton.set_bone_pose_rotation(arm["hand"], (in_clip[3] as Quaternion).slerp(_skeleton.get_bone_pose_rotation(arm["hand"]), turning))
		# The solver's arm for the clip's own hand is not quite the clip's arm: ease into it.
		var eased := smoothstep(0.0, 0.25, reached)
		if eased < 0.999:
			for i in arm_bones.size():
				_skeleton.set_bone_pose_rotation(arm_bones[i], (in_clip[i + 1] as Quaternion).slerp(_skeleton.get_bone_pose_rotation(arm_bones[i]), eased))
		return
	var swung := smoothstep(0.0, 1.0, (_weapon_up - weapon_draw_grab) / (1.0 - weapon_draw_grab))
	var with_view := Basis(Vector3.RIGHT, _look_pitch * weapon_follows_view)
	var stance_turn := (with_view * _stance.hand_turn()).orthonormalized()
	# Half-way the blade points backward, over the shoulder; of the two ways its edge can face
	# then, the one that asks the least turning of the hand in all.
	var over := DRAW_BLADE_OVER.normalized()
	var edge := (Vector3.UP - over * Vector3.UP.dot(over)).normalized()
	var over_turn := Basis.IDENTITY
	var least := INF
	for way: float in [1.0, -1.0]:
		var candidate: Basis = holding.call(to_skeleton.basis.orthonormalized() * Basis(edge * way, over, (edge * way).cross(over)))
		var turning := grab_turn.get_rotation_quaternion().angle_to(candidate.get_rotation_quaternion()) + candidate.get_rotation_quaternion().angle_to(stance_turn.get_rotation_quaternion())
		if turning < least:
			least = turning
			over_turn = candidate
	var turn := grab_turn.slerp(over_turn, swung).slerp(over_turn.slerp(stance_turn, swung), swung)
	# The fist's way: off the back outward past weapon_draw_out, then past weapon_draw_via in.
	var out := held_from + weapon_draw_out
	var via := held_from + with_view * weapon_draw_via
	var stance_at := held_from + with_view * _stance.hand_from_eyes()
	var first := grab_at.lerp(out, swung).lerp(out.lerp(via, swung), swung)
	var second := out.lerp(via, swung).lerp(via.lerp(stance_at, swung), swung)
	# THE SHOULDER IS THE STANCE'S FROM THE MOMENT THE HAND HAS THE WEAPON, at once: just then
	# the arm on the body and the arm from the stance's shoulder are both out of the picture,
	# so the change is not seen. Sliding the shoulder across during the swing showed, from
	# above, the arm being pulled half a metre out of the body (Kirill).
	WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, held_from + with_view * _stance.shoulder_from_eyes(), first.lerp(second, swung),
			DRAW_ELBOW.lerp(with_view * _stance.elbow_toward(), swung), turn, fist, lerpf(DRAW_REACH, _stance.max_reach, swung))

## The lantern hangs from its place by the hips and swings there; the light sits in its flame,
## and the flame glows only while the light is on (L).
func _place_lantern(player: Node3D, delta: float) -> void:
	# The skeleton's bones in the Player's space.
	var bones := player.global_transform.affine_inverse() * _skeleton.global_transform
	var hook: Vector3 = bones * (_skeleton.get_bone_global_pose(_hook_bone) * _hook_offset)
	var pivot := hook
	# Turning the lantern on / off: how far through it is (0-1, below 0 = not doing it).
	var through := _toggle_at / maxf(toggle_time, 0.01) if _toggle_at >= 0.0 else -1.0
	_swing_lantern(player, bones, pivot, delta)
	if through >= 0.0:
		# The hand swings the lantern forward on its hook: its body goes from wherever it
		# hangs toward straight ahead of the hook, and it is let back the same way. Held
		# there it has no speed of its own, so it swings back from rest when let go.
		# A right hand that HOLDS A WEAPON: see below. Its arm has further to come, so the
		# lantern sets off later for it.
		var armed := _weapon_node != null and not _weapon_on_back and _weapon_up > 0.0
		var swing_part: Array = TOGGLE_SWING_ARMED if armed else TOGGLE_SWING
		var swung := _part(through, swing_part) * (1.0 - _part(through, TOGGLE_BACK))
		var forward := deg_to_rad(toggle_swing_degrees)
		if through < swing_part[0]:
			_toggle_hang = (_bob - pivot).normalized() # how it hangs just before the hand moves it
		elif through < TOGGLE_BACK[1]:
			# Out and back along the same way, to where it hung: left to fall back by itself
			# it came down in front of the thigh and stayed leaning on it.
			_bob = pivot + _toggle_hang.slerp(Vector3(0.0, -cos(forward), -sin(forward)), swung) * LANTERN_ARM
			_bob_before = _bob
		# The right hand: its palm against the lantern's body, from before the swing to after.
		var reaching := _part(through, TOGGLE_REACH) * (1.0 - _part(through, TOGGLE_RELEASE))
		# Its palm faces the lantern. The hand comes open; as it arrives the fingers close
		# round the lantern one after another from the forefinger, the thumb from the other
		# side, and they open again as it lets go.
		var cup := toggle_cup_offset if toggle_cup_offset.length_squared() > 0.0001 else Vector3.BACK
		# A right hand that HOLDS A WEAPON keeps its fist round it and steadies the lantern
		# with that; the weapon comes along. Its arm sets off from the stance's shoulder,
		# which is not the body's: for the reach the shoulder goes back onto the body (the
		# lantern is at the hip, out of reach from where the stance has the shoulder).
		if armed:
			var right_upper: int = _arms["Right"]["upper"]
			_skeleton.set_bone_pose_position(right_upper, _skeleton.get_bone_pose_position(right_upper).lerp(_skeleton.get_bone_rest(right_upper).origin, _part(through, TOGGLE_REACH_ARMED) * (1.0 - _part(through, TOGGLE_RELEASE_ARMED))))
			# THE KNUCKLES of the fist nudge the lantern, the weapon pointing ahead (Kirill,
			# 2026-10-13: "the sword clips through body and lantern"). The handle is in the palm
			# and the crossguard beside it, so the palm against the lantern, as an open hand has
			# it, put the sword 5 cm into it and 8-13 cm into the body whichever way the hand was
			# turned, and the back of the hand against it bent the wrist 100-170 degrees. A
			# forearm laid against it instead touched only the wire handle, which did not show.
			# The fist COMES IN BEHIND THE LANTERN while it still hangs and goes forward with it
			# (Kirill, 2026-10-14: the lantern set off by itself and the hand came at its front
			# half-way through the swing). Its place is set from the lantern's middle, wherever
			# that is: toggle_armed_fist_hanging before the swing, toggle_armed_fist once swung,
			# and between the two by how far the swing is. It gets there round the back, by way
			# of toggle_armed_around. The forearm is rolled (which side of the fist faces up)
			# and the wrist bent to point the blade (toggle_armed_blade_hanging, then
			# toggle_armed_blade): since 2026-10-14 the fist LIFTS the lantern from under it.
			reaching = _part(through, TOGGLE_REACH_ARMED) * (1.0 - _part(through, TOGGLE_RELEASE_ARMED))
			var in_fist := _skeleton.get_bone_pose_rotation(_arms["Right"]["hand"])
			_reach(_arms["Right"], "palm", bones, _bob + toggle_armed_fist_hanging.lerp(toggle_armed_fist, swung), reaching, toggle_armed_elbow, -cup, 0.0, pivot + Vector3.DOWN * LANTERN_ARM + toggle_armed_around, Vector3.INF, Vector3.INF, in_fist)
			var forearm := _skeleton.get_bone_global_pose(_arms["Right"]["lower"])
			var along := (_skeleton.get_bone_global_pose(_arms["Right"]["hand"]).origin - forearm.origin).normalized()
			forearm.basis = Basis(along, deg_to_rad(toggle_armed_roll) * reaching) * forearm.basis
			_skeleton.set_bone_global_pose(_arms["Right"]["lower"], forearm)
			if toggle_armed_blade.length_squared() > 0.0001:
				# The wrist bends the blade toward toggle_armed_blade (the grip's +Y is the blade).
				var hand := _skeleton.get_bone_global_pose(_arms["Right"]["hand"])
				var blade_now := (hand.basis * _weapon_socket.basis.y).normalized()
				var blade_asked := (bones.affine_inverse().basis * toggle_armed_blade_hanging.normalized().slerp(toggle_armed_blade.normalized(), swung)).normalized()
				var bend_axis := blade_now.cross(blade_asked)
				if bend_axis.length_squared() > 0.000001:
					var bend := minf(blade_now.angle_to(blade_asked), TOGGLE_ARMED_WRIST_MAX) * reaching
					hand.basis = Basis(bend_axis.normalized(), bend) * hand.basis
					_skeleton.set_bone_global_pose(_arms["Right"]["hand"], hand)
		else:
			_reach(_arms["Right"], "palm", bones, _bob + toggle_cup_offset, reaching, TOGGLE_ELBOW, -cup)
		if not armed:
			var closed := [0.0, 0.0, 0.0, 0.0, 0.0]
			for i in closed.size():
				var late := 0.015 * i
				var gripping := smoothstep(TOGGLE_REACH[1] - 0.07 + late, TOGGLE_REACH[1] + 0.05 + late, through) * (1.0 - smoothstep(TOGGLE_RELEASE[0] - 0.02 + late, TOGGLE_RELEASE[0] + 0.08 + late, through))
				closed[i] = lerpf(toggle_open_curl, toggle_cup_curl * (0.6 if i == 0 else 1.0), gripping)
			_set_fingers(_arms["Right"], closed, reaching)
	_fidget_sheathed(bones, pivot, delta)
	# Its handle's top at the pivot, its body toward the swinging point, turned with the Player.
	var up := (pivot - _bob).normalized()
	var side := up.cross(Vector3.BACK)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	# The model's wide axis (its X) runs front to back, so its thin side is toward the leg.
	var lantern_place := Transform3D(Basis(up, _lantern_spin) * Basis(side.cross(up), up, -side), pivot)
	_lantern.global_transform = player.global_transform * lantern_place
	if through >= 0.0:
		# The left hand: to the knob on the lantern, wherever that now is. It comes open; thumb,
		# forefinger and middle finger close on the knob's end and the other two fold out of
		# the way; then the whole pinch turns about the knob's rod, and it opens leaving.
		var coming := _part(through, TOGGLE_LEFT_IN) * (1.0 - _part(through, TOGGLE_LEFT_OUT))
		var pinching := smoothstep(TOGGLE_LEFT_IN[1] - 0.1, TOGGLE_LEFT_IN[1], through) * (1.0 - smoothstep(TOGGLE_LEFT_OUT[0], TOGGLE_LEFT_OUT[0] + 0.08, through))
		var turned := _part(through, TOGGLE_TUG)
		var left: Dictionary = _arms["Left"]
		var folded := lerpf(toggle_open_curl, 1.3, pinching)
		var pinched := lerpf(toggle_open_curl, toggle_pinch_curl, pinching)
		var way := 1.0 if _toggle_lighting else -1.0
		# A LEFT HAND IN A SHIELD'S HANDLE STAYS IN IT (Kirill, 2026-10-13): the ring and the
		# little finger keep their hold as posed, the wrist keeps the turn it has in the
		# straps, and thumb, forefinger and middle finger do the pinch and roll the knob
		# between them. The shield comes along on the forearm. The same with the weapons up
		# or down; with them up the shoulder goes back onto the body for the reach.
		var strapped := _shield_node != null and shield.on_forearm and _shield_socket_set and _shield_stance != null
		var rolling := (toggle_knob_roll_strapped if strapped else toggle_knob_roll) * turned * way
		var holding: Array[Quaternion] = []
		if strapped:
			_skeleton.set_bone_pose_position(left["upper"], _skeleton.get_bone_pose_position(left["upper"]).lerp(_skeleton.get_bone_rest(left["upper"]).origin, coming))
			for finger: String in ["Ring", "Little"]:
				for joint: Array in left["fingers"][finger]:
					holding.append(_skeleton.get_bone_pose_rotation(joint[0]))
		# The thumb closes half as far as the fingers and swings in to meet them.
		_set_fingers(left, [lerpf(0.0, toggle_pinch_curl * 0.5, pinching) + rolling, pinched - rolling, pinched - rolling * 0.5, folded, folded], coming, toggle_pinch_thumb_in * pinching)
		if strapped:
			var kept := 0
			for finger: String in ["Ring", "Little"]:
				for joint: Array in left["fingers"][finger]:
					_skeleton.set_bone_pose_rotation(joint[0], holding[kept])
					kept += 1
		# Where the three fingertips meet, with the fingers as they now are (in the hand's axes).
		var to_hand := _skeleton.get_bone_global_pose(left["hand"]).affine_inverse()
		var tips: Array[Vector3] = []
		for finger: String in ["Thumb", "Index", "Middle"]:
			var joints: Array = left["fingers"][finger]
			var last := _skeleton.get_bone_global_pose(joints[2][0]).origin
			tips.append(to_hand * (last + (last - _skeleton.get_bone_global_pose(joints[1][0]).origin).normalized() * FINGERTIP))
		left["pinch"] = (tips[0] + (tips[1] + tips[2]) * 0.5) * 0.5
		# The rod runs out from the lantern's middle line through the knob. The hand is turned
		# so that the line from its middle to the fingertips points back along the rod at the
		# lantern: the tips are then its nearest part, and the knuckles and the folded fingers
		# stay outside the lantern (with the fingers' own line pointed there, the closed
		# fingers' knuckles went into it). The palm faces down as nearly as that allows, the
		# tips meet a little way off the rod's end, and the turn is a roll about the rod. It
		# goes round the front of the body, not straight across through the belly.
		var rod := (lantern_place.basis * Vector3(toggle_knob.x, 0.0, toggle_knob.z)).normalized()
		var to_tips := (left["pinch"] as Vector3) - (left["middle"] as Vector3)
		var front: Vector3 = bones * _skeleton.get_bone_global_pose(_hook_bone).origin + toggle_left_around
		# Up to the turn the hand finds its own grip on the knob, and that grip is kept, as
		# the lantern sees it. From the turn on, the hand's turn is that grip rolled about the
		# rod by exactly the turn's angle. (Worked out afresh each frame during the turn, the
		# grip itself shifted with the forearm as the hand went round, and a quarter turn of
		# the knob swung the hand through 180 to 220 degrees.)
		var turning: Variant = null
		if strapped:
			turning = _shield_hand_in_stance # the hand's turn on the forearm, kept: see _reach
		elif through >= TOGGLE_TUG[0] and _pinch_grip_valid:
			var rod_own := Vector3(toggle_knob.x, 0.0, toggle_knob.z).normalized()
			turning = lantern_place.basis * Basis(rod_own, toggle_knob_turn * turned * way) * _pinch_grip
		# With a shield on the forearm the elbow goes BACK and the hand comes to the knob along
		# the body's left side, not round its front: the forearm then lies beside the hip with
		# the shield outside it, as in the relaxed carry. Round the front, with the elbow
		# forward, the forearm crossed the thigh and no roll of it kept the shield out of the
		# body (worst standing right foot forward: 8 cm in, Kirill, 2026-10-13).
		# The elbow's side comes in with the reach, from where the arm has the elbow now: with
		# the wrist kept still the whole hand goes where the forearm does, and an elbow sent to
		# its side at once threw the wrist 15-18 cm in one frame.
		var left_elbow := TOGGLE_LEFT_ELBOW
		if strapped:
			var elbow_now := (bones.basis * (_skeleton.get_bone_global_pose(left["lower"]).origin - _skeleton.get_bone_global_pose(left["upper"]).origin)).normalized()
			left_elbow = elbow_now.lerp(toggle_strapped_elbow.normalized(), coming)
		_reach(left, "pinch", bones, lantern_place * toggle_knob + rod * toggle_pinch_gap, coming, left_elbow, Vector3.DOWN, 0.0, front if (toggle_strapped_round_front or not strapped) else Vector3.INF, -rod, to_tips, turning)
		if strapped:
			# The shield came along as the forearm happened to lie, which was through the
			# belly and the thigh (Kirill, 2026-10-13). The forearm, with the hand and the
			# shield on it, is rolled about the line from the elbow to the fingertips' meeting
			# place -- which stays on the knob -- to the roll that leaves the body the most
			# room: twenty-four rolls round are tried each frame against points along the trunk
			# and the legs, and the arm eases toward the best. (Facing the shield "away from
			# the body", as the relaxed carry does, was tried first: its long point still went
			# 5-9 cm into the thigh.)
			var lower := _skeleton.get_bone_global_pose(left["lower"])
			var hand := _skeleton.get_bone_global_pose(left["hand"])
			var line := (hand * (left["pinch"] as Vector3) - lower.origin).normalized()
			var on_arm := WeaponHold.in_hand(_shield_socket, shield)
			var low := _shield_points[0]
			var high := _shield_points[0]
			for point in _shield_points:
				low = low.min(point)
				high = high.max(point)
			var body_points: Array = [] # [place in the skeleton's space, how thick the body is round it]
			var hips := _skeleton.get_bone_global_pose(_hips_bone).origin
			var chest := _skeleton.get_bone_global_pose(_skeleton.find_bone("UpperChest")).origin
			for step in 5:
				body_points.append([hips.lerp(chest, step / 4.0), TOGGLE_TRUNK])
			for leg: Dictionary in _legs:
				var hip := _skeleton.get_bone_global_pose(leg["upper"]).origin
				var knee := _skeleton.get_bone_global_pose(leg["lower"]).origin
				var ankle := _skeleton.get_bone_global_pose(leg["foot"]).origin
				for step in 4:
					body_points.append([hip.lerp(knee, step / 3.0), TOGGLE_LEG])
					body_points.append([knee.lerp(ankle, (step + 1) / 4.0), TOGGLE_LEG])
			var best_roll := 0.0
			var best_room := -INF
			var kept_room := -INF # the room the roll chosen before still leaves
			for step in 24:
				var roll := step * TAU / 24.0
				var to_board := (Transform3D(Basis(line, roll) * lower.basis, lower.origin) * on_arm).affine_inverse()
				var room := INF
				for body_point: Array in body_points:
					var at: Vector3 = to_board * (body_point[0] as Vector3)
					var outside := Vector3(maxf(maxf(low.x - at.x, at.x - high.x), 0.0), maxf(maxf(low.y - at.y, at.y - high.y), 0.0), maxf(maxf(low.z - at.z, at.z - high.z), 0.0))
					var off := outside.length()
					if off <= 0.0: # inside the box: by how far, as a loss
						off = -minf(minf(at.x - low.x, high.x - at.x), minf(minf(at.y - low.y, high.y - at.y), minf(at.z - low.z, high.z - at.z)))
					room = minf(room, off - (body_point[1] as float))
				room -= absf(wrapf(roll, -PI, PI)) * 0.01 # of two rolls as good, the smaller
				if room > best_room:
					best_room = room
					best_roll = roll
				if absf(wrapf(roll - _toggle_roll_wanted, -PI, PI)) < TAU / 48.0 + 0.001:
					kept_room = room
			# Another roll is taken up only where it is clearly better: picked afresh each
			# frame, the choice hopped between two rolls about as good and the shield with it.
			if best_room > kept_room + 0.03:
				_toggle_roll_wanted = best_roll
			_toggle_shield_roll = lerp_angle(_toggle_shield_roll, _toggle_roll_wanted, 1.0 - exp(-delta / 0.12))
			lower.basis = Basis(line, wrapf(_toggle_shield_roll, -PI, PI) * coming) * lower.basis
			_skeleton.set_bone_global_pose(left["lower"], lower)
		if through < TOGGLE_TUG[0]:
			_pinch_grip = lantern_place.basis.inverse() * (bones.basis * _skeleton.get_bone_global_pose(left["hand"]).basis).orthonormalized()
			_pinch_grip_valid = true
	if _lantern_light == null:
		return
	var flame := player.to_local(_lantern.to_global(LANTERN_FLAME))
	if _lantern_light.has_method(&"set_rest_position"):
		_lantern_light.call(&"set_rest_position", flame)
	else:
		_lantern_light.position = flame
	if _lantern_pool:
		_lantern_pool.position = _lantern_pool_rest - _lantern_light.position
	if _body_light:
		# They follow the flicker, which changes the lantern light's energy and colour every frame.
		_body_light.light_energy = _lantern_light.light_energy * lantern_light_on_body
		_body_light.light_color = _lantern_light.light_color
		for near: OmniLight3D in [_near_minus, _near_plus]:
			near.visible = body_shadow_reach > 0.0
			near.omni_range = maxf(body_shadow_reach, 0.01)
			near.light_energy = _lantern_light.light_energy
			near.light_color = _lantern_light.light_color

## How far through one part of a sequence: 0 before it, 1 after, eased between.
func _part(through: float, part: Array) -> float:
	return smoothstep(part[0], part[1], through)

## The bones of both arms and what is needed to place a hand, all in the hand bone's own axes
## and read from the rest pose (a T-pose with the palms down): two points on the hand -- "palm",
## where it rests against a thing, and "pinch", between the tips of thumb and forefinger --
## the way the palm faces ("palm_out"), the way the fingers point ("fingers_out"), and each
## joint of each finger with the axis it closes about. A finger closes by turning from the way
## it points toward the ground, the palm's side in that pose.
func _setup_arms() -> void:
	for side: String in ["Left", "Right"]:
		var hand := _skeleton.find_bone(side + "Hand")
		var hand_rest := _skeleton.get_bone_global_rest(hand)
		var to_hand := hand_rest.affine_inverse()
		var knuckle := _skeleton.get_bone_global_rest(_skeleton.find_bone(side + "MiddleProximal")).origin
		var forefinger_tip := _skeleton.get_bone_global_rest(_skeleton.find_bone(side + "IndexDistal")).origin
		var thumb_tip := _skeleton.get_bone_global_rest(_skeleton.find_bone(side + "ThumbDistal")).origin
		# The fingers' joints and the thumb's swing: shared with everything else that closes a hand.
		var fingers := WeaponHold.finger_joints(_skeleton, side)
		var thumb_in: Vector3 = fingers["thumb_in"]
		var fingers_out := (hand_rest.basis.inverse() * (knuckle - hand_rest.origin)).normalized()
		var palm_out := hand_rest.basis.inverse() * Vector3.DOWN
		palm_out = (palm_out - fingers_out * palm_out.dot(fingers_out)).normalized()
		_arms[side] = {
			"upper": _skeleton.find_bone(side + "UpperArm"), "lower": _skeleton.find_bone(side + "LowerArm"), "hand": hand,
			"palm": to_hand * (hand_rest.origin.lerp(knuckle, 0.7) + Vector3.DOWN * 0.03),
			"middle": to_hand * hand_rest.origin.lerp(knuckle, 0.5),
			"pinch": to_hand * ((forefinger_tip + thumb_tip) * 0.5),
			"palm_out": palm_out, "fingers_out": fingers_out,
			"fingers": fingers,
			"thumb_in": thumb_in,
		}

## Bends one arm so that a point of its hand ("palm" or "pinch") is at `target`, a place in
## the Player's space, with the palm facing `palm_toward` (a direction in the Player's space);
## `weight` 0 leaves the clip's pose, 1 puts it there. Shoulder and hand stay where the body
## and the target put them, and the elbow goes to the side `elbow` points to. The upper and
## the lower arm are turned by the shortest way each. `around`: see where it is used. The hand is turned so that its palm faces
## as asked with its fingers running on from the forearm as nearly as that allows (the wrist
## bends as little as it can), then rolled by `roll` radians about its fingers.
func _reach(arm: Dictionary, point: String, bones: Transform3D, target: Vector3, weight: float, elbow: Vector3, palm_toward: Vector3, roll: float = 0.0, around: Vector3 = Vector3.INF, fingers_toward: Vector3 = Vector3.INF, aim: Vector3 = Vector3.INF, given: Variant = null, soft: float = 0.0) -> void:
	if weight <= 0.001:
		return
	var to_skeleton := bones.affine_inverse()
	var at: Vector3 = arm[point]
	# From where the clip has the point to the target: straight, or, given `around` (a place
	# in the Player's space), along a curve that bows out toward it.
	var from := _skeleton.get_bone_global_pose(arm["hand"]) * at
	var goal := from.lerp(to_skeleton * target, weight)
	if around.is_finite():
		var past := to_skeleton * around
		goal = from.lerp(past, weight).lerp(past.lerp(to_skeleton * target, weight), weight)
	var pole := (to_skeleton.basis * elbow).normalized()
	# The elbow's side comes in with the weight, from the side the arm has it on now. Taken
	# whole from the first sliver of weight, it threw the forearm round the moment a reach began
	# and the moment it ended, and the hand with it: with a sword in that hand the blade's tip
	# jumped 0.42 m in the frame the lantern's action ended (Kirill, 2026-10-13: "a visible
	# janky shift").
	var elbow_now := _skeleton.get_bone_global_pose(arm["lower"]).origin - _skeleton.get_bone_global_pose(arm["upper"]).origin
	if elbow_now.length() > 0.001:
		var eased := elbow_now.normalized().lerp(pole, weight)
		if eased.length() > 0.01:
			pole = eased.normalized()
	var palm_asked := (to_skeleton.basis * palm_toward).normalized()
	var hand_in_clip := Basis(_skeleton.get_bone_pose_rotation(arm["hand"]))
	# The hand's own frame, built on the axis that gets pointed: the way its fingers run, or
	# `aim` (a direction in the hand's own axes) where one is given; then the palm's side,
	# squared to it, and the third axis.
	var fingers_out: Vector3 = arm["fingers_out"]
	var pointed: Vector3 = aim.normalized() if aim.is_finite() else fingers_out
	var palm_out: Vector3 = arm["palm_out"]
	palm_out = palm_out - pointed * palm_out.dot(pointed)
	if palm_out.length_squared() < 0.0001:
		palm_out = pointed.cross(fingers_out)
	palm_out = palm_out.normalized()
	var own_frame := Basis(pointed, palm_out, pointed.cross(palm_out))
	for pass_index in 5: # the hand turns as the arm bends, which moves the point: settle it
		# The hand's turn, for the forearm as it now is.
		var lower := _skeleton.get_bone_global_pose(arm["lower"])
		var hand := _skeleton.get_bone_global_pose(arm["hand"])
		var forearm := (hand.origin - lower.origin).normalized()
		var wanted: Basis
		if given is Basis:
			# The hand's turn is given outright (in the Player's space).
			wanted = (to_skeleton.basis * (given as Basis)).orthonormalized()
		elif given is Quaternion:
			# The hand's turn ON THE FOREARM is given (the hand bone's own rotation): the
			# wrist does not move, and the hand goes wherever the forearm takes it.
			wanted = lower.basis.orthonormalized() * Basis(given as Quaternion)
		else:
			# Where the pointed axis goes: on from the forearm as nearly as the palm's facing
			# allows, or where `fingers_toward` asks.
			var pointing := forearm - palm_asked * forearm.dot(palm_asked)
			if fingers_toward.is_finite():
				pointing = to_skeleton.basis * fingers_toward
			if pointing.length_squared() < 0.0001:
				pointing = palm_asked.cross(Vector3.UP)
			pointing = pointing.normalized()
			var palm := palm_asked - pointing * palm_asked.dot(pointing)
			if palm.length_squared() < 0.0001:
				palm = pointing.cross(Vector3.RIGHT)
			palm = palm.normalized()
			wanted = Basis(pointing, palm, pointing.cross(palm)) * own_frame.inverse()
			var fingers := (wanted * fingers_out).normalized()
			if fingers_toward.is_finite():
				# The line is fixed: the hand is turned about it until its fingers run on
				# from the forearm as nearly as they can, which is the easiest wrist for it.
				var fingers_across := fingers - pointing * fingers.dot(pointing)
				var forearm_across := forearm - pointing * forearm.dot(pointing)
				if fingers_across.length_squared() > 0.0001 and forearm_across.length_squared() > 0.0001:
					wanted = Basis(pointing, fingers_across.signed_angle_to(forearm_across, pointing)) * wanted
			else:
				# The wrist bends no further than it can: past that the whole hand is turned
				# back until its fingers are within the limit of the forearm's line. (Pushing
				# the lantern forward with the forearm pointing at it asked for 70 degrees.)
				var bend := forearm.angle_to(fingers)
				var back := fingers.cross(forearm)
				if bend > TOGGLE_WRIST_MAX and back.length_squared() > 0.000001:
					wanted = Basis(back.normalized(), bend - TOGGLE_WRIST_MAX) * wanted
			wanted = Basis(pointing, roll) * wanted
		var clip_turn := (lower.basis * hand_in_clip).get_rotation_quaternion()
		hand.basis = Basis(clip_turn.slerp(wanted.get_rotation_quaternion(), weight))
		_skeleton.set_bone_global_pose(arm["hand"], hand)
		if pass_index == 4:
			break # the last pass only sets the hand's turn for the arm as solved
		var upper := _skeleton.get_bone_global_pose(arm["upper"])
		var hand_goal := hand.origin + goal - hand * at
		var upper_length := (lower.origin - upper.origin).length()
		var lower_length := (hand.origin - lower.origin).length()
		var to_goal := hand_goal - upper.origin
		var distance := to_goal.length()
		# `soft`: within that much of the arm's full length the reach eases into it instead of
		# stopping there (the elbow straightened to its limit in one frame and the hand's way
		# turned with it -- the strap fidget's reach, 2026-10-14).
		var full := upper_length + lower_length - 0.001
		if soft > 0.0 and distance > full - soft:
			distance = full - soft * exp(-(distance - (full - soft)) / soft)
		distance = clampf(distance, absf(upper_length - lower_length) + 0.001, full)
		var toward := to_goal.normalized()
		var sideways := pole - toward * pole.dot(toward)
		if sideways.length_squared() < 0.0001:
			sideways = toward.cross(Vector3.UP)
		# The triangle shoulder - elbow - hand with its three sides known.
		var cosine := clampf((upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * upper_length * distance), -1.0, 1.0)
		var elbow_at := upper.origin + toward * (upper_length * cosine) + sideways.normalized() * (upper_length * sqrt(1.0 - cosine * cosine))
		upper.basis = Basis(Quaternion((lower.origin - upper.origin).normalized(), (elbow_at - upper.origin).normalized())) * upper.basis
		_skeleton.set_bone_global_pose(arm["upper"], upper)
		lower = _skeleton.get_bone_global_pose(arm["lower"])
		hand = _skeleton.get_bone_global_pose(arm["hand"])
		lower.basis = Basis(Quaternion((hand.origin - lower.origin).normalized(), (upper.origin + toward * distance - lower.origin).normalized())) * lower.basis
		_skeleton.set_bone_global_pose(arm["lower"], lower)

func _setup_legs() -> void:
	_hips_bone = _skeleton.find_bone("Hips")
	for side: String in ["Left", "Right"]:
		var foot := _skeleton.find_bone(side + "Foot")
		_legs.append({
			"upper": _skeleton.find_bone(side + "UpperLeg"), "lower": _skeleton.find_bone(side + "LowerLeg"), "foot": foot, "toes": _skeleton.find_bone(side + "Toes"),
			"ankle": _skeleton.get_bone_global_rest(foot).origin.y, # the ankle's height standing on level ground
			"ground": 0.0, # the ground's height under the foot (world), followed at feet_max_speed
			"offset": 0.0, # m the foot is moved up just now (negative: down)
			"normal": Vector3.UP, # the ground's normal under it, in the Player's space
		})

## The ground's height (world) and normal straight under a place, by a ray against the
## collision from FEET_RAY_UP above the Player's feet level to feet_max_down below it; an
## empty array where there is none.
func _ground_under(player: Node3D, at: Vector3) -> Array:
	var level := player.global_position.y
	var query := PhysicsRayQueryParameters3D.create(Vector3(at.x, level + FEET_RAY_UP, at.z), Vector3(at.x, level - feet_max_down - 0.1, at.z))
	if player is CollisionObject3D:
		query.collision_mask = (player as CollisionObject3D).collision_mask
		query.exclude = [(player as CollisionObject3D).get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return []
	var found: Vector3 = hit["position"]
	# The collision is the plain heightmap; where a texture's relief moves the drawn ground off
	# it, the foot goes to the drawn ground.
	if feet_on_drawn_ground:
		found.y += TerrainDisplacement.lift_at(found)
	return [found.y, hit["normal"]]

## Puts both feet on the ground under them, after the clip. The ground's height under each
## ankle is looked up with a ray against the collision, and the foot is moved up or down by
## how far that is from the level the Player stands at -- so a foot the clip has lifted stays
## lifted by as much. The hips come down only when a leg could not reach its foot's place
## otherwise (feet_leg_stretch): coming down as far as the lower foot goes, they sank 16 cm
## jogging up a 20 degree slope, for the foot trailing behind. A foot on the ground is tilted to the
## slope; a lifted one is not, and is raised instead by what the ground under its toes is
## higher than under its ankle. All of it fades out in the air.
func _place_feet(player: Node3D, delta: float) -> void:
	if not feet_on_ground or _hips_bone < 0 or _legs.is_empty():
		return
	var weight_before := _feet_weight
	_feet_weight = move_toward(_feet_weight, 1.0 if _was_on_floor else 0.0, delta / maxf(feet_blend_time, 0.001))
	if _feet_weight <= 0.0:
		for leg in _legs:
			leg["offset"] = 0.0
			leg["normal"] = Vector3.UP
		_hips_drop = 0.0
		return
	var bones := player.global_transform.affine_inverse() * _skeleton.global_transform
	var to_skeleton := bones.affine_inverse()
	var up := to_skeleton.basis * Vector3.UP # one metre up, in the skeleton's space
	var level := player.global_position.y
	var follow := 1.0 - exp(-delta / maxf(feet_smoothing, 0.001))
	var feet_in_clip: Array[Transform3D] = []
	var planted_shares: Array[float] = []
	for leg in _legs:
		var foot := _skeleton.get_bone_global_pose(leg["foot"])
		feet_in_clip.append(foot)
		# How far the clip has the foot off the ground decides how much of the slope it takes.
		var lift: float = ((bones * foot.origin).y - _model.position.y) - (leg["ankle"] as float) * bones.basis.y.length()
		var planted := 1.0 - clampf(lift / maxf(feet_tilt_lift, 0.001), 0.0, 1.0)
		planted_shares.append(planted)
		var ground := level
		var normal := Vector3.UP
		var under_ankle := _ground_under(player, player.global_transform * (bones * foot.origin))
		if not under_ankle.is_empty():
			ground = under_ankle[0]
			normal = player.global_basis.inverse() * (under_ankle[1] as Vector3)
			if planted < 1.0 and (leg["toes"] as int) >= 0:
				var under_toes := _ground_under(player, player.global_transform * (bones * _skeleton.get_bone_global_pose(leg["toes"]).origin))
				if not under_toes.is_empty():
					ground += (1.0 - planted) * maxf((under_toes[0] as float) - ground, 0.0)
		# The height is followed in the world, not against the Player: under a foot that stands
		# it does not change, however fast the Player climbs past it.
		leg["ground"] = ground if weight_before <= 0.0 else move_toward(leg["ground"], ground, feet_max_speed * delta)
		leg["normal"] = (leg["normal"] as Vector3).lerp(normal, follow).normalized()
		leg["offset"] = clampf((leg["ground"] as float) - level, -feet_max_down, feet_max_up) * _feet_weight
	# The hips come down only as far as a leg needs to reach its foot's place.
	var straight := up.normalized()
	var drop := 0.0
	for i in _legs.size():
		var leg := _legs[i]
		var hip := _skeleton.get_bone_global_pose(leg["upper"]).origin
		var knee := _skeleton.get_bone_global_pose(leg["lower"]).origin
		var reach := ((knee - hip).length() + (feet_in_clip[i].origin - knee).length()) * feet_leg_stretch
		var to_foot := feet_in_clip[i].origin + up * (leg["offset"] as float) - hip
		var below := -to_foot.dot(straight)
		var aside := to_foot.length_squared() - below * below
		drop = maxf(drop, below - sqrt(maxf(reach * reach - aside, 0.0)))
	_hips_drop = lerpf(_hips_drop, minf(drop, feet_max_down * up.length()), 1.0 - exp(-delta / maxf(feet_hips_smoothing, 0.001)))
	var hips := _skeleton.get_bone_global_pose(_hips_bone)
	hips.origin -= straight * _hips_drop
	_skeleton.set_bone_global_pose(_hips_bone, hips)
	for i in _legs.size():
		var leg := _legs[i]
		var foot := feet_in_clip[i]
		var normal := (to_skeleton.basis * (leg["normal"] as Vector3)).normalized()
		var tilt := Quaternion.IDENTITY
		var axis := straight.cross(normal)
		if axis.length_squared() > 0.000001:
			tilt = Quaternion(axis.normalized(), minf(straight.angle_to(normal), deg_to_rad(feet_max_tilt)) * planted_shares[i] * _feet_weight)
		_solve_leg(leg, foot, foot.origin + up * (leg["offset"] as float), tilt)

## Bends one leg so that its ankle is at `goal` (the skeleton's space), the knee to the side
## the clip has it, and gives the foot the turn it has in the clip (`foot_in_clip`) with `tilt`
## on top.
func _solve_leg(leg: Dictionary, foot_in_clip: Transform3D, goal: Vector3, tilt: Quaternion) -> void:
	var upper := _skeleton.get_bone_global_pose(leg["upper"])
	var lower := _skeleton.get_bone_global_pose(leg["lower"])
	var foot := _skeleton.get_bone_global_pose(leg["foot"])
	var upper_length := (lower.origin - upper.origin).length()
	var lower_length := (foot.origin - lower.origin).length()
	var to_goal := goal - upper.origin
	var distance := clampf(to_goal.length(), absf(upper_length - lower_length) + 0.001, upper_length + lower_length - 0.001)
	var toward := to_goal.normalized()
	# The knee's side: where the clip has it, with the body's front (+Z of the skeleton) added
	# so that a leg the clip holds straight does not bend backward or sideways.
	var knee := lower.origin - upper.origin + Vector3.BACK * KNEE_FORWARD
	var sideways := knee - toward * knee.dot(toward)
	if sideways.length_squared() < 0.000001:
		sideways = Vector3.BACK - toward * Vector3.BACK.dot(toward)
	# The triangle hip - knee - ankle with its three sides known.
	var cosine := clampf((upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * upper_length * distance), -1.0, 1.0)
	var knee_at := upper.origin + toward * (upper_length * cosine) + sideways.normalized() * (upper_length * sqrt(1.0 - cosine * cosine))
	upper.basis = Basis(Quaternion((lower.origin - upper.origin).normalized(), (knee_at - upper.origin).normalized())) * upper.basis
	_skeleton.set_bone_global_pose(leg["upper"], upper)
	lower = _skeleton.get_bone_global_pose(leg["lower"])
	foot = _skeleton.get_bone_global_pose(leg["foot"])
	lower.basis = Basis(Quaternion((foot.origin - lower.origin).normalized(), (upper.origin + toward * distance - lower.origin).normalized())) * lower.basis
	_skeleton.set_bone_global_pose(leg["lower"], lower)
	foot = _skeleton.get_bone_global_pose(leg["foot"])
	foot.basis = Basis(tilt) * foot_in_clip.basis
	_skeleton.set_bone_global_pose(leg["foot"], foot)

## Sets how far each finger of a hand is closed: `closed` holds radians per joint for the
## thumb, forefinger, middle, ring and little finger (the order of FINGERS), 0 = flat as in the
## rest pose. `thumb_in` swings the thumb in toward the fingers at its first joint (radians).
## It replaces the clip's pose of the fingers by `weight`.
func _set_fingers(arm: Dictionary, closed: Array, weight: float, thumb_in: float = 0.0, joint_share: Vector3 = Vector3.ONE) -> void:
	if weight <= 0.001:
		return
	for i in FINGERS.size():
		var joints: Array = arm["fingers"][FINGERS[i]]
		for j in joints.size():
			var joint: Array = joints[j]
			var bone: int = joint[0]
			# The four fingers' joints may each take their own share of the curl (from the
			# knuckle outward): round something thick the knuckle bends little and the middle
			# joint most.
			var wanted := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion() * Quaternion(joint[1] as Vector3, (closed[i] as float) * (joint_share[j] if i > 0 else 1.0))
			if i == 0 and j == 0:
				wanted = wanted * Quaternion(arm["thumb_in"] as Vector3, thumb_in)
			_skeleton.set_bone_pose_rotation(bone, _skeleton.get_bone_pose_rotation(bone).slerp(wanted, weight))

## A light in the lantern light's place with its settings, as its child.
func _lantern_companion(light_name: String) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = light_name
	var lantern := _lantern_light as OmniLight3D
	if lantern:
		for property in [&"omni_range", &"omni_attenuation", &"omni_shadow_mode", &"light_specular", &"light_size", &"shadow_enabled", &"shadow_bias", &"shadow_normal_bias", &"shadow_blur", &"shadow_opacity"]:
			light.set(property, lantern.get(property))
	_lantern_light.add_child(light)
	return light
	if _lantern_frame_material:
		var level: Variant = _lantern_light.get(&"level")
		_lantern_frame_material.emission_energy_multiplier = lantern_flame_glow * (level if level is float else 1.0) if _lantern_light.visible else 0.0

## Moves _bob, the swinging point, on by one frame: its own speed, gravity, the push from the
## Player speeding up or slowing down, then the arm's length from the pivot and out of the leg.
func _swing_lantern(player: Node3D, bones: Transform3D, pivot: Vector3, delta: float) -> void:
	var player_velocity := (player.global_position - _player_position_before) / maxf(delta, 0.0001)
	var push := Vector3.ZERO
	if _bob_valid:
		push = -(player.global_basis.inverse() * ((player_velocity - _player_velocity_before) / maxf(delta, 0.0001))).limit_length(lantern_push_limit)
	_player_position_before = player.global_position
	_player_velocity_before = player_velocity
	if not lantern_swings or not _bob_valid:
		_bob = pivot + Vector3.DOWN * LANTERN_ARM
		_bob_before = _bob
		_bob_valid = true
		return

	var obstacles := []
	for obstacle in _lantern_obstacle_bones:
		obstacles.append([bones * _skeleton.get_bone_global_pose(obstacle[0]).origin, bones * _skeleton.get_bone_global_pose(obstacle[1]).origin, obstacle[2] + LANTERN_RADIUS])
	const STEPS := 2
	var step := minf(delta, 1.0 / 30.0) / STEPS # a long frame must not throw it
	for _i in STEPS:
		var moved := _bob + (_bob - _bob_before) * exp(-lantern_damping * step) + (Vector3.DOWN * LANTERN_GRAVITY + push) * step * step
		_bob_before = _bob
		_bob = moved
		var hit := false
		for _pass in 3:
			_bob = _on_arm(pivot)
			for obstacle in obstacles:
				var nearest := Geometry3D.get_closest_point_to_segment(_bob, obstacle[0], obstacle[1])
				var away := _bob - nearest
				var distance := away.length()
				if distance < obstacle[2]:
					# Out to the leg's surface; straight out from the body if it sits on the leg's axis.
					_bob = nearest + (away / distance if distance > 0.001 else _lantern_outward) * obstacle[2]
					hit = true
		_bob = _on_arm(pivot)
		# Never further from hanging straight than this, even where a raised leg would lift it
		# higher (it then sinks into the leg instead of standing on end).
		var arm := _bob - pivot
		var tilt := arm.angle_to(Vector3.DOWN)
		if tilt > deg_to_rad(lantern_max_angle):
			var around := Vector3.DOWN.cross(arm)
			if around.length_squared() > 0.000001:
				_bob = pivot + Vector3.DOWN.rotated(around.normalized(), deg_to_rad(lantern_max_angle)) * LANTERN_ARM
		if hit:
			_bob_before = _bob - (_bob - _bob_before) * lantern_bounce
		# A swinging leg hits at several metres a second, and the hips jolt with every step:
		# without a limit the lantern went over its own handle.
		_bob_before = _bob - (_bob - _bob_before).limit_length(lantern_max_speed * step)

## _bob brought back to the arm's length from the pivot.
func _on_arm(pivot: Vector3) -> Vector3:
	var arm := _bob - pivot
	return pivot + (arm.normalized() if arm.length_squared() > 0.000001 else Vector3.DOWN) * LANTERN_ARM

## The nearest of the eight DIRECTIONS to a velocity in the Player's axes (x right, y back).
func _direction(flat: Vector2) -> String:
	if flat.length_squared() < 0.0001:
		return "fwd"
	var clockwise_from_ahead := atan2(flat.x, -flat.y)
	return DIRECTIONS[posmod(roundi(clockwise_from_ahead / (PI / 4.0)), 8)]

func _playback_speed(speed: float, clip: StringName) -> float:
	return clampf(speed / maxf(CLIPS[clip][3], 0.01), min_playback_speed, max_playback_speed)

## The speed goes in as the clip's own (play()'s custom speed), not as the player's speed_scale:
## a cross-fade advances by speed_scale, so a clip frozen through it would never fade in.
func _play(clip: StringName, playback_speed: float) -> void:
	if clip == _clip and absf(playback_speed - _clip_speed) < 0.01:
		return
	_clip = clip
	_clip_speed = playback_speed
	_animations.play(clip, blend_time, playback_speed, playback_speed < 0.0)
