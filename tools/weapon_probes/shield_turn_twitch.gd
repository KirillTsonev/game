extends SceneTree
# Standing still, weapons up, breathing: the view tipped down slowly from level to straight down,
# then held. Per stretch of the pitch, the shield keep-off's turn (swing / roll, deg) and move:
# the largest step a frame and how often the turn the search aims at jumps.
var player: Node3D
var body: PlayerBody

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.weapon_raised = true
	var dt := 1.0 / 60.0
	for f in 120:
		body.set_motion(Vector3.ZERO, true, false, false, dt)
		body.advance(dt, 0.0)
	var frames := 1500
	var last_turn := Vector2.ZERO
	var last_aim := Vector2.ZERO
	var last_push := Vector3.ZERO
	var stretch := {}
	for f in frames:
		var pitch := -1.5 * minf(float(f) / 600.0, 1.0)
		body.set_motion(Vector3.ZERO, true, false, false, dt)
		body.advance(dt, pitch)
		var turn := (body.get("_shield_turn") as Vector2) * (180.0 / PI)
		var aim := (body.get("_shield_turn_aim") as Vector2) * (180.0 / PI)
		var push := body.get("_shield_push") as Vector3
		var key := int(f / 60)
		if not stretch.has(key):
			stretch[key] = {"pitch": pitch, "turn_step": 0.0, "push_step": 0.0, "aim_jumps": 0, "aim_jump_most": 0.0, "turn": turn, "push": push.length()}
		var s: Dictionary = stretch[key]
		if f > 0:
			s["turn_step"] = maxf(s["turn_step"], (turn - last_turn).length())
			s["push_step"] = maxf(s["push_step"], (push - last_push).length())
			if (aim - last_aim).length() > 0.5:
				s["aim_jumps"] += 1
				s["aim_jump_most"] = maxf(s["aim_jump_most"], (aim - last_aim).length())
		last_turn = turn
		last_aim = aim
		last_push = push
	for key: int in stretch:
		var s: Dictionary = stretch[key]
		print("TWITCH pitch from %+.2f | turn %5.1f / %5.1f deg, move %.3f m | largest step a frame: turn %.2f deg, move %.4f m | aim jumps %d (up to %.1f deg)" % [s["pitch"], (s["turn"] as Vector2).x, (s["turn"] as Vector2).y, s["push"], s["turn_step"], s["push_step"], s["aim_jumps"], s["aim_jump_most"]])
	quit()
