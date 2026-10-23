extends SceneTree
# How the sword hand's fingers lie round the handle through the rig swings, against the idle hold
# (the grip the stance's fingers were posed for): per frame (60 a second) the handle's place in the
# hand against the stance's grip (degrees turned, cm moved) and, per finger, its tip's distance
# from the handle's middle line (cm; the handle is PlayerBody.weapon.grip_radius thick, so a tip
# lying on it is about that plus the finger's own half thickness). The tip is the last joint carried
# on by its own length. Kirill, 2026-10-23: in the swing "the palm is not actually gripping the
# hilt tightly".
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/grip_fingers.gd
# -- --every=<n>: print every n-th frame (default 6). -- --off=swing_fingers_from_rig: the clip's fingers
# (keyed round the handle in Blender, tools/blender/fp_arms/wrap_fingers.py) off, the stance's fist kept. Also prints the nearest any finger joint (or tip) comes to the handle's
# middle line in the swing: under the handle's radius plus about half a finger, a finger is in the handle.

func _init() -> void:
	_run.call_deferred()

var nearest_joint := INF
var nearest_name := ""

func _from_line(arm_skeleton: Skeleton3D, socket: Transform3D, point: Vector3) -> float:
	var hand := arm_skeleton.get_bone_global_pose(arm_skeleton.find_bone("RightHand"))
	var in_hand := hand.affine_inverse() * point
	var along := (in_hand - socket.origin).dot(socket.basis.y.normalized())
	return (in_hand - socket.origin - socket.basis.y.normalized() * along).length()

func _tips(arm_skeleton: Skeleton3D, socket: Transform3D) -> Array:
	var out := []
	for finger: String in WeaponHold.FINGERS:
		var last := arm_skeleton.find_bone("Right" + finger + "Distal")
		var before := arm_skeleton.get_bone_parent(last)
		var at := arm_skeleton.get_bone_global_pose(last).origin
		var tip := at + (at - arm_skeleton.get_bone_global_pose(before).origin) * 0.8
		out.append(_from_line(arm_skeleton, socket, tip))
		var first := arm_skeleton.get_bone_parent(before)
		for bone in [first, before, last]:
			var d := _from_line(arm_skeleton, socket, arm_skeleton.get_bone_global_pose(bone).origin)
			if d < nearest_joint:
				nearest_joint = d
				nearest_name = arm_skeleton.get_bone_name(bone)
		if out[-1] < nearest_joint:
			nearest_joint = out[-1]
			nearest_name = finger + " tip"
	return out

func _run() -> void:
	var every := 6
	var off := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--every="):
			every = int(arg.trim_prefix("--every="))
		elif arg == "--off=swing_fingers_from_rig":
			off = true
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
	body.debug_lean = -8.6
	if off:
		body.swing_fingers_from_rig = false
	var step := func() -> void:
		body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
		body.advance(1.0 / 60.0, 0.0)
	for i in 150:
		step.call()
	var arm_skeleton: Skeleton3D = (body.get("_apart") as Dictionary)["Right"]["skeleton"]
	var stance: Transform3D = body.get("_weapon_socket")
	var fmt := func(tips: Array) -> String:
		return "  ".join(tips.map(func(d: float) -> String: return "%4.1f" % (d * 100.0)))
	var idle: Array = _tips(arm_skeleton, body.call("_socket_now"))
	print("GRIP idle: the nearest finger joint or tip %.1f cm from the handle's middle line (%s)" % [nearest_joint * 100.0, nearest_name])
	nearest_joint = INF
	print("GRIP fingers: thumb, fore, middle, ring, little (tip from the handle's middle line, cm); handle radius %.1f cm" % (body.weapon.grip_radius * 100.0))
	print("GRIP idle hold:                %s" % fmt.call(idle))
	for swing_name: StringName in PlayerBody.SWINGS:
		if not (PlayerBody.SWINGS[swing_name] as Dictionary).has("rig"):
			continue
		body.call("_start_swing", swing_name, false)
		var worst := 0.0
		for f in int(ceil(float(PlayerBody.SWINGS[swing_name]["time"]) * 60.0)):
			step.call()
			var socket: Transform3D = body.call("_socket_now")
			var tips: Array = _tips(arm_skeleton, socket)
			for i in tips.size():
				worst = maxf(worst, absf(tips[i] - idle[i]))
			if f % every == 0:
				var turned := rad_to_deg((socket.basis.orthonormalized() * stance.basis.orthonormalized().inverse()).get_rotation_quaternion().get_angle())
				print("GRIP %s %3d: handle off the grip %4.1f deg %3.1f cm  %s" % [swing_name, f, turned, socket.origin.distance_to(stance.origin) * 100.0, fmt.call(tips)])
		print("GRIP %s: a tip at most %.1f cm off its idle distance; the nearest finger joint or tip %.1f cm from the handle's middle line (%s)" % [swing_name, worst * 100.0, nearest_joint * 100.0, nearest_name])
		for i in 90:
			step.call()
	quit()
