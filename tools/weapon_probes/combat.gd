extends SceneTree
# The combat moves (PlayerBody.SWINGS, the block, BASH, BLOCK_HITS), weapons up, either foot forward, at 60 frames a second. Per 1/20 of each: where the fist is from the eyes (the Player's axes), the blade's way, the tip and the shield's middle in the picture (degrees right / up), the least room of the sword to the eyes, the body's capsules and the shield, of the shield to the eyes and the body, of the right forearm to the trunk; the wrist's bend and the forearm's roll; the shield's face. Then per move: the tip's fastest move in a frame (and when), the elbow's largest step in a frame (a flip, R7). Then a chained combo (forehand, backhand, forehand, clicked at "chain") and a swing clicked while blocking (a bash): the largest step of the tip at the joins.
# -- --only=<text>: only moves whose name contains it. -- --pitch=<rad>: the view's pitch.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D
var pitch := 0.0
var sword_mesh: MeshInstance3D
var shield_mesh: MeshInstance3D
var verts: PackedVector3Array = []
var shield_verts: PackedVector3Array = []
var parts: Array = [["Hips", "Spine", 0.17], ["Spine", "UpperChest", 0.17], ["UpperChest", "Neck", 0.15], ["Neck", "Head", 0.1], ["LeftUpperLeg", "LeftLowerLeg", 0.1], ["RightUpperLeg", "RightLowerLeg", 0.1]]

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

static func in_view(v: Vector3) -> Vector2:
	return Vector2(rad_to_deg(atan2(v.x, -v.z)), rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length())))

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, pitch)

func tip_world() -> Vector3:
	return sword_mesh.global_transform * Vector3(0, 0.9, 0)

func elbow_world() -> Vector3:
	var apart: Dictionary = body.get("_apart")
	var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
	return (right.global_transform * right.get_bone_global_pose(right.find_bone("RightLowerArm"))).origin

## One frame's measures.
func measure() -> Dictionary:
	var to_p := player.global_transform.affine_inverse()
	var eye_local: Vector3 = body.get("_eye")
	var eye := player.global_transform * eye_local
	var world := sk.global_transform
	var trunk: Array = []
	for part: Array in parts:
		trunk.append([(world * sk.get_bone_global_pose(sk.find_bone(part[0]))).origin, (world * sk.get_bone_global_pose(sk.find_bone(part[1]))).origin, part[2]])
	var m := {"sword-eyes": 9.0, "sword-body": 9.0, "sword-shield": 9.0, "shield-eyes": 9.0, "shield-body": 9.0, "arm-body": 9.0}
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
	for w in shield_verts:
		var at := shield_mesh.global_transform * w
		m["shield-eyes"] = minf(m["shield-eyes"], at.distance_to(eye))
		for t: Array in trunk:
			m["shield-body"] = minf(m["shield-body"], seg(at, t[0], t[1]) - (t[2] as float))
	var apart: Dictionary = body.get("_apart")
	var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
	var r_shoulder := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightUpperArm"))).origin
	var r_elbow := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightLowerArm"))).origin
	var r_hand := (right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))).origin
	for k in 11:
		var on_forearm := r_elbow.lerp(r_hand, k / 10.0)
		for t: Array in trunk:
			m["arm-body"] = minf(m["arm-body"], seg(on_forearm, t[0], t[1]) - (t[2] as float) - 0.04)
	var axes := WeaponHold.hand_axes(right, "Right")
	var hand_basis := right.global_transform.basis * right.get_bone_global_pose(right.find_bone("RightHand")).basis
	var palm := (hand_basis * (axes["palm_out"] as Vector3)).normalized()
	var fingers := (hand_basis * (axes["fingers_out"] as Vector3)).normalized()
	m["wrist"] = rad_to_deg((r_hand - r_elbow).normalized().angle_to(fingers))
	# The elbow's hinge: the axis the forearm folds about, in the upper arm's own axes, against the
	# stance's (0 = bent as the stance is; near 180 = bent the wrong way); and the bend itself.
	m["hinge"] = rad_to_deg(hinge_in_upper(right).angle_to(stance_hinge))
	m["bend"] = rad_to_deg((r_elbow - r_shoulder).angle_to(r_hand - r_elbow))
	# How far the elbow is above the higher of shoulder and wrist (cm; + = raised over a hanging
	# forearm, which reads as an elbow bent the wrong way -- Kirill, 2026-10-21, swing_down / swing_up).
	m["elbow_up"] = (r_elbow.y - maxf(r_shoulder.y, r_hand.y)) * 100.0
	# How far the upper arm is turned about its own line against the stance's, once its change of
	# line is taken the shortest way: the shoulder's own rotation of the upper arm (a real one goes
	# about 70-90 deg either way).
	var upper_now := right.get_bone_global_pose(right.find_bone("RightUpperArm")).basis.orthonormalized()
	var line_now := (right.get_bone_global_pose(right.find_bone("RightLowerArm")).origin - right.get_bone_global_pose(right.find_bone("RightUpperArm")).origin).normalized()
	var unturned := Basis(Quaternion(stance_upper_line, line_now)) * stance_upper
	var turned := (upper_now * unturned.inverse()).get_rotation_quaternion()
	m["twist"] = rad_to_deg(2.0 * atan2(Vector3(turned.x, turned.y, turned.z).dot(line_now), turned.w))
	m["twist"] = wrapf(m["twist"], -180.0, 180.0)
	m["roll"] = WeaponStance._forearm_roll(r_shoulder, r_elbow, r_hand, palm)
	m["palm"] = (to_p.basis * palm).normalized()
	m["fist"] = to_p * r_hand - eye_local
	m["blade"] = (to_p.basis * sword_mesh.global_transform.basis.y).normalized()
	m["tip"] = in_view(to_p * tip_world() - eye_local)
	var shield_node := body.get("_shield_node") as Node3D
	var middle_local: Vector3 = body.get("_shield_rim_middle")
	var face_local: Vector3 = body.get("_shield_face")
	var placed := to_p * shield_node.global_transform
	m["shield"] = in_view(placed * middle_local - eye_local)
	m["face"] = (placed.basis * face_local).normalized()
	return m

var stance_hinge := Vector3.ZERO
var dump_path := "" # -- --dump=<file.json>: each swing's frames (left foot) for tools/skyrim_reference/attack_analysis.py --ours
var dump_frames: Array = []
var dumped: Array = []
var trace := "" # -- --trace=<move>[:from:to]: that move's elbow frame by frame (left foot)
var trace_from := 0.0
var trace_to := 9.0
var stance_upper := Basis.IDENTITY
var stance_upper_line := Vector3.DOWN

## The axis the right forearm folds about (upper arm's line x forearm's), in the upper arm bone's axes.
static func hinge_in_upper(right: Skeleton3D) -> Vector3:
	var upper := right.get_bone_global_pose(right.find_bone("RightUpperArm"))
	var elbow := right.get_bone_global_pose(right.find_bone("RightLowerArm")).origin
	var wrist := right.get_bone_global_pose(right.find_bone("RightHand")).origin
	return (upper.basis.orthonormalized().inverse() * (elbow - upper.origin).cross(wrist - elbow)).normalized()

## Plays one move to its end (started by `start`), printing per 1/20.
func play(label: String, length: float, start: Callable) -> void:
	start.call()
	var bins := {}
	var tip_before := tip_world()
	var elbow_before := elbow_world()
	var tip_most := 0.0
	var tip_when := 0.0
	var elbow_most := 0.0
	var elbow_when := 0.0
	# The view's offset from the body's moves (view_offset: pitch, turn, tilt; degrees): its range
	# and its largest step in a frame (a jump in the view would show there).
	var head_low := Vector3.ZERO
	var head_high := Vector3.ZERO
	var head_step := 0.0
	var head_before := Vector3.ZERO
	var frames := 0
	while frames < int(length * 60.0) + 2:
		step()
		frames += 1
		var m := measure()
		var tip := tip_world()
		var elbow := elbow_world()
		if tip.distance_to(tip_before) > tip_most:
			tip_most = tip.distance_to(tip_before)
			tip_when = frames / 60.0
		var elbow_step := elbow.distance_to(elbow_before)
		var head := body.view_offset() * (180.0 / PI)
		head_low = head_low.min(head)
		head_high = head_high.max(head)
		head_step = maxf(head_step, head.distance_to(head_before))
		head_before = head
		if dump_path != "" and label.begins_with("swing_") and label.contains("left foot"):
			# Skyrim's model axes from the eyes (+X right, +Y ahead, +Z up) for attack_analysis.py.
			var to_p := player.global_transform.affine_inverse()
			var eye_local: Vector3 = body.get("_eye")
			var sky := func(v: Vector3) -> Array: return [v.x, -v.z, v.y]
			var apart: Dictionary = body.get("_apart")
			var right: Skeleton3D = apart["Right"]["skeleton"]
			var bone_at := func(bone: String) -> Vector3: return to_p * (right.global_transform * right.get_bone_global_pose(right.find_bone(bone))).origin - eye_local
			var hand_pose: Transform3D = to_p * right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))
			var socket: Transform3D = body.get("_weapon_socket")
			var sword_node := body.get("_weapon_node") as Node3D
			var sword_basis := (to_p * sword_node.global_transform).basis
			dump_frames.append({"grip": sky.call(hand_pose * socket.origin - eye_local), "blade": sky.call(sword_basis.z.normalized()), "edge": sky.call(sword_basis.x.normalized()),
					"hand": sky.call(bone_at.call("RightHand")), "fore": sky.call(bone_at.call("RightLowerArm")), "upper": sky.call(bone_at.call("RightUpperArm"))})
		if elbow.distance_to(elbow_before) > elbow_most:
			elbow_most = elbow.distance_to(elbow_before)
			elbow_when = frames / 60.0
		tip_before = tip
		elbow_before = elbow
		if trace != "" and label.begins_with(trace) and label.contains("left foot") and frames / 60.0 >= trace_from and frames / 60.0 <= trace_to:
			var last: Dictionary = body.get("_clip_last")
			print("TRACE %.3f elbow %s (step %.3f) way %s bend %.0f twist %+.0f hinge %.0f wrist %.0f elbow_up %+.0f" % [frames / 60.0, (player.global_transform.affine_inverse() * elbow - (body.get("_eye") as Vector3)).snappedf(0.01), elbow_step, ((last["elbow"] as Vector3) if last.has("elbow") else Vector3.ZERO).snappedf(0.01), m["bend"], m["twist"], m["hinge"], m["wrist"], m["elbow_up"]])
		var bin := mini(int(frames / 60.0 / length * 20.0), 19)
		if not bins.has(bin):
			bins[bin] = m
		else:
			for n: String in ["sword-eyes", "sword-body", "sword-shield", "shield-eyes", "shield-body", "arm-body"]:
				bins[bin][n] = minf(bins[bin][n], m[n])
			bins[bin]["wrist"] = maxf(bins[bin]["wrist"], m["wrist"])
			bins[bin]["elbow_up"] = maxf(bins[bin]["elbow_up"], m["elbow_up"])
	if not dump_frames.is_empty():
		dumped.append({"name": label, "dt": 1.0 / 60.0, "frames": dump_frames.duplicate()})
		dump_frames.clear()
	print("COMBAT %s: the view nods %+.1f..%+.1f deg, turns %+.1f..%+.1f (- = right), tilts %+.1f..%+.1f, at most %.2f deg in a frame" % [label, head_low.x, head_high.x, head_low.y, head_high.y, head_low.z, head_high.z, head_step])
	print("COMBAT %s: the tip at most %.3f m in a frame (%.1f m/s) at %.2f s; the elbow at most %.3f m in a frame at %.2f s" % [label, tip_most, tip_most * 60.0, tip_when, elbow_most, elbow_when])
	var least := {}
	for n: String in ["sword-eyes", "sword-body", "sword-shield", "shield-eyes", "shield-body", "arm-body"]:
		var line := "COMBAT   %-12s" % n
		least[n] = 9.0
		for bin in 20:
			var v: float = bins[bin][n] if bins.has(bin) else 9.0
			least[n] = minf(least[n], v)
			line += (" %+.2f" % v) if v < 8.0 else "   . "
		print(line)
	for n: String in ["wrist", "roll", "hinge", "bend", "twist", "elbow_up"]:
		var line := "COMBAT   %-12s" % n
		for bin in 20:
			line += (" %5.0f" % (bins[bin][n] as float)) if bins.has(bin) else "    - "
		print(line)
	for n: String in ["tip", "shield"]:
		var line := "COMBAT   %-12s" % n
		for bin in 20:
			line += (" %s" % (bins[bin][n] as Vector2).round()) if bins.has(bin) else " -"
		print(line)
	for n: String in ["fist", "blade", "palm", "face"]:
		var line := "COMBAT   %-6s" % n
		for bin in range(0, 20, 2):
			line += " %s" % ((bins[bin][n] as Vector3).snappedf(0.01) if bins.has(bin) else "-")
		print(line)
	print("COMBAT   least: %s" % least)

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pitch="):
			pitch = arg.trim_prefix("--pitch=").to_float()
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
		if arg.begins_with("--dump="):
			dump_path = arg.trim_prefix("--dump=")
		if arg.begins_with("--trace="):
			var parts_given := arg.trim_prefix("--trace=").split(":")
			trace = parts_given[0]
			if parts_given.size() >= 3:
				trace_from = parts_given[1].to_float()
				trace_to = parts_given[2].to_float()
	sk = body.get("_skeleton") as Skeleton3D
	sword_mesh = (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	shield_mesh = (body.get("_shield_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = sword_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for i in range(0, all.size(), 61):
		verts.append(all[i])
	var shield_all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for i in range(0, shield_all.size(), maxi(shield_all.size() / 400, 1)):
		shield_verts.append(shield_all[i])
	body.weapon_raised = true
	for mirrored: bool in [false, true]:
		body.set("_idle_mirrored", mirrored)
		var foot := "right" if mirrored else "left"
		for i in 150:
			step()
		var apart_now: Dictionary = body.get("_apart")
		var right_now: Skeleton3D = apart_now["Right"]["skeleton"]
		stance_hinge = hinge_in_upper(right_now)
		stance_upper = right_now.get_bone_global_pose(right_now.find_bone("RightUpperArm")).basis.orthonormalized()
		stance_upper_line = (right_now.get_bone_global_pose(right_now.find_bone("RightLowerArm")).origin - right_now.get_bone_global_pose(right_now.find_bone("RightUpperArm")).origin).normalized()
		if only == "" or "stance".contains(only):
			play("stance, %s foot fwd" % foot, 0.5, func() -> void: pass)
		for swing: StringName in PlayerBody.SWINGS:
			if only != "" and not String(swing).contains(only):
				continue
			play("%s, %s foot fwd" % [swing, foot], float((PlayerBody.SWINGS[swing] as Dictionary)["time"]), func() -> void: body.call("_start_swing", swing, false))
			for i in 20:
				step()
		if only == "" or "dodge".contains(only):
			# The arms in a dash's dodge (PlayerBody.DODGE_ARMS), weapons up: from the idle hold back
			# into it -- the tip's place before and after, to see that it lands where it left.
			for way: Vector3 in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
				var name_of := {Vector3.FORWARD: "forward", Vector3.BACK: "back", Vector3.LEFT: "left", Vector3.RIGHT: "right"}[way] as String
				var tip_before := tip_world()
				play("dodge_%s, %s foot fwd" % [name_of, foot], body.dodge_arm_time + 0.2, func() -> void: body.start_dash(way, 0.4))
				print("COMBAT   dodge_%s: the tip %.3f m from where it was before the dodge" % [name_of, tip_world().distance_to(tip_before)])
				for i in 20:
					step()
		if only == "" or "block".contains(only) or "bash".contains(only) or "hit".contains(only):
			body.blocking = true
			play("block up, %s foot fwd" % foot, 0.5, func() -> void: pass)
			play("bash, %s foot fwd" % foot, float(PlayerBody.BASH["time"]), func() -> void: body.attack())
			for h in PlayerBody.BLOCK_HITS.size():
				play("block_hit_%d, %s foot fwd" % [h, foot], float(PlayerBody.BLOCK_HITS[h]["time"]), func() -> void:
					body.set("_hit_index", h)
					body.set("_hit_at", 0.0))
			body.blocking = false
			play("block down, %s foot fwd" % foot, 0.5, func() -> void: pass)
		for i in 30:
			step()
	# A chained combo: click at each swing's "chain", three swings; the tip's largest step a frame
	# around each join (a jump would show there).
	if only == "" or "combo".contains(only):
		body.set("_idle_mirrored", false)
		for i in 60:
			step()
		body.attack()
		var tip_before := tip_world()
		var largest := 0.0
		var played: Array[String] = []
		for frame in 200:
			if body.combat_playing() != &"" and body.combat_time() >= float((PlayerBody.SWINGS[body.combat_playing()] as Dictionary)["chain"]) and played.size() < 3:
				played.append(String(body.combat_playing()))
				body.attack()
				var join_before := tip_world()
				step()
				print("COMBO join %d (%s -> %s): the tip moved %.3f m in the frame" % [played.size(), played[-1], body.combat_playing(), tip_world().distance_to(join_before)])
				tip_before = tip_world()
				continue
			step()
			largest = maxf(largest, tip_world().distance_to(tip_before))
			tip_before = tip_world()
		print("COMBO the tip at most %.3f m in a frame over the combo; ended with %s" % [largest, body.combat_playing()])
	if dump_path != "":
		var file := FileAccess.open(dump_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(dumped))
		file.close()
		print("COMBAT dumped %d swings to %s" % [dumped.size(), dump_path])
	quit()
