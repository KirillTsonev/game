extends SceneTree
# The draw from the back and the sheathing: the sword's MESH through it (does it jump when it changes hands), where the fist is in the view, the arm's angles.
func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	var body_sk := body.get("_skeleton") as Skeleton3D
	var copy_sk: Skeleton3D = (body.get("_apart") as Dictionary)["Right"]["skeleton"]
	var copy_model: Node3D = (body.get("_apart") as Dictionary)["Right"]["model"]
	var sk := body_sk
	var stance := body.get_node("WeaponStance") as WeaponStance
	var sword := body.get("_weapon_node") as Node3D
	var mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var box := mesh.mesh.get_aabb()
	var axis := box.get_longest_axis_index()
	var grip_end := box.get_center()
	var tip_end := box.get_center()
	# Which end is the grip: the one nearer the model's origin (the grip's middle is the origin).
	grip_end[axis] = box.position[axis] if absf(box.position[axis]) < absf(box.end[axis]) else box.end[axis]
	tip_end[axis] = box.end[axis] if absf(box.position[axis]) < absf(box.end[axis]) else box.position[axis]
	var axes := WeaponHold.hand_axes(sk, "Right")
	var half_v := deg_to_rad(37.5)
	var half_h := atan(tan(half_v) * 16.0 / 9.0)
	for turned_over: bool in [false, true]:
		body.weapon_back_turned_over = turned_over
		body.weapon_raised = false
		for i in 90:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
		sk = body_sk
		var to_p := player.global_transform.affine_inverse()
		var eye := body.eye_position()
		print("DRAW turned over %s | SHEATHED: on back %s, in combat %s | from the eyes (+X right, +Y up, -Z ahead): pommel end %s, tip %s | right hand %s | arms' copies shown %s" % [turned_over, body.get("_weapon_on_back"), body.in_combat(),
			(to_p * (mesh.global_transform * grip_end) - eye).snapped(Vector3.ONE * 0.01), (to_p * (mesh.global_transform * tip_end) - eye).snapped(Vector3.ONE * 0.01),
			(to_p * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand"))).origin - eye).snapped(Vector3.ONE * 0.01), ((body.get("_apart") as Dictionary)["Right"]["model"] as Node3D).visible])
		for direction: Array in [["DRAW", true], ["SHEATHE", false]]:
			body.weapon_raised = direction[1]
			var last_origin := mesh.global_transform * Vector3.ZERO
			var last_tip := mesh.global_transform * tip_end
			var last_back: bool = body.get("_weapon_on_back")
			var biggest := 0.0
			var change_jump := -1.0
			var change_turn := 0.0
			var last_basis := mesh.global_transform.basis.orthonormalized()
			var wrist_most := 0.0
			var elbow_least := 999.0
			var line := ""
			var frames := 0
			for i in 90:
				body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
				body.advance(1.0 / 60.0, 0.0)
				var up: float = body.get("_weapon_up")
				sk = copy_sk if copy_model.visible else body_sk
				var origin := mesh.global_transform * Vector3.ZERO
				var tip := mesh.global_transform * tip_end
				var step := maxf(origin.distance_to(last_origin), tip.distance_to(last_tip))
				var back: bool = body.get("_weapon_on_back")
				if back != last_back:
					change_jump = step
					change_turn = rad_to_deg(mesh.global_transform.basis.orthonormalized().get_rotation_quaternion().angle_to(last_basis.get_rotation_quaternion()))
				else:
					biggest = maxf(biggest, step)
				last_origin = origin
				last_tip = tip
				last_back = back
				last_basis = mesh.global_transform.basis.orthonormalized()
				to_p = player.global_transform.affine_inverse()
				eye = body.eye_position()
				var u := sk.get_bone_global_pose(sk.find_bone("RightUpperArm")).origin
				var l := sk.get_bone_global_pose(sk.find_bone("RightLowerArm")).origin
				var h := sk.get_bone_global_pose(sk.find_bone("RightHand"))
				if up > 0.0 and up < 1.0:
					frames += 1
					wrist_most = maxf(wrist_most, rad_to_deg((h.origin - l).normalized().angle_to((h.basis * (axes["fingers_out"] as Vector3)).normalized())))
					elbow_least = minf(elbow_least, 180.0 - rad_to_deg((u - l).angle_to(h.origin - l)))
				if i % 6 == 5 and i < 54:
					var fist := to_p * (sk.global_transform * h * stance.fist_in_hand(sk, 0.022)) - eye
					var where := "behind"
					if fist.z < -0.02:
						var across := rad_to_deg(atan2(fist.x, -fist.z))
						var high := rad_to_deg(atan2(fist.y, -fist.z))
						where = "%+.0f/%+.0f %s" % [across, high, "IN VIEW" if absf(across) < rad_to_deg(half_h) and absf(high) < rad_to_deg(half_v) else "out"]
					line += " | %.2f s (%.2f%s): fist %s [%s]" % [(i + 1) / 60.0, up, " back" if back else "", fist.snapped(Vector3.ONE * 0.01), where]
			print("DRAW   %s took %d frames; the sword's mesh moved at most %.3f m in a frame, and %.4f m / %.2f deg in the frame it changed between back and fist; wrist at most %.0f deg, elbow straightest %.0f deg" % [direction[0], frames, biggest, change_jump, change_turn, wrist_most, elbow_least])
			print("DRAW   ", line)
		var fist_end := player.global_transform.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand")) * stance.fist_in_hand(sk, 0.022)) - body.eye_position()
	body.weapon_raised = true
	for i in 90:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	sk = copy_sk
	print("DRAW drawn again: fist %.4f m from its stance place, on back %s" % [(player.global_transform.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand")) * stance.fist_in_hand(sk, 0.022)) - body.eye_position()).distance_to(stance.hand_from_eyes()), body.get("_weapon_on_back")])
	quit()
