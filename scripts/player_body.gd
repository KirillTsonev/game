class_name PlayerBody
extends Node3D

## The player's own body, seen from the first-person camera: the rogue model, one clip at a
## time picked from how the Player moves, and the point where the camera belongs (the eyes).
## The root of scenes/player_body.tscn (the model, and the hook the lantern hangs from), which
## is the node "Body" of player.tscn; the Player calls set_motion() every physics frame and
## advance() every frame.
##
## The clips come from two packs with skeletons of their own (Quaternius' Universal Animation
## Library, CC0, and Kevin Iglesias' Human Basic Motions). Each pack and the rogue are imported
## onto Godot's humanoid bone names, so any clip plays on the rogue:
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
## Measured on the packs' root-motion versions; the library's are times 1.07, the rogue's
## legs being that much longer than its mannequin's.
const CLIPS := {
	&"idle": [UAL1, "Idle", true, 0.0],
	&"jog_fwd": ["run_fwd.fbx", "", true, 4.0],
	&"jog_fwd_left": ["run_fwd_left.fbx", "", true, 4.0],
	&"jog_fwd_right": ["run_fwd_right.fbx", "", true, 4.0],
	&"jog_left": ["run_left.fbx", "", true, 4.0],
	&"jog_right": ["run_right.fbx", "", true, 4.0],
	&"jog_bwd": ["run_bwd.fbx", "", true, 4.0],
	&"jog_bwd_left": ["run_bwd_left.fbx", "", true, 4.0],
	&"jog_bwd_right": ["run_bwd_right.fbx", "", true, 4.0],
	# The library's jog: a long bounding stride, the Player's default pace while that was
	# 6 m/s. (Its "Sprint" covers 8.8 m/s, for the 9.6 m/s the sprint was then.)
	&"sprint": [UAL1, "Jog_Fwd", true, 5.6],
	&"crouch_idle": [UAL1, "Crouch_Idle", true, 0.0],
	&"crouch_fwd": [UAL1, "Crouch_Fwd", true, 0.8],
	&"jump_air": [UAL1, "Jump", true, 0.0],
	&"jump_land": [UAL1, "Jump_Land", false, 0.0],
}
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
@export var still_speed: float = 0.3 ## m/s below which the Player counts as standing
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
@onready var _model: Node3D = $Rogue
## Where the lantern's handle hangs: a marker under a BoneAttachment3D, placed in the editor.
@onready var _lantern_hook: Node3D = $HipsAttachment/LanternHook
@onready var _lantern: Node3D = $HipsAttachment/LanternHook/LanternModel
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
var _turn: float = 0.0 ## the body's turn away from the Player's facing (radians, + = to the left)
var _turn_wanted: float = 0.0
var _clip_speed: float = 1.0
var _was_on_floor: bool = true
var _landing_left: float = 0.0

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
		library.add_animation(clip, animation)
	for source: AnimationPlayer in sources.values():
		source.owner.free()
	_animations = AnimationPlayer.new()
	_model.add_child(_animations) # its tracks ("%GeneralSkeleton:<bone>") start at the model's root
	_animations.add_animation_library(&"", library)
	_animations.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL # see advance()
	_play(&"idle", 1.0)

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

## local_velocity: the Player's velocity in its own axes (-Z forward, +X right).
func set_motion(local_velocity: Vector3, on_floor: bool, crouching: bool, sprinting: bool, delta: float) -> void:
	var flat := Vector2(local_velocity.x, local_velocity.z)
	var speed := flat.length()
	var direction := _direction(flat)
	_turn_wanted = 0.0
	if on_floor and not _was_on_floor and speed < 1.0:
		_landing_left = _animations.get_animation(&"jump_land").length
	_was_on_floor = on_floor
	_landing_left = maxf(_landing_left - delta, 0.0)

	if not on_floor:
		_landing_left = 0.0
		_play(&"jump_air", 1.0)
	elif _landing_left > 0.0 and speed < 1.0:
		_play(&"jump_land", 1.0)
	elif crouching:
		if speed <= still_speed:
			_play(&"crouch_idle", 1.0)
		else:
			# One clip for every direction; moving backward plays it in reverse.
			_play(&"crouch_fwd", _playback_speed(speed, &"crouch_fwd") * (-1.0 if direction.begins_with("bwd") else 1.0))
	elif speed <= still_speed:
		_play(&"idle", 1.0)
	elif sprinting and direction.begins_with("fwd"):
		# There is one sprint clip, straight ahead: sprinting diagonally forward is that clip
		# with the whole body turned the way it goes.
		if direction != "fwd":
			_turn_wanted = diagonal_turn * (1.0 if direction == "fwd_left" else -1.0)
		_play(&"sprint", _playback_speed(speed, &"sprint"))
	else:
		var clip := StringName("jog_" + direction)
		_play(clip, _playback_speed(speed, clip))

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
	# Half a turn (the model faces +Z, the Player looks along -Z) plus the turn into a diagonal.
	_turn = lerp_angle(_turn, _turn_wanted, 1.0 - exp(-delta * diagonal_turn_rate))
	_model.rotation.y = PI + _turn
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
	_place_lantern(player, delta)

## The lantern hangs from its place by the hips and swings there; the light sits in its flame,
## and the flame glows only while the light is on (L).
func _place_lantern(player: Node3D, delta: float) -> void:
	# The skeleton's bones in the Player's space.
	var bones := player.global_transform.affine_inverse() * _skeleton.global_transform
	var pivot: Vector3 = bones * (_skeleton.get_bone_global_pose(_hook_bone) * _hook_offset)
	_swing_lantern(player, bones, pivot, delta)
	# Its handle's top at the pivot, its body toward the swinging point, turned with the Player.
	var up := (pivot - _bob).normalized()
	var side := up.cross(Vector3.BACK)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	# The model's wide axis (its X) runs front to back, so its thin side is toward the leg.
	_lantern.global_transform = player.global_transform * Transform3D(Basis(side.cross(up), up, -side), pivot)
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
		_lantern_frame_material.emission_energy_multiplier = lantern_flame_glow if _lantern_light.visible else 0.0

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
