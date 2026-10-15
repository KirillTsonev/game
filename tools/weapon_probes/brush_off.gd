extends SceneTree
# brush_off (PlayerBody.FIDGETS), weapons sheathed, with the shield on the forearm and with none, either foot forward, looking level. Per 1/20 of it: the view's dip and turn, where the right palm is in the picture, the palm's and the five fingertips' height off the brushed surface (its plane along the stroke line; below 0 = in it), the palm along the line (0 start, 1 end), the right arm's room to the trunk and legs, the shield's room to them; and over the whole: the line's ends on the board (in the model's axes, against its box), the face's angle off the way to the eyes, the palm's fastest move, the least fingertip height while on the surface.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

## `-- --search`: the shield held at many places ("shield_arm"), its face turned toward the eyes by
## several shares ("face_to_eyes"), the strokes three ways; each held at the first stroke's start
## and measured: the shield's least room to the trunk and legs, the face's angle off the way to
## the eyes, the right shoulder's distance to the line's ends (the arm reaches about 0.56 m to the
## palm), the line's middle in the picture, the palm's miss at the start and the right arm's room
## to the body. The ones with room >= 0.02 printed, best face first.
func _search(arms: Dictionary, shield_parts: Array, parts: Array, fov_h: float, fov_v: float) -> void:
	var shield_node := body.get("_shield_node") as Node3D
	var mesh := shield_node.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var all: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts: PackedVector3Array = []
	for i in range(0, all.size(), maxi(all.size() / 250, 1)):
		verts.append(all[i])
	var time := float((PlayerBody.FIDGETS[&"brush_off"] as Dictionary)["time"])
	var found: Array = []
	for x in [-0.05, 0.05, 0.15, 0.25]:
		for y in [-0.32, -0.22, -0.12]:
			for z in [-0.28, -0.38, -0.46]:
				for face in [0.4, 0.55, 0.7, 0.85, 1.0]:
					for way: Vector3 in [Vector3.ZERO]:
						body.brush_try = {"shield_arm": Vector3(x, y, z), "face_to_eyes": face}
						body.start_fidget(&"brush_off")
						for i in 3:
							body.debug_drive(&"brush_off", 0.3 * time)
							step()
						var to_p := player.global_transform.affine_inverse()
						var bones := to_p * sk.global_transform
						var eye: Vector3 = body.get("_eye")
						var line: Array = body.get("_brush_line")
						if line.is_empty():
							continue
						var frame := to_p * shield_node.global_transform
						var a := frame * (line[0] as Vector3)
						var b := frame * (line[1] as Vector3)
						var n := (frame * (line[2] as Vector3) - a).normalized()
						var room := 9.0
						for v: Vector3 in verts:
							var at: Vector3 = to_p * (shield_node.global_transform * v)
							for part: Array in shield_parts:
								room = minf(room, seg(at, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float))
						if room < 0.02:
							continue
						var shoulder := bones * sk.get_bone_global_pose(arms["Right"]["upper"]).origin
						var view := body.view_offset()
						var look := Basis(Vector3.UP, view.y) * Basis(Vector3.RIGHT, view.x)
						var to_mid := (look.inverse() * (a.lerp(b, 0.5) - eye)).normalized()
						var palm := bones * (sk.get_bone_global_pose(arms["Right"]["hand"]) * (arms["Right"]["palm"] as Vector3))
						var arm_room := 9.0
						var r_elbow := bones * sk.get_bone_global_pose(arms["Right"]["lower"]).origin
						var r_hand := bones * sk.get_bone_global_pose(arms["Right"]["hand"]).origin
						for k in 11:
							for part: Array in parts:
								arm_room = minf(arm_room, seg(r_elbow.lerp(r_hand, k / 10.0), bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float) - 0.04)
						found.append([rad_to_deg(n.angle_to(eye - a.lerp(b, 0.5))), "SEARCH face %3.0f deg off | arm %s face_to_eyes %.2f way %s | shield room %+.3f | shoulder to start %.2f end %.2f | line middle %+.0f right %+.0f up | palm misses %.3f | arm room %+.2f" % [rad_to_deg(n.angle_to(eye - a.lerp(b, 0.5))), Vector3(x, y, z), face, way, room, shoulder.distance_to(a), shoulder.distance_to(b), rad_to_deg(atan2(to_mid.x, -to_mid.z)), rad_to_deg(atan2(to_mid.y, -to_mid.z)), palm.distance_to(a + n * 0.02), arm_room]])
	body.brush_try = {}
	found.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	for row: Array in found.slice(0, 60):
		print(row[1])
	print("SEARCH %d kept" % found.size())

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
	# The same plays every run (each fidget draws its seed from the global random numbers).
	seed(int(OS.get_cmdline_user_args()[OS.get_cmdline_user_args().find("--seed") + 1]) if "--seed" in OS.get_cmdline_user_args() else 1)
	body.weapon_raised = false
	sk = body.get("_skeleton") as Skeleton3D
	var arms: Dictionary = body.get("_arms")
	var camera := player.get_node("Camera3D") as Camera3D
	var fov_v := deg_to_rad(camera.fov)
	var fov_h := 2.0 * atan(tan(fov_v * 0.5) * 16.0 / 9.0)
	var parts: Array = [["Hips", "Spine", 0.17], ["Spine", "UpperChest", 0.17], ["RightUpperLeg", "RightLowerLeg", 0.1], ["LeftUpperLeg", "LeftLowerLeg", 0.1]]
	var shield_parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["RightUpperLeg", "RightLowerLeg", 0.09], ["LeftUpperLeg", "LeftLowerLeg", 0.09]]
	var tips: Array = []
	for finger in ["Thumb", "Index", "Middle", "Ring", "Little"]:
		tips.append([sk.find_bone("Right%s%s" % [finger, "Proximal" if finger == "Thumb" else "Intermediate"]), sk.find_bone("Right%sDistal" % finger)])
	var shield_data: WeaponData = body.shield
	if "--no-outline" in OS.get_cmdline_user_args():
		body.brush_try = {"use_outline": false} # the strokes placed from the board's box, as before the outline
	if "--search" in OS.get_cmdline_user_args():
		_search(arms, shield_parts, parts, fov_h, fov_v)
		quit()
		return
	for with_shield: bool in [true, false]:
		if not with_shield:
			body.equip_shield(null)
		var shield_node := body.get("_shield_node") as Node3D
		var shield_verts: PackedVector3Array = []
		if shield_node:
			var mesh := shield_node.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
			var all: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for i in range(0, all.size(), maxi(all.size() / 400, 1)):
				shield_verts.append(all[i])
		for mirrored: bool in [false, true]:
			body.set("_idle_mirrored", mirrored)
			for i in 120:
				step()
			body.start_fidget(&"brush_off")
			var rows: Array[String] = []
			var frames := 0
			var palm_before := Vector3.INF
			var fastest := 0.0
			var fastest_at := 0.0
			var least_tip := 9.0
			var least_tip_row := ""
			var board_low: Array = [Vector3.INF, Vector3.INF, Vector3.INF]
			var board_high: Array = [-Vector3.INF, -Vector3.INF, -Vector3.INF]
			var board_face_first := Vector3.ZERO
			var board_turn := 0.0
			var elbow_before := Vector3.INF
			var elbow_before_next := Vector3.INF
			var inside_count := 0
			var inside_first := ""
			var inside_bins := {}
			var inside_deepest := 0.0
			var inside_deepest_row := ""
			var inside_what := {}
			var edge_past_end := INF
			var line_length := 0.0
			var farthest_along := 0.0
			var farthest_at := 0.0
			var jolts: Array = []
			var history: Array = [[], []]
			var least_room := 9.0
			var least_shield := 9.0
			var face_off := 0.0
			var line_report := ""
			var time := float((PlayerBody.FIDGETS[&"brush_off"] as Dictionary)["time"])
			while body.fidget_playing() == &"brush_off" and frames < 600:
				step()
				frames += 1
				elbow_before = elbow_before_next
				var through := float(frames) / 60.0 / time
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
				var speed := palm.distance_to(palm_before) * 60.0 if palm_before.is_finite() else 0.0
				if speed > fastest:
					fastest = speed
					fastest_at = through
				palm_before = palm
				var room := 9.0
				var r_elbow := bones * sk.get_bone_global_pose(arms["Right"]["lower"]).origin
				var r_hand := bones * sk.get_bone_global_pose(arms["Right"]["hand"]).origin
				for k in 11:
					var p := r_elbow.lerp(r_hand, k / 10.0)
					for part: Array in parts:
						room = minf(room, seg(p, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float) - 0.04)
				least_room = minf(least_room, room)
				var extra := ""
				var line: Array = body.get("_brush_line")
				if not line.is_empty():
					var frame: Transform3D
					if shield_node:
						frame = to_p * shield_node.global_transform
					else:
						frame = bones * sk.get_bone_global_pose(arms["Left"]["lower"])
					var a := frame * (line[0] as Vector3)
					var b := frame * (line[1] as Vector3)
					var n := (frame * (line[2] as Vector3) - a).normalized()
					if line_report == "":
						if shield_node:
							var low := shield_verts[0]
							var high := shield_verts[0]
							for v in shield_verts:
								low = low.min(v)
								high = high.max(v)
							var in_model := shield_node.global_transform.affine_inverse() * player.global_transform
							var shoulder := bones * sk.get_bone_global_pose(arms["Right"]["upper"]).origin
							line_report = "line in the model's axes %s -> %s, box %s .. %s; right shoulder to start %.2f, end %.2f m" % [in_model * a, in_model * b, low, high, shoulder.distance_to(a), shoulder.distance_to(b)]
							# Where the line, run on past its end, leaves the shield's real outline (body's
							# _shield_outline joined into edges), in metres past the end.
							var a_m := in_model * a
							var b_m := in_model * b
							a_m.z = 0.0
							b_m.z = 0.0
							var dir := (b_m - a_m).normalized()
							var side := Vector3(-dir.y, dir.x, 0.0)
							var outline: PackedVector2Array = body.get("_shield_outline")
							for i in outline.size():
								var p0 := Vector3(outline[i].x, outline[i].y, 0.0)
								var edge := Vector3(outline[(i + 1) % outline.size()].x, outline[(i + 1) % outline.size()].y, 0.0) - p0
								var den := dir.x * edge.y - dir.y * edge.x
								if absf(den) < 0.000001:
									continue
								var rel := p0 - b_m
								var s_at := (rel.x * dir.y - rel.y * dir.x) / den
								var t_at := (rel.x * edge.y - rel.y * edge.x) / den
								if s_at >= 0.0 and s_at <= 1.0 and t_at > -0.2:
									edge_past_end = minf(edge_past_end, t_at)
							line_length = a.distance_to(b)
						else:
							line_report = "line %.2f m long, %.2f m from the eyes" % [a.distance_to(b), eye.distance_to(a.lerp(b, 0.5))]
					var palm_up := (palm - a).dot(n)
					var fidget_at_now := float(body.get("_fidget_at"))
					var palm_along := (palm - a).dot(b - a) / (b - a).length_squared()
					if palm_along > farthest_along:
						farthest_along = palm_along
						farthest_at = fidget_at_now

					var tip_ups := ""
					var tip_least := 9.0
					for tip: Array in tips:
						var mid := bones * sk.get_bone_global_pose(tip[0]).origin
						var dist := bones * sk.get_bone_global_pose(tip[1]).origin
						var end := dist + (dist - mid).normalized() * 0.02
						var up := (end - a).dot(n)
						# Past the board's edge (the flick) there is nothing to go into.
						var over := true
						if shield_node:
							var in_model := shield_node.global_transform.affine_inverse() * (player.global_transform * end)
							over = in_model.x > -0.142 and in_model.x < 0.295 and in_model.y > -0.641 and in_model.y < 0.323
						if over:
							tip_least = minf(tip_least, up)
						tip_ups += " %+.3f" % up
					var fidget_at := float(body.get("_fidget_at"))
					var strokes: Vector4 = (PlayerBody.FIDGETS[&"brush_off"] as Dictionary)["brush"]["strokes"]
					var touching := fidget_at > strokes.x * time and fidget_at < strokes.y * time
					# Every other frame of the strokes: the palm's speed, how far along, how far off.
					if touching and with_shield and not mirrored and frames % 2 == 0:
						rows.append("STROKE  %.2f s  palm %.2f m/s  %.2f along  %+.3f off" % [fidget_at, speed, (palm - a).dot(b - a) / (b - a).length_squared(), (palm - a).dot(n)])
					# The palm's acceleration (m/s^2) through the strokes and the leave, for jolts.
					# Jerk (m/s^3: how suddenly the acceleration changes) of the palm and the right elbow,
					# from the third difference of their places a frame apart.
					# The palm's speed from the last stroke's end to the fidget's end, every other frame.
					if not mirrored and fidget_at > strokes.y * time - 0.7 and frames % 2 == 0:
						var fingers_way: Vector3 = (bones.basis * (sk.get_bone_global_pose(arms["Right"]["hand"]).basis * (arms["Right"]["fingers_out"] as Vector3))).normalized()
						var palm_face: Vector3 = (bones.basis * (sk.get_bone_global_pose(arms["Right"]["hand"]).basis * (arms["Right"]["palm_out"] as Vector3))).normalized()
						rows.append("LEAVE   %.2f s  palm %.2f m/s  elbow moved %.3f m  wrist bent %.0f deg, palm faces %s  %.2f along  %+.3f off" % [fidget_at, speed, r_elbow.distance_to(elbow_before) if elbow_before.is_finite() else 0.0, rad_to_deg(fingers_way.angle_to(r_hand - r_elbow)), palm_face.snapped(Vector3.ONE * 0.01), (palm - a).dot(b - a) / (b - a).length_squared(), (palm - a).dot(n)])
					if with_shield and not mirrored and fidget_at > strokes.x * time - 0.3:
						for which: int in 2:
							var point := palm if which == 0 else r_elbow
							var hist: Array = history[which]
							hist.append(point)
							if hist.size() > 4:
								hist.pop_front()
							if hist.size() == 4:
								var jerk := ((hist[3] as Vector3) - 3.0 * (hist[2] as Vector3) + 3.0 * (hist[1] as Vector3) - (hist[0] as Vector3)).length() * 216000.0
								jolts.append([jerk, "JERK  %s %.3f s  %.0f m/s^3  speed %.2f  %.2f along  %+.3f off" % ["palm " if which == 0 else "elbow", fidget_at, jerk, ((hist[3] as Vector3) - (hist[2] as Vector3)).length() * 60.0, (palm - a).dot(b - a) / (b - a).length_squared(), (palm - a).dot(n)]])
					if touching and tip_least < least_tip:
						least_tip = tip_least
						least_tip_row = "at %.3f: palm %+.3f off, %.2f along, tips%s" % [through, palm_up, palm_along, tip_ups]
					extra = " | palm %+.3f off, %.2f along | tips%s" % [palm_up, palm_along, tip_ups]
					if shield_node:
						face_off = rad_to_deg(n.angle_to(eye - a.lerp(b, 0.5)))
						extra += " | face %.0f deg off the eyes" % face_off
				if shield_node:
					var shield_room := 9.0
					var where := ""
					for v: Vector3 in shield_verts:
						var at: Vector3 = to_p * (shield_node.global_transform * v)
						for part: Array in shield_parts:
							var r := seg(at, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float)
							if r < shield_room:
								shield_room = r
								where = "model y %+.2f, %s" % [v.y, part[0]]
					least_shield = minf(least_shield, shield_room)
					var top := to_p * (shield_node.global_transform * Vector3(0.08, 0.32, 0.0)) - eye
					var tip := to_p * (shield_node.global_transform * Vector3(0.08, -0.64, 0.0)) - eye
					extra += " | shield-body %+.3f (%s), its top %s its tip %s from the eyes" % [shield_room, where, top, tip]
				elbow_before_next = r_elbow
				var fidget_at_all := float(body.get("_fidget_at"))
				# The board through the strokes, against the eyes: its middle, its top (by the strokes) and
				# its bottom tip -- how far each moves -- and how far it turns.
				if shield_node and fidget_at_all > PlayerBody.FIDGETS[&"brush_off"]["brush"]["strokes"].x * time and fidget_at_all < PlayerBody.FIDGETS[&"brush_off"]["brush"]["strokes"].y * time:
					var to_p_board := to_p * shield_node.global_transform
					var eye_now: Vector3 = body.get("_eye")
					for which in 3:
						var at_board: Vector3 = to_p_board * [Vector3(0.077, -0.16, 0.06), Vector3(0.15, 0.25, 0.06), Vector3(0.08, -0.6, 0.06)][which] - eye_now
						board_low[which] = (board_low[which] as Vector3).min(at_board)
						board_high[which] = (board_high[which] as Vector3).max(at_board)
					var face_now := (to_p_board.basis * Vector3(0, 0, 1)).normalized()
					if board_face_first == Vector3.ZERO:
						board_face_first = face_now
					board_turn = maxf(board_turn, rad_to_deg(board_face_first.angle_to(face_now)))
				# Any part of the right hand INSIDE the shield: the palm, the wrist and the five finger ends
				# within the board's real outline (body's _shield_outline) and between its back and face.
				if shield_node:
					var outline: PackedVector2Array = body.get("_shield_outline")
					var hand_points: Array = [palm, r_hand]
					for tip: Array in tips:
						hand_points.append(bones * sk.get_bone_global_pose(tip[1]).origin)
					var to_model := shield_node.global_transform.affine_inverse() * player.global_transform
					for k in hand_points.size():
						var m_at: Vector3 = to_model * (hand_points[k] as Vector3)
						# The palm point sits about 1.5 cm under the palm's skin and is aimed 1 cm under the face
						# while brushing: count it only deeper than 2.5 cm; finger ends get 5 mm of skin.
						if m_at.z < -0.03 or m_at.z > 0.063 - (0.025 if k == 0 else 0.005): # the board's back is at -0.03 (the model's -0.087 is the handle)
							continue
						if Geometry2D.is_point_in_polygon(Vector2(m_at.x, m_at.y), outline):
							inside_count += 1
							# How deep: under the face, and in from the outline's nearest edge.
							var in_from_edge := 9.0
							for e in outline.size():
								var q0 := outline[e]
								var q1 := outline[(e + 1) % outline.size()]
								in_from_edge = minf(in_from_edge, Geometry2D.get_closest_point_to_segment(Vector2(m_at.x, m_at.y), q0, q1).distance_to(Vector2(m_at.x, m_at.y)))
							var depth := minf(0.063 - m_at.z, in_from_edge)
							if depth > inside_deepest:
								inside_deepest = depth
								inside_deepest_row = "%.3f m (under the face %.3f, in from the edge %.3f) at %.2f s" % [depth, 0.063 - m_at.z, in_from_edge, float(body.get("_fidget_at"))]
							var bin := "%.1f" % float(body.get("_fidget_at"))
							inside_bins[bin] = int(inside_bins.get(bin, 0)) + 1
							inside_what[k] = int(inside_what.get(k, 0)) + 1
							if inside_first == "":
								inside_first = "%s at %.2f s" % [["palm", "wrist", "thumb", "forefinger", "middle finger", "ring finger", "little finger"][k], float(body.get("_fidget_at"))]
				if frames % 8 == 0:
					rows.append("BRUSH   %.2f dip %+.0f turn %+.0f | palm %+.0f right %+.0f up, %s | arm-body %+.2f%s" % [through, rad_to_deg(view.x), rad_to_deg(-view.y), off_h, off_v, "IN view" if seen else "out of view", room, extra])
			if shield_node and edge_past_end < INF:
				print("EDGE %s foot fwd: the line ends %.3f m before the real edge; the palm went at most %.3f m past the line's end, so %+.3f m past the edge, at %.2f s" % ["right" if mirrored else "left", edge_past_end, (farthest_along - 1.0) * line_length, (farthest_along - 1.0) * line_length - edge_past_end, farthest_at])
			# The leave's places as the body worked them out, from the eyes (the Player's axes: +X right,
			# +Y up, -Z ahead), with the board's middle and the palm where it ended.
			var eye_end: Vector3 = body.get("_eye")
			print("PLACES %s foot fwd: the last stroke ended %s, the arch's top %s, down through %s, the palm at the end %s%s" % ["right" if mirrored else "left", (body.get("_brush_leave") as Vector3) - eye_end, (body.get("_brush_top") as Vector3) - eye_end, (body.get("_brush_down") as Vector3) - eye_end, palm_before - eye_end, (", board middle " + str(player.global_transform.affine_inverse() * (shield_node.global_transform * (body.get("_shield_rim_middle") as Vector3)) - eye_end)) if shield_node else ""])
			if shield_node:
				print("BOARD %s foot fwd, through the strokes: its middle moves %s, its top %s, its bottom tip %s (m, the extent each way against the eyes); its face turns up to %.1f deg" % ["right" if mirrored else "left", (board_high[0] as Vector3) - (board_low[0] as Vector3), (board_high[1] as Vector3) - (board_low[1] as Vector3), (board_high[2] as Vector3) - (board_low[2] as Vector3), board_turn])
				print("INSIDE %s foot fwd: %d hand points inside the shield over the play%s" % ["right" if mirrored else "left", inside_count, (", first the " + inside_first) if inside_first != "" else ""])
				print("INSIDE   by time (s: points) %s; by part (0 palm, 1 wrist, 2-6 thumb..little) %s; deepest %s" % [inside_bins, inside_what, inside_deepest_row])
			print("BRUSH %s, %s foot fwd: %d frames, palm fastest %.2f m/s at %.2f, least fingertip height while brushing %+.3f m (%s), arm-body least %+.2f, shield-body least %+.3f | %s" % ["shield" if with_shield else "no shield", "right" if mirrored else "left", frames, fastest, fastest_at, least_tip, least_tip_row, least_room, least_shield, line_report])
			if not mirrored:
				for row in rows:
					print(row)
			jolts.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
			for jolt: Array in jolts.slice(0, 12):
				print(jolt[1])
			for i in 30:
				step()
	quit()
