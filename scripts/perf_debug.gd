extends Node
## DEBUG: dev-only key, not meant to ship.
##   T = tree probe: why can/can't a tree grow where the player stands.
##       Re-runs the tree placement checks at the player's feet via
##       WorldGenerator.debug_tree_probe() (terrain_gen.gd) and prints the report.
##   G = grass overlay: cycles a decal over the whole map -- off / density / dry / tall
##       (GrassScatter.cycle_debug_overlay).
##   H = grass probe: every density factor at the player's feet (GrassScatter.debug_probe).
##   J = grass field on/off (GrassField) -- A/B its FPS cost.
##   K = grass culling readback: tufts actually drawn per variant vs buffer capacity.
##   Y = grass tuning panel (scripts/debug/grass_tuning_panel.gd): distance bands + widening.
##       Y opens it with the cursor; click outside to look around again; Y = cursor back / close.
##   P = GPU/CPU frame time: averages the viewport's measured render time over TIMING_FRAMES frames
##       and prints avg / worst ms (works with VSync / the 60 FPS cap -- use this, not FPS).

const TIMING_FRAMES := 120

var _grass_panel: GrassTuningPanel
var _timing_left := 0
var _gpu_sum := 0.0
var _cpu_sum := 0.0
var _gpu_max := 0.0
var _cpu_max := 0.0

func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(), true)

func _process(_delta: float) -> void:
	if _timing_left <= 0:
		return
	var vp := get_tree().root.get_viewport_rid()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
	_gpu_sum += gpu
	_cpu_sum += cpu
	_gpu_max = maxf(_gpu_max, gpu)
	_cpu_max = maxf(_cpu_max, cpu)
	_timing_left -= 1
	if _timing_left == 0:
		print("[Timing] %d frames -- GPU avg %.2f ms (worst %.2f), render CPU avg %.2f ms (worst %.2f)" % [
			TIMING_FRAMES, _gpu_sum / TIMING_FRAMES, _gpu_max, _cpu_sum / TIMING_FRAMES, _cpu_max])

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.physical_keycode == KEY_T:
		_probe_tree_spot()
	elif event.physical_keycode == KEY_P:
		if _timing_left <= 0:
			_timing_left = TIMING_FRAMES
			_gpu_sum = 0.0
			_cpu_sum = 0.0
			_gpu_max = 0.0
			_cpu_max = 0.0
			print("[Timing] measuring %d frames -- hold still..." % TIMING_FRAMES)
	elif event.physical_keycode == KEY_Y:
		if not is_instance_valid(_grass_panel):
			_grass_panel = GrassTuningPanel.new()
			_grass_panel.visible = false
			get_tree().root.add_child(_grass_panel)
		_grass_panel.toggle()
	elif event.physical_keycode == KEY_G:
		print(GrassScatter.cycle_debug_overlay(get_tree().current_scene))
	elif event.physical_keycode == KEY_J:
		var field := get_tree().current_scene.get_node_or_null("GrassField") as Node3D
		if field:
			field.visible = not field.visible
			field.process_mode = Node.PROCESS_MODE_INHERIT if field.visible else Node.PROCESS_MODE_DISABLED
			print("[Grass] field %s -- %d FPS at toggle (let it settle a few seconds and compare)" % ["ON" if field.visible else "OFF", Engine.get_frames_per_second()])
	elif event.physical_keycode == KEY_K:
		var field := get_tree().current_scene.get_node_or_null("GrassField")
		if field:
			field.request_debug_counts() # prints "[Grass] drawn tufts ..." from the render thread
	elif event.physical_keycode == KEY_H:
		var player := get_tree().current_scene.get_node_or_null("Player") as Node3D
		if player:
			print(GrassScatter.debug_probe(player.global_position))
func _probe_tree_spot() -> void:
	var scene := get_tree().current_scene
	var player := scene.get_node_or_null("Player") as Node3D
	var gen := scene.get_node_or_null("WorldGenerator")
	if player == null or gen == null or not gen.has_method("debug_tree_probe"):
		print("[PerfDebug] tree probe: Player or WorldGenerator (with debug_tree_probe) not found")
		return
	print(gen.debug_tree_probe(player.global_position))
