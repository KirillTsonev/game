extends SceneTree
# Does the shield's keep-off from the body (PlayerBody.shield_body_clearance, _hold_shield) move the
# shield arm during the Blender swings whose clip carries it ("shield_from_rig")? Plays each such
# swing standing still at three pitches (level, half way down, all the way down) and prints, every
# clip frame (1/30 s), how far the keep-off has the arm moved (_shield_push, cm) and the forearm
# turned (_shield_turn, deg), then the largest of each and the frames where it is on at all.
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/shield_swing_clearance.gd
# `-- --quiet` leaves out the per-frame lines.

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
	var quiet := OS.get_cmdline_user_args().has("--quiet")
	var pitch := 0.0
	var step := func(at_pitch: float) -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, at_pitch)
	for down: float in [0.0, 0.7, 1.4]:
		pitch = -down
		for i in 150:
			step.call(pitch)
		for swing_name: StringName in PlayerBody.SWINGS:
			var swing: Dictionary = PlayerBody.SWINGS[swing_name]
			if not bool(swing.get("shield_from_rig", false)):
				continue
			body.call("_start_swing", swing_name, false)
			body.set("_swing_turn", 0.0)
			var frames := int(ceil(float(swing["time"]) * 30.0)) + 30 # the swing and a second after it
			var worst_push := 0.0
			var worst_push_at := -1
			var worst_turn := 0.0
			var worst_turn_at := -1
			var on: Array[int] = []
			for f in frames:
				if f > 0:
					step.call(pitch)
					step.call(pitch)
				var push: Vector3 = body.get("_shield_push")
				var turn: Vector2 = body.get("_shield_turn")
				var turned := rad_to_deg(absf(turn.x) + absf(turn.y))
				if push.length() > worst_push:
					worst_push = push.length()
					worst_push_at = f
				if turned > worst_turn:
					worst_turn = turned
					worst_turn_at = f
				if push.length() > 0.005 or turned > 1.0:
					on.append(f)
				if not quiet:
					print("SHIELD_CLEAR %s down %.1f rad frame %d (%s): push %.1f cm %s, turn %.1f deg" % [swing_name, down, f, "swing" if f / 30.0 <= float(swing["time"]) else "after", push.length() * 100.0, (push * 100.0).snappedf(0.1), turned])
			print("SHIELD_CLEAR %s down %.1f rad: push at most %.1f cm (frame %d), turn at most %.1f deg (frame %d); on (over 0.5 cm or 1 deg) on %d of %d frames %s" % [swing_name, down, worst_push * 100.0, worst_push_at, worst_turn, worst_turn_at, on.size(), frames, on])
			for i in 90:
				step.call(pitch)
	quit()
