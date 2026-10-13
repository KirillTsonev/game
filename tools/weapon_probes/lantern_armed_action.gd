extends SceneTree
# Weapons up, the whole lantern action at 60 frames a second, either foot forward: the least room of each kind in every tenth of the action. World space.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D
const NAMES := ["sword-body", "sword-lantern", "sword-shield", "sword-left arm", "sword-eyes", "arm-lantern", "arm-body", "knuckles touch", "fist-body", "fist behind", "fist right of"]

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

func step(delta: float) -> void:
	body.set_motion(Vector3.ZERO, true, false, false, delta)
	body.advance(delta, 0.0)

func _run() -> void:
	await _go()
	quit()

func _go() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hanging="):
			var n := arg.trim_prefix("--hanging=").split_floats(",")
			body.toggle_armed_fist_hanging = Vector3(n[0], n[1], n[2])
		if arg.begins_with("--around="):
			var n := arg.trim_prefix("--around=").split_floats(",")
			body.toggle_armed_around = Vector3(n[0], n[1], n[2])
	print("ACTION hanging ", body.toggle_armed_fist_hanging, " around ", body.toggle_armed_around)
	sk = body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var arms: Dictionary = body.get("_arms")
	var lantern := body.get("_lantern") as Node3D
	var sword := body.get("_weapon_node") as Node3D
	var shield := body.get("_shield_node") as Node3D
	var sword_mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = sword_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), 61):
		verts.append(all[i])
	var shield_box := shield_mesh.mesh.get_aabb()
	var shield_all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var shield_verts: PackedVector3Array = []
	for i in range(0, shield_all.size(), maxi(shield_all.size() / 500, 1)):
		shield_verts.append(shield_all[i])
	var parts: Array = [["Hips", "Spine", 0.17], ["Spine", "UpperChest", 0.17], ["UpperChest", "Neck", 0.15], ["LeftUpperLeg", "LeftLowerLeg", 0.1], ["LeftLowerLeg", "LeftFoot", 0.07], ["RightUpperLeg", "RightLowerLeg", 0.1], ["RightLowerLeg", "RightFoot", 0.07]]
	for mirrored: bool in [false, true]:
		body.weapon_raised = true
		body.set("_idle_mirrored", mirrored)
		for i in 90:
			step(1.0 / 60.0)
		body.toggle_lantern()
		var bins := {}
		var said := false
		var tip_before := Vector3.INF
		var tip_step := 0.0
		while body.turning_lantern():
			step(1.0 / 60.0)
			if not body.turning_lantern():
				break
			var through: float = (body.get("_toggle_at") as float) / body.toggle_time
			var world := sk.global_transform
			var top := lantern.global_transform * Vector3.ZERO
			var b_top := lantern.global_transform * Vector3(0.0, -0.14, 0.0)
			var b_low := lantern.global_transform * Vector3(0.0, -0.28, 0.0)
			var knuckles := Vector3.ZERO
			var left: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
			var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
			var l_elbow := (left.global_transform * left.get_bone_global_pose(left.find_bone("LeftLowerArm"))).origin
			var l_wrist := (left.global_transform * left.get_bone_global_pose(left.find_bone("LeftHand"))).origin
			var r_shoulder := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightUpperArm"))).origin
			var r_elbow := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightLowerArm"))).origin
			var r_hand := right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))
			var fist := r_hand * (arms["Right"]["palm"] as Vector3)
			var eye := player.global_transform * body.eye_position()
			var trunk: Array = []
			for part: Array in parts:
				trunk.append([(world * sk.get_bone_global_pose(sk.find_bone(part[0]))).origin, (world * sk.get_bone_global_pose(sk.find_bone(part[1]))).origin, part[2]])
			var m := {}
			for n: String in NAMES:
				m[n] = 9.0
			var to_shield := shield_mesh.global_transform.affine_inverse()
			for v in verts:
				var at := sword_mesh.global_transform * v
				for t: Array in trunk:
					m["sword-body"] = minf(m["sword-body"], seg(at, t[0], t[1]) - (t[2] as float))
				m["sword-lantern"] = minf(m["sword-lantern"], minf(seg(at, b_top, b_low) - 0.055, seg(at, top, b_top) - 0.03))
				m["sword-left arm"] = minf(m["sword-left arm"], seg(at, l_elbow, l_wrist + (l_wrist - l_elbow).normalized() * 0.1) - 0.05)
				m["sword-eyes"] = minf(m["sword-eyes"], at.distance_to(eye))
				var s := to_shield * at
				if s.x > shield_box.position.x - 0.05 and s.x < shield_box.end.x + 0.05 and s.y > shield_box.position.y - 0.05 and s.y < shield_box.end.y + 0.05 and s.z > shield_box.position.z - 0.05 and s.z < shield_box.end.z + 0.05:
					for w in shield_verts:
						m["sword-shield"] = minf(m["sword-shield"], s.distance_to(w))
			for k in 11:
				var on_forearm := r_elbow.lerp(r_hand.origin, k / 10.0)
				m["arm-lantern"] = minf(m["arm-lantern"], minf(seg(on_forearm, b_top, b_low) - 0.055, seg(on_forearm, top, b_top) - 0.03) - 0.035)
				var on_upper := r_shoulder.lerp(r_elbow, 0.5 + k / 20.0)
				for t: Array in trunk:
					m["arm-body"] = minf(m["arm-body"], minf(seg(on_forearm, t[0], t[1]), seg(on_upper, t[0], t[1])) - (t[2] as float) - 0.04)
			for t: Array in trunk:
				m["fist-body"] = minf(m["fist-body"], seg(fist, t[0], t[1]) - (t[2] as float) - 0.045)
			for finger: String in ["Index", "Middle", "Ring"]:
				knuckles += (right.global_transform * right.get_bone_global_pose(right.find_bone("Right" + finger + "Intermediate"))).origin / 3.0
			m["knuckles touch"] = seg(knuckles, b_top, b_low) - 0.055 - 0.015
			var in_player := player.global_transform.affine_inverse() * fist - (body.get("_bob") as Vector3)
			m["fist behind"] = in_player.z
			m["fist right of"] = in_player.x
			var tip := sword_mesh.global_transform * (Vector3(0, 0.9, 0))
			if tip_before.is_finite():
				tip_step = maxf(tip_step, tip.distance_to(tip_before))
				if tip.distance_to(tip_before) > 0.12:
					print("ACTION tip moved %.2f m in the frame at %.3f of the action" % [tip.distance_to(tip_before), through])
			tip_before = tip
			if not mirrored and through < 0.34:
				var tp := player.global_transform.affine_inverse()
				print("TRACE %.3f fist %s elbow %s shoulder %s blade %s lantern %s" % [through, (tp * fist).snappedf(0.01), (tp * r_elbow).snappedf(0.01), (tp * r_shoulder).snappedf(0.01), (tp.basis * sword_mesh.global_transform.basis.y).normalized().snappedf(0.01), (body.get("_bob") as Vector3).snappedf(0.01)])
			var bin := mini(int(through * 10.0), 9)
			if not bins.has(bin):
				bins[bin] = m
			else:
				for n: String in NAMES:
					bins[bin][n] = minf(bins[bin][n], m[n])
			if through > 0.5 and not said:
				said = true
				var to_p := player.global_transform.affine_inverse()
				print("ACTION %s foot: at the turn the fist is %s from the lantern's middle (Player's axes), blade toward %s, wrist at %s, elbow at %s, hook at %s, lantern's middle at %s" % ["right" if mirrored else "left", (to_p * fist - (body.get("_bob") as Vector3)).snappedf(0.01), (to_p.basis * sword_mesh.global_transform.basis.y).normalized().snappedf(0.01), (to_p * r_hand.origin).snappedf(0.01), (to_p * r_elbow).snappedf(0.01), (to_p * top).snappedf(0.01), (body.get("_bob") as Vector3).snappedf(0.01)])
		for n: String in NAMES:
			var line := "ACTION %s foot %-15s" % ["right" if mirrored else "left", n]
			for bin in 10:
				line += " %+.2f" % (bins[bin][n] as float) if bins.has(bin) and (bins[bin][n] as float) < 8.0 else "   . "
			print(line)
		print("ACTION largest move of the blade's tip in one frame: %.3f m" % tip_step)
		for i in 30:
			step(1.0 / 60.0)
	quit()
