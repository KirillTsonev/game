extends SceneTree
# The left arm against the TRUNK'S OWN MESH during the lantern's knob turn: the trunk's skinned vertices give its outline round its middle line (by height and direction), and points along the arm, with the arm's thickness, are tested against it.
const ARM_THICK := 0.055

var player: Node3D
var body: PlayerBody
var sk: Skeleton3D
var apart: Dictionary
var trunk_meshes: Array = [] # [mesh node, PackedVector3Array verts, bones, weights, per, bind bones, skin]
var trunk_bones := {}
var window := Vector2(0.25, 0.8)

func _init() -> void:
	_run.call_deferred()

func _outline() -> Dictionary:
	# Skinned trunk vertices -> the largest distance from the trunk's line per (height band, direction slot).
	var hips := sk.get_bone_global_pose(sk.find_bone("Hips")).origin
	var top := sk.get_bone_global_pose(sk.find_bone("Neck")).origin
	var axis := (top - hips).normalized()
	var ref := axis.cross(Vector3.RIGHT).normalized()
	var ref2 := axis.cross(ref)
	var grid := {}
	for entry: Array in trunk_meshes:
		var verts: PackedVector3Array = entry[1]
		var bones: PackedInt32Array = entry[2]
		var weights: PackedFloat32Array = entry[3]
		var per: int = entry[4]
		var bind_bone: Array = entry[5]
		var skin: Skin = entry[6]
		var mats: Array[Transform3D] = []
		for i in bind_bone.size():
			mats.append(sk.get_bone_global_pose(bind_bone[i]) * skin.get_bind_pose(i))
		for v in range(0, verts.size(), 2):
			var trunk_weight := 0.0
			var at := Vector3.ZERO
			for k in per:
				var w := weights[v * per + k]
				if w <= 0.0:
					continue
				var b := bones[v * per + k]
				if trunk_bones.has(bind_bone[b]):
					trunk_weight += w
				at += (mats[b] * verts[v]) * w
			if trunk_weight < 0.6:
				continue
			var rel := at - hips
			var height := rel.dot(axis)
			var radial := rel - axis * height
			var key := Vector2i(int(floor(height / 0.04)), int(fposmod(atan2(radial.dot(ref2), radial.dot(ref)), TAU) / TAU * 36.0) % 36)
			grid[key] = maxf(grid.get(key, 0.0), radial.length())
	return {"grid": grid, "hips": hips, "axis": axis, "ref": ref, "ref2": ref2}

func _depth(outline: Dictionary, point: Vector3) -> float:
	# How far a point of the arm (with its thickness) is inside the trunk's outline: positive = inside.
	var rel: Vector3 = point - (outline["hips"] as Vector3)
	var axis: Vector3 = outline["axis"]
	var height := rel.dot(axis)
	var radial := rel - axis * height
	var slot := int(fposmod(atan2(radial.dot(outline["ref2"] as Vector3), radial.dot(outline["ref"] as Vector3)), TAU) / TAU * 36.0) % 36
	var band := int(floor(height / 0.04))
	var grid: Dictionary = outline["grid"]
	var trunk := 0.0
	for db in [-1, 0, 1]:
		for ds in [-1, 0, 1]:
			trunk = maxf(trunk, grid.get(Vector2i(band + db, (slot + ds + 36) % 36), 0.0))
	if trunk <= 0.0:
		return -9.0
	return trunk + ARM_THICK - radial.length()

func _measure(weapons_up: bool, mirrored: bool) -> Array:
	body.weapon_raised = weapons_up
	body.set("_idle_mirrored", mirrored)
	for i in 70:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	body.toggle_lantern()
	var deepest := -9.0
	var where := ""
	var frames := 0
	while body.turning_lantern() and frames < 200:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
		frames += 1
		var through: float = (body.get("_toggle_at") as float) / body.toggle_time
		if not (frames % 6 == 0 and through > window.x and through < window.y):
			continue
		var outline := _outline()
		var left_sk: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
		var to_main := sk.global_transform.affine_inverse() * left_sk.global_transform
		var shoulder := to_main * left_sk.get_bone_global_pose(left_sk.find_bone("LeftUpperArm")).origin
		var elbow := to_main * left_sk.get_bone_global_pose(left_sk.find_bone("LeftLowerArm")).origin
		var wrist := to_main * left_sk.get_bone_global_pose(left_sk.find_bone("LeftHand")).origin
		var samples: Array = [["upper arm 45%", shoulder.lerp(elbow, 0.45)], ["upper arm 65%", shoulder.lerp(elbow, 0.65)], ["upper arm 85%", shoulder.lerp(elbow, 0.85)], ["elbow", elbow], ["forearm 25%", elbow.lerp(wrist, 0.25)], ["forearm 50%", elbow.lerp(wrist, 0.5)], ["forearm 75%", elbow.lerp(wrist, 0.75)], ["wrist", wrist]]
		for sample: Array in samples:
			var depth := _depth(outline, sample[1])
			if depth > deepest:
				deepest = depth
				where = "%s at %.0f%%" % [sample[0], through * 100.0]
	for i in 30:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	return [deepest, where]

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	sk = body.get("_skeleton") as Skeleton3D
	apart = body.get("_apart")
	# The trunk's bones: everything but the arms (from the collar bones), the legs and the head.
	var skip := {}
	for start: String in ["LeftShoulder", "RightShoulder", "LeftUpperLeg", "RightUpperLeg", "Head"]:
		var todo: Array[int] = [sk.find_bone(start)]
		while not todo.is_empty():
			var b: int = todo.pop_back()
			skip[b] = true
			for c in sk.get_bone_children(b):
				todo.append(c)
	for b in sk.get_bone_count():
		if not skip.has(b):
			trunk_bones[b] = true
	for mesh_node: MeshInstance3D in (body.get("_model") as Node3D).find_children("*", "MeshInstance3D", true, false):
		if mesh_node.skin == null or not mesh_node.visible:
			continue
		var bind_bone: Array = []
		for i in mesh_node.skin.get_bind_count():
			var bind_name := String(mesh_node.skin.get_bind_name(i))
			bind_bone.append(sk.find_bone(bind_name) if bind_name != "" else mesh_node.skin.get_bind_bone(i))
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			trunk_meshes.append([mesh_node, verts, bones, arrays[Mesh.ARRAY_WEIGHTS], bones.size() / maxi(verts.size(), 1), bind_bone, mesh_node.skin])
	# For scale: the same measure with the arm just hanging, no lantern action.
	for state: Array in [["standing, left foot fwd", false], ["standing, right foot fwd", true]]:
		body.weapon_raised = false
		body.set("_idle_mirrored", state[1])
		for i in 70:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
		var outline := _outline()
		var shoulder := sk.get_bone_global_pose(sk.find_bone("LeftUpperArm")).origin
		var elbow := sk.get_bone_global_pose(sk.find_bone("LeftLowerArm")).origin
		var wrist := sk.get_bone_global_pose(sk.find_bone("LeftHand")).origin
		print("MESHCLIP %s, arm hanging: upper arm 45%% %+.3f, 65%% %+.3f, 85%% %+.3f, elbow %+.3f, forearm 50%% %+.3f (positive = inside by this measure)" % [state[0], _depth(outline, shoulder.lerp(elbow, 0.45)), _depth(outline, shoulder.lerp(elbow, 0.65)), _depth(outline, shoulder.lerp(elbow, 0.85)), _depth(outline, elbow), _depth(outline, elbow.lerp(wrist, 0.5))])
	var settings: Array = []
	for arg in OS.get_cmdline_user_args():
		if arg == "--turnonly":
			window = Vector2(0.36, 0.66)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sweep"):
			for faces: float in [-28.0, -40.0]:
				for aside: float in [20.0, 40.0]:
					for out: Vector3 in [Vector3.ZERO, Vector3(-0.04, 0.0, -0.03), Vector3(-0.06, 0.0, -0.05), Vector3(-0.03, 0.0, -0.08)]:
						settings.append([faces, body.toggle_strapped_elbow, aside, out])
	if settings.is_empty():
		settings.append([0.0, body.toggle_strapped_elbow, 0.0, Vector3.ZERO])
	for setting: Array in settings:
		body.toggle_strapped_elbow = setting[1]
		var line := "MESHCLIP chest %.0f, swung %.0f left, shoulder out %s:" % [setting[0], setting[2], setting[3]]
		var worst := -9.0
		for state: Array in [["down L", false, false], ["down R", false, true], ["up L", true, false], ["up R", true, true]]:
			var got := _measure(state[1], state[2])
			worst = maxf(worst, got[0])
			line += " | %s: %s (%s)" % [state[0], ("%.3f m INSIDE" % got[0]) if (got[0] as float) > 0.0 else ("clear by %.3f" % -(got[0] as float)), got[1]]
		print(line, " || worst %+.3f" % worst)
	quit()
