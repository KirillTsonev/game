@tool
extends CompositorEffect
class_name PostProcessPainterlySAT

## Classic 4-region Kuwahara filter. Each pixel takes the mean colour of whichever of its four
## (stroke_radius + 1)^2 corner regions has the lowest luma variance.
##
## Since 2026-10-05 the region sums come from two separable box-sum passes (box_sum_h.glsl,
## box_sum_v.glsl: stroke_radius + 1 reads per pixel each) and kuwahara_box.glsl reads one value
## per region. Before that they came from a summed-area table (prefix_sum_h/v.glsl +
## kuwahara_sat.glsl, hence the class name, kept so compositor.tres still points here): its two
## build passes walked a whole row / column per thread and took 0.69 ms of this effect's 0.94 ms
## (GPU timestamps, 1620x800). The table's cost did not grow with stroke_radius; the box sums'
## does, linearly -- at the radius 4 used here they are far cheaper. They are also more exact:
## the table kept running sums over the whole frame in 32-bit floats.
##
## This is a separate, standalone effect -- it does not replace or modify
## PostProcessPainterlyEffect (the histogram one) elsewhere in this addon.

@export_group("Settings")

@export_range(1, 32, 1) var stroke_radius: int = 4:
	set(v):
		mutex.lock()
		stroke_radius = v
		mutex.unlock()

@export_range(0.0, 1.0, 0.01) var intensity: float = 1.0:
	set(v):
		mutex.lock()
		intensity = v
		mutex.unlock()

@export_range(0.0, 1.0, 0.01) var edge_sharpness: float = 0.0:
	set(v):
		mutex.lock()
		edge_sharpness = v
		mutex.unlock()

## DEBUG: set by the benchmark (scripts/debug/perf_bench.gd, _measure_post_passes) -- drops a GPU
## timestamp after each pass so their costs can be told apart.
var timestamps := false

var rd: RenderingDevice
var _shader_copy: RID
var _pipe_copy: RID
var _shader_h: RID
var _pipe_h: RID
var _shader_v: RID
var _pipe_v: RID
var _shader_kuwahara: RID
var _pipe_kuwahara: RID

var mutex: Mutex = Mutex.new()
var _original: RID
var _box_h: RID ## (width + radius) x height
var _box: RID ## (width + radius) x (height + radius)
var _last_size: Vector2i = Vector2i()
var _last_radius := -1

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	_create_pipeline()

## Returns [shader, pipeline] for a compute shader file, or two invalid RIDs.
func _load_compute(path: String) -> Array[RID]:
	var file: RDShaderFile = load(path)
	if file == null:
		return [RID(), RID()]
	var shader := rd.shader_create_from_spirv(file.get_spirv())
	return [shader, rd.compute_pipeline_create(shader) if shader.is_valid() else RID()]

func _create_pipeline() -> void:
	var dir := "res://addons/compositor_effects/painterly_sat/"
	var loaded := _load_compute("res://addons/compositor_effects/shared/copy.glsl")
	_shader_copy = loaded[0]
	_pipe_copy = loaded[1]
	loaded = _load_compute(dir + "box_sum_h.glsl")
	_shader_h = loaded[0]
	_pipe_h = loaded[1]
	loaded = _load_compute(dir + "box_sum_v.glsl")
	_shader_v = loaded[0]
	_pipe_v = loaded[1]
	loaded = _load_compute(dir + "kuwahara_box.glsl")
	_shader_kuwahara = loaded[0]
	_pipe_kuwahara = loaded[1]

func _make_texture(size: Vector2i, format: RenderingDevice.DataFormat) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = format
	fmt.width = size.x
	fmt.height = size.y
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	return rd.texture_create(fmt, RDTextureView.new())

func _image_set(shader_rid: RID, set_index: int, image: RID) -> RID:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 0
	u.add_id(image)
	return UniformSetCacheRD.get_cache(shader_rid, set_index, [u])

## One compute pass: `images` are bound as sets 0, 1, 2 ... in order; `groups` = dispatch size.
func _dispatch(shader_rid: RID, pipeline_rid: RID, images: Array[RID], groups: Vector2i, push_constant := PackedByteArray()) -> void:
	var cl: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	for i in images.size():
		rd.compute_list_bind_uniform_set(cl, _image_set(shader_rid, i, images[i]), i)
	if not push_constant.is_empty():
		rd.compute_list_set_push_constant(cl, push_constant, push_constant.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	rd.compute_list_end()

static func _groups(size: Vector2i, local: Vector2i) -> Vector2i:
	return Vector2i((size.x + local.x - 1) / local.x, (size.y + local.y - 1) / local.y)

func _render_callback(
	p_effect_callback_type: EffectCallbackType,
	p_render_data: RenderData
) -> void:
	if rd == null:
		return
	if not _pipe_copy.is_valid() or not _pipe_h.is_valid() or not _pipe_v.is_valid() or not _pipe_kuwahara.is_valid():
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return

	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	mutex.lock()
	var radius: int = maxi(stroke_radius, 1)
	var _intensity: float = intensity
	var _edge: float = edge_sharpness
	mutex.unlock()

	if size != _last_size or radius != _last_radius or not _original.is_valid() or not _box_h.is_valid() or not _box.is_valid():
		for old: RID in [_original, _box_h, _box]:
			if old.is_valid():
				rd.free_rid(old)
		_original = _make_texture(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		_box_h = _make_texture(size + Vector2i(radius, 0), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		_box = _make_texture(size + Vector2i(radius, radius), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		_last_size = size
		_last_radius = radius

	var push_constant := PackedFloat32Array([float(radius), _intensity, _edge, 0.0]).to_byte_array()
	var local := Vector2i(16, 16)

	for view: int in render_scene_buffers.get_view_count():
		var color_image: RID = render_scene_buffers.get_color_layer(view)
		if not color_image.is_valid():
			continue

		# 0) Preserve an untouched copy of the frame -- needed so the final
		#    pass's edge detection can safely read neighboring pixels while
		#    other invocations are writing their own result into color_image.
		_dispatch(_shader_copy, _pipe_copy, [color_image, _original], _groups(size, local))
		if timestamps:
			rd.capture_timestamp("painterly_sat/copy")

		# 1) Horizontal box sums: color_image -> _box_h.
		_dispatch(_shader_h, _pipe_h, [color_image, _box_h], _groups(size + Vector2i(radius, 0), local), push_constant)
		if timestamps:
			rd.capture_timestamp("painterly_sat/sum_h")

		# 2) Vertical box sums: _box_h -> _box, the sum of every (radius + 1)^2 box.
		_dispatch(_shader_v, _pipe_v, [_box_h, _box], _groups(size + Vector2i(radius, radius), local), push_constant)
		if timestamps:
			rd.capture_timestamp("painterly_sat/sum_v")

		# 3) Kuwahara from one box-sum read per region, plus optional edge-sharpening off the
		#    clean _original copy, written into color_image.
		_dispatch(_shader_kuwahara, _pipe_kuwahara, [_box, _original, color_image], _groups(size, local), push_constant)

