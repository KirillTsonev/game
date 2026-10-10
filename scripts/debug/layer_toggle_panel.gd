## DEBUG (dev only): checkboxes that show/hide whole scatter layers -- A/B their FPS cost, or look
## at one layer on its own. Opened with J via PerfDebug (scripts/perf_debug.gd). Built in code, no scene.
##
## - Grass: the GrassField node (hidden + its processing stopped, so the GPU cull pass stops too).
## - Trees / Rocks / Ferns + shrubs / Saplings / Flowers / Deadfall: the instancer nodes of that layer's mesh ids are hidden.
##   Their colliders go with them (TreeColliders / BoulderColliders / DeadfallColliders disabled;
##   saplings: their soft stem push is switched off),
##   so a hidden tree or boulder can be walked through.
## - Cliff meshes: the CliffDressing node (fault-line, knot and landmark cliffs; hidden + colliders
##   off). The terrain shaped around them stays.
## - Outcrop meshes (2026-10-05): the same for the outcrop container node.
## Mouse: same as the grass tuning panel -- J opens it with the cursor; click outside to look
## around again; J = cursor back, J again to close.
class_name LayerTogglePanel
extends CanvasLayer

## [key, checkbox title]
const LAYERS := [
	[&"grass", "Grass"],
	[&"trees", "Trees"],
	[&"rocks", "Rocks (boulders + scree)"],
	[&"understory", "Ferns / shrubs"],
	[&"saplings", "Saplings"],
	[&"flowers", "Flowers"],
	[&"deadfall", "Logs / stumps / branches"],
	[&"cliffs", "Cliff meshes"],
	[&"outcrops", "Outcrop meshes"],
]

var _shown: Dictionary = {} # layer key -> bool
var _status: Label

func _ready() -> void:
	layer = 50

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = 10.0
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	var title := Label.new()
	title.text = "LAYERS  (J: cursor / close)"
	title.add_theme_font_size_override("font_size", 13)
	box.add_child(title)
	for spec in LAYERS:
		_shown[spec[0]] = true
		var check := CheckBox.new()
		check.text = spec[1]
		check.button_pressed = true
		check.focus_mode = Control.FOCUS_NONE # keep WASD/arrows for the player
		check.add_theme_font_size_override("font_size", 12)
		check.toggled.connect(_on_layer_toggled.bind(spec[0]))
		box.add_child(check)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	box.add_child(_status)

## PerfDebug's J: closed -> open with cursor; open + mouse captured -> cursor back; open -> close.
func toggle() -> void:
	if not visible:
		visible = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_layer_toggled(on: bool, key: StringName) -> void:
	_shown[key] = on
	if key == &"grass":
		var field := get_tree().current_scene.get_node_or_null(GrassField.NODE_NAME) as Node3D
		if field:
			field.visible = on
			field.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	elif key == &"cliffs" or key == &"outcrops":
		# Their colliders are children of the meshes, so disabling the container removes those too.
		var container_name: String = CliffInstancer.CLIFF_DRESSING_NODE_NAME if key == &"cliffs" else TerrainOutcrops.OUTCROP_NODE_NAME
		var container := get_tree().current_scene.get_node_or_null(container_name) as Node3D
		if container:
			container.visible = on
			container.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	else:
		_set_meshes_shown(mesh_ids(key), on)
		var plants := get_tree().current_scene.get_node_or_null(PlantField.NODE_NAME) as PlantField
		if plants: # the layer's GPU-culled meshes are not instancer nodes
			plants.set_layer_shown(key, on)
		_set_colliders_enabled(key, on)
	_status.text = "%s %s -- %d FPS at toggle (let it settle)" % [key, "ON" if on else "OFF", Engine.get_frames_per_second()]
	print("[Layers] " + _status.text)

## Hides the instancer nodes of every layer that is switched off here, again. For after something
## made Terrain3D rebuild its nodes (PlantField.set_gpu_driven / set_reduced_shadows): rebuilt nodes come back visible.
func reapply_hidden() -> void:
	for key: StringName in _shown:
		if not _shown[key] and not mesh_ids(key).is_empty():
			_set_meshes_shown(mesh_ids(key), false)

## Terrain3D mesh ids of a layer (also read by the benchmark, scripts/debug/perf_bench.gd).
static func mesh_ids(key: StringName) -> Array[int]:
	match key:
		&"trees":
			return TreeScatter.TREE_MESH_IDS
		&"rocks":
			return RockScatter.ROCK_MESH_IDS + RockScatter.SCREE_MESH_IDS
		&"understory":
			return UnderstoryScatter.UNDERSTORY_MESH_IDS + PlantField.shadow_twin_ids(&"understory")
		&"saplings":
			return SaplingScatter.SAPLING_MESH_IDS
		&"flowers":
			return FlowerScatter.FLOWER_MESH_IDS
		&"deadfall":
			return DeadfallScatter.DEADFALL_MESH_IDS # stumps, logs, branches, sticks -- not mounds/cones
	return []

## The layer's collider container (one StaticBody3D per instance). A StaticBody3D whose processing
## is disabled is removed from the physics space (disable_mode = REMOVE, the default), so
## disabling the container takes every body under it out; INHERIT puts them back.
func _set_colliders_enabled(key: StringName, on: bool) -> void:
	var container_name := ""
	match key:
		&"trees":
			container_name = TreeScatter.TREE_COLLIDER_CONTAINER_NAME
		&"rocks":
			container_name = RockScatter.BOULDER_COLLIDER_CONTAINER_NAME
		&"deadfall":
			container_name = DeadfallScatter.COLLIDER_CONTAINER_NAME
		&"saplings":
			SaplingScatter.push_enabled = on # no colliders: the stems steer the player instead
	if container_name.is_empty():
		return # ferns / shrubs have no colliders
	var container := get_tree().current_scene.get_node_or_null(container_name)
	if container:
		container.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED

## The Terrain3D instancer names its nodes "MMI3D_C<cell x>_<cell z>_M<mesh id>_L<lod>".
## Returns (mesh id, lod), or (-1, -1) for any other node name.
static func parse_mmi_name(node_name: String) -> Vector2i:
	var parts := node_name.split("_")
	if parts.size() < 5 or parts[0] != "MMI3D":
		return Vector2i(-1, -1)
	return Vector2i(parts[3].substr(1).to_int(), parts[4].substr(1).to_int())

## Shows / hides the instancer's meshes of these ids, shadows included, through
## Terrain3DMeshAsset.enabled. Terrain3D 1.1 draws its instances straight on the RenderingServer:
## there are no MMI3D_* nodes to hide any more (hiding those was the way on 1.0.2, where switching
## `enabled` off closed the game a frame later with a stack overflow, 0xC00000FD). 1.1 queues the
## rebuild and does it once per frame.
func _set_meshes_shown(ids: Array[int], on: bool) -> void:
	set_mesh_assets_enabled(get_tree().current_scene.get_node_or_null("Terrain3D") as Terrain3D, ids, on)

## Also used by the benchmark (scripts/debug/perf_bench.gd).
static func set_mesh_assets_enabled(terrain: Terrain3D, ids: Array[int], on: bool) -> void:
	if terrain == null or terrain.get_assets() == null:
		return
	for id in ids:
		var asset: Terrain3DMeshAsset = terrain.get_assets().get_mesh_asset(id)
		if asset:
			asset.enabled = on
