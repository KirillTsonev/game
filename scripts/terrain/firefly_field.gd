## Fireflies -- the drawing and the scatter on approach (2026-10-19, TRIAL). Reads
## FireflyScatter.swarms.
##
## A Node3D (not a static module, because it needs _process), like GrassField. All fireflies are
## one MultiMesh of small quads (child node "Dots") drawn by shaders/firefly.gdshader, which does
## the hovering, blinking, flight and distance fade. The only work here is one number per swarm:
## its scatter (0 = at home, 1 = fled). It rises over SCATTER_TIME while the player is within
## REACT_RADIUS of the swarm, and once the player has been gone RETURN_DELAY it falls back over
## RETURN_TIME. The values go to the shader in a two-row float texture (row 1: where the take-off
## wave starts, _set_wave_origin), rewritten only when one changed. A loop over every swarm (a few dozen) is cheaper than any lookup grid.
## Created by WorldGenerator via FireflyField.spawn(parent_node) after FireflyScatter.
## Debug: the J panel's "Fireflies" row; the benchmark's layer:fireflies; PerfDebug 1 / 2 switch
## the two kinds of light below.
##
## Light (TRIAL 2026-10-20, Kirill: "can we try making them actual sources of light"), two kinds,
## no shadows, each fading out with distance by Light3D's own distance fade:
##   swarm lights -- one OmniLight3D per swarm in its colour, a soft glow round it that rises with
##     the swarm when it flees (child node "SwarmLights");
##   glints -- a pool of GLINT_COUNT short-range lights handed to the fireflies nearest the camera,
##     each following its firefly and flashing with it (child node "Glints"). For that the shader's
##     motion is repeated here (_position, _flash); the shader's header says what must match.
class_name FireflyField
extends Node3D

const NODE_NAME := "Fireflies"
const SHADER := preload("res://shaders/firefly.gdshader")

const REACT_RADIUS := 9.0 ## m from the swarm's centre (horizontal) at which it scatters
const SCATTER_TIME := 2.0 ## s from home to fully fled (was 0.5: too quick to see the shader's easing)
const RETURN_DELAY := 2.5 ## s after the player has left before they start back
const RETURN_TIME := 5.0 ## s from fled to home
const MAP_AABB_HEIGHT := 400.0

## -- Swarm lights (TUNING) --
const SWARM_LIGHTS_AT_START := true
const SWARM_LIGHT_RANGE := 8.0 ## m
## At 0.5 (range 6) it was invisible next to the lantern (Kirill: "toggling 1 doesn't make any
## difference"): about 0.2 on the ground 2.25 m below, against the lantern's 2.4 at 1.5 m.
const SWARM_LIGHT_ENERGY := 2.0
const SWARM_LIGHT_SHIMMER := 0.25 ## share of the energy it wavers by, slowly
const SWARM_LIGHT_SPECULAR := 0.3
const SWARM_LIGHT_FADE_BEGIN := 40.0 ## m from the camera; gone FADE_LENGTH further
const SWARM_LIGHT_FADE_LENGTH := 15.0
## -- Glints (TUNING) --
const GLINTS_AT_START := true
const GLINT_COUNT := 12 ## lights in the pool
const GLINT_RANGE := 3.0 ## m; a firefly hovers 0.5-4 m up, so the higher ones light only what is near them
const GLINT_ENERGY := 1.2 ## at a flash's peak
const GLINT_FLOOR := 0.0 ## share of the peak between flashes (the dots glow at the shader's blink_floor)
const GLINT_SPECULAR := 0.3
const GLINT_REACH := 25.0 ## m from the camera: only fireflies this near get a light
const GLINT_PICK_INTERVAL := 0.25 ## s between new picks of the nearest fireflies
const GLINT_SWAP_FLASH := 0.05 ## a light leaves its firefly only while the flash is below this (no visible jump)

## Salts of the shader's rand01, one per kind of number.
enum { SALT_HX = 1, SALT_HY, SALT_HZ, SALT_GX, SALT_GY, SALT_GZ, SALT_START, SALT_JITTER, SALT_SWARM_UP }

var _player: Node3D
var _dots: MultiMeshInstance3D
var _material: ShaderMaterial
var _state_image: Image
var _state_texture: ImageTexture
var _centres := PackedVector3Array()
var _scatter := PackedFloat32Array()
var _calm := PackedFloat32Array() ## s since the player was last near
var _wave_origin := PackedVector2Array() ## per swarm, world x / z: see _set_wave_origin
var _wave_near := PackedFloat32Array()
var _wave_span := PackedFloat32Array()
var _clock := 0.0 ## the shader's `clock`

## The shader's values, read once (tuned in the shader's uniforms).
var _p := {}
## Per firefly, in MultiMesh order (= the shader's INSTANCE_ID).
var _homes := PackedVector3Array()
var _seeds := PackedFloat32Array()
var _swarm_of := PackedInt32Array()
var _colours := PackedColorArray()
var _h := PackedVector3Array()
var _g := PackedVector3Array()
var _start := PackedFloat32Array()
var _jitter := PackedFloat32Array()
var _first := PackedInt32Array() ## per swarm: its first firefly; the swarm runs to the next one's
var _swarm_up := PackedFloat32Array() ## per swarm

var _swarm_lights_on := SWARM_LIGHTS_AT_START
var _glints_on := GLINTS_AT_START
var _swarm_root: Node3D
var _swarm_lights: Array[OmniLight3D] = []
var _glint_root: Node3D
var _glints: Array[OmniLight3D] = []
var _glint_ids := PackedInt32Array() ## per light: its firefly, -1 = none
var _wanted := {} ## firefly -> true: the nearest ones at the last pick
var _pick_timer := 0.0

## Adds a fresh field under parent_node (deferred, like GrassField). No-op without swarms.
static func spawn(parent_node: Node) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	if FireflyScatter.swarms.is_empty():
		return
	var field := FireflyField.new()
	field.name = NODE_NAME
	parent_node.add_child.call_deferred(field)

func _ready() -> void:
	_player = get_parent().get_node_or_null("Player") as Node3D
	var swarms := FireflyScatter.swarms
	var total := 0
	for s in swarms:
		total += (s.homes as PackedVector3Array).size()

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = total
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var i := 0
	var jitter_rng := RandomNumberGenerator.new()
	for si in swarms.size():
		var s: Dictionary = swarms[si]
		var homes: PackedVector3Array = s.homes
		var seeds: PackedFloat32Array = s.seeds
		var colour: Color = s.colour
		_centres.append(s.centre)
		_first.append(i)
		for k in homes.size():
			jitter_rng.seed = hash(seeds[k])
			var own_colour := Color.from_hsv(fposmod(colour.h + jitter_rng.randf_range(-1.0, 1.0) * FireflyScatter.HUE_JITTER, 1.0), colour.s, colour.v)
			mm.set_instance_transform(i, Transform3D(Basis(), homes[k]))
			mm.set_instance_color(i, own_colour)
			mm.set_instance_custom_data(i, Color(float(si), seeds[k], 0.0, 0.0))
			_homes.append(homes[k])
			_seeds.append(seeds[k])
			_swarm_of.append(si)
			_colours.append(own_colour)
			_h.append(Vector3(_rand01(i, SALT_HX), _rand01(i, SALT_HY), _rand01(i, SALT_HZ)))
			_g.append(Vector3(_rand01(i, SALT_GX), _rand01(i, SALT_GY), _rand01(i, SALT_GZ)) * TAU)
			_start.append(_rand01(i, SALT_START))
			_jitter.append(_rand01(i, SALT_JITTER))
			lo = lo.min(homes[k])
			hi = hi.max(homes[k])
			i += 1
	_first.append(i)
	var margin := Vector3(10.0, 10.0, 10.0) # hover + flight
	mm.custom_aabb = AABB(lo - margin, hi - lo + 2.0 * margin)

	_scatter.resize(swarms.size())
	_calm.resize(swarms.size())
	_calm.fill(RETURN_DELAY)
	_wave_origin.resize(swarms.size())
	_wave_near.resize(swarms.size())
	_wave_span.resize(swarms.size())
	_state_image = Image.create_empty(maxi(swarms.size(), 1), 2, false, Image.FORMAT_RGBAF)
	_state_texture = ImageTexture.create_from_image(_state_image)

	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("swarm_state", _state_texture)
	_dots = MultiMeshInstance3D.new()
	_dots.name = "Dots"
	_dots.multimesh = mm
	_dots.material_override = _material
	_dots.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dots)

	for param: String in ["hover_radius", "hover_speed", "blink_rate", "blink_width", "flee_up_min", "flee_up_max", "flee_jitter", "flee_stagger", "flee_wave_noise", "flee_wobble", "flee_wobble_speed"]:
		var v: Variant = _material.get_shader_parameter(param)
		_p[param] = float(v if v != null else RenderingServer.shader_get_parameter_default(SHADER.get_rid(), param))
	for si in swarms.size():
		_swarm_up.append(lerpf(_p.flee_up_min, _p.flee_up_max, _rand01(si, SALT_SWARM_UP)))
	_build_lights(swarms)
	print("FIREFLIES: field ready -- %d swarm(s), %d firefl%s; swarm lights %s, %d glint lights %s" % [swarms.size(), total, "y" if total == 1 else "ies",
		"on" if _swarm_lights_on else "off", GLINT_COUNT, "on" if _glints_on else "off"])

func _build_lights(swarms: Array[Dictionary]) -> void:
	_swarm_root = Node3D.new()
	_swarm_root.name = "SwarmLights"
	_swarm_root.visible = _swarm_lights_on
	add_child(_swarm_root)
	for si in swarms.size():
		var light := _make_light(SWARM_LIGHT_RANGE, SWARM_LIGHT_SPECULAR)
		light.light_color = swarms[si].colour
		light.light_energy = SWARM_LIGHT_ENERGY
		light.position = _centres[si]
		_swarm_root.add_child(light)
		_swarm_lights.append(light)
	_glint_root = Node3D.new()
	_glint_root.name = "Glints"
	_glint_root.visible = _glints_on
	add_child(_glint_root)
	for k in GLINT_COUNT:
		var light := _make_light(GLINT_RANGE, GLINT_SPECULAR)
		light.visible = false
		_glint_root.add_child(light)
		_glints.append(light)
		_glint_ids.append(-1)

func _make_light(light_range: float, specular: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.omni_range = light_range
	light.shadow_enabled = false
	light.light_specular = specular
	light.light_bake_mode = Light3D.BAKE_DISABLED
	light.distance_fade_enabled = true
	light.distance_fade_begin = SWARM_LIGHT_FADE_BEGIN
	light.distance_fade_length = SWARM_LIGHT_FADE_LENGTH
	return light

## PerfDebug 1.
func toggle_swarm_lights() -> String:
	_swarm_lights_on = not _swarm_lights_on
	_swarm_root.visible = _swarm_lights_on
	return "[Fireflies] swarm lights %s" % ("ON" if _swarm_lights_on else "off")

## PerfDebug 2.
func toggle_glints() -> String:
	_glints_on = not _glints_on
	_glint_root.visible = _glints_on
	return "[Fireflies] glint lights %s (%d in the pool)" % ["ON" if _glints_on else "off", GLINT_COUNT]

func _process(delta: float) -> void:
	_clock += delta
	_material.set_shader_parameter("clock", _clock)
	if _player == null:
		return
	_update_scatter(delta)
	if _swarm_lights_on:
		_update_swarm_lights()
	if _glints_on:
		_update_glints(delta)

func _update_scatter(delta: float) -> void:
	var p := _player.global_position
	var changed := false
	for si in _centres.size():
		var c := _centres[si]
		var near := Vector2(p.x - c.x, p.z - c.z).length_squared() < REACT_RADIUS * REACT_RADIUS
		var a := _scatter[si]
		if near:
			if a == 0.0:
				_set_wave_origin(si, Vector2(p.x, p.z))
			_calm[si] = 0.0
			a = minf(a + delta / SCATTER_TIME, 1.0)
		else:
			_calm[si] += delta
			if _calm[si] >= RETURN_DELAY:
				a = maxf(a - delta / RETURN_TIME, 0.0)
		if a != _scatter[si]:
			_scatter[si] = a
			_state_image.set_pixel(si, 0, Color(a, _wave_origin[si].x, _wave_origin[si].y, 0.0))
			changed = true
	if changed:
		_state_texture.update(_state_image)

## Where the take-off wave starts: the player's spot when a swarm at rest is disturbed (a swarm
## still partly up keeps its old one). Its homes lie within SWARM_RADIUS of the centre, so their
## distances from the spot run from wave_near to wave_near + wave_span. Row 1 of the state texture.
func _set_wave_origin(si: int, origin: Vector2) -> void:
	var to_centre := origin.distance_to(Vector2(_centres[si].x, _centres[si].z))
	var near := maxf(to_centre - FireflyScatter.SWARM_RADIUS, 0.0)
	_wave_origin[si] = origin
	_wave_near[si] = near
	_wave_span[si] = to_centre + FireflyScatter.SWARM_RADIUS - near
	_state_image.set_pixel(si, 1, Color(_wave_near[si], _wave_span[si], 0.0, 0.0))

## Each swarm's light: at its centre, raised by the climb of a firefly taking off half-way through
## the stagger, wavering slowly.
func _update_swarm_lights() -> void:
	var stagger: float = _p.flee_stagger
	for si in _swarm_lights.size():
		var climb := _smootherstep01((_scatter[si] - 0.5 * stagger) / (1.0 - stagger))
		var light := _swarm_lights[si]
		light.position = _centres[si] + Vector3(0.0, _swarm_up[si] * climb, 0.0)
		light.light_energy = SWARM_LIGHT_ENERGY * (1.0 + SWARM_LIGHT_SHIMMER * sin(_clock * 0.8 + float(si) * 1.7) * sin(_clock * 1.9 + float(si) * 0.6))

func _update_glints(delta: float) -> void:
	_pick_timer -= delta
	if _pick_timer <= 0.0:
		_pick_timer = GLINT_PICK_INTERVAL
		_pick_nearest()
	# A light leaves a firefly no longer among the nearest only between its flashes; the freed
	# lights then take nearest ones that have none.
	var taken := {}
	for k in _glints.size():
		var id := _glint_ids[k]
		if id >= 0 and not _wanted.has(id) and _flash(id) < GLINT_SWAP_FLASH:
			id = -1
			_glint_ids[k] = -1
		if id >= 0:
			taken[id] = true
	for id: int in _wanted:
		if taken.has(id):
			continue
		var free := _glint_ids.find(-1)
		if free < 0:
			break
		_glint_ids[free] = id
		_glints[free].light_color = _colours[id]
	for k in _glints.size():
		var id := _glint_ids[k]
		var light := _glints[k]
		light.visible = id >= 0
		if id < 0:
			continue
		light.position = _position(id)
		light.light_energy = GLINT_ENERGY * (GLINT_FLOOR + (1.0 - GLINT_FLOOR) * _flash(id))

## The GLINT_COUNT fireflies nearest the camera within GLINT_REACH, from the swarms near enough.
func _pick_nearest() -> void:
	_wanted.clear()
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var eye := camera.global_position
	var swarm_reach: float = GLINT_REACH + FireflyScatter.SWARM_RADIUS + float(_p.hover_radius) + float(_p.flee_up_max)
	var found: Array = [] # [distance squared, firefly]
	for si in _centres.size():
		if _centres[si].distance_squared_to(eye) > swarm_reach * swarm_reach:
			continue
		for id in range(_first[si], _first[si + 1]):
			var d2 := _position(id).distance_squared_to(eye)
			if d2 < GLINT_REACH * GLINT_REACH:
				found.append([d2, id])
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for n in mini(found.size(), GLINT_COUNT):
		_wanted[found[n][1]] = true

## Where the shader draws firefly `id` now -- its vertex() step by step.
func _position(id: int) -> Vector3:
	var h := _h[id]
	var g := _g[id]
	var t := _clock * float(_p.hover_speed)
	var drift := Vector3(
		sin(t * (0.7 + 0.6 * h.x) + g.x) + 0.5 * sin(t * (1.9 + h.y) + g.y),
		0.5 * sin(t * (0.5 + 0.5 * h.z) + g.z) + 0.25 * sin(t * (1.3 + h.x) + g.x),
		sin(t * (0.8 + 0.5 * h.y) + g.y) + 0.5 * sin(t * (1.7 + h.z) + g.z)) * (float(_p.hover_radius) / 1.5)
	var si := _swarm_of[id]
	var stagger: float = _p.flee_stagger
	var home := _homes[id]
	var order := clampf((Vector2(home.x, home.z).distance_to(_wave_origin[si]) - _wave_near[si]) / maxf(_wave_span[si], 0.001), 0.0, 1.0)
	var start := lerpf(order, _start[id], float(_p.flee_wave_noise)) * stagger
	var own := clampf((_scatter[si] - start) / (1.0 - stagger), 0.0, 1.0)
	var own_jitter := (_jitter[id] - 0.5) * 2.0 * float(_p.flee_jitter)
	var flee := Vector3(0.0, (_swarm_up[si] + own_jitter) * _smootherstep01(own), 0.0)
	var ft := _clock * float(_p.flee_wobble_speed)
	var flutter := Vector3(sin(ft * (1.0 + h.x) + g.z), sin(ft * (1.3 + h.y) + g.x), sin(ft * (0.9 + h.z) + g.y)) \
		* float(_p.flee_wobble) * 4.0 * own * (1.0 - own)
	return _homes[id] + drift + flutter + flee

## The shader's flash (0..1, without its blink_floor).
func _flash(id: int) -> float:
	var phase := fposmod(_clock * float(_p.blink_rate) * (0.7 + 0.6 * _h[id].z) + _seeds[id] * 7.0, 1.0)
	return exp(-pow((phase - 0.5) * float(_p.blink_width), 2.0))

static func _smootherstep01(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)

## The shader's rand01 / hash32 (lowbias32) in 32-bit steps.
static func _rand01(id: int, salt: int) -> float:
	return float(_hash32(_hash32(id) ^ salt) >> 8) / 16777216.0

static func _hash32(x: int) -> int:
	x &= 0xFFFFFFFF
	x ^= x >> 16
	x = _mul32(x, 0x7feb352d)
	x ^= x >> 15
	x = _mul32(x, 0x846ca68b)
	x ^= x >> 16
	return x

## a * b modulo 2^32, without overflowing 64 bits.
static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF
