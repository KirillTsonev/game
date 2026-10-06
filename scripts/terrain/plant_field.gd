## Plant renderer, GPU-culled (2026-10-06). Draws scattered plants that would otherwise be Terrain3D
## instancer nodes -- one node per 32 m cell, mesh and LOD, about 4 plants per draw call -- as ONE
## indirect MultiMesh per mesh and LOD, whatever the number of plants.
##
## A Node3D like GrassField (it needs _process). A scatter module hands a mesh's transforms to
## PlantField.submit() instead of the instancer; WorldGenerator then calls PlantField.spawn(). Each
## submitted mesh is a SET: its transforms go to the GPU once, and every frame a compute shader
## (shaders/foliage/plant_cull.glsl) picks each plant's LOD from its own distance to the camera,
## frustum-tests it and writes it into that LOD's instance buffer. Meshes, surface materials and
## LOD ranges are read from the Terrain3D mesh asset, so tools/setup_understory_assets.gd stays
## the one place they are set.
##
## What differs from Terrain3D's drawing: LODs switch (and the last range culls) per PLANT, at
## exactly the asset's range. Terrain3D measures to each 32 m cell's centre, so there a whole cell
## switches together, anywhere from about 22 m short of the range to 22 m past it.
##
## Phase 1 limits (see submit()): only assets that cast no shadows, with single-surface LOD meshes,
## no material override and at most MAX_LODS LODs. Anything else stays with Terrain3D. Shadows
## need a path of their own: a plant outside the view must still cast into it, and these buffers
## hold only what the camera sees.
##
## Compare / switch off: PerfDebug U moves the plants back to Terrain3D and here again in a running
## game; the user argument --plants-terrain3d starts the game with everything on Terrain3D (for
## benchmark pairs). PerfDebug's J panel and the benchmark's layer toggles call set_layer_shown().
class_name PlantField
extends Node3D

const NODE_NAME := "PlantField"
const CULL_SHADER_PATH := "res://shaders/foliage/plant_cull.glsl"
const MAX_LODS := 3 ## LOD outputs in plant_cull.glsl
const NEVER_CULLED := 1.0e9 ## range for a last LOD whose asset range is 0 (= drawn at any distance)
const CULL_MARGIN := 0.5 ## m added to each plant's bounding sphere for the frustum test
const FRAME_VEC4 := 7 ## plant_cull.glsl's frame buffer: 6 frustum planes + the camera position

## False = submit() refuses everything and the scatter modules use the Terrain3D instancer.
static var enabled := true
## mesh id -> {layer, id, asset, transforms}, filled by submit() during world generation.
static var _submitted: Dictionary = {}
## mesh id -> the asset's own cast-shadows setting, for the assets claim_shadow_casters() switched.
static var _claimed_shadow_modes: Dictionary = {}

var _terrain: Terrain3D
var _sets: Array[Dictionary] = [] # per mesh id: layer, id, name, transforms, count, radius, lods, push, RD rids
var _layer_shown: Dictionary = {} # layer key -> bool (missing = shown)
var _gpu_driven := true # false = the plants were handed back to Terrain3D (PerfDebug U)
var _switching := false # set_gpu_driven() is part-way through
var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline: RID
var _frame_buf: RID
var _dummy_inst: RID
var _dummy_cmd: RID
var _rt_ready := false

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	_submitted = {}
	_claimed_shadow_modes = {}
	enabled = not ("--plants-terrain3d" in OS.get_cmdline_user_args())

## Shadow-casting plants (2026-10-06, phase 2): PlantField draws the view, and the instancer keeps a
## copy that only casts -- a plant outside the view must still cast into it, and PlantField's
## buffers hold only what the camera sees. This switches those mesh assets to "shadows only" for
## this run (the game process's own copy; the asset file is not touched) and remembers what they
## were. Call it BEFORE anything is added to the instancer: every such change makes Terrain3D
## rebuild its nodes (0.3 s per asset once the world is scattered, measured).
static func claim_shadow_casters(assets: Terrain3DAssets, ids: Array[int]) -> void:
	if not enabled or assets == null:
		return
	for id in ids:
		var asset := assets.get_mesh_asset(id)
		if asset == null or asset.get_material_override() != null:
			continue
		var mode := asset.get_cast_shadows()
		if mode == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or mode == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			continue
		_claimed_shadow_modes[id] = mode
		asset.set_cast_shadows(GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)

## Takes over the drawing of one mesh asset's plants. Returns TRUE if the caller must NOT add them
## to the Terrain3D instancer, FALSE if it still must:
## - the asset cannot be drawn here as Terrain3D would (see the header): nothing is taken over;
## - the asset was claimed by claim_shadow_casters(): the view is drawn here, the instancer's copy
##   casts the shadows.
static func submit(layer: StringName, id: int, asset: Terrain3DMeshAsset, transforms: Array[Transform3D]) -> bool:
	if not enabled or asset == null or transforms.is_empty():
		return false
	if asset.get_material_override() != null:
		return false
	var shadow_mode: int = _claimed_shadow_modes.get(id, asset.get_cast_shadows())
	if shadow_mode != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and not _claimed_shadow_modes.has(id):
		return false # a shadow caster nobody claimed: Terrain3D draws it in full
	var lods := mini(asset.get_lod_count(), asset.get_last_lod() + 1)
	var drawable := lods >= 1 and lods <= MAX_LODS
	for i in (lods if drawable else 0):
		var mesh := asset.get_mesh(i) as Mesh
		if mesh == null or mesh.get_surface_count() != 1:
			drawable = false
	if not drawable:
		if _claimed_shadow_modes.has(id):
			push_error("PLANTS: mesh %d (%s) was claimed as a shadow caster but cannot be drawn by PlantField -- it will cast shadows and not be visible" % [id, asset.get_name()])
		return false
	_submitted[id] = {"layer": layer, "id": id, "asset": asset, "transforms": transforms, "shadow_mode": shadow_mode}
	return shadow_mode == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Adds a fresh PlantField under parent_node (deferred, like GrassField.spawn). No node if nothing
## was submitted.
static func spawn(parent_node: Node) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	if _submitted.is_empty():
		return
	var field := PlantField.new()
	field.name = NODE_NAME
	parent_node.add_child.call_deferred(field)

func _ready() -> void:
	process_priority = 100 # after the player has moved the camera this frame
	_terrain = get_parent().get_node_or_null("Terrain3D") as Terrain3D
	var ids: Array = _submitted.keys()
	ids.sort()
	for id: int in ids:
		_add_set(_submitted[id])
	_submitted = {}
	RenderingServer.call_on_render_thread(_rt_init)
	_apply_visibility()
	_update()
	var plants := 0
	var draws := 0
	var bytes := 0
	for s in _sets:
		plants += s.count
		draws += (s.lods as Array).size()
		bytes += s.count * 48 * ((s.lods as Array).size() + 1)
	print("PLANTS: field ready (GPU-culled) -- %d plants of %d meshes in %d draws, buffers %.1f MB" % [plants, _sets.size(), draws, bytes / 1048576.0])
	if "--plants-debug" in OS.get_cmdline_user_args():
		get_tree().create_timer(2.0).timeout.connect(request_debug_counts)
	if "--plants-debug-toggle" in OS.get_cmdline_user_args():
		_debug_toggle_test()

## DEBUG (--plants-debug-toggle): what PerfDebug U does, twice, with a line printed after each step
## -- to check from a command-line launch that the switch survives.
func _debug_toggle_test() -> void:
	await get_tree().create_timer(3.0).timeout
	for on: bool in [false, true]:
		print(await set_gpu_driven(on))
		await get_tree().create_timer(1.5).timeout
		print("[Plants] toggle test: still running 1.5 s after switching to %s" % ("PlantField" if on else "Terrain3D"))
		request_debug_counts()
	await get_tree().create_timer(1.0).timeout
	print("[Plants] toggle test: PASSED")

## One set = one mesh asset: its transform list + one indirect MultiMesh and RS instance per LOD.
func _add_set(sub: Dictionary) -> void:
	var asset: Terrain3DMeshAsset = sub.asset
	var transforms: Array[Transform3D] = sub.transforms
	var count := transforms.size()
	var lod_count := mini(asset.get_lod_count(), asset.get_last_lod() + 1)

	# The source list, in the MultiMesh TRANSFORM_3D layout (basis rows, origin in w).
	var src := PackedFloat32Array()
	src.resize(count * 12)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in count:
		var t := transforms[i]
		var o := i * 12
		src[o] = t.basis.x.x
		src[o + 1] = t.basis.y.x
		src[o + 2] = t.basis.z.x
		src[o + 3] = t.origin.x
		src[o + 4] = t.basis.x.y
		src[o + 5] = t.basis.y.y
		src[o + 6] = t.basis.z.y
		src[o + 7] = t.origin.y
		src[o + 8] = t.basis.x.z
		src[o + 9] = t.basis.y.z
		src[o + 10] = t.basis.z.z
		src[o + 11] = t.origin.z
		lo = lo.min(t.origin)
		hi = hi.max(t.origin)

	var radius := 0.0
	var ranges: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var meshes: Array[Mesh] = []
	for i in lod_count:
		var mesh := asset.get_mesh(i) as Mesh
		meshes.append(mesh)
		var aabb := mesh.get_aabb()
		for c in 8:
			radius = maxf(radius, aabb.get_endpoint(c).length())
		var r := asset.get_lod_range(i)
		ranges[i] = r if r > 0.0 else NEVER_CULLED
	# The plants' real extent: the scatter scales them up, so pad by a generous multiple of the radius.
	var pad := Vector3.ONE * (radius * 4.0 + 1.0)
	var bounds := AABB(lo - pad, hi - lo + pad * 2.0)

	var lods: Array[Dictionary] = []
	for i in lod_count:
		var mm := RenderingServer.multimesh_create()
		RenderingServer.multimesh_allocate_data(mm, count, RenderingServer.MULTIMESH_TRANSFORM_3D, false, false, true)
		RenderingServer.multimesh_set_mesh(mm, meshes[i].get_rid())
		RenderingServer.multimesh_set_custom_aabb(mm, bounds)
		var inst := RenderingServer.instance_create2(mm, get_world_3d().scenario)
		RenderingServer.instance_geometry_set_cast_shadows_setting(inst, RenderingServer.SHADOW_CASTING_SETTING_OFF)
		lods.append({"mesh": meshes[i], "mm": mm, "inst": inst, "range": ranges[i]})

	var push := PackedByteArray()
	push.resize(32)
	push.encode_u32(0, count)
	push.encode_u32(4, lod_count)
	push.encode_float(8, radius + CULL_MARGIN)
	push.encode_float(12, 0.0)
	for k in 4:
		push.encode_float(16 + k * 4, ranges[k])

	_sets.append({"layer": sub.layer, "id": sub.id, "name": asset.get_name(), "asset": asset, "shadow_mode": sub.shadow_mode, "transforms": transforms, "count": count,
		"radius": radius, "lods": lods, "push": push, "src_bytes": src.to_byte_array()})

func _process(_delta: float) -> void:
	_update()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_apply_visibility()
	elif what == NOTIFICATION_PREDELETE:
		var rd_rids: Array[RID] = []
		for s in _sets:
			for l: Dictionary in s.lods:
				RenderingServer.free_rid(l.inst)
				RenderingServer.free_rid(l.mm)
			if s.has("src_buf"):
				rd_rids.append(s.src_buf)
		for rid: RID in [_frame_buf, _dummy_inst, _dummy_cmd, _pipeline, _shader_rid]:
			if rid.is_valid():
				rd_rids.append(rid)
		RenderingServer.call_on_render_thread(Callable(GrassField, "_rt_free_rids").bind(rd_rids))

func _set_drawn(s: Dictionary) -> bool:
	return _gpu_driven and _layer_shown.get(s.layer, true) and is_inside_tree() and is_visible_in_tree()

func _apply_visibility() -> void:
	for s in _sets:
		var shown := _set_drawn(s)
		for l: Dictionary in s.lods:
			RenderingServer.instance_set_visible(l.inst, shown)

## Shows / hides every set of one layer (PerfDebug's J panel, the benchmark's layer toggles).
func set_layer_shown(layer: StringName, on: bool) -> void:
	_layer_shown[layer] = on
	_apply_visibility()

func has_layer(layer: StringName) -> bool:
	for s in _sets:
		if s.layer == layer:
			return true
	return false

## For the benchmark's audit (these plants are not nodes): one row per set.
func audit_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for s in _sets:
		var meshes: Array[Mesh] = []
		for l: Dictionary in s.lods:
			meshes.append(l.mesh)
		rows.append({"layer": s.layer, "label": "%d %s" % [s.id, s.name], "instances": s.count, "lod_meshes": meshes})
	return rows

## DEBUG (PerfDebug U): hands every set back to the Terrain3D instancer (on = false) or takes them
## again (on = true), to compare the two ways of drawing at the same spot. Causes a short hitch.
## Takes about 0.3 s per shadow-casting mesh (Terrain3D rebuilds its nodes each time), one per frame.
## `after_rebuild` is called after every rebuild, before the frame is drawn.
func set_gpu_driven(on: bool, after_rebuild: Callable = Callable()) -> String:
	if on == _gpu_driven or _terrain == null or _switching:
		return "[Plants] unchanged%s" % (" (a switch is still running)" if _switching else "")
	_switching = true # the switch takes a frame per shadow-casting mesh
	_gpu_driven = on
	var instancer := _terrain.get_instancer()
	var plants := 0
	var shadow_sets := 0
	for s in _sets:
		plants += s.count
		if s.shadow_mode != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			# The instancer keeps these plants either way: as shadow casters only, or drawn in full.
			# ONE asset per frame: Terrain3D rebuilds its nodes on each change, and 21 changes in one
			# frame closed the game a frame later with a stack overflow (0xC00000FD, no error printed).
			shadow_sets += 1
			(s.asset as Terrain3DMeshAsset).set_cast_shadows(GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if on else s.shadow_mode)
			if after_rebuild.is_valid():
				after_rebuild.call() # the rebuilt nodes are all visible: let the caller re-hide its layers
			await get_tree().process_frame
		elif on:
			instancer.clear_by_mesh(s.id)
		else:
			var colors := PackedColorArray()
			colors.resize(s.count)
			colors.fill(Color.WHITE)
			instancer.add_transforms(s.id, s.transforms, colors, true)
	var leftover := 0
	if on: # anything the instancer still has for the cleared ids must not be drawn twice
		var ids: Array[int] = []
		for s in _sets:
			if s.shadow_mode == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				ids.append(s.id)
		var stack: Array[Node] = [_terrain]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			stack.append_array(node.get_children(true))
			if node is MultiMeshInstance3D and LayerTogglePanel.parse_mmi_name(node.name).x in ids:
				(node as MultiMeshInstance3D).visible = false
				leftover += 1
	_apply_visibility()
	if after_rebuild.is_valid():
		after_rebuild.call()
	_switching = false
	return "[Plants] %d plants of %d meshes now drawn by %s%s" % [plants, _sets.size(), "the GPU-culled PlantField" if on else "Terrain3D (old path)",
		" -- %d Terrain3D nodes were left over and hidden" % leftover if leftover > 0 else ""]

func is_gpu_driven() -> bool:
	return _gpu_driven

## Main thread: this frame's camera, then queue the cull on the render thread.
func _update() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var active := PackedInt32Array()
	for i in _sets.size():
		if _set_drawn(_sets[i]):
			active.append(i)
	if active.is_empty():
		return
	var frame := PackedFloat32Array()
	frame.resize(FRAME_VEC4 * 4)
	var planes := cam.get_frustum()
	for k in 6:
		var pl: Plane = planes[k]
		frame[k * 4] = pl.normal.x
		frame[k * 4 + 1] = pl.normal.y
		frame[k * 4 + 2] = pl.normal.z
		frame[k * 4 + 3] = pl.d
	var eye := cam.global_position
	frame[24] = eye.x
	frame[25] = eye.y
	frame[26] = eye.z
	RenderingServer.call_on_render_thread(_rt_dispatch.bind(frame.to_byte_array(), active))

## ---------------------------------------------------------------- render thread ----

func _rt_init() -> void:
	_rd = RenderingServer.get_rendering_device()
	var shader_file: RDShaderFile = load(CULL_SHADER_PATH)
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("PLANTS: plant_cull.glsl failed to compile: %s" % spirv.compile_error_compute)
		return
	_shader_rid = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader_rid)
	_frame_buf = _rd.storage_buffer_create(FRAME_VEC4 * 16)
	_dummy_inst = _rd.storage_buffer_create(48)
	_dummy_cmd = _rd.storage_buffer_create(32)
	for s in _sets:
		var bytes: PackedByteArray = s.src_bytes
		s.src_buf = _rd.storage_buffer_create(bytes.size(), bytes)
		s.erase("src_bytes")
		var uniforms: Array[RDUniform] = [GrassField._storage_uniform(0, s.src_buf), GrassField._storage_uniform(1, _frame_buf)]
		for k in MAX_LODS:
			var inst_buf := _dummy_inst
			var cmd_buf := _dummy_cmd
			if k < (s.lods as Array).size():
				var l: Dictionary = s.lods[k]
				inst_buf = RenderingServer.multimesh_get_buffer_rd_rid(l.mm)
				cmd_buf = RenderingServer.multimesh_get_command_buffer_rd_rid(l.mm)
				l.cmd_buf = cmd_buf
			uniforms.append(GrassField._storage_uniform(2 + k * 2, inst_buf))
			uniforms.append(GrassField._storage_uniform(3 + k * 2, cmd_buf))
		s.uset = _rd.uniform_set_create(uniforms, _shader_rid, 0)
	_rt_ready = true

func _rt_dispatch(frame: PackedByteArray, active: PackedInt32Array) -> void:
	if not _rt_ready:
		return
	_rd.buffer_update(_frame_buf, 0, frame.size(), frame)
	for i in active:
		for l: Dictionary in _sets[i].lods:
			_rd.buffer_clear(l.cmd_buf, 4, 4) # the draw command's instance count; the shader counts it up
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	for i in active:
		var s: Dictionary = _sets[i]
		var push: PackedByteArray = s.push
		_rd.compute_list_bind_uniform_set(cl, s.uset, 0)
		_rd.compute_list_set_push_constant(cl, push, push.size())
		_rd.compute_list_dispatch(cl, int(ceil(float(s.count) / 64.0)), 1, 1)
	_rd.compute_list_end()

## DEBUG: reads back last frame's drawn counts per layer and LOD -- a GPU sync, dev only.
func request_debug_counts() -> void:
	if _gpu_driven:
		RenderingServer.call_on_render_thread(_rt_read_counts)
	else:
		print("[Plants] PlantField is drawing nothing (the plants are on Terrain3D)")
	# The instancer's nodes for the shadow-casting sets, by their cast_shadow value
	# (0 off, 1 on, 2 double-sided, 3 shadows only): all should read 3 while PlantField draws them.
	var ids: Array[int] = []
	for s in _sets:
		if s.shadow_mode != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			ids.append(s.id)
	if ids.is_empty() or _terrain == null:
		return
	var by_mode := {}
	var stack: Array[Node] = [_terrain]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children(true))
		var mmi := node as MultiMeshInstance3D
		if mmi and LayerTogglePanel.parse_mmi_name(mmi.name).x in ids:
			var key := "lod %d cast_shadow %d" % [LayerTogglePanel.parse_mmi_name(mmi.name).y, mmi.cast_shadow]
			by_mode[key] = int(by_mode.get(key, 0)) + 1
	print("[Plants] Terrain3D nodes of the %d shadow-casting meshes: %s" % [ids.size(), str(by_mode)])

func _rt_read_counts() -> void:
	if not _rt_ready:
		print("[Plants] culling not initialised")
		return
	var by_layer := {} # layer -> [plants, drawn LOD 0, 1, 2]
	for s in _sets:
		if not by_layer.has(s.layer):
			by_layer[s.layer] = [0, 0, 0, 0]
		by_layer[s.layer][0] += s.count
		for k in (s.lods as Array).size():
			by_layer[s.layer][1 + k] += _rd.buffer_get_data(s.lods[k].cmd_buf, 4, 4).decode_u32(0)
	for layer: StringName in by_layer:
		var c: Array = by_layer[layer]
		print("[Plants] %s: drawn %d of %d plants (LOD 0 / 1 / 2: %d / %d / %d)" % [layer, c[1] + c[2] + c[3], c[0], c[1], c[2], c[3]])
