## DEBUG (dev only): live tuning panel for GrassField's blade distance bands + widening curve.
## Opened with Y via PerfDebug (scripts/perf_debug.gd). Built in code, no scene.
##
## - Band sliders edit a working copy; "Apply bands" rebuilds the grass field with them
##   (GrassField.blade_bands + GrassField.spawn) -- takes a moment.
## - Widening sliders (blade width x 1 + min(pow(scale * dist, power), max)) apply LIVE.
## - Readout per band: blades per m^2, grid cells the GPU cull pass walks EVERY FRAME (the real cost:
##   (2 x end / spacing)^2), and blade widening at the band's far edge.
## - "Print values" prints GDScript you can paste over BLADE_BANDS / WIDEN_* in grass_field.gd.
## Mouse: the panel shows the cursor. Clicking outside the panel captures it again (player.gd),
## so you can look around; press Y to get the cursor back, Y again to close.
class_name GrassTuningPanel
extends CanvasLayer

const BAND_END_RANGE := [5.0, 250.0]
const SPACING_RANGE := [0.05, 8.0]

var _bands: Array = [] # working copy of GrassField.blade_bands
var _end_sliders: Array[HSlider] = []
var _spacing_sliders: Array[HSlider] = []
var _end_labels: Array[Label] = []
var _spacing_labels: Array[Label] = []
var _widen_sliders: Dictionary = {}
var _widen_labels: Dictionary = {}
var _wind_sliders: Dictionary = {}
var _wind_labels: Dictionary = {}
var _readout: Label
var _status: Label

func _ready() -> void:
	layer = 50
	_bands = GrassField.blade_bands.duplicate(true)

	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -470.0
	panel.offset_right = -10.0
	panel.offset_top = 10.0
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_add_label(box, "GRASS TUNING  (Y: cursor / close)", true)
	_add_label(box, "Distance bands -- change, then Apply bands", true)
	for k in _bands.size():
		var b: Dictionary = _bands[k]
		var end_name := "Draw distance (band %d end)" % k if k == _bands.size() - 1 else "Band %d end" % k
		var er := _add_slider_row(box, end_name, BAND_END_RANGE[0], BAND_END_RANGE[1], 1.0, float(b.outer))
		_end_sliders.append(er[0])
		_end_labels.append(er[1])
		er[0].value_changed.connect(_on_band_changed.bind(k, "outer"))
		var sr := _add_slider_row(box, "Band %d blade spacing" % k, SPACING_RANGE[0], SPACING_RANGE[1], 0.01, float(b.spacing))
		_spacing_sliders.append(sr[0])
		_spacing_labels.append(sr[1])
		sr[0].value_changed.connect(_on_band_changed.bind(k, "spacing"))

	box.add_child(HSeparator.new())
	_add_label(box, "Distance widening (live): width x 1 + min((scale x d)^power, max)", true)
	for spec in [["scale", 0.0, 0.1, 0.001, GrassField.widen_scale], ["power", 1.0, 6.0, 0.1, GrassField.widen_power], ["max", 1.0, 120.0, 1.0, GrassField.widen_max]]:
		var wr := _add_slider_row(box, "Widen " + spec[0], spec[1], spec[2], spec[3], spec[4])
		_widen_sliders[spec[0]] = wr[0]
		_widen_labels[spec[0]] = wr[1]
		wr[0].value_changed.connect(_on_widen_changed.bind(spec[0]))

	box.add_child(HSeparator.new())
	_add_label(box, "Wind (live): sway fades out between these distances", true)
	for spec in [["fade start", 0.0, 150.0, 1.0, GrassField.wind_fade_start], ["fade end", 1.0, 250.0, 1.0, GrassField.wind_fade_end]]:
		var wr := _add_slider_row(box, "Wind " + spec[0], spec[1], spec[2], spec[3], spec[4])
		_wind_sliders[spec[0]] = wr[0]
		_wind_labels[spec[0]] = wr[1]
		wr[0].value_changed.connect(_on_wind_changed.bind(spec[0]))

	box.add_child(HSeparator.new())
	_readout = Label.new()
	_readout.add_theme_font_size_override("font_size", 12)
	box.add_child(_readout)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for spec in [["Apply bands", _on_apply], ["Reset defaults", _on_reset], ["Print values", _on_print]]:
		var btn := Button.new()
		btn.text = spec[0]
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(spec[1])
		buttons.add_child(btn)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	box.add_child(_status)
	_refresh_labels()

## PerfDebug's Y: closed -> open with cursor; open + mouse captured -> cursor back; open -> close.
func toggle() -> void:
	if not visible:
		visible = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _add_label(parent: Control, text: String, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13 if bold else 12)
	parent.add_child(l)
	return l

## Returns [slider, value_label].
func _add_slider_row(parent: Control, title: String, lo: float, hi: float, step: float, value: float) -> Array:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var name_label := Label.new()
	name_label.text = title
	name_label.custom_minimum_size.x = 190.0
	name_label.add_theme_font_size_override("font_size", 12)
	row.add_child(name_label)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.focus_mode = Control.FOCUS_NONE # keep WASD/arrows for the player
	# Mouse wheel: handled here (and consumed, so it never reaches player.gd's click-to-capture).
	# Wheel = `step`, Shift = x10, Ctrl = x0.1 -- the slider itself allows the fine Ctrl steps.
	s.scrollable = false
	s.set_meta(&"wheel_step", step)
	s.step = step * 0.1
	s.gui_input.connect(_on_slider_wheel.bind(s))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.x = 170.0
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 60.0
	v.add_theme_font_size_override("font_size", 12)
	row.add_child(v)
	return [s, v]

func _on_slider_wheel(event: InputEvent, s: HSlider) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or (mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN):
		return
	s.accept_event() # both press + release, so nothing downstream sees the wheel
	if not mb.pressed:
		return
	var st: float = s.get_meta(&"wheel_step")
	if mb.shift_pressed:
		st *= 10.0
	elif mb.ctrl_pressed:
		st *= 0.1
	s.value += st if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -st

func _on_band_changed(value: float, k: int, key: String) -> void:
	_bands[k][key] = value
	_status.text = "Bands edited -- press Apply bands to rebuild the grass."
	_refresh_labels()

func _on_widen_changed(value: float, key: String) -> void:
	match key:
		"scale":
			GrassField.widen_scale = value
		"power":
			GrassField.widen_power = value
		"max":
			GrassField.widen_max = value
	var field := _field()
	if field:
		field.apply_widen()
	_refresh_labels()

func _on_wind_changed(value: float, key: String) -> void:
	if key == "fade start":
		GrassField.wind_fade_start = value
	else:
		GrassField.wind_fade_end = value
	var field := _field()
	if field:
		field.apply_widen() # also pushes the wind fade
	_refresh_labels()

func _on_apply() -> void:
	GrassField.blade_bands = _sanitized(_bands)
	_bands = GrassField.blade_bands.duplicate(true)
	_sync_sliders()
	GrassField.spawn(get_tree().current_scene)
	_status.text = "Rebuilt grass field with the new bands."
	print("[GrassTuning] applied bands: %s" % _bands_str(_bands))

func _on_reset() -> void:
	GrassField.reset_tuning()
	_bands = GrassField.blade_bands.duplicate(true)
	_sync_sliders()
	for key in _widen_sliders:
		_widen_sliders[key].set_value_no_signal({"scale": GrassField.widen_scale, "power": GrassField.widen_power, "max": GrassField.widen_max}[key])
	for key in _wind_sliders:
		_wind_sliders[key].set_value_no_signal(GrassField.wind_fade_start if key == "fade start" else GrassField.wind_fade_end)
	GrassField.spawn(get_tree().current_scene)
	_status.text = "Reset to defaults and rebuilt."
	_refresh_labels()

func _on_print() -> void:
	var lines := PackedStringArray()
	lines.append("[GrassTuning] paste into grass_field.gd:")
	lines.append("const BLADE_BANDS: Array[Dictionary] = [")
	for k in _bands.size():
		var b: Dictionary = _bands[k]
		var outer := "RADIUS" if k == _bands.size() - 1 else "%.1f" % float(b.outer)
		lines.append("\t{\"name\": \"%s\", \"inner\": %.1f, \"outer\": %s, \"band\": %.1f, \"spacing\": %.2f, \"mesh\": \"%s\"}," % [b.name, float(b.inner), outer, float(b.band), float(b.spacing), b.mesh])
	lines.append("]")
	lines.append("const RADIUS := %.1f" % float(_bands[-1].outer))
	lines.append("const WIDEN_SCALE := %.3f" % GrassField.widen_scale)
	lines.append("const WIDEN_POWER := %.2f" % GrassField.widen_power)
	lines.append("const WIDEN_MAX := %.1f" % GrassField.widen_max)
	lines.append("const WIND_FADE_START := %.1f" % GrassField.wind_fade_start)
	lines.append("const WIND_FADE_END := %.1f" % GrassField.wind_fade_end)
	print("\n".join(lines))
	_status.text = "Printed to the Output panel."

## Band ends strictly increasing (>= 2 m apart), each band starts where the previous ends,
## cross-fade width at most 40% of the band.
func _sanitized(bands: Array) -> Array:
	var out: Array = bands.duplicate(true)
	var prev := 0.0
	for k in out.size():
		var b: Dictionary = out[k]
		b.inner = prev
		b.outer = maxf(float(b.outer), prev + 2.0)
		var default_band: float = GrassField.BLADE_BANDS[mini(k, GrassField.BLADE_BANDS.size() - 1)].band
		b.band = minf(default_band, (float(b.outer) - prev) * 0.4)
		prev = float(b.outer)
	return out

func _sync_sliders() -> void:
	for k in _bands.size():
		_end_sliders[k].set_value_no_signal(float(_bands[k].outer))
		_spacing_sliders[k].set_value_no_signal(float(_bands[k].spacing))
	_refresh_labels()

func _refresh_labels() -> void:
	var lines := PackedStringArray()
	var total_cells := 0
	for k in _bands.size():
		var b: Dictionary = _bands[k]
		var outer := float(b.outer)
		var spacing := float(b.spacing)
		_end_labels[k].text = "%.1f m" % outer
		_spacing_labels[k].text = "%.3f m" % spacing
		var cells := int(pow(2.0 * outer / spacing, 2.0))
		total_cells += cells
		lines.append("band %d  %3.0f-%3.0f m   %6.2f blades/m2   cells %s   widen x%.1f" % [k, float(b.inner), outer, 1.0 / (spacing * spacing), _k(cells), GrassField.widen_at(outer)])
	lines.append("GPU cull cells per frame (all bands): %s" % _k(total_cells))
	_readout.text = "\n".join(lines)
	_widen_labels["scale"].text = "%.4f" % GrassField.widen_scale
	_widen_labels["power"].text = "%.2f" % GrassField.widen_power
	_widen_labels["max"].text = "%.1f" % GrassField.widen_max
	if not _wind_labels.is_empty():
		_wind_labels["fade start"].text = "%.0f m" % GrassField.wind_fade_start
		_wind_labels["fade end"].text = "%.0f m" % GrassField.wind_fade_end

func _k(v: int) -> String:
	return "%.1fM" % (v / 1000000.0) if v >= 1000000 else "%dk" % (v / 1000)

func _bands_str(bands: Array) -> String:
	var parts := PackedStringArray()
	for b in bands:
		parts.append("%.0f-%.0f@%.2f" % [float(b.inner), float(b.outer), float(b.spacing)])
	return ", ".join(parts)

func _field() -> GrassField:
	return get_tree().current_scene.get_node_or_null(GrassField.NODE_NAME) as GrassField
