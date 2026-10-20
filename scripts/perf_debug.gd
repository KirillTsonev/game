extends Node
## DEBUG: dev-only keys. Off in an exported game (see _ready): they work when the game is started
## from the editor or from a command line with the editor's executable (the benchmark launches).
##   Y = grass tuning panel (scripts/debug/grass_tuning_panel.gd): distance bands + widening.
##       Y opens it with the cursor; click outside to look around again; Y = cursor back / close.
##   J = layer panel (scripts/debug/layer_toggle_panel.gd): checkboxes to show/hide the grass,
##       tree, rock, fern/shrub and deadfall layers -- A/B their FPS cost. Same cursor handling as Y.
##   V = fly mode on / off (Player.debug_fly): no gravity, no collision. WASD moves where the
##       camera looks, Space up, Ctrl down, hold Shift for 6x speed. Switching it off drops the
##       player from where they are.
##   I = animation panel (scripts/debug/animation_panel.gd): the body's fidgets in stages, a
##       time slider, speed, loop. Same cursor handling as Y.
##   1 / 2 = the fireflies' swarm lights / glint lights on / off, each on its own
##       (FireflyField.toggle_swarm_lights / toggle_glints, 2026-10-20).
## The benchmark (scripts/debug/perf_bench.gd) runs, then quits, when the game is launched with
## the user argument --bench [--bench-label=<name>]. Its F9 / F10 keys, and T, P, R, H, G, K, O,
## M, F1-F4, F6, F7, F11, were removed on 2026-10-14 (Kirill: "leave only Y, J, V"); they are in
## git up to commit 0c93048.

const PerfBench := preload("res://scripts/debug/perf_bench.gd")

var _bench: Node
var _grass_panel: GrassTuningPanel
var _layer_panel: LayerTogglePanel
var _animation_panel: AnimationPanel

func _ready() -> void:
	# "editor" = the editor's executable is running the game; an exported game does not have it.
	if not OS.has_feature("editor"):
		set_process_input(false)
		return
	# The benchmark reads the viewport's measured render times.
	RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(), true)
	if "--bench" in OS.get_cmdline_user_args():
		_start_bench(true)

func _start_bench(quit_when_done: bool) -> void:
	if is_instance_valid(_bench):
		return # already running
	var label := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bench-label="):
			label = arg.trim_prefix("--bench-label=")
	_bench = PerfBench.new()
	add_child(_bench)
	_bench.run(quit_when_done, label)

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.physical_keycode == KEY_Y:
		if not is_instance_valid(_grass_panel):
			_grass_panel = GrassTuningPanel.new()
			_grass_panel.visible = false
			get_tree().root.add_child(_grass_panel)
		_grass_panel.toggle()
	elif event.physical_keycode == KEY_J:
		if not is_instance_valid(_layer_panel):
			_layer_panel = LayerTogglePanel.new()
			_layer_panel.visible = false
			get_tree().root.add_child(_layer_panel)
		_layer_panel.toggle()
	elif event.physical_keycode == KEY_I:
		if not is_instance_valid(_animation_panel):
			_animation_panel = AnimationPanel.new()
			_animation_panel.visible = false
			get_tree().root.add_child(_animation_panel)
		_animation_panel.toggle()
	elif event.physical_keycode == KEY_1 or event.physical_keycode == KEY_2:
		var fireflies := get_tree().current_scene.get_node_or_null(FireflyField.NODE_NAME) as FireflyField
		if fireflies == null:
			print("[PerfDebug] no fireflies in this world")
		elif event.physical_keycode == KEY_1:
			print(fireflies.toggle_swarm_lights())
		else:
			print(fireflies.toggle_glints())
	elif event.physical_keycode == KEY_V:
		var player := get_tree().current_scene.get_node_or_null("Player")
		if player:
			player.set("debug_fly", not player.get("debug_fly"))
			print("[PerfDebug] fly mode %s -- WASD where the camera looks, Space up, Ctrl down, hold Shift = fast; no collision" % ("ON" if player.get("debug_fly") else "off (falling from here)"))
