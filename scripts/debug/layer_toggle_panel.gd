## DEBUG (dev only): checkboxes that show/hide whole scatter layers -- A/B their FPS cost, or look
## at one layer on its own. Opened with J via PerfDebug (scripts/perf_debug.gd). Built in code, no scene.
##
## - Grass: the GrassField node (hidden + its processing stopped, so the GPU cull pass stops too).
## - Trees / Rocks / Ferns + shrubs / Deadfall: Terrain3DMeshAsset.enabled on that layer's mesh ids.
##   Their colliders go with them (TreeColliders / BoulderColliders / DeadfallColliders disabled),
##   so a hidden tree or boulder can be walked through.
## - Cliff meshes: the CliffDressing node (fault-line, knot and landmark cliffs; hidden + colliders
##   off). The terrain shaped around them stays. Outcrops are not included.
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
	[&"deadfall", "Logs / stumps / branches"],
	[&"cliffs", "Cliff meshes"],
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
	elif key == &"cliffs":
		# Their colliders are children of the meshes, so disabling the container removes those too.
		var cliffs := get_tree().current_scene.get_node_or_null(CliffInstancer.CLIFF_DRESSING_NODE_NAME) as Node3D
		if cliffs:
			cliffs.visible = on
			cliffs.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	else:
		_set_meshes_enabled(_mesh_ids(key), on)
		_set_colliders_enabled(key, on)
	_status.text = "%s %s -- %d FPS at toggle (let it settle)" % [key, "ON" if on else "OFF", Engine.get_frames_per_second()]
	print("[Layers] " + _status.text)

func _mesh_ids(key: StringName) -> Array[int]:
	match key:
		&"trees":
			return TreeScatter.TREE_MESH_IDS
		&"rocks":
			return RockScatter.ROCK_MESH_IDS + RockScatter.SCREE_MESH_IDS
		&"understory":
			return UnderstoryScatter.UNDERSTORY_MESH_IDS
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
	if container_name.is_empty():
		return # ferns / shrubs have no colliders
	var container := get_tree().current_scene.get_node_or_null(container_name)
	if container:
		container.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED

func _set_meshes_enabled(ids: Array[int], on: bool) -> void:
	var terrain := get_tree().current_scene.get_node_or_null("Terrain3D") as Terrain3D
	var assets: Terrain3DAssets = terrain.get_assets() if terrain else null
	if assets == null:
		return
	for id in ids:
		if id < assets.get_mesh_count():
			var asset: Terrain3DMeshAsset = assets.get_mesh_asset(id)
			if asset:
				asset.enabled = on
