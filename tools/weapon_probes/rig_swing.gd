extends SceneTree
# The Blender pipeline's round trip (docs/blender_animation.md): the rig's swing_down (fp_arms.glb,
# read by PlayerBody._rig_sample) against the copied ArmClip it was built from
# (stances_high_attackright.json 0.27-0.82 s), frame by frame, before any edit in Blender. Prints
# how far apart shoulder, elbow and wrist are (cm), the hand's and the sword's turn (deg), the
# sword's place in the hand (cm) and the head's turn (deg). Then the tree's own checks: a restart
# when scrubbed back, and a chained travel.

const CLIP := "res://assets/animations/first_person/stances_high_attackright.json"
const FROM := 0.27
const WIND_UP := 0.2 # the rig's clip starts in the hold and reaches the ArmClip's window after this

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	var arm: Dictionary = (body.get("_arms") as Dictionary)["Right"]
	var clip := ArmClip.from_file(CLIP)
	var arm_length: float = body.call("_arm_length")
	var worst := {"shoulder": 0.0, "elbow": 0.0, "wrist": 0.0, "hand": 0.0, "sword": 0.0, "grip": 0.0, "view": 0.0}
	var t := 0.0
	while t <= 0.5331:
		var rig: Dictionary = body.call("_rig_sample", &"swing_down", WIND_UP + t, arm)
		if rig.is_empty():
			print("RIG_SWING the rig is missing")
			quit()
			return
		var c := clip.sample(FROM + t)
		if t < 0.001 or OS.get_cmdline_user_args().has("--raw"):
			print("RIG_SWING raw t %.3f: rig shoulder %s wrist %s; clip shoulder %s wrist %s" % [t, (rig["shoulder"] as Vector3).snappedf(0.001), (rig["wrist"] as Vector3).snappedf(0.001), (c["shoulder"] as Vector3).snappedf(0.001), (c["wrist"] as Vector3).snappedf(0.001)])
		var shoulder: Vector3 = c["shoulder"]
		var elbow: Vector3 = c["elbow"]
		var wrist: Vector3 = c["wrist"]
		var theirs := elbow.distance_to(shoulder) + wrist.distance_to(elbow)
		wrist = shoulder + (wrist - shoulder) * (arm_length / theirs)
		var row := {
			"shoulder": (rig["shoulder"] as Vector3).distance_to(shoulder) * 100.0,
			"elbow": (rig["elbow"] as Vector3).distance_to(elbow) * 100.0, # the clip's elbow is on a shorter arm: compare its way
			"wrist": (rig["wrist"] as Vector3).distance_to(wrist) * 100.0,
			"hand": rad_to_deg(((rig["hand"] as Basis).get_rotation_quaternion()).angle_to((c["hand"] as Basis).get_rotation_quaternion())),
			"sword": rad_to_deg(((rig["hand"] as Basis) * (rig["grip"] as Transform3D).basis).get_rotation_quaternion().angle_to(((c["hand"] as Basis) * (c["grip"] as Transform3D).basis).get_rotation_quaternion())),
			"grip": (rig["grip"] as Transform3D).origin.distance_to((c["grip"] as Transform3D).origin) * 100.0,
			"view": (rig["view"] as Vector3).distance_to(c["view"]),
		}
		var elbow_way_rig := ((rig["elbow"] as Vector3) - (rig["shoulder"] as Vector3)).normalized()
		var elbow_way_clip := (elbow - shoulder).normalized()
		row["elbow"] = rad_to_deg(elbow_way_rig.angle_to(elbow_way_clip))
		for k: String in worst:
			worst[k] = maxf(worst[k], row[k])
		print("RIG_SWING t %.3f: shoulder %.1f cm, elbow way %.1f deg, wrist %.1f cm, hand %.1f deg, sword %.1f deg, grip %.1f cm, view %.1f deg (rig view %s)" % [t, row["shoulder"], row["elbow"], row["wrist"], row["hand"], row["sword"], row["grip"], row["view"], (rig["view"] as Vector3).snappedf(0.1)])
		t += 1.0 / 30.0
	print("RIG_SWING worst: shoulder %.1f cm, elbow way %.1f deg, wrist %.1f cm, hand %.1f deg, sword %.1f deg, grip %.1f cm, view %.1f deg" % [worst["shoulder"], worst["elbow"], worst["wrist"], worst["hand"], worst["sword"], worst["grip"], worst["view"]])
	# Scrubbed back: the same frame again.
	var a: Dictionary = body.call("_rig_sample", &"swing_down", 0.3, arm)
	var b: Dictionary = body.call("_rig_sample", &"swing_down", 0.1, arm)
	var again: Dictionary = body.call("_rig_sample", &"swing_down", 0.3, arm)
	print("RIG_SWING scrub: 0.3 s read twice, wrist %.4f m apart (0.1 s in between: %.3f m away)" % [(a["wrist"] as Vector3).distance_to(again["wrist"]), (a["wrist"] as Vector3).distance_to(b["wrist"])])
	quit()
