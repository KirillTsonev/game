extends SceneTree
# The fidgets with the weapons sheathed (PlayerBody.FIDGETS with "when": sheathed), the lantern lit, either foot forward, looking level: per tenth of each the view's dip and turn, where the right palm is in the picture (degrees off the middle, and whether it is inside a 16:9 picture of the camera's fov), the right arm's least room to the trunk and legs, and for the lantern the palm's distance to its bottom and how far it is lifted from hanging.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

## The least room of a forearm (elbow to wrist) to the body's capsules, less the forearm's own thickness.
func _arm_room(bones: Transform3D, elbow: Vector3, wrist: Vector3, parts: Array) -> float:
	var least := 9.0
	for k in 11:
		var p := elbow.lerp(wrist, k / 10.0)
		for part: Array in parts:
			least = minf(least, seg(p, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float) - 0.04)
	return least

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	body.weapon_raised = false
	(body.get("_lantern_light") as Light3D).visible = true
	sk = body.get("_skeleton") as Skeleton3D
	var arms: Dictionary = body.get("_arms")
	var lantern := body.get("_lantern") as Node3D
	var camera := player.get_node("Camera3D") as Camera3D
	var fov_v := deg_to_rad(camera.fov)
	var fov_h := 2.0 * atan(tan(fov_v * 0.5) * 16.0 / 9.0)
	var parts: Array = [["Hips", "Spine", 0.17], ["Spine", "UpperChest", 0.17], ["RightUpperLeg", "RightLowerLeg", 0.1], ["LeftUpperLeg", "LeftLowerLeg", 0.1]]
	# The trunk for the lantern: its middle line (the capsules above are for the arm, which
	# reads 3-4 cm "in" hanging); thighs as above.
	var lantern_parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["RightUpperLeg", "RightLowerLeg", 0.09], ["LeftUpperLeg", "LeftLowerLeg", 0.09]]
	var shield_mesh := (body.get("_shield_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_all: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var shield_verts: PackedVector3Array = []
	for i in range(0, shield_all.size(), maxi(shield_all.size() / 400, 1)):
		shield_verts.append(shield_all[i])
	var lantern_meshes: Array = (body.get("_lantern") as Node3D).find_children("*", "MeshInstance3D", true, false)
	var lantern_verts := {}
	for mesh: MeshInstance3D in lantern_meshes:
		var all: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var some: PackedVector3Array = []
		for i in range(0, all.size(), maxi(all.size() / 300, 1)):
			some.append(all[i])
		lantern_verts[mesh] = some
	for fidget: StringName in PlayerBody.FIDGETS:
		if (PlayerBody.FIDGETS[fidget] as Dictionary).get("when", &"drawn") != &"sheathed":
			continue
		for mirrored: bool in [false, true]:
			body.set("_idle_mirrored", mirrored)
			for i in 120:
				step()
			var hung := (body.get("_bob") as Vector3) - (body.get("_bob") as Vector3) # zero
			body.start_fidget(fidget)
			var rows: Array[String] = []
			var frames := 0
			var hang_dir := Vector3.ZERO
			var palm_before := Vector3.INF
			var lantern_least := 9.0
			var shield_least := 9.0
			while body.fidget_playing() == fidget and frames < 600:
				step()
				frames += 1
				var through := float(frames) / 60.0 / float((PlayerBody.FIDGETS[fidget] as Dictionary)["time"])
				var to_p := player.global_transform.affine_inverse()
				var bones := to_p * sk.global_transform
				var eye: Vector3 = body.get("_eye")
				var view := body.view_offset()
				var look := Basis(Vector3.UP, view.y) * Basis(Vector3.RIGHT, view.x)
				var palm := bones * (sk.get_bone_global_pose(arms["Right"]["hand"]) * (arms["Right"]["palm"] as Vector3))
				var to_palm := (look.inverse() * (palm - eye)).normalized()
				var off_h := rad_to_deg(atan2(to_palm.x, -to_palm.z))
				var off_v := rad_to_deg(atan2(to_palm.y, -to_palm.z))
				var seen := absf(deg_to_rad(off_h)) < fov_h * 0.5 and absf(deg_to_rad(off_v)) < fov_v * 0.5 and to_palm.z < 0.0
				var least := 9.0
				var r_elbow := bones * sk.get_bone_global_pose(arms["Right"]["lower"]).origin
				var r_hand := bones * sk.get_bone_global_pose(arms["Right"]["hand"]).origin
				for k in 11:
					var p := r_elbow.lerp(r_hand, k / 10.0)
					for part: Array in parts:
						least = minf(least, seg(p, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float) - 0.04)
				var extra := ""
				if fidget == &"strap":
					# The right palm against the left forearm (on the strap: about 0.05 m off its
					# middle line), the shield's mesh against the trunk and thighs, and where the
					# shield's middle is in the picture.
					var l_elbow := bones * sk.get_bone_global_pose(arms["Left"]["lower"]).origin
					var l_wrist := bones * sk.get_bone_global_pose(arms["Left"]["hand"]).origin
					var shield_room := 9.0
					var palm_to_shield := 9.0
					for v: Vector3 in shield_verts:
						var at: Vector3 = to_p * (shield_mesh.global_transform * v)
						palm_to_shield = minf(palm_to_shield, palm.distance_to(at))
						for part: Array in lantern_parts:
							shield_room = minf(shield_room, seg(at, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float))
					shield_least = minf(shield_least, shield_room)
					if shield_room < 0.0:
						print("SHIELD-IN %s %.3f %+.3f m" % ["right" if mirrored else "left", through, shield_room])
					var to_shield := (look.inverse() * (to_p * shield_mesh.global_transform.origin - eye)).normalized()
					var aim: Vector3 = body.get("_rim_target")
					var to_aim := (look.inverse() * (aim - eye)).normalized()
					extra = " | aimed at %+.0f right %+.0f up, palm %.3f m from it, shoulder to it %.2f m" % [rad_to_deg(atan2(to_aim.x, -to_aim.z)), rad_to_deg(atan2(to_aim.y, -to_aim.z)), palm.distance_to(aim), (bones * sk.get_bone_global_pose(arms["Right"]["upper"]).origin).distance_to(aim)]
					extra += " | palm to the shield %.3f m (forearm's line %.3f) | shield to the body %+.3f m, its middle %+.0f right %+.0f up | left arm-body %+.2f" % [palm_to_shield, seg(palm, l_elbow, l_wrist), shield_room, rad_to_deg(atan2(to_shield.x, -to_shield.z)), rad_to_deg(atan2(to_shield.y, -to_shield.z)), _arm_room(bones, l_elbow, l_wrist, parts)]
				if fidget == &"lantern_look":
					var top := to_p * lantern.global_transform.origin
					var bottom := to_p * (lantern.global_transform * Vector3(0, -0.3, 0))
					if hang_dir == Vector3.ZERO:
						hang_dir = (bottom - top).normalized()
					var body_top := to_p * (lantern.global_transform * Vector3(0, -0.14, 0))
					var body_low := to_p * (lantern.global_transform * Vector3(0, -0.28, 0))
					# Round the lantern's axis: where the palm is, in the lantern's own axes.
					var in_lantern := lantern.global_transform.affine_inverse() * (player.global_transform * palm)
					# The thumb's tip (its last joint) against the lantern's body, and how fast the palm moves.
					var thumb := bones * sk.get_bone_global_pose(sk.find_bone("RightThumbDistal")).origin
					var palm_speed := palm.distance_to(palm_before) * 60.0 if palm_before.is_finite() else 0.0
					palm_before = palm
					extra += " | thumb to the lantern's body %+.3f m, palm %.2f m/s" % [seg(thumb, body_top, body_low) - 0.055 - 0.01, palm_speed]
					# The lantern's mesh against the trunk and the thighs.
					var lantern_room := 9.0
					var lantern_where := ""
					for mesh: MeshInstance3D in lantern_meshes:
						for v: Vector3 in lantern_verts[mesh]:
							var at: Vector3 = to_p * (mesh.global_transform * v)
							for part: Array in lantern_parts:
								var room := seg(at, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float)
								if room < lantern_room:
									lantern_room = room
									lantern_where = "%s, %.2f m down the lantern" % [part[0], -(lantern.global_transform.affine_inverse() * (mesh.global_transform * v)).y]
					extra += " | lantern to the body %+.3f m (%s)" % [lantern_room, lantern_where]
					lantern_least = minf(lantern_least, lantern_room)
					extra = " | palm to the lantern's body %+.3f m, lifted %.0f deg, lantern turned %.0f deg, palm round it at %.0f deg" % [seg(palm, body_top, body_low) - 0.055, rad_to_deg(hang_dir.angle_to((bottom - top).normalized())), rad_to_deg(body.get("_lantern_spin")), rad_to_deg(atan2(in_lantern.x, in_lantern.z))] + extra
				if frames % (4 if fidget == &"lantern_look" and through > 0.55 and through < 0.95 else 12) == 0:
					rows.append("SHEATHED   %.2f dip %+.0f turn %+.0f | palm %+.0f right %+.0f up of the middle, %s | arm-body %+.2f%s" % [through, rad_to_deg(view.x), rad_to_deg(-view.y), off_h, off_v, "IN view" if seen else "out of view", least, extra])
			print("SHEATHED %s, %s foot fwd: %d frames (fov %.0f x %.0f deg)%s" % [fidget, "right" if mirrored else "left", frames, rad_to_deg(fov_h), rad_to_deg(fov_v), (" -- the lantern's least room to the body %+.3f m" % lantern_least) if fidget == &"lantern_look" else (" -- the shield's least room to the body %+.3f m" % shield_least) if fidget == &"strap" else ""])
			if not mirrored:
				for row in rows:
					print(row)
			for i in 30:
				step()
	quit()
