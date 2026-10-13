extends SceneTree
# Turning the lantern on / off with the shield on the arm, weapons down and up: does each hand get there, does the left hand stay in the handle, what clips.
func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	var sk := body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var lantern := body.get("_lantern") as Node3D
	var light := body.get("_lantern_light") as Light3D
	var shield := body.get("_shield_node") as Node3D
	var sword := body.get("_weapon_node") as Node3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var sword_mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), 9):
		verts.append(all[i])
	var parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["LeftUpperLeg", "LeftLowerLeg", 0.09], ["LeftLowerLeg", "LeftFoot", 0.06], ["RightUpperLeg", "RightLowerLeg", 0.09], ["RightLowerLeg", "RightFoot", 0.06]]
	var sword_box := sword_mesh.mesh.get_aabb()
	var axis := sword_box.get_longest_axis_index()
	var s0 := sword_box.get_center()
	var s1 := sword_box.get_center()
	s0[axis] = sword_box.position[axis]
	s1[axis] = sword_box.end[axis]
	for state: Array in [["down, left foot fwd", false, &"idle"], ["down, right foot fwd", false, &"idle_mirror"], ["up, left foot fwd", true, &"idle"], ["up, right foot fwd", true, &"idle_mirror"]]:
		body.weapon_raised = state[1]
		body.set("_idle_mirrored", state[2] == &"idle_mirror")
		for i in 100:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
		# The hand against the shield before: what "in the handle" is.
		var left_sk: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
		var hand_before: Transform3D = shield.global_transform.affine_inverse() * (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("LeftHand")))
		var ring_before := left_sk.get_bone_pose_rotation(left_sk.find_bone("LeftRingProximal"))
		var index_before := left_sk.get_bone_pose_rotation(left_sk.find_bone("LeftIndexProximal"))
		var lit_before := light.visible
		print("LANTERN %-21s clip playing: %s" % [state[0], (body.get("_animations") as AnimationPlayer).current_animation])
		body.toggle_lantern()
		var started: bool = body.turning_lantern()
		var pinch_best := 9.0
		var pinch_at_turn := 0.0
		var palm_best := 9.0
		var hand_moved := 0.0
		var hand_turned := 0.0
		var ring_moved := 0.0
		var index_most := 0.0
		var shield_deepest := 9.0
		var shield_where := ""
		var sword_nearest := 9.0
		var shoulder_off := [0.0, 0.0]
		var frames := 0
		var trace := ""
		var joints_nearest := 9.0
		var joints_which := ""
		var tips_off_rod := 0.0
		var wrist_step := 0.0
		var last_wrist := Vector3.INF
		while body.turning_lantern() and frames < 200:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
			frames += 1
			var through: float = (body.get("_toggle_at") as float) / body.toggle_time
			left_sk = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
			var right_sk: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
			# The left hand's three fingertips' meeting place against the knob.
			var knob := lantern.global_transform * body.toggle_knob
			var tips: Array[Vector3] = []
			for finger: String in ["Thumb", "Index", "Middle"]:
				var last := (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("Left" + finger + "Distal"))).origin
				var before_last := (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("Left" + finger + ("Proximal" if finger == "Thumb" else "Intermediate")))).origin
				tips.append(last + (last - before_last).normalized() * 0.02)
			var pinch := (tips[0] + (tips[1] + tips[2]) * 0.5) * 0.5
			if through > 0.38 and through < 0.64:
				var top := lantern.global_transform * Vector3.ZERO
				var bottom := lantern.global_transform * Vector3(0.0, -0.32, 0.0)
				for joint: String in ["LeftHand", "LeftIndexProximal", "LeftMiddleProximal", "LeftRingProximal", "LeftLittleProximal", "LeftIndexIntermediate", "LeftMiddleIntermediate", "LeftThumbProximal"]:
					var at := (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone(joint))).origin
					var line := bottom - top
					var off := at.distance_to(top + line * clampf((at - top).dot(line) / line.length_squared(), 0.0, 1.0))
					if off < joints_nearest:
						joints_nearest = off
						joints_which = joint
				var rod := (lantern.global_transform.basis * Vector3(body.toggle_knob.x, 0.0, body.toggle_knob.z)).normalized()
				var middle := (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("LeftHand"))).origin.lerp((left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("LeftMiddleProximal"))).origin, 0.5)
				tips_off_rod = maxf(tips_off_rod, rad_to_deg((pinch - middle).normalized().angle_to(-rod)))
				pinch_best = minf(pinch_best, pinch.distance_to(knob))
				pinch_at_turn = maxf(pinch_at_turn, pinch.distance_to(knob))
				index_most = maxf(index_most, rad_to_deg(left_sk.get_bone_pose_rotation(left_sk.find_bone("LeftIndexProximal")).angle_to(index_before)))
			# The right hand against the lantern's body.
			var palm := (right_sk.global_transform * right_sk.get_bone_global_pose(right_sk.find_bone("RightHand"))).origin
			var lantern_body := lantern.global_transform * Vector3(0.0, -0.2, 0.0)
			if through > 0.2 and through < 0.75:
				palm_best = minf(palm_best, palm.distance_to(lantern_body))
			var hand_now: Transform3D = shield.global_transform.affine_inverse() * (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("LeftHand")))
			hand_moved = maxf(hand_moved, hand_now.origin.distance_to(hand_before.origin))
			hand_turned = maxf(hand_turned, rad_to_deg(hand_now.basis.orthonormalized().get_rotation_quaternion().angle_to(hand_before.basis.orthonormalized().get_rotation_quaternion())))
			ring_moved = maxf(ring_moved, rad_to_deg(left_sk.get_bone_pose_rotation(left_sk.find_bone("LeftRingProximal")).angle_to(ring_before)))
			var wrist := (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("LeftHand"))).origin
			if last_wrist.is_finite():
				wrist_step = maxf(wrist_step, wrist.distance_to(last_wrist))
			last_wrist = wrist
			if frames % 2 == 0:
				var frame_deepest := 9.0
				var frame_where := ""
				var to_sk := sk.global_transform.affine_inverse() * shield_mesh.global_transform
				for part: Array in parts:
					var a := sk.get_bone_global_pose(sk.find_bone(part[0])).origin
					var b := sk.get_bone_global_pose(sk.find_bone(part[1])).origin
					var along := b - a
					for v in verts:
						var at := to_sk * v
						var nearest := a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0)
						var room := at.distance_to(nearest) - (part[2] as float)
						if room < frame_deepest:
							frame_deepest = room
							frame_where = part[0]
						if room < shield_deepest:
							shield_deepest = room
							shield_where = part[0]
				if frames % 6 == 0:
					trace += " %.2f:%+.2f(%s,roll %.0f)" % [through, frame_deepest, frame_where.replace("Left", "L").replace("Right", "R").substr(0, 6), rad_to_deg(wrapf(body.get("_toggle_shield_roll"), -PI, PI))]
			var eye := player.global_transform * body.eye_position()
			var p0 := sword_mesh.global_transform * s0 - eye
			var p1 := sword_mesh.global_transform * s1 - eye
			var seg := p1 - p0
			sword_nearest = minf(sword_nearest, (p0 + seg * clampf(-p0.dot(seg) / seg.length_squared(), 0.0, 1.0)).length())
		print("LANTERN %-21s started %s, took %d frames; light %s -> %s" % [state[0], started, frames, lit_before, light.visible])
		print("LANTERN %-21s left: the three fingertips' meeting place is %.3f..%.3f m from the knob through the turn; forefinger moved %.0f deg from its hold; ring finger moved %.1f deg | the hand in the shield's axes moved %.1f mm and turned %.1f deg at most | wrist's largest move in a frame %.3f m" % [state[0], pinch_best, pinch_at_turn, index_most, ring_moved, hand_moved * 1000.0, hand_turned, wrist_step])
		print("LANTERN %-21s right: the wrist comes within %.3f m of the lantern's body | shield against the body: %s%s | the sword comes within %.2f m of the eyes" % [state[0], palm_best, ("INSIDE by %.2f m" % -shield_deepest) if shield_deepest < 0.0 else ("clear by %.2f m" % shield_deepest), (" at " + shield_where) if shield_deepest < 0.0 else "", sword_nearest])
		print("LANTERN %-21s left hand at the knob: its joints come within %.3f m of the lantern's middle line (%s; the knob's end is 0.045 m out from that line); the line from the hand's middle to the fingertips is up to %.0f deg off pointing at the lantern" % [state[0], joints_nearest, joints_which, tips_off_rod])
		print("LANTERN %-21s room between shield and body through the action (share of the time: m, where, the forearm's roll):%s" % [state[0], trace])
		# Back as it was.
		for i in 40:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
		left_sk = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
		var hand_after: Transform3D = shield.global_transform.affine_inverse() * (left_sk.global_transform * left_sk.get_bone_global_pose(left_sk.find_bone("LeftHand")))
		print("LANTERN %-21s afterwards: the hand is %.1f mm from where it was in the shield; forefinger %.1f deg from its hold" % [state[0], hand_after.origin.distance_to(hand_before.origin) * 1000.0, rad_to_deg(left_sk.get_bone_pose_rotation(left_sk.find_bone("LeftIndexProximal")).angle_to(index_before))])
	# Refused while the weapon is on its way.
	body.weapon_raised = false
	for i in 10:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	body.toggle_lantern()
	print("LANTERN during a sheathing: started %s" % body.turning_lantern())
	quit()
