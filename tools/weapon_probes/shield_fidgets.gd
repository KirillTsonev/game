extends SceneTree
# The shield fidgets (PlayerBody.FIDGETS with "shield_keys"), weapons up, either foot forward, at
# 60 frames a second: per tenth of each the least room of the shield's mesh to the body's capsules,
# to the sword's mesh and to the eyes; the angle between the shield's face and the way to the
# eyes (180 = facing away, 0 = facing them); where its middle is in the picture; the left
# forearm's room to the trunk. And the largest change of the shield middle's speed in a frame.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

static func sample(mesh: MeshInstance3D, count: int) -> PackedVector3Array:
	var all: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var some: PackedVector3Array = []
	for i in range(0, all.size(), maxi(all.size() / count, 1)):
		some.append(all[i])
	return some

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	sk = body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var sword_mesh := (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_mesh := (body.get("_shield_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var sword_verts := sample(sword_mesh, 300)
	var shield_verts := sample(shield_mesh, 400)
	var box := shield_mesh.mesh.get_aabb()
	var thin := 0
	for a in 3:
		if box.size[a] < box.size[thin]:
			thin = a
	var camera := player.get_node("Camera3D") as Camera3D
	var parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["UpperChest", "Neck", 0.13], ["Neck", "Head", 0.09], ["LeftUpperLeg", "LeftLowerLeg", 0.09], ["RightUpperLeg", "RightLowerLeg", 0.09]]
	body.weapon_raised = true
	for i in 240:
		step()
	print("SHIELD the forearm's line %s, glance sign %+.0f" % [(body.get("_shield_forearm_axis") as Vector3).snappedf(0.01), body.get("_glance_sign")])
	for fidget: StringName in PlayerBody.FIDGETS:
		if not (PlayerBody.FIDGETS[fidget] as Dictionary).has("shield_keys"):
			continue
		for mirrored: bool in [false, true]:
			body.set("_idle_mirrored", mirrored)
			for i in 120:
				step()
			# The face's sign: the thin axis taken so that it points away from the hips in the stance.
			var to_p := player.global_transform.affine_inverse()
			var hips := to_p * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips"))).origin
			var face_sign := 1.0
			var face_now := (to_p.basis * shield_mesh.global_transform.basis)[thin].normalized()
			if face_now.dot(to_p * shield_mesh.global_transform.origin - hips) < 0.0:
				face_sign = -1.0
			body.start_fidget(fidget)
			var bins := {}
			var frames := 0
			var mid_was := Vector3.INF
			var speed_was := Vector3.INF
			var worst_change := 0.0
			var worst_at := 0.0
			while body.fidget_playing() == fidget and frames < 600:
				step()
				frames += 1
				var through := float(frames) / 60.0 / float((PlayerBody.FIDGETS[fidget] as Dictionary)["time"])
				to_p = player.global_transform.affine_inverse()
				var bones := to_p * sk.global_transform
				var eye: Vector3 = body.get("_eye")
				var m := {"shield-body": 9.0, "shield-sword": 9.0, "shield-eyes": 9.0, "face-eyes": 0.0, "left-arm": 9.0}
				var trunk: Array = []
				for part: Array in parts:
					trunk.append([bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin, part[2]])
				var shield_at := to_p * shield_mesh.global_transform
				var sword_at := to_p * sword_mesh.global_transform
				var sword_placed: Array[Vector3] = []
				for w in sword_verts:
					sword_placed.append(sword_at * w)
				for v in shield_verts:
					var at := shield_at * v
					m["shield-eyes"] = minf(m["shield-eyes"], at.distance_to(eye))
					for t: Array in trunk:
						m["shield-body"] = minf(m["shield-body"], seg(at, t[0], t[1]) - (t[2] as float))
				for w in sword_placed:
					for v in shield_verts:
						m["shield-sword"] = minf(m["shield-sword"], w.distance_to(shield_at * v))
				var middle := shield_at * box.get_center()
				var face := (shield_at.basis[thin]).normalized() * face_sign
				m["face-eyes"] = rad_to_deg(face.angle_to(eye - middle))
				var left: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
				var lb := to_p * left.global_transform
				var l_elbow := lb * left.get_bone_global_pose(left.find_bone("LeftLowerArm")).origin
				var l_wrist := lb * left.get_bone_global_pose(left.find_bone("LeftHand")).origin
				for k in 11:
					var p := l_elbow.lerp(l_wrist, k / 10.0)
					for t: Array in trunk:
						m["left-arm"] = minf(m["left-arm"], seg(p, t[0], t[1]) - (t[2] as float) - 0.04)
				if mid_was.is_finite():
					var speed := (middle - mid_was) * 60.0
					if speed_was.is_finite() and (speed - speed_was).length() > worst_change:
						worst_change = (speed - speed_was).length()
						worst_at = through
					speed_was = speed
				mid_was = middle
				var look := Basis(Vector3.UP, body.view_offset().y) * Basis(Vector3.RIGHT, body.view_offset().x)
				var to_mid := (look.inverse() * (middle - eye)).normalized()
				# The board's long axis as the picture shows it: degrees counterclockwise from the
				# picture's right (a clockwise turn makes it smaller).
				var long_axis := 0
				for a in 3:
					if box.size[a] > box.size[long_axis]:
						long_axis = a
				var long_in_view := look.inverse() * shield_at.basis[long_axis]
				var tilt := rad_to_deg(atan2(long_in_view.y, long_in_view.x))
				# Which way the face looks, left-right in the picture (+ = to the right, 0 = at the eyes' line).
				var face_in_view := look.inverse() * face
				var face_yaw := rad_to_deg(atan2(face_in_view.x, face_in_view.z))
				var bin := mini(int(through * 10.0), 9)
				if not bins.has(bin):
					bins[bin] = m
					bins[bin]["seen"] = Vector2(rad_to_deg(atan2(to_mid.x, -to_mid.z)), rad_to_deg(atan2(to_mid.y, -to_mid.z)))
					bins[bin]["tilt"] = tilt
					bins[bin]["yaw"] = face_yaw
				else:
					for n: String in ["shield-body", "shield-sword", "shield-eyes", "left-arm"]:
						bins[bin][n] = minf(bins[bin][n], m[n])
					bins[bin]["face-eyes"] = minf(bins[bin]["face-eyes"], m["face-eyes"])
			print("SHIELD %s, %s foot fwd: %d frames (%.2f s), the middle's speed changed at most %.2f m/s in a frame (at %.2f)" % [fidget, "right" if mirrored else "left", frames, frames / 60.0, worst_change, worst_at])
			for n: String in ["shield-body", "shield-sword", "shield-eyes", "left-arm", "face-eyes"]:
				var line := "SHIELD   %-13s" % n
				for bin in 10:
					line += ((" %+.2f" if n != "face-eyes" else " %5.0f") % (bins[bin][n] as float)) if bins.has(bin) else "   . "
				print(line)
			var tilt_line := "SHIELD   tilt in view  "
			for bin in 10:
				tilt_line += (" %5.0f" % (bins[bin]["tilt"] as float)) if bins.has(bin) else "   . "
			print(tilt_line)
			var yaw_line := "SHIELD   face yaw      "
			for bin in 10:
				yaw_line += (" %5.0f" % (bins[bin]["yaw"] as float)) if bins.has(bin) else "   . "
			print(yaw_line)
			var line := "SHIELD   seen (deg)    "
			for bin in 10:
				line += " %s" % ((bins[bin]["seen"] as Vector2).snappedf(1.0) if bins.has(bin) else "-")
			print(line)
			for i in 30:
				step()
	quit()
