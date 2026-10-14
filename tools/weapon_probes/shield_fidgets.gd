extends SceneTree
# The shield fidgets (PlayerBody.FIDGETS with "shield_keys"), weapons up, either foot forward, at
# 60 frames a second: per tenth of each the least room of the shield's mesh to the body's capsules,
# to the sword's mesh and to the eyes; the angle between the shield's face and the way to the
# eyes (180 = facing away, 0 = facing them); where its middle is in the picture; the left
# forearm's room to the trunk. And the largest change of the shield middle's speed in a frame.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D
const LEFT_CHAINS := [["LeftThumbMetacarpal", "LeftThumbProximal", "LeftThumbDistal"], ["LeftIndexProximal", "LeftIndexIntermediate", "LeftIndexDistal"], ["LeftMiddleProximal", "LeftMiddleIntermediate", "LeftMiddleDistal"], ["LeftRingProximal", "LeftRingIntermediate", "LeftRingDistal"], ["LeftLittleProximal", "LeftLittleIntermediate", "LeftLittleDistal"]]

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
	var tri := shield_mesh.mesh.generate_triangle_mesh()
	var thin := 0
	for a in 3:
		if box.size[a] < box.size[thin]:
			thin = a
	var camera := player.get_node("Camera3D") as Camera3D
	var parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["UpperChest", "Neck", 0.13], ["Neck", "Head", 0.09], ["LeftUpperLeg", "LeftLowerLeg", 0.09], ["RightUpperLeg", "RightLowerLeg", 0.09]]
	# The shakes' swings (PlayerBody._irregular_wave), for three seeds: each swing's length (s)
	# and peak, per wave of shield_settle.
	if PlayerBody.FIDGETS.has(&"shield_settle"):
		var settle: Dictionary = PlayerBody.FIDGETS[&"shield_settle"]
		for wave_name: String in ["bounce", "roll"]:
			var wave: Vector4 = (settle["shake"] as Dictionary)[wave_name]
			for seed: float in [0.1, 0.5, 0.9]:
				var swings: Array[String] = []
				var last_sign := 0.0
				var start := wave.x
				var peak := 0.0
				for k in 2001:
					var at := wave.x + (wave.y - wave.x) * k / 2000.0
					var v := PlayerBody._irregular_wave(wave, at, 0.0, seed)
					var sign := signf(v)
					if sign != 0.0 and last_sign != 0.0 and sign != last_sign:
						swings.append("%.2fs %+.2f" % [(at - start) * float(settle["time"]), peak])
						start = at
						peak = 0.0
					if sign != 0.0:
						last_sign = sign
					if absf(v) > absf(peak):
						peak = v
				swings.append("%.2fs %+.2f" % [(wave.y - start) * float(settle["time"]), peak])
				print("WAVE %s seed %.1f: %d swings: %s" % [wave_name, seed, swings.size(), ", ".join(swings)])
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
			var heights_from := Vector2.INF # the elbow's and wrist's heights in the first frame
			var clips := {} # left finger -> frames it was in the board
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
				# The left hand's fingers (thick: their bones' lines and four lines 9 mm off them)
				# through the shield's triangles.
				var to_board := shield_mesh.global_transform.affine_inverse() * left.global_transform
				var radius := 0.009 * to_board.basis.get_scale().x
				for chain: Array in LEFT_CHAINS:
					var points: Array[Vector3] = [to_board * left.get_bone_global_pose(left.find_bone("LeftHand")).origin]
					for bone_name: String in chain:
						points.append(to_board * left.get_bone_global_pose(left.find_bone(bone_name)).origin)
					var last := left.get_bone_global_pose(left.find_bone(chain[-1]))
					var before := left.get_bone_global_pose(left.find_bone(chain[-2]))
					points.append(to_board * (last * Vector3(0, 0.75 * last.origin.distance_to(before.origin), 0)))
					for k in points.size() - 1:
						var along := (points[k + 1] - points[k]).normalized()
						var side := along.cross(Vector3.UP if absf(along.y) < 0.9 else Vector3.RIGHT).normalized()
						var other := along.cross(side)
						for offset: Vector3 in [Vector3.ZERO, side * radius, -side * radius, other * radius, -other * radius]:
							if not tri.intersect_segment(points[k] + offset, points[k + 1] + offset).is_empty():
								clips[chain[-1]] = clips.get(chain[-1], 0) + 1
								break
				if heights_from == Vector2.INF:
					heights_from = Vector2(l_elbow.y, l_wrist.y)
				m["elbow-up"] = l_elbow.y - heights_from.x
				m["wrist-up"] = l_wrist.y - heights_from.y
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
					bins[bin]["elbow-up"] = maxf(bins[bin]["elbow-up"], m["elbow-up"])
					bins[bin]["wrist-up"] = maxf(bins[bin]["wrist-up"], m["wrist-up"])
			print("SHIELD %s, %s foot fwd: %d frames (%.2f s), the middle's speed changed at most %.2f m/s in a frame (at %.2f); left fingers in the board (frames): %s" % [fidget, "right" if mirrored else "left", frames, frames / 60.0, worst_change, worst_at, clips if not clips.is_empty() else "none"])
			for n: String in ["shield-body", "shield-sword", "shield-eyes", "left-arm", "elbow-up", "wrist-up", "face-eyes"]:
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
