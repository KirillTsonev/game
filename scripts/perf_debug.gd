extends Node
## DEBUG: dev-only key, not meant to ship.
##   T = tree probe: why can/can't a tree grow where the player stands.
##       Re-runs the tree placement checks at the player's feet via
##       WorldGenerator.debug_tree_probe() (terrain_gen.gd) and prints the report.

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.physical_keycode == KEY_T:
		_probe_tree_spot()

func _probe_tree_spot() -> void:
	var scene := get_tree().current_scene
	var player := scene.get_node_or_null("Player") as Node3D
	var gen := scene.get_node_or_null("WorldGenerator")
	if player == null or gen == null or not gen.has_method("debug_tree_probe"):
		print("[PerfDebug] tree probe: Player or WorldGenerator (with debug_tree_probe) not found")
		return
	print(gen.debug_tree_probe(player.global_position))
