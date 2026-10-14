extends SceneTree
# Weapons up, the lantern held forward: for fist places under it, where the palm, wrist and knuckles actually end up and where the blade points, in the Player's axes from the lantern's middle. Tells whether the arm reaches under the lantern at all.
var player: Node3D
var body: PlayerBody

func _init() -> void:
	_run.call_deferred()

func step(delta: float) -> void:
	body.set_motion(Vector3.ZERO, true, false, false, delta)
	body.advance(delta, 0.0)

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	var apart: Dictionary = body.get("_apart")
	var arms: Dictionary = body.get("_arms")
	var sk := body.get("_skeleton") as Skeleton3D
	var lantern := body.get("_lantern") as Node3D
	var sword_mesh := (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	body.weapon_raised = true
	for i in 90:
		step(1.0 / 60.0)
	body.toggle_lantern()
	while (body.get("_toggle_at") as float) / body.toggle_time < 0.42:
		step(1.0 / 60.0)
	var to_p := player.global_transform.affine_inverse()
	var bob := body.get("_bob") as Vector3
	print("TRACE lantern body from %s to %s (Player's axes, from its middle)" % [(to_p * (lantern.global_transform * Vector3(0, -0.14, 0)) - bob).snappedf(0.01), (to_p * (lantern.global_transform * Vector3(0, -0.28, 0)) - bob).snappedf(0.01)])
	var shoulder_bone := sk.find_bone("RightUpperArm")
	for y: float in [0.05, 0.0, -0.05, -0.1, -0.15]:
		for z: float in [0.08, 0.0, -0.06]:
			for roll: float in [-90.0, 0.0, 90.0, 180.0]:
				body.toggle_armed_fist = Vector3(0.05, y, z)
				body.toggle_armed_roll = roll
				step(0.0001)
				var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
				var hand := right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))
				var palm := hand * (arms["Right"]["palm"] as Vector3)
				var knuckles := Vector3.ZERO
				for finger: String in ["Index", "Middle", "Ring", "Little"]:
					knuckles += (right.global_transform * right.get_bone_global_pose(right.find_bone("Right" + finger + "Proximal"))).origin / 4.0
				var shoulder := (right.global_transform * right.get_bone_global_pose(shoulder_bone)).origin
				print("TRACE asked %s roll %4.0f | palm %s wrist %s knuckles %s back of hand toward %s blade %s shoulder-palm %.2f" % [Vector3(0.05, y, z), roll, (to_p * palm - bob).snappedf(0.01), (to_p * hand.origin - bob).snappedf(0.01), (to_p * knuckles - bob).snappedf(0.01), (to_p.basis * (knuckles - palm)).normalized().snappedf(0.1), (to_p.basis * sword_mesh.global_transform.basis.y).normalized().snappedf(0.01), shoulder.distance_to(palm)])
	quit()
