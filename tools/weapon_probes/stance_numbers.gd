extends SceneTree
# The two stances in numbers, weapons up, left foot forward, looking level: from the eyes in the Player's axes (+X right, +Y up, -Z ahead) where the sword's grip, the shoulders and the shield are, which ways the blade, its edge and the shield's face point, and where they are in the picture (degrees right / up of its middle). For laying out attack and block keys.
var player: Node3D
var body: PlayerBody

func _init() -> void:
	_run.call_deferred()

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

static func in_view(v: Vector3) -> String:
	return "%+.0f / %+.0f deg" % [rad_to_deg(atan2(v.x, -v.z)), rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length()))]

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	body.weapon_raised = true
	for i in 180:
		step()
	var to_p := player.global_transform.affine_inverse()
	var eye: Vector3 = body.get("_eye")
	var stance := body.get("_stance") as WeaponStance
	var shield_stance := body.get("_shield_stance") as WeaponStance
	print("STANCE sword: hand %s shoulder %s elbow toward %s max reach %.3f" % [stance.hand_from_eyes().snappedf(0.001), stance.shoulder_from_eyes().snappedf(0.001), stance.elbow_toward().snappedf(0.01), stance.max_reach])
	print("STANCE shield: hand %s shoulder %s elbow toward %s max reach %.3f" % [shield_stance.hand_from_eyes().snappedf(0.001), shield_stance.shoulder_from_eyes().snappedf(0.001), shield_stance.elbow_toward().snappedf(0.01), shield_stance.max_reach])
	var sword := body.get("_weapon_node") as Node3D
	var mesh := sword.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var m := to_p * mesh.global_transform
	print("STANCE sword mesh box %s" % mesh.mesh.get_aabb())
	var grip := m * Vector3.ZERO - eye
	var tip := m * Vector3(0, 0.9, 0) - eye
	print("STANCE sword: mesh origin %s, tip %s (%s), blade %s, mesh +X %s, mesh +Z %s" % [grip.snappedf(0.001), tip.snappedf(0.001), in_view(tip), (m.basis.y).normalized().snappedf(0.01), m.basis.x.normalized().snappedf(0.01), m.basis.z.normalized().snappedf(0.01)])
	var held := (to_p * sword.global_transform)
	print("STANCE sword node: origin %s basis x %s y %s z %s" % [(held.origin - eye).snappedf(0.001), held.basis.x.normalized().snappedf(0.01), held.basis.y.normalized().snappedf(0.01), held.basis.z.normalized().snappedf(0.01)])
	var shield := body.get("_shield_node") as Node3D
	var smesh := shield.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var s := to_p * smesh.global_transform
	var middle_local: Vector3 = body.get("_shield_rim_middle")
	var face_local: Vector3 = body.get("_shield_face")
	var length_local: Vector3 = body.get("_shield_length")
	var middle := (to_p * shield.global_transform) * middle_local - eye
	print("STANCE shield mesh box %s; rim middle %s face %s length %s (its own axes)" % [smesh.mesh.get_aabb(), middle_local, face_local, length_local])
	print("STANCE shield: middle %s (%s), face %s, length %s" % [middle.snappedf(0.001), in_view(middle), ((to_p * shield.global_transform).basis * face_local).normalized().snappedf(0.01), ((to_p * shield.global_transform).basis * length_local).normalized().snappedf(0.01)])
	print("STANCE eye %s" % eye.snappedf(0.001))
	var apart: Dictionary = body.get("_apart")
	var right: Skeleton3D = apart["Right"]["skeleton"]
	var axes := WeaponHold.hand_axes(right, "Right")
	var hand_basis := (to_p * right.global_transform).basis * right.get_bone_global_pose(right.find_bone("RightHand")).basis
	print("STANCE right hand: palm %s fingers %s thumb side %s" % [(hand_basis * (axes["palm_out"] as Vector3)).normalized().snappedf(0.01), (hand_basis * (axes["fingers_out"] as Vector3)).normalized().snappedf(0.01), (hand_basis * (axes["thumb_side"] as Vector3)).normalized().snappedf(0.01)])
	var socket: Transform3D = body.get("_weapon_socket")
	var grip_in_p := hand_basis * socket.basis
	print("STANCE grip axes (the Player's): +X (edge) %s +Y (blade) %s" % [grip_in_p.x.normalized().snappedf(0.01), grip_in_p.y.normalized().snappedf(0.01)])
	var l_elbow := (to_p * right.global_transform * right.get_bone_global_pose(right.find_bone("RightLowerArm"))).origin - eye
	print("STANCE right elbow %s" % l_elbow.snappedf(0.001))
	quit()
