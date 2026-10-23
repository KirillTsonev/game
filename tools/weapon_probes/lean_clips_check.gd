extends SceneTree
# The leaned Blender clips (PlayerBody.swing_lean_clips, _lean_clips_frame; docs/blender_animation.md,
# "The leaned clips"): plays swing_down_blender at fixed leans and views and prints, per run, the
# sword tip's largest step and largest change of step between clip frames (1/30 s; a jump shows as
# both), the wrist put past the arm's reach (_swing_overreach), the shield's largest step, and where
# the tip is in the picture at the cut's middle. Runs: leans -20 / -8.6 / 0 / 10 / 20 looking level,
# 20 looking 40 and 80 deg down, and 20 started level then looked all the way down in 0.15 s from
# the wind-up's end (the live blend). `-- --off` plays them with swing_lean_clips off to compare.
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/lean_clips_check.gd

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
	var step := func(pitch: float) -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, pitch)
	var swing: Dictionary = PlayerBody.SWINGS[SWING]
	var frames := int(round(float(swing["time"]) * 30.0))
	var runs := [["level", -20.0, 0.0, 0.0], ["level", -8.6, 0.0, 0.0], ["level", 0.0, 0.0, 0.0], ["level", 10.0, 0.0, 0.0], ["level", 20.0, 0.0, 0.0],
			["40 down", 20.0, -0.698, -0.698], ["80 down", 20.0, -1.4, -1.4], ["level, then down at 11", 20.0, 0.0, -1.4]]
	for run: Array in runs:
		for i in 150:
			step.call(run[2])
		body.debug_lean = run[1]
		body.call("_start_swing", SWING, false)
		var weapon := body.get("_weapon_node") as Node3D
		var mesh := weapon.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		var box := mesh.get_aabb()
		var tip_local := Vector3(box.get_center().x, box.get_center().y, box.end.z if absf(box.end.z) > absf(box.position.z) else box.position.z)
		var shield := body.get("_shield_node") as Node3D
		var tips: Array[Vector3] = []
		var shields: Array[Vector3] = []
		var over := 0.0
		var share_at_end := 0.0
		var pitch: float = run[2]
		var cut_middle := ""
		for f in frames:
			if f > 0:
				for k in 2:
					if f >= 11 and pitch > run[3]:
						pitch = maxf(pitch - (1.4 / 9.0) / 2.0, run[3]) # 0.15 s to all the way down
					step.call(pitch)
			var to_player := player.global_transform.affine_inverse()
			var eye: Vector3 = body.eye_position()
			tips.append(to_player * (mesh.global_transform * tip_local) - eye)
			shields.append(to_player * shield.global_transform.origin - eye)
			over = maxf(over, body.get("_swing_overreach"))
			if f == 20:
				var camera := Transform3D(Basis.from_euler(Vector3(pitch, 0, 0) + body.view_offset()), body.eye_position())
				var seen := camera.affine_inverse() * (to_player * (mesh.global_transform * tip_local))
				cut_middle = "%.0f deg right, %.0f deg up" % [rad_to_deg(atan2(seen.x, -seen.z)), rad_to_deg(atan2(seen.y, -seen.z))]
			share_at_end = body.get("_swing_down_share")
		var worst_step := 0.0
		var worst_step_at := 0
		var worst_change := 0.0
		var worst_change_at := 0
		var worst_shield := 0.0
		var worst_shield_at := 0
		for f in range(1, tips.size()):
			var s := tips[f].distance_to(tips[f - 1])
			if s > worst_step:
				worst_step = s
				worst_step_at = f
			if f >= 2:
				var c := ((tips[f] - tips[f - 1]) - (tips[f - 1] - tips[f - 2])).length()
				if c > worst_change:
					worst_change = c
					worst_change_at = f
			var sh := shields[f].distance_to(shields[f - 1])
			if sh > worst_shield:
				worst_shield = sh
				worst_shield_at = f
		print("LEAN_CLIPS %-24s lean %+5.1f: tip step at most %.1f cm (frame %d), its change at most %.1f cm (frame %d); wrist past reach at most %.1f cm; shield step at most %.1f cm (frame %d); tip at frame 20 %s; down share %.2f" % [run[0], run[1],
				worst_step * 100.0, worst_step_at, worst_change * 100.0, worst_change_at, over * 100.0, worst_shield * 100.0, worst_shield_at, cut_middle, share_at_end])
		if OS.get_cmdline_user_args().has("--path"):
			print("LEAN_CLIPS   tip path (cm from the eyes): %s" % [tips.map(func(t: Vector3) -> Vector3: return (t * 100.0).round())])
		for i in 60:
			step.call(run[3])
	quit()
