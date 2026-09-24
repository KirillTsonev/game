@tool
extends CompositorEffect
class_name PostProcessPainterlySAT

## Classic 4-region Kuwahara filter accelerated with a summed-area table
## (see prefix_sum_h.glsl / prefix_sum_v.glsl / kuwahara_sat.glsl). Cost is
## roughly INDEPENDENT of stroke_radius, unlike the histogram-based
## PostProcessPainterlyEffect elsewhere in this addon -- that one scans a
## full (2*radius+1)^2 neighborhood per pixel per frame, this one reads 4
## precomputed rectangle sums in O(1) regardless of radius. The trade is
## two extra full-resolution linear passes (building the SAT) plus somewhat
## reduced fp32 precision on very large accumulated sums (no Kahan/error
## compensation here -- shouldn't be visible at normal screen resolutions
## and HDR ranges, but worth knowing if banding ever shows up).
##
## This is a separate, standalone effect -- it does not replace or modify
## PostProcessPainterlyEffect. Add it to the WorldEnvironment's Compositor
## Effects list alongside (or instead of) the original to compare.

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
var _row_sum: RID
var _sat: RID
var _last_size: Vector2i = Vector2i()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	_create_pipeline()

func _create_pipeline() -> void:
	var copy_file: RDShaderFile = load("res://addons/compositor_effects/shared/copy.glsl")
	if copy_file != null:
		_shader_copy = rd.shader_create_from_spirv(copy_file.get_spirv())
		if _shader_copy.is_valid():
			_pipe_copy = rd.compute_pipeline_create(_shader_copy)

	var h_file: RDShaderFile = load("res://addons/compositor_effects/painterly_sat/prefix_sum_h.glsl")
	if h_file != null:
		_shader_h = rd.shader_create_from_spirv(h_file.get_spirv())
		if _shader_h.is_valid():
			_pipe_h = rd.compute_pipeline_create(_shader_h)

	var v_file: RDShaderFile = load("res://addons/compositor_effects/painterly_sat/prefix_sum_v.glsl")
	if v_file != null:
		_shader_v = rd.shader_create_from_spirv(v_file.get_spirv())
		if _shader_v.is_valid():
			_pipe_v = rd.compute_pipeline_create(_shader_v)

	var k_file: RDShaderFile = load("res://addons/compositor_effects/painterly_sat/kuwahara_sat.glsl")
	if k_file != null:
		_shader_kuwahara = rd.shader_create_from_spirv(k_file.get_spirv())
		if _shader_kuwahara.is_valid():
			_pipe_kuwahara = rd.compute_pipeline_create(_shader_kuwahara)

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

func _dispatch(shader_rid: RID, pipeline_rid: RID, src: RID, dst: RID, groups_x: int, groups_y: int) -> void:
	var u_src: RDUniform = RDUniform.new()
	u_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_src.binding = 0
	u_src.add_id(src)
	var set_src: RID = UniformSetCacheRD.get_cache(shader_rid, 0, [u_src])

	var u_dst: RDUniform = RDUniform.new()
	u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_dst.binding = 0
	u_dst.add_id(dst)
	var set_dst: RID = UniformSetCacheRD.get_cache(shader_rid, 1, [u_dst])

	var cl: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, set_src, 0)
	rd.compute_list_bind_uniform_set(cl, set_dst, 1)
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_end()

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

	if size != _last_size or not _original.is_valid() or not _row_sum.is_valid() or not _sat.is_valid():
		if _original.is_valid():
			rd.free_rid(_original)
		if _row_sum.is_valid():
			rd.free_rid(_row_sum)
		if _sat.is_valid():
			rd.free_rid(_sat)
		_original = _make_texture(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		_row_sum = _make_texture(size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		_sat = _make_texture(size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		_last_size = size

	mutex.lock()
	var _radius: float = float(stroke_radius)
	var _intensity: float = intensity
	var _edge: float = edge_sharpness
	mutex.unlock()

	var push_constant: PackedFloat32Array = PackedFloat32Array([_radius, _intensity, _edge, 0.0])

	var k_groups_x: int = (size.x + 15) / 16
	var k_groups_y: int = (size.y + 15) / 16
	var h_groups_y: int = (size.y + 63) / 64
	var v_groups_x: int = (size.x + 63) / 64

	for view: int in render_scene_buffers.get_view_count():
		var color_image: RID = render_scene_buffers.get_color_layer(view)
		if not color_image.is_valid():
			continue

		# 0) Preserve an untouched copy of the frame -- needed so the final
		#    pass's edge detection can safely read neighboring pixels while
		#    other invocations are writing their own result into color_image.
		_dispatch(_shader_copy, _pipe_copy, color_image, _original, k_groups_x, k_groups_y)

		# 1) Horizontal running sum: color_image -> _row_sum (one thread/row).
		_dispatch(_shader_h, _pipe_h, color_image, _row_sum, 1, h_groups_y)

		# 2) Vertical running sum: _row_sum -> _sat, completing the 2D SAT
		#    (one thread/column).
		_dispatch(_shader_v, _pipe_v, _row_sum, _sat, v_groups_x, 1)

		# 3) Classic 4-region Kuwahara via O(1) SAT rectangle queries, plus
		#    optional edge-sharpening off the clean _original copy, written
		#    into color_image.
		var u_sat: RDUniform = RDUniform.new()
		u_sat.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_sat.binding = 0
		u_sat.add_id(_sat)
		var set_sat: RID = UniformSetCacheRD.get_cache(_shader_kuwahara, 0, [u_sat])

		var u_orig: RDUniform = RDUniform.new()
		u_orig.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_orig.binding = 0
		u_orig.add_id(_original)
		var set_orig: RID = UniformSetCacheRD.get_cache(_shader_kuwahara, 1, [u_orig])

		var u_dst: RDUniform = RDUniform.new()
		u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_dst.binding = 0
		u_dst.add_id(color_image)
		var set_dst: RID = UniformSetCacheRD.get_cache(_shader_kuwahara, 2, [u_dst])

		var cl: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe_kuwahara)
		rd.compute_list_bind_uniform_set(cl, set_sat, 0)
		rd.compute_list_bind_uniform_set(cl, set_orig, 1)
		rd.compute_list_bind_uniform_set(cl, set_dst, 2)
		rd.compute_list_set_push_constant(cl, push_constant.to_byte_array(), 16)
		rd.compute_list_dispatch(cl, k_groups_x, k_groups_y, 1)
		rd.compute_list_end()
