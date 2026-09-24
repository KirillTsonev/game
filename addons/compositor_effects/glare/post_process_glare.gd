@tool
extends CompositorEffect
class_name PostProcessGlare

## Star/streak glare.
## Default path (fast): 3 compute passes --
##   1. glare_prefilter.glsl : bright-pass + downsample to 1/resolution_divisor
##   2. glare_rays.glsl      : ray streaks at reduced res, hardware bilinear taps
##   3. glare_composite.glsl : bilinear upsample + additive/screen blend
## legacy_full_res = true runs the original single full-res pass (glare.glsl),
## ~384 texel reads per pixel at the project's settings -- kept for A/B.

enum BlendMode { ADDITIVE, SCREEN }

@export_group("Settings")

@export_range(0.0, 10.0, 0.01) var threshold: float = 1.0:
	set(v):
		mutex.lock()
		threshold = v
		mutex.unlock()

@export_range(0.0, 5.0, 0.01) var intensity: float = 1.0:
	set(v):
		mutex.lock()
		intensity = v
		mutex.unlock()

@export_range(1.0, 2000.0, 1.0) var glare_size: float = 150.0:
	set(v):
		mutex.lock()
		glare_size = v
		mutex.unlock()

@export_range(1, 8, 1) var ray_axes: int = 2:
	set(v):
		mutex.lock()
		ray_axes = v
		mutex.unlock()

@export var tint_color: Color = Color.WHITE:
	set(v):
		mutex.lock()
		tint_color = v
		mutex.unlock()

## [sky-occlusion] 2026-09-24 local edit: how much of the SKY-sourced glare (sun/moon disc)
## is removed where solid geometry is in front (full-res depth test, so thin trunks count).
## 0 = original behaviour, 1 = none over geometry. Glare from bright geometry is unaffected.
## Fast path only (legacy_full_res ignores it).
@export_range(0.0, 1.0, 0.01) var sky_occlusion: float = 0.85:
	set(v):
		mutex.lock()
		sky_occlusion = v
		mutex.unlock()

@export_group("Advanced Settings")

@export_subgroup("Shape")

@export_range(0.0, 360.0, 0.1) var rotation_degrees: float = 0.0:
	set(v):
		mutex.lock()
		rotation_degrees = v
		mutex.unlock()

@export_range(4, 128, 1) var samples_per_arm: int = 32:
	set(v):
		mutex.lock()
		samples_per_arm = v
		mutex.unlock()

@export_range(0.1, 10.0, 0.1) var falloff_curve: float = 2.0:
	set(v):
		mutex.lock()
		falloff_curve = v
		mutex.unlock()

@export_range(0.0, 2.0, 0.01) var knee: float = 0.2:
	set(v):
		mutex.lock()
		knee = v
		mutex.unlock()

@export_range(0.0, 1.0, 0.01) var asymmetry: float = 0.0:
	set(v):
		mutex.lock()
		asymmetry = v
		mutex.unlock()

@export_subgroup("Chromatic")

@export_range(0.0, 1.0, 0.01) var chroma_shift: float = 0.0:
	set(v):
		mutex.lock()
		chroma_shift = v
		mutex.unlock()

@export_subgroup("Animation")

@export_range(0.0, 180.0, 0.5) var rotation_speed: float = 0.0:
	set(v):
		mutex.lock()
		rotation_speed = v
		mutex.unlock()

@export_subgroup("Blend")

@export var blend_mode: BlendMode = BlendMode.ADDITIVE:
	set(v):
		mutex.lock()
		blend_mode = v
		mutex.unlock()

@export_subgroup("Performance")

## Glare is computed at 1/N resolution then upsampled. 4 = quarter res.
@export_range(1, 4, 1) var resolution_divisor: int = 4:
	set(v):
		mutex.lock()
		resolution_divisor = v
		mutex.unlock()

## A/B: run the original single full-res pass instead.
@export var legacy_full_res: bool = false:
	set(v):
		mutex.lock()
		legacy_full_res = v
		mutex.unlock()

var rd: RenderingDevice
var mutex: Mutex = Mutex.new()

# legacy
var shader: RID
var pipeline: RID
var _shader_copy: RID
var _pipe_copy: RID
var _intermediate: RID
var _last_size: Vector2i = Vector2i()

# fast path
var _sh_pre: RID
var _pl_pre: RID
var _sh_rays: RID
var _pl_rays: RID
var _sh_comp: RID
var _pl_comp: RID
var _sampler: RID
var _bright: RID
var _glare: RID
var _small_key: Vector3i = Vector3i()  # full w, full h, divisor

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	_create_pipeline()
	_create_fast_pipelines()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for r in [_bright, _glare, _intermediate, _sampler, _sh_pre, _sh_rays, _sh_comp, shader, _shader_copy]:
			if r.is_valid():
				rd.free_rid(r)

func _create_pipeline() -> void:
	var shader_file: RDShaderFile = load("res://addons/compositor_effects/glare/glare.glsl")
	if shader_file == null:
		return

	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		return

	pipeline = rd.compute_pipeline_create(shader)

	var copy_file: RDShaderFile = load("res://addons/compositor_effects/shared/copy.glsl")
	if copy_file != null:
		_shader_copy = rd.shader_create_from_spirv(copy_file.get_spirv())
		if _shader_copy.is_valid():
			_pipe_copy = rd.compute_pipeline_create(_shader_copy)

func _load_compute(path: String) -> Array:
	var f: RDShaderFile = load(path)
	if f == null:
		push_warning("PostProcessGlare: could not load %s" % path)
		return [RID(), RID()]
	var spirv: RDShaderSPIRV = f.get_spirv()
	if spirv.compile_error_compute != "":
		push_warning("PostProcessGlare: %s compile error:\n%s" % [path, spirv.compile_error_compute])
		return [RID(), RID()]
	var sh := rd.shader_create_from_spirv(spirv)
	if not sh.is_valid():
		return [RID(), RID()]
	return [sh, rd.compute_pipeline_create(sh)]

func _create_fast_pipelines() -> void:
	var a := _load_compute("res://addons/compositor_effects/glare/glare_prefilter.glsl")
	_sh_pre = a[0]; _pl_pre = a[1]
	a = _load_compute("res://addons/compositor_effects/glare/glare_rays.glsl")
	_sh_rays = a[0]; _pl_rays = a[1]
	a = _load_compute("res://addons/compositor_effects/glare/glare_composite.glsl")
	_sh_comp = a[0]; _pl_comp = a[1]
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(ss)

func _fast_ready() -> bool:
	return _pl_pre.is_valid() and _pl_rays.is_valid() and _pl_comp.is_valid() and _sampler.is_valid()

func _small_tex(w: int, h: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = w
	fmt.height = h
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	return rd.texture_create(fmt, RDTextureView.new())

func _image_uniform(rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 0
	u.add_id(rid)
	return u

func _sampled_uniform(rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 0
	u.add_id(_sampler)
	u.add_id(rid)
	return u

func _dispatch(pl: RID, sh: RID, set0: RDUniform, set1: RDUniform, push: PackedFloat32Array, gx: int, gy: int, set2: RDUniform = null) -> void:
	var s0: RID = UniformSetCacheRD.get_cache(sh, 0, [set0])
	var s1: RID = UniformSetCacheRD.get_cache(sh, 1, [set1])
	var bytes := push.to_byte_array()
	var cl: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pl)
	rd.compute_list_bind_uniform_set(cl, s0, 0)
	rd.compute_list_bind_uniform_set(cl, s1, 1)
	if set2 != null:  # [sky-occlusion] depth for prefilter + composite
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(sh, 2, [set2]), 2)
	rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	rd.compute_list_dispatch(cl, gx, gy, 1)
	rd.compute_list_end()

func _render_callback(
	p_effect_callback_type: EffectCallbackType,
	p_render_data: RenderData
) -> void:
	if rd == null:
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return

	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var t: float = float(Time.get_ticks_msec()) / 1000.0

	mutex.lock()
	var _threshold: float = threshold
	var _intensity: float = intensity
	var _size: float = glare_size
	var _samples: float = float(samples_per_arm)
	var _rays: float = float(ray_axes)
	var _angle: float = deg_to_rad(rotation_degrees)
	var _tint: Color = tint_color
	var _falloff: float = falloff_curve
	var _knee: float = knee
	var _chroma: float = chroma_shift
	var _rspeed: float = deg_to_rad(rotation_speed)
	var _blend: float = float(blend_mode)
	var _asym: float = asymmetry
	var _div: int = resolution_divisor
	var _legacy: bool = legacy_full_res
	var _sky_occ: float = sky_occlusion  # [sky-occlusion]
	mutex.unlock()

	if _legacy or not _fast_ready():
		_render_legacy(render_scene_buffers, size, PackedFloat32Array([
			_threshold, _intensity, _size, _samples,
			_rays, _angle, _tint.r, _tint.g,
			_tint.b, _falloff, _knee, _chroma,
			_rspeed, t, _blend, _asym,
		]))
		return

	var sw: int = (size.x + _div - 1) / _div
	var sh: int = (size.y + _div - 1) / _div
	var key := Vector3i(size.x, size.y, _div)
	if key != _small_key or not _bright.is_valid() or not _glare.is_valid():
		if _bright.is_valid():
			rd.free_rid(_bright)
		if _glare.is_valid():
			rd.free_rid(_glare)
		_bright = _small_tex(sw, sh)
		_glare = _small_tex(sw, sh)
		_small_key = key

	var push_pre := PackedFloat32Array([_threshold, _knee, float(_div), 0.0])
	var push_rays := PackedFloat32Array([
		_size, _samples, _rays, _angle,
		_tint.r, _tint.g, _tint.b, _falloff,
		_chroma, _rspeed, t, _asym,
		_intensity, float(_div), float(size.x), float(size.y),
	])
	var push_comp := PackedFloat32Array([_blend, _sky_occ, 0.0, 0.0])  # [sky-occlusion] slot 1
	var sgx: int = (sw + 7) / 8
	var sgy: int = (sh + 7) / 8
	var fgx: int = (size.x + 7) / 8
	var fgy: int = (size.y + 7) / 8

	for view: int in render_scene_buffers.get_view_count():
		var color_image: RID = render_scene_buffers.get_color_layer(view)
		var depth_u := _sampled_uniform(render_scene_buffers.get_depth_layer(view))  # [sky-occlusion]
		_dispatch(_pl_pre, _sh_pre, _image_uniform(color_image), _image_uniform(_bright), push_pre, sgx, sgy, depth_u)
		_dispatch(_pl_rays, _sh_rays, _sampled_uniform(_bright), _image_uniform(_glare), push_rays, sgx, sgy)
		_dispatch(_pl_comp, _sh_comp, _image_uniform(color_image), _sampled_uniform(_glare), push_comp, fgx, fgy, depth_u)

## Original single full-res pass, unchanged (A/B via legacy_full_res).
func _render_legacy(render_scene_buffers: RenderSceneBuffersRD, size: Vector2i, push_constant: PackedFloat32Array) -> void:
	if not shader.is_valid() or not pipeline.is_valid():
		return

	if size != _last_size or not _intermediate.is_valid():
		if _intermediate.is_valid():
			rd.free_rid(_intermediate)
		var fmt := RDTextureFormat.new()
		fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		fmt.width = size.x
		fmt.height = size.y
		fmt.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		)
		_intermediate = rd.texture_create(fmt, RDTextureView.new())
		_last_size = size

	var x_groups: int = (size.x + 15) / 16
	var y_groups: int = (size.y + 15) / 16

	for view: int in render_scene_buffers.get_view_count():
		var color_image: RID = render_scene_buffers.get_color_layer(view)

		if _pipe_copy.is_valid():
			var u_cp_src: RDUniform = RDUniform.new()
			u_cp_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u_cp_src.binding = 0
			u_cp_src.add_id(color_image)
			var set_cp_src: RID = UniformSetCacheRD.get_cache(_shader_copy, 0, [u_cp_src])

			var u_cp_dst: RDUniform = RDUniform.new()
			u_cp_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u_cp_dst.binding = 0
			u_cp_dst.add_id(_intermediate)
			var set_cp_dst: RID = UniformSetCacheRD.get_cache(_shader_copy, 1, [u_cp_dst])

			var cl_copy: int = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl_copy, _pipe_copy)
			rd.compute_list_bind_uniform_set(cl_copy, set_cp_src, 0)
			rd.compute_list_bind_uniform_set(cl_copy, set_cp_dst, 1)
			rd.compute_list_dispatch(cl_copy, x_groups, y_groups, 1)
			rd.compute_list_end()

		var u_src: RDUniform = RDUniform.new()
		u_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_src.binding = 0
		u_src.add_id(_intermediate)
		var set_src: RID = UniformSetCacheRD.get_cache(shader, 0, [u_src])

		var u_dst: RDUniform = RDUniform.new()
		u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_dst.binding = 0
		u_dst.add_id(color_image)
		var set_dst: RID = UniformSetCacheRD.get_cache(shader, 1, [u_dst])

		var compute_list: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set_src, 0)
		rd.compute_list_bind_uniform_set(compute_list, set_dst, 1)
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), 64)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()
