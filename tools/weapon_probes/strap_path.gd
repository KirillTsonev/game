extends SceneTree
# The strap fidget (PlayerBody.FIDGETS strap), weapons sheathed, standing: (1) the right palm's
# way in during "raise the shield", every 3 frames: where it is against the board (its height
# above the board's face, + = on the side facing away from the body; and whether it is inside the
# board's outline), and where it is seen; (2) held at the grip (debug_drive) for 5 s: how far the
# palm, the aimed point and the shield's middle move in the picture (degrees) with the breathing.
# JITTER lines: frames where the palm's speed changes by more than 0.15 m/s. `-- --warm=<frames>`:
# how long to stand before the fidget (default 120), to start it at another point of the idle.
# `-- --trace-15`: every frame from 0.135 to 0.17, the right arm's stretch, elbow and hand turn.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D
const CHAINS := [["RightThumbMetacarpal", "RightThumbProximal", "RightThumbDistal"], ["RightIndexProximal", "RightIndexIntermediate", "RightIndexDistal"], ["RightMiddleProximal", "RightMiddleIntermediate", "RightMiddleDistal"], ["RightRingProximal", "RightRingIntermediate", "RightRingDistal"], ["RightLittleProximal", "RightLittleIntermediate", "RightLittleDistal"]]

func _init() -> void:
	_run.call_deferred()

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

func seen(at: Vector3) -> Vector2:
	var view := body.view_offset()
	var look := Basis(Vector3.UP, view.y) * Basis(Vector3.RIGHT, view.x)
	var to := (look.inverse() * (at - (body.get("_eye") as Vector3))).normalized()
	return Vector2(rad_to_deg(atan2(to.x, -to.z)), rad_to_deg(atan2(to.y, -to.z)))

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	body.weapon_raised = false
	sk = body.get("_skeleton") as Skeleton3D
	var arms: Dictionary = body.get("_arms")
	var shield_mesh := (body.get("_shield_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var box := shield_mesh.mesh.get_aabb()
	# The board's thin axis is its face's normal.
	var thin := 0
	for a in 3:
		if box.size[a] < box.size[thin]:
			thin = a
	var all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), maxi(all.size() / 2000, 1)):
		verts.append(all[i])
	var warm := 120
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--warm="):
			warm = arg.trim_prefix("--warm=").to_int()
	for i in warm:
		step()
	var lower_id: int = arms["Left"]["lower"]
	print("ELBOW before: the left lower arm's own position %s" % sk.get_bone_pose_position(lower_id))
	body.start_fidget(&"strap")
	var time := float((PlayerBody.FIDGETS[&"strap"] as Dictionary)["time"])
	var frames := 0
	var tri := shield_mesh.mesh.generate_triangle_mesh()
	var palm_was := Vector3.INF
	var speed_was := Vector3.INF
	var aim_was := Vector3.INF
	var trace_hand := Basis()
	while body.fidget_playing() == &"strap" and frames < 60 * 4:
		step()
		frames += 1
		var through := frames / 60.0 / time
		# Jitter: a frame where the palm's speed changes sharply, or the aimed point jumps.
		var palm_now := (player.global_transform.affine_inverse() * sk.global_transform) * (sk.get_bone_global_pose(arms["Right"]["hand"]) * (arms["Right"]["palm"] as Vector3))
		var aim_now: Vector3 = body.get("_rim_target")
		if palm_was.is_finite():
			var speed := (palm_now - palm_was) * 60.0
			if speed_was.is_finite() and (speed - speed_was).length() > 0.15:
				print("JITTER %.3f the palm's speed changed by %.2f m/s in a frame (%.2f -> %.2f m/s); the aim moved %.3f m" % [through, (speed - speed_was).length(), speed_was.length(), speed.length(), aim_now.distance_to(aim_was)])
			if OS.get_cmdline_user_args().has("--trace-15") and through > 0.135 and through < 0.17:
				var b := player.global_transform.affine_inverse() * sk.global_transform
				var wr := b * sk.get_bone_global_pose(arms["Right"]["hand"]).origin
				var el := b * sk.get_bone_global_pose(arms["Right"]["lower"]).origin
				var hb := (b.basis * sk.get_bone_global_pose(arms["Right"]["hand"]).basis).orthonormalized()
				var shd := b * sk.get_bone_global_pose(arms["Right"]["upper"]).origin
				print("FRAME %.3f shoulder to wrist %.3f m (arm %.3f), elbow bent %.1f deg" % [through, shd.distance_to(wr), shd.distance_to(el) + el.distance_to(wr), 180.0 - rad_to_deg((shd - el).angle_to(wr - el))])
				print("FRAME %.3f palm v %s | wrist %s elbow %s | hand turned %.1f deg | aim %s | rim pick %d" % [through, speed.snappedf(0.01), wr.snappedf(0.001), el.snappedf(0.001), rad_to_deg(Quaternion(hb).angle_to(Quaternion(trace_hand))) if trace_hand != Basis() else 0.0, aim_now.snappedf(0.001), body.get("_rim_pick")])
				trace_hand = hb
			speed_was = speed
		palm_was = palm_now
		aim_was = aim_now
		# The thumb and fingers through the board: each bone (and on past the last joint by a
		# fingertip's length) tested against the board's triangles.
		if through > 0.15 and through < 0.9:
			var to_board := shield_mesh.global_transform.affine_inverse() * sk.global_transform
			var through_list: Array[String] = []
			for chain: Array in CHAINS:
				var points: Array[Vector3] = [to_board * sk.get_bone_global_pose(arms["Right"]["hand"]).origin]
				for bone_name: String in chain:
					points.append(to_board * sk.get_bone_global_pose(sk.find_bone(bone_name)).origin)
				# The tip: on from the last joint by three quarters of the segment before it (a
				# fixed 2.5 cm put the little finger's tip past its real end).
				var last := sk.get_bone_global_pose(sk.find_bone(chain[-1]))
				var before := sk.get_bone_global_pose(sk.find_bone(chain[-2]))
				points.append(to_board * (last * Vector3(0, 0.75 * last.origin.distance_to(before.origin), 0)))
				for k in points.size() - 1:
					if not tri.intersect_segment(points[k], points[k + 1]).is_empty():
						through_list.append("%s seg %d" % [chain[-1], k])
			if not through_list.is_empty():
				print("CLIP %.3f %s" % [through, ", ".join(through_list)])
			if frames % 6 == 0:
				# Across the board at the grip: + = the side the board's face looks to (thin axis).
				var aim_board := to_board * (sk.global_transform.affine_inverse() * player.global_transform * aim_now)
				var tip := func(bone_name: String) -> Vector3:
					return to_board * (sk.get_bone_global_pose(sk.find_bone(bone_name)) * Vector3(0, 0.025, 0))
				var thumb_tip: Vector3 = tip.call("RightThumbDistal")
				var middle_tip: Vector3 = tip.call("RightMiddleDistal")
				var palm_board := to_board * (sk.get_bone_global_pose(arms["Right"]["hand"]) * (arms["Right"]["palm"] as Vector3))
				print("SIDES %.3f across the board from the grip point: thumb tip %+.3f, middle tip %+.3f, palm %+.3f m" % [through, (thumb_tip - aim_board)[thin] * signf(box.size[thin]), (middle_tip - aim_board)[thin] * signf(box.size[thin]), (palm_board - aim_board)[thin] * signf(box.size[thin])])
		if frames % 3 != 0 or (through > 0.42 and through < 0.6):
			continue
		var to_p := player.global_transform.affine_inverse()
		var bones := to_p * sk.global_transform
		var palm := bones * (sk.get_bone_global_pose(arms["Right"]["hand"]) * (arms["Right"]["palm"] as Vector3))
		var in_board := shield_mesh.global_transform.affine_inverse() * (player.global_transform * palm)
		var mid := box.get_center()
		var out_of_face := (in_board[thin] - mid[thin]) * signf(box.size[thin])
		var inside := true
		for a in 3:
			if a != thin and (in_board[a] < box.position[a] or in_board[a] > box.end[a]):
				inside = false
		var s := seen(palm)
		# The hand's least room to the board's mesh: palm, wrist and the middle finger's tip.
		var hand_points: Array[Vector3] = [palm, bones * sk.get_bone_global_pose(arms["Right"]["hand"]).origin, bones * sk.get_bone_global_pose(sk.find_bone("RightMiddleDistal")).origin]
		var room := 9.0
		for v in verts:
			var at := to_p * (shield_mesh.global_transform * v)
			for h in hand_points:
				room = minf(room, h.distance_to(at))
		print("PATH %.2f palm %+.3f m off the board's middle plane (%s the outline) | hand to the mesh %.3f m | seen %+.0f right %+.0f up | palm %s" % [through, out_of_face, "INSIDE" if inside else "outside", room, s.x, s.y, palm.snappedf(0.01)])
	# Held at the grip.
	for hold_at: float in [0.368, 0.2]:
		var lo := Vector2.INF
		var hi := -Vector2.INF
		var lo_aim := Vector2.INF
		var hi_aim := -Vector2.INF
		var lo_mid := Vector2.INF
		var hi_mid := -Vector2.INF
		var gap := Vector2(INF, -INF)
		var eye_lo := Vector3.INF
		var eye_hi := -Vector3.INF
		for i in 300:
			body.debug_drive(&"strap", hold_at * time)
			step()
			if i < 60:
				continue
			var to_p := player.global_transform.affine_inverse()
			var bones := to_p * sk.global_transform
			var palm := bones * (sk.get_bone_global_pose(arms["Right"]["hand"]) * (arms["Right"]["palm"] as Vector3))
			var s := seen(palm)
			lo = lo.min(s)
			hi = hi.max(s)
			var aim: Vector3 = body.get("_rim_target")
			var sa := seen(aim)
			lo_aim = lo_aim.min(sa)
			hi_aim = hi_aim.max(sa)
			var sm := seen(to_p * shield_mesh.global_transform.origin)
			lo_mid = lo_mid.min(sm)
			hi_mid = hi_mid.max(sm)
			var d := palm.distance_to(aim)
			gap = Vector2(minf(gap.x, d), maxf(gap.y, d))
			var e: Vector3 = body.get("_eye")
			eye_lo = eye_lo.min(e)
			eye_hi = eye_hi.max(e)
			if OS.get_cmdline_user_args().has("--trace-hold") and hold_at > 0.3 and i % 10 == 0:
				var shoulder := bones * sk.get_bone_global_pose(arms["Left"]["upper"]).origin
				var chest := bones * sk.get_bone_global_pose(sk.find_bone("UpperChest")).origin
				var lhand := bones * sk.get_bone_global_pose(arms["Left"]["hand"]).origin
				var on_arm: Transform3D = bones * sk.get_bone_global_pose(body.get("_shield_bone")) * WeaponHold.in_hand(body.get("_shield_now"), body.shield)
				var placed: Transform3D = to_p * (body.get("_shield_node") as Node3D).global_transform
				var upper_len := (sk.get_bone_global_pose(arms["Left"]["lower"]).origin - sk.get_bone_global_pose(arms["Left"]["upper"]).origin).length()
				print("ARM-OFF the forearm's board vs the drawn one: %.3f m, %.1f deg; the left upper arm %.3f m long (rest %.3f)" % [on_arm.origin.distance_to(placed.origin), rad_to_deg(Quaternion(on_arm.basis.orthonormalized()).angle_to(Quaternion(placed.basis.orthonormalized()))), upper_len, sk.get_bone_rest(arms["Left"]["lower"]).origin.length()])
				print("TRACE eye %s | shoulder-eye %s | chest-eye %s | breath %s | left hand-eye %s | shield mid-eye %s | shield basis y %s" % [e.snappedf(0.001), (shoulder - e).snappedf(0.001), (chest - e).snappedf(0.001), (body.get("_breath_now") as Vector3).snappedf(0.001), (lhand - e).snappedf(0.001), (to_p * shield_mesh.global_transform.origin - e).snappedf(0.001), (to_p.basis * shield_mesh.global_transform.basis.y).normalized().snappedf(0.01)])
		body.debug_release()
		for i in 120:
			step()
		print("ELBOW after a hold and release: %s" % sk.get_bone_pose_position(lower_id))
		print("HOLD at %.2f: palm moves %.2f x %.2f deg in the picture, the aim %.2f x %.2f, the shield's middle %.2f x %.2f; palm to aim %.3f..%.3f m; the eyes move %s m" % [hold_at, hi.x - lo.x, hi.y - lo.y, hi_aim.x - lo_aim.x, hi_aim.y - lo_aim.y, hi_mid.x - lo_mid.x, hi_mid.y - lo_mid.y, gap.x, gap.y, (eye_hi - eye_lo).snappedf(0.001)])
	quit()
