## The castle (2026-10-09): a fixed landmark at the north end of the generated map, and the strip
## of mountain terrain beyond that end.
##
## The valley's north end is part of the generated map since the same day (its first version was
## a separate fixed block of terrain with a bay and a crag; Kirill: "I don't think we need an
## actual separate chunk ... extend the rng terrain to cover that area as well and use the castle
## as a landmark that just always stays at the same place"). What is fixed is only WHERE the
## castle stands, in heightmap pixels (SITE_PX): the middle of the valley's width at its north
## end, straight ahead of the walk up the valley, in front of the mountain that closes it. Its
## ground is whatever this run generated; the shaping stages keep clear of it (filter_plan,
## SITE_KEEP_RADIUS), nothing grows in it (covers, through MountainWalls.on_mountain) and the
## valley's road ends in front of it (road_end).
##
## 2026-10-12: until then it stood in the low-X corner of the valley's end, and a bridge 240 m up
## joined it to a village of boxes on a terrain "shoulder" raised on the western ridge. All three
## went with the zone plan they belonged to (the castle entered from the top, through the
## mountains; Kirill: "we don't need the bridge, the village, and the mountain pillar now, also
## move the castle to be in the center of the valley"). They are in git up to `4d30d31`.
##
## The mountain closes the valley inside the map (MountainWalls.raise_foot, side 2). Beyond the
## map's north edge its ground carries on as LENGTH m of terrain, the "north apron" (build_maps):
## as wide as the whole Terrain3D import (both side aprons + the map), rising from the edge by the
## same ramp as the side aprons and painted the same bare rock. The mountain rows of MountainWalls
## stand on its far edge. Its rows come first in the import, so the generated map's pixel (0, 0)
## is LENGTH m in +Z from the corner Terrain3D reports.
##
## The castle itself is a blockout: a plain block with lit windows.
##
## Static-only: never instantiated; call as TerrainCastle.some_func(...).
class_name TerrainCastle
extends RefCounted

## -- The castle's site --
## Its centre, in heightmap pixels of the generated map (x from the low-X edge, y = pz from the
## north edge): the middle of the map's width (the floor's edges are held straight beside it,
## TerrainHeightmap.build_valley_shape, so that is the middle of the floor too). The mountain's
## foot lies up to MountainWalls.NORTH_FOOT_MAX m inside the north edge, behind it. TUNING.
const SITE_PX := Vector2(192.0, 78.0)
## Knots, cliff meshes and outcrops keep this far from the centre, m.
const SITE_KEEP_RADIUS := 40.0
## The valley's road ends this far in front of the middle of the castle's south face, m.
const ROAD_END_GAP := 8.0
## The stand-in for the castle, m (x, height, z). The height is fixed (Kirill, 2026-10-09:
## "hardcode tower standin height at 150m", then "let's make tower 200m"; before, its top followed
## the crest of the ridge west of it and came out 107..233 m depending on the seed; 250 since
## Kirill set it himself). Its base is PLACEHOLDER_SINK m below the lowest ground under it
## (sampled every SITE_GROUND_STEP m).
const PLACEHOLDER_SIZE := Vector3(30.0, 250.0, 24.0)
const PLACEHOLDER_SINK := 1.0
const SITE_GROUND_STEP := 3
const PLACEHOLDER_NAME := "CastlePlaceholder"
## Its lit windows (Kirill, 2026-10-09), all in m and all TUNING: this many glowing panes on its
## four faces from CASTLE_LIGHT_FROM m above its base, more of them toward the top. They always
## face the camera: from far away a window is a point of light.
const CASTLE_LIGHTS := 110
const CASTLE_LIGHT_FROM := 20.0
const CASTLE_LIGHT_SIZE := Vector2(1.6, 2.4)
const LIGHT_COLOR := Color(1.0, 0.62, 0.26)
const LIGHT_ENERGY := 6.0
const LIGHT_STAND_OFF := 0.6 ## m a light stands off the surface it is on

## -- The north apron --
## Its length (Z), m. Terrain3D takes whole regions: with AREA_LENGTH and the hub's length it
## should come to a multiple of the region size (256 + 1024 + 512 = 1792), or the rest is padded
## with holes on the +Z end.
const LENGTH := 256
## Its ground leaves the map's edge at WALL_EDGE_GRADE (the grade the map's own ground has past
## the foot line, MountainWalls.FOOT_EXTRA_GRADE) and takes the ramp's shape over EDGE_BLEND m.
const WALL_EDGE_GRADE := 0.75
const EDGE_BLEND := 20.0
const EDGE_SMOOTH_RADIUS := 6 ## columns each way averaged into the height the ramp stands on
## Behind its crest the ramp falls away, but not below this many m above its start.
const WALL_BACK_MIN := 25.0
const WALL_RELIEF := 40.0 ## ridges and gullies on the ramp, m
const WALL_RELIEF_FREQUENCY := 1.0 / 100.0
const COLOR_BLEND := 20.0 ## m from the map's edge over which its own shading replaces the edge's colour

## The apron's heights along its two side edges, smoothed: what MountainWalls' seated side rows
## stand on there. Set by build_maps. One per apron row (row 0 = the northmost), [low X, high X].
static var side_edge_heights: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
## The whole north apron's heights as built (row-major, `north_apron_width` columns, row 0 = the
## northmost), for the mountain rows that stand on it: north_row_heights, north_apron_height.
static var north_apron_heights := PackedFloat32Array()
static var north_apron_width := 0

## The north apron's heights along the line `d` m north of the map's edge, one per import column,
## smoothed like the edges above; empty before build_maps.
static func north_row_heights(d: float) -> PackedFloat32Array:
	if north_apron_width <= 0:
		return PackedFloat32Array()
	var j := clampi(LENGTH - int(round(d)), 0, LENGTH - 1)
	return MountainWalls._row_average(north_apron_heights.slice(j * north_apron_width, (j + 1) * north_apron_width), MountainWalls.SEAT_SMOOTH_RADIUS)

## The north apron's ground height at import column `c`, `d` m north of the map's edge (between
## its samples); NAN off the apron.
static func north_apron_height(c: float, d: float) -> float:
	var j := float(LENGTH) - d
	if north_apron_width <= 0 or c < 0.0 or c > float(north_apron_width - 1) or j < 0.0 or j > float(LENGTH - 1):
		return NAN
	var c0 := mini(int(c), north_apron_width - 2)
	var j0 := mini(int(j), LENGTH - 2)
	var tc := c - float(c0)
	var tj := j - float(j0)
	var i := j0 * north_apron_width + c0
	return lerpf(lerpf(north_apron_heights[i], north_apron_heights[i + 1], tc), lerpf(north_apron_heights[i + north_apron_width], north_apron_heights[i + north_apron_width + 1], tc), tj)

## True where the castle stands: heightmap pixel (px, pz) within `pad` m of its footprint.
## Read-only: safe from worker threads.
static func covers(px: float, pz: float, pad: float = 0.0) -> bool:
	return absf(px - SITE_PX.x) <= PLACEHOLDER_SIZE.x * 0.5 + pad and absf(pz - SITE_PX.y) <= PLACEHOLDER_SIZE.z * 0.5 + pad

## Where the valley's road ends, in heightmap pixels: in front of the middle of the castle's
## south face.
static func road_end() -> Vector2:
	return SITE_PX + Vector2(0.0, PLACEHOLDER_SIZE.z * 0.5 + ROAD_END_GAP)

## Drops the entries of `plan` (planned cliff meshes or outcrops, each with px / pz) that reach
## into the castle's site; `reach` gives an entry's radius. Returns how many were dropped.
static func filter_plan(plan: Array, reach: Callable) -> int:
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var e: Dictionary = plan[i]
		if Vector2(float(e.px), float(e.pz)).distance_to(SITE_PX) < SITE_KEEP_RADIUS + float(reach.call(e)):
			plan.remove_at(i)
			removed += 1
	return removed

## The north apron's maps for the Terrain3D import, `width` columns x LENGTH rows, row-major,
## row 0 = the northmost: {heights: PackedFloat32Array, control: PackedInt32Array, color:
## PackedByteArray (RGBA8)}. `edge_row` / `edge_color` = the heights and the colour-map pixels
## (RGBA8) of the import's row just south of it: the map's north edge with both side aprons.
## Its ridges and shading come from `master_seed`, like the side aprons' (a constant seed until
## 2026-10-09: it was the one piece of mountain that was the same on every run).
static func build_maps(edge_row: PackedFloat32Array, edge_color: PackedByteArray, width: int, master_seed: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var relief_noise := _noise(master_seed ^ 0x4E52544C, WALL_RELIEF_FREQUENCY, FastNoiseLite.FRACTAL_RIDGED, 4) # 'NRTL'
	var shade_noise := _noise(master_seed ^ 0x4E525348, 1.0 / 60.0, FastNoiseLite.FRACTAL_FBM, 3) # 'NRSH'
	var base := MountainWalls._row_average(edge_row, EDGE_SMOOTH_RADIUS)
	# The ramp only depends on the distance out: one table, 1 m apart.
	var ramp := PackedFloat32Array()
	ramp.resize(LENGTH + 1)
	for d in LENGTH + 1:
		ramp[d] = maxf(MountainWalls._ramp_height(float(d), WALL_EDGE_GRADE), minf(float(d), WALL_BACK_MIN))

	# -- Heights --
	# 2026-10-10: the rows in bands on worker threads (see _north_height_band), as on the sides.
	var heights := PackedFloat32Array()
	var crest := -INF
	var bands := ceili(float(LENGTH) / MountainWalls.APRON_BAND_ROWS)
	var height_out: Array = []
	height_out.resize(bands)
	var height_ctx := {"width": width, "edge_row": edge_row, "base": base, "ramp": ramp, "relief_noise": relief_noise, "out": height_out, "mutex": Mutex.new()}
	# 2026-10-11: both band loops of this function run in the native library when it is there
	# (TerrainUtil.kernels(); north_heights / north_colors in native/src/terrain_kernels.cpp). The
	# band functions are the reference and the fallback: change both together.
	var kernel_consts := MountainWalls.kernel_consts()
	kernel_consts.merge({
		"NORTH_LENGTH": LENGTH, "WALL_RELIEF": WALL_RELIEF, "NORTH_EDGE_BLEND": EDGE_BLEND, "WALL_EDGE_GRADE": WALL_EDGE_GRADE,
		"NORTH_COLOR_BLEND": COLOR_BLEND, "MAP_FROM": MountainWalls.MAP_OFFSET_X, "MAP_TO": MountainWalls.MAP_OFFSET_X + TerrainConfig.AREA_WIDTH,
	})
	var native_heights: Dictionary = {}
	if TerrainUtil.kernel(&"north_heights") != null:
		native_heights = TerrainUtil.kernel(&"north_heights").call("north_heights", height_ctx, kernel_consts)
	if native_heights.has("heights"):
		height_out = [native_heights]
	else:
		WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_north_height_band.bind(height_ctx), bands, TerrainUtil.object_call_threads(), true))
	for b: Dictionary in height_out:
		heights.append_array(b.heights)
		crest = maxf(crest, b.crest)
	# No pixel is forced bare any more (2026-10-12; it was the village's shoulder where that
	# reached north of the map). The colour band and its native copy still take the mask.
	var on_shoulder := PackedByteArray()
	on_shoulder.resize(width * LENGTH)

	# -- The outer edges, for the mountain rows seated on them --
	var low_x_edge := PackedFloat32Array()
	var high_x_edge := PackedFloat32Array()
	for j in LENGTH:
		low_x_edge.append(heights[j * width])
		high_x_edge.append(heights[j * width + width - 1])
	north_apron_heights = heights
	north_apron_width = width
	side_edge_heights[0] = MountainWalls._row_average(low_x_edge, MountainWalls.SEAT_SMOOTH_RADIUS)
	side_edge_heights[1] = MountainWalls._row_average(high_x_edge, MountainWalls.SEAT_SMOOTH_RADIUS)

	# -- Ground and colour, from the finished shape: the mountain's, as on the side aprons --
	# (bare rock, turf on low ledges only, snow high up; creases darker, faint layers by height)
	var control := PackedInt32Array()
	var color := PackedByteArray()
	var color_out: Array = []
	color_out.resize(bands)
	var color_ctx := {
		"width": width, "heights": heights, "base": base, "on_shoulder": on_shoulder, "edge_color": edge_color,
		"shade_noise": shade_noise, "rock_id": MountainWalls.rock_texture_id, "out": color_out, "mutex": Mutex.new(),
	}
	var native_colors: Dictionary = {}
	if TerrainUtil.kernel(&"north_colors") != null:
		native_colors = TerrainUtil.kernel(&"north_colors").call("north_colors", color_ctx, kernel_consts)
	if native_colors.has("control"):
		color_out = [native_colors]
	else:
		WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_north_color_band.bind(color_ctx), bands, TerrainUtil.object_call_threads(), true))
	for b: Dictionary in color_out:
		control.append_array(b.control)
		color.append_array(b.color)
	print("TERRAIN_GEN: north apron -- %dx%d m of terrain north of the map, crest up to %.0f m above the map's edge (%d ms)" % [width, LENGTH, crest, Time.get_ticks_msec() - t0])
	return {"heights": heights, "control": control, "color": color}

## build_maps()'s heights for rows [band * APRON_BAND_ROWS, +APRON_BAND_ROWS). Worker thread: reads
## the shared inputs in ctx, fills band-sized outputs of its own, stores them under ctx.mutex.
static func _north_height_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var edge_row: PackedFloat32Array = ctx.edge_row
	var base: PackedFloat32Array = ctx.base
	var ramp: PackedFloat32Array = ctx.ramp
	var relief_noise: FastNoiseLite = ctx.relief_noise
	var j_from := band * MountainWalls.APRON_BAND_ROWS
	var j_to := mini(j_from + MountainWalls.APRON_BAND_ROWS, LENGTH)
	var heights := PackedFloat32Array()
	heights.resize(width * (j_to - j_from))
	var crest := -INF
	for j in range(j_from, j_to):
		var d := LENGTH - j # m north of the map's edge
		var relief := smoothstep(10.0, 60.0, float(d)) * WALL_RELIEF
		var join := smoothstep(0.0, EDGE_BLEND, float(d))
		for c in width:
			var body := base[c] + ramp[d] + relief * (0.5 + 0.5 * relief_noise.get_noise_2d(c, d))
			var h := lerpf(edge_row[c] + WALL_EDGE_GRADE * float(d), body, join)
			heights[(j - j_from) * width + c] = h
			crest = maxf(crest, h - base[c])
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = {"heights": heights, "crest": crest}
	mutex.unlock()

## build_maps()'s ground and colour for one band of rows, from the finished heights. Worker
## thread, same rules; control pixels packed with TerrainGroundPaint._pack (the same bits as
## TerrainHeightmap.pack_control_blend without its GDExtension calls).
static func _north_color_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var heights: PackedFloat32Array = ctx.heights
	var base: PackedFloat32Array = ctx.base
	var on_shoulder: PackedByteArray = ctx.on_shoulder
	var edge_color: PackedByteArray = ctx.edge_color
	var shade_noise: FastNoiseLite = ctx.shade_noise
	var rock_id: int = ctx.rock_id
	var j_from := band * MountainWalls.APRON_BAND_ROWS
	var j_to := mini(j_from + MountainWalls.APRON_BAND_ROWS, LENGTH)
	var control := PackedInt32Array()
	control.resize(width * (j_to - j_from))
	var color := PackedByteArray()
	color.resize(width * (j_to - j_from) * 4)
	var map_from := MountainWalls.MAP_OFFSET_X
	var map_to := MountainWalls.MAP_OFFSET_X + TerrainConfig.AREA_WIDTH
	for j in range(j_from, j_to):
		var j0 := maxi(j - 1, 0)
		var j1 := mini(j + 1, LENGTH - 1)
		var own_share := smoothstep(0.0, COLOR_BLEND, float(LENGTH - j))
		for c in width:
			var cell := j * width + c
			var li := (j - j_from) * width + c
			var c0 := maxi(c - 1, 0)
			var c1 := mini(c + 1, width - 1)
			var h := heights[cell]
			var dx := (heights[j * width + c1] - heights[j * width + c0]) / float(maxi(c1 - c0, 1))
			var dz := (heights[j1 * width + c] - heights[j0 * width + c]) / float(maxi(j1 - j0, 1))
			var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
			var above := h - base[c]
			var turf := smoothstep(MountainWalls.APRON_TURF_NY_NONE, MountainWalls.APRON_TURF_NY_FULL, ny) \
				* (1.0 - smoothstep(MountainWalls.APRON_TURF_TOP - MountainWalls.APRON_TURF_FADE, MountainWalls.APRON_TURF_TOP, above)) * MountainWalls.APRON_TURF_AMOUNT
			var snow := smoothstep(MountainWalls.APRON_SNOW_FROM, MountainWalls.APRON_SNOW_FULL, above + MountainWalls.APRON_SNOW_WANDER * shade_noise.get_noise_2d(c * 2.0 + 50.0, j * 2.0)) \
				* smoothstep(MountainWalls.APRON_SNOW_NY_NONE, MountainWalls.APRON_SNOW_NY_FULL, ny)
			if on_shoulder[cell] == 1:
				turf = 0.0
				snow = 0.0
			if snow > 0.02:
				control[li] = TerrainGroundPaint._pack(rock_id, MountainWalls.APRON_SNOW_ID, snow)
			else:
				control[li] = TerrainGroundPaint._pack(rock_id, MountainWalls.APRON_TURF_ID, turf)
			var curvature := heights[j * width + c0] + heights[j * width + c1] + heights[j0 * width + c] + heights[j1 * width + c] - 4.0 * h # > 0 in a crease
			var shade := clampf(1.0 - curvature * MountainWalls.APRON_CREASE_SHADE, MountainWalls.APRON_CREASE_MIN, MountainWalls.APRON_CREASE_MAX) / MountainWalls.APRON_CREASE_MAX
			shade *= 1.0 - MountainWalls.APRON_STRATA_SHADE * (0.5 + 0.5 * sin((h + 4.0 * shade_noise.get_noise_2d(float(c) * 3.0, float(j) * 3.0)) * TAU / MountainWalls.APRON_STRATA_PERIOD))
			shade *= lerpf(MountainWalls.APRON_SHADE_MIN, 1.0, 0.5 + 0.5 * shade_noise.get_noise_2d(float(c), float(j)))
			shade = lerpf(shade, 1.0, snow * 0.7) # snow fills creases and covers the rock's layers
			var tint := MountainWalls.MOUNTAIN_TINT.lerp(MountainWalls.APRON_TURF_TINT, turf).lerp(MountainWalls.APRON_SNOW_TINT, snow)
			var final := Color(shade * tint.r, shade * tint.g, shade * tint.b)
			if own_share < 1.0 and edge_color.size() >= width * 4:
				# What the row south of it is coloured: the side aprons' pixels as they are, the
				# map's with the mountain's tint the ground paint multiplies into them later.
				var edge := Color(edge_color[c * 4] / 255.0, edge_color[c * 4 + 1] / 255.0, edge_color[c * 4 + 2] / 255.0)
				if c >= map_from and c < map_to:
					edge = Color(edge.r * MountainWalls.MOUNTAIN_TINT.r, edge.g * MountainWalls.MOUNTAIN_TINT.g, edge.b * MountainWalls.MOUNTAIN_TINT.b)
				final = edge.lerp(final, own_share)
			color[li * 4] = int(255.0 * final.r)
			color[li * 4 + 1] = int(255.0 * final.g)
			color[li * 4 + 2] = int(255.0 * final.b)
			color[li * 4 + 3] = 128 # roughness left as it is
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = {"control": control, "color": color}
	mutex.unlock()
static func _noise(noise_seed: int, frequency: float, fractal: int, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH if fractal == FastNoiseLite.FRACTAL_FBM else FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = fractal
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	return noise

## The stand-in for the castle: a plain dark block standing in the ground at SITE_PX, with
## collision (reachable, not enterable) and lit windows. Its height is read from the terrain as
## imported (`terrain`), so this runs after the import. Added to `parent_node` (deferred, like
## the other generated bodies).
static func spawn_placeholder(parent_node: Node, terrain: Terrain3D, heightmap_corner: Vector3) -> void:
	var old := parent_node.get_node_or_null(PLACEHOLDER_NAME)
	if old:
		old.name = PLACEHOLDER_NAME + "_old"
		old.queue_free()
	var data: Terrain3DData = terrain.get_data()
	var centre := Vector3(heightmap_corner.x + SITE_PX.x, 0.0, heightmap_corner.z + SITE_PX.y)
	var size := PLACEHOLDER_SIZE

	# The lowest ground under the footprint.
	var ground := INF
	for dz in range(-int(size.z * 0.5), int(size.z * 0.5) + 1, SITE_GROUND_STEP):
		for dx in range(-int(size.x * 0.5), int(size.x * 0.5) + 1, SITE_GROUND_STEP):
			var h := data.get_height(centre + Vector3(dx, 0.0, dz))
			if not is_nan(h):
				ground = minf(ground, h)
	if ground == INF:
		push_warning("TERRAIN_GEN: castle placeholder -- no terrain at its site, skipped")
		return
	var foot := Vector3(centre.x, ground - PLACEHOLDER_SINK, centre.z)
	print("TERRAIN_GEN: castle placeholder -- %.0f x %.0f m at map pixel (%.0f, %.0f), %.0f m tall, top %.0f m above the valley floor" % [size.x, size.z, SITE_PX.x, SITE_PX.y, size.y, foot.y + size.y - TerrainHeightmap.BASE_LEVEL])

	var body := StaticBody3D.new()
	body.name = PLACEHOLDER_NAME
	body.position = foot + Vector3(0.0, size.y * 0.5, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.12, 0.14)
	material.roughness = 0.9
	_add_box(body, "Castle", size, Vector3.ZERO, material)

	# Windows on its four faces, more of them toward the top (in the body's own space: its
	# origin is the middle of the block).
	var light_rng := RandomNumberGenerator.new()
	light_rng.seed = 0x43534C54 # 'CSLT': the same on every run
	var castle_points: Array[Vector3] = []
	for i in CASTLE_LIGHTS:
		var up := lerpf(-size.y * 0.5 + CASTLE_LIGHT_FROM, size.y * 0.5 - 3.0, sqrt(light_rng.randf()))
		var face := light_rng.randi_range(0, 3)
		var along := light_rng.randf_range(-0.42, 0.42)
		if face < 2:
			castle_points.append(Vector3((size.x * 0.5 + LIGHT_STAND_OFF) * (1.0 if face == 0 else -1.0), up, along * size.z))
		else:
			castle_points.append(Vector3(along * size.x, up, (size.z * 0.5 + LIGHT_STAND_OFF) * (1.0 if face == 2 else -1.0)))
	_add_glow_points(body, "CastleLights", castle_points, CASTLE_LIGHT_SIZE, light_rng)
	print("TERRAIN_GEN: lights -- %d on the castle" % castle_points.size())
	parent_node.add_child.call_deferred(body)

## Points of light: one glowing pane of `pane_size` m (x 0.75..1.25 each) at every one of
## `points` (in `parent`'s own space), as one MultiMesh named `node_name` under `parent`. The
## panes always face the camera, so each reads as a point of light from any side and any angle.
static func _add_glow_points(parent: Node3D, node_name: String, points: Array[Vector3], pane_size: Vector2, rng: RandomNumberGenerator) -> void:
	if points.is_empty():
		return
	var pane := QuadMesh.new()
	pane.size = pane_size
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color.BLACK
	glow.emission_enabled = true
	glow.emission = LIGHT_COLOR
	glow.emission_energy_multiplier = LIGHT_ENERGY
	glow.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	glow.billboard_keep_scale = true
	pane.material = glow
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = pane
	multimesh.instance_count = points.size()
	for i in points.size():
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * rng.randf_range(0.75, 1.25)), points[i]))
	var lights := MultiMeshInstance3D.new()
	lights.name = node_name
	lights.multimesh = multimesh
	lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(lights)

## A box mesh with a matching collider, both children of `body` at `offset`.
static func _add_box(body: StaticBody3D, box_name: String, size: Vector3, offset: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	var mesh := MeshInstance3D.new()
	mesh.name = box_name
	mesh.mesh = box
	mesh.position = offset
	body.add_child(mesh)
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.name = box_name + "Collider"
	collider.shape = shape
	collider.position = offset
	body.add_child(collider)
