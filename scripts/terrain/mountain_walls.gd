## The valley's mountain walls, on both long sides since 2026-10-09 (`side`: 0 = the low-X / left
## side, 1 = the high-X / right side; every per-side function takes it): the playable slopes
## stop at the map's edge, and from there mountain meshes carry the slope on up. Scenery only --
## no collision (WorldBounds stops the player just inside the edge), no shadow casting.
##
## Two parts, from the valley outward:
##  - the APRON: real terrain. APRON_WIDTH m of extra ground on the low-X side of the Terrain3D
##    import (apron_maps, joined on by TerrainHub.join_images), carrying the valley's slope on past
##    the generated map: it leaves the map's edge at the terrain's own grade (the hub's higher
##    plateau included), steepens until it cannot be walked, and ends in a low noise ridge. Being
##    terrain, it has no seam with the map at all -- same mesh, same shader, same collision -- and
##    the player can walk off the map's edge onto it; WorldBounds' left wall stands WALK_DEPTH m
##    out. Nothing is scattered on it. (Before, 2026-10-08: first a row of mountain slices, whose
##    vertices were metres apart so the terrain floated over them; then a mesh built to the
##    terrain's edge, which fitted but still met it along a straight line in another shader.)
##  - behind it, ROWS of ridge lines (meshes), each taller and hazier than the one in front and
##    rising out of mist. Every row is a line of SEGMENTS (ridge slices cut from a downloaded
##    mountain by tools/blender/cut_mountain_wall.py), scaled to the row's size. Their number
##    follows the length of the map's edge, so AREA_LENGTH / AREA_WIDTH can change freely. Which
##    segment stands where comes from the run's seed. A segment's own frame: +X = depth (away
##    from the valley, its foot at x = 0), Z = along the wall (centred), Y = up, foot at y = 0.
##
## Where the valley ends and the mountain begins is NOT the map's edge (a straight line, however
## well it is hidden) but the FOOT LINE, which wanders FOOT_MIN..FOOT_MAX m inside the generated
## map (raise_foot, a heightmap stage): past it the map's own ground steepens into the wall and is
## painted rock with no grass (stamp_rock_distance, used by the grass bake and the ground paint).
## The map's edge then lies inside steep rock on both sides, where nothing marks it.
##
## Drawn by shaders/mountain_wall.gdshader: tiling rock projected from three sides, with the
## segment's own baked maps only as large-scale variation (they are far too coarse up close).
##
## Static-only: never instantiated; call as MountainWalls.some_func(...).
class_name MountainWalls
extends RefCounted

## Height of the apron's back (outer) edge per row of the map + hub, smoothed: what the seated
## mountain row stands on. Set by apron_maps, read by build.
static var apron_back_heights: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()] # per side
## How tall the apron is per row of the map + hub, 0 (lowest saddle) .. 1 (highest peak). Set by
## apron_maps, read by build (the seated row follows it).
static var apron_envelope: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()] # per side
## The foot line of each side (raise_foot's result): [low X, high X, north end]. Per row of the
## generated map (per column for the north end), how far inside that edge the mountain begins.
## Read by mountain_depth / on_mountain.
static var foot_lines: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
## The rise raise_foot has added per heightmap pixel so far this run (the highest of the sides').
static var _foot_rise := PackedFloat32Array()
## Vegetation keeps this far clear of the foot line, m (trunk and crown radii come on top).
const FOOT_PLANT_GAP := 1.5
## The rows' materials with their haze and mist strengths, [material, haze, mist] each -- for
## toggle_fog (PerfDebug F7).
static var _section_noise: FastNoiseLite
static var _section_seed := 0
static var _fog_materials: Array = []
static var _fog_environment: Environment
static var _fog_shown := true
static var _clouds_shown := true
## Fog is on when the game starts; F7 switches it off / on. (Kirill, 2026-10-09: "disable fog"
## in the morning, "let's turn on fog by default" in the afternoon.)
const FOG_ON_AT_START := true

## The scene's distance fog (SCENE_FOG_*) on the WorldEnvironment under `parent_node`.
static func _apply_scene_fog(parent_node: Node) -> void:
	var world := parent_node.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world == null or world.environment == null:
		push_warning("TERRAIN_GEN: no WorldEnvironment found -- the scene's distance fog is not set")
		return
	_fog_environment = world.environment
	_fog_environment.fog_enabled = true
	_fog_environment.fog_mode = Environment.FOG_MODE_DEPTH
	_fog_environment.fog_depth_begin = SCENE_FOG_BEGIN
	_fog_environment.fog_depth_end = SCENE_FOG_END
	_fog_environment.fog_depth_curve = SCENE_FOG_CURVE
	_fog_environment.fog_density = SCENE_FOG_DENSITY
	_fog_environment.fog_light_color = HAZE_COLOR
	_fog_environment.fog_light_energy = 1.0
	_fog_environment.fog_sun_scatter = 0.0
	_fog_environment.fog_aerial_perspective = SCENE_FOG_SKY_BLEND
	_fog_environment.fog_sky_affect = 0.0

## DEBUG (PerfDebug F7): the scene's distance fog and the rows' haze and mist off / on.
static func toggle_fog() -> String:
	_fog_shown = not _fog_shown
	if _fog_environment:
		_fog_environment.fog_enabled = _fog_shown
	for entry: Array in _fog_materials:
		var material: ShaderMaterial = entry[0]
		material.set_shader_parameter("haze_amount", float(entry[1]) if _fog_shown else 0.0)
		material.set_shader_parameter("mist_amount", float(entry[2]) if _fog_shown else 0.0)
	return "[MountainWalls] distance fog, and haze and mist on the mountain rows: %s (%d material(s))" % ["on" if _fog_shown else "OFF", _fog_materials.size()]

## DEBUG (PerfDebug F6): the mountains' clouds off / on -- the sheets between the rows and, when
## CLOUDS_ON_ROWS, the patches painted on the rows. Independent of the fog (F7): Kirill,
## 2026-10-09, "why does f7 toggle both fog and cloud? make them separate with f6".
static func toggle_clouds() -> String:
	_clouds_shown = not _clouds_shown
	_apply_clouds()
	return "[MountainWalls] clouds in the mountains: %s (%d sheet(s); painted on the rows: %s)" % ["on" if _clouds_shown else "OFF", _cloud_sheets.size(), "yes" if CLOUDS_ON_ROWS else "switched off in code"]

## Shows or hides both kinds of cloud to match _clouds_shown.
static func _apply_clouds() -> void:
	for entry: Array in _fog_materials:
		(entry[0] as ShaderMaterial).set_shader_parameter("cloud_amount", CLOUD_AMOUNT if _clouds_shown and CLOUDS_ON_ROWS else 0.0)
	for sheet in _cloud_sheets:
		if is_instance_valid(sheet):
			sheet.visible = _clouds_shown

## Clouds on the mountain rows (2026-10-09, Kirill: "supplement the fog with some clouds in the
## mountains" -- the cheapest of three ways offered): drifting patches of veil drawn by the rows'
## shader in a band of heights above each row's mist, so the even mist breaks up into banks that
## move. Paint on the surface: they cannot hang in the gaps between peaks. They go off and on
## with F6, on their own (not with the fog, F7). TUNING.
## SWITCHED OFF the same day (Kirill: "temporarily disable approach 1 on clouds, don't remove,
## and implement approach 2"): true brings them back, beside the sheets (CLOUD_SHEETS).
const CLOUDS_ON_ROWS := false
const CLOUD_AMOUNT := 0.85 ## how much a cloud hides of the rock under it
const CLOUD_COVERAGE := 0.5 ## share of the band under cloud
const CLOUD_SOFTNESS := 0.2 ## softness of a cloud's edge (in noise value)
const CLOUD_COLOR := Color(0.38, 0.43, 0.54)
## One tile of the cloud pattern is this many m across on a row of size 1 (x the row's size:
## the patches look about the same size on screen on every row), drifting at CLOUD_DRIFT m/s
## along world x / z -- the way the sky's clouds go (CloudSky.drift_direction).
const CLOUD_TILE := 900.0
const CLOUD_DRIFT := Vector2(-5.5, -5.5)
## The band reaches from where a row's mist is complete to this share of the mist's own height
## range above where the mist ends.
const CLOUD_ABOVE_MIST := 0.8
const CLOUD_NOISE_SIZE := 256
static var _cloud_noise: ImageTexture

## Cloud banks between the rows (2026-10-09, the second way): upright see-through sheets drawn
## by shaders/mountain_cloud.gdshader, one per entry on each long side and across the north end.
## They hang in the gaps between peaks and shift against the mountains as the camera moves; a
## mountain in front hides them, and toward a mountain just behind they thin out.
##   "out"     m from the map's edge to the sheet (on the north end: from its north edge)
##   "bottom" / "top"  the band of heights the clouds sit in, m above the valley floor
##   "tile"    size of one patch-pattern tile along the sheet, m (larger further back, so the
##             patches look about the same size from the valley)
##   "amount"  how much the thickest cloud hides of what is behind it
## For orientation, per side: the first row's crest is about 520 m out, the second row's about
## 1570 m, the third's about 2680 m. Two sheets a little apart read as one bank with depth. TUNING.
const CLOUD_SHEETS: Array[Dictionary] = [
	{"out": 300.0, "bottom": 130.0, "top": 420.0, "tile": 650.0, "amount": 0.6},
	{"out": 430.0, "bottom": 170.0, "top": 520.0, "tile": 800.0, "amount": 0.6},
	{"out": 720.0, "bottom": 250.0, "top": 820.0, "tile": 1300.0, "amount": 0.7},
	{"out": 930.0, "bottom": 320.0, "top": 980.0, "tile": 1500.0, "amount": 0.7},
	{"out": 1750.0, "bottom": 600.0, "top": 1700.0, "tile": 2600.0, "amount": 0.75},
]
const CLOUD_SHEET_SHADER_PATH := "res://shaders/mountain_cloud.gdshader"
const CLOUD_SHEET_COVERAGE := 0.5 ## share of a sheet's band under cloud
const CLOUD_SHEET_SOFTNESS := 0.22
const CLOUD_SHEET_DRIFT := 6.0 ## m per second along the sheet
## A sheet runs this far past both ends of what it stands along, and its clouds fade out over
## CLOUD_SHEET_END_FADE m at each end.
const CLOUD_SHEET_OVERRUN := 700.0
const CLOUD_SHEET_END_FADE := 350.0
## The clouds thin out over this share of the sheet's "tile" in front of a mountain behind them.
const CLOUD_SHEET_PROXIMITY := 0.15
static var _cloud_sheets: Array[MeshInstance3D] = []

## Adds the cloud sheets (CLOUD_SHEETS) to `root`: both long sides and the north end.
static func _build_cloud_sheets(root: Node3D, heightmap_corner: Vector3, floor_y: float, rng: RandomNumberGenerator) -> void:
	_cloud_sheets = []
	var shader := load(CLOUD_SHEET_SHADER_PATH) as Shader
	if shader == null:
		push_warning("TERRAIN_GEN: %s could not be loaded -- no cloud sheets" % CLOUD_SHEET_SHADER_PATH)
		return
	var z_low := heightmap_corner.z - float(TerrainCastle.LENGTH) - CLOUD_SHEET_OVERRUN
	var z_high := heightmap_corner.z + float(TerrainConfig.AREA_LENGTH + TerrainHub.STRIP_LENGTH) + CLOUD_SHEET_OVERRUN
	var x_low := heightmap_corner.x - float(APRON_WIDTH) - CLOUD_SHEET_OVERRUN
	var x_high := heightmap_corner.x + float(TerrainConfig.AREA_WIDTH + APRON_WIDTH) + CLOUD_SHEET_OVERRUN
	for place in 3: # 0 = low-X side, 1 = high-X side, 2 = north end
		for index in CLOUD_SHEETS.size():
			var def: Dictionary = CLOUD_SHEETS[index]
			var along_low := z_low if place < 2 else x_low
			var along_high := z_high if place < 2 else x_high
			var span := float(def.top) - float(def.bottom)
			# The quad reaches past the band: the band's limits wander by a quarter of its height.
			var quad := QuadMesh.new()
			quad.size = Vector2(along_high - along_low, span * 1.6)
			var material := ShaderMaterial.new()
			material.shader = shader
			material.set_shader_parameter("cloud_noise", _cloud_noise_texture())
			material.set_shader_parameter("cloud_color", CLOUD_COLOR)
			material.set_shader_parameter("cloud_amount", float(def.amount))
			material.set_shader_parameter("cloud_coverage", CLOUD_SHEET_COVERAGE)
			material.set_shader_parameter("cloud_softness", CLOUD_SHEET_SOFTNESS)
			material.set_shader_parameter("tile", float(def.tile))
			material.set_shader_parameter("along_axis", Vector3.BACK if place < 2 else Vector3.RIGHT)
			material.set_shader_parameter("drift", CLOUD_SHEET_DRIFT)
			material.set_shader_parameter("noise_offset", Vector2(rng.randf(), rng.randf()))
			material.set_shader_parameter("bottom_y", floor_y + float(def.bottom))
			material.set_shader_parameter("top_y", floor_y + float(def.top))
			material.set_shader_parameter("end_low", along_low)
			material.set_shader_parameter("end_high", along_high)
			material.set_shader_parameter("end_fade", CLOUD_SHEET_END_FADE)
			material.set_shader_parameter("proximity_fade", float(def.tile) * CLOUD_SHEET_PROXIMITY)
			quad.material = material
			var sheet := MeshInstance3D.new()
			sheet.mesh = quad
			sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var centre_y := floor_y + (float(def.top) + float(def.bottom)) * 0.5
			var along_centre := (along_low + along_high) * 0.5
			if place == 2:
				sheet.position = Vector3(along_centre, centre_y, heightmap_corner.z - float(def.out))
			else:
				var x := heightmap_corner.x - float(def.out) if place == 0 else heightmap_corner.x + float(TerrainConfig.AREA_WIDTH - 1) + float(def.out)
				sheet.position = Vector3(x, centre_y, along_centre)
				sheet.rotation.y = PI * 0.5 # the quad's width along world z
			sheet.name = "Cloud_%s_%d" % [["Left", "Right", "North"][place], index]
			root.add_child(sheet)
			_cloud_sheets.append(sheet)

## The repeating noise the rows' clouds are cut from (built once per run of the game).
static func _cloud_noise_texture() -> ImageTexture:
	if _cloud_noise == null:
		if _cloud_noise_task >= 0:
			WorkerThreadPool.wait_for_task_completion(_cloud_noise_task)
			_cloud_noise_task = -1
		else:
			_render_cloud_noise()
		_cloud_noise = ImageTexture.create_from_image(_cloud_noise_image)
		_cloud_noise_image = null
	return _cloud_noise

## Starts rendering that image on a worker thread (2026-10-10); WorldGenerator calls it before the
## heightmap build. _cloud_noise_texture() waits for it, or renders the image itself.
static var _cloud_noise_task := -1
static var _cloud_noise_image: Image
static func prewarm_cloud_noise() -> void:
	if _cloud_noise == null and _cloud_noise_task < 0:
		_cloud_noise_task = WorkerThreadPool.add_task(_render_cloud_noise)

static func _render_cloud_noise() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 0x434C4F55 # 'CLOU'
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 4
	var image := noise.get_seamless_image(CLOUD_NOISE_SIZE, CLOUD_NOISE_SIZE)
	image.convert(Image.FORMAT_L8)
	image.generate_mipmaps()
	_cloud_noise_image = image

const NODE_NAME := "MountainWalls"
const SHADER_PATH := "res://shaders/mountain_wall.gdshader"
## The mountain models the rows are built from, each cut into three segments by
## tools/blender/cut_mountain_wall.py. "maps": the segments come with their own baked colour and
## normal map (large-scale variation in the shader); the others are shape only.
const SOURCES := {
	"rugged": {"dir": "res://assets/models/mountains/rugged_mountain/", "segments": ["rugged_mountain_a", "rugged_mountain_b", "rugged_mountain_c"], "maps": true},
	"alpine": {"dir": "res://assets/models/mountains/mountain_alpine_style/", "segments": ["mountain_alpine_style_a", "mountain_alpine_style_b", "mountain_alpine_style_c"], "maps": false},
	"horn": {"dir": "res://assets/models/mountains/landscape_sketching/", "segments": ["landscape_sketching_a", "landscape_sketching_b", "landscape_sketching_c"], "maps": false},
	# 2026-10-09, for variety (Kirill): five more of the downloaded models (D:\Downloads\mountains).
	# "lakes" is as steep as "rugged" and comes with maps like it; "lake" is the same kind of
	# range, gentler; "massif" is jagged, "peak" one broad peak, "radial" the steepest of all.
	"lakes": {"dir": "res://assets/models/mountains/mountain_lakes_211109/", "segments": ["mountain_lakes_211109_a", "mountain_lakes_211109_b", "mountain_lakes_211109_c"], "maps": true},
	"lake": {"dir": "res://assets/models/mountains/mountain_lake_211106/", "segments": ["mountain_lake_211106_a", "mountain_lake_211106_b", "mountain_lake_211106_c"], "maps": true},
	# "height" (optional, 1 if absent): the slices' own heights are multiplied by it. These three
	# came out of the cutter with crests 430-720 m above the foot, the older ones 300-440 m.
	"massif": {"dir": "res://assets/models/mountains/mountain_1/", "segments": ["mountain_1_a", "mountain_1_b", "mountain_1_c"], "maps": false, "height": 0.75},
	"peak": {"dir": "res://assets/models/mountains/mountain_2/", "segments": ["mountain_2_a", "mountain_2_b", "mountain_2_c"], "maps": false, "height": 0.85},
	"radial": {"dir": "res://assets/models/mountains/terrain005/", "segments": ["terrain005_a", "terrain005_b", "terrain005_c"], "maps": false, "height": 0.65},
}
const DETAIL_ALBEDO := "res://textures/source/rock_face_03_albedo_1k.png"
const DETAIL_NORMAL := "res://textures/source/rock_face_03_normal_1k.png"
const SEGMENT_LENGTH := 300.0 ## m along the wall, as cut (crest about 300 m above the foot, 420 m deep)
## Every segment ends in the same cross-section (cut_mountain_wall.py: END_OVERLAP, END_BLEND --
## keep these two equal to the tool's). Neighbours overlap by END_OVERLAP, where both are that
## cross-section, so a row has no gaps. To make a whole number of segments fit, each is stretched
## or squeezed along the wall (by 15 % at most).
const END_OVERLAP := 10.0
const END_BLEND := 70.0

## The rows of mountain slices behind the near ridge, nearest first. TUNING -- all of it.
##   "sources"      which of SOURCES the row's segments are drawn from
##   "height_min" / "height_max"  each segment's height is scaled by a random factor between the
##                  two (optional; HEIGHT_SCALE_MIN / MAX otherwise). A wide range gives a row
##                  high peaks and low passes, through which the row behind shows.
##   "size"         scale of a segment's depth and height (1 = as cut)
##   "length"       scale along the wall, before the fit-to-edge stretch
##   "seat"         true: the row stands on the back edge of the apron and follows its height
##                  (_seat_lift), so the apron's peaks run up into it. Its haze and mist hide
##                  that join from the valley; Kirill prefers the fog (2026-10-08: "bring back
##                  the old amount") -- F7 shows the join. It reaches about 630 m out: the next row must start
##                  beyond that, or its front shows the seated row's back poking through.
##                  Otherwise:
##   "out"          m from the map's edge to the row's foot
##   "base"         height of the foot, m above the valley floor
##   "margin"       m the row runs on past both ends of the map + hub (0 until the valley's two
##                  ends are built: a row running on past them hangs in the air there)
##   "haze"         0..1, how far the whole row is veiled toward HAZE_COLOR, on top of the
##                  scene's distance fog (SCENE_FOG_*), which veils everything by distance
##   "mist_full" / "mist_clear"  heights above the valley floor: fully in mist at / below the first,
##                  clear at / above the second ("mist" = its strength, 0 = none). The ridge in
##                  front hides a row's lower part from the valley (from the floor only what is
##                  above about 250..350 m shows of the first row), so the mist must reach well
##                  up the row to be seen at all -- 130..300 m was tried and was invisible.
##   "detail_near" / "detail_far"  size of one rock-texture tile near / far from the camera, m
const ROWS: Array[Dictionary] = [
	{"sources": ["rugged", "lakes"], "size": 1.2, "length": 1.2, "seat": true, "margin": 0.0, "haze": 0.3, "mist": 0.95, "mist_full": 230.0, "mist_clear": 470.0, "detail_near": 40.0, "detail_far": 150.0},
	{"sources": ["alpine", "rugged", "massif", "lake"], "size": 2.4, "length": 2.2, "out": 780.0, "base": 100.0, "margin": 0.0, "height_min": 0.6, "height_max": 1.2, "haze": 0.45, "mist": 1.0, "mist_full": 480.0, "mist_clear": 950.0, "detail_near": 90.0, "detail_far": 350.0},
	{"sources": ["horn", "alpine", "radial", "peak"], "size": 3.6, "length": 2.2, "out": 1500.0, "base": 150.0, "margin": 0.0, "height_min": 0.7, "height_max": 1.3, "haze": 0.55, "mist": 1.0, "mist_full": 800.0, "mist_clear": 1500.0, "detail_near": 160.0, "detail_far": 600.0},
]

## -- The apron --
## Width of the terrain added on the low-X side of the import, m. With AREA_WIDTH it should come to
## a multiple of the region size (128 + 384 = 512), or the rest is padded with holes.
const APRON_WIDTH := 128
## West of the low-X apron the Terrain3D import has this many more columns (2026-10-09): holes,
## except where the village's shoulder stands (TerrainCastle.west_strip_maps). With the two
## aprons and the map they come to 768, three whole regions -- the place of the hole padding the
## import had on its other side before. So the generated map's pixel (0, 0) is MAP_OFFSET_X m in
## +X from the corner Terrain3D reports, no longer APRON_WIDTH.
const WEST_EXTRA := 128
const MAP_OFFSET_X := APRON_WIDTH + WEST_EXTRA
## Its ramp, as [m out from the map's edge, rise per metre]: it leaves the edge at the terrain's
## own grade there (measured, replacing the first entry's value -- already steep, the foot line
## lies inside the map), holds a grade the player cannot walk (45 deg = 1.0), eases off and falls
## away behind the crest. TUNING.
const RAMP_GRADES := [[0.0, 1.0], [10.0, 1.15], [35.0, 1.15], [75.0, 0.1], [90.0, -0.3]]
const RAMP_EDGE_ENTRIES := 1 ## how many leading entries take the measured grade
const RAMP_GRADE_MIN := 0.5 ## the measured grade at the edge is kept within these two
const RAMP_GRADE_MAX := 1.2
const RAMP_GRADE_PROBE := 4 ## m inside the edge the terrain's grade is measured over
const RAMP_GRADE_SMOOTH_RADIUS := 6 ## rows on each side averaged into that grade
## -- The foot line (inside the generated map) --
## How far inside the low-X edge the mountain begins, m: it wanders between these two, in broad
## lobes of about 1 / FOOT_FREQUENCY m with smaller wiggles on them. TUNING.
## 2026-10-09 (Kirill: "the valley is strictly rectangular ... make its shape irregular"): the
## valley itself meanders now (TerrainHeightmap.build_valley_shape), and on the two long sides
## this range is measured from where the floor's edge has moved to: raise_foot adds
## TerrainHeightmap.floor_shift to the line, so the rock follows every bend at the top of the
## forested slope. (A first attempt widened this range to 4..115 m over a straight valley:
## rejected.) Guards, all in raise_foot: the line turns by at most FOOT_LINE_SLOPE m per m along
## the valley; both sides together leave FOOT_MIN_OPEN m of floor; near the map's south end it
## is back within FOOT_END_MAX (the hub's walls carry straight on from there); the castle's
## corner stays open. A cliff, knot or outcrop still pulls it back to its own footprint.
const FOOT_MIN := 4.0
const FOOT_MAX := 34.0
const FOOT_LINE_SLOPE := 1.5
const FOOT_MIN_OPEN := 120.0
const FOOT_END_MAX := 34.0
const FOOT_END_TAPER_START := 30.0 ## m from the south edge up to which FOOT_END_MAX holds; 1 m more per m beyond
const FOOT_CASTLE_GAP := 10.0 ## m of open ground kept between the rock and the castle's low-X face
## Deep inside a headland the ground's extra grade (FOOT_EXTRA_GRADE) eases to FOOT_DEEP_GRADE,
## from FOOT_DEEP_RUN m past the line -- or a 115 m headland would stand 85 m high at the map's edge.
const FOOT_DEEP_RUN := 40.0
const FOOT_DEEP_GRADE := 0.35
## Relief on the rock inside the map (2026-10-09). Its rise depended only on the distance past
## the foot line, the same on every row: fine for a band up to 34 m deep, but since the valley
## meanders the rock is up to 100 m deep there and read as a smooth sheet "procedurally
## stretched out of the mountain" (Kirill). Ribs and gullies up to FOOT_RELIEF m tall, about
## 1 / FOOT_RELIEF_FREQUENCY m apart and FOOT_RELIEF_STRETCH x as long down the slope: nothing
## at FOOT_RELIEF_START m past the line (the wall at the foot stays as it is), full from
## FOOT_RELIEF_FULL m. On top, FOOT_ROUGHNESS m of finer unevenness. TUNING.
const FOOT_RELIEF := 16.0
const FOOT_RELIEF_START := 4.0
const FOOT_RELIEF_FULL := 35.0
const FOOT_RELIEF_FREQUENCY := 1.0 / 55.0
const FOOT_RELIEF_STRETCH := 0.45
const FOOT_ROUGHNESS := 1.2
const FOOT_ROUGHNESS_FREQUENCY := 1.0 / 7.0
## The same at the map's north end, where the mountain closes the valley across its floor: the
## line lies deeper, so the end reads as a wall of rock and not as the map's edge. TUNING.
const NORTH_FOOT_MIN := 20.0
const NORTH_FOOT_MAX := 55.0
const FOOT_FREQUENCY := 1.0 / 75.0
## Past the foot line the ground's grade grows by this much, reached FOOT_EASE m in.
const FOOT_EXTRA_GRADE := 0.75
const FOOT_EASE := 5.0 ## (2026-10-08: 10 -> 5, a clearer break in slope where the rock starts)
## At the foot line the rock starts as a wall, not as a tilt of the ground: this tall (wandering
## between the two along the line), reached FOOT_WALL_RUN m past the line (about 55..75 deg).
## Kirill, 2026-10-08: ground and mountain are separate things -- the ground laps against rock.
const FOOT_WALL_MIN := 5.0
const FOOT_WALL_MAX := 12.0
const FOOT_WALL_RUN := 3.5
const FOOT_WALL_FREQUENCY := 1.0 / 40.0
## The base alternates along the foot line between two forms (Kirill, 2026-10-08: one continuous
## ledge is unrealistic), in stretches of about 1 / FOOT_SECTION_FREQUENCY m:
##  - wall and ledge: the wall above, then a ledge FOOT_LEDGE_WIDTH m deep on which the ground's
##    own rise is taken back by FOOT_LEDGE_FLATTEN per m;
##  - one steep slope with no ledge: FOOT_STEEP_HEIGHT x the wall's height, at up to
##    FOOT_STEEP_GRADE (3.0 = about 72 deg; terrain cannot be vertical or overhang).
const FOOT_SECTION_FREQUENCY := 1.0 / 70.0
const FOOT_LEDGE_WIDTH := 5.0
const FOOT_LEDGE_FLATTEN := 0.5
const FOOT_STEEP_HEIGHT := 1.7
const FOOT_STEEP_GRADE := 3.0
const FOOT_OBSTACLE_GAP := 4.0 ## m the foot line stays clear of cliff / knot / outcrop footprints
## Right at the edge the apron carries on whatever the terrain is doing there (its exact height
## and its local grade, up or down), and blends into the ramp over this many m -- so a hump or a
## hollow that reaches the map's edge runs out on the apron and is not cut off at the edge.
const APRON_EDGE_BLEND := 24.0
const APRON_EDGE_GRADE_PROBE := 3 ## m inside the edge that local grade is measured over
const APRON_EDGE_GRADE_LIMIT := 1.3 ## ... and its largest size, up or down
## The ramp itself starts from the edge's height averaged over this many rows each way, so one
## bump at the edge (or the hub's scarp) does not become a ridge extruded straight up the apron.
const APRON_BASE_SMOOTH_RADIUS := 20
## The foot of the steep face wanders in plan: the ramp is read up to this many m further out or
## nearer than the true distance (spurs standing out into the valley, bays set back), on a
## wavelength of 1 / APRON_PLAN_FREQUENCY m along the edge. TUNING.
const APRON_PLAN_SHIFT := 20.0
const APRON_PLAN_FREQUENCY := 1.0 / 150.0
## Spurs: buttresses running up the face, this tall at most, one every 1 / frequency m or so.
const APRON_SPUR_HEIGHT := 22.0
const APRON_SPUR_FREQUENCY := 1.0 / 55.0
## The ridge's height rises and falls along the valley: everything above its first
## APRON_ENVELOPE_FLOOR m (kept as it is -- that part is what stops the player) is scaled by a
## factor wandering between these two, on a wavelength of about 1 / frequency m. Low stretches
## are saddles that show the mountains behind; high ones are peaks. TUNING.
const APRON_ENVELOPE_MIN := 0.3
const APRON_ENVELOPE_MAX := 1.7
const APRON_ENVELOPE_FREQUENCY := 1.0 / 330.0
const APRON_ENVELOPE_FLOOR := 28.0
## Where that factor is high the ridge does not fall away behind its crest but keeps rising to
## the apron's back edge, up into the mountain row seated there: fully from the second value,
## not at all below the first. The rise per metre, from APRON_CONNECT_START m out.
const APRON_CONNECT_ENVELOPE_NONE := 1.0
const APRON_CONNECT_ENVELOPE_FULL := 1.35
const APRON_CONNECT_GRADE := 0.8
const APRON_CONNECT_START := 70.0
## The mountain row seated on the apron (ROWS, "seat"): it starts this far inside the apron's
## back edge and this far below it, and its ground rises by SEAT_GRADE at first, levelling off
## after about SEAT_RUN m.
const SEAT_OVERLAP := 6.0
const SEAT_SINK := 6.0
const SEAT_GRADE := 0.45
const SEAT_RUN := 150.0
const SEAT_SMOOTH_RADIUS := 8 ## rows each way averaged into the height the row follows
## Where the apron is low (a saddle) the seated row is low too: its own heights are scaled from
## this (apron at its lowest) to 1 (at its highest) -- the saddles are the windows through which
## the rows behind are seen from the valley.
const SEAT_SADDLE_HEIGHT := 0.3
## -- Debris along the foot line (scatter_foot_debris) --
## Boulders: one per this many m of line on average, lying up to FOOT_BOULDER_REACH m out into
## the valley from the line (most of them near it), scaled within the range.
const FOOT_BOULDER_SPACING := 7.0
const FOOT_BOULDER_REACH := 9.0
const FOOT_BOULDER_SCALE_MIN := 0.7
const FOOT_BOULDER_SCALE_MAX := 2.2
## 2026-10-10 (Kirill: "the boulders and scree are sometimes placed on very steep cliffs on the
## mountain ridge terrains"): were 0.6 for boulders (53 deg) and 0.45 for scree (63 deg), read at
## the one point where the stone stands. Now about 35 and 41 deg, and the steepest of five
## readings counts: the spot itself and FOOT_SLOPE_PROBE x the stone's scale to each side, so a
## stone on a narrow ledge under a face is refused too.
const FOOT_BOULDER_MIN_NORMAL_Y := 0.82 ## no boulder on steeper ground than this
const FOOT_SCREE_MIN_NORMAL_Y := 0.75
const FOOT_SLOPE_PROBE := 0.8 ## m per unit of scale
## Scree stones: this many per m of line, from FOOT_SCREE_BACK m up the rock to FOOT_SCREE_REACH
## m out, enlarged (the scree meshes are 4-23 cm stones).
const FOOT_SCREE_PER_METRE := 4.0
const FOOT_SCREE_BACK := 3.0
const FOOT_SCREE_REACH := 8.0
const FOOT_SCREE_SCALE_MIN := 1.0
const FOOT_SCREE_SCALE_MAX := 3.2
## Rock structure at the base: the apron's rise is cut into bands APRON_TERRACE_HEIGHT m tall, each a steep
## face (the first APRON_TERRACE_FACE of the band's climb) and a ledge above it. The bands' level
## is shifted by up to APRON_TERRACE_WARP m by noise, so ledges are not contour lines, and
## APRON_TERRACE_STRENGTH < 1 leaves the ledges a little slope. TUNING.
const APRON_TERRACE_HEIGHT := 11.0
const APRON_TERRACE_FACE := 0.4
const APRON_TERRACE_WARP := 5.0
const APRON_TERRACE_FREQUENCY := 1.0 / 45.0
const APRON_TERRACE_STRENGTH := 0.85
## The bands are only cut into the base: fully up to 0.4 x this rise above the edge, not at all
## above it -- and only along the wall-and-ledge stretches of the foot line (_ledge_share).
const APRON_TERRACE_TOP := 30.0
## Colour variety, all from the apron's shape (no noise blobs): creases darker and edges lighter
## (per m of curvature, within the two limits), faint layers every APRON_STRATA_PERIOD m of
## height, and turf on ledges (normal.y between the two values) up to APRON_TURF_TOP m above
## the map's edge, fading out over the last APRON_TURF_FADE m.
const APRON_COLOR_BLEND := 20.0 ## m from the map's edge over which the apron's own shading replaces the map's colour
const APRON_CREASE_SHADE := 0.2
const APRON_CREASE_MIN := 0.7
const APRON_CREASE_MAX := 1.1
const APRON_STRATA_PERIOD := 9.0
const APRON_STRATA_SHADE := 0.07
const APRON_TURF_NY_NONE := 0.93
const APRON_TURF_NY_FULL := 0.985
const APRON_TURF_TOP := 110.0
const APRON_TURF_FADE := 40.0
const APRON_TURF_AMOUNT := 0.65
const APRON_TURF_ID := 5 ## TerrainGroundPaint.GRASS_ID
const APRON_TURF_TINT := Color(0.8, 0.9, 0.75) ## the colour map over turf (not the rock's grey tint)
## Snow on the apron's tips (2026-10-08): the terrain's Snow texture (id 9, registered by
## tools/assign_flat_textures.gd from tools/make_snow_texture.py's noise-built pair) from
## APRON_SNOW_FROM m above the map's edge, complete at APRON_SNOW_FULL, the line shifted by up to
## APRON_SNOW_WANDER m by noise; none on ground steeper than the first normal.y, all on ground
## flatter than the second. Under snow the colour map is APRON_SNOW_TINT, not the rock's tint.
const APRON_SNOW_ID := 9
const APRON_SNOW_FROM := 75.0
const APRON_SNOW_FULL := 125.0
const APRON_SNOW_WANDER := 18.0
const APRON_SNOW_NY_NONE := 0.42
const APRON_SNOW_NY_FULL := 0.7
const APRON_SNOW_TINT := Color(0.86, 0.9, 1.0)
## Snow on the mountain rows: from this height above the valley floor (about where the apron's
## begins), complete SNOW_FADE m higher, on ground flatter than the shader's snow slope limits.
const SNOW_LINE := 150.0
const SNOW_FADE := 220.0
const SNOW_COLOR := Color(0.72, 0.78, 0.9)
## Ridges and gullies added on top of the ramp: nothing at the edge, full height from
## APRON_RELIEF_FULL m out.
const APRON_RELIEF := 45.0
const APRON_RELIEF_START := 12.0
const APRON_RELIEF_FULL := 70.0
const APRON_RELIEF_FREQUENCY := 1.0 / 110.0
## Its ground: bare rock face everywhere (a noise mix of two rocks looked like a cow's hide, and
## the mossy rock on its gentler parts read as soil on a mountain), with a mild brightness
## variation in the colour map.
const APRON_ROCK := 2 ## TerrainGroundPaint.ROCK_FACE_ID
## The texture id every piece of mountain terrain is painted with: the aprons, the north end, the
## village's shoulder and the rock past the foot line on the map. 2026-10-10: a texture of its
## own ("MountainRock", the RockFace images again), so the mountain's displacement and tile size
## can differ from the rock ground at the valley's cliffs. WorldGenerator registers it at startup
## and sets this (_ensure_mountain_texture); APRON_ROCK is what it stays at if that fails.
static var rock_texture_id := APRON_ROCK
const APRON_SHADE_FREQUENCY := 1.0 / 60.0
const APRON_SHADE_MIN := 0.86
## WorldBounds' invisible wall on this side stands this far out from the map's edge, m. The
## apron is too steep to walk before that, also in its bays (the steep face starts up to
## APRON_PLAN_SHIFT m later there).
const WALK_DEPTH := 60.0
## The rows behind the castle end (TerrainCastle), running across the valley. Same keys as ROWS;
## "out" = m north of the castle block's far edge. "seat" true: the row stands on that edge and
## follows its height (_north_seat_lift) -- at a level base its foot hung about 90 m above the
## low ground behind the bay. They run END_ROW_MARGIN m past both sides, behind the side rows' ends.
## "seat_at" (instead of "seat"): the row stands ON the north apron, its foot that many m north of
## the map's edge, and is draped over the apron's ground behind its foot (NORTH_DRAPE_*), so the
## terrain never shows through it.
## The first entry is such a row, a "half-cascade" (Kirill, 2026-10-09): from the valley the
## north mountains looked too far behind the terrain ridge, the height not gradual as on the
## sides -- the full row behind it has its crest about 850 m from the map's edge, where the
## sides' first row has it at about 520 m. This one starts just behind the ridge's crest, at half
## the next row's size. TUNING.
## "fixed" (optional): the row's slices from low X to high X as [slice, height factor] -- the same
## on every seed, in place of the random pick. All three rows are pinned (Kirill, 2026-10-09: "I
## like the moon between the two peaks, I'd like to make that permanent"): this is the range of
## seed 1541671226, where from the hub's plateau the moon stands between the two peaks of the
## far row. The moon's place is the DirectionalLight3D's rotation in main.tscn (about -37.5,
## 178.8, 82.0 deg: 37.5 deg up, due north). Changing a row's "length", END_ROW_MARGIN or the
## map's width changes how many segments fit and where the peaks stand.
const END_ROWS: Array[Dictionary] = [
	{"fixed": [["rugged_mountain_b", 1.0268], ["rugged_mountain_c", 0.9542], ["mountain_lakes_211109_c", 1.1315], ["mountain_lakes_211109_b", 1.0116], ["rugged_mountain_b", 0.8973]],
		"sources": ["rugged", "lakes"], "size": 0.9, "length": 1.0, "seat_at": 105.0, "height_min": 0.8, "height_max": 1.15, "haze": 0.15, "mist": 0.6, "mist_full": 110.0, "mist_clear": 300.0, "detail_near": 30.0, "detail_far": 120.0},
	{"fixed": [["mountain_1_b", 0.8267], ["mountain_1_c", 0.8718], ["mountain_lakes_211109_a", 1.1111]],
		"sources": ["rugged", "alpine", "lakes", "massif"], "size": 1.8, "length": 1.6, "seat": true, "height_min": 0.7, "height_max": 1.2, "haze": 0.3, "mist": 0.9, "mist_full": 230.0, "mist_clear": 470.0, "detail_near": 60.0, "detail_far": 220.0},
	{"fixed": [["mountain_alpine_style_b", 1.2214], ["mountain_2_b", 1.2926]],
		"sources": ["horn", "alpine", "radial", "peak", "lake"], "size": 3.6, "length": 2.2, "out": 700.0, "base": 150.0, "height_min": 0.8, "height_max": 1.3, "haze": 0.55, "mist": 1.0, "mist_full": 800.0, "mist_clear": 1500.0, "detail_near": 160.0, "detail_far": 600.0},
]
const END_ROW_MARGIN := 420.0
## A north row over the apron keeps this far above the apron's ground, from NORTH_DRAPE_RUN m
## behind its foot (at the foot itself it is sunk by SEAT_SINK, like every seated row).
const NORTH_DRAPE_CLEAR := 1.5
const NORTH_DRAPE_RUN := 20.0
## Each segment's heights are scaled by a random factor in this range (the skyline varies more);
## the scaling fades out toward both ends, where neighbours must agree.
const HEIGHT_SCALE_MIN := 0.85
const HEIGHT_SCALE_MAX := 1.15
## The mountain's colour. The rock texture it is drawn with (rock_face_03) is a warm brown -- on
## its own a mountain face in it reads as soil. This is multiplied into it wherever the ground is
## mountain (the rows, the apron's colour map, the map's ground past the foot line): it takes the
## red and green down until the brown comes out a neutral, darker grey. TUNING.
const MOUNTAIN_TINT := Color(0.55, 0.70, 1.0)
const TINT := MOUNTAIN_TINT
## What rows fade into with distance, and the paler colour of the mist at their feet (both unlit,
## so they are the same in shadow). TUNING: the sky's horizon colour is (0.35, 0.40, 0.51); the
## first values tried, a tenth of that, drew as black.
const HAZE_COLOR := Color(0.2, 0.235, 0.31)
const MIST_COLOR := Color(0.3, 0.35, 0.45)
## The rows' own veil is none nearer than VEIL_NEAR m from the camera and complete from VEIL_FAR
## (flying up to a row, its rock shows -- before, the mist was a flat grey coat on it). The
## seated row also starts clear at its join with the apron and gains its veil over
## SEAT_VEIL_RAMP m going back, so no line runs along the apron's crest.
const VEIL_NEAR := 120.0
const VEIL_FAR := 600.0
const SEAT_VEIL_RAMP := 240.0
## Distance fog on the whole scene, set on the WorldEnvironment at startup (build): what makes
## terrain ridge, mountain rows and far forest fade together. None nearer than SCENE_FOG_BEGIN m,
## SCENE_FOG_DENSITY of the fog colour at SCENE_FOG_END m; the sky is left alone. TUNING.
const SCENE_FOG_BEGIN := 150.0
const SCENE_FOG_END := 3200.0
const SCENE_FOG_CURVE := 0.75 ## below 1 = more of the fog arrives early
const SCENE_FOG_DENSITY := 0.9
const SCENE_FOG_SKY_BLEND := 0.35 ## how far the fog takes the sky's colour behind it

## Builds the walls under `parent_node` (deferred, like the other generated nodes).
static func build(parent_node: Node, maps: Dictionary, heightmap_corner: Vector3, master_seed: int) -> void:
	var t0 := Time.get_ticks_msec()
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	var shader := load(SHADER_PATH) as Shader
	var loaded: Dictionary = {} # source name -> Array[Dictionary], one per segment
	for source_name: String in SOURCES:
		var source_def: Dictionary = SOURCES[source_name]
		var segments: Array[Dictionary] = []
		for segment: String in source_def.segments:
			var source := _load_segment(source_def.dir, segment, source_def.maps)
			if source.is_empty() or shader == null:
				push_warning("TERRAIN_GEN: mountain wall segment %s (or its shader) could not be loaded -- walls skipped" % segment)
				return
			source["height"] = float(source_def.get("height", 1.0))
			segments.append(source)
		loaded[source_name] = segments

	var root := Node3D.new()
	root.name = NODE_NAME
	_fog_materials = []
	_fog_shown = true
	_clouds_shown = true
	_apply_scene_fog(parent_node)
	var rng := RandomNumberGenerator.new()
	rng.seed = master_seed ^ 0x57414C4C # 'WALL' salt
	var edge_length := float(TerrainConfig.AREA_LENGTH + TerrainHub.STRIP_LENGTH)
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	var tris := 0
	var placed := 0
	var summary: Array[String] = []
	for side in 2:
		for row_index in ROWS.size():
			var row: Dictionary = ROWS[row_index]
			var size: float = row.size
			var margin: float = row.margin
			var total_length := edge_length + 2.0 * margin + float(TerrainCastle.LENGTH) # the castle end's sides too
			var pitch := (SEGMENT_LENGTH - END_OVERLAP) * float(row.length) # between neighbours' centres, unstretched
			var count := maxi(1, roundi(total_length / pitch))
			var spacing := total_length / float(count)
			var length_scale := float(row.length) * spacing / pitch
			# A segment's depth axis is its +X: as cut for the high-X side, half a turn about Y for the low-X side.
			var seated: bool = row.get("seat", false)
			var out: float = float(APRON_WIDTH) - SEAT_OVERLAP if seated else float(row.out)
			var x := heightmap_corner.x - out if side == 0 else heightmap_corner.x + float(TerrainConfig.AREA_WIDTH - 1) + out
			var facing := Basis(Vector3.UP, PI) if side == 0 else Basis.IDENTITY
			var lift: Callable = _seat_lift.bind(heightmap_corner.z, x, side) if seated else _level_lift.bind(floor_y + float(row.base))
			var sources: Array[Dictionary] = []
			for source_name: String in row.sources:
				sources.append_array(loaded[source_name])
			var materials: Array[ShaderMaterial] = []
			for source in sources:
				var material := _row_material(shader, source, row, floor_y)
				if seated: # clear at the join with the apron, the veil growing behind it
					material.set_shader_parameter("veil_ramp", SEAT_VEIL_RAMP)
					material.set_shader_parameter("veil_ramp_x", x)
					material.set_shader_parameter("veil_ramp_side", 1.0 if side == 0 else -1.0)
				materials.append(material)
			var tall: Callable = _seat_tall.bind(heightmap_corner.z, side) if seated else _full_tall
			var height_min: float = row.get("height_min", HEIGHT_SCALE_MIN)
			var height_max: float = row.get("height_max", HEIGHT_SCALE_MAX)
			var last_pick := -1
			for i in count:
				var pick := rng.randi_range(0, sources.size() - 1)
				if pick == last_pick: # never the same slice twice in a row
					pick = (pick + 1 + rng.randi_range(0, sources.size() - 2)) % sources.size()
				last_pick = pick
				var origin := Vector3(x, 0.0, heightmap_corner.z - float(TerrainCastle.LENGTH) - margin + (float(i) + 0.5) * spacing)
				var scale := Vector3(size, size * rng.randf_range(height_min, height_max) * float(sources[pick].height), length_scale)
				var instance := _place(sources[pick], Transform3D(facing, origin), scale, lift, tall)
				instance.material_override = materials[pick]
				instance.name = "%s_row%d_%02d_%s" % ["Left" if side == 0 else "Right", row_index, i, sources[pick].name]
				root.add_child(instance)
				tris += int(sources[pick].tris)
				placed += 1
			if side == 0:
				summary.append("row %d (%s): %d x %.0f m" % [row_index, " + ".join(row.sources), count, spacing])
	parent_node.add_child.call_deferred(root)
	# Behind the castle end: rows across the valley, their depth axis toward -Z (a quarter turn).
	var end_span := float(TerrainConfig.AREA_WIDTH + 2 * APRON_WIDTH) + 2.0 * END_ROW_MARGIN
	for row_index in END_ROWS.size():
		var row: Dictionary = END_ROWS[row_index]
		var pitch := (SEGMENT_LENGTH - END_OVERLAP) * float(row.length)
		var count := maxi(1, roundi(end_span / pitch))
		var spacing := end_span / float(count)
		var sources: Array[Dictionary] = []
		for source_name: String in row.sources:
			sources.append_array(loaded[source_name])
		var materials: Array[ShaderMaterial] = []
		for source in sources:
			materials.append(_row_material(shader, source, row, floor_y))
		var seat_at: float = row.get("seat_at", -1.0) # m north of the map's edge, on the apron
		var seated: bool = row.get("seat", false) or seat_at >= 0.0
		var foot_north := seat_at if seat_at >= 0.0 else (float(TerrainCastle.LENGTH) - SEAT_OVERLAP if seated else float(TerrainCastle.LENGTH) + float(row.get("out", 0.0)))
		var z := heightmap_corner.z - foot_north
		var lift: Callable = _north_seat_lift.bind(heightmap_corner.x - float(MAP_OFFSET_X), z, heightmap_corner.z, TerrainCastle.north_row_heights(foot_north)) if seated else _level_lift.bind(floor_y + float(row.base))
		var fixed: Array = row.get("fixed", [])
		var last_pick := -1
		for i in count:
			var pick := -1
			var height_factor := 1.0
			if i < fixed.size():
				# A pinned row: this slice at this height on every seed (see END_ROWS).
				for k in sources.size():
					if sources[k].name == fixed[i][0]:
						pick = k
				height_factor = float(fixed[i][1])
				if pick < 0:
					push_warning("TERRAIN_GEN: north row %d wants slice %s, which is not among its sources -- using another" % [row_index, fixed[i][0]])
					pick = 0
			else:
				pick = rng.randi_range(0, sources.size() - 1)
				if pick == last_pick:
					pick = (pick + 1 + rng.randi_range(0, sources.size() - 2)) % sources.size()
				height_factor = rng.randf_range(float(row.height_min), float(row.height_max))
			last_pick = pick
			var origin := Vector3(heightmap_corner.x - float(APRON_WIDTH) - END_ROW_MARGIN + (float(i) + 0.5) * spacing, 0.0, z)
			var scale := Vector3(float(row.size), float(row.size) * height_factor * float(sources[pick].height), float(row.length) * spacing / pitch)
			var instance := _place(sources[pick], Transform3D(Basis(Vector3.UP, PI * 0.5), origin), scale, lift, _full_tall)
			instance.material_override = materials[pick]
			instance.name = "North_row%d_%02d_%s" % [row_index, i, sources[pick].name]
			root.add_child(instance)
			tris += int(sources[pick].tris)
			placed += 1
		summary.append("north row %d (%s): %d x %.0f m" % [row_index, " + ".join(row.sources), count, spacing])
	_build_cloud_sheets(root, heightmap_corner, floor_y, rng)
	if not FOG_ON_AT_START:
		toggle_fog()
	print("TERRAIN_GEN: mountain walls, per side -- %s; %d segment(s) on both sides and the north end, %d tris; %d cloud sheet(s) (%d ms)" % ["; ".join(summary), placed, tris, _cloud_sheets.size(), Time.get_ticks_msec() - t0])

## One side's apron maps for the Terrain3D import, APRON_WIDTH wide and one row per row of the
## map + hub, row-major, column 0 = the lowest world x (the outer edge on the low-X side, the
## map's edge on the high-X side): {heights: PackedFloat32Array,
## control: PackedInt32Array (packed control pixels), color: PackedByteArray (RGBA8)}.
static func apron_maps(maps: Dictionary, master_seed: int, side: int = 0) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var rim := _rim_profile(maps, 0 if side == 0 else TerrainConfig.AREA_WIDTH - 1)
	var side_seed := master_seed + side * 7919 # each side its own shapes
	var rows: int = (rim.height as PackedFloat32Array).size()
	var relief_noise := _apron_noise(side_seed ^ 0x4E454152, APRON_RELIEF_FREQUENCY, FastNoiseLite.FRACTAL_RIDGED, 4) # 'NEAR'
	var plan_noise := _apron_noise(side_seed ^ 0x504C414E, APRON_PLAN_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 2) # 'PLAN'
	var spur_noise := _apron_noise(side_seed ^ 0x53505552, APRON_SPUR_FREQUENCY, FastNoiseLite.FRACTAL_RIDGED, 2) # 'SPUR'
	var shade_noise := _apron_noise(side_seed ^ 0x53484144, APRON_SHADE_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 3) # 'SHAD'
	var envelope_noise := _apron_noise(side_seed ^ 0x454E5645, APRON_ENVELOPE_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 2) # 'ENVE'
	var terrace_noise := _apron_noise(side_seed ^ 0x54455252, APRON_TERRACE_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 2) # 'TERR'

	# -- Heights --
	var heights := PackedFloat32Array()
	heights.resize(APRON_WIDTH * rows)
	var crest_min := INF
	var crest_max := -INF
	# The ramp only depends on the (shifted) distance out and on the grade at the edge: one
	# table per grade in steps of 0.01, read between its 1 m entries.
	var table_size := APRON_WIDTH + int(APRON_PLAN_SHIFT) + 2
	var ramp_tables: Dictionary = {}
	for row in rows:
		var grade_key := roundi(float(rim.grade[row]) * 100.0)
		if not ramp_tables.has(grade_key):
			var table := PackedFloat32Array()
			table.resize(table_size)
			for out in table_size:
				table[out] = _ramp_height(float(out), grade_key / 100.0)
			ramp_tables[grade_key] = table
	# 2026-10-10: the rows in bands on worker threads (see _apron_height_band; each side was
	# 0.3 s of heights on the main thread). A row depends on nothing but its own inputs, so the
	# result is the single loop's.
	_ledge_share(master_seed, 0, side) # builds the shared section noise before the bands read it
	var bands := ceili(float(rows) / APRON_BAND_ROWS)
	var height_out: Array = []
	height_out.resize(bands)
	var height_ctx := {
		"rows": rows, "side": side, "master_seed": master_seed, "table_size": table_size, "ramp_tables": ramp_tables,
		"grade": rim.grade, "edge_height": rim.height, "edge_grade": rim.local_grade, "base_height": rim.smooth_height,
		"plan_noise": plan_noise, "envelope_noise": envelope_noise, "spur_noise": spur_noise, "relief_noise": relief_noise, "terrace_noise": terrace_noise,
		"out": height_out, "mutex": Mutex.new(),
	}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_apron_height_band.bind(height_ctx), bands, TerrainUtil.object_call_threads(), true))
	heights.clear()
	var envelopes := PackedFloat32Array()
	for b: Dictionary in height_out:
		heights.append_array(b.heights)
		envelopes.append_array(b.envelopes)
		crest_min = minf(crest_min, b.crest_min)
		crest_max = maxf(crest_max, b.crest_max)
	apron_envelope[side] = envelopes
	# The village's shoulder, on the low-X side (TerrainCastle): the higher of the two heights,
	# before anything is derived from the shape. Bare rock where it is: no turf, no snow.
	var on_shoulder := PackedByteArray()
	if side == 0:
		on_shoulder = TerrainCastle.raise_massif_on_apron(heights, APRON_WIDTH, rows, maps.heights)

	var back := PackedFloat32Array()
	back.resize(rows)
	for row in rows:
		back[row] = heights[row * APRON_WIDTH + (0 if side == 0 else APRON_WIDTH - 1)] # the outer column
	apron_back_heights[side] = _row_average(back, SEAT_SMOOTH_RADIUS)

	# -- Ground and colour, from the finished shape --
	var control := PackedInt32Array()
	var color := PackedByteArray()
	var turf_px := 0
	var snow_px := 0
	# The generated map's own colour-map pixels along the edge (its hub rows have none: white).
	var map_color := PackedByteArray()
	if maps.get("color") is Image and (maps.color as Image).get_format() == Image.FORMAT_RGBA8:
		map_color = (maps.color as Image).get_data()
	# In bands on worker threads, as the heights above (see _apron_color_band).
	var color_out: Array = []
	color_out.resize(bands)
	var color_ctx := {
		"rows": rows, "side": side, "heights": heights, "edge_height": rim.height, "on_shoulder": on_shoulder,
		"map_color": map_color, "shade_noise": shade_noise, "rock_id": rock_texture_id,
		"out": color_out, "mutex": Mutex.new(),
	}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_apron_color_band.bind(color_ctx), bands, TerrainUtil.object_call_threads(), true))
	for b: Dictionary in color_out:
		control.append_array(b.control)
		color.append_array(b.color)
		turf_px += b.turf_px
		snow_px += b.snow_px
	print("TERRAIN_GEN: mountain apron -- %d x %d m of terrain on the %s side, crest %.0f..%.0f m above the map's edge, turf on %.1f %% of it, snow on %.1f %% (%d ms)" % [APRON_WIDTH, rows, "low-X" if side == 0 else "high-X", crest_min, crest_max, 100.0 * turf_px / float(APRON_WIDTH * rows), 100.0 * snow_px / float(APRON_WIDTH * rows), Time.get_ticks_msec() - t0])
	return {"heights": heights, "control": control, "color": color}

const APRON_BAND_ROWS := 32 ## rows per worker-thread task in apron_maps()

## apron_maps()'s heights for rows [band * APRON_BAND_ROWS, +APRON_BAND_ROWS). Worker thread: reads
## the shared inputs in ctx, fills band-sized outputs of its own, stores them under ctx.mutex.
static func _apron_height_band(band: int, ctx: Dictionary) -> void:
	var rows: int = ctx.rows
	var side: int = ctx.side
	var master_seed: int = ctx.master_seed
	var table_size: int = ctx.table_size
	var ramp_tables: Dictionary = ctx.ramp_tables
	var grades: PackedFloat32Array = ctx.grade
	var edge_heights: PackedFloat32Array = ctx.edge_height
	var edge_grades: PackedFloat32Array = ctx.edge_grade
	var base_heights: PackedFloat32Array = ctx.base_height
	var plan_noise: FastNoiseLite = ctx.plan_noise
	var envelope_noise: FastNoiseLite = ctx.envelope_noise
	var spur_noise: FastNoiseLite = ctx.spur_noise
	var relief_noise: FastNoiseLite = ctx.relief_noise
	var terrace_noise: FastNoiseLite = ctx.terrace_noise
	var r_from := band * APRON_BAND_ROWS
	var r_to := mini(r_from + APRON_BAND_ROWS, rows)
	var heights := PackedFloat32Array()
	heights.resize(APRON_WIDTH * (r_to - r_from))
	var envelopes := PackedFloat32Array()
	envelopes.resize(r_to - r_from)
	var crest_min := INF
	var crest_max := -INF
	for row in range(r_from, r_to):
		var ramp: PackedFloat32Array = ramp_tables[roundi(float(grades[row]) * 100.0)]
		var edge_height: float = edge_heights[row]
		var edge_grade: float = edge_grades[row]
		var base_height: float = base_heights[row]
		var plan_shift := plan_noise.get_noise_1d(float(row)) * APRON_PLAN_SHIFT
		var envelope := lerpf(APRON_ENVELOPE_MIN, APRON_ENVELOPE_MAX, smoothstep(-0.4, 0.4, envelope_noise.get_noise_1d(float(row))))
		var connect := smoothstep(APRON_CONNECT_ENVELOPE_NONE, APRON_CONNECT_ENVELOPE_FULL, envelope)
		var ledge_share := _ledge_share(master_seed, row, side)
		envelopes[row - r_from] = (envelope - APRON_ENVELOPE_MIN) / (APRON_ENVELOPE_MAX - APRON_ENVELOPE_MIN)
		var crest := -INF
		for a in APRON_WIDTH:
			var out := float(APRON_WIDTH - a if side == 0 else a + 1) # m out from the map's edge
			# The ramp, read nearer or further out (never before its own start).
			var shifted := maxf(out + plan_shift * smoothstep(0.0, APRON_EDGE_BLEND, out), out * 0.35)
			var s0 := mini(int(shifted), table_size - 2)
			var rise := lerpf(ramp[s0], ramp[s0 + 1], shifted - float(s0))
			rise += smoothstep(8.0, 50.0, shifted) * APRON_SPUR_HEIGHT * (0.5 + 0.5 * spur_noise.get_noise_2d(out * 0.25, float(row)))
			rise += smoothstep(APRON_RELIEF_START, APRON_RELIEF_FULL, shifted) * APRON_RELIEF * (0.5 + 0.5 * relief_noise.get_noise_2d(out, float(row)))
			# Taller or lower along the valley (not the first metres), and at the peaks no fall behind the crest.
			rise = minf(rise, APRON_ENVELOPE_FLOOR) + envelope * maxf(rise - APRON_ENVELOPE_FLOOR, 0.0)
			rise += connect * APRON_CONNECT_GRADE * maxf(shifted - APRON_CONNECT_START, 0.0)
			# Faces and ledges, at the base only (and none in the first metres, where the apron still follows the map's edge).
			var shift := terrace_noise.get_noise_2d(out, float(row)) * APRON_TERRACE_WARP
			var steps := (rise + shift) / APRON_TERRACE_HEIGHT
			var stepped := (floorf(steps) + smoothstep(0.0, APRON_TERRACE_FACE, steps - floorf(steps))) * APRON_TERRACE_HEIGHT - shift
			rise = lerpf(rise, stepped, APRON_TERRACE_STRENGTH * ledge_share * smoothstep(4.0, 20.0, out) * (1.0 - smoothstep(APRON_TERRACE_TOP * 0.4, APRON_TERRACE_TOP, rise)))
			var body := base_height + rise
			var near := edge_height + edge_grade * out
			var h := lerpf(near, body, smoothstep(0.0, APRON_EDGE_BLEND, out))
			heights[(row - r_from) * APRON_WIDTH + a] = h
			crest = maxf(crest, h - edge_height)
		crest_min = minf(crest_min, crest)
		crest_max = maxf(crest_max, crest)
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = {"heights": heights, "envelopes": envelopes, "crest_min": crest_min, "crest_max": crest_max}
	mutex.unlock()

## apron_maps()'s ground and colour for one band of rows, from the finished heights. Worker
## thread, same rules; the control pixels are packed here (TerrainGroundPaint._pack, the same
## bits as TerrainHeightmap.pack_control_blend without its GDExtension calls).
static func _apron_color_band(band: int, ctx: Dictionary) -> void:
	var rows: int = ctx.rows
	var side: int = ctx.side
	var heights: PackedFloat32Array = ctx.heights
	var edge_heights: PackedFloat32Array = ctx.edge_height
	var on_shoulder: PackedByteArray = ctx.on_shoulder
	var map_color: PackedByteArray = ctx.map_color
	var shade_noise: FastNoiseLite = ctx.shade_noise
	var rock_id: int = ctx.rock_id
	var r_from := band * APRON_BAND_ROWS
	var r_to := mini(r_from + APRON_BAND_ROWS, rows)
	var control := PackedInt32Array()
	control.resize(APRON_WIDTH * (r_to - r_from))
	var color := PackedByteArray()
	color.resize(APRON_WIDTH * (r_to - r_from) * 4)
	var turf_px := 0
	var snow_px := 0
	var map_width := TerrainConfig.AREA_WIDTH
	for row in range(r_from, r_to):
		var r0 := maxi(row - 1, 0)
		var r1 := mini(row + 1, rows - 1)
		var edge_height: float = edge_heights[row]
		# What the map's ground is coloured right at the edge (the ground paint multiplies the
		# mountain's tint into the map's colour there): the apron starts from exactly that and
		# takes its own shading over APRON_COLOR_BLEND m, or a straight line shows at the edge.
		var edge_color := Color(MOUNTAIN_TINT.r, MOUNTAIN_TINT.g, MOUNTAIN_TINT.b)
		if row < TerrainConfig.AREA_LENGTH and not map_color.is_empty():
			var e := (row * map_width + (0 if side == 0 else map_width - 1)) * 4
			edge_color = Color(map_color[e] / 255.0 * MOUNTAIN_TINT.r, map_color[e + 1] / 255.0 * MOUNTAIN_TINT.g, map_color[e + 2] / 255.0 * MOUNTAIN_TINT.b)
		for a in APRON_WIDTH:
			var i := row * APRON_WIDTH + a
			var li := (row - r_from) * APRON_WIDTH + a
			var a0 := maxi(a - 1, 0)
			var a1 := mini(a + 1, APRON_WIDTH - 1)
			var h := heights[i]
			var h_a0 := heights[row * APRON_WIDTH + a0]
			var h_a1 := heights[row * APRON_WIDTH + a1]
			var h_r0 := heights[r0 * APRON_WIDTH + a]
			var h_r1 := heights[r1 * APRON_WIDTH + a]
			var dx := (h_a1 - h_a0) / float(maxi(a1 - a0, 1))
			var dz := (h_r1 - h_r0) / float(maxi(r1 - r0, 1))
			var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
			# Turf on ledges, low on the mountain only.
			var turf := smoothstep(APRON_TURF_NY_NONE, APRON_TURF_NY_FULL, ny) * (1.0 - smoothstep(APRON_TURF_TOP - APRON_TURF_FADE, APRON_TURF_TOP, h - edge_height)) * APRON_TURF_AMOUNT
			var bare := not on_shoulder.is_empty() and on_shoulder[i] == 1
			if bare:
				turf = 0.0
			if turf > 0.02:
				turf_px += 1
			control[li] = TerrainGroundPaint._pack(rock_id, APRON_TURF_ID, turf)
			# Snow on the tips (turf never reaches this high).
			var snow := smoothstep(APRON_SNOW_FROM, APRON_SNOW_FULL, h - edge_height + APRON_SNOW_WANDER * shade_noise.get_noise_2d(float(a) * 2.0 + 50.0, float(row) * 2.0)) * smoothstep(APRON_SNOW_NY_NONE, APRON_SNOW_NY_FULL, ny)
			if bare:
				snow = 0.0
			if snow > 0.02:
				snow_px += 1
				control[li] = TerrainGroundPaint._pack(rock_id, APRON_SNOW_ID, snow)
			# Brightness: creases darker, edges lighter; faint layers by height; a mild broad variation.
			var curvature := h_a0 + h_a1 + h_r0 + h_r1 - 4.0 * h # > 0 in a crease
			var shade := clampf(1.0 - curvature * APRON_CREASE_SHADE, APRON_CREASE_MIN, APRON_CREASE_MAX) / APRON_CREASE_MAX
			shade *= 1.0 - APRON_STRATA_SHADE * (0.5 + 0.5 * sin((h + 4.0 * shade_noise.get_noise_2d(float(a) * 3.0, float(row) * 3.0)) * TAU / APRON_STRATA_PERIOD))
			shade *= lerpf(APRON_SHADE_MIN, 1.0, 0.5 + 0.5 * shade_noise.get_noise_2d(float(a), float(row)))
			var tint := MOUNTAIN_TINT.lerp(APRON_TURF_TINT, turf).lerp(APRON_SNOW_TINT, snow)
			shade = lerpf(shade, 1.0, snow * 0.7) # snow fills creases and covers the rock's layers
			var own := Color(shade * tint.r, shade * tint.g, shade * tint.b)
			var final := edge_color.lerp(own, smoothstep(0.0, APRON_COLOR_BLEND, float(APRON_WIDTH - a if side == 0 else a + 1)))
			color[li * 4] = int(255.0 * final.r)
			color[li * 4 + 1] = int(255.0 * final.g)
			color[li * 4 + 2] = int(255.0 * final.b)
			color[li * 4 + 3] = 128 # roughness left as it is
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = {"control": control, "color": color, "turf_px": turf_px, "snow_px": snow_px}
	mutex.unlock()
static func _apron_noise(noise_seed: int, frequency: float, fractal: int, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH if fractal == FastNoiseLite.FRACTAL_FBM else FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = fractal
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	return noise

## 1 where the mountain's base is a wall with a ledge, 0 where it is one steep slope, per row of
## the map + hub (the same for raise_foot and apron_maps).
static func _ledge_share(master_seed: int, row: int, side: int = 0) -> float:
	if _section_noise == null or _section_seed != master_seed:
		_section_noise = _apron_noise(master_seed ^ 0x53454354, FOOT_SECTION_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 2) # 'SECT'
		_section_seed = master_seed
	return smoothstep(-0.12, 0.12, _section_noise.get_noise_1d(float(row + side * 4096)))

## The foot line on one side: for every row of the generated map, how far inside that side's edge the mountain
## begins (m = heightmap pixels), FOOT_MIN..FOOT_MAX, pulled back where a cliff, knot or outcrop
## footprint (`obstacle_mask`) is nearer the edge than that. Raises `heights` in place past the
## line: a wall with a ledge or one steep slope, alternating along the line (FOOT_WALL_*,
## FOOT_SECTION_FREQUENCY ...), then the ground's grade grows by FOOT_EXTRA_GRADE, eased in over
## FOOT_EASE m. Returns the line.
##
## `side` 2 is the map's north (low-Z) end, where the mountain closes the valley: the line then
## has one entry per COLUMN and lies NORTH_FOOT_MIN..NORTH_FOOT_MAX m inside the north edge. Call
## the sides in order (0, 1, 2): where two sides' mountains overlap, in the corners, the ground
## gets the higher of their rises, not the sum.
static func raise_foot(heights: PackedFloat32Array, width: int, length: int, obstacle_mask: PackedByteArray, master_seed: int, side: int = 0) -> PackedFloat32Array:
	var t0 := Time.get_ticks_msec()
	var side_seed := master_seed + side * 7919
	var lobes := _apron_noise(side_seed ^ 0x464F4F54, FOOT_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 4) # 'FOOT'
	var wall_noise := _apron_noise(side_seed ^ 0x57414C32, FOOT_WALL_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 2) # 'WAL2'
	# The same two fields for every side (the run's seed, not the side's), so the corners agree.
	var relief_noise := _apron_noise(master_seed ^ 0x46524C46, FOOT_RELIEF_FREQUENCY, FastNoiseLite.FRACTAL_RIDGED, 4) # 'FRLF'
	var rough_noise := _apron_noise(master_seed ^ 0x46524F55, FOOT_ROUGHNESS_FREQUENCY, FastNoiseLite.FRACTAL_FBM, 3) # 'FROU'
	var count := width if side == 2 else length # entries along the line
	var depth := length if side == 2 else width # pixels there are going in from the edge
	var foot_min := NORTH_FOOT_MIN if side == 2 else FOOT_MIN
	var foot_max := NORTH_FOOT_MAX if side == 2 else FOOT_MAX
	if side == 0 or _foot_rise.size() != width * length:
		_foot_rise = PackedFloat32Array()
		_foot_rise.resize(width * length)
	var foot := PackedFloat32Array()
	foot.resize(count)
	var reach := mini(int(foot_max + TerrainHeightmap.VALLEY_MEANDER_IN + FOOT_OBSTACLE_GAP) + 1, depth)
	# The long sides' guards (see FOOT_MAX): each side's share of the floor, the south end, the castle.
	var floor_edge := (0.5 - TerrainConfig.VALLEY_FLOOR_WIDTH_FRACTION * 0.5) * float(width - 1)
	var open_cap := floor_edge + maxf(float(width - 1) - 2.0 * floor_edge - FOOT_MIN_OPEN, 0.0) * 0.5
	var castle_cap := TerrainCastle.SITE_PX.x - TerrainCastle.PLACEHOLDER_SIZE.x * 0.5 - FOOT_CASTLE_GAP
	var castle_half := TerrainCastle.PLACEHOLDER_SIZE.z * 0.5 + FOOT_CASTLE_GAP
	var clipped := 0
	for row in count:
		# Stretched so the line spends time at both ends of its range, like a shore with headlands.
		var wanted := lerpf(foot_min, foot_max, smoothstep(-0.45, 0.45, lobes.get_noise_1d(float(row))))
		if side < 2:
			# The valley's own bend at this row: the rock stays at the top of the forested slope.
			wanted = maxf(wanted + TerrainHeightmap.floor_shift(side, float(row)), FOOT_MIN)
			wanted = minf(wanted, open_cap)
			wanted = minf(wanted, FOOT_END_MAX + maxf(float(count - 1 - row) - FOOT_END_TAPER_START, 0.0))
			if side == 0:
				wanted = minf(wanted, castle_cap + maxf(absf(float(row) - TerrainCastle.SITE_PX.y) - castle_half, 0.0))
				# Beside the village's shoulder the map's edge is always the mountain's rock.
				if TerrainCastle.shoulder_keepout(0.0, float(row)):
					wanted = maxf(wanted, TerrainCastle.MASSIF_MAP_FOOT)
		for px in reach:
			if float(px) - FOOT_OBSTACLE_GAP >= wanted:
				break
			if obstacle_mask[_foot_index(side, row, px, width)] != 0:
				wanted = maxf(float(px) - FOOT_OBSTACLE_GAP, 0.0)
				clipped += 1
				break
		foot[row] = wanted
	# No sharper turn than FOOT_LINE_SLOPE: every entry at most that much further in than its
	# neighbours (lowering only, so the line still clears every obstacle and guard).
	for row in range(1, count):
		foot[row] = minf(foot[row], foot[row - 1] + FOOT_LINE_SLOPE)
	for row in range(count - 2, -1, -1):
		foot[row] = minf(foot[row], foot[row + 1] + FOOT_LINE_SLOPE)
	foot = _row_average(foot, 2)
	foot_lines[side] = foot
	var raised := 0
	var highest := 0.0
	for row in count:
		var line := foot[row]
		var wall := lerpf(FOOT_WALL_MIN, FOOT_WALL_MAX, 0.5 + 0.5 * wall_noise.get_noise_1d(float(row)))
		var ledge := _ledge_share(master_seed, row, side)
		var steep_height := wall * FOOT_STEEP_HEIGHT
		var steep_run := steep_height * 1.5 / FOOT_STEEP_GRADE
		for px in int(ceil(line)):
			var into := line - float(px)
			# Wall, ledge, then the extra grade behind them ...
			var behind := maxf(into - FOOT_WALL_RUN - FOOT_LEDGE_WIDTH, 0.0)
			var with_ledge := wall * smoothstep(0.0, FOOT_WALL_RUN, into) - FOOT_LEDGE_FLATTEN * clampf(into - FOOT_WALL_RUN, 0.0, FOOT_LEDGE_WIDTH) \
				+ _foot_back_rise(behind)
			# ... or one taller steep slope (a smoothstep's steepest grade is 1.5 x its mean), then the extra grade.
			behind = maxf(into - steep_run, 0.0)
			var steep := steep_height * smoothstep(0.0, steep_run, into) + _foot_back_rise(behind)
			var rise := lerpf(steep, with_ledge, ledge)
			var i := _foot_index(side, row, px, width)
			# Relief on the rock (FOOT_RELIEF): ribs and gullies running down the slope, and a
			# finer roughness. Sampled at the pixel's place on the map, squeezed along the fall line.
			var map_x := float(i % width)
			var map_z := float(i / width)
			var along_fall := FOOT_RELIEF_STRETCH
			var ribs := relief_noise.get_noise_2d(map_x, map_z * along_fall) if side == 2 else relief_noise.get_noise_2d(map_x * along_fall, map_z)
			rise += smoothstep(FOOT_RELIEF_START, FOOT_RELIEF_FULL, into) * FOOT_RELIEF * (0.5 + 0.5 * ribs)
			rise = maxf(rise + smoothstep(1.0, 8.0, into) * FOOT_ROUGHNESS * rough_noise.get_noise_2d(map_x, map_z), 0.0)
			if rise > _foot_rise[i]: # only what an earlier side has not already raised
				heights[i] += rise - _foot_rise[i]
				_foot_rise[i] = rise
				raised += 1
			highest = maxf(highest, rise)
	var sorted := Array(foot)
	sorted.sort()
	print("TERRAIN_GEN: mountain foot line (%s) -- %.0f..%.0f m inside the edge (median %.0f, upper quarter from %.0f), held back by an obstacle on %d of %d entries, %d px raised by up to %.1f m (%d ms)" % [["low-X side", "high-X side", "north end"][side], sorted[0], sorted[-1], sorted[sorted.size() / 2], sorted[sorted.size() * 3 / 4], clipped, count, raised, highest, Time.get_ticks_msec() - t0])
	return foot

## The rise the ground gains `behind` m past the foot's wall or steep slope: the extra grade,
## eased in over FOOT_EASE m, easing off to FOOT_DEEP_GRADE from FOOT_DEEP_RUN m.
static func _foot_back_rise(behind: float) -> float:
	if behind < FOOT_EASE:
		return FOOT_EXTRA_GRADE * behind * behind / (2.0 * FOOT_EASE)
	if behind < FOOT_DEEP_RUN:
		return FOOT_EXTRA_GRADE * (behind - FOOT_EASE * 0.5)
	return FOOT_EXTRA_GRADE * (FOOT_DEEP_RUN - FOOT_EASE * 0.5) + FOOT_DEEP_GRADE * (behind - FOOT_DEEP_RUN)

## Lowers `field` (a distance field in m, one entry per heightmap pixel, capped at `cap`) to each
## pixel's distance from the mountain's rock: 0 past a foot line, and the distance to the line,
## measured straight in from that side's edge, in front of it. For GrassScatter.bake (no grass
## on the rock) and TerrainGroundPaint.paint (rock ground, as at a cliff's foot).
static func stamp_rock_distance(field: PackedFloat32Array, width: int, length: int, cap: float) -> void:
	for side in 3:
		var foot := foot_lines[side]
		var depth := length if side == 2 else width
		for along in mini(foot.size(), width if side == 2 else length):
			var line := foot[along]
			if line <= 0.0: # a cliff or knot stands at the edge there: no mountain foot
				continue
			for inside in clampi(int(line + cap) + 2, 0, depth):
				var i := _foot_index(side, along, inside, width)
				var d := maxf(float(inside) - line, 0.0)
				if d < field[i]:
					field[i] = d

## Heightmap index of the pixel `inside` px in from side `side`'s edge, at entry `along` of that
## side's foot line (a row for the long sides, a column for the north end).
static func _foot_index(side: int, along: int, inside: int, width: int) -> int:
	if side == 2:
		return inside * width + along
	return along * width + (inside if side == 0 else width - 1 - inside)

## How far past the nearest foot line heightmap pixel (px, pz) lies, m: above 0 on the mountain's
## rock, below 0 in the valley (the distance to the line); -INF when there is no foot line.
## Read-only: safe from worker threads.
static func mountain_depth(px: float, pz: float) -> float:
	var deepest := -INF
	for side in 3:
		var foot := foot_lines[side]
		if foot.is_empty():
			continue
		var along := pz if side < 2 else px
		var inside := px if side == 0 else (float(TerrainConfig.AREA_WIDTH - 1) - px if side == 1 else pz)
		var line := foot[clampi(int(along), 0, foot.size() - 1)]
		if line > 0.0: # 0 = a cliff or knot stands at the edge there: no mountain foot
			deepest = maxf(deepest, line - inside)
	return deepest

## Boulders (with collision) and scree stones along the foot line, on the generated map: what
## has come down the face lies where the slope eases, thick at the line and thinning into the
## valley. After RockScatter's own passes and before the trees (the boulders join
## RockScatter.rock_keep_circles, which trees, grass and the rest keep clear of).
static func scatter_foot_debris(parent_node: Node, terrain: Terrain3D, maps: Dictionary, heightmap_corner: Vector3, rng: RandomNumberGenerator) -> void:
	var t0 := Time.get_ticks_msec()
	var feet: Array[PackedFloat32Array] = [maps.get("mountain_foot", PackedFloat32Array()), maps.get("mountain_foot_right", PackedFloat32Array()), maps.get("mountain_foot_north", PackedFloat32Array())]
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	if (feet[0].is_empty() and feet[1].is_empty() and feet[2].is_empty()) or instancer == null:
		return
	var heights: PackedFloat32Array = maps.heights
	var road_weight: PackedFloat32Array = maps.road_weight
	var width := TerrainConfig.AREA_WIDTH
	var length := TerrainConfig.AREA_LENGTH
	var old := parent_node.get_node_or_null("MountainFootRocks")
	if old:
		old.name = "MountainFootRocks_old"
		old.queue_free()
	var colliders := Node3D.new()
	colliders.name = "MountainFootRocks"
	var transforms: Dictionary = {} # mesh id -> Array[Transform3D]
	var boulders := 0
	var stones := 0
	var shapes: Dictionary = {}
	for mesh_id in RockScatter.ROCK_MESH_IDS:
		var glb_path: String = RockScatter.ROCK_SCENE_PATHS[mesh_id]
		shapes[mesh_id] = TerrainUtil.cached_shape(glb_path, "rock", RockScatter.ROCK_HULL_BAKE_VERSION, RockScatter._bake_rock_hull.bind(glb_path))
	# Counts are for the two sides and the north end together. [count, mesh ids, reach back, reach out, scale min, scale max, steepest normal.y, is boulder]
	var line_length := 2.0 * float(length) + float(width)
	for pass_def: Array in [
			[int(line_length / FOOT_BOULDER_SPACING), RockScatter.ROCK_MESH_IDS, 0.0, FOOT_BOULDER_REACH, FOOT_BOULDER_SCALE_MIN, FOOT_BOULDER_SCALE_MAX, FOOT_BOULDER_MIN_NORMAL_Y, true],
			[int(line_length * FOOT_SCREE_PER_METRE), RockScatter.SCREE_MESH_IDS, FOOT_SCREE_BACK, FOOT_SCREE_REACH, FOOT_SCREE_SCALE_MIN, FOOT_SCREE_SCALE_MAX, FOOT_SCREE_MIN_NORMAL_Y, false]]:
		var ids: Array[int] = pass_def[1]
		var is_boulder: bool = pass_def[7]
		for i in int(pass_def[0]):
			# A place on the three lines laid end to end: low-X side, high-X side, north end.
			var at := rng.randf() * line_length
			var side := mini(int(at / float(length)), 2)
			var along := clampf(at - float(side * length), 2.0, float(width if side == 2 else length) - 3.0)
			# Mostly near the line: the square of a random number. `inside` = m from that side's edge.
			var inside := -1.0
			if not feet[side].is_empty():
				inside = feet[side][int(along)] - float(pass_def[2]) + pow(rng.randf(), 2.0) * (float(pass_def[2]) + float(pass_def[3]))
			var px := inside if side == 0 else (float(width - 1) - inside if side == 1 else along)
			var pz := along if side < 2 else inside
			# Not on another side's rock (the corners), nor where the castle stands.
			if inside >= 0.0 and (mountain_depth(px, pz) > float(pass_def[2]) + 0.5 or TerrainCastle.covers(px, pz, 2.0)):
				continue
			var scale := lerpf(float(pass_def[4]), float(pass_def[5]), pow(rng.randf(), 1.6))
			var mesh_id: int = ids[rng.randi() % ids.size()]
			var spin := rng.randf_range(0.0, TAU)
			if px < 1.0 or px > float(width) - 2.0 or pz < 1.0 or pz > float(length) - 2.0 or road_weight[int(pz) * width + int(px)] > 0.0:
				continue
			var normal := TerrainUtil.sample_normal(heights, width, length, px, pz)
			var steepest_ny := normal.y
			var probe := FOOT_SLOPE_PROBE * scale
			for offset: Vector2 in [Vector2(probe, 0.0), Vector2(-probe, 0.0), Vector2(0.0, probe), Vector2(0.0, -probe)]:
				steepest_ny = minf(steepest_ny, TerrainUtil.sample_normal(heights, width, length, clampf(px + offset.x, 1.0, float(width) - 2.0), clampf(pz + offset.y, 1.0, float(length) - 2.0)).y)
			if steepest_ny < float(pass_def[6]):
				continue
			if is_boulder:
				scale *= float(RockScatter.ROCK_BASE_SCALE[mesh_id])
			var height := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
			var basis := Basis(Quaternion(normal, spin) * Quaternion(Vector3.UP, normal)).scaled(Vector3.ONE * scale)
			# Boulders are sunk by a quarter of their size, so their downhill side does not float.
			var xform := Transform3D(basis, Vector3(heightmap_corner.x + px, height - (0.25 * scale if is_boulder else 0.02), heightmap_corner.z + pz))
			if not transforms.has(mesh_id):
				transforms[mesh_id] = [] as Array[Transform3D]
			transforms[mesh_id].append(xform)
			if is_boulder:
				boulders += 1
				RockScatter.rock_keep_circles.append(Vector3(px, pz, RockScatter.BOULDER_KEEPOUT_RADIUS * scale))
				if shapes.get(mesh_id) != null:
					RockScatter._add_rock_collider(colliders, shapes[mesh_id], xform, boulders)
			else:
				stones += 1
	for mesh_id: int in transforms:
		var colors := PackedColorArray()
		colors.resize((transforms[mesh_id] as Array).size())
		colors.fill(Color.WHITE)
		instancer.add_transforms(mesh_id, transforms[mesh_id], colors, true)
	parent_node.add_child.call_deferred(colliders)
	print("TERRAIN_GEN: mountain foot debris -- %d boulder(s) with collision, %d scree stone(s) along the foot line (%d ms)" % [boulders, stones, Time.get_ticks_msec() - t0])

## True where the generated map's ground at heightmap pixel (px, pz) is the mountain's rock --
## past a foot line -- or within `radius` + FOOT_PLANT_GAP m of it, and where the castle stands
## (TerrainCastle.covers). The scatter stages
## of everything that grows (trees, saplings, understory, flowers, deadfall) place nothing there
## (Kirill, 2026-10-09: no vegetation on the terrain ridge). Read-only: safe from worker threads.
static func on_mountain(px: float, pz: float, radius: float = 0.0) -> bool:
	return mountain_depth(px, pz) > -(radius + FOOT_PLANT_GAP) or TerrainCastle.covers(px, pz, radius)

## One segment's mesh arrays and baked textures: {name, arrays, tris, diff, normal} (the last two
## null for a source without maps); empty when a file is missing.
static func _load_segment(dir: String, segment: String, with_maps: bool) -> Dictionary:
	var scene := load(dir + segment + ".glb") as PackedScene
	if scene == null:
		return {}
	var instance := scene.instantiate()
	var meshes := instance.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty() or (meshes[0] as MeshInstance3D).mesh == null:
		instance.free()
		return {}
	var arrays := (meshes[0] as MeshInstance3D).mesh.surface_get_arrays(0)
	instance.free()
	# A mountain face looks up: its triangles' front sides (clockwise in Godot) must face upward.
	# A mirrored export has them facing down, and the wall is then culled from every side but below.
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var facing_up := 0
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		if (vertices[indices[i + 2]] - a).cross(vertices[indices[i + 1]] - a).y > 0.0:
			facing_up += 1
	if facing_up * 2 < indices.size() / 3:
		push_warning("TERRAIN_GEN: mountain wall segment %s has only %d of %d triangles facing up -- exported mirrored?" % [segment, facing_up, indices.size() / 3])
	return {
		"name": segment, "arrays": arrays, "tris": indices.size() / 3,
		"diff": load(dir + "textures/" + segment + "_diff.png") if with_maps else null,
		"normal": load(dir + "textures/" + segment + "_nor_gl.png") if with_maps else null,
	}

## The mountains' rock with nothing else on it -- no baked maps, haze, mist, clouds or snow --
## for other rock that should match them (TerrainCastle's village base). The mesh needs tangents.
## `tile_near` / `tile_far` = size of one rock-texture tile near / far from the camera, m.
static func plain_rock_material(tile_near: float = 30.0, tile_far: float = 120.0) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	material.set_shader_parameter("macro_shade", 0.0)
	material.set_shader_parameter("macro_normal_strength", 0.0)
	material.set_shader_parameter("detail_albedo", load(DETAIL_ALBEDO))
	material.set_shader_parameter("detail_normal", load(DETAIL_NORMAL))
	material.set_shader_parameter("detail_size_near", tile_near)
	material.set_shader_parameter("detail_size_far", tile_far)
	material.set_shader_parameter("tint", TINT)
	return material

## The material of segment `source` in `row`.
static func _row_material(shader: Shader, source: Dictionary, row: Dictionary, floor_y: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	if source.diff != null:
		material.set_shader_parameter("macro_albedo", source.diff)
		material.set_shader_parameter("macro_normal", source.normal)
	else: # shape only: the baked maps' share of the look is switched off
		material.set_shader_parameter("macro_shade", 0.0)
		material.set_shader_parameter("macro_normal_strength", 0.0)
	material.set_shader_parameter("detail_albedo", load(DETAIL_ALBEDO))
	material.set_shader_parameter("detail_normal", load(DETAIL_NORMAL))
	material.set_shader_parameter("detail_size_near", float(row.detail_near))
	material.set_shader_parameter("detail_size_far", float(row.detail_far))
	material.set_shader_parameter("tint", TINT)
	material.set_shader_parameter("haze_color", HAZE_COLOR)
	material.set_shader_parameter("mist_color", MIST_COLOR)
	material.set_shader_parameter("haze_amount", float(row.haze))
	material.set_shader_parameter("mist_amount", float(row.mist))
	material.set_shader_parameter("mist_full_y", floor_y + float(row.mist_full))
	material.set_shader_parameter("mist_clear_y", floor_y + float(row.mist_clear))
	material.set_shader_parameter("cloud_noise", _cloud_noise_texture())
	material.set_shader_parameter("cloud_amount", CLOUD_AMOUNT if CLOUDS_ON_ROWS else 0.0)
	material.set_shader_parameter("cloud_color", CLOUD_COLOR)
	material.set_shader_parameter("cloud_scale", CLOUD_TILE * float(row.size))
	material.set_shader_parameter("cloud_drift", CLOUD_DRIFT)
	material.set_shader_parameter("cloud_coverage", CLOUD_COVERAGE)
	material.set_shader_parameter("cloud_softness", CLOUD_SOFTNESS)
	material.set_shader_parameter("cloud_bottom_y", floor_y + float(row.mist_full))
	material.set_shader_parameter("cloud_top_y", floor_y + float(row.mist_clear) + CLOUD_ABOVE_MIST * (float(row.mist_clear) - float(row.mist_full)))
	material.set_shader_parameter("veil_near", VEIL_NEAR)
	material.set_shader_parameter("veil_far", VEIL_FAR)
	material.set_shader_parameter("snow_color", SNOW_COLOR)
	material.set_shader_parameter("snow_line_y", floor_y + SNOW_LINE)
	material.set_shader_parameter("snow_fade", SNOW_FADE)
	_fog_materials.append([material, float(row.haze), float(row.mist)])
	return material

## The terrain along edge column `px`, per row (the generated map's rows, then the hub's):
##   "height"         its height there
##   "smooth_height"  that, averaged over APRON_BASE_SMOOTH_RADIUS rows each way
##   "grade"          its rise per metre toward the edge, measured over RAMP_GRADE_PROBE m,
##                    averaged over RAMP_GRADE_SMOOTH_RADIUS rows each way, within RAMP_GRADE_MIN..MAX
##   "local_grade"    the same over APRON_EDGE_GRADE_PROBE m and 2 rows each way, up or down,
##                    within +-APRON_EDGE_GRADE_LIMIT
static func _rim_profile(maps: Dictionary, px: int) -> Dictionary:
	var rows := TerrainConfig.AREA_LENGTH + TerrainHub.STRIP_LENGTH
	var inward := 1 if px == 0 else -1
	var height := PackedFloat32Array()
	var raw_grade := PackedFloat32Array()
	var raw_local := PackedFloat32Array()
	for row in rows:
		var h := _terrain_height(maps, float(px), float(row))
		height.append(h)
		raw_grade.append((h - _terrain_height(maps, float(px + inward * RAMP_GRADE_PROBE), float(row))) / float(RAMP_GRADE_PROBE))
		raw_local.append((h - _terrain_height(maps, float(px + inward * APRON_EDGE_GRADE_PROBE), float(row))) / float(APRON_EDGE_GRADE_PROBE))
	var grade := _row_average(raw_grade, RAMP_GRADE_SMOOTH_RADIUS)
	var local_grade := _row_average(raw_local, 2)
	for row in rows:
		grade[row] = clampf(grade[row], RAMP_GRADE_MIN, RAMP_GRADE_MAX)
		local_grade[row] = clampf(local_grade[row], -APRON_EDGE_GRADE_LIMIT, APRON_EDGE_GRADE_LIMIT)
	return {"height": height, "smooth_height": _row_average(height, APRON_BASE_SMOOTH_RADIUS), "grade": grade, "local_grade": local_grade}

## `values` with every entry replaced by the mean of its neighbours up to `radius` away.
static func _row_average(values: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())
	for i in values.size():
		var sum := 0.0
		var lo := maxi(i - radius, 0)
		var hi := mini(i + radius, values.size() - 1)
		for j in range(lo, hi + 1):
			sum += values[j]
		out[i] = sum / float(hi - lo + 1)
	return out

## The terrain's height at heightmap pixel (px, row), bilinear; rows past the generated map are
## the hub's. Clamped to the map + hub.
static func _terrain_height(maps: Dictionary, px: float, row: float) -> float:
	var width := TerrainConfig.AREA_WIDTH
	var rows := TerrainConfig.AREA_LENGTH + TerrainHub.STRIP_LENGTH
	var heights: PackedFloat32Array = maps.heights
	var hub_heights: PackedFloat32Array = maps.hub_heights
	var fx := clampf(px, 0.0, float(width - 1))
	var fz := clampf(row, 0.0, float(rows - 1))
	var x0 := mini(int(fx), width - 2)
	var z0 := mini(int(fz), rows - 2)
	var corner := PackedFloat32Array()
	for dz in 2:
		for dx in 2:
			var r := z0 + dz
			corner.append(heights[r * width + x0 + dx] if r < TerrainConfig.AREA_LENGTH else hub_heights[(r - TerrainConfig.AREA_LENGTH) * width + x0 + dx])
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	return lerpf(lerpf(corner[0], corner[1], tx), lerpf(corner[2], corner[3], tx), tz)

## Height of the apron's ramp `d` m out from the map's edge, above the edge, when it leaves
## the edge at `edge_grade`: the area under RAMP_GRADES (straight lines between its entries).
static func _ramp_height(d: float, edge_grade: float) -> float:
	var height := 0.0
	for i in RAMP_GRADES.size():
		var d0: float = RAMP_GRADES[i][0]
		if d <= d0:
			break
		var g0: float = edge_grade if i < RAMP_EDGE_ENTRIES else float(RAMP_GRADES[i][1])
		if i == RAMP_GRADES.size() - 1:
			height += (d - d0) * g0
			break
		var d1: float = RAMP_GRADES[i + 1][0]
		var g1: float = edge_grade if i + 1 < RAMP_EDGE_ENTRIES else float(RAMP_GRADES[i + 1][1])
		var reach := minf(d, d1)
		var g_reach := lerpf(g0, g1, (reach - d0) / (d1 - d0))
		height += (reach - d0) * (g0 + g_reach) * 0.5
	return height

static func _level_lift(_v: Vector3, base: float) -> float:
	return base

## How much of its height a segment keeps at world position `v`: all of it ...
static func _full_tall(_v: Vector3) -> float:
	return 1.0

## ... or, for the row seated on the apron, less where the apron is low (SEAT_SADDLE_HEIGHT).
static func _seat_tall(v: Vector3, z_origin: float, side: int) -> float:
	var envelope := apron_envelope[side]
	var last := envelope.size() - 1
	var row := clampf(v.z - z_origin, 0.0, float(last))
	var r0 := int(row)
	return lerpf(SEAT_SADDLE_HEIGHT, 1.0, lerpf(envelope[r0], envelope[mini(r0 + 1, last)], row - float(r0)))

## Lift of a vertex (world position `v`) of the row seated on the apron: the apron's back-edge
## height at its place along the wall, SEAT_SINK lower, plus a rise that starts at SEAT_GRADE and
## levels off (SEAT_GRADE x SEAT_RUN m in all) -- the apron's slope carried on under the row.
## `foot_x` = world x of the row's foot.
static func _seat_lift(v: Vector3, z_origin: float, foot_x: float, side: int) -> float:
	var back_heights := apron_back_heights[side]
	var last := back_heights.size() - 1
	var row := clampf(v.z - z_origin, 0.0, float(last))
	var r0 := int(row)
	var back := lerpf(back_heights[r0], back_heights[mini(r0 + 1, last)], row - float(r0))
	# North of the map the row stands on the castle block's side edge, not on the apron.
	var north := z_origin - v.z
	if north > 0.0:
		back = lerpf(back, _edge_height(TerrainCastle.side_edge_heights[side], float(TerrainCastle.LENGTH) - north, back), smoothstep(0.0, TerrainCastle.EDGE_BLEND, north))
	var beyond := maxf(foot_x - v.x if side == 0 else v.x - foot_x, 0.0)
	var lift := back - SEAT_SINK + SEAT_GRADE * SEAT_RUN * (1.0 - exp(-beyond / SEAT_RUN))
	if side == 0:
		# The village's shoulder (TerrainCastle) reaches out under this row: where it is ground
		# -- on the import's west strip, or anywhere on its level top -- the mesh stays under it
		# (`v.y` is the vertex's own height before the lift). Beyond it the row rises behind
		# the village as everywhere else.
		var map_x := v.x - (foot_x + float(APRON_WIDTH) - SEAT_OVERLAP) # in the generated map's pixels
		var shoulder := TerrainCastle.massif_height(map_x, v.z - z_origin)
		var natural := TerrainCastle.natural_back_heights
		var natural_back := natural[clampi(int(v.z - z_origin), 0, natural.size() - 1)] if not natural.is_empty() else back
		if shoulder > -INF and (shoulder >= TerrainCastle.massif_top_y - 0.01 or (map_x >= -float(MAP_OFFSET_X) and shoulder > natural_back + 0.5)):
			lift = minf(lift, shoulder - TerrainCastle.MASSIF_MESH_UNDER - v.y)
	return lift

## The same for the row seated on the castle block's north edge (END_ROWS, "seat"): that edge's
## height at the vertex's place along it. `x_origin` = world x of the block's column 0, `foot_z` =
## world z of the row's foot; the row's ground rises going north (-Z).
## `map_z` = world z of the map's north edge; `foot_heights` = the apron's (smoothed) heights
## along the row's foot, per import column. Where the vertex lies over the apron it is also kept
## above the apron's ground (NORTH_DRAPE_*): `v.y` is its own height before the lift.
static func _north_seat_lift(v: Vector3, x_origin: float, foot_z: float, map_z: float, foot_heights: PackedFloat32Array) -> float:
	var back := _edge_height(foot_heights, v.x - x_origin, TerrainHeightmap.BASE_LEVEL)
	var beyond := maxf(foot_z - v.z, 0.0)
	var lift := back - SEAT_SINK + SEAT_GRADE * SEAT_RUN * (1.0 - exp(-beyond / SEAT_RUN))
	var ground := TerrainCastle.north_apron_height(v.x - x_origin, map_z - v.z)
	if not is_nan(ground):
		lift = maxf(lift, ground + lerpf(-SEAT_SINK, NORTH_DRAPE_CLEAR, smoothstep(0.0, NORTH_DRAPE_RUN, beyond)) - v.y)
	return lift

## `heights` at position `at` (in entries, between two of them; held at both ends); `fallback`
## when there are none.
static func _edge_height(heights: PackedFloat32Array, at: float, fallback: float) -> float:
	if heights.is_empty():
		return fallback
	var last := heights.size() - 1
	var p := clampf(at, 0.0, float(last))
	var p0 := int(p)
	return lerpf(heights[p0], heights[mini(p0 + 1, last)], p - float(p0))

## A MeshInstance3D holding `source` in world space: scaled by `scale` (x = depth, y = height --
## fading to x's value at both ends, z = along the wall), turned and moved by `xform`, and every
## vertex's height multiplied by `tall` and raised by `lift` (both called with the vertex's world
## position). Normals are rebuilt from the finished surface.
static func _place(source: Dictionary, xform: Transform3D, scale: Vector3, lift: Callable, tall: Callable) -> MeshInstance3D:
	var arrays: Array = (source.arrays as Array).duplicate()
	var vertices: PackedVector3Array = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var half := SEGMENT_LENGTH * 0.5
	for i in vertices.size():
		var local := vertices[i]
		var y_scale := lerpf(scale.y, scale.x, smoothstep(half - END_BLEND, half - END_OVERLAP, absf(local.z)))
		var v := xform * Vector3(local.x * scale.x, local.y * y_scale, local.z * scale.z)
		v.y = v.y * float(tall.call(v)) + float(lift.call(v))
		vertices[i] = v
	# Smooth normals: every triangle's (area-weighted) normal added to its three corners. Godot's
	# front side is clockwise.
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var face := (vertices[indices[i + 2]] - a).cross(vertices[indices[i + 1]] - a)
		normals[indices[i]] += face
		normals[indices[i + 1]] += face
		normals[indices[i + 2]] += face
	for i in normals.size():
		normals[i] = normals[i].normalized() if normals[i].length_squared() > 0.0 else Vector3.UP
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	# Tangents: stretched and turned like the surface, then squared up against the new normal. A
	# segment exported without any (no UVs) gets plain ones along the wall -- the shader reads
	# them, and a missing tangent turns its normal into NaN (a black mountain).
	var tangents := PackedFloat32Array()
	tangents.resize(vertices.size() * 4)
	var source_tangents := PackedFloat32Array()
	if arrays[Mesh.ARRAY_TANGENT] != null:
		source_tangents = arrays[Mesh.ARRAY_TANGENT]
	for i in vertices.size():
		var t := Vector3.BACK
		if not source_tangents.is_empty():
			t = xform.basis * Vector3(source_tangents[i * 4] * scale.x, source_tangents[i * 4 + 1] * scale.y, source_tangents[i * 4 + 2] * scale.z)
		t -= normals[i] * t.dot(normals[i])
		t = t.normalized() if t.length_squared() > 1e-8 else normals[i].cross(Vector3.RIGHT).normalized()
		tangents[i * 4] = t.x
		tangents[i * 4 + 1] = t.y
		tangents[i * 4 + 2] = t.z
		tangents[i * 4 + 3] = source_tangents[i * 4 + 3] if not source_tangents.is_empty() else 1.0
	arrays[Mesh.ARRAY_TANGENT] = tangents
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance
