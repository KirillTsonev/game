extends SceneTree
# The sword fidgets (PlayerBody.FIDGETS), weapons up, either foot forward, at 60 frames a second: per tenth of each the least room of the sword to the eyes, the body's capsules and the shield, the right arm to the trunk, where the fist is from the eyes and which ways the blade and its edge point (the Player's axes); the fastest move of the blade's tip. Then: does one start by itself after the wait, and does a key end it smoothly.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

var pitch := 0.0 # -- --pitch=<rad>: the view's pitch throughout

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, pitch)

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false # started by hand below
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pitch="):
			pitch = arg.trim_prefix("--pitch=").to_float()
	sk = body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var sword := body.get("_weapon_node") as Node3D
	var shield := body.get("_shield_node") as Node3D
	var sword_mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = sword_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), 61):
		verts.append(all[i])
	var shield_all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var shield_verts: PackedVector3Array = []
	for i in range(0, shield_all.size(), maxi(shield_all.size() / 400, 1)):
		shield_verts.append(shield_all[i])
	var parts: Array = [["Hips", "Spine", 0.17], ["Spine", "UpperChest", 0.17], ["UpperChest", "Neck", 0.15], ["Neck", "Head", 0.1], ["LeftUpperLeg", "LeftLowerLeg", 0.1], ["RightUpperLeg", "RightLowerLeg", 0.1]]
	body.weapon_raised = true
	for fidget: StringName in PlayerBody.FIDGETS:
		for mirrored: bool in [false, true]:
			body.set("_idle_mirrored", mirrored)
			for i in 120:
				step()
			body.start_fidget(fidget)
			var bins := {}
			var tip_before := Vector3.INF
			var tip_most := 0.0
			var frames := 0
			while body.fidget_playing() == fidget and frames < 1000:
				step()
				frames += 1
				var through := float(frames) / 60.0 / float((PlayerBody.FIDGETS[fidget] as Dictionary)["time"])
				var to_p := player.global_transform.affine_inverse()
				var eye_local: Vector3 = body.get("_eye")
				var eye := player.global_transform * eye_local
				var world := sk.global_transform
				var trunk: Array = []
				for part: Array in parts:
					trunk.append([(world * sk.get_bone_global_pose(sk.find_bone(part[0]))).origin, (world * sk.get_bone_global_pose(sk.find_bone(part[1]))).origin, part[2]])
				var m := {"sword-eyes": 9.0, "sword-body": 9.0, "sword-shield": 9.0, "arm-body": 9.0}
				var to_shield := shield_mesh.global_transform.affine_inverse()
				var shield_box := shield_mesh.mesh.get_aabb().grow(0.05)
				for v in verts:
					var at := sword_mesh.global_transform * v
					m["sword-eyes"] = minf(m["sword-eyes"], at.distance_to(eye))
					for t: Array in trunk:
						m["sword-body"] = minf(m["sword-body"], seg(at, t[0], t[1]) - (t[2] as float))
					var s := to_shield * at
					if shield_box.has_point(s):
						for w in shield_verts:
							m["sword-shield"] = minf(m["sword-shield"], s.distance_to(w))
				var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
				var r_elbow := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightLowerArm"))).origin
				var r_hand := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))).origin
				for k in 11:
					var on_forearm := r_elbow.lerp(r_hand, k / 10.0)
					for t: Array in trunk:
						m["arm-body"] = minf(m["arm-body"], seg(on_forearm, t[0], t[1]) - (t[2] as float) - 0.04)
				if OS.get_cmdline_user_args().has("--push-trace") and not mirrored and fidget == &"inspect":
					print("PUSH %.3f wanted %.3f m, eased %.3f m" % [through, (body.get("_weapon_push_wanted") as Vector3).length(), (body.get("_weapon_push") as Vector3).length()])
				if OS.get_cmdline_user_args().has("--roll-trace") and not mirrored and frames % 3 == 0:
					var r_shoulder := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightUpperArm"))).origin
					var axes := WeaponHold.hand_axes(right, "Right")
					var palm := (right.global_transform.basis * right.get_bone_global_pose(right.find_bone("RightHand")).basis * (axes["palm_out"] as Vector3)).normalized()
					var lower_q := right.get_bone_pose_rotation(right.find_bone("RightLowerArm"))
					var fingers := (right.global_transform.basis * right.get_bone_global_pose(right.find_bone("RightHand")).basis * (axes["fingers_out"] as Vector3)).normalized()
					var bend := rad_to_deg((r_hand - r_elbow).normalized().angle_to(fingers))
					var tip_speed := (sword_mesh.global_transform * Vector3(0, 0.9, 0)).distance_to(tip_before) * 60.0 if tip_before.is_finite() else 0.0
					print("ROLL %s %.3f forearm roll %+.0f deg, lower arm's own turn %.0f deg, wrist bent %.0f deg, tip %.2f m/s" % [fidget, through, WeaponStance._forearm_roll(r_shoulder, r_elbow, r_hand, palm), rad_to_deg(lower_q.get_angle()), bend, tip_speed])
				var tip := sword_mesh.global_transform * Vector3(0, 0.9, 0)
				if tip_before.is_finite():
					tip_most = maxf(tip_most, tip.distance_to(tip_before))
				tip_before = tip
				var bin := mini(int(through * 10.0), 9)
				if not bins.has(bin):
					bins[bin] = m
					bins[bin]["fist"] = to_p * r_hand - eye_local
					bins[bin]["blade"] = (to_p.basis * sword_mesh.global_transform.basis.y).normalized()
				else:
					for n: String in m:
						bins[bin][n] = minf(bins[bin][n], m[n])
			print("FIDGET %s, %s foot fwd: %d frames (%.2f s), the blade's tip at most %.3f m in a frame" % [fidget, "right" if mirrored else "left", frames, frames / 60.0, tip_most])
			for n: String in ["sword-eyes", "sword-body", "sword-shield", "arm-body"]:
				var line := "FIDGET   %-13s" % n
				for bin in 10:
					line += (" %+.2f" % (bins[bin][n] as float)) if bins.has(bin) and (bins[bin][n] as float) < 8.0 else "   . "
				print(line)
			for n: String in ["fist", "blade"]:
				var line := "FIDGET   %-6s" % n
				for bin in 10:
					line += " %s" % ((bins[bin][n] as Vector3).snappedf(0.01) if bins.has(bin) else "-")
				print(line)
			for i in 30:
				step()
	# By itself after the wait, and ended by a key.
	body.fidgets_on = true
	body.fidget_after = 1.0
	body.fidget_after_random = 0.0
	var waited := 0
	while body.fidget_playing() == &"" and waited < 600:
		step()
		waited += 1
	print("FIDGET by itself: %s after %.2f s standing" % [body.fidget_playing(), waited / 60.0])
	for i in 60:
		step()
	var hand_before := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand"))).origin
	body.interrupt_fidget()
	var ended := 0
	var hand_step := 0.0
	while body.fidget_playing() != &"" and ended < 120:
		step()
		ended += 1
		var hand_now := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightHand"))).origin
		hand_step = maxf(hand_step, hand_now.distance_to(hand_before))
		hand_before = hand_now
	print("FIDGET a key ended it in %.2f s; the wrist moved at most %.3f m in a frame meanwhile" % [ended / 60.0, hand_step])
	quit()
