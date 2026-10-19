extends SceneTree
# Crouched and still, weapons up (either foot forward): the view tipped from level to straight
# down in a short time, as a quick look down. The least room between the shield's vertices and
# the trunk's and legs' capsules (as shield_backward.gd), per 0.1 s after the look starts, and
# the keep-off's turn and move. `-- --turn-speed=<deg/s>` overrides shield_clear_turn_speed.
var player: Node3D
var body: PlayerBody

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--turn-speed="):
			body.shield_clear_turn_speed = arg.trim_prefix("--turn-speed=").to_float()
		elif arg.begins_with("--ease="):
			body.shield_clearance_ease = arg.trim_prefix("--ease=").to_float()
	var sk := body.get("_skeleton") as Skeleton3D
	var shield := body.get("_shield_node") as Node3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), maxi(all.size() / 600, 1)):
		verts.append(all[i])
	var parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["UpperChest", "Neck", 0.13], ["LeftUpperLeg", "LeftLowerLeg", 0.09], ["LeftLowerLeg", "LeftFoot", 0.06], ["RightUpperLeg", "RightLowerLeg", 0.09], ["RightLowerLeg", "RightFoot", 0.06]]
	var dt := 1.0 / 60.0
	body.weapon_raised = true
	for mirrored: bool in [false, true]:
		for look_time: float in [0.1, 0.25, 0.5]:
			# Stand, then crouch with the foot asked for forward, level.
			for f in 60:
				body.set_motion(Vector3.ZERO, true, false, false, dt)
				body.advance(dt, 0.0)
			body.set("_idle_mirrored", mirrored)
			body.set_motion(Vector3.ZERO, true, true, false, dt)
			body.set("_idle_mirrored", mirrored)
			for f in 120:
				body.set_motion(Vector3.ZERO, true, true, false, dt)
				body.advance(dt, 0.0)
			var clip := (body.get("_animations") as AnimationPlayer).current_animation
			var per_tenth: Array[float] = []
			per_tenth.resize(15)
			per_tenth.fill(9.0)
			var least := 9.0
			var where := ""
			var at_time := 0.0
			for f in 90:
				var t := f * dt
				var pitch := -1.5 * minf(t / look_time, 1.0)
				body.set_motion(Vector3.ZERO, true, true, false, dt)
				body.advance(dt, pitch)
				var world := sk.global_transform
				var lines: Array = []
				for part: Array in parts:
					lines.append([(world * sk.get_bone_global_pose(sk.find_bone(part[0]))).origin, (world * sk.get_bone_global_pose(sk.find_bone(part[1]))).origin, part[2], part[0]])
				var frame_least := 9.0
				for v in verts:
					var p := shield_mesh.global_transform * v
					for line: Array in lines:
						var room := seg(p, line[0], line[1]) - (line[2] as float)
						if room < frame_least:
							frame_least = room
						if room < least:
							least = room
							where = line[3]
							at_time = t
				var tenth := mini(int(t * 10.0), 14)
				per_tenth[tenth] = minf(per_tenth[tenth], frame_least)
			var text := ""
			for r in per_tenth:
				text += " %+.2f" % r
			var turn := (body.get("_shield_turn") as Vector2) * (180.0 / PI)
			print("QUICK %-18s look in %.2f s | least %+.3f at %-13s (%.2f s) | end: turn %.0f / %.0f deg, move %.2f | per 0.1 s:%s" % [clip, look_time, least, where, at_time, turn.x, turn.y, (body.get("_shield_push") as Vector3).length(), text])
			for f in 60:
				body.set_motion(Vector3.ZERO, true, true, false, dt)
				body.advance(dt, 0.0)
	quit()
