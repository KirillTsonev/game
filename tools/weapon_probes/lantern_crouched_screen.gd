extends SceneTree
# Weapons up, crouched, the lantern action: where the fist and the blade's tip are ON SCREEN
# (1280 x 720, the camera's fov, the view's dip / turn / tilt as the Player applies them) every
# few frames, to see the path the player sees. -- --mirrored: the right foot forward.
var player: Node3D
var body: PlayerBody

func _init() -> void:
	_run.call_deferred()

func step(delta: float) -> void:
	body.set_motion(Vector3.ZERO, true, true, false, delta)
	body.advance(delta, 0.0)

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	var camera := player.get_node("Camera3D") as Camera3D
	var sk := body.get("_skeleton") as Skeleton3D
	var arms: Dictionary = body.get("_arms")
	var apart: Dictionary = body.get("_apart")
	var sword := body.get("_weapon_node") as Node3D
	var sword_mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	body.weapon_raised = true
	body.set("_idle_mirrored", OS.get_cmdline_user_args().has("--mirrored"))
	for i in 90:
		step(1.0 / 60.0)
	body.toggle_lantern()
	var focal := 360.0 / tan(deg_to_rad(camera.fov) * 0.5)
	var frame := 0
	var after := 0
	while after < 20:
		step(1.0 / 60.0)
		if not body.turning_lantern():
			after += 1
		var through: float = (body.get("_toggle_at") as float) / body.toggle_time if body.turning_lantern() else 1.0 + after / 90.0
		frame += 1
		if frame % 3 != 0:
			continue
		var cam := Transform3D(Basis.from_euler(body.view_offset()), body.eye_position())
		var to_cam := (player.global_transform * cam).affine_inverse()
		var right: Skeleton3D = apart["Right"]["skeleton"] if (apart["Right"]["model"] as Node3D).visible else sk
		var fist := right.global_transform * right.get_bone_global_pose(right.find_bone("RightHand")) * (arms["Right"]["palm"] as Vector3)
		var line := "SCREEN %.3f view %s" % [through, (body.view_offset() * 57.3).snappedf(1.0)]
		for named: Array in [["fist", fist], ["mid", sword_mesh.global_transform * Vector3(0, 0.45, 0)], ["tip", sword_mesh.global_transform * Vector3(0, 0.9, 0)]]:
			var c: Vector3 = to_cam * (named[1] as Vector3)
			if c.z < -0.01:
				line += "  %s (%4d, %4d)" % [named[0], int(640.0 + focal * c.x / -c.z), int(360.0 - focal * c.y / -c.z)]
			else:
				line += "  %s behind" % named[0]
		print(line)
	quit()
