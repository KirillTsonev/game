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
var _weapon_node: Node3D ## the held weapon's model
var _weapon_socket: Transform3D ## the fist's middle in the right hand bone's axes (WeaponHold.socket)
var _weapon_fist: Array[float] = [] ## how far each finger closes round the held weapon
var _weapon_up: float = 0.0 ## 0-1: how far the right arm is into the stance (weapon_raised)
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
## Off, or with no such node: the arm is the clip's, the weapon still in its fist.
@export var weapon_raised: bool = true
@export var weapon_raise_time: float = 0.25 ## seconds to bring it up or let it down
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
	equip(weapon)
	if _lantern_light:
		var body_bit := 1 << (BODY_LAYER - 1)
		for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false) + _lantern.find_children("*", "MeshInstance3D", true, false):
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
	library.add_animation(&"idle_mirror", _mirrored(library.get_animation(&"idle")))
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
func _mirrored(animation: Animation) -> Animation:
	var mirror := animation.duplicate(true) as Animation
	for track in mirror.get_track_count():
		var path := mirror.track_get_path(track)
		var bone := String(path.get_concatenated_subnames())
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

## Starts turning the lantern on or off; ignored while one is under way and while in the air.
func toggle_lantern() -> void:
	# Not in the air (a jump, a fall): the press is dropped, nothing happens.
	if _toggle_at >= 0.0 or _lantern_light == null or not _was_on_floor:
		return
	_toggle_at = 0.0
	_toggle_lighting = not _lantern_light.visible
	_pinch_grip_valid = false
	_toggle_dips = not _sprinting

## True while an action is moving the camera (turning the lantern on / off, unless it was
## started sprinting, when the view is left alone): the Player ignores the mouse meanwhile.
func has_the_view() -> bool:
	return _toggle_at >= 0.0 and _toggle_dips

## What to add to the camera's rotation just now (radians; x = pitch, 0 or below; y = turn,
## negative = to the right; z = tilt, negative = right ear down): the look of toggle_lantern().
func view_offset() -> Vector3:
	return Vector3(_view_dip, -deg_to_rad(toggle_turn_degrees) * _toggle_view, -deg_to_rad(toggle_roll_degrees) * _toggle_view)

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
	_advance_arm(delta)
	_advance_toggle(delta, camera_pitch)
	camera_pitch += _view_dip
	# Half a turn (the model faces +Z, the Player looks along -Z) plus the turn into a diagonal.
	_turn = lerp_angle(_turn, _turn_wanted, 1.0 - exp(-delta * diagonal_turn_rate))
	_model.rotation.y = PI + _turn
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
	_hold_weapon(player, delta) # before the lantern: the reach to it sets off from this pose
	_place_lantern(player, delta)
	# After the lantern: turning it on / off moves the right arm.
	if _weapon_node:
		_weapon_node.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_arms["Right"]["hand"]) * WeaponHold.in_hand(_weapon_socket, weapon)

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
	_weapon_fist = WeaponHold.fist_curls(_skeleton, "Right", data.grip_radius)
	# Placed by this script in the same frame as the pose, like the lantern.
	_weapon_node = data.scene.instantiate() as Node3D
	add_child(_weapon_node)
	_weapon_node.top_level = true
	if _lantern_light:
		for mesh: MeshInstance3D in _weapon_node.find_children("*", "MeshInstance3D", true, false):
			mesh.layers = 1 << (BODY_LAYER - 1)

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
	_weapon_up = move_toward(_weapon_up, 1.0 if weapon_raised and (_stance or reference) and not weapon_arm_from_clips else 0.0, delta / maxf(weapon_raise_time, 0.01))
	var weight := smoothstep(0.0, 1.0, _weapon_up)
	if weight > 0.001:
		# The stance outright, then back toward the clip's arm by what is left of the weight.
		var arm_bones: Array[int] = [arm["upper"], arm["lower"], arm["hand"]]
		var in_clip: Array = [_skeleton.get_bone_pose_position(arm["upper"])]
		for bone in arm_bones:
			in_clip.append(_skeleton.get_bone_pose_rotation(bone))
		var to_skeleton := (player.global_transform.affine_inverse() * _skeleton.global_transform).affine_inverse()
		var held_from := _eye + _weapon_bob(delta) # the eyes, and the bob of the steps
		if reference:
			# The wrist itself is put where the clip has it (no reach limit: its arm is shorter).
			WeaponHold.solve_arm(_skeleton, "Right", to_skeleton, held_from + (frame["shoulder"] as Vector3), held_from + (frame["wrist"] as Vector3),
					(frame["elbow"] as Vector3) - (frame["shoulder"] as Vector3), frame["hand"] as Basis, Vector3.ZERO, 1.0)
		else:
			_stance.pose(_skeleton, to_skeleton, held_from, _stance.fist_in_hand(_skeleton, weapon.grip_radius))
		if weight < 0.999:
			_skeleton.set_bone_pose_position(arm["upper"], (in_clip[0] as Vector3).lerp(_skeleton.get_bone_pose_position(arm["upper"]), weight))
			for i in arm_bones.size():
				_skeleton.set_bone_pose_rotation(arm_bones[i], (in_clip[i + 1] as Quaternion).slerp(_skeleton.get_bone_pose_rotation(arm_bones[i]), weight))
	if _stance:
		_stance.pose_fingers(_skeleton, weapon.grip_radius) # as posed by hand in the editor
	else:
		_set_fingers(arm, _weapon_fist, 1.0)

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
		var swung := _part(through, TOGGLE_SWING) * (1.0 - _part(through, TOGGLE_BACK))
		var forward := deg_to_rad(toggle_swing_degrees)
		if through < TOGGLE_SWING[0]:
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
		_reach(_arms["Right"], "palm", bones, _bob + toggle_cup_offset, reaching, TOGGLE_ELBOW, -cup)
		var closed := [0.0, 0.0, 0.0, 0.0, 0.0]
		for i in closed.size():
			var late := 0.015 * i
			var gripping := smoothstep(TOGGLE_REACH[1] - 0.07 + late, TOGGLE_REACH[1] + 0.05 + late, through) * (1.0 - smoothstep(TOGGLE_RELEASE[0] - 0.02 + late, TOGGLE_RELEASE[0] + 0.08 + late, through))
			closed[i] = lerpf(toggle_open_curl, toggle_cup_curl * (0.6 if i == 0 else 1.0), gripping)
		_set_fingers(_arms["Right"], closed, reaching)
	# Its handle's top at the pivot, its body toward the swinging point, turned with the Player.
	var up := (pivot - _bob).normalized()
	var side := up.cross(Vector3.BACK)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	# The model's wide axis (its X) runs front to back, so its thin side is toward the leg.
	var lantern_place := Transform3D(Basis(side.cross(up), up, -side), pivot)
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
		var rolling := toggle_knob_roll * turned * way
		# The thumb closes half as far as the fingers and swings in to meet them.
		_set_fingers(left, [lerpf(0.0, toggle_pinch_curl * 0.5, pinching) + rolling, pinched - rolling, pinched - rolling * 0.5, folded, folded], coming, toggle_pinch_thumb_in * pinching)
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
		if through >= TOGGLE_TUG[0] and _pinch_grip_valid:
			var rod_own := Vector3(toggle_knob.x, 0.0, toggle_knob.z).normalized()
			turning = lantern_place.basis * Basis(rod_own, toggle_knob_turn * turned * way) * _pinch_grip
		_reach(left, "pinch", bones, lantern_place * toggle_knob + rod * toggle_pinch_gap, coming, TOGGLE_LEFT_ELBOW, Vector3.DOWN, 0.0, front, -rod, to_tips, turning)
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
func _reach(arm: Dictionary, point: String, bones: Transform3D, target: Vector3, weight: float, elbow: Vector3, palm_toward: Vector3, roll: float = 0.0, around: Vector3 = Vector3.INF, fingers_toward: Vector3 = Vector3.INF, aim: Vector3 = Vector3.INF, given: Variant = null) -> void:
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
		var distance := clampf(to_goal.length(), absf(upper_length - lower_length) + 0.001, upper_length + lower_length - 0.001)
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
