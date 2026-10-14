extends SceneTree
# Weapons up, the lantern held forward: many places for the sword fist, elbow sides and forearm rolls, one per tiny frame. Kept: blade within 30 deg of straight ahead, and either the KNUCKLES or the POMMEL against the lantern's body. World space.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

func step(delta: float) -> void:
	body.set_motion(Vector3.ZERO, true, false, false, delta)
	body.advance(delta, 0.0)

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	sk = body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var lantern := body.get("_lantern") as Node3D
	var sword := body.get("_weapon_node") as Node3D
	var shield := body.get("_shield_node") as Node3D
	var sword_mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	for mesh: MeshInstance3D in lantern.find_children("*", "MeshInstance3D", true, false):
		print("SEARCH lantern mesh in the lantern's axes: ", lantern.global_transform.affine_inverse() * mesh.global_transform * mesh.mesh.get_aabb())
	var all: PackedVector3Array = sword_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var sbox := sword_mesh.mesh.get_aabb()
	print("SEARCH sword mesh box ", sbox)
	var pommel := Vector3.ZERO
	var count := 0
	for v in all:
		if v.y < sbox.position.y + 0.01:
			pommel += v
			count += 1
	pommel /= maxf(count, 1.0)
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), 97):
		verts.append(all[i])
	var shield_box := shield_mesh.mesh.get_aabb()
	var shield_all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var shield_verts: PackedVector3Array = []
	for i in range(0, shield_all.size(), maxi(shield_all.size() / 500, 1)):
		shield_verts.append(shield_all[i])
	var parts: Array = [["Hips", "Spine", 0.17], ["Spine", "UpperChest", 0.17], ["UpperChest", "Neck", 0.15], ["LeftUpperLeg", "LeftLowerLeg", 0.1], ["LeftLowerLeg", "LeftFoot", 0.07], ["RightUpperLeg", "RightLowerLeg", 0.1], ["RightLowerLeg", "RightFoot", 0.07]]
	# -- --under: the fist UNDER the swung lantern, lifting it (Kirill, 2026-10-14: the sword
	# landed on top of the lantern). Only the knuckles count, and only on the lantern's underside.
	var under := OS.get_cmdline_user_args().has("--under")
	var candidates: Array = []
	if under:
		# The forearm's roll alone only spins the blade about the forearm: below the lantern no
		# roll points it ahead without running it up through the lantern (lantern_under_trace.gd).
		# The wrist bends it toward toggle_armed_blade; the roll then picks which side of the
		# fist faces up.
		for x: float in [0.02, 0.04, 0.06, 0.08]:
			for y: float in [-0.10, -0.12, -0.14, -0.16]:
				for z: float in [-0.08, -0.04, 0.0, 0.04]:
					for pole: Vector3 in [Vector3(1.0, -0.6, 0.2), Vector3(1.0, -0.2, 0.3)]:
						for roll: float in [-40.0, -20.0, 0.0, 20.0]:
							for aim: Vector3 in [Vector3(0.0, -0.3, -0.95), Vector3(0.0, -0.4, -0.92), Vector3(0.1, -0.35, -0.93)]:
								candidates.append([Vector3(x, y, z), pole, roll, aim.normalized()])
	else:
		for x: float in [0.04, 0.07, 0.10, 0.13, 0.16]:
			for y: float in [0.02, 0.05, 0.08, 0.11, 0.14]:
				for z: float in [0.04, 0.08, 0.12, 0.16, 0.2]:
					for pole: Vector3 in [Vector3(1.0, -0.3, 0.0), Vector3(0.9, 0.0, -0.4), Vector3(0.7, -0.5, -0.4), Vector3(0.6, 0.5, 0.3)]:
						for roll: float in [0.0, 15.0, 30.0, 45.0, 60.0]:
							candidates.append([Vector3(x, y, z), pole, roll])
	var results := {"knuckles": {}, "pommel": {}}
	for mirrored: bool in [false, true]:
		body.weapon_raised = true
		body.set("_idle_mirrored", mirrored)
		for i in 90:
			step(1.0 / 60.0)
		body.toggle_lantern()
		while (body.get("_toggle_at") as float) / body.toggle_time < 0.42:
			step(1.0 / 60.0)
		var tiny := body.toggle_time * 0.2 / candidates.size()
		for index in candidates.size():
			var c: Array = candidates[index]
			body.toggle_armed_fist = c[0]
			body.toggle_armed_elbow = c[1]
			body.toggle_armed_roll = c[2]
			body.toggle_armed_blade = c[3] if c.size() > 3 else Vector3.ZERO
			step(tiny)
			var blade := (player.global_transform.basis.inverse() * sword_mesh.global_transform.basis.y).normalized()
			if under:
				# Within about 50 degrees of ahead, and not up into the lantern.
				if blade.z > -0.6 or blade.y > 0.05:
					continue
			elif blade.z > -0.82:
				continue
			var world := sk.global_transform
			var top := lantern.global_transform * Vector3.ZERO
			var low := lantern.global_transform * Vector3(0.0, -0.33, 0.0)
			var b_top := lantern.global_transform * Vector3(0.0, -0.14, 0.0)
			var b_low := lantern.global_transform * Vector3(0.0, -0.28, 0.0)
			var left: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
			var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
			var l_elbow := (left.global_transform * left.get_bone_global_pose(left.find_bone("LeftLowerArm"))).origin
			var l_wrist := (left.global_transform * left.get_bone_global_pose(left.find_bone("LeftHand"))).origin
			var r_shoulder := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightUpperArm"))).origin
			var r_elbow := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightLowerArm"))).origin
			var r_hand := right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))
			var knuckles := Vector3.ZERO
			for finger: String in ["Index", "Middle", "Ring"]:
				knuckles += (right.global_transform * right.get_bone_global_pose(right.find_bone("Right" + finger + "Intermediate"))).origin / 3.0
			var pommel_at := sword_mesh.global_transform * pommel
			var eye := player.global_transform * body.eye_position()
			var trunk: Array = []
			for part: Array in parts:
				trunk.append([(world * sk.get_bone_global_pose(sk.find_bone(part[0]))).origin, (world * sk.get_bone_global_pose(sk.find_bone(part[1]))).origin, part[2]])
			var touch_k := seg(knuckles, b_top, b_low) - 0.055 - 0.015
			var touch_p := seg(pommel_at, b_top, b_low) - 0.055
			var by_knuckles := touch_k > -0.015 and touch_k < 0.01
			var by_pommel := touch_p > -0.015 and touch_p < 0.01
			if under:
				# Any part of the hand may carry it (wrist, back of the hand, either row of
				# knuckles), as long as that part is UNDER the lantern's middle line.
				by_pommel = false
				by_knuckles = false
				var hand_points: Array[Vector3] = [r_hand.origin, knuckles]
				for finger: String in ["Index", "Middle", "Ring", "Little"]:
					var base := (right.global_transform * right.get_bone_global_pose(right.find_bone("Right" + finger + "Proximal"))).origin
					hand_points.append(base)
					hand_points.append(r_hand.origin.lerp(base, 0.5))
				var along := b_low - b_top
				var down := player.global_transform.basis * Vector3.DOWN
				touch_k = 9.0
				for p in hand_points:
					var off := p - (b_top + along * clampf((p - b_top).dot(along) / along.length_squared(), 0.0, 1.0))
					var gap := off.length() - 0.055 - 0.02
					if gap < touch_k:
						touch_k = gap
						by_knuckles = off.dot(down) > 0.7 * off.length()
				# Up to 4 cm short is kept: clear of the lantern comes first, the gap is scored.
				by_knuckles = by_knuckles and touch_k > -0.015 and touch_k < 0.04
			if not by_knuckles and not by_pommel:
				continue
			var s_body := 9.0
			var s_lantern := 9.0 # the whole sword
			var s_lantern_above := 9.0 # the sword without its pommel end
			var s_left := 9.0
			var s_eyes := 9.0
			var s_mesh := 9.0
			var to_shield := shield_mesh.global_transform.affine_inverse()
			for v in verts:
				var at := sword_mesh.global_transform * v
				for t: Array in trunk:
					s_body = minf(s_body, seg(at, t[0], t[1]) - (t[2] as float))
				var room := minf(seg(at, b_top, b_low) - 0.055, seg(at, top, b_top) - 0.03)
				s_lantern = minf(s_lantern, room)
				if v.y > sbox.position.y + 0.05:
					s_lantern_above = minf(s_lantern_above, room)
				s_left = minf(s_left, seg(at, l_elbow, l_wrist + (l_wrist - l_elbow).normalized() * 0.1) - 0.05)
				s_eyes = minf(s_eyes, at.distance_to(eye))
				var s := to_shield * at
				if s.x > shield_box.position.x - 0.05 and s.x < shield_box.end.x + 0.05 and s.y > shield_box.position.y - 0.05 and s.y < shield_box.end.y + 0.05 and s.z > shield_box.position.z - 0.05 and s.z < shield_box.end.z + 0.05:
					for w in shield_verts:
						s_mesh = minf(s_mesh, s.distance_to(w))
			var arm_trunk := 9.0
			var arm_lantern := 9.0
			for k in 11:
				var on_forearm := r_elbow.lerp(r_hand.origin, k / 10.0)
				var on_upper := r_shoulder.lerp(r_elbow, 0.5 + k / 20.0)
				arm_lantern = minf(arm_lantern, minf(seg(on_forearm, b_top, b_low) - 0.055, seg(on_forearm, top, b_top) - 0.03) - 0.035)
				for t: Array in trunk:
					arm_trunk = minf(arm_trunk, minf(seg(on_forearm, t[0], t[1]), seg(on_upper, t[0], t[1])) - (t[2] as float) - 0.04)
			var common := minf(minf(s_body, s_mesh - 0.03), minf(minf(s_left, arm_trunk + 0.03), minf(arm_lantern + 0.01, s_eyes - 0.3)))
			if under:
				# Sword and forearm clear of the lantern first (Kirill, 2026-10-14: both clipped
				# it); the arm by the trunk is let read as deep as a hanging arm does (-0.06),
				# and a gap to the lantern costs as much as clipping it.
				common = minf(minf(s_body + 0.02, s_mesh - 0.03), minf(minf(s_left, arm_trunk + 0.07), minf(arm_lantern, s_eyes - 0.3))) - maxf(touch_k, 0.0)
			var text := " | %s: body %+.2f lantern %+.2f (without pommel %+.2f) shield %.2f left arm %+.2f arm-trunk %+.2f arm-lantern %+.2f knuckles %+.3f pommel %+.3f eyes %.2f blade %s fist at %s" % ["R" if mirrored else "L", s_body, s_lantern, s_lantern_above, s_mesh, s_left, arm_trunk, arm_lantern, touch_k, touch_p, s_eyes, blade.snappedf(0.01), ((player.global_transform.affine_inverse() * r_hand.origin) - (body.get("_bob") as Vector3)).snappedf(0.01)]
			for kind: String in ["knuckles", "pommel"]:
				if (kind == "knuckles" and not by_knuckles) or (kind == "pommel" and not by_pommel):
					continue
				var score := minf(common, s_lantern + 0.005 if kind == "knuckles" else s_lantern_above + 0.005)
				if under:
					score = minf(common, s_lantern - maxf(touch_k, 0.0))
				var kept: Dictionary = results[kind]
				if not kept.has(index):
					kept[index] = [score, text, 1]
				else:
					kept[index] = [minf(kept[index][0], score), (kept[index][1] as String) + text, 2]
		while body.turning_lantern():
			step(1.0 / 60.0)
		for i in 30:
			step(1.0 / 60.0)
	for kind: String in ["knuckles", "pommel"]:
		var kept: Dictionary = results[kind]
		var order := kept.keys().filter(func(i: int) -> bool: return kept[i][2] == 2)
		order.sort_custom(func(a: int, b: int) -> bool: return (kept[a][0] as float) > (kept[b][0] as float))
		print("SEARCH %s: %d poses touch with either foot forward (of %d tried)" % [kind, order.size(), candidates.size()])
		for index: int in order.slice(0, 8):
			var c: Array = candidates[index]
			print("SEARCH %s worst %+.3f fist %s elbow %s roll %.0f blade asked %s%s" % [kind, kept[index][0], c[0], c[1], c[2], c[3].snappedf(0.01) if c.size() > 3 else "-", kept[index][1]])
	quit()
