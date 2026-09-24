extends CanvasLayer

## Barebones pause / main menu. Autoloaded so it's available from any scene.
## Esc (ui_cancel) toggles it open/closed; opening pauses the SceneTree so
## gameplay (player, physics) freezes while the menu is up. This node's own
## process_mode is ALWAYS so it (and its Control children, which inherit
## process_mode by default) keep receiving input while paused.

const SCALING_MODE_OFF := 0   # Bilinear / scaling disabled (matches fsr_debug_toggle.gd)
const SCALING_MODE_FSR := 1   # FSR 1.0
const DEFAULT_FSR_SCALE := 0.85
const SETTINGS_PATH := "user://settings.cfg"

@onready var root: Control = $Root
@onready var main_panel: VBoxContainer = $Root/Center/MainPanel
@onready var options_panel: VBoxContainer = $Root/Center/OptionsPanel
@onready var resume_button: Button = $Root/Center/MainPanel/ResumeButton
@onready var options_button: Button = $Root/Center/MainPanel/OptionsButton
@onready var back_button: Button = $Root/Center/OptionsPanel/BackButton
@onready var fsr_toggle: CheckBox = $Root/Center/OptionsPanel/FSRRow/FSRToggle
@onready var fsr_slider: HSlider = $Root/Center/OptionsPanel/FSRScaleRow/FSRScaleSlider
@onready var fsr_value_label: Label = $Root/Center/OptionsPanel/FSRScaleRow/FSRScaleValue
@onready var shadows_toggle: CheckBox = $Root/Center/OptionsPanel/ShadowsRow/ShadowsToggle
@onready var postfx_toggle: CheckBox = $Root/Center/OptionsPanel/PostFXRow/PostFXToggle

var _is_open: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	root.visible = false

	resume_button.pressed.connect(_on_resume_pressed)
	options_button.pressed.connect(_on_options_pressed)
	back_button.pressed.connect(_on_back_pressed)
	fsr_toggle.toggled.connect(_on_fsr_toggled)
	fsr_slider.value_changed.connect(_on_fsr_scale_changed)
	shadows_toggle.toggled.connect(_on_shadows_toggled)
	postfx_toggle.toggled.connect(_on_postfx_toggled)

	# Apply whatever was saved from last session (if anything) to the
	# viewport BEFORE the controls read the viewport's state, so both the
	# rendering and the UI reflect the saved setting from frame one.
	_load_settings()
	_sync_fsr_controls_from_viewport()

	# The DirectionalLight3D and WorldEnvironment both live in the
	# (not-yet-loaded) main scene -- autoloads ready before the main scene
	# is added to the tree, so these settings have to be applied a frame
	# later, once those nodes actually exist.
	call_deferred("_apply_deferred_shadows_setting")
	call_deferred("_apply_deferred_postfx_setting")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if not _is_open:
			_open_menu()
		elif options_panel.visible:
			_on_back_pressed()
		else:
			_close_menu()
		get_viewport().set_input_as_handled()

func _open_menu() -> void:
	_is_open = true
	root.visible = true
	main_panel.visible = true
	options_panel.visible = false
	_sync_fsr_controls_from_viewport()
	_sync_shadows_control_from_light()
	_sync_postfx_control_from_compositor()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close_menu() -> void:
	_is_open = false
	root.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_resume_pressed() -> void:
	_close_menu()

func _on_options_pressed() -> void:
	main_panel.visible = false
	options_panel.visible = true

func _on_back_pressed() -> void:
	options_panel.visible = false
	main_panel.visible = true

func _on_fsr_toggled(enabled: bool) -> void:
	var vp := get_viewport()
	if enabled:
		vp.scaling_3d_mode = SCALING_MODE_FSR
		vp.scaling_3d_scale = fsr_slider.value
	else:
		vp.scaling_3d_mode = SCALING_MODE_OFF
		vp.scaling_3d_scale = 1.0
	# Slider stays draggable either way -- it just doesn't affect rendering
	# until FSR is enabled (see _on_fsr_scale_changed).
	_save_settings()

func _on_fsr_scale_changed(value: float) -> void:
	fsr_value_label.text = "%d%%" % int(round(value * 100.0))
	if fsr_toggle.button_pressed:
		get_viewport().scaling_3d_scale = value
		_save_settings()

func _on_shadows_toggled(enabled: bool) -> void:
	var light := _get_directional_light()
	if light:
		light.shadow_enabled = enabled
	_save_settings()

func _on_postfx_toggled(enabled: bool) -> void:
	_set_postfx_enabled(enabled)
	_save_settings()

## Finds the scene's sun/shadow-caster the same defensive way player.gd
## looks up Terrain3D -- a search rather than a hardcoded path, so this
## autoload doesn't break if main.tscn's node layout changes or this menu
## gets reused in a different scene that has no DirectionalLight3D at all.
func _get_directional_light() -> DirectionalLight3D:
	var lights := get_tree().root.find_children("*", "DirectionalLight3D", true, false)
	if lights.is_empty():
		return null
	return lights[0]

## Same defensive search pattern as _get_directional_light -- main.tscn's
## WorldEnvironment is where res://assets/compositor.tres (the array of
## post-process CompositorEffects: film grain, bloom, glare, gaussian/radial
## blur, painterly saturation) is actually assigned.
func _get_world_environment() -> WorldEnvironment:
	var envs := get_tree().root.find_children("*", "WorldEnvironment", true, false)
	if envs.is_empty():
		return null
	return envs[0]

## Toggles every effect in the compositor's effect array at once, rather
## than clearing WorldEnvironment.compositor entirely -- this only flips
## each CompositorEffect's own `enabled` flag (which the renderer already
## respects per-effect, skipping disabled ones outright), so the Compositor
## resource and its effect list stay intact and re-enabling doesn't need to
## remember/restore anything.
func _set_postfx_enabled(enabled: bool) -> void:
	var world_env := _get_world_environment()
	if not world_env or not world_env.compositor:
		return
	for effect in world_env.compositor.compositor_effects:
		if effect:
			effect.enabled = enabled

func _apply_deferred_shadows_setting() -> void:
	var light := _get_directional_light()
	if light:
		light.shadow_enabled = shadows_toggle.button_pressed

func _apply_deferred_postfx_setting() -> void:
	_set_postfx_enabled(postfx_toggle.button_pressed)

## Reads whatever the viewport's actual scaling state is (which may have
## been set by fsr_debug_toggle.gd's F10 shortcut, or a previous menu
## session) so the Options panel never shows a stale value.
func _sync_fsr_controls_from_viewport() -> void:
	var vp := get_viewport()
	var enabled := vp.scaling_3d_mode == SCALING_MODE_FSR
	fsr_toggle.button_pressed = enabled
	fsr_slider.value = vp.scaling_3d_scale if enabled else DEFAULT_FSR_SCALE
	fsr_value_label.text = "%d%%" % int(round(fsr_slider.value * 100.0))

func _sync_shadows_control_from_light() -> void:
	var light := _get_directional_light()
	if light:
		shadows_toggle.button_pressed = light.shadow_enabled

## Reads back whether post-FX is currently on from the live compositor
## effects themselves (true if ANY effect is enabled) rather than trusting
## the control's last state, same reasoning as the FSR/shadows syncs above.
func _sync_postfx_control_from_compositor() -> void:
	var world_env := _get_world_environment()
	if not world_env or not world_env.compositor:
		return
	var any_enabled := false
	for effect in world_env.compositor.compositor_effects:
		if effect and effect.enabled:
			any_enabled = true
			break
	postfx_toggle.button_pressed = any_enabled

## Video settings are saved to a small ConfigFile every time they change --
## no save button needed, and it's the only persisted state this project
## has, so a single flat file is plenty.
func _save_settings() -> void:
	var cfg := ConfigFile.new()
	var vp := get_viewport()
	cfg.set_value("video", "fsr_enabled", vp.scaling_3d_mode == SCALING_MODE_FSR)
	cfg.set_value("video", "fsr_scale", fsr_slider.value)
	cfg.set_value("video", "shadows_enabled", shadows_toggle.button_pressed)
	cfg.set_value("video", "postfx_enabled", postfx_toggle.button_pressed)
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("[PauseMenu] Failed to save %s (error %d)" % [SETTINGS_PATH, err])

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return # no settings file yet (first run) -- keep engine defaults
	var enabled: bool = cfg.get_value("video", "fsr_enabled", false)
	var saved_scale: float = cfg.get_value("video", "fsr_scale", DEFAULT_FSR_SCALE)
	var vp := get_viewport()
	if enabled:
		vp.scaling_3d_mode = SCALING_MODE_FSR
		vp.scaling_3d_scale = saved_scale
	else:
		vp.scaling_3d_mode = SCALING_MODE_OFF
		vp.scaling_3d_scale = 1.0
	# shadows_toggle already defaults to button_pressed = true (the scene's
	# authored default, matching DirectionalLight3D's own default); just
	# override it here if a save file says otherwise. The actual light
	# node gets this value in _apply_deferred_shadows_setting().
	shadows_toggle.button_pressed = cfg.get_value("video", "shadows_enabled", true)
	# Same pattern as shadows above -- postfx_toggle already defaults to
	# button_pressed = true (matching every effect's authored enabled = true
	# in compositor.tres); the WorldEnvironment itself gets this value in
	# _apply_deferred_postfx_setting().
	postfx_toggle.button_pressed = cfg.get_value("video", "postfx_enabled", true)
