extends SceneTree
# The shield arm for the Blender arm pipeline (docs/blender_animation.md, "The shield arm"): writes
# the LEFT arm as the game draws it apart (PlayerBody._apart) and the shield on it, for
# tools/blender/fp_arms/add_shield_arm.py --
#   animation_sources/fp_arms/shield_source.glb   the left arm's meshes on the whole skeleton, in
#                                                 its rest pose, in the EYES' space, no textures;
#   animation_sources/fp_arms/shield_source.json  the stance (every bone of the left arm from the
#                                                 eyes, rest and pose), the shield's place and
#                                                 scene, and "swings": the arm and the shield as
#                                                 the game moves them through each Blender swing
#                                                 (SWINGS entries with "rig"), every 1/30 s from
#                                                 the swing's start -- what the clip is keyed from.
# The weapons up, standing still, view level, breathing off, the swing unturned (no lean).
#
#   Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/blender/fp_arms/export_shield_source.gd

const OUT_DIR := "res://animation_sources/fp_arms/"
const ARM_BONES: Array[String] = ["LeftUpperArm", "LeftLowerArm", "LeftHand"]

func _init() -> void:
	_run.call_deferred()

static func _t(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z, t.basis.y.x, t.basis.y.y, t.basis.y.z, t.basis.z.x, t.basis.z.y, t.basis.z.z, t.origin.x, t.origin.y, t.origin.z]

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	body.weapon_breathing = 0.0
	body.shield_breathing = 0.0
	body.weapon_raised = true
	body.shield_arm_from_rig = false # the arm as the game moves it without a clip: the "shield" counterweight
	var step := func() -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	for i in 150:
		step.call()
	var to_player := player.global_transform.affine_inverse()
	var eye: Vector3 = body.get("_eye")
	var apart: Dictionary = body.get("_apart")
	var arm_model: Node3D = apart["Left"]["model"]
	var arm_skeleton: Skeleton3D = apart["Left"]["skeleton"]
	var chain: PackedInt32Array = apart["Left"]["chain"]
	var shield_node := body.get("_shield_node") as Node3D
	# From the eyes where they are NOW: the camera follows the head, which moves during a swing (up
	# to 1.6 cm in the down slash), and the game places the arms from the eyes every frame -- read
	# from the eyes before the swing, that move came into the clip and the game added it again.
	var to_eyes := func() -> Transform3D: return Transform3D(Basis.IDENTITY, -(body.get("_eye") as Vector3)) * to_player * arm_skeleton.global_transform
	var shield_in_eyes := func() -> Transform3D: return Transform3D(Basis.IDENTITY, -(body.get("_eye") as Vector3)) * to_player * shield_node.global_transform

	var bones := {}
	var at_eyes: Transform3D = to_eyes.call()
	for bone in chain:
		bones[arm_skeleton.get_bone_name(bone)] = {"pose": _t(at_eyes * arm_skeleton.get_bone_global_pose(bone)), "rest": _t(at_eyes * arm_skeleton.get_bone_global_rest(bone))}
	var data := {
		"eye": [eye.x, eye.y, eye.z],
		"skeleton_to_eyes": _t(at_eyes),
		"bones": bones,
		"shield": _t(shield_in_eyes.call()),
		"shield_scene": (body.shield as WeaponData).scene.resource_path,
		"fps": 30,
		"swings": {},
	}

	# Each Blender swing as the game plays it now: the left arm and the shield, every 1/30 s.
	for swing_name: StringName in PlayerBody.SWINGS:
		var swing: Dictionary = PlayerBody.SWINGS[swing_name]
		if not swing.has("rig"):
			continue
		body.call("_start_swing", swing_name, false)
		body.set("_swing_turn", 0.0)
		var frames: Array = []
		var count := int(round(float(swing["clip_to"]) * 30.0)) + 1
		for f in count:
			if f > 0:
				step.call()
				step.call()
			var now: Transform3D = to_eyes.call()
			var frame := {"shield": _t(shield_in_eyes.call())}
			for bone_name in ARM_BONES:
				frame[bone_name] = _t(now * arm_skeleton.get_bone_global_pose(arm_skeleton.find_bone(bone_name)))
			frames.append(frame)
		(data["swings"] as Dictionary)[String(swing["rig"])] = frames
		for i in 90:
			step.call()
		print("FP_ARMS shield arm through %s: %d frames" % [swing["rig"], frames.size()])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var file := FileAccess.open(OUT_DIR + "shield_source.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(data, " "))
	file.close()

	# The arm's copy at rest: only the arm's meshes, placed so that its skeleton sits in the eyes' space.
	var copy := arm_model.duplicate() as Node3D
	for node: Node in copy.find_children("*", "", true, false):
		if node is MeshInstance3D and not PlayerBody.ARM_APART_MESHES.has(String(node.name)):
			node.get_parent().remove_child(node)
			node.free()
		elif node is AnimationPlayer:
			node.get_parent().remove_child(node)
			node.free()
	for mesh: MeshInstance3D in copy.find_children("*", "MeshInstance3D", true, false):
		mesh.visible = true
	copy.visible = true
	var wrapper := Node3D.new()
	wrapper.name = "ShieldArmSource"
	root.add_child(wrapper)
	wrapper.add_child(copy)
	var copy_skeleton := copy.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	copy_skeleton.reset_bone_poses()
	for mesh: MeshInstance3D in copy.find_children("*", "MeshInstance3D", true, false):
		_bind_at_rest(mesh, copy_skeleton)
	var model_to_skeleton := arm_model.global_transform.affine_inverse() * arm_skeleton.global_transform
	copy.transform = at_eyes * model_to_skeleton.affine_inverse()
	var document := GLTFDocument.new()
	document.image_format = "None"
	var state := GLTFState.new()
	var error := document.append_from_scene(wrapper, state)
	if error == OK:
		error = document.write_to_filesystem(state, OUT_DIR + "shield_source.glb")
	var hand: Array = bones["LeftHand"]["pose"]
	print("FP_ARMS wrote %sshield_source.glb (error %d) and shield_source.json: %d bones, the left wrist from the eyes %s" % [OUT_DIR, error, bones.size(), Vector3(hand[9], hand[10], hand[11]).snappedf(0.001)])
	quit()

## As export_arm_source.gd's (the skin bound in the rest pose; see there).
static func _bind_at_rest(mesh_node: MeshInstance3D, skeleton: Skeleton3D) -> void:
	var skin := mesh_node.skin
	var source := mesh_node.mesh as ArrayMesh
	if skin == null or source == null:
		return
	var to_mesh := mesh_node.global_transform.affine_inverse() * skeleton.global_transform
	var bound: Array[Transform3D] = []
	var new_skin := Skin.new()
	for i in skin.get_bind_count():
		var bone := skin.get_bind_bone(i)
		if bone < 0:
			bone = skeleton.find_bone(skin.get_bind_name(i))
		var rest := to_mesh * skeleton.get_bone_global_rest(bone)
		bound.append(rest * skin.get_bind_pose(i))
		new_skin.add_named_bind(skeleton.get_bone_name(bone), rest.affine_inverse())
	var mesh := ArrayMesh.new()
	for s in source.get_surface_count():
		var arrays := source.surface_get_arrays(s)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
		var weights_of: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var per := weights_of.size() / maxi(points.size(), 1)
		for v in points.size():
			var m := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
			for k in per:
				var w := weights[v * per + k]
				if w > 0.0:
					var t := bound[weights_of[v * per + k]]
					m.basis.x += t.basis.x * w
					m.basis.y += t.basis.y * w
					m.basis.z += t.basis.z * w
					m.origin += t.origin * w
			points[v] = m * points[v]
			if not normals.is_empty():
				normals[v] = (m.basis * normals[v]).normalized()
			if not tangents.is_empty():
				var tangent := (m.basis * Vector3(tangents[v * 4], tangents[v * 4 + 1], tangents[v * 4 + 2])).normalized()
				tangents[v * 4] = tangent.x
				tangents[v * 4 + 1] = tangent.y
				tangents[v * 4 + 2] = tangent.z
		arrays[Mesh.ARRAY_VERTEX] = points
		if not normals.is_empty():
			arrays[Mesh.ARRAY_NORMAL] = normals
		if not tangents.is_empty():
			arrays[Mesh.ARRAY_TANGENT] = tangents
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if per == 8 else 0)
		mesh.surface_set_material(s, source.surface_get_material(s))
	mesh_node.mesh = mesh
	mesh_node.skin = new_skin
