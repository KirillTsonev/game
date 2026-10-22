extends SceneTree
# Prints what assets/animations/first_person/fp_arms.glb holds as Godot imported it: the
# skeleton's bones, the animations and their lengths and tracks.

func _init() -> void:
	var scene := (load("res://assets/animations/first_person/fp_arms.glb") as PackedScene).instantiate()
	var skeleton := scene.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var names: Array[String] = []
	for b in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(b))
	print("FP_RIG skeleton %s: %d bones: %s" % [scene.get_path_to(skeleton), names.size(), ", ".join(names)])
	var player := scene.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	for animation_name in player.get_animation_list():
		var animation := player.get_animation(animation_name)
		print("FP_RIG animation %s: %.3f s, %d tracks, first %s" % [animation_name, animation.length, animation.get_track_count(), animation.track_get_path(0) if animation.get_track_count() > 0 else ""])
	scene.free()
	quit()
