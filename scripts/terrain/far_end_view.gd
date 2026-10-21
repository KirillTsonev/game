## What the player sees of the valley beyond the section being played (PROTOTYPE 2026-10-21,
## the biome valley; only with TerrainCastle.FAR_END).
##
## The valley is to be five sections of about 1 km, of which only the one being played is built;
## the walk through fog between two sections is to be the loading screen (Kirill). So nothing
## past the section's end may be seen: a bank of dense fog fills the valley's end
## (shaders/fog_bank.gdshader), from BANK_START_PZ m inside the map's north edge to well past
## the end of the terrain, its top a U across the valley (BANK_FLOOR_TOP m above the floor, up to
## about BANK_TOP over the side ridges). It is dense from any distance
## (a first version thickened the scene's distance fog as the player came near the end; Kirill:
## "that weird thing where the fog appears as we get closer to the edge"). It hides the ground
## past the section and the side ridges; the castle and the mountain rows behind it
## (MountainWalls.END_ROWS, with their cloud sheets) are drawn after it and seen through it,
## their feet in mist of BANK_COLOR so they rise out of it (TerrainCastle.FAR_DRAW_ORDER).
##
## It also lets the camera see that far: the castle stands about 5 km out, the rows behind it
## up to about 8 km, and a camera's default far plane is 4 km.
class_name FarEndView
extends Node

const NODE_NAME := "FarEndView"
const BANK_SHADER_PATH := "res://shaders/fog_bank.gdshader"
## The bank's south face, in heightmap pz (positive = inside the map, south of its north edge),
## and the m over which the fog thickens north of it. TUNING.
const BANK_START_PZ := 150.0
const BANK_FRONT_FADE := 150.0
## The front bulges toward the valley and back like the top's billows and swell (fog_bank.gdshader,
## front_bulge), this times their height -- up to about 110 m each way; the box reaches
## BANK_FRONT_BULGE m south of the front for it. (A flat front read as a grey wall -- Kirill.) TUNING.
const BANK_FRONT_BULGE_SCALE := 1.0
const BANK_FRONT_BULGE := 150.0
## How far it reaches north of the north apron's end, and past both sides of the import, m
## (past the sides: at least BANK_SIDE_RISE minus the ~200 m from a floor edge to the import's).
const BANK_OVERRUN := 900.0
## Its top: m above the valley floor where the fog has thinned to nothing, the m below that over
## which it thins, and how far that line wanders. TUNING. (160 / 90 / 35 at first: from the
## overlook anything more than about 4 deg up passed over the bank or through its thin top, and
## the castle and the horizon showed through -- Kirill. Now it fills the gap far above the ridges.)
const BANK_TOP := 700.0
## (150 / 80 while it was a flat fog; a cloud sea has a firmer top, with billows on it.)
const BANK_TOP_FADE := 60.0
const BANK_TOP_WANDER := 60.0
## The top is a U across the valley (Kirill, 2026-10-21: "make the fog u-shaped, along the valley
## shape"): BANK_TOP over the side ridges, only BANK_FLOOR_TOP m above the floor between its two
## edges (as the map's north row has them, which the north apron carries on), rising over
## BANK_SIDE_RISE m outward from each edge (an S: easing in and out). Dense up to
## BANK_FLOOR_TOP - BANK_TOP_FADE over the floor. TUNING. (200 at first: the sides stood as walls
## of cloud; Kirill asked for the slope of the mountains it hides. At 700 the steepest part is
## about 49 deg, and the apron's peaks, up to 220 m about 200 m out, stay about 50 m under its top there, 267 m.)
const BANK_FLOOR_TOP := 160.0
const BANK_SIDE_RISE := 700.0
## The U fills the basin round the valley's sections (ValleyPath.basin, 2026-10-21: one wide valley
## holding all of them, its floor a gentle rise to the castle's section, so the castle's foot stands
## about BANK_FLOOR_TOP deep in it; for a few hours before, it followed each section's own middle
## and floor, which gave ridges across the cloud at every step -- Kirill). The shader reads the
## basin from a lookup texture (_path_texture). Over the map's own
## terrain and the north apron it keeps to the map's line, then eases onto the path -- sideways
## over BANK_SHIFT_HOLD m past the apron's end, up and down over BANK_FLOOR_HOLD m: the first
## section beyond is shifted and lower, and followed at once the bank would sink off the terrain's
## end and the near mountain slopes. The bend sideways is the part that shows (the valley turning
## as it enters the cloud), so it comes sooner; the map's own end cannot bend far (its floor's edge
## is 70 m from its side, Kirill chose this over bending the terrain, 2026-10-21). (500 for both
## at first. Until then the top rose along a straight line north to the castle: as pow(share of
## the way, 2), the curve Kirill asked for -- "so it looks like it floats along curved terrain".)
## TUNING.
const BANK_SHIFT_HOLD := 150.0
const BANK_FLOOR_HOLD := 500.0
## (600 while everything out there was drawn over the bank. Behind it -- TerrainCastle.FAR_OVER_BANK
## false -- the bank must reach past the rows behind the castle, up to about 1 km back, and
## MountainWalls.FAR_FILL's slices, 1.5 km back, or their feet stand in the open.)
const BANK_BEYOND_CASTLE := 2500.0
## The box reaches this far sideways past the path's widest shift on either side (the far side
## ranges stand MountainWalls.FAR_SIDE_OUT_FROM m out, and are 1 km deep), m.
const BANK_SIDE_REACH := 3200.0
## Samples of the path's lookup texture, from the bank's front to its far end.
const BANK_PATH_SAMPLES := 1024
## The castle, its lights and the far rows are drawn after the bank (seen through it), so below
## its top they would be painted over the fog (Kirill, 2026-10-21: their misty feet showed as a
## dark band between the section's end and the castle). They fade out from BANK_REVEAL_ABOVE m
## over the top to nothing BANK_REVEAL_BELOW m under it (soft, as the top wanders BANK_TOP_WANDER).
## The castle's lights are left out under the top. TUNING.
const BANK_REVEAL_BELOW := 100.0
const BANK_REVEAL_ABOVE := 40.0
## Fog per m of view ray inside it (0.03: 95 % hidden after 100 m). TUNING.
const BANK_DENSITY := 0.03
## A sea of low cloud since 2026-10-21 (Kirill: "it could be haze, low clouds, anything that
## completely blocks the view"), lit by the moon (the DirectionalLight3D, read at start): its
## colour deep in, just under its top where a billow faces the moon / is turned from it, and
## how far under the top the light reaches, m. Billows on the top: height (m, up and down) and
## size. TUNING.
const BANK_COLOR := MountainWalls.HAZE_COLOR
const BANK_TOP_COLOR := Color(0.42, 0.47, 0.58)
const BANK_SHADE_COLOR := MountainWalls.MIST_COLOR
const BANK_LIGHT_DEPTH := 60.0
const BANK_BILLOW_HEIGHT := 35.0
const BANK_BILLOW_SCALE := 180.0
## The second section is a lava zone, its left ridges active volcanoes (Kirill, 2026-10-21): glows
## in the bank there, lighting it from inside in red / orange flashes "like lightning shows
## on/through storm clouds" (fog_bank.gdshader: a dull steady glow, sudden flashes that die away,
## some twice, each glow at its own times). Each: "along" (m north of the map's north edge), "out"
## (m out past the basin's low-X edge -- left, walking north) or "x" (m sideways from the map's
## middle, + = right), "up" (m above the basin's floor), "radius" (m, how far its light spreads).
## At most LAVA_GLOW_MAX. TUNING, all of it.
const LAVA_GLOWS: Array[Dictionary] = [
	{"along": 450.0, "out": 250.0, "up": 230.0, "radius": 380.0},
	{"along": 800.0, "out": 450.0, "up": 280.0, "radius": 450.0},
	{"along": 1150.0, "out": 300.0, "up": 250.0, "radius": 400.0},
	# Toward the valley's middle, ahead of the start (Kirill: "can't really see it to the side").
	{"along": 700.0, "x": -250.0, "up": 120.0, "radius": 450.0},
	# Over the first section's left side, where the bank begins: the others are mostly behind the
	# turn, hardly seen from the spawn (Kirill).
	{"along": 150.0, "x": -260.0, "up": 150.0, "radius": 400.0},
]
## The shader's room for glows, lava and ice together (fog_bank.gdshader's arrays; its loops stop
## at the count used). Lava's are taken first.
const LAVA_GLOW_MAX := 8
const LAVA_GLOW_COLOR := Color(1.0, 0.35, 0.08)
const LAVA_GLOW_STRENGTH := 1.5 ## added to the cloud's colour at a flash's peak, at its middle
const LAVA_GLOW_STEADY := 0.08 ## the dull glow between flashes, as a share of a flash
const LAVA_FLASH_PERIOD := 2.5 ## s: one chance of a flash per glow in each
const LAVA_FLASH_CHANCE := 0.45 ## share of those chances taken
const LAVA_FLASH_DECAY := 6.0 ## 1/s: how fast a flash dies away
## The third section is an ice zone (ValleyPath.SECTIONS[ICE_SECTION]; Kirill, 2026-10-21): cold
## light from within the bank there, slow "to contrast the quick sudden flashes of the lava area"
## and coming from under / within the fog (an aurora in the sky above was tried first the same day
## and dropped): pale glows that swell and fade over "period" s, each at its own place in the
## cycle ("phase", 0..1 -- staggered, the light seems to pass from one to the next), never below
## ICE_GLOW_LOW, and wander slowly through the cloud by "drift" m. Each: "along" (m past the
## section's start), "x" (m sideways from the section's middle), "up" (m above the basin's floor),
## "radius" (m). TUNING, all of it.
const ICE_SECTION := 2
const ICE_GLOWS: Array[Dictionary] = [
	# On the valley's right side (Kirill; -150 / 200 / -50 at first, in its middle).
	{"along": 200.0, "x": 280.0, "up": 100.0, "radius": 500.0, "period": 7.0, "phase": 0.0, "drift": 150.0},
	{"along": 550.0, "x": 380.0, "up": 110.0, "radius": 550.0, "period": 9.0, "phase": 0.33, "drift": 200.0},
	{"along": 900.0, "x": 320.0, "up": 100.0, "radius": 500.0, "period": 8.0, "phase": 0.66, "drift": 150.0},
]
const ICE_GLOW_COLOR := Color(0.55, 0.85, 1.0)
## Added to the cloud's colour at a breath's peak, at its middle. (0.9 at first: overlapping, the
## glows burnt out to one near-white spot with no cloud contours left in it -- Kirill.)
const ICE_GLOW_STRENGTH := 0.45
const ICE_GLOW_LOW := 0.15 ## between breaths, as a share of the peak
## On slopes of the cloud's top turned away from the moon, the glow's light as a share of its light
## on those facing it: the puffs' contours show in it. TUNING.
const ICE_GLOW_SHAPE_LOW := 0.25
## (10000 while the castle stood 4 km out; ValleyPath puts it about 6 km out, its rows up to 3 km
## behind it.)
const CAMERA_FAR := 14000.0

var _player: Node3D

## Adds a fresh one, with its fog bank, under `parent_node` (deferred, like the other generated
## nodes). No-op without TerrainCastle.FAR_END.
static func spawn(parent_node: Node, heightmap_corner: Vector3) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	if not TerrainCastle.FAR_END:
		return
	var view := FarEndView.new()
	view.name = NODE_NAME
	view.add_child(_build_bank(heightmap_corner))
	parent_node.add_child.call_deferred(view)

## `shader` (one written to be drawn after the bank: ALPHA from bank_reveal, depth_draw_always)
## as a plain opaque one, which the bank covers wherever it lies in front of it
## (TerrainCastle.FAR_OVER_BANK false). Cached per shader.
static var _behind_shaders := {}
static func behind_bank(shader: Shader) -> Shader:
	if not _behind_shaders.has(shader):
		var copy := Shader.new()
		copy.code = shader.code.replace("ALPHA = bank_reveal(world_pos);", "").replace(", depth_draw_always", "")
		_behind_shaders[shader] = copy
	return _behind_shaders[shader]

## Sets the bank's top (the uniforms of shaders/fog_bank_top.gdshaderinc) on `material`: the
## bank's own, and those of everything drawn after it and seen through it (the castle, the far
## mountain rows), which are not drawn below that top.
static func set_bank_shape(material: ShaderMaterial, heightmap_corner: Vector3) -> void:
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	material.set_shader_parameter("bank_top_y", floor_y + BANK_TOP)
	material.set_shader_parameter("bank_floor_top_y", floor_y + BANK_FLOOR_TOP)
	material.set_shader_parameter("bank_middle_x", heightmap_corner.x + _MAP_MIDDLE)
	material.set_shader_parameter("bank_side_rise", BANK_SIDE_RISE)
	material.set_shader_parameter("bank_map_north_z", heightmap_corner.z)
	material.set_shader_parameter("bank_path", _path_texture())
	material.set_shader_parameter("bank_path_from", _path_from())
	material.set_shader_parameter("bank_path_to", _path_to())
	material.set_shader_parameter("bank_reveal_below", BANK_REVEAL_BELOW)
	material.set_shader_parameter("bank_reveal_above", BANK_REVEAL_ABOVE)

## The bank's top at world (x, z), m: bank_top_at() of the include, without the wander.
static func bank_top_at(x: float, z: float, heightmap_corner: Vector3) -> float:
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	var basin := basin_at(heightmap_corner.z - z)
	var dx := x - heightmap_corner.x - _MAP_MIDDLE
	var outside := maxf(maxf(basin.x - dx, dx - basin.y), 0.0)
	return lerpf(floor_y + BANK_FLOOR_TOP, floor_y + BANK_TOP, smoothstep(0.0, BANK_SIDE_RISE, outside)) + basin.z

## The generated map's middle, m from its low-X edge: what ValleyPath's shifts are measured from.
const _MAP_MIDDLE := float(TerrainConfig.AREA_WIDTH - 1) * 0.5

## The valley the bank fills at `along` (ValleyPath.basin: x / y = its floor's low / high edge,
## m sideways from the map's middle, z = its floor): over the terrain the map's own floor (its
## north row's edges, level), easing onto the basin over BANK_SHIFT_HOLD (edges) and
## BANK_FLOOR_HOLD (floor) m past the terrain's end.
static func basin_at(along: float) -> Vector3:
	var terrain_end := float(TerrainCastle.LENGTH)
	var basin := ValleyPath.basin(along)
	var edges := smoothstep(terrain_end, terrain_end + BANK_SHIFT_HOLD, along)
	return Vector3(
		lerpf(TerrainHeightmap.floor_lo(0.0) - _MAP_MIDDLE, basin.x, edges),
		lerpf(TerrainHeightmap.floor_hi(0.0) - _MAP_MIDDLE, basin.y, edges),
		basin.z * smoothstep(terrain_end, terrain_end + BANK_FLOOR_HOLD, along))

## The stretch the lookup texture covers, along: the bank's front to its far end.
static func _path_from() -> float:
	return -BANK_START_PZ

static func _path_to() -> float:
	return ValleyPath.castle_along() + BANK_BEYOND_CASTLE

## basin_at() from _path_from() to _path_to(), BANK_PATH_SAMPLES texels (R / G = the floor's low /
## high edge, B = its floor, m). Rebuilt when the map's floor edges (per run) change.
static var _path_tex: ImageTexture
static var _path_key := Vector2(NAN, NAN)
static func _path_texture() -> ImageTexture:
	var key := Vector2(TerrainHeightmap.floor_lo(0.0), TerrainHeightmap.floor_hi(0.0))
	if _path_tex == null or key != _path_key:
		_path_key = key
		var image := Image.create(BANK_PATH_SAMPLES, 1, false, Image.FORMAT_RGBF)
		for i in BANK_PATH_SAMPLES:
			var basin := basin_at(lerpf(_path_from(), _path_to(), float(i) / float(BANK_PATH_SAMPLES - 1)))
			image.set_pixel(i, 0, Color(basin.x, basin.y, basin.z))
		_path_tex = ImageTexture.create_from_image(image)
	return _path_tex

static func _castle_z(heightmap_corner: Vector3) -> float:
	return heightmap_corner.z + TerrainCastle.SITE_PX.y - TerrainCastle.far_shift()

static func _build_bank(heightmap_corner: Vector3) -> MeshInstance3D:
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	var import_low_x := heightmap_corner.x - float(MountainWalls.APRON_WIDTH)
	var import_high_x := heightmap_corner.x + float(TerrainConfig.AREA_WIDTH + MountainWalls.APRON_WIDTH)
	var castle_z := _castle_z(heightmap_corner)
	# The path's extremes, for the box.
	var shift_min := 0.0
	var shift_max := 0.0
	var floor_min := 0.0
	var floor_max := 0.0
	for section: Dictionary in ValleyPath.SECTIONS:
		shift_min = minf(shift_min, float(section.shift))
		shift_max = maxf(shift_max, float(section.shift))
		floor_min = minf(floor_min, float(section.floor))
		floor_max = maxf(floor_max, float(section.floor))
	var middle_x := heightmap_corner.x + float(TerrainConfig.AREA_WIDTH - 1) * 0.5
	var box_min := Vector3(minf(import_low_x - BANK_OVERRUN, middle_x + shift_min - BANK_SIDE_REACH), floor_y - 100.0 + floor_min, minf(heightmap_corner.z - float(TerrainCastle.LENGTH) - BANK_OVERRUN, castle_z - BANK_BEYOND_CASTLE))
	var box_max := Vector3(maxf(import_high_x + BANK_OVERRUN, middle_x + shift_max + BANK_SIDE_REACH), floor_y + BANK_TOP + BANK_TOP_WANDER + BANK_BILLOW_HEIGHT * 1.4 + floor_max, heightmap_corner.z + BANK_START_PZ + BANK_FRONT_BULGE)
	var material := ShaderMaterial.new()
	material.shader = load(BANK_SHADER_PATH) as Shader
	material.set_shader_parameter("noise", MountainWalls._cloud_noise_texture())
	material.set_shader_parameter("box_min", box_min)
	material.set_shader_parameter("box_max", box_max)
	material.set_shader_parameter("fog_color", BANK_COLOR)
	material.set_shader_parameter("top_color", BANK_TOP_COLOR)
	material.set_shader_parameter("shade_color", BANK_SHADE_COLOR)
	material.set_shader_parameter("light_depth", BANK_LIGHT_DEPTH)
	material.set_shader_parameter("billow_height", BANK_BILLOW_HEIGHT)
	material.set_shader_parameter("billow_scale", BANK_BILLOW_SCALE)
	material.set_shader_parameter("density", BANK_DENSITY)
	material.set_shader_parameter("front_z", heightmap_corner.z + BANK_START_PZ)
	material.set_shader_parameter("front_bulge_scale", BANK_FRONT_BULGE_SCALE)
	material.set_shader_parameter("front_reach", BANK_FRONT_BULGE)
	material.set_shader_parameter("front_fade", BANK_FRONT_FADE)
	material.set_shader_parameter("top_fade", BANK_TOP_FADE)
	material.set_shader_parameter("top_wander", BANK_TOP_WANDER)
	set_bank_shape(material, heightmap_corner)
	# The glows: the lava zone's (placed off the basin's low-X edge or across the valley; flashing),
	# then the ice zone's (from its section's middle; breathing, wandering).
	var glows := PackedVector4Array()
	var looks := PackedVector4Array()
	var times := PackedVector4Array()
	var lava := LAVA_GLOW_COLOR.srgb_to_linear()
	for glow: Dictionary in LAVA_GLOWS:
		var basin := basin_at(float(glow.along))
		var sideways: float = float(glow.x) if glow.has("x") else basin.x - float(glow.out)
		glows.append(Vector4(heightmap_corner.x + _MAP_MIDDLE + sideways, floor_y + basin.z + float(glow.up), heightmap_corner.z - float(glow.along), float(glow.radius)))
		looks.append(Vector4(lava.r, lava.g, lava.b, LAVA_GLOW_STRENGTH))
		times.append(Vector4(0.0, 1.0, 0.0, 0.0))
	if ICE_SECTION < ValleyPath.SECTIONS.size():
		var ice := ICE_GLOW_COLOR.srgb_to_linear()
		var span: Vector2 = ValleyPath.spans()[ICE_SECTION]
		var middle := ValleyPath.at((span.x + span.y) * 0.5).x
		for glow: Dictionary in ICE_GLOWS:
			var along := span.x + float(glow.along)
			glows.append(Vector4(heightmap_corner.x + _MAP_MIDDLE + middle + float(glow.x), floor_y + basin_at(along).z + float(glow.up), heightmap_corner.z - along, float(glow.radius)))
			looks.append(Vector4(ice.r, ice.g, ice.b, ICE_GLOW_STRENGTH))
			times.append(Vector4(1.0, float(glow.period), float(glow.phase), float(glow.drift)))
	if glows.size() > LAVA_GLOW_MAX:
		push_warning("TERRAIN_GEN: far end -- %d glows, the bank's shader takes %d: the rest left out" % [glows.size(), LAVA_GLOW_MAX])
	var count := mini(glows.size(), LAVA_GLOW_MAX)
	glows = glows.slice(0, count)
	looks = looks.slice(0, count)
	times = times.slice(0, count)
	while glows.size() < LAVA_GLOW_MAX:
		glows.append(Vector4(0.0, 0.0, 0.0, 1.0))
		looks.append(Vector4.ZERO)
		times.append(Vector4(0.0, 1.0, 0.0, 0.0))
	material.set_shader_parameter("glow_points", glows)
	material.set_shader_parameter("glow_looks", looks)
	material.set_shader_parameter("glow_times", times)
	material.set_shader_parameter("glow_count", count)
	material.set_shader_parameter("glow_steady", LAVA_GLOW_STEADY)
	material.set_shader_parameter("breathe_low", ICE_GLOW_LOW)
	material.set_shader_parameter("breathe_shape_low", ICE_GLOW_SHAPE_LOW)
	material.set_shader_parameter("flash_period", LAVA_FLASH_PERIOD)
	material.set_shader_parameter("flash_chance", LAVA_FLASH_CHANCE)
	material.set_shader_parameter("flash_decay", LAVA_FLASH_DECAY)
	var box := BoxMesh.new()
	box.size = box_max - box_min
	box.material = material
	var bank := MeshInstance3D.new()
	bank.name = "FogBank"
	bank.mesh = box
	bank.position = (box_min + box_max) * 0.5
	bank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	print("TERRAIN_GEN: far end -- fog bank from %.0f m inside the map's north edge to %.0f m past the castle, %.0f m wide, top %.0f m above the floor between px %.0f..%.0f, %.0f m over the sides, following ValleyPath (shifts %.0f..%.0f m, floors %.0f..%.0f m)" % [BANK_START_PZ, BANK_BEYOND_CASTLE, box_max.x - box_min.x, BANK_FLOOR_TOP, TerrainHeightmap.floor_lo(0.0), TerrainHeightmap.floor_hi(0.0), BANK_TOP, shift_min, shift_max, floor_min, floor_max])
	return bank

func _ready() -> void:
	# The cloud's top is lit from the moon: a DirectionalLight3D shines along its -Z, so the moon is at +Z.
	var moon := get_parent().get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	var bank := get_node_or_null("FogBank") as MeshInstance3D
	if moon and bank:
		var material := (bank.mesh as PrimitiveMesh).material as ShaderMaterial
		if material:
			material.set_shader_parameter("moon_toward", moon.global_transform.basis.z.normalized())
	_player = get_parent().get_node_or_null("Player") as Node3D
	if _player:
		var camera := _player.get_node_or_null("Camera3D") as Camera3D
		if camera:
			camera.far = maxf(camera.far, CAMERA_FAR)
