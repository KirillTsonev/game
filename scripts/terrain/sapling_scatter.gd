## Sapling scattering -- the mid-storey between the shrubs (1-1.6 m) and the canopy (2026-10-04).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## SaplingScatter.scatter_saplings(...). Must run AFTER TreeScatter.scatter_trees (reads
## TreeScatter.tree_points / tree_mesh_ids), RockScatter.scatter_boulders and
## DeadfallScatter.scatter_deadfall (keep-outs).
##
## The saplings ARE the canopy trees, scaled down per instance (Kirill picked that look over cut
## pine tops, 2026-10-04) -- no new models or textures. They have their own Terrain3D mesh ids
## (64-68, registered by tools/setup_tree_assets.gd build_sapling_assets()) pointing at the same
## baked tree meshes, so they can switch to the impostor at 80 m instead of the trees' 175 m.
## Placement: young trees come up where there is light next to seed trees -- grove EDGES (canopy
## cover ~0.5), a few under the canopy, almost none in the open -- and in patches, not evenly.
## A sapling is usually the same kind (pine / deciduous) as the nearest canopy tree.
## No physics colliders. Stems are "soft" (Kirill, 2026-10-04): the player's path is bent around
## them, so walking into a sapling brushes past it instead of stopping -- see steer_around_stems().
class_name SaplingScatter
extends RefCounted

## Terrain3D mesh asset ids -- keep in sync with SAPLINGS in tools/setup_tree_assets.gd.
const SAPLING_MESH_IDS: Array[int] = [64, 65, 66, 67, 68]
## Species mix: [id, weight, base scale]. Base scale brings each tree to ~3.5-3.7 m; SIZE_MIN/MAX
## then vary it. Only leafy colour variants, and only the lighter meshes (tris in brackets).
const PINE_MIX := [
	[64, 0.40, 0.15], # PackPineB (1.9k), 23.4 m
	[65, 0.35, 0.13], # PackPineA2 (2.9k), 27.7 m
	[66, 0.25, 0.20], # PackPineC2 (4.8k), 17.7 m
]
const DECID_MIX := [
	[67, 0.60, 0.30], # PackDecidC2 (5.8k), 12.1 m
	[68, 0.40, 0.20], # PackDecidA2 (7.2k), 18.3 m
]
const SIZE_MIN := 0.6 ## x base scale -> ~2.1 m
const SIZE_MAX := 1.1 ## x base scale -> ~4.0 m

## -- Density --
const CANDIDATE_STEP := 3.0 ## m, jittered candidate grid -- at most one sapling per step x step cell
const MAX_P := 0.25 ## chance per candidate at a grove edge inside a patch
const CANOPY_WEIGHT := 0.15 ## share of MAX_P under closed canopy (the edge bump 4c(1-c) has weight 1)
const OPEN_P := 0.004 ## chance in the open (lone saplings; not tied to patches)
const PATCH_NOISE_FREQ := 0.04 ## ~25 m features: saplings come up in patches
const PATCH_LO := 0.45 ## noise (0..1) below this -> no saplings
const PATCH_HI := 0.65 ## above this -> full density

## -- Placement --
const MAX_SLOPE_NORMAL_Y := 0.76 ## ~40 deg max
const KEEPOUT_RADIUS := 0.5 ## m, footprint for the rock / deadfall keep-out tests
const TRUNK_CLEAR_RADIUS := 2.0 ## m (x tree scale): no sapling this close to a canopy trunk
const MIN_SPACING := 1.6 ## m between saplings
const PARENT_RADIUS := 14.0 ## m: the nearest canopy tree within this decides pine / deciduous
const PARENT_MATCH_P := 0.8 ## chance to follow it (else the other kind)
const EMBED := 0.05 ## m sunk into the ground
const LEAN_MAX_DEG := 5.0
const EDGE_MARGIN := 2.0 ## px kept off the heightmap border
const TREE_CELL := 8.0 ## m, bucket size of the canopy-tree lookup grid

## -- Soft stems (instead of colliders) --
## A hard stem collider stops the player dead on a head-on hit. Instead the player's own movement
## is bent around nearby stems (steer_around_stems, called by player.gd every physics frame).
const PUSH_RADIUS := 0.6 ## m from the stem centre to the player centre: where the bending starts
## Share of the speed TOWARD the stem that is turned sideways when right at the stem (0..1).
## Below 1 on purpose: the rest still carries the player forward, so a sapling wedged against a
## rock can be pushed through instead of trapping the player.
const PUSH_STRENGTH := 0.85
const STEM_CELL := 2.0 ## m, bucket size of the stem lookup grid (> PUSH_RADIUS, so 3x3 cells is enough)

## Last run's counts, for debugging / docs.
static var last_counts: Dictionary = {}
## Every sapling stem this run: Vector2i(cell) -> Array[Vector2(world x, world z)].
static var _stem_grid: Dictionary = {}
## Off while the sapling layer is hidden in the J layer panel.
static var push_enabled := true

static func scatter_saplings(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var t0 := Time.get_ticks_msec()
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	var assets: Terrain3DAssets = terrain.get_assets()
	var active: Dictionary = {}
	for id in SAPLING_MESH_IDS:
		instancer.clear_by_mesh(id)
		active[id] = assets != null and assets.get_mesh_asset(id) != null
	if not active.values().has(true):
		print("TERRAIN_GEN: no sapling mesh assets registered (ids %s) -- run build_sapling_assets() in tools/setup_tree_assets.gd" % str(SAPLING_MESH_IDS))
		return

	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var tree_grid := _build_tree_grid()
	var keep_rects := UnderstoryScatter._build_keep_rects(cliff_plan, cliff_top_profiles)
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	keep_circles.append_array(RockScatter.rock_keep_circles)

	var patch_noise := FastNoiseLite.new()
	patch_noise.seed = rng.randi()
	patch_noise.frequency = PATCH_NOISE_FREQ

	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	var counts := {"candidates": 0, "rolled": 0, "rej_slope": 0, "rej_road": 0, "rej_rock": 0, "rej_deadfall": 0, "rej_trunk": 0, "rej_spacing": 0, "pine": 0, "decid": 0}
	for id in SAPLING_MESH_IDS:
		transforms_by_mesh[id] = [] as Array[Transform3D]
		colors_by_mesh[id] = PackedColorArray()
		counts[id] = 0
	var spacing_grid: Dictionary = {} # Vector2i(cell of MIN_SPACING) -> Array[Vector2]

	var steps_x := int((float(width - 1) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	var steps_z := int((float(length - 1) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	for iz in steps_z:
		for ix in steps_x:
			counts.candidates += 1
			var px := EDGE_MARGIN + (float(ix) + rng.randf()) * CANDIDATE_STEP
			var pz := EDGE_MARGIN + (float(iz) + rng.randf()) * CANDIDATE_STEP
			var c := UnderstoryScatter._grid_sample(canopy, gw, gl, px, pz)
			var patch := smoothstep(PATCH_LO, PATCH_HI, patch_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
			var p := OPEN_P + MAX_P * (4.0 * c * (1.0 - c) + CANOPY_WEIGHT * c) * patch
			if rng.randf() >= p:
				continue
			counts.rolled += 1

			# Costlier checks only for spots that passed the roll.
			var normal := TerrainUtil.sample_normal(heights, width, length, px, pz)
			if normal.y < MAX_SLOPE_NORMAL_Y:
				counts.rej_slope += 1
				continue
			var idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
			if road_weight[idx] > 0.0:
				counts.rej_road += 1
				continue
			if MountainWalls.on_mountain(px, pz, KEEPOUT_RADIUS) or RockScatter.boulder_blocked(px, pz, KEEPOUT_RADIUS, keep_rects, keep_circles):
				counts.rej_rock += 1
				continue
			if DeadfallScatter.keep_blocked(px, pz, KEEPOUT_RADIUS):
				counts.rej_deadfall += 1
				continue
			var parent := _nearest_tree(tree_grid, px, pz)
			if parent.too_close:
				counts.rej_trunk += 1
				continue
			if _too_close(spacing_grid, px, pz):
				counts.rej_spacing += 1
				continue

			var pine: bool = parent.pine if parent.found else rng.randf() < 0.5
			if parent.found and rng.randf() >= PARENT_MATCH_P:
				pine = not pine
			var pick: Array = UnderstoryScatter._pick_species(PINE_MIX if pine else DECID_MIX, rng)
			var id: int = pick[0]
			if not active[id]:
				continue
			var scale := float(pick[2]) * rng.randf_range(SIZE_MIN, SIZE_MAX)
			var basis := Basis(Vector3.UP, rng.randf() * TAU)
			var lean := deg_to_rad(rng.randf_range(0.0, LEAN_MAX_DEG))
			if lean > 0.0001:
				var la := rng.randf() * TAU
				basis = Basis(Vector3(cos(la), 0.0, sin(la)), lean) * basis
			var h := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
			var pos := Vector3(import_position.x + px, h - EMBED, import_position.z + pz)
			transforms_by_mesh[id].append(Transform3D(basis.scaled(Vector3.ONE * scale), pos))
			colors_by_mesh[id].append(Color.WHITE)
			_add_stem(pos)
			var cell := Vector2i(floori(px / MIN_SPACING), floori(pz / MIN_SPACING))
			if not spacing_grid.has(cell):
				spacing_grid[cell] = []
			spacing_grid[cell].append(Vector2(px, pz))
			counts[id] += 1
			counts["pine" if pine else "decid"] += 1

	for id in SAPLING_MESH_IDS:
		if not (transforms_by_mesh[id] as Array).is_empty():
			instancer.add_transforms(id, transforms_by_mesh[id], colors_by_mesh[id], true)

	last_counts = counts
	var per_id: Array[String] = []
	for id in SAPLING_MESH_IDS:
		per_id.append("%d: %d" % [id, counts[id]])
	print("TERRAIN_GEN: saplings -- %d placed: %d pine + %d deciduous (%s) from %d candidate spots; rolled %d, rejected slope %d / road %d / rock %d / deadfall %d / trunk %d / spacing %d; %d ms" % [
		counts.pine + counts.decid, counts.pine, counts.decid, ", ".join(per_id), counts.candidates, counts.rolled,
		counts.rej_slope, counts.rej_road, counts.rej_rock, counts.rej_deadfall, counts.rej_trunk, counts.rej_spacing, Time.get_ticks_msec() - t0])

## Canopy trees bucketed in TREE_CELL cells: Vector2i -> Array[int] (indices into TreeScatter.tree_points).
static func _build_tree_grid() -> Dictionary:
	var grid := {}
	for i in TreeScatter.tree_points.size():
		var tp := TreeScatter.tree_points[i]
		var c := Vector2i(floori(tp.x / TREE_CELL), floori(tp.y / TREE_CELL))
		if not grid.has(c):
			grid[c] = []
		grid[c].append(i)
	return grid

## Nearest canopy tree within PARENT_RADIUS -> {found, pine, too_close}. too_close = inside some
## trunk's clear ring (TRUNK_CLEAR_RADIUS x that tree's scale).
static func _nearest_tree(grid: Dictionary, px: float, pz: float) -> Dictionary:
	var reach := int(ceil(PARENT_RADIUS / TREE_CELL))
	var c := Vector2i(floori(px / TREE_CELL), floori(pz / TREE_CELL))
	var best_d2 := PARENT_RADIUS * PARENT_RADIUS
	var best := -1
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			for i: int in grid.get(Vector2i(c.x + dx, c.y + dz), []):
				var tp := TreeScatter.tree_points[i]
				var d2 := (px - tp.x) * (px - tp.x) + (pz - tp.y) * (pz - tp.y)
				var clear := TRUNK_CLEAR_RADIUS * tp.z
				if d2 < clear * clear:
					return {"found": true, "pine": false, "too_close": true}
				if d2 < best_d2:
					best_d2 = d2
					best = i
	if best < 0:
		return {"found": false, "pine": false, "too_close": false}
	return {"found": true, "pine": TreeScatter.TREE_IDS_PINE.has(TreeScatter.tree_mesh_ids[best]), "too_close": false}

static func _too_close(grid: Dictionary, px: float, pz: float) -> bool:
	var c := Vector2i(floori(px / MIN_SPACING), floori(pz / MIN_SPACING))
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for p: Vector2 in grid.get(Vector2i(c.x + dx, c.y + dz), []):
				if (px - p.x) * (px - p.x) + (pz - p.y) * (pz - p.y) < MIN_SPACING * MIN_SPACING:
					return true
	return false

static func _add_stem(world_pos: Vector3) -> void:
	var c := Vector2i(floori(world_pos.x / STEM_CELL), floori(world_pos.z / STEM_CELL))
	if not _stem_grid.has(c):
		_stem_grid[c] = []
	_stem_grid[c].append(Vector2(world_pos.x, world_pos.z))

## The player's velocity, bent around any sapling stem within PUSH_RADIUS. Only the part of the
## horizontal velocity heading TOWARD a stem is turned sideways (to the side the player is already
## passing on), and the speed is kept -- so the player brushes past instead of stopping. Moving
## away from a stem, or standing still, changes nothing. Vertical velocity is untouched.
static func steer_around_stems(world_pos: Vector3, velocity: Vector3) -> Vector3:
	if not push_enabled or _stem_grid.is_empty():
		return velocity
	var v := Vector2(velocity.x, velocity.z)
	var speed := v.length()
	if speed < 0.01:
		return velocity
	var p := Vector2(world_pos.x, world_pos.z)
	var c := Vector2i(floori(p.x / STEM_CELL), floori(p.y / STEM_CELL))
	var bent := false
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for stem: Vector2 in _stem_grid.get(Vector2i(c.x + dx, c.y + dz), []):
				var to_stem := stem - p
				var dist := to_stem.length()
				if dist >= PUSH_RADIUS or dist < 0.0001:
					continue
				var dir := to_stem / dist
				var toward := v.dot(dir)
				if toward <= 0.0:
					continue # already moving away
				var side := Vector2(-dir.y, dir.x)
				if v.dot(side) < 0.0:
					side = -side # dead-on (dot = 0) keeps the first side, so the choice never flickers
				var turn := PUSH_STRENGTH * smoothstep(0.0, 1.0, 1.0 - dist / PUSH_RADIUS) * toward
				v += (side - dir) * turn
				bent = true
	if not bent:
		return velocity
	var new_speed := v.length()
	if new_speed > 0.0001:
		v *= speed / new_speed
	return Vector3(v.x, velocity.y, v.y)

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	last_counts = {}
	_stem_grid = {}
	push_enabled = true
