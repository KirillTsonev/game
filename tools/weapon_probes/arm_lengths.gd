extends SceneTree
# Our right arm's lengths (the drawn-apart arm, weapons up): shoulder to elbow, elbow to wrist, wrist
# to the middle knuckle, wrist to the fist's middle (the grip), the stance's max_reach -- against the
# Stances mod's (tools/skyrim_reference/arm_lengths.py).
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
	body.fidgets_on = false
	body.weapon_raised = true
	for i in 150:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	var apart: Dictionary = body.get("_apart")
	var right: Skeleton3D = apart["Right"]["skeleton"]
	var at := func(bone: String) -> Vector3: return (right.global_transform * right.get_bone_global_pose(right.find_bone(bone))).origin
	var hand_pose := right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))
	var socket: Transform3D = body.get("_weapon_socket")
	var stance := body.get("_stance") as WeaponStance
	print("ARMS ours: upper %.3f  forearm %.3f  hand %.3f  wrist-grip %.3f  max_reach (shoulder-grip) %.3f  shoulder-grip now %.3f" % [
		(at.call("RightUpperArm") as Vector3).distance_to(at.call("RightLowerArm")), (at.call("RightLowerArm") as Vector3).distance_to(at.call("RightHand")),
		(at.call("RightHand") as Vector3).distance_to(at.call("RightMiddleProximal")), hand_pose.origin.distance_to(hand_pose * socket.origin),
		stance.max_reach, (at.call("RightUpperArm") as Vector3).distance_to(hand_pose * socket.origin)])
	quit()
