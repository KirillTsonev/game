## Clouds in the night sky (2026-10-06): drives the cloud part of shaders/moon_sky.gdshader and dims
## the moonlight while a cloud is in front of the moon.
##
## The shader draws two drifting layers of one noise texture. This node builds that texture, moves
## the drift every frame and switches the clouds on (cloud_amount; the material keeps 0, so the
## editor and a run without this node show a clear sky). It also works out the cloud density in the
## moon's direction with the same maths as the shader's cloud_density() -- change both together --
## and scales the DirectionalLight3D's energy by it. A cloud's shadow is far wider than the view, so
## on the ground it reads as the whole scene dimming, which is what this does.
##
## The look (coverage, softness, scale, opacity, colours) is set on the sky material in main.tscn's
## WorldEnvironment; the values here are the movement and the dimming. Nothing is saved.
## WorldGenerator spawns it. Compare / switch off: the user argument --no-clouds.
class_name CloudSky
extends Node

const NODE_NAME := "CloudSky"
const NOISE_SIZE := 256

## Where the clouds drift to, in world x / z: the way the grass gusts travel (shaders/wind.gdshaderinc).
@export var drift_direction := Vector2(-1.0, -1.0)
## Drift in noise-texture widths per second: 0.004 = the pattern repeats overhead every ~4 minutes.
@export var drift_speed := 0.004
## Share of the moonlight left under the thickest cloud (at cloud_opacity 1).
@export_range(0.0, 1.0) var min_moonlight := 0.35
## Seconds the moonlight takes to follow the cloud in front of the moon.
@export var dim_smoothing := 1.5

var _material: ShaderMaterial
var _light: DirectionalLight3D
var _rest_energy := 1.0
var _noise_data: PackedByteArray
var _offset := Vector2.ZERO
var _dim := 0.0
# Look values read back from the material, refreshed twice a second (live tuning in the inspector).
var _look: Dictionary = {}
var _look_age := INF

## Adds the node to `parent_node` (deferred), unless switched off or the scene has no moon sky.
static func spawn(parent_node: Node) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	if "--no-clouds" in OS.get_cmdline_user_args():
		return
	var clouds := CloudSky.new()
	clouds.name = NODE_NAME
	parent_node.add_child.call_deferred(clouds)

func _ready() -> void:
	var world := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world and world.environment and world.environment.sky:
		_material = world.environment.sky.sky_material as ShaderMaterial
	if _material == null or _material.shader == null or not _material.shader.resource_path.ends_with("moon_sky.gdshader"):
		push_warning("CLOUDS: no moon_sky sky material -- clouds not created")
		set_process(false)
		return
	_light = get_parent().get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if _light:
		_rest_energy = _light.light_energy

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 4
	var image := noise.get_seamless_image(NOISE_SIZE, NOISE_SIZE)
	image.convert(Image.FORMAT_L8)
	_noise_data = image.get_data()
	image.generate_mipmaps()
	_material.set_shader_parameter("cloud_noise", ImageTexture.create_from_image(image))
	_material.set_shader_parameter("cloud_amount", 1.0)

func _exit_tree() -> void:
	if _material:
		_material.set_shader_parameter("cloud_amount", 0.0)
	if _light:
		_light.light_energy = _rest_energy

func _process(delta: float) -> void:
	# The pattern moves with the drift, so the texture offset goes the other way.
	# Not wrapped to 0..1: the second layer reads it at another scale and would jump at the wrap.
	_offset -= drift_direction.normalized() * drift_speed * delta
	_material.set_shader_parameter("cloud_offset", _offset)
	if _light == null:
		return
	_look_age += delta
	if _look_age > 0.5:
		_look_age = 0.0
		for key: String in ["cloud_coverage", "cloud_softness", "cloud_scale", "cloud_opacity", "cloud_flatten", "cloud_horizon_fade"]:
			_look[key] = _look_value(key)
	# A DirectionalLight3D shines along its -Z, so the moon is at +Z.
	var cover := _density(_light.global_basis.z.normalized()) * float(_look.cloud_opacity)
	_dim = lerpf(_dim, cover, 1.0 - exp(-delta / maxf(dim_smoothing, 0.001)))
	_light.light_energy = _rest_energy * lerpf(1.0, min_moonlight, _dim)

## The material's value for a shader uniform, or the shader's default when the material has none.
func _look_value(key: String) -> float:
	var value: Variant = _material.get_shader_parameter(key)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(_material.shader.get_rid(), key)
	return float(value)

## The shader's cloud_density() for the direction `dir`.
func _density(dir: Vector3) -> float:
	if dir.y <= 0.0:
		return 0.0
	var uv := Vector2(dir.x, dir.z) / (dir.y + float(_look.cloud_flatten)) * float(_look.cloud_scale) + _offset
	var n := _sample(uv) * 0.65 + _sample(uv * 2.3 + _offset * 0.6) * 0.35
	var edge := 1.0 - float(_look.cloud_coverage)
	var soft := float(_look.cloud_softness)
	return smoothstep(edge - soft, edge + soft, n) * smoothstep(0.0, float(_look.cloud_horizon_fade), dir.y)

## The noise at `uv`, repeating and bilinear, as the shader's sampler reads it.
func _sample(uv: Vector2) -> float:
	var x := fposmod(uv.x, 1.0) * NOISE_SIZE - 0.5
	var y := fposmod(uv.y, 1.0) * NOISE_SIZE - 0.5
	var x0 := int(floorf(x))
	var y0 := int(floorf(y))
	var fx := x - x0
	var fy := y - y0
	var xa := posmod(x0, NOISE_SIZE)
	var xb := posmod(x0 + 1, NOISE_SIZE)
	var ya := posmod(y0, NOISE_SIZE) * NOISE_SIZE
	var yb := posmod(y0 + 1, NOISE_SIZE) * NOISE_SIZE
	var top := lerpf(_noise_data[ya + xa], _noise_data[ya + xb], fx)
	var bottom := lerpf(_noise_data[yb + xa], _noise_data[yb + xb], fx)
	return lerpf(top, bottom, fy) / 255.0
