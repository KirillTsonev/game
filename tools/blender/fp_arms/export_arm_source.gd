extends SceneTree
# Step 1 of the Blender arm pipeline (docs/blender_animation.md): writes the right arm as the game
# draws it apart (PlayerBody._apart) for tools/blender/fp_arms/build_scene.py --
#   animation_sources/fp_arms/arm_source.glb   the arm's meshes on the whole skeleton, in its rest
#                                              pose, placed in the EYES' space (the Player's axes,
#                                              origin at the eyes), no textures;
#   animation_sources/fp_arms/arm_source.json  the stance as the game holds it (every bone of the
#                                              arm from the eyes), the sword's socket in the hand,
#                                              the sword's place, the camera's field of view.
# The weapons up, standing still, view level, breathing off.
#
#   Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/blender/fp_arms/export_arm_source.gd
#
# Re-run it after changing the stance; then build_scene.py again.

const OUT_DIR := "res://animation_sources/fp_arms/"

func _init() -> void:
	_run.call_deferred()

static func _t(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z, t.basis.y.x, t.basis.y.y, t.basis.y.z, t.basis.z.x, t.basis.z.y, t.basis.z.z, t.origin.x, t.origin.y, t.origin.z]

static func _v(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

## The model's skin is bound in the source FBX's A-pose, while its rest is the humanoid T-pose
## ("fix silhouette"). Blender takes either the bind pose as the rest (then its rest is not the
## game's) or the rest with the mesh still in the A-pose (then the mesh deforms wrong). So the
## mesh is skinned into the rest pose here and bound there: bind = rest.
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

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	body.weapon_breathing = 0.0
	body.weapon_raised = true
	for i in 150:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	var to_player := player.global_transform.affine_inverse()
	var eye: Vector3 = body.get("_eye")
	var apart: Dictionary = body.get("_apart")
	var arm_model: Node3D = apart["Right"]["model"]
	var arm_skeleton: Skeleton3D = apart["Right"]["skeleton"]
	var chain: PackedInt32Array = apart["Right"]["chain"]
	# Skeleton space -> the eyes' space.
	var to_eyes := Transform3D(Basis.IDENTITY, -eye) * to_player * arm_skeleton.global_transform

	var bones := {}
	for bone in chain:
		bones[arm_skeleton.get_bone_name(bone)] = {"pose": _t(to_eyes * arm_skeleton.get_bone_global_pose(bone)), "rest": _t(to_eyes * arm_skeleton.get_bone_global_rest(bone))}
	var hand := arm_skeleton.find_bone("RightHand")
	var axes := WeaponHold.hand_axes(arm_skeleton, "Right")
	var sword := body.get("_weapon_node") as Node3D
	var camera := player.find_children("*", "Camera3D", true, false)[0] as Camera3D
	var data := {
		"eye": _v(eye),
		"skeleton_to_eyes": _t(to_eyes),
		"bones": bones,
		"socket": _t(body.get("_weapon_socket") as Transform3D),
		"sword": _t(Transform3D(Basis.IDENTITY, -eye) * to_player * sword.global_transform),
		"sword_scene": (body.weapon as WeaponData).scene.resource_path,
		"palm_out": _v(axes["palm_out"]), "fingers_out": _v(axes["fingers_out"]),
		"arm_length": body.call("_arm_length"),
		"fov": camera.fov,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var file := FileAccess.open(OUT_DIR + "arm_source.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "  "))
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
	wrapper.name = "ArmSource"
	root.add_child(wrapper)
	wrapper.add_child(copy)
	var copy_skeleton := copy.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	copy_skeleton.reset_bone_poses()
	for mesh: MeshInstance3D in copy.find_children("*", "MeshInstance3D", true, false):
		_bind_at_rest(mesh, copy_skeleton)
	var model_to_skeleton := arm_model.global_transform.affine_inverse() * arm_skeleton.global_transform
	copy.transform = to_eyes * model_to_skeleton.affine_inverse()
	var document := GLTFDocument.new()
	document.image_format = "None"
	var state := GLTFState.new()
	var error := document.append_from_scene(wrapper, state)
	if error == OK:
		error = document.write_to_filesystem(state, OUT_DIR + "arm_source.glb")
	var stance_hand: Array = bones["RightHand"]["pose"]
	print("FP_ARMS wrote %sarm_source.glb (error %d) and arm_source.json: %d bones, wrist from the eyes %s, arm %.3f m, fov %.1f" % [OUT_DIR, error, bones.size(), Vector3(stance_hand[9], stance_hand[10], stance_hand[11]).snappedf(0.001), data["arm_length"], camera.fov])
	quit()
