extends SceneTree
# Weapons drawn, the lantern action's end: frame by frame, how far the sword, the shield, each hand, the view and the eyes move, to find a jump. All in the Player's space, per 1/60 s.
func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	var body := player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	var sk := body.get("_skeleton") as Skeleton3D
	var apart: Dictionary = body.get("_apart")
	var sword := body.get("_weapon_node") as Node3D
	var shield := body.get("_shield_node") as Node3D
	var sword_mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var shield_mesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var sbox := sword_mesh.mesh.get_aabb()
	var axis := sbox.get_longest_axis_index()
	var tip := sbox.get_center()
	tip[axis] = sbox.end[axis] if absf(sbox.end[axis]) > absf(sbox.position[axis]) else sbox.position[axis]
	for mirrored: bool in [false]:
		body.weapon_raised = true
		body.set("_idle_mirrored", mirrored)
		for i in 100:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
		body.toggle_lantern()
		var names := ["sword tip", "sword grip", "shield middle", "right wrist", "left wrist", "right shoulder", "left shoulder", "eyes", "view (deg)", "shield push", "weapon bob"]
		var before := {}
		var steps := {} # name -> Array of step sizes per frame
		var marks: Array[String] = []
		for name: String in names:
			steps[name] = []
		var frame := 0
		var after_end := 0
		while after_end < 25 and frame < 300:
			body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
			body.advance(1.0 / 60.0, 0.0)
			frame += 1
			var running := body.turning_lantern()
			if not running:
				after_end += 1
			var to_p := player.global_transform.affine_inverse()
			var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
			var left: Skeleton3D = apart["Left"]["skeleton"] if (apart["Left"]["model"] as Node3D).visible else sk
			var view: Vector3 = body.view_offset()
			var now := {
				"sword tip": to_p * (sword_mesh.global_transform * tip), "sword grip": to_p * sword.global_position, "shield middle": to_p * (shield_mesh.global_transform * shield_mesh.mesh.get_aabb().get_center()),
				"right wrist": to_p * (right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand"))).origin, "left wrist": to_p * (left.global_transform * left.get_bone_global_pose(left.find_bone("LeftHand"))).origin,
				"right shoulder": to_p * (right.global_transform * right.get_bone_global_pose(right.find_bone("RightUpperArm"))).origin, "left shoulder": to_p * (left.global_transform * left.get_bone_global_pose(left.find_bone("LeftUpperArm"))).origin,
				"eyes": body.eye_position(), "view (deg)": Vector3(rad_to_deg(view.x), rad_to_deg(view.y), rad_to_deg(view.z)), "shield push": body.get("_shield_push"), "weapon bob": body.get("_bob_now"),
			}
			for name: String in names:
				(steps[name] as Array).append((now[name] as Vector3).distance_to(before[name]) if before.has(name) else 0.0)
			before = now
			marks.append("%.2f" % ((body.get("_toggle_at") as float) / body.toggle_time) if running else "end+%d" % after_end)
		# The last third of the action and what follows: every frame's step, and the largest change of step.
		var from := 0
		for i in marks.size():
			if marks[i] == "0.70" or marks[i] == "0.71":
				from = i
				break
		for name: String in names:
			var series: Array = steps[name]
			var worst := 0.0
			var worst_at := ""
			for i in range(maxi(from, 2), series.size()):
				var change := absf((series[i] as float) - (series[i - 1] as float))
				if change > worst:
					worst = change
					worst_at = marks[i]
			var line := ""
			for i in range(from, series.size(), 2):
				line += " %.3f" % (series[i] as float)
			print("JANK %-15s largest change of step between two frames %.4f at %s | steps every 2nd frame from 0.70:%s" % [name, worst, worst_at, line])
		print("JANK marks every 2nd frame: ", " ".join(PackedStringArray(range(from, marks.size(), 2).map(func(i: int) -> String: return marks[i]))))
	quit()
