extends SceneTree
# The left palm against the shield's mesh (its handle and straps included), weapons up: in the
# stance and through each shield fidget. The palm is taken as three lines from the wrist to the
# forefinger's, middle finger's and little finger's knuckles, each at the palm's surface (PALM
# toward the palm side), at the back of the hand (BACK) and in between (MID); a line crossing
# the mesh is counted per frame. And the least room of the palm's heel (the wrist's end of the
# palm surface) to the mesh's vertices.
const PALM := 0.013 ## half the hand's thickness (m)

var player: Node3D
var body: PlayerBody

func _init() -> void:
	_run.call_deferred()

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
	body.weapon_raised = true
	var apart: Dictionary = body.get("_apart")
	var arms: Dictionary = body.get("_arms")
	var palm_out: Vector3 = arms["Left"]["palm_out"]
	var shield_mesh := (body.get("_shield_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var tri := shield_mesh.mesh.generate_triangle_mesh()
	var verts: PackedVector3Array = shield_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var box := shield_mesh.mesh.get_aabb()
	var thin := box.size.min_axis_index()
	# Where the board itself is across the thickness: the share of vertices in each tenth.
	var layers: Array[int] = []
	layers.resize(10)
	layers.fill(0)
	for v in verts:
		layers[mini(int((v[thin] - box.position[thin]) / box.size[thin] * 10.0), 9)] += 1
	print("PALM the shield's thickness %.3f m; its vertices per tenth across it: %s" % [box.size[thin], layers])
	for i in 240:
		step()
	var runs: Array = [[&"", 120]]
	for fidget: StringName in PlayerBody.FIDGETS:
		if (PlayerBody.FIDGETS[fidget] as Dictionary).has("shield_keys"):
			runs.append([fidget, 0])
	for run: Array in runs:
		var fidget: StringName = run[0]
		if fidget != &"":
			body.start_fidget(fidget)
		var counts := {}
		var depths := {}
		var heel_least := 9.0
		var frames := 0
		while frames < 600 and ((fidget == &"" and frames < int(run[1])) or (fidget != &"" and body.fidget_playing() == fidget)):
			step()
			frames += 1
			var left: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else body.get("_skeleton") as Skeleton3D
			var to_board := shield_mesh.global_transform.affine_inverse() * left.global_transform
			var scale := to_board.basis.get_scale().x
			var hand := left.get_bone_global_pose(left.find_bone("LeftHand"))
			var palm_way := (hand.basis.orthonormalized() * palm_out).normalized()
			for layer: Array in [["PALM", 1.0], ["MID", 0.0], ["BACK", -1.0]]:
				var shift: Vector3 = palm_way * PALM * float(layer[1])
				for knuckle: String in ["LeftIndexProximal", "LeftMiddleProximal", "LeftLittleProximal"]:
					var a := to_board * (hand.origin + shift)
					var b := to_board * (left.get_bone_global_pose(left.find_bone(knuckle)).origin + shift)
					var hit := tri.intersect_segment(a, b)
					if not hit.is_empty():
						var key := "%s wrist-%s" % [layer[0], knuckle.trim_prefix("Left").trim_suffix("Proximal")]
						counts[key] = int(counts.get(key, 0)) + 1
						# Where across the shield's thickness the crossing is: 0 = the board's face
						# side of the box, 1 = its far side (where straps and handle stand off).
						var across := (((hit["position"] as Vector3)[thin] - box.position[thin]) / box.size[thin])
						depths[key] = "%s %.2f" % [depths.get(key, ""), across] if str(depths.get(key, "")).length() < 40 else depths[key]
			# The heel: the wrist's end of the palm surface.
			var heel := to_board * (hand.origin + palm_way * PALM)
			for v in verts:
				heel_least = minf(heel_least, heel.distance_to(v) / scale)
		print("PALM %s (%d frames): lines through the mesh %s; the heel's least room to the mesh's vertices %.3f m" % [fidget if fidget != &"" else "stance", frames, counts if not counts.is_empty() else "none", heel_least])
		for key: String in depths:
			print("PALM   %s crossings across the thickness:%s" % [key, depths[key]])
		for i in 30:
			step()
	quit()
