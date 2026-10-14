extends SceneTree
# The body's side of the animation debug panel (scripts/debug/animation_panel.gd): what PlayerBody.debug_animations lists, that debug_drive holds a pose (the same time gives the same blade, a key does not cancel it, it does not end by itself) and that debug_release lets the arm back to the stance. And that the panel script itself loads and builds.
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
	var sword_mesh := (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	for animation in body.debug_animations():
		var text := "PANEL %s %.2f s:" % [animation["name"], animation["time"]]
		for stage: Array in animation["stages"]:
			text += " [%s %.2f-%.2f]" % stage
		print(text)
	# Held at 1.5 s of inspect, for two seconds, with a "key" in between.
	for i in 120: # the draw from the back first (weapon_draw_time)
		body.debug_drive(&"inspect", 0.0)
		step()
	body.debug_drive(&"inspect", 1.5)
	step()
	var blade := sword_mesh.global_transform.basis.y.normalized()
	var drift := 0.0
	for i in 120:
		if i == 30:
			body.interrupt_fidget()
		body.debug_drive(&"inspect", 1.5)
		step()
		drift = maxf(drift, rad_to_deg(sword_mesh.global_transform.basis.y.normalized().angle_to(blade)))
	print("PANEL held 2 s at 1.5 s (a key pressed half-way): still playing %s, blade moved at most %.2f deg" % [body.fidget_playing(), drift])
	# Past its end: still held.
	body.debug_drive(&"inspect", 4.0)
	for i in 60:
		step()
	print("PANEL held at its end for 1 s: still playing %s" % body.fidget_playing())
	body.debug_drive(&"inspect", 1.8) # released part way through
	step()
	body.debug_release()
	var frames := 0
	while body.fidget_playing() != &"" and frames < 120:
		step()
		frames += 1
	print("PANEL released: back to the stance in %.2f s" % (frames / 60.0))
	var panel := AnimationPanel.new()
	root.add_child(panel)
	await process_frame
	print("PANEL the panel script builds: %s" % (panel.get_child_count() > 0))
	quit()
