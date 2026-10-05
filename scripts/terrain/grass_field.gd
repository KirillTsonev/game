## Grass groundcover -- STEP 2: the renderer, GPU-culled (2026-09-25). Reads GrassScatter's bake.
##
## A Node3D (not a static module like the rest of scripts/terrain/, because it needs _process)
## that follows the player. It owns a set of LAYERS; each layer is one INDIRECT MultiMesh drawn
## through a RenderingServer instance. Every frame a compute shader (shaders/grass/grass_cull.glsl)
## walks every grid cell of each layer around the player, keeps only instances that exist
## (density + patch maps), are inside the layer's distance band and inside the camera frustum,
## writes those straight into the MultiMesh instance buffer and sets the draw's instance count on
## the GPU. The CPU never touches a blade; nothing culled reaches the vertex stage.
##
## Grass = per-blade Ghost of Tsushima grass, a port of GodotGrass (shaders/grass/grass_blade.gdshader
## + its two blade meshes). Blade density falls with distance in bands (BLADE_BANDS) and the shader
## widens blades to compensate; unlike GodotGrass's hard tile LOD swaps (which pop), neighbouring
## bands cross-fade per blade (stochastic keep).
## History: v1 used GPUParticles3D (every slot processed + drawn, hidden ones as zero-scale) -- 35 M
## tris / 32 FPS vs 3 M / 60 FPS without grass (measured 2026-09-25), which is what the culling
## fixed. A second "tufts" style (procedural multi-blade tufts) existed for comparison until
## 2026-09-27; removed -- blades are the look.
## Created by WorldGenerator via GrassField.spawn(parent_node) right after GrassScatter.bake.
## Debug: PerfDebug J toggles the field, K prints drawn blades per band (GPU readback),
## Y opens the tuning panel (bands + widening, scripts/debug/grass_tuning_panel.gd).
class_name GrassField
extends Node3D

const NODE_NAME := "GrassField"
const CULL_SHADER_PATH := "res://shaders/grass/grass_cull.glsl"
const BLADE_SHADER := preload("res://shaders/grass/grass_blade.gdshader")

## Grass reaches RADIUS (2026-09-27: 250 m, Kirill's tuned bands below).
const RADIUS := 250.0
const FADE_BAND := 20.0 ## outer edge: blades thin to nothing over these metres
## Instance buffer size per layer, as a fraction of its grid slots. What's drawn is at most
## (frustum wedge of the layer's band) x (density keep). If K reports a layer at its capacity,
## instances are being dropped -- raise this.
const CAPACITY_FRACTION := 0.35
const MAP_AABB_HEIGHT := 400.0 ## culling box for the RS instances (the GPU decides the real set)
const PARAMS_VEC4 := 11 ## size of the cull shader's params buffer, in vec4s (see grass_cull.glsl)

## BLADE distance bands. `band` = cross-fade width just inside the band's outer edge (the next band
## fades in over the same metres); high-poly blade (9 tris) for the first two, one triangle beyond.
## The blade shader widens blades with camera distance (WIDEN_*) to cover the thinner bands.
## 2026-09-27: Kirill's values from the tuning panel (Y) -- dense grass to 100 m. (Was GodotGrass's
## layout: 0-12 @0.1, 12-40 @0.2, 40-70 @0.4, 70-100 @1.0, 100-150 @5.0.)
## 2026-09-28: Kirill's second tuning pass (denser far bands, widen max back up to 70 -- the far
## shimmer is handled by the wind fade below instead of by narrower blades).
const BLADE_BANDS: Array[Dictionary] = [
	{"name": "blades_0", "inner": 0.0, "outer": 50.0, "band": 3.0, "spacing": 0.1, "mesh": "high"},
	{"name": "blades_1", "inner": 50.0, "outer": 100.0, "band": 6.0, "spacing": 0.25, "mesh": "high"},
	{"name": "blades_2", "inner": 100.0, "outer": 150.0, "band": 8.0, "spacing": 0.5, "mesh": "low"},
	{"name": "blades_3", "inner": 150.0, "outer": 200.0, "band": 10.0, "spacing": 1.25, "mesh": "low"},
	{"name": "blades_4", "inner": 200.0, "outer": RADIUS, "band": FADE_BAND, "spacing": 3.0, "mesh": "low"},
]
## SHORT layer (2026-10-02, docs/forest_floor_plan.md step 4): low blades in the gaps BETWEEN the
## patches (grass_cull.glsl, pc.kind 1 near / 2 far), so a gap has a silhouette instead of a flat
## texture. One triangle per blade. `band` = the metres just inside `outer` over which the layer
## thins to nothing (and the next layer thins in). In the tuning panel since 2026-10-05 (the field
## builds from `short_layers`). Cost not measured yet -- K prints the drawn counts. Set SHORT_LAYER_ENABLED false to compare. (First try, one layer 0-40 m @ 0.1 m:
## too sparse, invisible from a distance -- see SHORT_* in grass_cull.glsl.)
const SHORT_LAYER_ENABLED := true
const SHORT_LAYERS: Array[Dictionary] = [
	{"name": "short_0", "kind": 1, "inner": 0.0, "outer": 37.5, "band": 5.0, "spacing": 0.07},
	{"name": "short_1", "kind": 2, "inner": 37.5, "outer": 75.0, "band": 15.0, "spacing": 0.2},
]
const SHORT_MAX_HEIGHT := 0.5 ## m -- for the cull sphere (1.01 m tallest blade x 0.45 + margin)
const SHORT_FAR_HALF_WIDTH := 1.0 ## m -- grass_cull.glsl SHORT_FAR_MAX x the 0.05 m blade half-width
## LIVE-TUNABLE copies (2026-09-27, grass tuning panel -- debug key Y): the field builds its blade
## layers from `blade_bands` (not BLADE_BANDS) and the widening curve from widen_*. Static so they
## survive the rebuild (GrassField.spawn) the panel does after a band change. Defaults = the consts.
const WIDEN_SCALE := 0.0333 ## blade width x (1 + min(pow(scale * dist, power), max)) -- GodotGrass's curve was 0.033 / 4 / 75
const WIDEN_POWER := 4.0
const WIDEN_MAX := 70.0
## WIND FADE (2026-09-28): wind sway is full up to WIND_FADE_START and gone by WIND_FADE_END (m
## from the camera). Far blades are metres wide (widening) and their sway read as a heat-haze
## "mirage" shimmer; per-blade motion isn't visible that far anyway. Live-tunable in the panel.
const WIND_FADE_START := 40.0
const WIND_FADE_END := 80.0
static var wind_fade_start := WIND_FADE_START
static var wind_fade_end := WIND_FADE_END
static var blade_bands: Array = BLADE_BANDS.duplicate(true)
static var short_layers: Array = SHORT_LAYERS.duplicate(true) ## live copy, in the panel since 2026-10-05
static var widen_scale := WIDEN_SCALE
static var widen_power := WIDEN_POWER
static var widen_max := WIDEN_MAX
## Blade-shader uniforms changed in the panel (name -> value); empty = the shader's own defaults.
static var shader_overrides: Dictionary = {}

## Current value of a grass_blade.gdshader uniform: the panel's override, else the shader default.
static func blade_param(param: StringName) -> Variant:
	return shader_overrides.get(param, RenderingServer.shader_get_parameter_default(BLADE_SHADER.get_rid(), param))

static func reset_tuning() -> void:
	shader_overrides = {}
	blade_bands = BLADE_BANDS.duplicate(true)
	short_layers = SHORT_LAYERS.duplicate(true)
	widen_scale = WIDEN_SCALE
	widen_power = WIDEN_POWER
	widen_max = WIDEN_MAX
	wind_fade_start = WIND_FADE_START
	wind_fade_end = WIND_FADE_END

static func widen_at(dist: float) -> float:
	return 1.0 + minf(pow(widen_scale * dist, widen_power), widen_max)

## Live: push the current widen_* to this field's blade material (no rebuild needed).
func apply_widen() -> void:
	if _blade_mat:
		_blade_mat.set_shader_parameter("widen_scale", widen_scale)
		_blade_mat.set_shader_parameter("widen_power", widen_power)
		_blade_mat.set_shader_parameter("widen_max", widen_max)
		_blade_mat.set_shader_parameter("wind_fade_start", wind_fade_start)
		_blade_mat.set_shader_parameter("wind_fade_end", maxf(wind_fade_end, wind_fade_start + 1.0))
		for param: StringName in shader_overrides:
			_blade_mat.set_shader_parameter(param, shader_overrides[param])

## Blades read the map's R as COVERAGE (fraction of ground inside patches -- see grass_cull.glsl);
## this scales it (1.0 = the bake's zone targets as-is).
const BLADE_DENSITY_SCALE := 1.0
const BLADE_MAX_HEIGHT := 1.15 ## m -- tallest blade (0.75 m mesh x 0.8 x tall 1.35 x stature 1.25 = 1.01) + margin, for the cull sphere

## (2026-09-27/28: sun-shadow culling -- skipping blades in terrain / rock / tree shadow -- was built,
## measured and removed: ~17% fewer blades mid-map saved only ~0.07 ms GPU. Not worth the load time.)

var debug_counts_text := "" ## filled by request_debug_counts() (render thread), read by PerfDebug K

var _player: Node3D
var _blade_mat: ShaderMaterial
var _layers: Array[Dictionary] = [] # per layer: mesh, mm, inst, n, capacity, base params, RD rids
var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline: RID
var _sampler: RID
var _rt_ready := false

## Adds a fresh GrassField under parent_node (deferred -- parent is still setting up children
## during WorldGenerator._ready()). No-op if the density bake didn't run.
static func spawn(parent_node: Node) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old" # free the name now -- the new field must be "GrassField" (PerfDebug looks it up)
		old.queue_free()
	if GrassScatter.density_texture == null:
		push_warning("GRASS: no density bake -- grass field not created")
		return
	var field := GrassField.new()
	field.name = NODE_NAME
	parent_node.add_child.call_deferred(field)

func _ready() -> void:
	_player = get_parent().get_node_or_null("Player") as Node3D
	if _player == null:
		push_warning("GRASS: no sibling Player -- grass field centred on the origin")

	# GodotGrass's mat_grass.tres noise, rebuilt in code: clump = cellular 256 seamless,
	# wind = perlin 512 seamless, freq 0.0275, fractal gain 0.1, domain warp amp 20 freq 0.005.
	_blade_mat = ShaderMaterial.new()
	_blade_mat.shader = BLADE_SHADER
	var clump := FastNoiseLite.new()
	clump.noise_type = FastNoiseLite.TYPE_CELLULAR
	_blade_mat.set_shader_parameter("clump_noise", ImageTexture.create_from_image(clump.get_seamless_image(256, 256)))
	var wind := FastNoiseLite.new()
	wind.noise_type = FastNoiseLite.TYPE_PERLIN
	wind.frequency = 0.0275
	wind.fractal_gain = 0.1
	wind.domain_warp_enabled = true
	wind.domain_warp_amplitude = 20.0
	wind.domain_warp_frequency = 0.005
	_blade_mat.set_shader_parameter("wind_noise", ImageTexture.create_from_image(wind.get_seamless_image(512, 512)))
	apply_widen()

	var blade_meshes := {"high": _build_blade_mesh(true), "low": _build_blade_mesh(false)}
	var prev_band := 0.0
	for b: Dictionary in blade_bands:
		var outer: float = b.outer
		var widen := widen_at(outer) # the blade shader's distance widening at this band's far edge
		_add_layer({
			"name": b.name, "spacing": float(b.spacing), "mesh": blade_meshes[b.mesh],
			"inner": float(b.inner), "inner_band": prev_band, "outer": outer, "band": float(b.band),
			"density_scale": BLADE_DENSITY_SCALE,
			"cull_radius": BLADE_MAX_HEIGHT + 0.05 * widen, "cull_lift": BLADE_MAX_HEIGHT * 0.5,
		})
		prev_band = b.band
	if SHORT_LAYER_ENABLED:
		prev_band = 0.0
		for s: Dictionary in short_layers:
			_add_layer({
				"name": s.name, "spacing": float(s.spacing), "mesh": blade_meshes["low"],
				"inner": float(s.inner), "inner_band": prev_band, "outer": float(s.outer), "band": float(s.band),
				"density_scale": BLADE_DENSITY_SCALE, "kind": int(s.kind),
				"cull_radius": SHORT_MAX_HEIGHT + (SHORT_FAR_HALF_WIDTH if s.kind == 2 else 0.05 * widen_at(s.outer)),
				"cull_lift": SHORT_MAX_HEIGHT * 0.5,
			})
			prev_band = s.band

	RenderingServer.call_on_render_thread(_rt_init)
	_apply_visibility()
	_update()
	var summary := PackedStringArray()
	var total_mb := 0.0
	for l in _layers:
		summary.append("%s %dx%d@%.2f m cap %d" % [l.name, l.n, l.n, l.spacing, l.capacity])
		total_mb += l.capacity * 64.0 / 1048576.0
	print("GRASS: field ready (GPU-culled) -- %d layers, instance buffers %.1f MB: %s" % [_layers.size(), total_mb, ", ".join(summary)])

## One layer = one indirect MultiMesh + RS instance + its static cull params.
func _add_layer(cfg: Dictionary) -> void:
	var spacing: float = cfg.spacing
	var outer: float = cfg.outer
	var n := int(ceil(2.0 * outer / spacing)) + 1
	var capacity := maxi(64, int(n * n * CAPACITY_FRACTION))
	var map_aabb := AABB(GrassScatter.map_corner + Vector3(0.0, -MAP_AABB_HEIGHT * 0.5, 0.0),
		Vector3(GrassScatter.map_size.x, MAP_AABB_HEIGHT, GrassScatter.map_size.y))

	var mm := RenderingServer.multimesh_create()
	RenderingServer.multimesh_allocate_data(mm, capacity, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true, true)
	RenderingServer.multimesh_set_mesh(mm, (cfg.mesh as Mesh).get_rid())
	RenderingServer.multimesh_set_custom_aabb(mm, map_aabb)
	var inst := RenderingServer.instance_create2(mm, get_world_3d().scenario)
	RenderingServer.instance_geometry_set_material_override(inst, _blade_mat.get_rid())
	RenderingServer.instance_geometry_set_cast_shadows_setting(inst, RenderingServer.SHADOW_CASTING_SETTING_OFF)

	# Everything in params except the frustum planes + centre, which change per frame.
	var base := PackedFloat32Array()
	base.resize(PARAMS_VEC4 * 4)
	base[6 * 4 + 3] = spacing
	base[7 * 4 + 0] = GrassScatter.map_corner.x
	base[7 * 4 + 1] = GrassScatter.map_corner.z
	base[7 * 4 + 2] = GrassScatter.map_size.x
	base[7 * 4 + 3] = GrassScatter.map_size.y
	base[8 * 4 + 0] = outer
	base[8 * 4 + 1] = float(cfg.band)
	base[8 * 4 + 2] = float(cfg.inner)
	base[8 * 4 + 3] = float(cfg.inner_band)
	base[9 * 4 + 0] = float(_layers.size() + 1) # seed
	base[9 * 4 + 1] = float(cfg.density_scale)
	base[10 * 4 + 0] = 0.02 # embed (m sunk into the ground)
	base[10 * 4 + 1] = float(cfg.cull_radius)
	base[10 * 4 + 2] = float(cfg.cull_lift)

	_layers.append({"name": cfg.name, "spacing": spacing, "mesh": cfg.mesh, "mm": mm, "inst": inst,
		"n": n, "capacity": capacity, "base": base, "kind": int(cfg.get("kind", 0))})

func _process(_delta: float) -> void:
	_update()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_apply_visibility()
	elif what == NOTIFICATION_PREDELETE:
		var rd_rids: Array[RID] = []
		for l in _layers:
			RenderingServer.free_rid(l.inst)
			RenderingServer.free_rid(l.mm)
			if l.has("params_buf"):
				rd_rids.append(l.params_buf)
				rd_rids.append(l.stats_buf)
		if _pipeline.is_valid():
			rd_rids.append(_pipeline)
		if _shader_rid.is_valid():
			rd_rids.append(_shader_rid)
		if _sampler.is_valid():
			rd_rids.append(_sampler)
		RenderingServer.call_on_render_thread(Callable(GrassField, "_rt_free_rids").bind(rd_rids))

func _apply_visibility() -> void:
	var shown := is_inside_tree() and is_visible_in_tree()
	for l in _layers:
		RenderingServer.instance_set_visible(l.inst, shown)

## Main thread: gather this frame's camera + player state and queue the cull on the render thread.
func _update() -> void:
	var p := _player.global_position if _player else Vector3.ZERO
	_blade_mat.set_shader_parameter("player_position", p)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var planes := cam.get_frustum()
	var frames := {} # layer index -> params bytes
	for i in _layers.size():
		var l: Dictionary = _layers[i]
		var params: PackedFloat32Array = (l.base as PackedFloat32Array).duplicate()
		for k in 6:
			var pl: Plane = planes[k]
			params[k * 4 + 0] = pl.normal.x
			params[k * 4 + 1] = pl.normal.y
			params[k * 4 + 2] = pl.normal.z
			params[k * 4 + 3] = pl.d
		params[6 * 4 + 0] = p.x
		params[6 * 4 + 1] = p.y
		params[6 * 4 + 2] = p.z
		# 2026-09-29: the blade widening curve (read-only copy, values unchanged) so the cull can
		# drop far, widened blades standing on a crest -- see "crest drop" in grass_cull.glsl.
		params[9 * 4 + 2] = widen_scale
		params[9 * 4 + 3] = widen_power
		params[10 * 4 + 3] = widen_max
		frames[i] = params.to_byte_array()
	RenderingServer.call_on_render_thread(_rt_dispatch.bind(frames))

## ---------------------------------------------------------------- render thread ----

func _rt_init() -> void:
	_rd = RenderingServer.get_rendering_device()
	var shader_file: RDShaderFile = load(CULL_SHADER_PATH)
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("GRASS: grass_cull.glsl failed to compile: %s" % spirv.compile_error_compute)
		return
	_shader_rid = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader_rid)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var density_rd := RenderingServer.texture_get_rd_texture(GrassScatter.density_texture.get_rid())
	var height_rd := RenderingServer.texture_get_rd_texture(GrassScatter.height_texture.get_rid())
	var patch_rd := RenderingServer.texture_get_rd_texture(GrassScatter.patch_texture.get_rid()) # 2026-09-27: shared with TerrainGroundPaint
	for l in _layers:
		l.params_buf = _rd.storage_buffer_create(PARAMS_VEC4 * 16)
		l.stats_buf = _rd.storage_buffer_create(4)
		var uniforms: Array[RDUniform] = [
			_storage_uniform(0, RenderingServer.multimesh_get_buffer_rd_rid(l.mm)),
			_storage_uniform(1, RenderingServer.multimesh_get_command_buffer_rd_rid(l.mm)),
			_storage_uniform(2, l.stats_buf),
			_storage_uniform(3, l.params_buf),
			_texture_uniform(4, density_rd),
			_texture_uniform(5, height_rd),
			_texture_uniform(6, patch_rd),
		]
		l.uset = _rd.uniform_set_create(uniforms, _shader_rid, 0)
	_rt_ready = true

func _rt_dispatch(frames: Dictionary) -> void:
	if not _rt_ready or frames.is_empty():
		return
	for i: int in frames:
		var l: Dictionary = _layers[i]
		var bytes: PackedByteArray = frames[i]
		_rd.buffer_update(l.params_buf, 0, bytes.size(), bytes)
		_rd.buffer_clear(l.stats_buf, 0, 4)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	for i: int in frames:
		var l: Dictionary = _layers[i]
		var push := PackedInt32Array([0, l.capacity, l.n, l.kind]).to_byte_array()
		_rd.compute_list_bind_uniform_set(cl, l.uset, 0)
		_rd.compute_list_set_push_constant(cl, push, push.size())
		_rd.compute_list_dispatch(cl, int(ceil(float(l.n * l.n) / 64.0)), 1, 1)
	_rd.compute_list_add_barrier(cl)
	for i: int in frames:
		var l: Dictionary = _layers[i]
		var push := PackedInt32Array([1, l.capacity, l.n, 0]).to_byte_array()
		_rd.compute_list_bind_uniform_set(cl, l.uset, 0)
		_rd.compute_list_set_push_constant(cl, push, push.size())
		_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_end()

## DEBUG: GrassScatter.debug_road_check() via this node (callable from the MCP runtime).
func debug_road_check() -> String:
	return GrassScatter.debug_road_check()

## DEBUG (PerfDebug K): reads back last frame's per-layer counts -- a GPU sync, dev only.
func request_debug_counts() -> void:
	RenderingServer.call_on_render_thread(_rt_read_counts)

func _rt_read_counts() -> void:
	if not _rt_ready:
		debug_counts_text = "[Grass] culling not initialised"
		return
	var parts := PackedStringArray()
	var total := 0
	for l in _layers:
		var raw := _rd.buffer_get_data(l.stats_buf).decode_u32(0)
		var drawn := mini(raw, l.capacity)
		total += drawn
		parts.append("%s %d/%d%s" % [l.name, drawn, l.capacity, "  ** AT CAPACITY, %d dropped **" % (raw - l.capacity) if raw > l.capacity else ""])
	debug_counts_text = "[Grass] drawn %d blades (%s)" % [total, ", ".join(parts)]
	print(debug_counts_text)

static func _rt_free_rids(rids: Array[RID]) -> void:
	var rd := RenderingServer.get_rendering_device()
	for r in rids:
		if r.is_valid():
			rd.free_rid(r)

static func _storage_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u

func _texture_uniform(binding: int, texture_rd: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(texture_rd)
	return u

## ---------------------------------------------------------------- meshes ----

## GodotGrass's blades, rebuilt from their .obj data (assets/grass/grass_high.obj / grass_low.obj):
## a 0.10 m wide, 0.75 m tall tapered strip -- high = rows at y 0/.15/.3/.45/.6 + tip (9 tris),
## low = one triangle. UV.y = 1 at the base, 0 at the tip (Godot's OBJ import flips V);
## UV.x = 0/1 across the blade (tip 0.5). Normal +Z. Tangents generated (the shader uses ANISOTROPY).
static func _build_blade_mesh(high: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# (Typed arrays built explicitly -- a ternary between two array literals yields an untyped
	# Array, which GDScript refuses to assign to Array[float] at runtime.)
	var rows: Array[float] = [0.0]
	var half_widths: Array[float] = [0.05]
	if high:
		rows.assign([0.0, 0.15, 0.3, 0.45, 0.6])
		half_widths.assign([0.05, 0.0475, 0.0425, 0.034167, 0.023333])
	for r in rows.size():
		for side in [-1.0, 1.0]:
			st.set_normal(Vector3(0.0, 0.0, 1.0))
			st.set_uv(Vector2(0.5 + side * 0.5, 1.0 - rows[r] / 0.75))
			st.add_vertex(Vector3(half_widths[r] * side, rows[r], 0.0))
	st.set_normal(Vector3(0.0, 0.0, 1.0))
	st.set_uv(Vector2(0.5, 0.0))
	st.add_vertex(Vector3(0.0, 0.75, 0.0))
	for r in rows.size() - 1:
		var l0 := r * 2
		st.add_index(l0)
		st.add_index(l0 + 1)
		st.add_index(l0 + 3)
		st.add_index(l0)
		st.add_index(l0 + 3)
		st.add_index(l0 + 2)
	var last := (rows.size() - 1) * 2
	st.add_index(last)
	st.add_index(last + 1)
	st.add_index(rows.size() * 2)
	st.generate_tangents()
	return st.commit()
