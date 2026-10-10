## Grass groundcover -- STEP 1: the density bake (2026-09-25).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## GrassScatter.bake(...). Must run AFTER RockScatter.scatter_boulders (reads
## RockScatter.rock_keep_circles) and TreeScatter.scatter_trees (canopy via
## UnderstoryScatter._build_canopy_grid, which reads TreeScatter.tree_points).
##
## Design: grass is NOT scattered as instances here (a million tufts through the Terrain3D
## instancer would cost seconds of startup and all that memory). Instead this bakes ONE small
## texture, 1 px = 1 m, same pixel space as `heights`; step 2's GPU-particle emitters around the
## player read it and place tufts entirely on the GPU. Channels:
##   R  coverage 0..1 -- fraction of ground inside dense grass patches (patches themselves are
##                       made on the GPU): open x meadow variation x slope x rock x road x canopy
##   G  dry      0..1 -- ridges (convex), high ground, verges, noise; minus shade
##   B  tall     0..1 -- hollows (concave), clumps; shorter at verges
##   A  tussock  0..1 -- where isolated tussocks may grow (0 on road / in rock footprints / cliffs)
## "Rock" = boulders/erratics (rock_keep_circles), outcrops, cliff-mesh footprints, and a band
## along each cliff foot where the scree carpet lies. Steep ground is handled by the slope factor.
## Road distance is measured from the centreline, so grass stops at the PAINTED surface
## (TerrainRoad.ROAD_TEXTURE_HALF_WIDTH) but still grows on the graded shoulder beyond it.
##
## Debug (PerfDebug keys): G cycles an in-world decal overlay (off / density / dry / tall),
## H prints every factor at the player's feet.
class_name GrassScatter
extends RefCounted

## -- Density factors --
const SLOPE_BARE_NY := 0.70 ## normal.y at/below this -> no grass (~46 deg)
const SLOPE_FULL_NY := 0.88 ## normal.y at/above this -> full grass (~28 deg); thins in between
const ROCK_GAP := 0.25 ## m of bare ground right against any rock
const ROCK_FADE := 3.0 ## m over which grass recovers to full density away from rock
const SCREE_BAND_OFFSET := 1.0 ## m out from a cliff foot to the scree band's centre line
const SCREE_BAND_RADIUS := 1.5 ## m half-width of that band (scree margin is 0-3 m -- see RockScatter)
const SCREE_BAND_STEP := 0.75 ## m between stamped points along the foot
## Grass starts ROAD_CLEAR_MARGIN past the WORST-CASE painted road edge (TerrainRoad:
## ROAD_TEXTURE_HALF_WIDTH + ROAD_EDGE_NOISE_STRENGTH -- the paint edge wobbles), measured from BOTH
## the raw road path and the smoothed path the road mesh is built on (they differ on bends).
## The margin covers the 1 m/px bake's bilinear blur (~0.5 m) plus blade lean/bend. 2026-09-25:
## was 3.0 + 0.2 from the raw path only -> grass on the road on bends and at wide paint wobbles.
const ROAD_CLEAR_MARGIN := 0.5
const ROAD_FADE := 1.8 ## m over which grass recovers beyond that
## 2026-10-10 (Kirill: "a band of empty space clearing the grass blades to the sides of the road
## ... it looks like it's been mowed on purpose"): the two constants above gave every stretch of
## road the same bare band, 0.5 m past the WORST-CASE painted edge and 1.8 m more to full grass.
## The blades now go by the distance to the road's PAINTED vertices (those showing at least
## ROAD_PAINT_MIN_BLEND of the road texture) and by the verge's wear, a smooth noise:
##   reach = VERGE_REACH_MAX x smoothstep(VERGE_NOISE_LO, VERGE_NOISE_HI, noise) -- how far from
##           the stones the ground is worn to soil here; 0 on most of the road's length;
##   soil  = 1 within half of reach of the stones, 0 from reach (GrassScatter.verge_soil, which
##           the ground paint reads for the soil texture and for what the road's edge fades into);
##   grass = none within reach + VERGE_GRASS_GAP, full VERGE_GRASS_FADE further.
## So blades stand up to the stones where the verge is not worn, and the worn patches are
## lens-shaped, widest where the noise peaks. ROAD_CLEAR_MARGIN / ROAD_FADE and the distance to
## the centrelines are still computed, for debug_road_check only. Not handled: the RoadMesh
## overlay (built only while the road texture is not displaced) follows a smoothed centreline and
## can leave the paint on bends.
const ROAD_PAINT_MIN_BLEND := 0.3
const VERGE_NOISE_FREQ := 1.0 / 9.0 ## ~9 m features along the road
const VERGE_NOISE_LO := 0.42 ## 2026-10-10: were 0.5 / 0.72 -- Kirill: "they blend better but there's much fewer of them"
const VERGE_NOISE_HI := 0.62
const VERGE_REACH_MAX := 5.0 ## was 3: patches under about 4 m across cannot be round on the 1 m vertex grid
const VERGE_GRASS_GAP := 0.3
const VERGE_GRASS_FADE := 0.8
## R is COVERAGE (2026-09-25 "middle ground"): the fraction of ground inside dense grass patches,
## not a per-blade thinning factor. The patches themselves (2-6 m, soft edges) + gap tussocks are
## made on the GPU in grass_cull.glsl; this only sets how much of each area they cover. Targets
## (conifer glacial valley): open floor 60-80 %, grove edges 30-50 %, under dense canopy 5-15 %
## (needles + moss, ferns own it), road shoulder a short trampled band, rock/scree/steep ground
## tussocks only (via the A channel).
const OPEN_COVERAGE := 0.85 ## coverage of open, flat, rock/road-free ground at the top of MEADOW_VAR
const CANOPY_MIN_FACTOR := 0.15 ## coverage multiplier under full canopy -> ~5-15 %
const PATCH_NOISE_FREQ := 0.035 ## ~30 m features: broad meadow-to-meadow coverage variation
const MEADOW_VAR_MIN := 0.75 ## coverage multiplier at the low end of that variation (-> ~64-85 % open floor)
const CLUMP_NOISE_FREQ := 0.15 ## ~7 m features: now only drives the tall channel
## A = TUSSOCK ALLOWANCE: where isolated tussocks may grow in the gaps between patches (and on
## ground too rocky/steep for patches). 0 on the road and inside rock footprints.
const TUSSOCK_ROCK_CLEAR := 0.45 ## m -- no tussocks closer than this to a rock footprint
const TUSSOCK_SLOPE_BARE_NY := 0.45 ## normal.y below this (~63 deg) -> no tussocks either
const TUSSOCK_SLOPE_FULL_NY := 0.62

## -- Worn patches (2026-10-02): sparse bare-soil patches in the open ground. They were made in
## TerrainGroundPaint from its own noise, which the grass never saw, so the short gap blades grew
## across them. Now baked here: worn = smoothstep(WORN_LO, WORN_HI, mean of a regional + a detail
## noise), coverage x (1 - worn) (tussocks may still grow), and the ground paint reads `worn`.
const WORN_REGION_FREQ := 0.045 ## ~22 m: where worn patches occur
const WORN_DETAIL_FREQ := 0.25 ## ~4 m: their ragged outlines
const WORN_LO := 0.74
const WORN_HI := 0.88

## -- Patch map (2026-09-27): the blade PATCH noise, baked once here instead of computed per
## blade in grass_cull.glsl, so the GPU grass and the ground texture (TerrainGroundPaint) read the
## SAME patches -- the grass texture then lies exactly under the blades. PATCH_RES px per metre,
## raw noise 0..1 (R8); both sides apply smoothstep(PATCH_N_LO, PATCH_N_HI) and then
## keep = smoothstep(n, n + 2 * PATCH_EDGE, coverage) -- see patch_keep().
const PATCH_RES := 2 ## px per metre (0.5 m texels)
const PATCH_SCALE := 5.0 ## m -- main patch size (patches ~2-6 m across)
const PATCH_LACUNARITY := 2.27 ## second octave at ~2.2 m: ragged, lobed outlines
const PATCH_GAIN := 0.54
const PATCH_N_LO := 0.2
const PATCH_N_HI := 0.8
const PATCH_EDGE := 0.06

## -- Curvature (laplacian over CURV_RADIUS px; + = hollow, - = ridge) --
const CURV_RADIUS := 3
const CURV_FULL := 0.12 ## |laplacian| (1/m) that counts as a full hollow/ridge -- tune from the printed p10/p90

## -- Dry channel --
const DRY_NOISE_FREQ := 0.018 ## ~55 m features
const DRY_BASE := 0.15
const DRY_NOISE_WEIGHT := 0.35
const DRY_CONVEX_WEIGHT := 0.5 ## ridges dry out
const DRY_CONCAVE_WEIGHT := 0.4 ## hollows stay lush
const DRY_HEIGHT_WEIGHT := 0.2 ## higher ground slightly drier
const DRY_EDGE_WEIGHT := 0.25 ## trampled verges near road/rock
const DRY_SHADE_WEIGHT := 0.3 ## canopy shade keeps grass green

## -- Tall channel --
const TALL_BASE := 0.35
const TALL_CONCAVE_WEIGHT := 0.6
const TALL_CONVEX_WEIGHT := 0.35
const TALL_CLUMP_WEIGHT := 0.25
const TALL_EDGE_MIN := 0.5 ## tall multiplier right at a road/rock verge

## -- Debug overlay --
const OVERLAY_NODE_NAME := "GrassDebugDecal"
const OVERLAY_MODES: Array[String] = ["off", "density", "dry", "tall"]
const OVERLAY_ALPHA := 0.7

## Baked outputs, read by step 2 (grass renderer). Reset per run.
static var density_image: Image
static var density_texture: ImageTexture
static var height_texture: ImageTexture ## maps.height (FORMAT_RF, raw metres)
static var color_texture: ImageTexture ## maps.color (Terrain3D colour-variation map)
static var patch_image: Image ## blade patch noise, R8, PATCH_RES px/m (see PATCH_* above)
static var patch_texture: ImageTexture
static var worn := PackedByteArray() ## worn-soil weight per map pixel, 0..255 (see WORN_*)
static var verge_soil := PackedByteArray() ## worn road verge per map pixel, 0..255 (see VERGE_*)
static var map_corner := Vector3.ZERO ## world position of pixel (0, 0) -- WorldGenerator's heightmap_corner
static var map_size := Vector2i.ZERO
static var height_min := 0.0
static var height_max := 0.0
static var last_stats: Dictionary = {}

## DEBUG: the bake's inputs, kept so debug_probe() can explain any spot. ~2.5 MB.
static var _dbg: Dictionary = {}
static var _overlay_mode := 0

static func bake(_parent_node: Node, maps: Dictionary, corner: Vector3, rng: RandomNumberGenerator) -> void:
	var t0 := Time.get_ticks_msec()
	var width := TerrainConfig.AREA_WIDTH
	var length := TerrainConfig.AREA_LENGTH
	var n := width * length
	var heights: PackedFloat32Array = maps.heights
	map_corner = corner
	map_size = Vector2i(width, length)
	height_min = INF
	height_max = -INF
	for h in heights:
		height_min = minf(height_min, h)
		height_max = maxf(height_max, h)
	var hspan := maxf(height_max - height_min, 0.001)

	# -- Rock distance field (m, capped at ROCK_FADE) --
	var rock_d := PackedFloat32Array()
	rock_d.resize(n)
	rock_d.fill(ROCK_FADE)
	var circles: Array[Vector3] = []
	circles.append_array(RockScatter.rock_keep_circles)
	circles.append_array(DeadfallScatter.deadfall_keep_circles) # stumps + logs: no blades through them
	var boulder_count := circles.size()
	for oc in maps.outcrop_plan:
		circles.append(Vector3(oc.px, oc.pz, oc.radius))
	var outcrop_count := circles.size() - boulder_count
	var scree_points := _add_scree_band_circles(maps.cliff_features, circles)
	for c in circles:
		_stamp_circle(rock_d, width, length, c.x, c.y, c.z, ROCK_FADE)
	var rects := UnderstoryScatter._build_keep_rects(maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles)
	for kr in rects:
		_stamp_rect(rock_d, width, length, kr, ROCK_FADE)
	# The rock band along the edge where the mountain wall begins (2026-10-08).
	MountainWalls.stamp_rock_distance(rock_d, width, length, ROCK_FADE)
	var t_rock := Time.get_ticks_msec() - t0

	# -- Road distance field (m from centreline, capped) --
	var road_cap := road_clear_distance() + ROAD_FADE + 0.5
	var road_d := PackedFloat32Array()
	road_d.resize(n)
	road_d.fill(road_cap)
	var road_path: PackedVector2Array = maps.road_path
	var last_stamp := Vector2(-INF, -INF)
	var road_stamps := 0
	for p in road_path:
		if p.distance_squared_to(last_stamp) < 0.25: # path is dense; 0.5 m between stamps is plenty
			continue
		last_stamp = p
		_stamp_circle(road_d, width, length, p.x, p.y, 0.0, road_cap)
		road_stamps += 1
	# The visible road MESH follows a separately smoothed centreline (TerrainRoad.build_road_mesh:
	# _resample_path + _smooth_path_for_mesh(3, 4)) that drifts off the raw path on bends -- stamp it too.
	if road_path.size() >= 2:
		var mesh_path := TerrainRoad._smooth_path_for_mesh(TerrainRoad._resample_path(road_path, TerrainRoad.ROAD_MESH_SEGMENT_LENGTH), 3, 4)
		last_stamp = Vector2(-INF, -INF)
		for p in mesh_path:
			if p.distance_squared_to(last_stamp) < 0.25:
				continue
			last_stamp = p
			_stamp_circle(road_d, width, length, p.x, p.y, 0.0, road_cap)
			road_stamps += 1
	# Distance to the road's painted vertices (see VERGE_*), from the control map as the road left it.
	var paint_cap := VERGE_REACH_MAX + VERGE_GRASS_GAP + VERGE_GRASS_FADE + 1.0
	var paint_d := PackedFloat32Array()
	paint_d.resize(n)
	paint_d.fill(paint_cap)
	var road_control: PackedByteArray = (maps.control as Image).get_data() # FORMAT_RF: uint32 bits
	var min_blend := int(ROAD_PAINT_MIN_BLEND * 255.0)
	var painted := 0
	for pz in length:
		for px in width:
			var c := road_control.decode_u32((pz * width + px) * 4)
			# base = bits 27-31, overlay = 22-26, blend = 14-21
			if ((c >> 27) & 0x1F) == TerrainRoad.ROAD_TEXTURE_ID or (((c >> 22) & 0x1F) == TerrainRoad.ROAD_TEXTURE_ID and ((c >> 14) & 0xFF) >= min_blend):
				_stamp_circle(paint_d, width, length, px, pz, 0.0, paint_cap)
				painted += 1
	if not road_path.is_empty():
		var p0: Vector2 = road_path[0]
		if p0.x < -1.0 or p0.x > float(width) or p0.y < -1.0 or p0.y > float(length):
			push_warning("GRASS: road_path[0]=%s is outside heightmap pixel space -- road fade will be wrong" % p0)

	# -- Canopy (same field the understory uses) --
	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy_grid := UnderstoryScatter._build_canopy_grid(gw, gl)

	# -- Noise (FastNoiseLite.get_image runs in C++; ~1 ms each) --
	# The seeds are drawn in this fixed order; the images are then rendered together on worker
	# threads (2026-10-05: one get_image() is ~16 ms here, not ~1 ms, and there are six).
	var patch_noise := _noise(rng.randi(), PATCH_NOISE_FREQ)
	var clump_noise := _noise(rng.randi(), CLUMP_NOISE_FREQ)
	var dry_noise := _noise(rng.randi(), DRY_NOISE_FREQ)
	# Blade patch noise (see PATCH_*): 2 octaves, normalised 0..1. Seed drawn here so the worn
	# seeds below don't shift the patch layout.
	var pn := FastNoiseLite.new()
	pn.seed = rng.randi()
	pn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	pn.fractal_type = FastNoiseLite.FRACTAL_FBM
	pn.fractal_octaves = 2
	pn.fractal_lacunarity = PATCH_LACUNARITY
	pn.fractal_gain = PATCH_GAIN
	pn.frequency = 1.0 / (PATCH_SCALE * PATCH_RES)
	var worn_a_noise := _noise(rng.randi(), WORN_REGION_FREQ)
	var worn_b_noise := _noise(rng.randi(), WORN_DETAIL_FREQ)
	var verge_noise := _noise(rng.randi(), VERGE_NOISE_FREQ) # drawn last: the seeds above stay as they were
	var noise_images := noise_images_parallel([
		[patch_noise, width, length], [clump_noise, width, length], [dry_noise, width, length],
		[worn_a_noise, width, length], [worn_b_noise, width, length],
		[pn, width * PATCH_RES, length * PATCH_RES], [verge_noise, width, length]])
	var patch_n: PackedByteArray = (noise_images[0] as Image).get_data()
	var clump_n: PackedByteArray = (noise_images[1] as Image).get_data()
	var dry_n: PackedByteArray = (noise_images[2] as Image).get_data()
	var worn_a: PackedByteArray = (noise_images[3] as Image).get_data()
	var worn_b: PackedByteArray = (noise_images[4] as Image).get_data()
	var verge_n: PackedByteArray = (noise_images[6] as Image).get_data()
	var t_fields := Time.get_ticks_msec() - t0

	# -- Per-pixel combine, in row bands on worker threads (see _bake_band) --
	var bands := ceili(float(length) / BAKE_BAND_ROWS)
	var band_out: Array = []
	band_out.resize(bands)
	var ctx := {
		"width": width, "length": length, "heights": heights, "rock_d": rock_d, "road_d": road_d,
		"canopy_grid": canopy_grid, "gw": gw, "gl": gl,
		"patch_n": patch_n, "clump_n": clump_n, "dry_n": dry_n, "worn_a": worn_a, "worn_b": worn_b,
		"paint_d": paint_d, "verge_n": verge_n,
		"height_min": height_min, "hspan": hspan, "road_lo": road_clear_distance(),
		"out": band_out, "mutex": Mutex.new(),
	}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_bake_band.bind(ctx), bands, -1, true))
	var bytes := PackedByteArray()
	worn = PackedByteArray()
	verge_soil = PackedByteArray()
	var dens_sum := 0.0
	var covered := 0
	var full := 0
	var dry_sum := 0.0
	var tall_sum := 0.0
	var curv_samples := PackedFloat32Array()
	for b: Dictionary in band_out:
		bytes.append_array(b.bytes)
		worn.append_array(b.worn)
		verge_soil.append_array(b.verge)
		curv_samples.append_array(b.curv_samples)
		dens_sum += b.dens_sum
		covered += b.covered
		full += b.full
		dry_sum += b.dry_sum
		tall_sum += b.tall_sum

	density_image = Image.create_from_data(width, length, false, Image.FORMAT_RGBA8, bytes)
	density_texture = ImageTexture.create_from_image(density_image)
	height_texture = ImageTexture.create_from_image(maps.height)
	color_texture = ImageTexture.create_from_image(maps.color)
	patch_image = noise_images[5]
	patch_texture = ImageTexture.create_from_image(patch_image)
	_dbg = {"heights": heights, "rock_d": rock_d, "road_d": road_d, "paint_d": paint_d, "verge_n": verge_n, "canopy": canopy_grid, "gw": gw, "gl": gl, "patch": patch_n, "clump": clump_n, "dry": dry_n}

	curv_samples.sort()
	var cs := curv_samples.size()
	var c10 := curv_samples[int(cs * 0.1)] if cs > 0 else 0.0
	var c90 := curv_samples[int(cs * 0.9)] if cs > 0 else 0.0
	last_stats = {"mean_density": dens_sum / n, "covered_pct": 100.0 * covered / n, "full_pct": 100.0 * full / n}
	print("GRASS: density bake -- mean density %.2f, %.1f%% of map has grass (>0.15), %.1f%% full (>0.8); on grassed ground mean dry %.2f / tall %.2f" % [
		dens_sum / n, 100.0 * covered / n, 100.0 * full / n, dry_sum / maxf(1.0, covered), tall_sum / maxf(1.0, covered)])
	print("GRASS: rock sources %d boulder/erratic + %d outcrop circle(s), %d scree-band point(s), %d cliff rect(s); road %d stamp(s) from %d path pts; curvature p10 %.3f p90 %.3f (CURV_FULL %.3f)" % [
		boulder_count, outcrop_count, scree_points, rects.size(), road_stamps, road_path.size(), c10, c90, CURV_FULL])
	# Output checksum: must not change across a speed-only change.
	print("GRASS: checksum density %d, worn %d, patch %d, verge %d (%d painted road vertices)" % [hash(bytes), hash(worn), hash(patch_image.get_data()), hash(verge_soil), painted])
	print("GRASS: timing -- rock field %d ms, all fields %d ms, total %d ms" % [t_rock, t_fields, Time.get_ticks_msec() - t0])

const BAKE_BAND_ROWS := 16 ## rows per worker-thread task in bake()

## bake()'s per-pixel combine for rows [band * BAKE_BAND_ROWS, +BAKE_BAND_ROWS). Runs on a worker
## thread: reads the shared fields in ctx, fills band-sized outputs of its own (density RGBA bytes,
## worn bytes, curvature samples, stats), which bake() joins in band order -- the same bytes the
## single loop produced. No engine-object calls in the loop.
static func _bake_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var length: int = ctx.length
	var heights: PackedFloat32Array = ctx.heights
	var rock_d: PackedFloat32Array = ctx.rock_d
	var canopy_grid: PackedFloat32Array = ctx.canopy_grid
	var gw: int = ctx.gw
	var gl: int = ctx.gl
	var patch_n: PackedByteArray = ctx.patch_n
	var clump_n: PackedByteArray = ctx.clump_n
	var dry_n: PackedByteArray = ctx.dry_n
	var worn_a: PackedByteArray = ctx.worn_a
	var worn_b: PackedByteArray = ctx.worn_b
	var paint_d: PackedFloat32Array = ctx.paint_d
	var verge_n: PackedByteArray = ctx.verge_n
	var h_min: float = ctx.height_min
	var hspan: float = ctx.hspan

	var z0 := band * BAKE_BAND_ROWS
	var z1 := mini(z0 + BAKE_BAND_ROWS, length)
	var bn := (z1 - z0) * width
	var bytes := PackedByteArray()
	bytes.resize(bn * 4)
	var worn_out := PackedByteArray()
	worn_out.resize(bn)
	var verge_out := PackedByteArray()
	verge_out.resize(bn)
	var w1 := width - 1
	var l1 := length - 1
	var inv_r2 := 1.0 / float(CURV_RADIUS * CURV_RADIUS)
	var dens_sum := 0.0
	var covered := 0
	var full := 0
	var dry_sum := 0.0
	var tall_sum := 0.0
	var curv_samples := PackedFloat32Array()
	for pz in range(z0, z1):
		var zm := maxi(pz - 1, 0)
		var zp := mini(pz + 1, l1)
		var zcm := maxi(pz - CURV_RADIUS, 0)
		var zcp := mini(pz + CURV_RADIUS, l1)
		var row := pz * width
		for px in width:
			var i := row + px
			var li := (pz - z0) * width + px
			var xm := maxi(px - 1, 0)
			var xp := mini(px + 1, w1)
			var h := heights[i]
			var dx := (heights[row + xp] - heights[row + xm]) / float(xp - xm)
			var dz := (heights[zp * width + px] - heights[zm * width + px]) / float(zp - zm)
			var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
			var curv := (heights[row + maxi(px - CURV_RADIUS, 0)] + heights[row + mini(px + CURV_RADIUS, w1)] \
				+ heights[zcm * width + px] + heights[zcp * width + px] - 4.0 * h) * inv_r2
			if (i & 63) == 0:
				curv_samples.append(curv)
			var cv := clampf(curv / CURV_FULL, -1.0, 1.0)
			var hollow := maxf(cv, 0.0)
			var ridge := maxf(-cv, 0.0)

			var slope_f := smoothstep(SLOPE_BARE_NY, SLOPE_FULL_NY, ny)
			var rock_f := smoothstep(ROCK_GAP, ROCK_FADE, rock_d[i])
			# The road's verge (see VERGE_*): worn to soil within `reach` of the stones, grass beyond.
			var reach := VERGE_REACH_MAX * smoothstep(VERGE_NOISE_LO, VERGE_NOISE_HI, verge_n[i] / 255.0)
			var pd := paint_d[i]
			if reach > 0.3:
				verge_out[li] = int((1.0 - smoothstep(reach * 0.5, reach, pd)) * 255.0 + 0.5)
			var road_f := smoothstep(reach + VERGE_GRASS_GAP, reach + VERGE_GRASS_GAP + VERGE_GRASS_FADE, pd)
			var canopy := UnderstoryScatter._grid_sample(canopy_grid, gw, gl, float(px), float(pz))
			var canopy_f := lerpf(1.0, CANOPY_MIN_FACTOR, canopy)
			var meadow_f := lerpf(MEADOW_VAR_MIN, 1.0, patch_n[i] / 255.0)
			var clump := clump_n[i] / 255.0
			var worn_w := smoothstep(WORN_LO, WORN_HI, (worn_a[i] + worn_b[i]) / 510.0)
			worn_out[li] = int(worn_w * 255.0 + 0.5)
			var density := OPEN_COVERAGE * meadow_f * slope_f * rock_f * road_f * canopy_f * (1.0 - worn_w) # = coverage
			var tussock := road_f * smoothstep(0.0, TUSSOCK_ROCK_CLEAR, rock_d[i]) * smoothstep(TUSSOCK_SLOPE_BARE_NY, TUSSOCK_SLOPE_FULL_NY, ny)

			var verge := rock_f * road_f # 0 right at a rock/road edge, 1 in the open
			var dry := clampf(DRY_BASE + DRY_NOISE_WEIGHT * (dry_n[i] / 127.5 - 1.0) + DRY_CONVEX_WEIGHT * ridge \
				- DRY_CONCAVE_WEIGHT * hollow + DRY_HEIGHT_WEIGHT * (h - h_min) / hspan \
				+ DRY_EDGE_WEIGHT * (1.0 - verge) - DRY_SHADE_WEIGHT * canopy, 0.0, 1.0)
			var tall := clampf((TALL_BASE + TALL_CONCAVE_WEIGHT * hollow - TALL_CONVEX_WEIGHT * ridge \
				+ TALL_CLUMP_WEIGHT * (clump * 2.0 - 1.0)) * lerpf(TALL_EDGE_MIN, 1.0, verge), 0.0, 1.0)

			var o := li * 4
			bytes[o] = int(density * 255.0 + 0.5)
			bytes[o + 1] = int(dry * 255.0 + 0.5)
			bytes[o + 2] = int(tall * 255.0 + 0.5)
			bytes[o + 3] = int(tussock * 255.0 + 0.5)
			dens_sum += density
			if density > 0.15:
				covered += 1
				dry_sum += dry
				tall_sum += tall
			if density > 0.8:
				full += 1

	var result := {"bytes": bytes, "worn": worn_out, "verge": verge_out, "curv_samples": curv_samples, "dens_sum": dens_sum, "covered": covered, "full": full, "dry_sum": dry_sum, "tall_sum": tall_sum}
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = result
	mutex.unlock()

## m from the road centreline where grass may start: worst-case painted edge + margin (see ROAD_CLEAR_MARGIN).
static func road_clear_distance() -> float:
	return TerrainRoad.ROAD_TEXTURE_HALF_WIDTH + TerrainRoad.ROAD_EDGE_NOISE_STRENGTH + ROAD_CLEAR_MARGIN

## Scree band: points along each single-sided cliff's foot, pushed a little out onto the low side
## (same foot-line maths as UnderstoryScatter._build_cliff_shade_grid). Returns how many were added.
static func _add_scree_band_circles(cliff_features: Array[Dictionary], circles: Array[Vector3]) -> int:
	var added := 0
	for f in cliff_features:
		if not f.has("step_height"):
			continue
		var low_side_sign := -1.0 if float(f.step_height) > 0.0 else 1.0
		var perp := Vector2(f.perp_x, f.perp_z)
		var axis := Vector2(f.axis_x, f.axis_z)
		var face_out := (perp * low_side_sign).normalized()
		var half_len: float = f.half_len
		var center: Vector2 = f.center
		var t := -half_len
		while t <= half_len:
			var nt := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve := float(f.curve_amplitude) * lerpf(sin(nt * PI * float(f.curve_frequency) + float(f.curve_phase)), sin(nt * PI * float(f.curve_frequency2) + float(f.curve_phase2)), float(f.curve_weight2))
			var foot := center + axis * t + perp * (low_side_sign * float(f.edge_softness) + curve)
			var p := foot + face_out * SCREE_BAND_OFFSET
			circles.append(Vector3(p.x, p.y, SCREE_BAND_RADIUS))
			added += 1
			t += SCREE_BAND_STEP
	return added

## field[px,pz] = min(field, distance to a circle of radius r) within r + cap of its centre.
static func _stamp_circle(field: PackedFloat32Array, width: int, length: int, cx: float, cz: float, r: float, cap: float) -> void:
	var reach := r + cap
	var x0 := maxi(0, floori(cx - reach))
	var x1 := mini(width - 1, ceili(cx + reach))
	var z0 := maxi(0, floori(cz - reach))
	var z1 := mini(length - 1, ceili(cz + reach))
	for z in range(z0, z1 + 1):
		var fz := float(z) - cz
		var row := z * width
		for x in range(x0, x1 + 1):
			var fx := float(x) - cx
			var d := maxf(sqrt(fx * fx + fz * fz) - r, 0.0)
			if d < field[row + x]:
				field[row + x] = d

## Same for a cliff mesh's rotated local footprint box (UnderstoryScatter._build_keep_rects format).
static func _stamp_rect(field: PackedFloat32Array, width: int, length: int, kr: Dictionary, cap: float) -> void:
	var c: Vector2 = kr.c
	var ax: Vector2 = kr.ax
	var az: Vector2 = kr.az
	var bx0 := INF
	var bx1 := -INF
	var bz0 := INF
	var bz1 := -INF
	for lx in [float(kr.x0) - cap, float(kr.x1) + cap]:
		for lz in [float(kr.z0) - cap, float(kr.z1) + cap]:
			var p: Vector2 = c + ax * lx + az * lz
			bx0 = minf(bx0, p.x)
			bx1 = maxf(bx1, p.x)
			bz0 = minf(bz0, p.y)
			bz1 = maxf(bz1, p.y)
	var x0 := maxi(0, floori(bx0))
	var x1 := mini(width - 1, ceili(bx1))
	var z0 := maxi(0, floori(bz0))
	var z1 := mini(length - 1, ceili(bz1))
	for z in range(z0, z1 + 1):
		var row := z * width
		for x in range(x0, x1 + 1):
			var d := Vector2(float(x), float(z)) - c
			var lx := d.dot(ax)
			var lz := d.dot(az)
			var ex := maxf(maxf(float(kr.x0) - lx, lx - float(kr.x1)), 0.0)
			var ez := maxf(maxf(float(kr.z0) - lz, lz - float(kr.z1)), 0.0)
			var dist := sqrt(ex * ex + ez * ez)
			if dist < field[row + x]:
				field[row + x] = dist

## Normalised 0..255 noise, one byte per heightmap pixel (row-major, same layout as `heights`).
static func _noise_bytes(seed_value: int, freq: float, width: int, length: int) -> PackedByteArray:
	var img := _noise(seed_value, freq).get_image(width, length)
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	return img.get_data()

## The noise _noise_bytes renders (smooth simplex at `freq`).
static func _noise(seed_value: int, freq: float) -> FastNoiseLite:
	var fn := FastNoiseLite.new()
	fn.seed = seed_value
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.frequency = freq
	return fn

## Renders several noise images at the same time on the engine's worker threads. Each spec is
## [FastNoiseLite, width, height]; returns one L8 Image per spec, in the same order. Create the
## noises (and draw their seeds) in a fixed order BEFORE calling, so the result does not depend
## on thread timing.
static func noise_images_parallel(specs: Array) -> Array:
	var out: Array = []
	out.resize(specs.size())
	var ctx := {"specs": specs, "out": out, "mutex": Mutex.new()}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_noise_image_task.bind(ctx), specs.size(), -1, true))
	return out

static func _noise_image_task(index: int, ctx: Dictionary) -> void:
	var spec: Array = ctx.specs[index]
	var img: Image = (spec[0] as FastNoiseLite).get_image(spec[1], spec[2])
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[index] = img
	mutex.unlock()

## ---------------------------------------------------------------- DEBUG ----

## PerfDebug key G: cycles the terrain overlay off -> density -> dry -> tall -> off.
## A Decal covering the whole map, projecting a colour-coded copy of the bake straight down.
static func cycle_debug_overlay(parent_node: Node) -> String:
	var old := parent_node.get_node_or_null(OVERLAY_NODE_NAME)
	if old:
		old.queue_free()
	if density_image == null:
		return "[Grass] no bake yet -- overlay unavailable"
	_overlay_mode = (_overlay_mode + 1) % OVERLAY_MODES.size()
	if _overlay_mode == 0:
		return "[Grass] overlay off"
	var decal := Decal.new()
	decal.name = OVERLAY_NODE_NAME
	decal.texture_albedo = ImageTexture.create_from_image(_build_overlay_image(_overlay_mode))
	decal.size = Vector3(map_size.x, (height_max - height_min) + 60.0, map_size.y)
	decal.position = map_corner + Vector3(map_size.x * 0.5, (height_min + height_max) * 0.5, map_size.y * 0.5)
	decal.upper_fade = 0.0
	decal.lower_fade = 0.0
	decal.normal_fade = 0.0
	decal.albedo_mix = 1.0
	parent_node.add_child(decal)
	var legend: String = {
		1: "red = no grass -> green = full grass",
		2: "grey = no grass; green = lush -> straw = dry",
		3: "grey = no grass; dark blue = short -> cyan = tall",
	}[_overlay_mode]
	return "[Grass] overlay: %s (%s). The road should read as a clean no-grass stripe -- if it's offset or mirrored, the overlay is misaligned." % [OVERLAY_MODES[_overlay_mode], legend]

static func _build_overlay_image(mode: int) -> Image:
	var src := density_image.get_data()
	var n := map_size.x * map_size.y
	var out := PackedByteArray()
	out.resize(n * 4)
	var a := int(OVERLAY_ALPHA * 255.0)
	for i in n:
		var d := src[i * 4] / 255.0
		var c: Color
		match mode:
			1:
				c = Color(0.85, 0.1, 0.1).lerp(Color(0.1, 0.95, 0.2), d)
			2:
				c = Color(0.3, 0.3, 0.3) if d < 0.05 else Color(0.15, 0.8, 0.2).lerp(Color(0.95, 0.8, 0.3), src[i * 4 + 1] / 255.0)
			_:
				c = Color(0.3, 0.3, 0.3) if d < 0.05 else Color(0.1, 0.2, 0.6).lerp(Color(0.3, 0.95, 1.0), src[i * 4 + 2] / 255.0)
		var o := i * 4
		out[o] = int(c.r * 255.0)
		out[o + 1] = int(c.g * 255.0)
		out[o + 2] = int(c.b * 255.0)
		out[o + 3] = a
	return Image.create_from_data(map_size.x, map_size.y, false, Image.FORMAT_RGBA8, out)

## PerfDebug key H: every input and factor at a world position, recomputed with the bake's constants.
static func debug_probe(world_pos: Vector3) -> String:
	if density_image == null or _dbg.is_empty():
		return "[Grass] no bake yet"
	var px := int(round(world_pos.x - map_corner.x))
	var pz := int(round(world_pos.z - map_corner.z))
	var width := map_size.x
	var length := map_size.y
	if px < 0 or pz < 0 or px >= width or pz >= length:
		return "[Grass] (%d, %d) is outside the map" % [px, pz]
	var i := pz * width + px
	var heights: PackedFloat32Array = _dbg.heights
	var xm := maxi(px - 1, 0)
	var xp := mini(px + 1, width - 1)
	var zm := maxi(pz - 1, 0)
	var zp := mini(pz + 1, length - 1)
	var dx := (heights[pz * width + xp] - heights[pz * width + xm]) / float(xp - xm)
	var dz := (heights[zp * width + px] - heights[zm * width + px]) / float(zp - zm)
	var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
	var rock_d: float = _dbg.rock_d[i]
	var paint_d: float = _dbg.paint_d[i]
	var reach := VERGE_REACH_MAX * smoothstep(VERGE_NOISE_LO, VERGE_NOISE_HI, _dbg.verge_n[i] / 255.0)
	var canopy := UnderstoryScatter._grid_sample(_dbg.canopy, _dbg.gw, _dbg.gl, float(px), float(pz))
	var px_col := density_image.get_pixel(px, pz)
	return "[Grass] pixel (%d, %d): COVERAGE %.2f  tussock %.2f  dry %.2f  tall %.2f\n  open    x%.2f\n  meadow  noise %.2f -> x%.2f\n  slope   normal.y %.2f -> x%.2f\n  rock    %.1f m -> x%.2f\n  road    %.1f m from the painted road, verge worn to %.1f m -> x%.2f\n  canopy  %.2f -> x%.2f" % [
		px, pz, px_col.r, px_col.a, px_col.g, px_col.b,
		OPEN_COVERAGE,
		_dbg.patch[i] / 255.0, lerpf(MEADOW_VAR_MIN, 1.0, _dbg.patch[i] / 255.0),
		ny, smoothstep(SLOPE_BARE_NY, SLOPE_FULL_NY, ny),
		rock_d, smoothstep(ROCK_GAP, ROCK_FADE, rock_d),
		paint_d, reach, smoothstep(reach + VERGE_GRASS_GAP, reach + VERGE_GRASS_GAP + VERGE_GRASS_FADE, paint_d),
		canopy, lerpf(1.0, CANOPY_MIN_FACTOR, canopy)]

## DEBUG: does the BAKE put any grass on the painted road? Counts pixels within the worst-case
## painted edge (ROAD_TEXTURE_HALF_WIDTH + ROAD_EDGE_NOISE_STRENGTH) of either road centreline
## that have coverage (R) or tussock allowance (A) > 0. 0 = the bake is clean and anything seen
## on the road comes from how blades are drawn (lean / distance widening), not from the map.
static func debug_road_check() -> String:
	if density_image == null or _dbg.is_empty():
		return "[Grass] no bake yet"
	var road_d: PackedFloat32Array = _dbg.road_d
	var data := density_image.get_data()
	var edge := TerrainRoad.ROAD_TEXTURE_HALF_WIDTH + TerrainRoad.ROAD_EDGE_NOISE_STRENGTH
	var on_road := 0
	var with_cov := 0
	var with_tus := 0
	var max_cov := 0
	var min_d_with_grass := INF
	for i in road_d.size():
		var r := data[i * 4]
		var a := data[i * 4 + 3]
		if r > 0 or a > 0:
			min_d_with_grass = minf(min_d_with_grass, road_d[i])
		if road_d[i] >= edge:
			continue
		on_road += 1
		if r > 0:
			with_cov += 1
			max_cov = maxi(max_cov, r)
		if a > 0:
			with_tus += 1
	return "[Grass] road check: %d px within %.1f m of the road centrelines; %d with coverage (max %.2f), %d with tussock allowance; nearest grass-allowed px is %.2f m from a centreline (clear distance %.2f m)" % [
		on_road, edge, with_cov, max_cov / 255.0, with_tus, min_d_with_grass, road_clear_distance()]

## Blade-patch keep (0..1) at heightmap pixel (px, pz) for coverage c -- the CPU twin of
## blade_patch_keep()'s patch term in grass_cull.glsl (tussocks not included). Reads the texel at
## exactly that point, which is what the GPU samples for a blade standing there.
static func patch_keep(px: int, pz: int, c: float) -> float:
	if patch_image == null or c <= 0.0:
		return 0.0
	var n := smoothstep(PATCH_N_LO, PATCH_N_HI, patch_image.get_pixel(px * PATCH_RES, pz * PATCH_RES).r)
	return smoothstep(n, n + 2.0 * PATCH_EDGE, c)

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	density_image = null
	patch_image = null
	patch_texture = null
	worn = PackedByteArray()
	verge_soil = PackedByteArray()
	density_texture = null
	height_texture = null
	color_texture = null
	last_stats = {}
	_dbg = {}
	_overlay_mode = 0
