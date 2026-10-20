## Mushroom scattering -- fly agarics and boletes on the forest floor (2026-10-20).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## MushroomScatter.scatter_mushrooms(...). Must run AFTER TreeScatter (tree_points, the canopy),
## RockScatter, DeadfallScatter (keep-outs, deadfall_keep_circles), GrassScatter.bake (coverage)
## and TerrainGroundPaint.paint: each mushroom stands on the DRAWN ground
## (TerrainDisplacement.drawn), and the pine litter painted under the canopy is displaced by up to
## about 30 cm -- placed on the plain heightmap, a 10 cm mushroom would be buried or float.
##
## Both kinds grow from the soil with tree roots (mycorrhizal), not on wood, so they come in
## TROOPS of one kind:
##   by trees    -- some trees get a troop in their root zone, 0.7-2.5 m x tree scale from the trunk;
##   on the floor -- a jittered grid under the canopy, in patches; some fly agaric troops there
##                  are an arc of a "fairy ring" instead of a clump;
##   by deadfall -- a few troops beside stumps and logs (damp ground), not on them.
## Mushrooms stand upright (they grow against gravity) with a small lean. No collision, no shadows.
## Meshes + ids: tools/setup_ground_debris_assets.gd (DEBRIS, ids 89-102). Drawn by PlantField.
class_name MushroomScatter
extends RefCounted

## Terrain3D mesh asset ids -- keep in sync with DEBRIS in tools/setup_ground_debris_assets.gd.
const RED_IDS: Array[int] = [89, 90, 91, 92, 93, 94, 95, 96, 97]
const BOLETE_IDS: Array[int] = [98, 99, 100, 101, 102]
const MUSHROOM_MESH_IDS: Array[int] = [89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102]

## Kind mix: [id, weight, scale_min, scale_max, radius (m at scale 1: half the cap's width)].
## Fly agaric a-c are mature (11-18 cm, wide caps), d-i younger (6-11 cm); more young than old.
const RED_MIX := [
	[89, 0.06, 0.9, 1.15, 0.05], [90, 0.08, 0.9, 1.15, 0.047], [91, 0.1, 0.9, 1.2, 0.05],
	[92, 0.13, 0.9, 1.25, 0.032], [93, 0.13, 0.9, 1.25, 0.025], [94, 0.13, 0.9, 1.25, 0.022],
	[95, 0.13, 0.9, 1.25, 0.028], [96, 0.13, 0.9, 1.3, 0.019], [97, 0.11, 0.9, 1.3, 0.012],
]
## Bolete a-b tall (9-11 cm), c squat, d-e small (5 cm).
const BOLETE_MIX := [[98, 0.18, 0.85, 1.2, 0.05], [99, 0.2, 0.85, 1.2, 0.04], [100, 0.2, 0.85, 1.2, 0.04], [101, 0.21, 0.9, 1.3, 0.016], [102, 0.21, 0.9, 1.3, 0.015]]
## Multiplies every scale range above. 1.0 = the scanned size.
const SIZE_BOOST := 1.15
## Share of troops that are fly agarics (else boletes), by where they grow.
const RED_SHARE_PINE := 0.45 ## under a pine
const RED_SHARE_DECIDUOUS := 0.35 ## under a deciduous tree
const RED_SHARE_FLOOR := 0.4 ## on the floor / by deadfall

## -- Troops --
const TROOP_MIN := 2
const TROOP_MAX := 8 ## size = lerp(MIN, MAX, randf()^2): small troops more often than big ones
const TROOP_SPREAD := 0.55 ## m (x sqrt(randf)): how far a mushroom lands from the troop's centre
const TROOP_ATTEMPTS := 3 ## spots tried per mushroom before it is dropped
const SPACING := 0.9 ## x the two caps' radii: closest two mushrooms of a troop may stand
const LONE_P := 0.15 ## chance a troop is only one mushroom

## -- By trees --
const TREE_TROOP_P := 0.16 ## chance a tree has a troop
const ROOT_ZONE_MIN := 0.7 ## m x tree scale from the trunk centre
const ROOT_ZONE_MAX := 2.5

## -- On the floor --
const FLOOR_STEP := 5.0 ## m, jittered candidate grid
const FLOOR_MAX_P := 0.14 ## chance per candidate, full canopy, inside a patch
const FLOOR_CANOPY_LO := 0.35 ## canopy cover below this -> none
const FLOOR_CANOPY_HI := 0.75 ## above this -> full chance
const PATCH_NOISE_FREQ := 0.035 ## ~30 m: mushroom years / damp hollows
const PATCH_LO := 0.45
const PATCH_HI := 0.65
const RING_P := 0.25 ## chance a fly agaric troop on the floor is an arc of a ring
const RING_RADIUS_MIN := 0.9 ## m
const RING_RADIUS_MAX := 2.2
const RING_ARC_MIN := 0.35 ## share of the full circle
const RING_ARC_MAX := 0.9
const RING_STEP := 0.22 ## m between mushrooms along the ring (jittered)

## -- By deadfall --
const DEADFALL_P := 0.035 ## chance per stump / log footprint circle (a log has several)
const DEADFALL_GAP_MIN := 0.08 ## m from the footprint's edge
const DEADFALL_GAP_MAX := 0.45

## -- Placement --
const MIN_NORMAL_Y := 0.75 ## ~41 deg max
const MAX_GRASS := 0.55 ## grass coverage (GrassScatter bake) above this -> none: the grass would hide them
const TRUNK_PAD := 0.06 ## m kept from a trunk (TreeScatter.TREE_TRUNK_RADIUS x scale)
const EMBED := 0.006 ## m x scale sunk into the ground (the fly agarics' bulbs already reach below 0)
const LEAN_MAX_DEG := 8.0
const EDGE_MARGIN := 2.0 ## px kept off the heightmap border

## Last run's counts, for debugging / docs.
static var last_counts: Dictionary = {}

static func scatter_mushrooms(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var t0 := Time.get_ticks_msec()
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	var assets: Terrain3DAssets = terrain.get_assets()
	var active: Dictionary = {}
	var transforms: Dictionary = {}
	for id in MUSHROOM_MESH_IDS:
		instancer.clear_by_mesh(id)
		active[id] = assets != null and assets.get_mesh_asset(id) != null
		transforms[id] = [] as Array[Transform3D]
	if not active.values().has(true):
		print("TERRAIN_GEN: no mushroom mesh assets registered (ids %s) -- run setup_mesh_assets() in tools/setup_ground_debris_assets.gd" % str(MUSHROOM_MESH_IDS))
		return

	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	keep_circles.append_array(RockScatter.rock_keep_circles)
	var keep_grid := RockScatter.build_keep_grid(UnderstoryScatter._build_keep_rects(cliff_plan, cliff_top_profiles), keep_circles, width, length)
	var counts := {"trees": 0, "floor": 0, "rings": 0, "deadfall": 0, "red": 0, "bolete": 0, "rejected": 0}
	var ctx := {
		"heights": heights, "width": width, "length": length, "corner": import_position, "rng": rng,
		"road": road_weight, "active": active, "transforms": transforms, "counts": counts,
		"keep_start": keep_grid.start, "keep_data": keep_grid.data,
		"trunks": DeadfallScatter._build_trunk_grid(),
		"coverage": GrassScatter.density_image.get_data() if GrassScatter.density_image else PackedByteArray(),
		"max_grass": int(MAX_GRASS * 255.0),
	}

	# 1. Root zones of trees.
	for i in TreeScatter.tree_points.size():
		if rng.randf() >= TREE_TROOP_P:
			continue
		var tp := TreeScatter.tree_points[i]
		var a := rng.randf() * TAU
		var d := rng.randf_range(ROOT_ZONE_MIN, ROOT_ZONE_MAX) * tp.z
		var red_share := RED_SHARE_PINE if TreeScatter.TREE_IDS_PINE.has(TreeScatter.tree_mesh_ids[i]) else RED_SHARE_DECIDUOUS
		if _troop(ctx, tp.x + cos(a) * d, tp.y + sin(a) * d, rng.randf() < red_share) > 0:
			counts.trees += 1

	# 2. The shaded floor, in patches; some fly agaric troops are ring arcs.
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var patch_noise := FastNoiseLite.new()
	patch_noise.seed = rng.randi()
	patch_noise.frequency = PATCH_NOISE_FREQ
	var steps_x := int((float(width - 1) - 2.0 * EDGE_MARGIN) / FLOOR_STEP)
	var steps_z := int((float(length - 1) - 2.0 * EDGE_MARGIN) / FLOOR_STEP)
	for iz in steps_z:
		for ix in steps_x:
			var px := EDGE_MARGIN + (float(ix) + rng.randf()) * FLOOR_STEP
			var pz := EDGE_MARGIN + (float(iz) + rng.randf()) * FLOOR_STEP
			var roll := rng.randf()
			var c := UnderstoryScatter._grid_sample(canopy, gw, gl, px, pz)
			if c <= FLOOR_CANOPY_LO:
				continue
			var p := FLOOR_MAX_P * smoothstep(FLOOR_CANOPY_LO, FLOOR_CANOPY_HI, c) * smoothstep(PATCH_LO, PATCH_HI, patch_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
			if roll >= p:
				continue
			var red := rng.randf() < RED_SHARE_FLOOR
			if red and rng.randf() < RING_P:
				if _ring(ctx, px, pz) > 0:
					counts.rings += 1
			elif _troop(ctx, px, pz, red) > 0:
				counts.floor += 1

	# 3. Beside stumps and logs.
	for kc: Vector3 in DeadfallScatter.deadfall_keep_circles:
		if rng.randf() >= DEADFALL_P:
			continue
		var a := rng.randf() * TAU
		var d := kc.z + rng.randf_range(DEADFALL_GAP_MIN, DEADFALL_GAP_MAX)
		if _troop(ctx, kc.x + cos(a) * d, kc.y + sin(a) * d, rng.randf() < RED_SHARE_FLOOR) > 0:
			counts.deadfall += 1

	var checksum := 0 # the same seed must print the same number on every run
	for id in MUSHROOM_MESH_IDS:
		checksum = hash([checksum, transforms[id]])
	print("TERRAIN_GEN: mushroom placement checksum %d" % checksum)
	for id in MUSHROOM_MESH_IDS:
		var list: Array[Transform3D] = transforms[id]
		if PlantField.submit(&"mushrooms", id, assets.get_mesh_asset(id), list):
			continue
		if not list.is_empty():
			var colors := PackedColorArray()
			colors.resize(list.size())
			colors.fill(Color.WHITE)
			instancer.add_transforms(id, list, colors, true)

	last_counts = counts
	print("TERRAIN_GEN: mushrooms -- %d fly agarics + %d boletes in %d troops by trees, %d on the floor, %d ring arcs, %d by deadfall; %d spots rejected; placed on the drawn ground: %s; %d ms" % [
		counts.red, counts.bolete, counts.trees, counts.floor, counts.rings, counts.deadfall, counts.rejected, TerrainDisplacement.is_ready(), Time.get_ticks_msec() - t0])

## One troop of one kind round (px, pz). Returns how many mushrooms were placed.
static func _troop(ctx: Dictionary, px: float, pz: float, red: bool) -> int:
	var rng: RandomNumberGenerator = ctx.rng
	var mix: Array = RED_MIX if red else BOLETE_MIX
	var n := 1 if rng.randf() < LONE_P else int(round(lerpf(TROOP_MIN, TROOP_MAX, pow(rng.randf(), 2.0))))
	var placed: Array[Vector3] = [] # px, pz, radius of this troop's mushrooms
	for i in n:
		var row := UnderstoryScatter._pick_species(mix, rng)
		for attempt in TROOP_ATTEMPTS:
			var a := rng.randf() * TAU
			var d := 0.0 if i == 0 and attempt == 0 else sqrt(rng.randf()) * TROOP_SPREAD
			if _add(ctx, row, px + cos(a) * d, pz + sin(a) * d, placed):
				break
	return placed.size()

## An arc of a fly agaric "fairy ring": mushrooms spaced along part of a circle round (px, pz).
static func _ring(ctx: Dictionary, px: float, pz: float) -> int:
	var rng: RandomNumberGenerator = ctx.rng
	var radius := rng.randf_range(RING_RADIUS_MIN, RING_RADIUS_MAX)
	var arc := rng.randf_range(RING_ARC_MIN, RING_ARC_MAX) * TAU
	var start := rng.randf() * TAU
	var steps := maxi(3, int(arc * radius / RING_STEP))
	var placed: Array[Vector3] = []
	for i in steps:
		var a := start + arc * (float(i) + rng.randf_range(-0.3, 0.3)) / float(steps)
		var r := radius + rng.randf_range(-0.12, 0.12)
		_add(ctx, UnderstoryScatter._pick_species(RED_MIX, rng), px + cos(a) * r, pz + sin(a) * r, placed)
	return placed.size()

## Places one mushroom from a mix row if the spot is free; appends it to `placed` (its troop).
static func _add(ctx: Dictionary, row: Array, px: float, pz: float, placed: Array[Vector3]) -> bool:
	var id: int = row[0]
	if not ctx.active[id]:
		return false
	var width: int = ctx.width
	var length: int = ctx.length
	var rng: RandomNumberGenerator = ctx.rng
	var scale := SIZE_BOOST * rng.randf_range(row[2], row[3])
	var radius: float = float(row[4]) * scale
	if px < EDGE_MARGIN or pz < EDGE_MARGIN or px > float(width - 1) - EDGE_MARGIN or pz > float(length - 1) - EDGE_MARGIN:
		return false
	for q: Vector3 in placed:
		if Vector2(px - q.x, pz - q.y).length() < (radius + q.z) * SPACING:
			return false
	var heights: PackedFloat32Array = ctx.heights
	var road: PackedFloat32Array = ctx.road
	var idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
	var coverage: PackedByteArray = ctx.coverage
	var trunk := DeadfallScatter._nearest_trunk(ctx.trunks, Vector2(px, pz), 1.0)
	if TerrainUtil.sample_normal(heights, width, length, px, pz).y < MIN_NORMAL_Y \
			or road[idx] > 0.0 \
			or (not coverage.is_empty() and coverage[idx * 4] > ctx.max_grass) \
			or (trunk.z > 0.0 and Vector2(px - trunk.x, pz - trunk.y).length() < TreeScatter.TREE_TRUNK_RADIUS * trunk.z + TRUNK_PAD + radius) \
			or MountainWalls.on_mountain(px, pz, radius) \
			or RockScatter.keep_grid_blocked(px, pz, radius, ctx.keep_start, ctx.keep_data) \
			or DeadfallScatter.keep_blocked(px, pz, radius):
		ctx.counts.rejected += 1
		return false
	var basis := Basis(Vector3.UP, rng.randf() * TAU)
	var lean := deg_to_rad(rng.randf_range(0.0, LEAN_MAX_DEG))
	if lean > 0.0001:
		var la := rng.randf() * TAU
		basis = Basis(Vector3(cos(la), 0.0, sin(la)), lean) * basis
	var corner: Vector3 = ctx.corner
	var h := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
	var pos := TerrainDisplacement.drawn(Vector3(corner.x + px, h, corner.z + pz)) - Vector3(0.0, EMBED * scale, 0.0)
	var list: Array[Transform3D] = ctx.transforms[id]
	list.append(Transform3D(basis.scaled(Vector3.ONE * scale), pos))
	placed.append(Vector3(px, pz, radius))
	ctx.counts["red" if RED_IDS.has(id) else "bolete"] += 1
	return true

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	last_counts = {}
