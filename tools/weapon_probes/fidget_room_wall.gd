extends SceneTree
# PlayerBody._fidget_has_room against real collision: a ground slab, and a wall (or a tree trunk)
# placed round the Player. Per fidget (weapons as it needs them, standing; drawn ones crouched
# too): does it have room with nothing about, a wall 0.5 / 0.8 / 1.2 m ahead, 0.5 m behind,
# 0.5 m to the left / right, a trunk (0.3 m thick) 0.7 m ahead. Then: a fidget playing in the
# open is ended when a wall appears in front, and none starts by itself with the wall there.
var player: CharacterBody3D
var body: PlayerBody
var crouched := false

func _init() -> void:
	_run.call_deferred()

func step() -> void:
	body.set_motion(Vector3.ZERO, true, crouched, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

func _box(size: Vector3, at: Vector3) -> StaticBody3D:
	var solid := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	solid.add_child(shape)
	solid.position = at
	root.add_child(solid)
	return solid

func _trunk(at: Vector3) -> StaticBody3D:
	var solid := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.15
	cylinder.height = 4.0
	shape.shape = cylinder
	solid.add_child(shape)
	solid.position = at
	root.add_child(solid)
	return solid

func _run() -> void:
	_box(Vector3(20, 1, 20), Vector3(0, -0.5, 0)) # the ground, its top at the feet
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as CharacterBody3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await physics_frame
	body.fidgets_on = false
	(body.get("_lantern_light") as Light3D).visible = true
	# A wall is 3 m wide, 3 m tall, 0.2 m thick; "at" is its face nearest the Player.
	var places := {
		"open": func() -> Node: return null,
		"wall 0.5 ahead": func() -> Node: return _box(Vector3(3, 3, 0.2), Vector3(0, 1.5, -0.6)),
		"wall 0.8 ahead": func() -> Node: return _box(Vector3(3, 3, 0.2), Vector3(0, 1.5, -0.9)),
		"wall 1.2 ahead": func() -> Node: return _box(Vector3(3, 3, 0.2), Vector3(0, 1.5, -1.3)),
		"wall 0.5 behind": func() -> Node: return _box(Vector3(3, 3, 0.2), Vector3(0, 1.5, 0.6)),
		"wall 0.5 left": func() -> Node: return _box(Vector3(0.2, 3, 3), Vector3(-0.6, 1.5, 0)),
		"wall 0.5 right": func() -> Node: return _box(Vector3(0.2, 3, 3), Vector3(0.6, 1.5, 0)),
		"trunk 0.7 ahead": func() -> Node: return _trunk(Vector3(0, 2, -0.7)),
	}
	var line := "WALL %-28s" % "fidget"
	for place: String in places:
		line += " %-16s" % place
	print(line)
	for fidget: StringName in PlayerBody.FIDGETS:
		var drawn: bool = (PlayerBody.FIDGETS[fidget] as Dictionary).get("when", &"drawn") != &"sheathed"
		for crouch: bool in ([false, true] if drawn else [false]):
			crouched = crouch
			body.weapon_raised = drawn
			for i in 240:
				step()
			line = "WALL %-28s" % ("%s%s" % [fidget, " crouched" if crouch else ""])
			for place: String in places:
				var thing: Node = (places[place] as Callable).call()
				await physics_frame
				line += " %-16s" % ("room" if body.call("_fidget_has_room", fidget) else "BLOCKED")
				if thing:
					thing.free()
					await physics_frame
			print(line)
	# Playing in the open, then a wall 0.5 m ahead: ended?
	crouched = false
	body.weapon_raised = false
	for i in 240:
		step()
	body.start_fidget(&"brush_off")
	for i in 30:
		step()
	var wall := _box(Vector3(3, 3, 0.2), Vector3(0, 1.5, -0.6))
	await physics_frame
	var frames := 0
	while body.fidget_playing() != &"" and frames < 120:
		step()
		frames += 1
	print("WALL brush_off playing, a wall appears 0.5 m ahead: %s after %.2f s" % ["ended" if body.fidget_playing() == &"" else "STILL PLAYING", frames / 60.0])
	# With the wall there, a wait of 1 s: does any fidget start by itself in 6 s?
	body.fidgets_on = true
	body.fidget_after = 1.0
	body.fidget_after_random = 0.0
	var started: Array[StringName] = []
	for i in 360:
		step()
		if body.fidget_playing() != &"" and not started.has(body.fidget_playing()):
			started.append(body.fidget_playing())
	print("WALL sheathed, wall 0.5 m ahead, 6 s standing: started %s" % [started])
	wall.free()
	await physics_frame
	started.clear()
	for i in 360:
		step()
		if body.fidget_playing() != &"" and not started.has(body.fidget_playing()):
			started.append(body.fidget_playing())
	print("WALL sheathed, open, 6 s standing: started %s" % [started])
	quit()
