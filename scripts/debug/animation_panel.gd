## DEBUG (dev only): plays the body's animations in parts to look at them -- the fidgets for now
## (PlayerBody.FIDGETS). Opened with I via PerfDebug (scripts/perf_debug.gd). Built in code, no
## scene. Kirill, 2026-10-14: "break that animation into stages and each stage is triggered by a
## debug button ... a debug menu we could reuse for other animations as well".
##
## - The list: what the body offers (PlayerBody.debug_animations). Another kind of animation is
##   added there (name, length, stages) and to PlayerBody.debug_drive, not here.
## - A stage button plays that stage and stops at its end; "Play all" plays the whole. "Hold at
##   end" keeps the last pose after "Play all" (else the arm goes back to its stance).
## - The time slider scrubs: the pose is held where it is let go. Speed slows playing down.
## - "Release" hands the arm back (it eases to the stance). Closing the panel releases too.
## While the panel holds an animation, keys do not cancel it and no fidget starts by itself.
## The weapons are raised for a fidget. Mouse: as the J panel -- I opens it with the cursor;
## click outside to look around again; I = cursor back, I again to close.
class_name AnimationPanel
extends CanvasLayer

var _body: PlayerBody
var _animations: Array[Dictionary] = []
var _picked := 0
var _time := 0.0
var _until := -1.0 ## seconds at which playing stops; below 0 = not playing
var _from := 0.0 ## where a loop starts again
var _holding := false ## the panel holds the body's animation
var _whole := false ## playing all of it (for "hold at end")

var _list: OptionButton
var _stages: HBoxContainer
var _slider: HSlider
var _time_label: Label
var _speed: HSlider
var _speed_label: Label
var _loop: CheckBox
var _hold_end: CheckBox
var _status: Label

func _ready() -> void:
	layer = 50
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_top = 10.0
	panel.offset_right = -10.0
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size.x = 360.0
	margin.add_child(box)

	var title := Label.new()
	title.text = "ANIMATIONS  (I: cursor / close)"
	title.add_theme_font_size_override("font_size", 13)
	box.add_child(title)

	_list = OptionButton.new()
	_list.focus_mode = Control.FOCUS_NONE
	_list.item_selected.connect(_on_picked)
	box.add_child(_list)

	_stages = HBoxContainer.new()
	_stages.add_theme_constant_override("separation", 4)
	box.add_child(_stages)

	var time_row := HBoxContainer.new()
	box.add_child(time_row)
	_slider = HSlider.new()
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.step = 0.001
	_slider.value_changed.connect(_on_scrubbed)
	time_row.add_child(_slider)
	_time_label = Label.new()
	_time_label.custom_minimum_size.x = 90.0
	_time_label.add_theme_font_size_override("font_size", 12)
	time_row.add_child(_time_label)

	var speed_row := HBoxContainer.new()
	box.add_child(speed_row)
	var speed_title := Label.new()
	speed_title.text = "Speed"
	speed_title.add_theme_font_size_override("font_size", 12)
	speed_row.add_child(speed_title)
	_speed = HSlider.new()
	_speed.focus_mode = Control.FOCUS_NONE
	_speed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_speed.min_value = 0.1
	_speed.max_value = 1.0
	_speed.step = 0.05
	_speed.value = 1.0
	_speed.value_changed.connect(func(_v: float) -> void: _show_time())
	speed_row.add_child(_speed)
	_speed_label = Label.new()
	_speed_label.custom_minimum_size.x = 40.0
	_speed_label.add_theme_font_size_override("font_size", 12)
	speed_row.add_child(_speed_label)

	var checks := HBoxContainer.new()
	box.add_child(checks)
	_loop = _check(checks, "Loop")
	_hold_end = _check(checks, "Hold at end")
	var release := Button.new()
	release.text = "Release"
	release.focus_mode = Control.FOCUS_NONE
	release.add_theme_font_size_override("font_size", 12)
	release.pressed.connect(_release)
	checks.add_child(release)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

func _check(parent: Control, text: String) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.focus_mode = Control.FOCUS_NONE
	check.add_theme_font_size_override("font_size", 12)
	parent.add_child(check)
	return check

## PerfDebug's I: closed -> open with cursor; open + mouse captured -> cursor back; open -> close.
func toggle() -> void:
	if not visible:
		visible = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_refresh()
	elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_release()

## Finds the body and fills the list (again, as the body may have been made since).
func _refresh() -> void:
	var player := get_tree().current_scene.get_node_or_null("Player")
	_body = player.get_node_or_null("Body") as PlayerBody if player else null
	_animations = _body.debug_animations() if _body else []
	_list.clear()
	for animation in _animations:
		_list.add_item(String(animation["name"]))
	if _animations.is_empty():
		_status.text = "No body with animations found."
		return
	_picked = clampi(_picked, 0, _animations.size() - 1)
	_list.select(_picked)
	_on_picked(_picked)

func _on_picked(index: int) -> void:
	_picked = index
	_until = -1.0
	var animation := _animations[index]
	for child in _stages.get_children():
		child.queue_free()
	var stages: Array = animation["stages"]
	for i in stages.size():
		var stage: Array = stages[i]
		var button := Button.new()
		button.text = "%d %s" % [i + 1, stage[0]]
		button.tooltip_text = "%.2f - %.2f s" % [stage[1], stage[2]]
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 11)
		button.pressed.connect(_play.bind(float(stage[1]), float(stage[2]), false))
		_stages.add_child(button)
	var all := Button.new()
	all.text = "Play all"
	all.focus_mode = Control.FOCUS_NONE
	all.add_theme_font_size_override("font_size", 11)
	all.pressed.connect(_play.bind(0.0, float(animation["time"]), true))
	_stages.add_child(all)
	_slider.max_value = float(animation["time"])
	_time = 0.0
	_slider.set_value_no_signal(0.0)
	_show_time()

func _play(from: float, to: float, whole: bool) -> void:
	_from = from
	_time = from
	_until = to
	_whole = whole
	_drive()

func _on_scrubbed(value: float) -> void:
	_until = -1.0 # scrubbing stops playing; the pose is held where it is let go
	_time = value
	_drive()

func _release() -> void:
	_until = -1.0
	if _body and _holding:
		_body.debug_release()
	_holding = false
	_show_time()

func _drive() -> void:
	if _body == null or _animations.is_empty():
		return
	_body.debug_drive(_animations[_picked]["name"], _time)
	_holding = true
	_show_time()

func _process(delta: float) -> void:
	if _until < 0.0 or _body == null:
		return
	_time += delta * _speed.value
	if _time >= _until:
		if _loop.button_pressed:
			_time = _from
		else:
			_time = _until
			_until = -1.0
			if _whole and not _hold_end.button_pressed:
				_body.debug_drive(_animations[_picked]["name"], _time)
				_release()
				return
	_slider.set_value_no_signal(_time)
	_drive()

func _show_time() -> void:
	if _animations.is_empty():
		return
	_time_label.text = "%.2f / %.2f s" % [_time, float(_animations[_picked]["time"])]
	_speed_label.text = "%.2fx" % _speed.value
	var stage_now := ""
	for stage: Array in _animations[_picked]["stages"]:
		if _time >= float(stage[1]) - 0.0001 and _time <= float(stage[2]) + 0.0001:
			stage_now = stage[0]
	_status.text = ("%s -- %s" % ["playing" if _until >= 0.0 else ("holding" if _holding else "released"), stage_now])
