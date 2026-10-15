extends SceneTree
# The shield during the sword fidgets that let it sag ("shield_rest" in PlayerBody.FIDGETS), weapons up, either foot forward: how far the shield's middle drops below where the stance holds it (most, and when), its least room to the trunk and legs against the stance's own, and the sword's least room to the shield. The stance's own numbers are printed beside them as the "before".
var player: Node3D
var body: PlayerBody
var sk: Skeleton3D

func _init() -> void:
	_run.call_deferred()

static func seg(at: Vector3, a: Vector3, b: Vector3) -> float:
	var along := b - a
	return at.distance_to(a + along * clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0))

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

## The shield's least room to the trunk's middle line and the legs (vertices against capsules).
func shield_room(shield_verts: PackedVector3Array, shield_node: Node3D) -> float:
	var to_p := player.global_transform.affine_inverse()
	var bones := to_p * sk.global_transform
	var parts: Array = [["Hips", "Spine", 0.15], ["Spine", "UpperChest", 0.15], ["LeftUpperLeg", "LeftLowerLeg", 0.09], ["RightUpperLeg", "RightLowerLeg", 0.09]]
	var least := 9.0
	for v in shield_verts:
		var at: Vector3 = to_p * (shield_node.global_transform * v)
		for part: Array in parts:
			least = minf(least, seg(at, bones * sk.get_bone_global_pose(sk.find_bone(part[0])).origin, bones * sk.get_bone_global_pose(sk.find_bone(part[1])).origin) - (part[2] as float))
	return least

## The sword's least room to the shield: the blade's mesh points against the shield's.
func sword_to_shield(sword_verts: PackedVector3Array, sword_node: Node3D, shield_verts: PackedVector3Array, shield_node: Node3D) -> float:
	var least := 9.0
	for a in sword_verts:
		var at: Vector3 = sword_node.global_transform * a
		for b in shield_verts:
			least = minf(least, at.distance_to(shield_node.global_transform * b))
	return least

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	seed(1)
	body.fidgets_on = false
	body.weapon_raised = true
	sk = body.get("_skeleton") as Skeleton3D
	var shield_node := body.get("_shield_node") as Node3D
	var sword_node := body.get("_weapon_node") as Node3D
	var pick := func(node: Node3D, count: int) -> PackedVector3Array:
		var mesh := node.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		var all: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var in_node := node.global_transform.affine_inverse() * mesh.global_transform
		var some: PackedVector3Array = []
		for i in range(0, all.size(), maxi(all.size() / count, 1)):
			some.append(in_node * all[i])
		return some
	var shield_verts: PackedVector3Array = pick.call(shield_node, 250)
	var sword_verts: PackedVector3Array = pick.call(sword_node, 80)
	for fidget: StringName in [&"inspect", &"wrist_roll", &"shoulder_tap"]:
		for mirrored: bool in [false, true]:
			body.set("_idle_mirrored", mirrored)
			for i in 150:
				step()
			# The stance itself: the shield's middle against the eyes, and its room to the body.
			var eye: Vector3 = body.get("_eye")
			var to_p := player.global_transform.affine_inverse()
			var middle_rest: Vector3 = to_p * shield_node.global_transform.origin - eye
			var room_rest := shield_room(shield_verts, shield_node)
			body.start_fidget(fidget)
			var frames := 0
			var drop_most := 0.0
			var drop_at := 0.0
			var room_least := 9.0
			var room_at := 0.0
			var sword_least := 9.0
			var time := float((PlayerBody.FIDGETS[fidget] as Dictionary)["time"])
			while body.fidget_playing() == fidget and frames < 600:
				step()
				frames += 1
				var through := float(frames) / 60.0 / time
				eye = body.get("_eye")
				to_p = player.global_transform.affine_inverse()
				var middle: Vector3 = to_p * shield_node.global_transform.origin - eye
				if middle_rest.y - middle.y > drop_most:
					drop_most = middle_rest.y - middle.y
					drop_at = through
				if frames % 3 == 0:
					var room := shield_room(shield_verts, shield_node)
					if room < room_least:
						room_least = room
						room_at = through
					sword_least = minf(sword_least, sword_to_shield(sword_verts, sword_node, shield_verts, shield_node))
			print("SAG %s, %s foot fwd: the shield's middle at most %.3f m lower than in the stance (at %.2f); its room to the body %+.3f m at least (at %.2f; the stance %+.3f); the sword to the shield %.3f m at least" % [fidget, "right" if mirrored else "left", drop_most, drop_at, room_least, room_at, room_rest, sword_least])
			for i in 40:
				step()
	quit()
