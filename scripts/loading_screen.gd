extends CanvasLayer

## Autoload "LoadingScreen": a black full-screen cover with a progress bar and one line of text,
## shown from the boot scene (scripts/boot.gd) until WorldGenerator has built the world and drawn
## its first frames. Hidden unless begin() is called, so tool / test scenes are not covered.
##
##   LoadingScreen.begin()                 show at 0 %, stop 3D rendering (loading frames stay cheap)
##   LoadingScreen.set_progress(0.4, "..") bar position 0..1 + the text under it
##   LoadingScreen.show_world()            3D rendering back on, cover still up (first frames hitch)
##   LoadingScreen.end()                   hide
##
## Built in code so it needs no scene file. To restyle it, edit _build().

const BAR_SIZE := Vector2(420.0, 6.0)
const BAR_TRACK_COLOR := Color(1.0, 1.0, 1.0, 0.12)
const BAR_FILL_COLOR := Color(0.85, 0.85, 0.8, 1.0)
const TEXT_COLOR := Color(0.7, 0.7, 0.66, 1.0)
const NOTE_COLOR := Color(0.7, 0.7, 0.66, 0.6)
## Shown under the step text on a machine's first launch: the collision shapes and model scans are
## built and saved then (see TerrainUtil.cached_shape and the cliff cache), so the bar moves slower.
const FIRST_LAUNCH_NOTE := "First launch: preparing the world. This takes longer only once."

## Bar position 0..1 last set -- WorldGenerator continues from wherever the boot scene left it.
var progress := 0.0

var _bar: ProgressBar
var _label: Label
var _note: Label

func _ready() -> void:
	layer = 100 # above the pause menu and every debug overlay
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false

func is_active() -> bool:
	return visible

func begin() -> void:
	if visible:
		return
	visible = true
	get_tree().root.disable_3d = true
	set_progress(0.0, "")
	_note.text = FIRST_LAUNCH_NOTE if _is_first_launch() else ""

## True while this machine has no saved cliff collision shapes, the largest of the caches the world
## generator builds on its first run. Checked when the screen goes up, before that run fills it.
func _is_first_launch() -> bool:
	var cache_dir := CliffInstancer.CLIFF_TRIMESH_DISK_CACHE_DIR
	return not DirAccess.dir_exists_absolute(cache_dir) or DirAccess.get_files_at(cache_dir).is_empty()

func set_progress(fraction: float, text: String) -> void:
	progress = clampf(fraction, 0.0, 1.0)
	_bar.value = progress
	_label.text = text

func show_world() -> void:
	get_tree().root.disable_3d = false

func end() -> void:
	show_world()
	visible = false

## Esc must not open the pause menu (and pause the tree) under the cover.
func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()

func _build() -> void:
	var background := ColorRect.new()
	background.color = Color.BLACK
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	center.add_child(column)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = BAR_SIZE
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.show_percentage = false
	var track := StyleBoxFlat.new()
	track.bg_color = BAR_TRACK_COLOR
	var fill := StyleBoxFlat.new()
	fill.bg_color = BAR_FILL_COLOR
	_bar.add_theme_stylebox_override("background", track)
	_bar.add_theme_stylebox_override("fill", fill)
	column.add_child(_bar)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", TEXT_COLOR)
	column.add_child(_label)

	_note = Label.new()
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.add_theme_color_override("font_color", NOTE_COLOR)
	column.add_child(_note)
