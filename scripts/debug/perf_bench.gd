## DEBUG (dev only): automated performance benchmark. Started by PerfDebug (scripts/perf_debug.gd):
##   - F9 in a running game, or
##   - launch with the user argument --bench (runs, writes the report, quits):
##       Godot_v4.7.2-stable_win64_console.exe --path <project> -- --bench --bench-label=<name>
##     More user arguments: --bench-only=<text>[,<text>...] (only the ablation toggles whose name
##     contains one of the texts),
##     --bench-no-shadows (sun shadows off for the whole run), --bench-scale=<x> (3D render scale
##     multiplied by x for the whole run). The last two are recorded in the report's meta.
##
## What a run does (about 4 minutes; the player is frozen and moved by the benchmark):
##   1. Conditions: VSync off, FPS cap off, window WINDOW_SIZE. Needs MASTER_SEED pinned
##      (TerrainConfig) -- the stations come from the generated map.
##   2. Audit: every mesh in the scene (instances, triangles, shadow casting) and every texture
##      their materials and the terrain use (size, estimated memory).
##   3. Stations: fixed camera spots picked from the map data (_build_stations). At each one:
##      frame time (avg / p50 / p95 / p99 / worst), GPU ms, render CPU ms, draw calls, triangles,
##      video memory.
##   4. Ablation at ABLATION_STATIONS: one thing switched off at a time (each scatter layer, each
##      compositor effect, sun shadows, sun shadows at 100 m, SSAO (if on), MSAA, FXAA, half render scale). "delta" = what the
##      frame gains with it off = roughly its cost. Costs overlap, so deltas do not add up.
##   5. Walk: along the road at WALK_SPEED -- frame-time spikes while the world streams past.
##   6. Startup: WorldGenerator.startup_timings.
## Output: res://perf_reports/<time>_<git>_<label>.json + .txt (also printed). Compare two runs
## with tools/perf_compare.ps1.
extends Node

const WINDOW_SIZE := Vector2i(1906, 942)
const REPORT_DIR := "res://perf_reports"
## After moving the camera or switching something: wait at least this long before measuring.
const SETTLE_FRAMES := 20
const SETTLE_SECONDS := 0.6
## One measurement lasts at least this many frames AND this many seconds.
const MEASURE_FRAMES := 120
const MEASURE_SECONDS := 1.5
const MEASURE_MAX_FRAMES := 5000
const ABLATION_STATIONS := ["spawn_ahead", "forest_dense", "exit_look_back"]
const WALK_SPEED := 10.0 ## m/s along the road (the player walks at 4.5)
const WALK_SECONDS := 20.0
const FOREST_CELL := 16.0 ## m -- grid used to find the densest tree cell
const OPEN_RADIUS := 20.0 ## m -- "road_open" = the road point with the fewest trees this close
const AUDIT_ROWS := 40

var _scene: Node
var _gen: Node
var _terrain: Terrain3D
var _player: Node3D
var _camera: Camera3D
var _corner := Vector3.ZERO
var _layer_nodes := {} # layer key -> Array[Node3D] to hide for that layer (filled by _audit_meshes)
var _layer_assets := {} # layer key -> {asset label -> stats} (filled by _audit_meshes)
var _vp: RID
var _materials := {} # Material -> true, collected by _audit_meshes for _audit_textures

func run(quit_when_done: bool, label: String) -> void:
	# The project starts in the boot scene (loading screen), which switches to the main scene once
	# that has loaded -- wait for the scene that holds the WorldGenerator (30 s at most).
	var wait_until := Time.get_ticks_msec() + 30000
	while get_tree().current_scene == null or (get_tree().current_scene.get_node_or_null("WorldGenerator") == null and Time.get_ticks_msec() < wait_until):
		await get_tree().process_frame
	if not _bind_scene():
		push_error("[Bench] needs the main scene (WorldGenerator, Terrain3D, Player)")
		queue_free()
		return
	while not _gen.startup_timings.has("settled_at_ms"):
		await get_tree().process_frame

	var root := get_tree().root
	_vp = root.get_viewport_rid()
	var saved_vsync := DisplayServer.window_get_vsync_mode()
	var saved_max_fps := Engine.max_fps
	var saved_size := root.size
	var saved_mouse := Input.mouse_mode
	var saved_xform := _player.global_transform
	var saved_pitch := _camera.rotation.x
	var saved_process := _player.process_mode
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if root.mode != Window.MODE_WINDOWED:
		root.mode = Window.MODE_WINDOWED
	root.size = WINDOW_SIZE
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_player.process_mode = Node.PROCESS_MODE_DISABLED # no input, no gravity: the benchmark places it
	# Whole-run conditions from user arguments, to split one layer's cost (with --bench-only=layer:<x>):
	# --bench-no-shadows = sun shadows off, --bench-scale=<x> = 3D render scale multiplied by x.
	var sun := _scene.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	var saved_shadows := sun.shadow_enabled if sun else false
	var saved_scale := root.scaling_3d_scale
	for arg in OS.get_cmdline_user_args():
		if arg == "--bench-no-shadows" and sun:
			sun.shadow_enabled = false
		elif arg.begins_with("--bench-scale="):
			root.scaling_3d_scale = saved_scale * arg.trim_prefix("--bench-scale=").to_float()

	_read_corner()
	var stations := _build_stations()
	print("[Bench] started -- %d stations, about 4 minutes. Do not touch the window." % stations.size())
	for st in stations: # warm-up: compile every pipeline these views need before measuring
		_goto(st)
		await _settle()
	if root.size != WINDOW_SIZE:
		push_warning("[Bench] viewport is %s, wanted %s -- results are not comparable with a %s run" % [root.size, WINDOW_SIZE, WINDOW_SIZE])
	# The Options menu's saved video settings apply to a benchmark launch too. A run with one of
	# these off is not comparable with the baseline (happened 2026-10-05) -- record and warn.
	var world_env := _scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var ssao_on := world_env != null and world_env.environment != null and world_env.environment.ssao_enabled
	var post_effects_on := 0
	if world_env and world_env.compositor:
		for effect in world_env.compositor.compositor_effects:
			if effect and effect.enabled:
				post_effects_on += 1
	var shadows_arg_off := "--bench-no-shadows" in OS.get_cmdline_user_args()
	# (SSAO is off in the project since 2026-10-05 and has no menu entry; it is only recorded.)
	if post_effects_on == 0 or (sun and not sun.shadow_enabled and not shadows_arg_off):
		push_warning("[Bench] video settings differ from the baseline: sun shadows %s, %d post effects on -- check the Options menu" % ["on" if sun and sun.shadow_enabled else "OFF", post_effects_on])

	var report := {
		"meta": {
			"time": Time.get_datetime_string_from_system(),
			"git": _git_head(),
			"label": label,
			"seed": _gen._debug_seed,
			"godot": Engine.get_version_info().string,
			"adapter": RenderingServer.get_video_adapter_name(),
			"viewport": [root.size.x, root.size.y],
			"msaa_3d": root.msaa_3d,
			"screen_space_aa": root.screen_space_aa,
			"scaling_3d_scale": root.scaling_3d_scale,
			"scaling_3d_mode": root.scaling_3d_mode,
			"sun_shadows": sun != null and sun.shadow_enabled,
			"ssao": ssao_on,
			"post_effects_on": post_effects_on,
			"frame_capped": false,
		},
		"startup": _gen.startup_timings,
		"audit": {"meshes": _audit_meshes()},
		"stations": [],
		"ablation": [],
	}
	report.audit["layers"] = _audit_layers()
	report.audit["textures"] = _audit_textures()

	for st in stations:
		_goto(st)
		var m: Dictionary = await _measure()
		m["name"] = st.name
		m["pos"] = [_r(st.pos.x), _r(st.pos.y), _r(st.pos.z)]
		report.stations.append(m)
		print("[Bench] station %s: %.2f ms frame, %.2f ms GPU" % [st.name, m.frame_ms, m.gpu_ms])
		# A frame far longer than its own GPU + CPU work = something outside the game limits the
		# frame rate (driver setting, overlay limiter). Frame-time columns then only show the cap.
		if m.frame_ms > 10.0 and m.frame_ms > 2.0 * (m.gpu_ms + m.cpu_render_ms):
			report.meta.frame_capped = true
	if report.meta.frame_capped:
		push_warning("[Bench] the frame rate is capped from outside the game -- compare GPU ms, not frame ms")

	var toggles := _build_toggles()
	for st in stations:
		if not ABLATION_STATIONS.has(st.name):
			continue
		_goto(st)
		var base_start: Dictionary = await _measure()
		var rows: Array = []
		for t in toggles:
			t.apply.call(false)
			var m: Dictionary = await _measure()
			t.apply.call(true)
			m["name"] = t.name
			rows.append(m)
			print("[Bench] %s, %s off: %.2f ms frame" % [st.name, t.name, m.frame_ms])
		var base_end: Dictionary = await _measure()
		# Baseline = mean of the readings before and after, so slow drift (GPU clock, heat) cancels.
		var base_frame: float = (base_start.frame_ms + base_end.frame_ms) * 0.5
		var base_gpu: float = (base_start.gpu_ms + base_end.gpu_ms) * 0.5
		for m in rows:
			m["delta_frame_ms"] = _r(base_frame - m.frame_ms)
			m["delta_gpu_ms"] = _r(base_gpu - m.gpu_ms)
			m["delta_draw_calls"] = base_start.draw_calls - m.draw_calls
			m["delta_primitives"] = base_start.primitives - m.primitives
		report.ablation.append({"station": st.name, "baseline_start": base_start, "baseline_end": base_end, "toggles": rows})

	print("[Bench] walking the road...")
	report["walk"] = await _walk(_road_path())

	_player.process_mode = saved_process
	_player.global_transform = saved_xform
	_camera.rotation.x = saved_pitch
	if sun:
		sun.shadow_enabled = saved_shadows
	root.scaling_3d_scale = saved_scale
	root.size = saved_size
	Engine.max_fps = saved_max_fps
	DisplayServer.window_set_vsync_mode(saved_vsync)
	Input.mouse_mode = saved_mouse

	var summary := _summary(report)
	print(summary)
	var dir := ProjectSettings.globalize_path(REPORT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	if not FileAccess.file_exists(dir + "/.gdignore"):
		FileAccess.open(dir + "/.gdignore", FileAccess.WRITE).close() # keep the editor from scanning reports
	var stem := "%s/%s_%s%s" % [dir, str(report.meta.time).replace(":", "").replace("-", "").replace("T", "_"), report.meta.git, "" if label.is_empty() else "_" + label]
	var f := FileAccess.open(stem + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t"))
	f.close()
	f = FileAccess.open(stem + ".txt", FileAccess.WRITE)
	f.store_string(summary)
	f.close()
	print("[Bench] report written: %s.json (+ .txt)" % stem)
	if quit_when_done:
		get_tree().quit()
	queue_free()

## Finds the main scene's nodes. False while the main scene (or one of them) is not there.
func _bind_scene() -> bool:
	_scene = get_tree().current_scene
	if _scene == null:
		return false
	_gen = _scene.get_node_or_null("WorldGenerator")
	_terrain = _scene.get_node_or_null("Terrain3D") as Terrain3D
	_player = _scene.get_node_or_null("Player") as Node3D
	if _gen == null or _terrain == null or _player == null:
		return false
	_camera = _player.get_node("Camera3D") as Camera3D
	return true

## Same read-back as WorldGenerator._ready(): where Terrain3D really put the map.
func _read_corner() -> void:
	var region_size: int = _terrain.get_region_size()
	var min_x := 1 << 30
	var min_z := 1 << 30
	for loc in _terrain.get_data().get_region_locations():
		min_x = mini(min_x, loc.x)
		min_z = mini(min_z, loc.y)
	_corner = Vector3(min_x * region_size, 0, min_z * region_size)

# ---------------------------------------------------------------- station hold (PerfDebug F10)

var _held := {} # what hold_station() changed, for release_station()

## Puts the frozen player at ablation station `index` under the benchmark's conditions (window
## size, VSync and FPS cap off) and leaves it there -- for a profiler capture (the editor's Visual
## Profiler, RenderDoc) of the same view the reports measure. Returns the station name, or "" if
## the world is not ready. Call release_station() to hand the player back.
func hold_station(index: int) -> String:
	if not _bind_scene() or not _gen.startup_timings.has("settled_at_ms"):
		return ""
	var root := get_tree().root
	if _held.is_empty():
		_held = {
			"vsync": DisplayServer.window_get_vsync_mode(), "max_fps": Engine.max_fps, "size": root.size,
			"xform": _player.global_transform, "pitch": _camera.rotation.x, "process": _player.process_mode,
		}
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		if root.mode == Window.MODE_WINDOWED:
			root.size = WINDOW_SIZE
		_player.process_mode = Node.PROCESS_MODE_DISABLED
	_read_corner()
	for st in _build_stations():
		if st.name == ABLATION_STATIONS[index]:
			_goto(st)
			return "%s (viewport %dx%d, 3D scale %.2f)" % [st.name, root.size.x, root.size.y, root.scaling_3d_scale]
	return ""

func release_station() -> void:
	if _held.is_empty():
		return
	_player.process_mode = _held.process
	_player.global_transform = _held.xform
	_camera.rotation.x = _held.pitch
	get_tree().root.size = _held.size
	Engine.max_fps = _held.max_fps
	DisplayServer.window_set_vsync_mode(_held.vsync)
	_held = {}

# ---------------------------------------------------------------- stations

## Road centreline in heightmap pixels (1 px = 1 m), ordered spawn -> exit.
func _road_path() -> PackedVector2Array:
	var maps: Dictionary = _gen._debug_maps
	var path: PackedVector2Array = maps.road_path
	var spawn := Vector2(maps.spawn_pixel.x, maps.spawn_pixel.z)
	if path[0].distance_to(spawn) > path[path.size() - 1].distance_to(spawn):
		path = path.duplicate()
		path.reverse()
	return path

func _build_stations() -> Array[Dictionary]:
	var maps: Dictionary = _gen._debug_maps
	var path := _road_path()
	var n := path.size()
	var spawn := Vector2(maps.spawn_pixel.x, maps.spawn_pixel.z)
	var exit := Vector2(maps.exit_pixel.x, maps.exit_pixel.z)
	var trees: PackedVector3Array = TreeScatter.tree_points # (px, pz, scale)
	var stations: Array[Dictionary] = []

	stations.append(_station("spawn_ahead", spawn, exit - spawn, 0.0))
	stations.append(_station("spawn_ground", spawn, exit - spawn, -1.4))
	stations.append(_station("spawn_sky", spawn, exit - spawn, 1.4))
	@warning_ignore("integer_division")
	var mid := n / 2
	stations.append(_station("road_mid", path[mid], path[mini(mid + 8, n - 1)] - path[maxi(mid - 8, 0)], 0.0))
	var far := path[int(n * 0.95)]
	stations.append(_station("exit_look_back", far, spawn - far, 0.0))

	# forest_dense: the FOREST_CELL cell with the most trees, standing as far from a trunk as it allows.
	var cells := {}
	for tp in trees:
		var c := Vector2i(int(tp.x / FOREST_CELL), int(tp.y / FOREST_CELL))
		cells[c] = cells.get(c, 0) + 1
	var best_cell := Vector2i.ZERO
	var best_count := -1
	for c in cells:
		if cells[c] > best_count:
			best_count = cells[c]
			best_cell = c
	if best_count > 0:
		var best_p := (Vector2(best_cell) + Vector2(0.5, 0.5)) * FOREST_CELL
		var best_gap := -1.0
		for ix in 7:
			for iz in 7:
				var p := (Vector2(best_cell) + Vector2(ix + 1, iz + 1) / 8.0) * FOREST_CELL
				var gap := INF
				for tp in trees:
					gap = minf(gap, p.distance_squared_to(Vector2(tp.x, tp.y)))
				if gap > best_gap:
					best_gap = gap
					best_p = p
		var centre := Vector2(TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH) * 0.5
		stations.append(_station("forest_dense", best_p, centre - best_p, 0.0))

	# road_open: the road point with the fewest trees within OPEN_RADIUS.
	var open_i := mid
	var open_count := 1 << 30
	for k in range(6, 55):
		var i := int(n * k / 60.0)
		var count := 0
		for tp in trees:
			if path[i].distance_squared_to(Vector2(tp.x, tp.y)) < OPEN_RADIUS * OPEN_RADIUS:
				count += 1
		if count < open_count:
			open_count = count
			open_i = i
	stations.append(_station("road_open", path[open_i], path[mini(open_i + 8, n - 1)] - path[maxi(open_i - 8, 0)], 0.0))

	# cliff_face: from the nearest road point, looking at the first knot (or the first cliff mesh).
	var target := Vector2.INF
	if not maps.knots.is_empty():
		target = Vector2(maps.knots[0].ax, maps.knots[0].az)
	elif not maps.cliff_dressing_plan.is_empty():
		target = Vector2(maps.cliff_dressing_plan[0].px, maps.cliff_dressing_plan[0].pz)
	if target != Vector2.INF:
		var near := path[0]
		for p in path:
			if p.distance_squared_to(target) < near.distance_squared_to(target):
				near = p
		stations.append(_station("cliff_face", near, target - near, 0.0))
	return stations

func _station(station_name: String, px: Vector2, dir: Vector2, pitch: float) -> Dictionary:
	var pos := _corner + Vector3(px.x, 0.0, px.y)
	var h: float = _terrain.get_data().get_height(pos)
	pos.y = (0.0 if is_nan(h) else h) + 0.1
	return {"name": station_name, "pos": pos, "dir": dir, "pitch": pitch}

func _goto(st: Dictionary) -> void:
	var d: Vector2 = st.dir
	_player.global_position = st.pos
	_player.rotation = Vector3(0.0, atan2(-d.x, -d.y), 0.0) # forward is -Z
	_camera.rotation.x = st.pitch

# ---------------------------------------------------------------- measuring

func _settle() -> void:
	var t0 := Time.get_ticks_usec()
	var frames := 0
	while frames < SETTLE_FRAMES or Time.get_ticks_usec() - t0 < SETTLE_SECONDS * 1e6:
		await get_tree().process_frame
		frames += 1

func _measure() -> Dictionary:
	await _settle()
	var dts := PackedFloat32Array()
	var gpu := 0.0
	var cpu := 0.0
	var t0 := Time.get_ticks_usec()
	var last := t0
	while dts.size() < MEASURE_MAX_FRAMES and (dts.size() < MEASURE_FRAMES or last - t0 < MEASURE_SECONDS * 1e6):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		dts.append((now - last) / 1000.0)
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu()
	var m := _frame_stats(dts)
	m["gpu_ms"] = _r(gpu / dts.size())
	m["cpu_render_ms"] = _r(cpu / dts.size())
	m["draw_calls"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	m["primitives"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	m["objects"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	m["video_mem_mb"] = _r(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)
	m["texture_mem_mb"] = _r(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0)
	m["buffer_mem_mb"] = _r(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0)
	m["process_ms"] = _r(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	m["physics_ms"] = _r(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	m["static_mem_mb"] = _r(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
	m["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	return m

static func _frame_stats(dts: PackedFloat32Array) -> Dictionary:
	var s := dts.duplicate()
	s.sort()
	var n := s.size()
	var sum := 0.0
	for v in s:
		sum += v
	return {
		"frames": n,
		"frame_ms": _r(sum / n),
		"p50_ms": _r(s[int(n * 0.5)]),
		"p95_ms": _r(s[mini(n - 1, int(n * 0.95))]),
		"p99_ms": _r(s[mini(n - 1, int(n * 0.99))]),
		"max_ms": _r(s[n - 1]),
	}

static func _r(v: float) -> float:
	return snappedf(v, 0.001)

func _walk(path: PackedVector2Array) -> Dictionary:
	var cum := PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		cum.append(cum[i - 1] + path[i].distance_to(path[i - 1]))
	var total := cum[cum.size() - 1]
	var start := total * 0.05
	var end := total * 0.95
	_goto_path(path, cum, start)
	await _settle()
	var dts := PackedFloat32Array()
	var gpu := 0.0
	var t0 := Time.get_ticks_usec()
	var last := t0
	var dist := start
	while dist < end and last - t0 < WALK_SECONDS * 1e6:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		dts.append((now - last) / 1000.0)
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
		dist = start + WALK_SPEED * (now - t0) / 1e6
		_goto_path(path, cum, minf(dist, end))
	var m := _frame_stats(dts)
	var hitches := 0
	var over_60fps := 0
	for v in dts:
		if v > m.p50_ms * 2.0:
			hitches += 1
		if v > 16.667:
			over_60fps += 1
	m["gpu_ms"] = _r(gpu / dts.size())
	m["metres"] = _r(dist - start)
	m["seconds"] = _r((last - t0) / 1e6)
	m["hitches_over_2x_median"] = hitches
	m["frames_over_16_7_ms"] = over_60fps
	return m

func _goto_path(path: PackedVector2Array, cum: PackedFloat32Array, dist: float) -> void:
	var p := _path_point(path, cum, dist)
	var ahead := _path_point(path, cum, dist + 6.0)
	_goto(_station("walk", p, ahead - p if ahead != p else Vector2(0, 1), 0.0))

static func _path_point(path: PackedVector2Array, cum: PackedFloat32Array, dist: float) -> Vector2:
	var i := clampi(cum.bsearch(dist), 1, cum.size() - 1)
	var seg := cum[i] - cum[i - 1]
	return path[i - 1].lerp(path[i], clampf((dist - cum[i - 1]) / seg, 0.0, 1.0) if seg > 0.0 else 0.0)

# ---------------------------------------------------------------- ablation

## [{name, apply: Callable(on: bool)}] -- apply(false) switches the thing off, apply(true) puts it back.
## Only things that are on in the project right now are listed.
func _build_toggles() -> Array[Dictionary]:
	var toggles: Array[Dictionary] = []
	var root := get_tree().root

	for key: StringName in _layer_nodes:
		toggles.append({"name": "layer:%s" % key, "apply": _set_layer_shown.bind(key)})
	var all_layers := func(on: bool) -> void:
		for key: StringName in _layer_nodes:
			_set_layer_shown(on, key)
	toggles.append({"name": "layer:ALL", "apply": all_layers})

	var world_env := _scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env and world_env.compositor:
		var effects: Array[CompositorEffect] = []
		for effect in world_env.compositor.compositor_effects:
			if effect and effect.enabled:
				effects.append(effect)
				var script := effect.get_script() as Script
				var effect_name := script.resource_path.get_file().get_basename().trim_prefix("post_process_") if script else effect.get_class()
				toggles.append({"name": "post:%s" % effect_name, "apply":func(on: bool) -> void: effect.enabled = on})
		var all_effects := func(on: bool) -> void:
			for effect in effects:
				effect.enabled = on
		toggles.append({"name": "post:ALL", "apply":all_effects})
	if world_env and world_env.environment:
		var env := world_env.environment
		for prop in ["ssao_enabled", "ssil_enabled", "sdfgi_enabled", "glow_enabled", "volumetric_fog_enabled", "fog_enabled", "ssr_enabled"]:
			if env.get(prop) == true:
				toggles.append({"name": "env:%s" % prop.trim_suffix("_enabled"), "apply":func(on: bool) -> void: env.set(prop, on)})
		# (2026-10-05: toggles for SSAO at each quality level were here. Every level cost the same
		# -- docs/performance_findings.md step 5 -- and SSAO is off in the project since.)

	var sun := _scene.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun and sun.shadow_enabled:
		toggles.append({"name": "sun_shadows", "apply":func(on: bool) -> void: sun.shadow_enabled = on})
		# A shorter shadow range. The splits are fractions of it, so they move in with it. LOD
		# ranges tied to the shadow range (the tree impostor switch) stay put: a lower bound.
		var shadow_dist := sun.directional_shadow_max_distance
		if shadow_dist > 100.0:
			toggles.append({"name": "sun_shadow_100m", "apply":func(on: bool) -> void: sun.directional_shadow_max_distance = shadow_dist if on else 100.0})
	var lantern := _player.get_node_or_null("Lantern") as Light3D
	if lantern and lantern.visible:
		toggles.append({"name": "lantern", "apply":func(on: bool) -> void: lantern.visible = on})

	var msaa := root.msaa_3d
	if msaa != Viewport.MSAA_DISABLED:
		toggles.append({"name": "msaa_3d", "apply":func(on: bool) -> void: root.msaa_3d = msaa if on else Viewport.MSAA_DISABLED})
	var ssaa := root.screen_space_aa
	if ssaa != Viewport.SCREEN_SPACE_AA_DISABLED:
		toggles.append({"name": "screen_space_aa", "apply":func(on: bool) -> void: root.screen_space_aa = ssaa if on else Viewport.SCREEN_SPACE_AA_DISABLED})
	# Not a feature: renders 3D at a quarter of the pixels. A big delta = the frame is bound by
	# per-pixel work (shading, overdraw, post); a small one = by geometry / draw calls / CPU.
	var scale := root.scaling_3d_scale
	toggles.append({"name": "render_scale_50", "apply":func(on: bool) -> void: root.scaling_3d_scale = scale if on else scale * 0.5})
	# --bench-only=<text>[,<text>...]: keep only the toggles whose name contains one of the texts
	# (a quick, targeted run).
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bench-only="):
			var only := arg.trim_prefix("--bench-only=").split(",", false)
			toggles = toggles.filter(func(t: Dictionary) -> bool:
				for text in only:
					if text in str(t.name):
						return true
				return false)
	return toggles

## Rendering only: colliders stay (the player is frozen, so they cost nothing to measure here).
func _set_layer_shown(on: bool, key: StringName) -> void:
	for node: Node3D in _layer_nodes[key]:
		node.visible = on
		if node is GrassField: # hidden grass must also stop its GPU cull pass
			node.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED

# ---------------------------------------------------------------- audit

## [layer key, asset label, lod] of a mesh node. Terrain3D instancer nodes go by mesh id (the J
## panel's layers; ids in none of them = "instanced_other"), anything else by its top-level node.
func _classify(node: Node, layer_by_id: Dictionary) -> Array:
	var path := str(_scene.get_path_to(node))
	if path.begins_with("Terrain3D/"):
		var parsed := LayerTogglePanel.parse_mmi_name(node.name)
		if parsed.x < 0:
			return [&"terrain_other", str(node.name), 0]
		var asset: Terrain3DMeshAsset = _terrain.get_assets().get_mesh_asset(parsed.x)
		return [layer_by_id.get(parsed.x, &"instanced_other"), "%d %s" % [parsed.x, asset.name if asset else "?"], parsed.y]
	var top := path.get_slice("/", 0)
	var layer: StringName = {CliffInstancer.CLIFF_DRESSING_NODE_NAME: &"cliffs", TerrainOutcrops.OUTCROP_NODE_NAME: &"outcrops", TerrainRoad.ROAD_MESH_NODE_NAME: &"road"}.get(top, StringName(top))
	var label := str(node.name)
	var lod := 0
	var at := label.rfind("_LOD")
	if at >= 0: # the cliff / outcrop GLBs ship their LOD chain as sibling nodes <name>_LOD0..3
		lod = label.substr(at + 4).to_int()
		label = label.substr(0, at)
	return [layer, label, lod]

## Per layer, per asset: instances, triangles of each LOD, instances x LOD 0 triangles. Built from
## what _audit_meshes collected. The grass is not made of nodes, so it is added from GrassField's
## own layer list with its buffer CAPACITY as the instance count (drawn counts: PerfDebug key K).
func _audit_layers() -> Array:
	var field := _scene.get_node_or_null(GrassField.NODE_NAME)
	if field:
		_layer_nodes[&"grass"] = [field]
		_layer_assets[&"grass"] = {}
		for l: Dictionary in field.get("_layers"):
			_layer_assets[&"grass"][l.name] = {"instances": int(l.capacity), "nodes": 1, "lod_tris": {0: _tri_count(l.mesh)}, "shadow_lods": {}}
	for key: StringName in [&"cliffs", &"outcrops"]: # one container node each: hide that, not every mesh
		var container_name: String = CliffInstancer.CLIFF_DRESSING_NODE_NAME if key == &"cliffs" else TerrainOutcrops.OUTCROP_NODE_NAME
		var container := _scene.get_node_or_null(container_name)
		if container and _layer_nodes.has(key):
			_layer_nodes[key] = [container]
	for key: StringName in _layer_nodes.keys():
		if not (key in [&"grass", &"cliffs", &"outcrops", &"instanced_other"] or not LayerTogglePanel.mesh_ids(key).is_empty()):
			_layer_nodes.erase(key) # player, road, ...: listed in the audit, not switched off
	var layers: Array = []
	for key: StringName in _layer_assets:
		var assets: Array = []
		var layer_tris := 0
		var layer_instances := 0
		var layer_nodes := 0
		for label: String in _layer_assets[key]:
			var a: Dictionary = _layer_assets[key][label]
			var lods: Array = a.lod_tris.keys()
			lods.sort()
			var shadow_lods: Array = a.shadow_lods.keys()
			shadow_lods.sort()
			var lod0: int = a.lod_tris.get(0, 0)
			assets.append({"asset": label, "instances": a.instances, "nodes": a.nodes, "lod_tris": lods.map(func(lod: int) -> int: return a.lod_tris[lod]), "shadow_lods": shadow_lods, "lod0_total_tris": lod0 * a.instances})
			layer_tris += lod0 * a.instances
			layer_instances += a.instances
			layer_nodes += a.nodes
		assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.lod0_total_tris > b.lod0_total_tris)
		layers.append({"layer": key, "instances": layer_instances, "nodes": layer_nodes, "lod0_total_tris": layer_tris, "assets": assets})
	layers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.lod0_total_tris > b.lod0_total_tris)
	return layers

## Every mesh drawn by the scene, grouped by Mesh resource. "tris" is LOD 0 of one instance, so
## total_tris is an upper bound (automatic mesh LODs and culling draw fewer).
func _audit_meshes() -> Dictionary:
	var layer_by_id := {}
	for spec in LayerTogglePanel.LAYERS:
		for mesh_id in LayerTogglePanel.mesh_ids(spec[0]):
			layer_by_id[mesh_id] = spec[0]
	var by_mesh := {}
	var stack: Array[Node] = [_scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children(true))
		var mesh: Mesh = null
		var count := 0
		var mmi := node as MultiMeshInstance3D
		var mi := node as MeshInstance3D
		if mmi and mmi.multimesh:
			mesh = mmi.multimesh.mesh
			count = mmi.multimesh.visible_instance_count if mmi.multimesh.visible_instance_count >= 0 else mmi.multimesh.instance_count
		elif mi:
			mesh = mi.mesh
			count = 1
		if mesh == null or count == 0:
			continue
		var gi := node as GeometryInstance3D
		var id := mesh.get_instance_id()
		if not by_mesh.has(id):
			var label := mesh.resource_path
			if label.is_empty():
				label = mesh.resource_name if not mesh.resource_name.is_empty() else str(node.name)
			by_mesh[id] = {"mesh": label, "tris": _tri_count(mesh), "surfaces": mesh.get_surface_count(), "instances": 0, "nodes": 0, "shadow_instances": 0, "visibility_range_end": 0.0, "sample_node": str(node.get_path())}
		var mats: Array = [gi.material_override, gi.material_overlay]
		for s in mesh.get_surface_count():
			mats.append(mesh.surface_get_material(s))
			if mi:
				mats.append(mi.get_surface_override_material(s))
		for mat in mats:
			if mat:
				_materials[mat] = true
		var casts_shadow := gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cls := _classify(node, layer_by_id)
		var layer: StringName = cls[0]
		var lod: int = cls[2]
		if not _layer_assets.has(layer):
			_layer_assets[layer] = {}
			_layer_nodes[layer] = []
		_layer_nodes[layer].append(node)
		if not _layer_assets[layer].has(cls[1]):
			_layer_assets[layer][cls[1]] = {"instances": 0, "nodes": 0, "lod_tris": {}, "shadow_lods": {}}
		var a: Dictionary = _layer_assets[layer][cls[1]]
		a.nodes += 1
		a.lod_tris[lod] = by_mesh[id].tris
		if lod == 0: # every LOD node of a cell holds the same instances; count them once
			a.instances += count
		if casts_shadow:
			a.shadow_lods[lod] = true
		var e: Dictionary = by_mesh[id]
		e.instances += count
		e.nodes += 1
		if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			e.shadow_instances += count
		e.visibility_range_end = maxf(e.visibility_range_end, gi.visibility_range_end)
	var rows: Array = by_mesh.values()
	var total_tris := 0
	var shadow_tris := 0
	var total_instances := 0
	var total_nodes := 0
	for e in rows:
		e["total_tris"] = e.tris * e.instances
		total_tris += e.total_tris
		shadow_tris += e.tris * e.shadow_instances
		total_instances += e.instances
		total_nodes += e.nodes
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.total_tris > b.total_tris)
	return {"unique_meshes": rows.size(), "mesh_nodes": total_nodes, "instances": total_instances, "total_tris": total_tris, "shadow_casting_tris": shadow_tris, "top": rows.slice(0, AUDIT_ROWS)}

static func _tri_count(mesh: Mesh) -> int:
	var am := mesh as ArrayMesh
	if am == null:
		@warning_ignore("integer_division")
		return mesh.get_faces().size() / 3
	var tris := 0
	for s in am.get_surface_count():
		var indices := am.surface_get_array_index_len(s)
		@warning_ignore("integer_division")
		tris += (indices if indices > 0 else am.surface_get_array_len(s)) / 3
	return tris

static func _bytes_per_pixel(format: int) -> float:
	match format:
		Image.FORMAT_DXT1, Image.FORMAT_RGTC_R, Image.FORMAT_ETC2_RGB8:
			return 0.5
		Image.FORMAT_DXT5, Image.FORMAT_DXT3, Image.FORMAT_RGTC_RG, Image.FORMAT_BPTC_RGBA, Image.FORMAT_BPTC_RGBF, Image.FORMAT_BPTC_RGBFU, Image.FORMAT_L8, Image.FORMAT_R8:
			return 1.0
		Image.FORMAT_RGBAH:
			return 8.0
		Image.FORMAT_RGBAF:
			return 16.0
	return 4.0 # RGBA8 / RGB8 (padded on the GPU) / unknown

## Every texture used by the audited meshes' materials and by the Terrain3D texture list, biggest
## first, and per folder. Memory is ESTIMATED (size x format x 4/3 for mipmaps); the measured
## total is each station's texture_mem_mb. Call after _audit_meshes (it collects the materials).
func _audit_textures() -> Dictionary:
	var rows: Array = []
	var by_dir := {}
	var total := 0
	var textures := {} # Texture2D -> true
	for mat: Material in _materials:
		for prop in mat.get_property_list(): # ShaderMaterial uniforms are listed too (shader_parameter/...)
			if prop.type == TYPE_OBJECT:
				var tex := mat.get(prop.name) as Texture2D
				if tex:
					textures[tex] = true
	var assets: Terrain3DAssets = _terrain.get_assets()
	for i in assets.get_texture_count():
		var asset: Terrain3DTextureAsset = assets.get_texture(i)
		for tex in [asset.albedo_texture, asset.normal_texture] if asset else []:
			if tex:
				textures[tex] = true
	for tex: Texture2D in textures:
		var path := tex.resource_path
		var format: int = tex.call("get_format") if tex.has_method("get_format") else -1
		var bytes := int(tex.get_width() * tex.get_height() * _bytes_per_pixel(format) * 4.0 / 3.0)
		total += bytes
		rows.append({"path": path, "width": tex.get_width(), "height": tex.get_height(), "format": format, "mb": _r(bytes / 1048576.0)})
		var dir := path.get_base_dir() if not path.is_empty() else "(generated at runtime)"
		by_dir[dir] = by_dir.get(dir, 0) + bytes
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.mb > b.mb)
	var dirs: Array = []
	for dir in by_dir:
		dirs.append({"dir": dir, "mb": _r(by_dir[dir] / 1048576.0)})
	dirs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.mb > b.mb)
	return {"count": rows.size(), "total_mb": _r(total / 1048576.0), "top": rows.slice(0, AUDIT_ROWS), "by_dir": dirs.slice(0, AUDIT_ROWS)}

# ---------------------------------------------------------------- report

static func _git_head() -> String:
	var git := ProjectSettings.globalize_path("res://") + ".git/"
	var head := FileAccess.get_file_as_string(git + "HEAD").strip_edges()
	if head.begins_with("ref: "):
		head = FileAccess.get_file_as_string(git + head.substr(5)).strip_edges()
	return head.left(8) if not head.is_empty() else "nogit"

static func _summary(report: Dictionary) -> String:
	var meta: Dictionary = report.meta
	var out: Array[String] = []
	out.append("==== PERF BENCH %s  git %s  %s ====" % [meta.label, meta.git, meta.time])
	out.append("viewport %dx%d, 3D scale %.3f, sun shadows %s, SSAO %s, %d post effects | %s | Godot %s | seed %d" % [meta.viewport[0], meta.viewport[1], meta.scaling_3d_scale, "on" if meta.sun_shadows else "OFF", "on" if meta.ssao else "OFF", meta.post_effects_on, meta.adapter, meta.godot, meta.seed])
	if meta.frame_capped:
		out.append("!! FRAME RATE CAPPED FROM OUTSIDE THE GAME (driver / overlay limiter): the frame columns show the cap -- read the GPU columns.")
	out.append("")
	out.append("STATIONS (ms)       frame    p95    p99  worst    GPU  CPUrender   draws  tris(M)  VRAM MB")
	for m in report.stations:
		out.append("%-17s %7.2f %6.2f %6.2f %6.2f %6.2f %10.2f %7d %8.2f %8.0f" % [m.name, m.frame_ms, m.p95_ms, m.p99_ms, m.max_ms, m.gpu_ms, m.cpu_render_ms, m.draw_calls, m.primitives / 1e6, m.video_mem_mb])
	for a in report.ablation:
		out.append("")
		out.append("ABLATION at %s -- baseline %.2f ms frame / %.2f ms GPU (end of pass: %.2f / %.2f)" % [a.station, a.baseline_start.frame_ms, a.baseline_start.gpu_ms, a.baseline_end.frame_ms, a.baseline_end.gpu_ms])
		out.append("switched off          frame saved  GPU saved  draws saved  tris saved(M)")
		for m in a.toggles:
			out.append("%-22s %10.2f %10.2f %12d %14.2f" % [m.name, m.delta_frame_ms, m.delta_gpu_ms, m.delta_draw_calls, m.delta_primitives / 1e6])
	var w: Dictionary = report.walk
	out.append("")
	out.append("WALK %.0f m in %.1f s: frame %.2f ms, p95 %.2f, p99 %.2f, worst %.2f | GPU %.2f | %d frames over 2x median, %d over 16.7 ms (of %d)" % [w.metres, w.seconds, w.frame_ms, w.p95_ms, w.p99_ms, w.max_ms, w.gpu_ms, w.hitches_over_2x_median, w.frames_over_16_7_ms, w.frames])
	var s: Dictionary = report.startup
	out.append("")
	out.append("STARTUP: _ready() began at %.2f s, took %.2f s, first frame at %.2f s, settled at %.2f s" % [s.ready_started_at_ms / 1000.0, s.ready_total_ms / 1000.0, s.first_frame_at_ms / 1000.0, s.settled_at_ms / 1000.0])
	for stage in s.stage_ms:
		out.append("  %-32s %6d ms" % [stage, s.stage_ms[stage]])
	var meshes: Dictionary = report.audit.meshes
	out.append("")
	out.append("MESHES: %d unique, %d nodes, %d instances, %.1f M tris at LOD 0 (%.1f M cast shadows). Top by total tris:" % [meshes.unique_meshes, meshes.mesh_nodes, meshes.instances, meshes.total_tris / 1e6, meshes.shadow_casting_tris / 1e6])
	for e in meshes.top.slice(0, 15):
		out.append("  %8.2f M = %7d tris x %6d inst (%d shadow)  %s" % [e.total_tris / 1e6, e.tris, e.instances, e.shadow_instances, e.mesh])
	out.append("")
	out.append("LAYERS -- instances x LOD 0 triangles (an upper bound: LODs and culling draw fewer; the ablation's \"tris saved\" is what is really drawn)")
	for layer in report.audit.layers:
		out.append("%-16s %8.2f M tris  %7d instances  %5d nodes" % [layer.layer, layer.lod0_total_tris / 1e6, layer.instances, layer.nodes])
		for a in layer.assets.slice(0, 8):
			out.append("    %8.2f M = %6d inst x %7d tris  LODs %s  shadow LODs %s  %s" % [a.lod0_total_tris / 1e6, a.instances, a.lod_tris[0] if not a.lod_tris.is_empty() else 0, "/".join(a.lod_tris.map(func(t: int) -> String: return str(t))), str(a.shadow_lods), a.asset])
		if layer.assets.size() > 8:
			out.append("    ... %d more in the .json" % (layer.assets.size() - 8))
	var textures: Dictionary = report.audit.textures
	out.append("")
	out.append("TEXTURES: %d used by mesh materials + terrain, ~%.0f MB estimated. Top folders:" % [textures.count, textures.total_mb])
	for d in textures.by_dir.slice(0, 15):
		out.append("  %8.1f MB  %s" % [d.mb, d.dir])
	return "\n".join(out) + "\n"
