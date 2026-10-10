## DEBUG (dev only): live tuning panel for GrassField's blade distance bands + widening curve.
## Opened with Y via PerfDebug (scripts/perf_debug.gd). Built in code, no scene.
##
## - Band sliders edit a working copy; "Apply bands" rebuilds the grass field with them
##   (GrassField.blade_bands + GrassField.spawn) -- takes a moment.
## - Short grass (2026-10-05): per short layer its end, fade-out width (the metres before the end
##   over which it thins to nothing) and blade spacing; applied by the same "Apply bands".
## - Widening sliders (blade width x 1 + min(pow(scale * dist, power), max)) apply LIVE.
## - Readout per band: blades per m^2, grid cells the GPU cull pass walks EVERY FRAME (the real cost:
##   (2 x end / spacing)^2), and blade widening at the band's far edge.
## - "Print values" prints GDScript you can paste over BLADE_BANDS / WIDEN_* in grass_field.gd.
## - Second panel (top left, 2026-10-02): blade colours + blend/ambient sliders (grass_blade.gdshader
##   uniforms, kept in GrassField.shader_overrides so they survive a rebuild) and the Grass ground
##   texture's tint (TerrainGroundPaint.GRASS_TINT). All live; "Print values" prints them too.
## Mouse: the panel shows the cursor. Clicking outside the panel captures it again (player.gd),
## so you can look around; press Y to get the cursor back, Y again to close.
class_name GrassTuningPanel
extends CanvasLayer

const BAND_END_RANGE := [5.0, 250.0]
const SPACING_RANGE := [0.05, 8.0]

const SHORT_END_RANGE := [5.0, 150.0]
const SHORT_FADE_RANGE := [0.5, 60.0]
const SHORT_SPACING_RANGE := [0.05, 1.0]
## Short-layer sliders: [dictionary key, row title, range, step, label format].
const SHORT_ROWS := [
	["outer", "end", SHORT_END_RANGE, 1.0, "%.1f m"], ["band", "fade-out width", SHORT_FADE_RANGE, 1.0, "%.1f m"],
	["spacing", "blade spacing", SHORT_SPACING_RANGE, 0.01, "%.3f m"],
]

var _bands: Array = [] # working copy of GrassField.blade_bands
var _short: Array = [] # working copy of GrassField.short_layers
var _short_sliders: Array[Dictionary] = [] # per layer: key -> HSlider
var _short_labels: Array[Dictionary] = [] # per layer: key -> Label
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
## grass_blade.gdshader uniforms shown in the colour panel: [uniform, row title] / [uniform, row title, max].
const COLOR_PARAMS := [
	[&"base_color", "Blade base"], [&"tip_color", "Blade tip"],
	[&"dry_base_color", "Dry blade base"], [&"dry_tip_color", "Dry blade tip"],
	[&"subsurface_scattering_color", "Backlit glow"],
]
const FLOAT_PARAMS := [
	[&"tip_blend", "Tip blend (tall)", 1.0], [&"short_tip_blend", "Tip blend (short)", 1.0],
	[&"backlight_floor", "Backlight floor", 0.5], [&"blade_ambient", "Blade ambient", 1.0],
	[&"blade_saturation", "Blade saturation", 1.0],
]
var _color_pickers: Dictionary = {}
var _float_sliders: Dictionary = {}
var _float_labels: Dictionary = {}
var _tint_picker: ColorPickerButton
var _tint_mult: HSlider
var _tint_mult_label: Label

func _ready() -> void:
	layer = 50
	_bands = GrassField.blade_bands.duplicate(true)
	_short = GrassField.short_layers.duplicate(true)

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
	_add_label(box, "Short grass in the gaps -- change, then Apply bands", true)
	for k in _short.size():
		var title := "Short %s" % ("far" if k == _short.size() - 1 else "near" if k == 0 else str(k))
		_short_sliders.append({})
		_short_labels.append({})
		for spec in SHORT_ROWS:
			var row := _add_slider_row(box, "%s %s" % [title, spec[1]], spec[2][0], spec[2][1], spec[3], float(_short[k][spec[0]]))
			_short_sliders[k][spec[0]] = row[0]
			_short_labels[k][spec[0]] = row[1]
			row[0].value_changed.connect(_on_short_changed.bind(k, spec[0]))

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
	_build_color_panel()
	_refresh_labels()

## Second panel, top left: blade colours + ground tint, all live.
func _build_color_panel() -> void:
	var panel := PanelContainer.new()
	panel.offset_left = 10.0
	panel.offset_top = 10.0
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_add_label(box, "GRASS COLOUR (live)", true)
	for spec in COLOR_PARAMS:
		var picker := _add_color_row(box, spec[1], _as_color(GrassField.blade_param(spec[0])), _blade_default(spec[0]))[0] as ColorPickerButton
		_color_pickers[spec[0]] = picker
		picker.color_changed.connect(_on_blade_param_changed.bind(spec[0]))
	for spec in FLOAT_PARAMS:
		var fr := _add_slider_row(box, spec[1], 0.0, spec[2], 0.01, float(GrassField.blade_param(spec[0])))
		_float_sliders[spec[0]] = fr[0]
		_float_labels[spec[0]] = fr[1]
		fr[0].value_changed.connect(_on_blade_param_changed.bind(spec[0]))

	box.add_child(HSeparator.new())
	_add_label(box, "Grass ground texture: tint x brightness (white, 1 = untouched)", true)
	var tint_row := _add_color_row(box, "Ground tint", TerrainGroundPaint.GRASS_TINT, TerrainGroundPaint.GRASS_TINT)
	_tint_picker = tint_row[0]
	_tint_picker.color_changed.connect(func(_c: Color) -> void: _apply_ground_tint())
	(tint_row[1] as Button).pressed.connect(func() -> void: _tint_mult.value = 1.0) # its reset also resets the brightness
	var tr := _add_slider_row(box, "Ground brightness", 0.25, 3.0, 0.05, 1.0)
	_tint_mult = tr[0]
	_tint_mult_label = tr[1]
	_tint_mult.value_changed.connect(func(_v: float) -> void: _apply_ground_tint())
	_add_label(box, "Patch shade (PATCH_SHADE) is baked at startup -- not live.")

## The shader's own default for a colour uniform (ignores the panel's override).
func _blade_default(param: StringName) -> Color:
	return _as_color(RenderingServer.shader_get_parameter_default(GrassField.BLADE_SHADER.get_rid(), param))

func _as_color(v: Variant) -> Color:
	return Color(v.x, v.y, v.z) if v is Vector3 else v

## Returns [picker, reset_button]; the button puts `default` back (and fires color_changed).
func _add_color_row(parent: Control, title: String, color: Color, default: Color) -> Array:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var name_label := Label.new()
	name_label.text = title
	name_label.custom_minimum_size.x = 190.0
	name_label.add_theme_font_size_override("font_size", 12)
	row.add_child(name_label)
	var picker := ColorPickerButton.new()
	picker.color = color
	picker.edit_alpha = false
	picker.focus_mode = Control.FOCUS_NONE
	picker.custom_minimum_size = Vector2(170.0, 22.0)
	row.add_child(picker)
	var reset := Button.new()
	reset.text = "Reset"
	reset.focus_mode = Control.FOCUS_NONE
	reset.add_theme_font_size_override("font_size", 12)
	reset.pressed.connect(func() -> void:
		picker.color = default
		picker.color_changed.emit(default))
	row.add_child(reset)
	return [picker, reset]

func _on_blade_param_changed(value: Variant, param: StringName) -> void:
	GrassField.shader_overrides[param] = value
	var field := _field()
	if field:
		field.apply_widen() # also pushes the shader overrides
	_refresh_labels()

func _ground_tint() -> Color:
	var c := _tint_picker.color
	var m := float(_tint_mult.value)
	return Color(c.r * m, c.g * m, c.b * m)

func _apply_ground_tint() -> void:
	var terrain := get_tree().current_scene.get_node_or_null("Terrain3D") as Terrain3D
	var asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(TerrainGroundPaint.GRASS_ID) if terrain and terrain.get_assets() else null
	if asset:
		asset.set_albedo_color(_ground_tint())
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

func _on_short_changed(value: float, k: int, key: String) -> void:
	_short[k][key] = value
	_status.text = "Short grass edited -- press Apply bands to rebuild the grass."
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
	GrassField.short_layers = _sanitized_short(_short)
	_short = GrassField.short_layers.duplicate(true)
	_sync_sliders()
	GrassField.spawn(get_tree().current_scene)
	_status.text = "Rebuilt grass field with the new bands."
	print("[GrassTuning] applied bands: %s | short: %s" % [_bands_str(_bands), _bands_str(_short)])

func _on_reset() -> void:
	GrassField.reset_tuning()
	_bands = GrassField.blade_bands.duplicate(true)
	_short = GrassField.short_layers.duplicate(true)
	_sync_sliders()
	for key in _widen_sliders:
		_widen_sliders[key].set_value_no_signal({"scale": GrassField.widen_scale, "power": GrassField.widen_power, "max": GrassField.widen_max}[key])
	for key in _wind_sliders:
		_wind_sliders[key].set_value_no_signal(GrassField.wind_fade_start if key == "fade start" else GrassField.wind_fade_end)
	for spec in COLOR_PARAMS:
		_color_pickers[spec[0]].color = _blade_default(spec[0])
	for spec in FLOAT_PARAMS:
		_float_sliders[spec[0]].set_value_no_signal(float(GrassField.blade_param(spec[0])))
	_tint_picker.color = TerrainGroundPaint.GRASS_TINT
	_tint_mult.set_value_no_signal(1.0)
	_apply_ground_tint()
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
	lines.append("const SHORT_LAYERS: Array[Dictionary] = [")
	for s: Dictionary in _short:
		lines.append("\t{\"name\": \"%s\", \"kind\": %d, \"inner\": %.1f, \"outer\": %.1f, \"band\": %.1f, \"spacing\": %.2f}," % [s.name, int(s.kind), float(s.inner), float(s.outer), float(s.band), float(s.spacing)])
	lines.append("]")
	lines.append("const WIDEN_SCALE := %.3f" % GrassField.widen_scale)
	lines.append("const WIDEN_POWER := %.2f" % GrassField.widen_power)
	lines.append("const WIDEN_MAX := %.1f" % GrassField.widen_max)
	lines.append("const WIND_FADE_START := %.1f" % GrassField.wind_fade_start)
	lines.append("const WIND_FADE_END := %.1f" % GrassField.wind_fade_end)
	lines.append("[GrassTuning] paste into grass_blade.gdshader (GrassColor uniforms):")
	for spec in COLOR_PARAMS:
		var c: Color = _color_pickers[spec[0]].color
		lines.append("uniform vec3 %s : source_color = vec3(%.3f, %.3f, %.3f);" % [spec[0], c.r, c.g, c.b])
	for spec in FLOAT_PARAMS:
		lines.append("%s = %.2f" % [spec[0], float(_float_sliders[spec[0]].value)])
	var t := _ground_tint()
	lines.append("[GrassTuning] paste into ground_paint.gd:")
	lines.append("const GRASS_TINT := Color(%.3f, %.3f, %.3f)" % [t.r, t.g, t.b])
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

## Short layers: each starts where the previous ends, is at least 2 m deep, and thins out over at
## most its own depth.
func _sanitized_short(layers: Array) -> Array:
	var out: Array = layers.duplicate(true)
	var prev := 0.0
	for s: Dictionary in out:
		s.inner = prev
		s.outer = maxf(float(s.outer), prev + 2.0)
		s.band = clampf(float(s.band), SHORT_FADE_RANGE[0], float(s.outer) - prev)
		prev = float(s.outer)
	return out

func _sync_sliders() -> void:
	for k in _bands.size():
		_end_sliders[k].set_value_no_signal(float(_bands[k].outer))
		_spacing_sliders[k].set_value_no_signal(float(_bands[k].spacing))
	for k in _short.size():
		for key: String in _short_sliders[k]:
			_short_sliders[k][key].set_value_no_signal(float(_short[k][key]))
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
	for k in _short.size():
		var s: Dictionary = _short[k]
		for spec in SHORT_ROWS:
			_short_labels[k][spec[0]].text = spec[4] % float(s[spec[0]])
		var short_cells := int(pow(2.0 * float(s.outer) / float(s.spacing), 2.0))
		total_cells += short_cells
		lines.append("short %d %3.0f-%3.0f m   %6.2f blades/m2   cells %s   fades out over the last %.0f m" % [k, float(s.inner), float(s.outer), 1.0 / (float(s.spacing) * float(s.spacing)), _k(short_cells), float(s.band)])
	lines.append("GPU cull cells per frame (all bands + short): %s" % _k(total_cells))
	_readout.text = "\n".join(lines)
	_widen_labels["scale"].text = "%.4f" % GrassField.widen_scale
	_widen_labels["power"].text = "%.2f" % GrassField.widen_power
	_widen_labels["max"].text = "%.1f" % GrassField.widen_max
	if not _wind_labels.is_empty():
		_wind_labels["fade start"].text = "%.0f m" % GrassField.wind_fade_start
		_wind_labels["fade end"].text = "%.0f m" % GrassField.wind_fade_end
	for param: StringName in _float_labels:
		_float_labels[param].text = "%.2f" % float(_float_sliders[param].value)
	if _tint_mult_label:
		_tint_mult_label.text = "x%.2f" % float(_tint_mult.value)

func _k(v: int) -> String:
	return "%.1fM" % (v / 1000000.0) if v >= 1000000 else "%dk" % (v / 1000)

func _bands_str(bands: Array) -> String:
	var parts := PackedStringArray()
	for b in bands:
		parts.append("%.0f-%.0f@%.2f" % [float(b.inner), float(b.outer), float(b.spacing)])
	return ", ".join(parts)

func _field() -> GrassField:
	return get_tree().current_scene.get_node_or_null(GrassField.NODE_NAME) as GrassField
