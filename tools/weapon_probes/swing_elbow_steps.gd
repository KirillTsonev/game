extends SceneTree
# The drawn sword arm's elbow through swing_down_blender, per clip frame (1/30 s): its step (cm),
# the change of that step (a jolt shows as a large one), the elbow's bend and its way round the
# shoulder-wrist line (deg from the frame before), at leans -8.6 / 0 / 10 / 20 looking level and +20
# at 40 / 80 deg down. Prints the frames 14-26 and the worst of each run. `-- --off` plays with
# PlayerBody.swing_lean_clips off; `-- --no-hinge` with the swing's elbow hinge (_align_swing_elbow) off.
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/swing_elbow_steps.gd

const SWING := &"swing_down_blender"

func _init() -> void:
	_run.call_deferred()

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
	body.swing_lean_clips = not OS.get_cmdline_user_args().has("--off")
	if OS.get_cmdline_user_args().has("--no-hinge"):
		body.set("_stance_hinge", Vector3.ZERO)
	var step := func(pitch: float) -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, pitch)
		if OS.get_cmdline_user_args().has("--no-hinge"):
			body.set("_stance_hinge", Vector3.ZERO)
	var frames := int(round(float(PlayerBody.SWINGS[SWING]["time"]) * 30.0))
	for run: Array in [[-8.6, 0.0], [0.0, 0.0], [10.0, 0.0], [20.0, 0.0], [20.0, -0.698], [20.0, -1.4]]:
		for i in 150:
			step.call(run[1])
		body.debug_lean = run[0]
		body.call("_start_swing", SWING, false)
		var apart: Dictionary = body.get("_apart")
		var bones: Skeleton3D = apart["Right"]["skeleton"]
		var upper := bones.find_bone("RightUpperArm")
		var lower := bones.find_bone("RightLowerArm")
		var hand := bones.find_bone("RightHand")
		var elbows: Array[Vector3] = []
		var bends: Array[float] = []
		var ways: Array[Vector3] = []
		for f in frames:
			if f > 0:
				step.call(run[1])
				step.call(run[1])
			var to_eyes := Transform3D(Basis.IDENTITY, -body.eye_position()) * player.global_transform.affine_inverse() * bones.global_transform
			var s := to_eyes * bones.get_bone_global_pose(upper).origin
			var e := to_eyes * bones.get_bone_global_pose(lower).origin
			var w := to_eyes * bones.get_bone_global_pose(hand).origin
			elbows.append(e)
			bends.append(rad_to_deg((e - s).angle_to(w - e)))
			var axis := (w - s).normalized()
			ways.append(((e - s) - axis * (e - s).dot(axis)).normalized())
		var worst_change := 0.0
		var worst_at := 0
		var worst_way := 0.0
		var worst_way_at := 0
		var lines := PackedStringArray()
		for f in range(1, frames):
			var st := elbows[f].distance_to(elbows[f - 1])
			var change := ((elbows[f] - elbows[f - 1]) - (elbows[f - 1] - elbows[f - 2])).length() if f >= 2 else 0.0
			var way := rad_to_deg(ways[f].angle_to(ways[f - 1]))
			if change > worst_change:
				worst_change = change
				worst_at = f
			if way > worst_way:
				worst_way = way
				worst_way_at = f
			if f >= 14 and f <= 26:
				lines.append("%d: step %.1f, change %.1f, bend %.0f, way %.0f" % [f, st * 100.0, change * 100.0, bends[f], way])
		print("ELBOW lean %+5.1f pitch %.2f: largest change of step %.1f cm (frame %d), largest turn of its way %.0f deg (frame %d)" % [run[0], run[1], worst_change * 100.0, worst_at, worst_way, worst_way_at])
		print("ELBOW   " + " | ".join(lines))
		for i in 60:
			step.call(run[1])
	quit()
