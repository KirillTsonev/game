extends SceneTree
# The chest turn of the Blender swings (PlayerBody.swing_chest_from_rig; docs/blender_animation.md,
# "The chest"): plays each rig swing twice, the turn on and off, each on a freshly made Player (so
# both runs stand at the same moment of the idle), and prints per 1/30 s the body's heading (its
# shoulder line's, degrees left of square to the Player's line of sight), that line's tilt (+ = the right shoulder
# higher) and how far the camera's eyes and the sword's tip
# differ between the two runs (cm). The sword is the clip's either way; only the body turns.
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/chest_turn.gd

func _init() -> void:
	_run.call_deferred()

func _play(swing_name: StringName, chest_on: bool) -> Array:
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
	body.debug_lean = -8.6 # the clip as animated
	body.swing_chest_from_rig = chest_on
	var step := func() -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	for i in 150:
		step.call()
	var skeleton: Skeleton3D = body.get("_skeleton")
	var to_player := player.global_transform.affine_inverse()
	var swing: Dictionary = PlayerBody.SWINGS[swing_name]
	body.call("_start_swing", swing_name, false)
	body.set("_swing_turn", 0.0)
	var rows := []
	for f in int(ceil(float(swing["time"]) * 30.0)):
		step.call()
		step.call()
		var mesh := (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		var aabb := mesh.get_aabb()
		var tip := to_player * (mesh.global_transform * (aabb.position + Vector3(aabb.size.x * 0.5, aabb.size.y * 0.5, aabb.size.z)))
		# The body's shoulder line (its own upper arms' heads, which stay at its shoulders while the
		# drawn copies show the arms): + = the right (sword) shoulder higher.
		var right := to_player * skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("RightUpperArm")).origin
		var left := to_player * skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("LeftUpperArm")).origin
		var across := right - left
		# The heading from the shoulder line, not the chest bone's facing: the idle carries the chest
		# leaning forward, and a tilt then swings its facing sideways (read as 4-5 deg of extra turn).
		rows.append({"heading": rad_to_deg(atan2(-across.z, across.x)), "tilt": rad_to_deg(atan2(across.y, Vector2(across.x, across.z).length())), "eyes": body.eye_position(), "tip": tip})
	player.queue_free()
	await process_frame
	return rows

func _run() -> void:
	for swing_name: StringName in PlayerBody.SWINGS:
		var swing: Dictionary = PlayerBody.SWINGS[swing_name]
		if not swing.has("rig"):
			continue
		var on: Array = await _play(swing_name, true)
		var off: Array = await _play(swing_name, false)
		var worst_eyes := 0.0
		var worst_tip := 0.0
		for f in on.size():
			var a: Dictionary = on[f]
			var b: Dictionary = off[f]
			worst_eyes = maxf(worst_eyes, (a["eyes"] as Vector3).distance_to(b["eyes"]))
			worst_tip = maxf(worst_tip, (a["tip"] as Vector3).distance_to(b["tip"]))
			if f % 3 == 0:
				print("CHEST %s frame %2d: chest heading %+.1f deg (off: %+.1f), shoulder line %+.1f deg (off: %+.1f), eyes moved %.2f cm, tip moved %.2f cm" % [swing["rig"], f, a["heading"], b["heading"], a["tilt"], b["tilt"], (a["eyes"] as Vector3).distance_to(b["eyes"]) * 100.0, (a["tip"] as Vector3).distance_to(b["tip"]) * 100.0])
		print("CHEST %s: the eyes at most %.2f cm, the sword's tip at most %.2f cm from the run without the turn" % [swing["rig"], worst_eyes * 100.0, worst_tip * 100.0])
	quit()
