## Flower scattering -- small flowering plants on the forest floor and in the open (2026-10-04).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## FlowerScatter.scatter_flowers(...). Must run AFTER TreeScatter.scatter_trees (canopy),
## RockScatter.scatter_boulders, DeadfallScatter.scatter_deadfall (keep-outs) and
## GrassScatter.bake (reads its coverage, so open-ground flowers stay off bare soil and rock).
##
## Four plants (meshes + ids: tools/setup_understory_assets.gd; docs/vegetation.md "Flowers"):
##   wood sorrel -- 6-19 cm, violet flowers. SHADE plant: colonies under the canopy.
##   poppy       -- 0.4-0.7 m, red. OPEN ground: loose drifts, plus a few along the road verges.
##   dandelion   -- 0.2 m rosette. OPEN ground: thin everywhere, more around clover.
##   clover      -- flat ~1.2 m carpet pieces. OPEN, near-level ground: a patch = 2-4 pieces
##                  overlapping + a few dandelions (the arrangement of the scanned meadow patch
##                  the two came from, rebuilt per patch so it doesn't repeat).
## Low plants (sorrel, dandelion, clover) are tilted to the ground normal; poppies stand upright.
## No collision, no physics.
class_name FlowerScatter
extends RefCounted

## Terrain3D mesh asset ids -- keep in sync with UNDERSTORY_ASSETS in tools/setup_understory_assets.gd.
const SORREL_IDS: Array[int] = [71, 72, 73, 74, 75, 76, 77, 78]
const POPPY_IDS: Array[int] = [79, 80, 81, 82, 83]
const DANDELION_ID := 84
const CLOVER_IDS: Array[int] = [85, 86, 87, 88]
const FLOWER_MESH_IDS: Array[int] = [71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88]

## Species mix: [id, weight, scale_min, scale_max].
## Sorrel A-H: A is a 3-leaf sprig, H the fullest plant. Scaled up a little so they read from eye height.
const SORREL_MIX := [
	[71, 0.08, 1.1, 1.6], [72, 0.14, 1.0, 1.5], [73, 0.12, 1.0, 1.5], [74, 0.14, 1.0, 1.4],
	[75, 0.10, 1.0, 1.5], [76, 0.12, 1.0, 1.5], [77, 0.15, 1.0, 1.4], [78, 0.15, 1.0, 1.4],
]
## Poppy A / B / C / D / H (the red ones; E / F are pink, G has no flowers): C is the big 0.8 x 1 m plant.
const POPPY_MIX := [[79, 0.25, 0.9, 1.25], [80, 0.2, 0.9, 1.3], [81, 0.15, 0.8, 1.1], [82, 0.2, 0.9, 1.3], [83, 0.2, 0.9, 1.25]]
const DANDELION_ROW := [DANDELION_ID, 1.0, 0.75, 1.2]
const CLOVER_MIX := [[85, 0.25, 0.85, 1.2], [86, 0.25, 0.85, 1.2], [87, 0.25, 0.85, 1.2], [88, 0.25, 0.85, 1.2]]

## Multiplies every scale range above. 1.0 = the sizes in the mix rows (near the scanned size);
## raised because the flowers got lost among the other foliage (user, 2026-10-04).
const SIZE_BOOST := 1.3

## -- Where --
const CANDIDATE_STEP := 0.8 ## m, jittered candidate grid -- at most one roll per step x step cell
const SORREL_SHADE_LO := 0.35 ## canopy cover below this -> no sorrel
const SORREL_SHADE_HI := 0.7 ## above this -> full SORREL_MAX_P
const OPEN_CANOPY_MAX := 0.25 ## canopy cover above this -> no poppies / dandelions / clover
const OPEN_MIN_GRASS := 0.3 ## grass coverage (GrassScatter bake) below this -> none either (bare soil, rock, verge)

## -- How many (chance per candidate) --
const SORREL_MAX_P := 0.6 ## inside a colony, in full shade
const SORREL_NOISE_FREQ := 0.09 ## ~11 m features: sorrel grows in colonies
const SORREL_COLONY_LO := 0.55 ## noise (0..1) below this -> no colony
const SORREL_COLONY_HI := 0.68 ## above this -> full density
const POPPY_MAX_P := 0.1 ## inside a drift
const POPPY_NOISE_FREQ := 0.03 ## ~33 m features: poppy drifts
const POPPY_DRIFT_LO := 0.55
const POPPY_DRIFT_HI := 0.7
const POPPY_VERGE_P := 0.05 ## extra chance within VERGE_REACH of the road
const VERGE_REACH := 3.0 ## m
const DANDELION_P := 0.012 ## anywhere in the open
const CLOVER_PATCH_P := 0.02 ## chance a candidate starts a clover patch (inside clover ground)
const CLOVER_NOISE_FREQ := 0.05 ## ~20 m features: where clover grows
const CLOVER_LO := 0.5
const CLOVER_HI := 0.65
const CLOVER_PIECES_MIN := 2
const CLOVER_PIECES_MAX := 4
const CLOVER_SPREAD := 0.9 ## m, pieces land within this of the patch centre (pieces are ~1.2 m: they overlap)
const CLOVER_DANDELIONS_MIN := 2
const CLOVER_DANDELIONS_MAX := 5
const CLOVER_DANDELION_SPREAD := 1.6 ## m

## -- Placement --
const MAX_SLOPE_NORMAL_Y := 0.72 ## ~44 deg max, like the understory
const CLOVER_MIN_NORMAL_Y := 0.93 ## ~21 deg max: a flat 1.2 m piece floats or digs in on steeper ground
const KEEPOUT_RADIUS := 0.25 ## m, footprint for the rock / deadfall keep-out tests
const CLOVER_KEEPOUT_RADIUS := 0.6
const EMBED := 0.02 ## m sunk into the ground
const POPPY_LEAN_MAX_DEG := 7.0
const EDGE_MARGIN := 1.5 ## px kept off the heightmap border

## Last run's counts, for debugging / docs.
static var last_counts: Dictionary = {}

static func scatter_flowers(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var t0 := Time.get_ticks_msec()
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	var assets: Terrain3DAssets = terrain.get_assets()
	var active: Dictionary = {}
	var transforms: Dictionary = {}
	var counts := {"candidates": 0, "sorrel": 0, "poppy": 0, "poppy_verge": 0, "dandelion": 0, "clover": 0, "clover_patches": 0, "rejected": 0}
	for id in FLOWER_MESH_IDS:
		instancer.clear_by_mesh(id)
		active[id] = assets != null and assets.get_mesh_asset(id) != null
		transforms[id] = [] as Array[Transform3D]
	if not active.values().has(true):
		print("TERRAIN_GEN: no flower mesh assets registered (ids %s) -- run build_understory_assets() in tools/setup_understory_assets.gd" % str(FLOWER_MESH_IDS))
		return
	if GrassScatter.density_image == null:
		print("TERRAIN_GEN: flowers skipped -- GrassScatter.bake has not run")
		return

	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	keep_circles.append_array(RockScatter.rock_keep_circles)
	var ctx := {
		"heights": heights, "width": width, "length": length, "corner": import_position, "rng": rng,
		"road": road_weight, "rects": UnderstoryScatter._build_keep_rects(cliff_plan, cliff_top_profiles),
		"circles": keep_circles, "active": active, "transforms": transforms, "counts": counts,
	}
	var coverage := GrassScatter.density_image.get_data() # RGBA8, R = grass coverage
	var min_grass := int(OPEN_MIN_GRASS * 255.0)

	var sorrel_noise := _noise(rng, SORREL_NOISE_FREQ)
	var poppy_noise := _noise(rng, POPPY_NOISE_FREQ)
	var clover_noise := _noise(rng, CLOVER_NOISE_FREQ)

	var steps_x := int((float(width - 1) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	var steps_z := int((float(length - 1) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	# The candidate rows run in bands on the engine's worker threads, one random stream per row
	# (2026-10-05, same scheme and same caveat as UnderstoryScatter.scatter_understory: a seed
	# gives the same flowers every run, but not the ones it gave when all rows shared `rng`).
	var bands := ceili(float(steps_z) / BAND_ROWS)
	var band_out: Array = []
	band_out.resize(bands)
	ctx.merge({
		"canopy": canopy, "gw": gw, "gl": gl, "coverage": coverage, "min_grass": min_grass,
		"sorrel_noise": sorrel_noise, "poppy_noise": poppy_noise, "clover_noise": clover_noise,
		"steps_x": steps_x, "steps_z": steps_z, "row_seed": rng.randi(),
		"out": band_out, "mutex": Mutex.new(),
	})
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_scatter_band.bind(ctx), bands, -1, true))
	for b: Dictionary in band_out:
		for id in FLOWER_MESH_IDS:
			(transforms[id] as Array).append_array(b.transforms[id])
		for key in counts:
			counts[key] += b.counts[key]
	var checksum := 0 # the same seed must print the same number on every run
	for id in FLOWER_MESH_IDS:
		checksum = hash([checksum, transforms[id]])
	print("TERRAIN_GEN: flower placement checksum %d" % checksum)

	for id in FLOWER_MESH_IDS:
		var list: Array[Transform3D] = transforms[id]
		if not list.is_empty():
			var colors := PackedColorArray()
			colors.resize(list.size())
			colors.fill(Color.WHITE)
			instancer.add_transforms(id, list, colors, true)

	last_counts = counts
	print("TERRAIN_GEN: flowers -- %d wood sorrel, %d poppies (%d on road verges), %d dandelions, %d clover piece(s) in %d patch(es) from %d candidate spots; %d rejected (slope / road / rock / deadfall); %d ms" % [
		counts.sorrel, counts.poppy, counts.poppy_verge, counts.dandelion, counts.clover, counts.clover_patches, counts.candidates, counts.rejected, Time.get_ticks_msec() - t0])

const BAND_ROWS := 16 ## candidate rows per worker-thread task in scatter_flowers()

## scatter_flowers()'s candidate loop for rows [band * BAND_ROWS, +BAND_ROWS). Runs on a worker
## thread: reads the shared data in `shared`, and gives _add / _add_clover_patch its own copy of
## that dictionary with band-local "rng", "transforms" and "counts", which the caller joins in
## band order. One random stream per row, seeded from shared.row_seed and the row number.
static func _scatter_band(band: int, shared: Dictionary) -> void:
	var width: int = shared.width
	var length: int = shared.length
	var canopy: PackedFloat32Array = shared.canopy
	var gw: int = shared.gw
	var gl: int = shared.gl
	var coverage: PackedByteArray = shared.coverage
	var min_grass: int = shared.min_grass
	var sorrel_noise: FastNoiseLite = shared.sorrel_noise
	var poppy_noise: FastNoiseLite = shared.poppy_noise
	var clover_noise: FastNoiseLite = shared.clover_noise
	var steps_x: int = shared.steps_x
	var steps_z: int = shared.steps_z
	var row_seed: int = shared.row_seed

	var rng := RandomNumberGenerator.new()
	var transforms := {}
	for id in FLOWER_MESH_IDS:
		transforms[id] = [] as Array[Transform3D]
	var counts := {"candidates": 0, "sorrel": 0, "poppy": 0, "poppy_verge": 0, "dandelion": 0, "clover": 0, "clover_patches": 0, "rejected": 0}
	var ctx := shared.duplicate()
	ctx.rng = rng
	ctx.transforms = transforms
	ctx.counts = counts
	var n_candidates := 0
	for iz in range(band * BAND_ROWS, mini((band + 1) * BAND_ROWS, steps_z)):
		rng.seed = hash(row_seed + iz)
		for ix in steps_x:
			n_candidates += 1
			var px := EDGE_MARGIN + (float(ix) + rng.randf()) * CANDIDATE_STEP
			var pz := EDGE_MARGIN + (float(iz) + rng.randf()) * CANDIDATE_STEP
			var c := UnderstoryScatter._grid_sample(canopy, gw, gl, px, pz)
			if c >= SORREL_SHADE_LO:
				var colony := smoothstep(SORREL_COLONY_LO, SORREL_COLONY_HI, sorrel_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
				if colony > 0.0 and rng.randf() < SORREL_MAX_P * colony * smoothstep(SORREL_SHADE_LO, SORREL_SHADE_HI, c):
					if _add(ctx, UnderstoryScatter._pick_species(SORREL_MIX, rng), px, pz, true, MAX_SLOPE_NORMAL_Y, KEEPOUT_RADIUS):
						counts.sorrel += 1
				continue
			if c > OPEN_CANOPY_MAX:
				continue
			var idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
			if coverage[idx * 4] < min_grass:
				continue
			var verge := _near_road(ctx, px, pz)
			var p_poppy := POPPY_MAX_P * smoothstep(POPPY_DRIFT_LO, POPPY_DRIFT_HI, poppy_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
			if verge:
				p_poppy += POPPY_VERGE_P
			var p_clover := CLOVER_PATCH_P * smoothstep(CLOVER_LO, CLOVER_HI, clover_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
			var roll := rng.randf()
			if roll < p_poppy:
				if _add(ctx, UnderstoryScatter._pick_species(POPPY_MIX, rng), px, pz, false, MAX_SLOPE_NORMAL_Y, KEEPOUT_RADIUS):
					counts.poppy += 1
					if verge:
						counts.poppy_verge += 1
			elif roll < p_poppy + DANDELION_P:
				if _add(ctx, DANDELION_ROW, px, pz, true, MAX_SLOPE_NORMAL_Y, KEEPOUT_RADIUS):
					counts.dandelion += 1
			elif roll < p_poppy + DANDELION_P + p_clover:
				_add_clover_patch(ctx, px, pz)
	counts.candidates = n_candidates

	var mutex: Mutex = shared.mutex
	mutex.lock()
	(shared.out as Array)[band] = {"transforms": transforms, "counts": counts}
	mutex.unlock()

## One clover patch: 2-4 carpet pieces overlapping around the centre + a few dandelions among them.
static func _add_clover_patch(ctx: Dictionary, px: float, pz: float) -> void:
	var rng: RandomNumberGenerator = ctx.rng
	var placed := 0
	for i in rng.randi_range(CLOVER_PIECES_MIN, CLOVER_PIECES_MAX):
		var a := rng.randf() * TAU
		var d := 0.0 if i == 0 else rng.randf() * CLOVER_SPREAD
		if _add(ctx, UnderstoryScatter._pick_species(CLOVER_MIX, rng), px + cos(a) * d, pz + sin(a) * d, true, CLOVER_MIN_NORMAL_Y, CLOVER_KEEPOUT_RADIUS):
			placed += 1
	if placed == 0:
		return
	ctx.counts.clover += placed
	ctx.counts.clover_patches += 1
	for i in rng.randi_range(CLOVER_DANDELIONS_MIN, CLOVER_DANDELIONS_MAX):
		var a := rng.randf() * TAU
		var d := sqrt(rng.randf()) * CLOVER_DANDELION_SPREAD
		if _add(ctx, DANDELION_ROW, px + cos(a) * d, pz + sin(a) * d, true, MAX_SLOPE_NORMAL_Y, KEEPOUT_RADIUS):
			ctx.counts.dandelion += 1

## Places one plant from a mix row [id, weight, scale_min, scale_max] if the spot is free.
## hug = tilt it to the ground normal (low, flat plants); otherwise upright with a small lean.
static func _add(ctx: Dictionary, row: Array, px: float, pz: float, hug: bool, min_normal_y: float, keepout: float) -> bool:
	var id: int = row[0]
	if not ctx.active[id]:
		return false
	var width: int = ctx.width
	var length: int = ctx.length
	var rng: RandomNumberGenerator = ctx.rng
	if px < EDGE_MARGIN or pz < EDGE_MARGIN or px > float(width - 1) - EDGE_MARGIN or pz > float(length - 1) - EDGE_MARGIN:
		return false
	var heights: PackedFloat32Array = ctx.heights
	var normal := TerrainUtil.sample_normal(heights, width, length, px, pz)
	var road: PackedFloat32Array = ctx.road
	if normal.y < min_normal_y \
			or road[clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)] > 0.0 \
			or RockScatter.boulder_blocked(px, pz, keepout, ctx.rects, ctx.circles) \
			or DeadfallScatter.keep_blocked(px, pz, keepout):
		ctx.counts.rejected += 1
		return false
	var basis := Basis(Vector3.UP, rng.randf() * TAU)
	if hug:
		var axis := Vector3.UP.cross(normal)
		if axis.length_squared() > 0.000001:
			basis = Basis(axis.normalized(), Vector3.UP.angle_to(normal)) * basis
	else:
		var lean := deg_to_rad(rng.randf_range(0.0, POPPY_LEAN_MAX_DEG))
		if lean > 0.0001:
			var la := rng.randf() * TAU
			basis = Basis(Vector3(cos(la), 0.0, sin(la)), lean) * basis
	var corner: Vector3 = ctx.corner
	var h := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
	var list: Array[Transform3D] = ctx.transforms[id]
	list.append(Transform3D(basis.scaled(Vector3.ONE * SIZE_BOOST * rng.randf_range(row[2], row[3])), Vector3(corner.x + px, h - EMBED, corner.z + pz)))
	return true

## True if the road is within VERGE_REACH (4 probes -- enough for a "near the road" bonus).
static func _near_road(ctx: Dictionary, px: float, pz: float) -> bool:
	var width: int = ctx.width
	var length: int = ctx.length
	var road: PackedFloat32Array = ctx.road
	for o: Vector2 in [Vector2(VERGE_REACH, 0.0), Vector2(-VERGE_REACH, 0.0), Vector2(0.0, VERGE_REACH), Vector2(0.0, -VERGE_REACH)]:
		if road[clampi(int(round(pz + o.y)), 0, length - 1) * width + clampi(int(round(px + o.x)), 0, width - 1)] > 0.0:
			return true
	return false

static func _noise(rng: RandomNumberGenerator, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = rng.randi()
	n.frequency = freq
	return n

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	last_counts = {}
