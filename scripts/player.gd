extends CharacterBody3D

# Minimal first-person walk-and-look controller.
# No combat, no interaction, no AI -- just movement, by design.

@export var speed: float = 4.5
@export var mouse_sensitivity: float = 0.003
@export var gravity: float = 9.8
@export var jump_velocity: float = 4.5 ## about 1 m of height at gravity 9.8
@export var sprint_multiplier: float = 1.6
## Speed straight sideways and in the three backward directions, as a share of the forward
## speed; not while crouched. 1 = the same speed everywhere. It was 0.67 for an afternoon,
## while the pace was 6 m/s and the body's sideways and backward run clips, made for 4 m/s,
## played at 1.5 times their pace; the pace is 4 m/s now (player.tscn, Kirill, 2026-10-12)
## and one set of run clips covers all eight directions.
@export var off_forward_multiplier: float = 1.0
@export var crouch_multiplier: float = 0.5
## Capsule height while crouched (standing: the scene's capsule). The body's crouch clip keeps
## the hood under about 1.05 m and the eyes at about 0.9 m; the camera must stay inside the capsule.
@export var crouch_height: float = 1.1
@export var crouch_camera_height: float = 0.95 ## only without a Body node: with one the camera follows its head
@export var crouch_time: float = 0.15 ## seconds to ease between standing and crouched
## 4 m in 0.4 s since 2026-10-12 (was 5 m in 0.2 s), for the body's dash clips: they are hops
## of about 2 m in a second, and over 0.2 s one would have played at five times its pace.
@export var dash_distance: float = 4.0 ## metres covered by one dash on open ground
@export var dash_time: float = 0.4 ## seconds a dash lasts
@export var dash_cooldown: float = 0.8 ## seconds after a dash ends before the next one
@export var dash_double_tap_time: float = 0.25 ## longest gap between the two presses of a double tap

@onready var camera: Camera3D = $Camera3D
@onready var collision: CollisionShape3D = $CollisionShape3D
## The visible body (scripts/player_body.gd). Without the node the player is a bare camera, as before.
@onready var body: PlayerBody = get_node_or_null("Body") as PlayerBody

var pitch: float = 0.0

## DEBUG (PerfDebug V): fly mode. No gravity and no collision: WASD moves where the camera
## looks, Space up, Ctrl down, Shift held = fast. Walls, terrain and the world's edges do not stop it.
var debug_fly: bool = false
const FLY_SPEED := 15.0 ## m/s
const FLY_FAST_MULTIPLIER := 6.0

## Sprint (Shift) and crouch (Ctrl) are toggles and cancel each other.
var _sprinting: bool = false
var _crouching: bool = false
var _crouch_t: float = 0.0 ## 0 = standing, 1 = fully crouched
var _capsule: CapsuleShape3D
var _stand_height: float
var _stand_camera_height: float
## Space stood the player up from a crouch: no jump until the key is released.
var _jump_held_from_crouch: bool = false

## Dash: W / A / S / D pressed twice within dash_double_tap_time, on the ground only. Its
## direction is fixed when it starts; a crouched player stands up first (no headroom = no dash).
var _dash_direction: Vector3 = Vector3.ZERO
var _dash_left: float = 0.0 ## seconds of the running dash still to go, 0 = not dashing
var _dash_cooldown_left: float = 0.0
var _last_tap_key: Key = KEY_NONE
var _last_tap_msec: int = 0

## Stall detector: logs a diagnostic entry (with the actual colliders
## involved) whenever the player is trying to move but barely progressing,
## so a "stuck at a chunk seam" report can be diagnosed by querying this
## array at runtime instead of relying on screenshots. Read it live with
## query_runtime_node on the Player, property "debug_log".
var debug_log: Array = []
const DEBUG_LOG_MAX := 30
var _stuck_frames: int = 0

## Safety net for chunk-geometry gaps that let the player fall out of the
## level entirely: track the last position the player was actually
## standing on solid ground, and snap back there if they ever fall well
## below any reasonable floor height. FALL_RESET_Y is far below any real
## chunk floor (all chunk floors sit near y=0) so this only fires on a
## genuine fall-through.
const FALL_RESET_Y := -50.0
var last_safe_transform: Transform3D

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Own copy of the capsule: crouching resizes it, and the scene's sub-resource is shared.
	_capsule = collision.shape.duplicate() as CapsuleShape3D
	collision.shape = _capsule
	_stand_height = _capsule.height
	_stand_camera_height = camera.position.y
	_snap_to_ground()
	last_safe_transform = global_transform

## Terrain is procedurally regenerated (see terrain_gen.gd) and comes out a
## different shape/height every run, so a hardcoded spawn Y baked into the
## scene's transform goes stale the moment the terrain changes -- either
## burying the player or dropping them from height. On ready, if a
## Terrain3D node exists anywhere in the tree (test scenes like
## level_zone.tscn don't have one, so this is a no-op there), query the
## ACTUAL generated height at this spawn XZ and snap just above it instead
## of trusting the scene's baked Y.
func _snap_to_ground() -> void:
	var terrains := get_tree().root.find_children("*", "Terrain3D", true, false)
	if terrains.is_empty():
		return
	var terrain: Terrain3D = terrains[0]
	var data: Terrain3DData = terrain.get_data()
	if data == null:
		return
	var ground_height: float = data.get_height(global_position)
	if is_nan(ground_height):
		return # spawn XZ falls outside any generated region -- leave the scene's baked position alone rather than guess
	# player.tscn's CollisionShape3D sits at local y=0.925 -- exactly the
	# capsule's own half-height -- so the capsule's bottom lines up with the
	# CharacterBody3D's own origin. In other words global_position.y IS foot
	# level already; only a small clearance is needed so it doesn't spawn
	# clipped a hair into the ground.
	const SPAWN_CLEARANCE := 0.1
	global_position.y = ground_height + SPAWN_CLEARANCE
	#global_position.y = 15

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look, only while the cursor is captured.
	# Not while the body has the view (turning the lantern on / off): the mouse is ignored
	# then, and the view comes back to where it was (Kirill, 2026-10-12).
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not (body and body.has_the_view()):
		rotate_y(-event.relative.x * mouse_sensitivity)
		pitch = clamp(pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		camera.rotation.x = pitch

	# Esc is now handled by the PauseMenu autoload (opens the pause menu and
	# releases the mouse itself). Click back into the window to re-capture
	# the mouse during normal play (e.g. after alt-tabbing).
	# L = lantern on/off (the OmniLight3D "Lantern" on the belt, player.tscn). Its child
	# "GroundPool" (the overhead spot that lights the ground) hides with it.
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_L:
		var lantern := get_node_or_null("Lantern") as Light3D
		if body:
			body.toggle_lantern() # the view dips, and the light changes part-way through
		elif lantern:
			lantern.visible = not lantern.visible

	# Shift = sprint on/off, Ctrl = crouch on/off, Space while crouched = stand up (no jump).
	if event is InputEventKey and event.pressed and not event.echo and not debug_fly:
		match event.physical_keycode:
			KEY_SHIFT:
				_set_crouching(false)
				if not _crouching: # still crouched = no headroom to stand, so no sprint either
					_sprinting = not _sprinting
			KEY_CTRL:
				_set_crouching(not _crouching)
			KEY_SPACE:
				if _crouching:
					_set_crouching(false)
					_jump_held_from_crouch = true
			KEY_W:
				_tap_for_dash(KEY_W, Vector3.FORWARD)
			KEY_S:
				_tap_for_dash(KEY_S, Vector3.BACK)
			KEY_A:
				_tap_for_dash(KEY_A, Vector3.LEFT)
			KEY_D:
				_tap_for_dash(KEY_D, Vector3.RIGHT)

	# Left click only (2026-09-27): the mouse WHEEL is also an InputEventMouseButton, and
	# re-capturing on it stole the cursor from UI like the grass tuning panel.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and body:
			body.attack() # a click that only takes the cursor back is not a swing
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Plain, standard CharacterBody3D FPS pattern (the same shape used by
## Godot's own demos/docs) -- gravity only while not on the floor, WASD
## always drives horizontal velocity, move_and_slide() resolves collision.
## Earlier revisions added coyote-time floor debouncing and an automatic
## "unstick" teleport on top of this; both were removed after live testing
## showed they weren't fixing the actual reported problem (WASD producing
## zero movement, including zero movement from the unconditional unstick
## teleport itself) -- that points at something other than movement/
## collision logic, so the custom machinery was net complexity with no
## evidence it helped. Back to the plain baseline.
func _physics_process(delta: float) -> void:
	if debug_fly:
		_fly(delta)
		return
	if not is_on_floor():
		velocity.y -= gravity * delta

	# A hard landing holds the player where it came down until the body has risen again.
	var landing_hard: bool = body != null and body.holds_player()

	# Jump: held Space jumps again on landing. Not while crouched or still standing up.
	if not Input.is_key_pressed(KEY_SPACE):
		_jump_held_from_crouch = false
	elif is_on_floor() and not _crouching and not _jump_held_from_crouch and not landing_hard:
		velocity.y = jump_velocity

	_update_crouch(delta)

	# Raw WASD reads -- no Input Map setup required to try this out.
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.y -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	input_dir = input_dir.normalized()
	if landing_hard:
		input_dir = Vector2.ZERO

	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var move_speed := speed
	if _crouching:
		move_speed *= crouch_multiplier
	else:
		if input_dir.y >= 0.0: # not forward at all (W not held, or cancelled by S)
			move_speed *= off_forward_multiplier
		elif _sprinting: # sprinting is forward and diagonally forward only: there is no clip for the rest
			move_speed *= sprint_multiplier

	_dash_cooldown_left = maxf(_dash_cooldown_left - delta, 0.0)
	var dash_ended := false
	if _dash_left > 0.0:
		# The dash replaces the WASD velocity; walls still stop it in move_and_slide().
		_dash_left -= delta
		direction = _dash_direction
		var dash_speed := dash_distance / maxf(dash_time, 0.001)
		velocity.x = direction.x * dash_speed
		velocity.z = direction.z * dash_speed
		if _dash_left <= 0.0:
			_dash_left = 0.0
			_dash_cooldown_left = dash_cooldown
			dash_ended = true
	elif direction:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		_sprinting = false # sprint ends when the player stops, so the next walk starts at walking pace
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	# Saplings have no colliders: their stems bend the path around them instead (brush past, no stop).
	velocity = SaplingScatter.steer_around_stems(global_position, velocity)

	# Snapshot BEFORE move_and_slide() -- it mutates `velocity` in place based
	# on collision response, so if the player is fully blocked in every
	# direction it zeroes velocity.x/z right along with actually stopping
	# them. _log_if_stuck used to read `velocity` AFTER this call, so a
	# total block looked identical to "no input attempted" (0 intended vs 0
	# actual) and silently never got logged -- exactly backwards from what a
	# stall detector needs to catch.
	var velocity_before_slide := velocity
	var pos_before := global_position
	move_and_slide()
	_log_if_stuck(direction, velocity_before_slide, delta, pos_before)
	if body:
		# The velocity after the slide: walking into a wall plays the idle clip.
		body.set_motion(transform.basis.inverse() * velocity, is_on_floor(), _crouching, _sprinting, delta)
	if dash_ended:
		# No slide past the dash's distance: the next frame starts from the WASD velocity.
		velocity.x = 0.0
		velocity.z = 0.0

	if is_on_floor():
		last_safe_transform = global_transform
	elif global_position.y < FALL_RESET_Y:
		print("FALL: player dropped below y=%.1f (at %s) -- resetting to last safe position %s" % [FALL_RESET_Y, global_position, last_safe_transform.origin])
		global_transform = last_safe_transform
		velocity = Vector3.ZERO

## DEBUG fly mode (see debug_fly): moves the body directly, so nothing collides with it.
func _fly(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move -= camera.global_basis.z
	if Input.is_key_pressed(KEY_S):
		move += camera.global_basis.z
	if Input.is_key_pressed(KEY_A):
		move -= camera.global_basis.x
	if Input.is_key_pressed(KEY_D):
		move += camera.global_basis.x
	if Input.is_key_pressed(KEY_SPACE):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		move += Vector3.DOWN
	var fly_speed := FLY_SPEED * (FLY_FAST_MULTIPLIER if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if move.length_squared() > 0.0:
		global_position += move.normalized() * fly_speed * delta
	velocity = Vector3.ZERO

## One press of a movement key: the second press of the same key in time starts a dash along
## local_direction (the body's own axes).
func _tap_for_dash(key: Key, local_direction: Vector3) -> void:
	var now := Time.get_ticks_msec()
	var is_double := key == _last_tap_key and now - _last_tap_msec <= int(dash_double_tap_time * 1000.0)
	_last_tap_key = key
	_last_tap_msec = now
	if not is_double:
		return
	_last_tap_key = KEY_NONE # a third quick press starts a new double tap, not another dash
	if _dash_left > 0.0 or _dash_cooldown_left > 0.0 or not is_on_floor():
		return
	if body and body.holds_player():
		return
	_set_crouching(false)
	if _crouching:
		return
	_dash_direction = (transform.basis * local_direction).normalized()
	_dash_left = dash_time
	if body:
		body.start_dash(local_direction, dash_time)

## Standing up is refused while something is overhead: the body's current shape is swept up
## by the height it still has to grow.
func _set_crouching(want: bool) -> void:
	if want == _crouching:
		return
	if not want and test_move(global_transform, Vector3.UP * (_stand_height - _capsule.height)):
		return
	_crouching = want
	if want:
		_sprinting = false

## Eases the capsule and the camera between standing and crouched. The capsule shrinks from
## the top: its bottom stays at the body's origin (foot level, see _snap_to_ground).
func _update_crouch(delta: float) -> void:
	var target := 1.0 if _crouching else 0.0
	if _crouch_t == target:
		return
	_crouch_t = move_toward(_crouch_t, target, delta / maxf(crouch_time, 0.001))
	_capsule.height = lerpf(_stand_height, crouch_height, _crouch_t)
	collision.position.y = _capsule.height * 0.5
	if body == null:
		camera.position.y = lerpf(_stand_camera_height, crouch_camera_height, _crouch_t)

## With a body the camera sits at its eyes, which move with the clip being played (lower and
## further forward when jogging, lower still when sneaking).
func _process(delta: float) -> void:
	if body:
		body.advance(delta, pitch)
		if body.has_eye_position():
			camera.position = body.eye_position()
		# `pitch` stays the Player's own: the look at the lantern is added for as long as it lasts.
		camera.rotation = Vector3(pitch, 0.0, 0.0) + body.view_offset()

func _log_if_stuck(direction: Vector3, velocity_before_slide: Vector3, delta: float, pos_before: Vector3) -> void:
	var actual_move := global_position - pos_before
	var intended_move := Vector3(velocity_before_slide.x, 0, velocity_before_slide.z) * delta

	# "Stuck" = actively trying to move but barely progressing, for several
	# frames in a row (one bad frame is normal contact resolution noise).
	if direction != Vector3.ZERO and intended_move.length() > 0.01 and actual_move.length() < intended_move.length() * 0.1:
		_stuck_frames += 1
	else:
		_stuck_frames = 0
		return

	# Log once on the frame it becomes a real stall, then every 30 frames
	# (~0.5s) after that while it persists, so the log stays fresh without
	# flooding every physics tick.
	if _stuck_frames == 5 or (_stuck_frames > 5 and _stuck_frames % 30 == 0):
		var collisions: Array = []
		for i in get_slide_collision_count():
			var col := get_slide_collision(i)
			var collider := col.get_collider()
			collisions.append({
				"collider_name": collider.name if collider else "?",
				"collider_path": str(collider.get_path()) if collider else "?",
				"normal": col.get_normal(),
				"position": col.get_position(),
				"travel": col.get_travel(),
				"remainder": col.get_remainder(),
			})
		var entry := {
			"stuck_frames": _stuck_frames,
			"player_position": global_position,
			"intended_move": intended_move,
			"actual_move": actual_move,
			"slide_collision_count": get_slide_collision_count(),
			"collisions": collisions,
		}
		debug_log.append(entry)
		if debug_log.size() > DEBUG_LOG_MAX:
			debug_log.pop_front()
		print("STUCK frame=", _stuck_frames, " pos=", global_position, " intended=", intended_move, " actual=", actual_move, " collisions=", collisions)
