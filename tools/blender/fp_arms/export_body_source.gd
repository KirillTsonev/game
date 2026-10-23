extends SceneTree
# The body for the Blender arm scene, as a reference to animate against (docs/blender_animation.md,
# "The body as a reference"): writes the BODY as the game draws it during a Blender swing -- the
# torso, hips and legs; not the head and hood (shadows only: the camera is inside them) -- for
# tools/blender/fp_arms/add_body_reference.py:
#   animation_sources/fp_arms/body_source.glb   those meshes on the whole skeleton, in its rest
#                                               pose, in the EYES' space, no textures;
#   animation_sources/fp_arms/body_source.json  every bone's rest from the eyes, and "frames": every
#                                               bone's pose from the eyes as the game moves the body
#                                               through the swing (SWING), every 1/30 s from its start.
# The body's own arms are as the game leaves them, shrunk into the shoulders (the arms seen are the
# drawn copies, which the clip animates). The weapons up, standing still, view level, breathing off,
# the swing unturned (no lean), and WITHOUT the swing's chest turn (PlayerBody.swing_chest_from_rig
# off): add_body_reference.py turns the reference's spine by CTRL_chest live, as the game does, so
# editing the chest needs no new recording.
#
#   Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/blender/fp_arms/export_body_source.gd

const OUT_DIR := "res://animation_sources/fp_arms/"
const SWING := &"swing_down_blender"

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
	# Without the swing's chest turn: the Blender reference adds CTRL_chest's turn itself, live
	# (add_body_reference.py), so the torso follows the control as it is edited.
	body.swing_chest_from_rig = false
	var step := func() -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	for i in 150:
		step.call()
	var to_player := player.global_transform.affine_inverse()
	var model: Node3D = body.get("_model")
	var skeleton: Skeleton3D = body.get("_skeleton")
	# From the eyes where they are NOW (as export_shield_source.gd: the camera follows the head).
	var to_eyes := func() -> Transform3D: return Transform3D(Basis.IDENTITY, -(body.get("_eye") as Vector3)) * to_player * skeleton.global_transform
	var at_eyes: Transform3D = to_eyes.call()
	var rest := {}
	for bone in skeleton.get_bone_count():
		rest[skeleton.get_bone_name(bone)] = _t(at_eyes * skeleton.get_bone_global_rest(bone))

	var swing: Dictionary = PlayerBody.SWINGS[SWING]
	body.call("_start_swing", SWING, false)
	body.set("_swing_turn", 0.0)
	var frames: Array = []
	for f in int(round(float(swing["clip_to"]) * 30.0)) + 1:
		if f > 0:
			step.call()
			step.call()
		var now: Transform3D = to_eyes.call()
		var frame := {}
		for bone in skeleton.get_bone_count():
			frame[skeleton.get_bone_name(bone)] = _t(now * skeleton.get_bone_global_pose(bone))
		frames.append(frame)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var file := FileAccess.open(OUT_DIR + "body_source.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"rest": rest, "frames": frames, "swing": String(swing["rig"]), "fps": 30}, " "))
	file.close()

	# The body's meshes at rest: the ones the game draws (not those that only cast a shadow).
	var drawn := PackedStringArray()
	for caster: Array in body.get("_own_casters"):
		if caster[1] != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			drawn.append(String((caster[0] as Node).name))
	var copy := model.duplicate() as Node3D
	for node: Node in copy.find_children("*", "", true, false):
		if (node is MeshInstance3D and not drawn.has(String(node.name))) or node is AnimationPlayer:
			node.get_parent().remove_child(node)
			node.free()
	for mesh: MeshInstance3D in copy.find_children("*", "MeshInstance3D", true, false):
		mesh.visible = true
	copy.visible = true
	var wrapper := Node3D.new()
	wrapper.name = "BodySource"
	root.add_child(wrapper)
	wrapper.add_child(copy)
	var copy_skeleton := copy.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	copy_skeleton.reset_bone_poses()
	for mesh: MeshInstance3D in copy.find_children("*", "MeshInstance3D", true, false):
		_bind_at_rest(mesh, copy_skeleton)
	var model_to_skeleton := model.global_transform.affine_inverse() * skeleton.global_transform
	copy.transform = at_eyes * model_to_skeleton.affine_inverse()
	var document := GLTFDocument.new()
	document.image_format = "None"
	var state := GLTFState.new()
	var error := document.append_from_scene(wrapper, state)
	if error == OK:
		error = document.write_to_filesystem(state, OUT_DIR + "body_source.glb")
	print("FP_ARMS wrote %sbody_source.glb (error %d; meshes %s) and body_source.json: %d bones, %d frames of %s" % [OUT_DIR, error, ", ".join(drawn), rest.size(), frames.size(), swing["rig"]])
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
