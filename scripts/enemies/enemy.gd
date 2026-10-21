## One enemy (2026-10-21, rudimentary; a coloured capsule for now, its colour = its state). It
## lives on EnemyGrid's cells: think() runs once per EnemyDirector.TICK and decides what to do and
## where to go; move() runs every frame and slides it toward the next cell of its path, which it
## must reserve first (EnemyDirector.reserve), so two enemies never stand on one cell.
##
## States: IDLE (stands a while), WANDER (to a random cell within WANDER_RADIUS of home), CHASE
## (the player was seen within NOTICE_RADIUS: a path to the player's cell, renewed when that
## changes), ATTACK (within ATTACK_RANGE: faces the player and lunges every ATTACK_INTERVAL --
## no damage yet), RETURN (lost the player: back home, then IDLE). The player is seen when a ray
## from the enemy's eyes to the player's chest hits nothing else.
class_name Enemy
extends Node3D

enum State { IDLE, WANDER, CHASE, ATTACK, RETURN }

const WALK_SPEED := 1.4 ## m/s, wandering and going home
const CHASE_SPEED := 3.8 ## m/s (the player jogs at 3, sprints at 4.8)
const NOTICE_RADIUS := 18.0 ## m: seen nearer than this, the player is noticed
const LOSE_RADIUS := 32.0 ## m: farther than this, or out of sight for LOSE_TIME, the chase ends
const LOSE_TIME := 4.0 ## s
const ATTACK_RANGE := 1.8 ## m between the enemy's middle and the player's
const ATTACK_INTERVAL := 1.2 ## s between lunges
const LUNGE_TIME := 0.35 ## s
const LUNGE_REACH := 0.45 ## m the body moves forward at the lunge's peak
const WANDER_RADIUS := 10.0 ## m from home
const IDLE_TIME := Vector2(1.5, 5.0) ## s, random between these
const STUCK_TICKS := 2 ## ticks waiting for a reserved cell before looking for a way round
const EYE_HEIGHT := 1.55 ## m above the feet
const TARGET_HEIGHT := 1.0 ## m above the player's origin (its feet) the eyes aim at
const TURN_RATE := 10.0 ## how fast it turns toward where it goes (1/s, eased)
const HEIGHT := 1.8
const RADIUS := 0.35
const STATE_COLOURS := {
	State.IDLE: Color(0.35, 0.55, 0.35),
	State.WANDER: Color(0.45, 0.65, 0.4),
	State.CHASE: Color(0.95, 0.55, 0.1),
	State.ATTACK: Color(0.9, 0.12, 0.1),
	State.RETURN: Color(0.35, 0.45, 0.8),
}

var state := State.IDLE
var cell := Vector2i.ZERO ## the cell it stands on (or is leaving)
var home := Vector2i.ZERO
var next_think := 0.0 ## time of its next think(), s (EnemyDirector's clock)

var _path: Array[Vector2i] = []
var _goal := Vector2i(-1, -1) ## the end of _path
var _step_to := Vector2i(-1, -1) ## the cell it is moving onto, (-1, -1) = standing
var _waited := 0 ## ticks spent waiting for the next cell
var _idle_left := 0.0
var _last_seen := -INF
var _attack_left := 0.0
var _lunge := 0.0 ## time left in the running lunge, s
var _yaw_goal := 0.0
var _body: Node3D
var _material: StandardMaterial3D

func place(director: EnemyDirector, at: Vector2i, first_think: float) -> void:
	cell = at
	home = at
	next_think = first_think
	director.reserve(cell, self)
	global_position = director.grid.world_of(cell)
	_yaw_goal = randf() * TAU
	rotation.y = _yaw_goal
	_idle_left = randf_range(IDLE_TIME.x, IDLE_TIME.y)
	_build_body()
	_set_state(State.IDLE)

func _build_body() -> void:
	_material = StandardMaterial3D.new()
	_material.roughness = 0.8
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	var capsule := CapsuleMesh.new()
	capsule.radius = RADIUS
	capsule.height = HEIGHT
	var mesh := MeshInstance3D.new()
	mesh.name = "Capsule"
	mesh.mesh = capsule
	mesh.material_override = _material
	mesh.position.y = HEIGHT * 0.5
	_body.add_child(mesh)
	# Something to show which way it faces (-Z, like every Node3D's forward).
	var visor := BoxMesh.new()
	visor.size = Vector3(0.36, 0.1, 0.12)
	var visor_material := StandardMaterial3D.new()
	visor_material.albedo_color = Color(0.08, 0.08, 0.08)
	var face := MeshInstance3D.new()
	face.name = "Visor"
	face.mesh = visor
	face.material_override = visor_material
	face.position = Vector3(0.0, EYE_HEIGHT, -RADIUS + 0.02)
	_body.add_child(face)

func _set_state(s: State) -> void:
	state = s
	_material.albedo_color = STATE_COLOURS[s]

## Once per tick: what to do now.
func think(director: EnemyDirector, now: float) -> void:
	var grid := director.grid
	var player := director.player
	var hunting := state == State.CHASE or state == State.ATTACK
	var to_player := INF
	var player_at := Vector3.ZERO
	var seen := false
	if is_instance_valid(player):
		player_at = player.global_position
		to_player = Vector2(player_at.x - global_position.x, player_at.z - global_position.z).length()
		seen = to_player < (LOSE_RADIUS if hunting else NOTICE_RADIUS) and _sees(player, player_at)
		if seen:
			_last_seen = now
	if not hunting and seen:
		_set_state(State.CHASE)
		hunting = true
	elif hunting and (to_player > LOSE_RADIUS or now - _last_seen > LOSE_TIME):
		_set_state(State.RETURN)
		hunting = false
		_go_to(director, home)

	match state:
		State.IDLE:
			_idle_left -= EnemyDirector.TICK
			if _idle_left <= 0.0 and _pick_wander_goal(director):
				_set_state(State.WANDER)
		State.WANDER, State.RETURN:
			if _path.is_empty() and _step_to.x < 0:
				_set_state(State.IDLE)
				_idle_left = randf_range(IDLE_TIME.x, IDLE_TIME.y)
		State.CHASE:
			if to_player <= ATTACK_RANGE:
				_set_state(State.ATTACK)
				_path.clear()
				_attack_left = 0.0
			else:
				var target := grid.nearest_walkable(grid.cell_of(player_at), 3, grid.area_of(cell))
				if target.x >= 0 and (target != _goal or (_path.is_empty() and _step_to.x < 0)):
					_go_to(director, target)
		State.ATTACK:
			if to_player > ATTACK_RANGE + 0.6:
				_set_state(State.CHASE)
			else:
				_attack_left -= EnemyDirector.TICK
				if _attack_left <= 0.0:
					_lunge = LUNGE_TIME
					_attack_left = ATTACK_INTERVAL

	# Waiting for a cell someone else holds: after STUCK_TICKS, a way round them.
	if _step_to.x < 0 and not _path.is_empty():
		_waited += 1
		if _waited >= STUCK_TICKS:
			_waited = 0
			_path = director.crowd_path(self, cell, _goal)

## Each frame: along the path, cell by cell.
func move(director: EnemyDirector, delta: float) -> void:
	var grid := director.grid
	if _step_to.x < 0:
		_take_step(director)
	var pos := global_position
	if _step_to.x >= 0:
		var target := Vector2(grid.corner.x + _step_to.x, grid.corner.z + _step_to.y)
		var here := Vector2(pos.x, pos.z)
		var to_target := target - here
		if to_target.length_squared() > 0.0001:
			_yaw_goal = atan2(-to_target.x, -to_target.y)
		var speed := CHASE_SPEED if state == State.CHASE else WALK_SPEED
		here = here.move_toward(target, speed * delta)
		pos.x = here.x
		pos.z = here.y
		if here.is_equal_approx(target):
			director.release(cell, self)
			cell = _step_to
			_step_to = Vector2i(-1, -1)
			_take_step(director) # straight on to the next cell, no stop between them
	elif state == State.ATTACK and is_instance_valid(director.player):
		var to_player := director.player.global_position - pos
		_yaw_goal = atan2(-to_player.x, -to_player.z)
	pos.y = grid.ground_height(pos.x, pos.z)
	global_position = pos
	rotation.y = lerp_angle(rotation.y, _yaw_goal, 1.0 - exp(-TURN_RATE * delta))
	# The lunge: the body leans and moves forward and back, the feet stay on the cell.
	if _lunge > 0.0:
		_lunge = maxf(_lunge - delta, 0.0)
	var k := sin(PI * (1.0 - _lunge / LUNGE_TIME)) if _lunge > 0.0 else 0.0
	_body.position = Vector3(0.0, 0.0, -LUNGE_REACH * k)
	_body.rotation.x = -0.35 * k

func _take_step(director: EnemyDirector) -> void:
	if _path.is_empty() or state == State.ATTACK:
		return
	if director.reserve(_path[0], self):
		_step_to = _path.pop_front()
		_waited = 0

## A new path to `goal` (from the cell it is stepping onto, if it is moving).
func _go_to(director: EnemyDirector, goal: Vector2i) -> void:
	_goal = goal
	_path = director.grid.find_path(_step_to if _step_to.x >= 0 else cell, goal)

func _pick_wander_goal(director: EnemyDirector) -> bool:
	var grid := director.grid
	for attempt in 6:
		var offset := Vector2.from_angle(randf() * TAU) * sqrt(randf()) * WANDER_RADIUS
		var c := home + Vector2i(roundi(offset.x), roundi(offset.y))
		if c != cell and grid.walkable(c) and grid.area_of(c) == grid.area_of(cell):
			_go_to(director, c)
			if not _path.is_empty():
				return true
	return false

func _sees(player: Node3D, player_at: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3(0.0, EYE_HEIGHT, 0.0), player_at + Vector3(0.0, TARGET_HEIGHT, 0.0))
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.collider == player
