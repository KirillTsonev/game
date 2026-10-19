extends SceneTree
# The space each fidget (PlayerBody.FIDGETS) sweeps through, for PlayerBody.FIDGET_ROOMS: every fidget, either
# foot forward, standing and (weapons drawn) crouched and looking 0.6 rad down and up, at 60 frames a second. Each frame the arms
# (shoulder to the finger tips), the held sword, the shield and the lantern are sampled, and a
# point counts once it is more than MOVED m from where it was as the fidget started -- what the
# fidget moves: not the sheathed sword, nor a shield swaying a few cm. Measured from the eyes in the
# Player's axes, and for the drawn fidgets turned back by the view's pitch the stance follows
# (_look_pitch * weapon_follows_view), as _fidget_has_room turns the box. Prints one box per
# fidget to paste into FIDGET_ROOMS, then (the drawn ones, looking 0.9 / 0.3 rad down and up) how
# far moved points come outside the box as FIDGET_ROOMS has it now. -- --only=<name>: one fidget.
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D
const MOVED := 0.12
const BONES := ["UpperArm", "LowerArm", "Hand", "ThumbDistal", "IndexDistal", "MiddleDistal", "LittleDistal"]

var crouched := false
var pitch := 0.0

func _init() -> void:
	_run.call_deferred()

func step() -> void:
	body.set_motion(Vector3.ZERO, true, crouched, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, pitch)

static func _sample(mesh: MeshInstance3D, count: int) -> PackedVector3Array:
	var all: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var some: PackedVector3Array = []
	for i in range(0, all.size(), maxi(all.size() / count, 1)):
		some.append(all[i])
	return some

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false # started by hand below
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	sk = body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var sword_mesh := (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_mesh := (body.get("_shield_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var sword_verts := _sample(sword_mesh, 300)
	var shield_verts := _sample(shield_mesh, 200)
	var lantern_meshes: Array = (body.get("_lantern") as Node3D).find_children("*", "MeshInstance3D", true, false)
	var lantern_verts := {}
	for mesh: MeshInstance3D in lantern_meshes:
		lantern_verts[mesh] = _sample(mesh, 100)
	(body.get("_lantern_light") as Light3D).visible = true
	# Every sampled point, in the order kept from frame to frame: from the eyes, the Player's axes,
	# turned back by the stance's share of the view's pitch for a drawn fidget.
	var points := func(drawn: bool) -> PackedVector3Array:
		var to_p := player.global_transform.affine_inverse()
		var back := Basis(Vector3.RIGHT, (body.get("_look_pitch") as float) * body.weapon_follows_view).inverse() if drawn else Basis.IDENTITY
		var eye: Vector3 = body.get("_eye")
		var out: PackedVector3Array = []
		var world: Array[Vector3] = []
		for side: String in ["Right", "Left"]:
			var bones: Skeleton3D = apart[side]["skeleton"] if (apart[side]["model"] as Node3D).visible else sk
			for bone: String in BONES:
				world.append((bones.global_transform * bones.get_bone_global_pose(bones.find_bone(side + bone))).origin)
		if drawn:
			for v in sword_verts:
				world.append(sword_mesh.global_transform * v)
		for v in shield_verts:
			world.append(shield_mesh.global_transform * v)
		for mesh: MeshInstance3D in lantern_meshes:
			for v: Vector3 in lantern_verts[mesh]:
				world.append(mesh.global_transform * v)
		for at in world:
			out.append(back * (to_p * at - eye))
		return out
	var rooms := {}
	for fidget: StringName in PlayerBody.FIDGETS:
		if only != "" and String(fidget) != only:
			continue
		var data: Dictionary = PlayerBody.FIDGETS[fidget]
		var drawn: bool = data.get("when", &"drawn") != &"sheathed"
		var box := AABB()
		var any := false
		# [crouched, the view's pitch]: the drawn ones also looking down and up (the shield does
		# not follow the view as the sword does: at 0 alone, looking 0.6 down it came 0.2 m outside).
		var ways: Array = [[false, 0.0], [false, -0.6], [false, 0.6], [true, 0.0]] if drawn else [[false, 0.0]]
		for way: Array in ways:
			for mirrored: bool in [false, true]:
				crouched = way[0]
				pitch = way[1]
				body.weapon_raised = drawn
				body.set("_idle_mirrored", mirrored)
				for i in 240:
					step()
				body.start_fidget(fidget)
				var start := PackedVector3Array()
				var frames := 0
				var moved := 0
				while body.fidget_playing() == fidget and frames < 1000:
					step()
					frames += 1
					var now: PackedVector3Array = points.call(drawn)
					if start.is_empty():
						start = now
						continue
					for i in now.size():
						if now[i].distance_to(start[i]) > MOVED:
							moved += 1
							if not any:
								box = AABB(now[i], Vector3.ZERO)
								any = true
							else:
								box = box.expand(now[i])
				print("ROOM %s, %s, pitch %+.1f, %s foot fwd: %d frames, %d moved samples" % [fidget, "crouched" if crouched else "standing", pitch, "right" if mirrored else "left", frames, moved])
				for i in 30:
					step()
		rooms[fidget] = box
		print("ROOM %s: from the eyes %s to %s, size %s" % [fidget, box.position.snappedf(0.01), box.end.snappedf(0.01), box.size.snappedf(0.01)])
	print("ROOM paste into FIDGET_ROOMS:")
	for fidget: StringName in rooms:
		var b: AABB = rooms[fidget]
		print("ROOM \t&\"%s\": AABB(Vector3(%.2f, %.2f, %.2f), Vector3(%.2f, %.2f, %.2f))," % [fidget, b.position.x, b.position.y, b.position.z, b.size.x, b.size.y, b.size.z])
	# The drawn ones looking down and up: how far outside the box as FIDGET_ROOMS has it now.
	for fidget: StringName in rooms:
		var data: Dictionary = PlayerBody.FIDGETS[fidget]
		if data.get("when", &"drawn") == &"sheathed" or not PlayerBody.FIDGET_ROOMS.has(fidget):
			continue
		var stored: AABB = PlayerBody.FIDGET_ROOMS[fidget]
		for look: float in [-0.9, -0.3, 0.3, 0.9]:
			crouched = false
			pitch = look
			body.weapon_raised = true
			body.set("_idle_mirrored", false)
			for i in 240:
				step()
			body.start_fidget(fidget)
			var start := PackedVector3Array()
			var worst := 0.0
			var frames := 0
			while body.fidget_playing() == fidget and frames < 1000:
				step()
				frames += 1
				var now: PackedVector3Array = points.call(true)
				if start.is_empty():
					start = now
					continue
				for i in now.size():
					if now[i].distance_to(start[i]) > MOVED:
						var p := now[i]
						var outside := Vector3(maxf(maxf(stored.position.x - p.x, p.x - stored.end.x), 0.0), maxf(maxf(stored.position.y - p.y, p.y - stored.end.y), 0.0), maxf(maxf(stored.position.z - p.z, p.z - stored.end.z), 0.0))
						worst = maxf(worst, outside.length())
			print("ROOM %s looking %+.1f rad: moved points at most %.3f m outside its room" % [fidget, look, worst])
	quit()
