extends SceneTree
# The shield against the body while jogging back, back-left and back-right, weapons up and down, looking straight down and level: the least room between the shield's vertices and the trunk's and legs' capsules, where, and when in the stride. `-- --pitch=<rad>` adds a pitch to try.
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
	var sk := body.get("_skeleton") as Skeleton3D
	var shield := body.get("_shield_node") as Node3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), maxi(all.size() / 600, 1)):
		verts.append(all[i])
	# The same radii as lantern_feet.gd.
	var parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["UpperChest", "Neck", 0.13], ["LeftUpperLeg", "LeftLowerLeg", 0.09], ["LeftLowerLeg", "LeftFoot", 0.06], ["RightUpperLeg", "RightLowerLeg", 0.09], ["RightLowerLeg", "RightFoot", 0.06]]
	var pitches: Array[float] = [-1.4, 0.0]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pitch="):
			pitches.append(arg.trim_prefix("--pitch=").to_float())
		elif arg == "--no-turn": # the keep-off as it was before 2026-10-19: moved only
			body.shield_clear_swing_max = 0.0
			body.shield_clear_roll_max = 0.0
	var speed := 3.0
	var ways := {"back": Vector3(0, 0, 1), "back-left": Vector3(-1, 0, 1).normalized(), "back-right": Vector3(1, 0, 1).normalized(), "left": Vector3(-1, 0, 0), "right": Vector3(1, 0, 0), "forward (for comparison)": Vector3(0, 0, -1)}
	for raised: bool in [true, false]:
		for pitch in pitches:
			for way: String in ways:
				body.weapon_raised = raised
				var deepest := 9.0
				var where := ""
				var at_time := 0.0
				var clip := ""
				var push_most := 0.0
				var turn_most := Vector2.ZERO
				var per_tenth: Array[float] = []
				per_tenth.resize(10)
				per_tenth.fill(9.0)
				var frames := 240
				for f in 60 + frames:
					body.set_motion((ways[way] as Vector3) * speed, true, false, false, 1.0 / 60.0)
					body.advance(1.0 / 60.0, pitch)
					if f < 60:
						continue
					clip = (body.get("_animations") as AnimationPlayer).current_animation
					push_most = maxf(push_most, ((body.get("_shield_push") if raised else body.get("_relaxed_push")) as Vector3).length())
					var turn := body.get("_shield_turn") as Vector2
					turn_most = Vector2(maxf(turn_most.x, absf(rad_to_deg(turn.x))), maxf(turn_most.y, absf(rad_to_deg(turn.y))))
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
							if room < deepest:
								deepest = room
								where = line[3]
								at_time = float(f - 60) / 60.0
					var tenth := mini(int(float(f - 60) / frames * 10.0), 9)
					per_tenth[tenth] = minf(per_tenth[tenth], frame_least)
				var line_text := ""
				for r in per_tenth:
					line_text += " %+.2f" % r
				print("SHIELD weapons %-4s pitch %+.2f %-24s clip %-14s least %+.3f at %-13s (%.2f s) | push up to %.2f, turn up to %.0f / %.0f deg | per 0.4 s:%s" % ["up" if raised else "down", pitch, way, clip, deepest, where, at_time, push_most, turn_most.x, turn_most.y, line_text])
	quit()
