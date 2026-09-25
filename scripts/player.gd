extends CharacterBody3D

# Minimal first-person walk-and-look controller.
# No combat, no interaction, no AI -- just movement, by design.

@export var speed: float = 4.5
@export var mouse_sensitivity: float = 0.003
@export var gravity: float = 9.8

@onready var camera: Camera3D = $Camera3D

var pitch: float = 0.0

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
	# player.tscn's CollisionShape3D sits at local y=0.9 -- exactly the
	# capsule's own half-height -- so the capsule's bottom lines up with the
	# CharacterBody3D's own origin. In other words global_position.y IS foot
	# level already; only a small clearance is needed so it doesn't spawn
	# clipped a hair into the ground.
	const SPAWN_CLEARANCE := 0.1
	global_position.y = ground_height + SPAWN_CLEARANCE
	#global_position.y = 15

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look, only while the cursor is captured.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		pitch = clamp(pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		camera.rotation.x = pitch

	# Esc is now handled by the PauseMenu autoload (opens the pause menu and
	# releases the mouse itself). Click back into the window to re-capture
	# the mouse during normal play (e.g. after alt-tabbing).
	if event is InputEventMouseButton and event.pressed:
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
	if not is_on_floor():
		velocity.y -= gravity * delta

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

	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

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

	if is_on_floor():
		last_safe_transform = global_transform
	elif global_position.y < FALL_RESET_Y:
		print("FALL: player dropped below y=%.1f (at %s) -- resetting to last safe position %s" % [FALL_RESET_Y, global_position, last_safe_transform.origin])
		global_transform = last_safe_transform
		velocity = Vector3.ZERO

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
