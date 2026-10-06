extends OmniLight3D

## Flame flicker for the lantern (2026-10-06): the OmniLight3D "Lantern" in player.tscn and its
## child spot "GroundPool" brighten and dim together with a smooth noise read over time -- a slow
## layer (the flame breathing) plus a faster, weaker one (the shimmer), and now and then a deeper
## dip (the flame catching a draught). The colour leans toward ember red as it dims.
## The energies and colours set in the scene are the resting values the flicker moves around.
## Not yet judged in game: every value below is a first guess, tunable live in the Remote tree.

## Share of the energy the flicker swings by, each way. 0 = a steady lantern (with gutter_depth 0).
@export_range(0.0, 0.5, 0.01) var flicker_amount: float = 0.12
## Multiplies every rate below: 1 = breathing at about 2.5 Hz, shimmer at about 11 Hz.
@export_range(0.1, 4.0, 0.05) var flicker_speed: float = 1.0
## Extra share of the energy lost at the bottom of an occasional deeper dip.
@export_range(0.0, 0.8, 0.01) var gutter_depth: float = 0.25
## How far the colour moves toward EMBER per unit of dimming (at 1, a 30 % dip goes 30 % of the way).
@export_range(0.0, 2.0, 0.05) var colour_shift: float = 0.6
## m the light itself wanders, so the shadows sway. 0 = off. Above 0 the lantern's shadow map is
## redrawn every frame, also while the player stands still.
@export_range(0.0, 0.05, 0.001) var shadow_sway: float = 0.0

const EMBER := Color(1.0, 0.45, 0.15)
const BREATH_HZ := 2.5
const SHIMMER_HZ := 11.0
const GUTTER_HZ := 0.8
const SWAY_HZ := 3.0
## get_noise_1d() stays within about +-0.6: this brings the swing up to flicker_amount.
const NOISE_GAIN := 1.6

var _noise := FastNoiseLite.new()
var _time: float = 0.0
var _pool: Light3D
var _rest_energy: float
var _rest_color: Color
var _rest_position: Vector3
var _pool_rest_energy: float
var _pool_rest_color: Color

func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_pool = get_node_or_null("GroundPool") as Light3D
	_rest_energy = light_energy
	_rest_color = light_color
	_rest_position = position
	if _pool:
		_pool_rest_energy = _pool.light_energy
		_pool_rest_color = _pool.light_color

func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta * flicker_speed
	# Each layer reads the same noise far apart, so they do not move together.
	var level := _noise.get_noise_1d(_time * BREATH_HZ) * 0.7 + _noise.get_noise_1d(_time * SHIMMER_HZ + 100.0) * 0.3
	var gutter := smoothstep(0.3, 0.55, _noise.get_noise_1d(_time * GUTTER_HZ + 500.0)) * gutter_depth
	_apply(maxf(1.0 + level * NOISE_GAIN * flicker_amount - gutter, 0.0))
	if shadow_sway > 0.0:
		var t := _time * SWAY_HZ
		position = _rest_position + Vector3(_noise.get_noise_1d(t + 200.0), _noise.get_noise_1d(t + 300.0), _noise.get_noise_1d(t + 400.0)) * shadow_sway
	elif position != _rest_position:
		position = _rest_position

## Back to the scene's resting values. The benchmark calls this: it stops the player's processing,
## which would otherwise leave the lantern at whatever brightness it had at that moment.
func hold_steady() -> void:
	_apply(1.0)
	position = _rest_position

func _apply(factor: float) -> void:
	var ember := clampf((1.0 - factor) * colour_shift, 0.0, 1.0)
	light_energy = _rest_energy * factor
	light_color = _rest_color.lerp(EMBER, ember)
	if _pool:
		_pool.light_energy = _pool_rest_energy * factor
		_pool.light_color = _pool_rest_color.lerp(EMBER, ember)
