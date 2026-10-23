extends SceneTree
# The shield arm of the Blender swings against animation_sources/fp_arms/shield_source.json (the
# arm as the game moved it before the clip had one, which the clip was keyed from): plays each swing
# whose clip carries the shield arm ("shield_from_rig") as export_shield_source.gd recorded it, and
# prints the largest differences per bone and of the shield (m, deg) and the frame they fall on.
# After editing the shield arm in Blender the differences are the edit; with nothing edited they
# measure the round trip.
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/shield_rig_check.gd

func _init() -> void:
	_run.call_deferred()

static func _transform(a: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])), Vector3(a[9], a[10], a[11]))

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	body.weapon_breathing = 0.0
	body.shield_breathing = 0.0
	body.weapon_raised = true
	var step := func() -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	for i in 150:
		step.call()
	var recorded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://animation_sources/fp_arms/shield_source.json"))
	var to_player := player.global_transform.affine_inverse()
	var eye: Vector3 = body.get("_eye")
	var apart: Dictionary = body.get("_apart")
	var arm_skeleton: Skeleton3D = apart["Left"]["skeleton"]
	var shield_node := body.get("_shield_node") as Node3D
	for swing_name: StringName in PlayerBody.SWINGS:
		var swing: Dictionary = PlayerBody.SWINGS[swing_name]
		if not bool(swing.get("shield_from_rig", false)) or not (recorded["swings"] as Dictionary).has(String(swing["rig"])):
			continue
		var frames: Array = recorded["swings"][String(swing["rig"])]
		body.call("_start_swing", swing_name, false)
		body.set("_swing_turn", 0.0)
		var worst := {}
		for f in frames.size():
			if f > 0:
				step.call()
				step.call()
			var to_eyes := Transform3D(Basis.IDENTITY, -(body.get("_eye") as Vector3)) * to_player # the eyes where they are now, as recorded
			var now := {"shield": to_eyes * shield_node.global_transform}
			for bone_name in ["LeftUpperArm", "LeftLowerArm", "LeftHand"]:
				now[bone_name] = to_eyes * arm_skeleton.global_transform * arm_skeleton.get_bone_global_pose(arm_skeleton.find_bone(bone_name))
			if OS.get_cmdline_user_args().has("--screen"):
				# Where the shield's middle is in the picture, as the Player turns its camera (its
				# pitch, level here, plus the body's view offset: the swing's nod) -- degrees right / up.
				var mesh := shield_node.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
				var middle := to_player * (mesh.global_transform * mesh.get_aabb().get_center())
				var camera := Transform3D(Basis.from_euler(body.view_offset()), body.eye_position())
				var seen := camera.affine_inverse() * middle
				print("SHIELD_RIG screen %d: the shield's middle %.2f deg right, %.2f deg up (the view nods %.2f deg); from the eyes %s m; the mesh's own middle %s" % [f, rad_to_deg(atan2(seen.x, -seen.z)), rad_to_deg(atan2(seen.y, -seen.z)), rad_to_deg(body.view_offset().x), (middle - body.eye_position()).snappedf(0.001), mesh.get_aabb().get_center().snappedf(0.001)])
			if OS.get_cmdline_user_args().has("--frames"):
				var was_hand := _transform(frames[f]["LeftHand"]).origin
				var rig_now: Dictionary = body.get("_rig_left")
				var rig_hold: Dictionary = body.get("_rig_left_hold")
				var rig_moved: Vector3 = ((rig_now["wrist"] as Vector3) - (rig_hold["wrist"] as Vector3)) if not rig_now.is_empty() else Vector3.INF
				var shoulder_moved: Vector3 = ((rig_now["shoulder"] as Vector3) - (rig_hold["shoulder"] as Vector3)) if not rig_now.is_empty() else Vector3.INF
				print("SHIELD_RIG frame %d: the wrist off by %s, the shoulder off by %s; the rig's wrist moved %s, its shoulder %s" % [f, ((now["LeftHand"] as Transform3D).origin - was_hand).snappedf(0.001),
						((now["LeftUpperArm"] as Transform3D).origin - _transform(frames[f]["LeftUpperArm"]).origin).snappedf(0.001), rig_moved.snappedf(0.001), shoulder_moved.snappedf(0.001)])
			for part: String in now:
				var was := _transform(frames[f][part])
				var is_now: Transform3D = now[part]
				var moved := was.origin.distance_to(is_now.origin)
				var turned := rad_to_deg((is_now.basis.orthonormalized() * was.basis.orthonormalized().inverse()).get_rotation_quaternion().get_angle())
				if not worst.has(part) or moved > worst[part][0]:
					worst[part] = [moved, f, worst[part][2] if worst.has(part) else 0.0, worst[part][3] if worst.has(part) else 0]
				if turned > worst[part][2]:
					worst[part][2] = turned
					worst[part][3] = f
		for part: String in worst:
			print("SHIELD_RIG %s %-13s at most %.4f m off (frame %d), %.2f deg (frame %d)" % [swing["rig"], part, worst[part][0], worst[part][1], worst[part][2], worst[part][3]])
		for i in 90:
			step.call()
	quit()
