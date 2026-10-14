extends SceneTree
# Standing still, weapons up, both idles: how far the upper chest moves against the eyes, the breathing taken from it (_breath_now), its period, and how far the sword's grip and the shield move against the eyes, with the breathing on and off.
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
	var sword := body.get("_weapon_node") as Node3D
	var shield := body.get("_shield_node") as Node3D
	var sk := body.get("_skeleton") as Skeleton3D
	var chest_bone := sk.find_bone("UpperChest")
	var share_sword := body.weapon_breathing
	var share_shield := body.shield_breathing
	for setting: Array in [["on", share_sword, share_shield], ["off", 0.0, 0.0]]:
		body.weapon_breathing = setting[1]
		body.shield_breathing = setting[2]
		for mirrored: bool in [false, true]:
			body.weapon_raised = true
			body.set("_idle_mirrored", mirrored)
			for i in 240:
				body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
				body.advance(1.0 / 60.0, 0.0)
			var lows := {"chest": Vector3.INF, "breath": Vector3.INF, "sword": Vector3.INF, "shield": Vector3.INF}
			var highs := {"chest": -Vector3.INF, "breath": -Vector3.INF, "sword": -Vector3.INF, "shield": -Vector3.INF}
			var crossings := 0
			var last_y := 0.0
			var largest_step := 0.0
			var sword_before := Vector3.INF
			for i in 480:
				body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
				body.advance(1.0 / 60.0, 0.0)
				var to_p := player.global_transform.affine_inverse()
				var eye: Vector3 = body.get("_eye")
				var values := {
					"chest": (to_p * sk.global_transform * sk.get_bone_global_pose(chest_bone)).origin - eye,
					"breath": body.get("_breath_now") as Vector3,
					"sword": to_p * sword.global_transform.origin - eye,
					"shield": to_p * shield.global_transform.origin - eye,
				}
				for k: String in values:
					lows[k] = (lows[k] as Vector3).min(values[k])
					highs[k] = (highs[k] as Vector3).max(values[k])
				var y := (values["breath"] as Vector3).y
				if i > 0 and signf(y) != signf(last_y):
					crossings += 1
				last_y = y
				if sword_before.is_finite():
					largest_step = maxf(largest_step, (values["sword"] as Vector3).distance_to(sword_before))
				sword_before = values["sword"]
			var text := "BREATH %-3s %-11s clip %-12s" % [setting[0], "right fwd" if mirrored else "left fwd", (body.get("_animations") as AnimationPlayer).current_animation]
			for k: String in ["chest", "breath", "sword", "shield"]:
				text += " | %s moves %s cm" % [k, ((highs[k] as Vector3) - (lows[k] as Vector3) * 1.0).snappedf(0.001) * 100.0]
			text += " | about %.1f s a breath | sword's largest step in a frame %.1f mm" % [8.0 / maxf(crossings / 2.0, 0.5), largest_step * 1000.0]
			print(text)
	quit()
