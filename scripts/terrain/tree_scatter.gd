## Tree scattering (stands + lone trees) and the debug tree-placement probe (PerfDebug key T).
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TreeScatter.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TreeScatter
extends RefCounted

## Scatters Boulder01 instances along the low side of each cliff feature's
## foot, using the exact fault-line data _add_cliff_features computed for
## carving the heightmap -- so boulders end up exactly where the cliff
## actually is. Must run AFTER data.import_images() (regions need to exist
## before the instancer can attach transforms to them) and BEFORE
## data.save_directory() -- instancer data is part of each region's own
## saved resource, same as the height/control/color maps.
## -- Canopy (tree) layer scattering (2026-09-21) --
## The first vegetation layer: full conifer trees (fir + pine, 3 variants each,
## Terrain3DMeshAsset ids 14-19 -- see setup_tree_assets.gd) scattered on the
## valley FLOOR + gentle slopes in irregular clumped stands, NOT along cliff
## feet like the boulder/scree talus. Placement template is the glacial-erratic
## floor loop in _scatter_boulders (floor zone via _zone_pixel_range + reach
## clamp), NOT the talus loop. Trees stay UPRIGHT (random yaw + a few degrees of
## lean only -- never normal-aligned like rocks), cluster around a handful of
## stand centres with gaussian falloff (a few lone outliers between stands),
## reuse the same road_weight / slope-normal / cliff-outcrop keep-out rejects,
## and leave deliberate clearings so the route stays legible. Unlike scree,
## trees DO get collision -- a simple upright trunk cylinder on EVERY tree (not the
## full mesh hull). Road-range gating was removed because off-road trees the player
## walked up to had no collision; Jolt handles a few hundred cylinders trivially.
## Tree set (Terrain3D mesh asset ids -- see setup_tree_assets.gd PACK_TREES).
## 2026-09-24: the old Poly Haven fir/pine assets (were 14-19) were removed and the
## Fab pack trees renumbered from 20-33 to 14-27. Keep in sync with PACK_TREES.
const TREE_IDS_FAB_PACK: Array[int] = [14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]  ## Fab vegetation pack (Kirill's cleaned selection): 8 pines + 6 deciduous (1.9-11.3k tris)
const TREE_MESH_IDS: Array[int] = TREE_IDS_FAB_PACK
const TREE_REACH := 4.0 ## canopy footprint radius (~6-7 m wide trees) kept off the map edge, same role as ERRATIC_REACH
## Stand counts calibrated at 256x256 and scaled by real map area (like ERRATIC/OUTCROP) so stand density stays constant as AREA_* change.
const TREE_DENSITY_BASE_AREA := 256.0 * 256.0
const TREE_STAND_COUNT_MIN_BASE := 17
const TREE_STAND_COUNT_MAX_BASE := 26
const TREE_PER_STAND_MIN := 12
const TREE_PER_STAND_MAX := 32
const TREE_STAND_SPREAD := 18.0 ## std-dev (world units) of trees scattered around a stand centre
const TREE_LONE_COUNT_MIN_BASE := 12 ## a few lone outliers between stands, per base area
const TREE_LONE_COUNT_MAX_BASE := 24
const TREE_MAX_SLOPE_NORMAL_Y := 0.80 ## trees only on floor + gentle slopes -- flatter requirement than scree (0.62); steeper than this = no tree
const TREE_MAX_PLACEMENT_ATTEMPTS := 6
const TREE_SCALE_MIN := 0.85
const TREE_SCALE_MAX := 1.25
const TREE_EMBED_DEPTH := 0.20 ## sink the base slightly so the trunk root meets the ground rather than floating on uneven terrain
const TREE_LEAN_MAX_DEG := 4.0 ## max random lean off vertical -- a touch of wind-bent character, never a full ground-align
const TREE_KEEPOUT_RADIUS := 1.2 ## trunk footprint radius for cliff-mesh / outcrop keep-outs (so trunks never spawn inside rock)
const TREE_STAND_LOWGROUND_SAMPLES := 1 ## pick each stand centre as the lowest of this many floor candidates -- a cheap "wetter, lower ground" density bias with no moisture map
## Where trees may go, as fractions of the map (clump centres, lone trees and each tree's
## jitter are all clamped to this). 2026-09-24: trees used to reuse the valley "floor"
## zone (x 22.5%-77.5%) + a hard-coded z 10%-90%, which left flat, walkable wall-zone
## terraces permanently bare. Now a wide band; TREE_MAX_SLOPE_NORMAL_Y is what keeps
## trunks off genuinely steep wall faces. Counts scale with the WHOLE map area, so a wider
## band spreads the same trees thinner -- raise TREE_STAND_COUNT_* to compensate.
const TREE_X_BAND_MIN := 0.03
const TREE_X_BAND_MAX := 0.97
const TREE_Z_BAND_MIN := 0.02
const TREE_Z_BAND_MAX := 0.98
## Clump-centre spacing (2026-09-24): each stand centre is the best of this many random
## candidates, keeping the one farthest from the stands already placed. 1 = pure random
## (clumps bunch up and leave big voids), ~6 = evenly spread but still irregular,
## 15+ = close to a regular pattern. Costs nothing at runtime, same tree count.
const TREE_STAND_SPACING_CANDIDATES := 6
## Colliders: every tree gets a StaticBody trunk cylinder (see _place_one_tree), sized by the constants below.
const TREE_COLLIDER_CONTAINER_NAME := "TreeColliders"
const TREE_TRUNK_RADIUS := 0.28 ## base trunk collider radius at scale 1.0 (scaled per instance)
const TREE_TRUNK_HEIGHT := 6.0 ## upright cylinder height at scale 1.0 -- the player-blocking lower trunk, not the whole tree
## DEBUG (2026-09-24, "why no trees here" probe): the data _scatter_trees used, kept so
## debug_tree_probe() can re-run the exact placement checks at any spot (PerfDebug key T).
## ~1 MB (height + road maps). Remove with debug_tree_probe once no longer needed.
static var _tree_debug: Dictionary = {}

## Canopy tree scatter -- see the TREE_* const block for the design. Floor-based
## clumped stands, upright, gameplay-range trunk colliders. Same timing contract
## as _scatter_boulders/_scatter_scree: after import_images(), before anything
## reads the finished Terrain3D.
static func scatter_trees(parent_node: Node, terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, road_path: PackedVector2Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	# Only scatter tree ids actually registered as mesh assets -- lets the canopy
	# work with however many variants are imported so far (e.g. fir only, before
	# pine is exported) instead of erroring on a missing id.
	var assets: Terrain3DAssets = terrain.get_assets()
	var active_ids: Array[int] = []
	for id in TREE_MESH_IDS:
		if assets and assets.get_mesh_asset(id) != null:
			active_ids.append(id)
	# Clear this run's tree instances before re-scattering.
	for id in TREE_IDS_FAB_PACK:
		instancer.clear_by_mesh(id)
	if active_ids.is_empty():
		print("TERRAIN_GEN: no tree mesh assets registered (ids %s) -- skipping canopy scatter" % str(TREE_MESH_IDS))
		return

	# Runtime trunk-collider container -- same off-tree deferred-attach pattern as
	# the boulder colliders (avoids "parent busy setting up children").
	var parent := parent_node
	var old_container := parent.get_node_or_null(TREE_COLLIDER_CONTAINER_NAME)
	if old_container:
		old_container.queue_free()
	var collider_container := Node3D.new()
	collider_container.name = TREE_COLLIDER_CONTAINER_NAME
	parent.add_child.call_deferred(collider_container)

	# Keep-outs: identical construction to _scatter_boulders / _scatter_scree.
	var keep_rects: Array[Dictionary] = []
	var cliff_defs_by_name: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		cliff_defs_by_name[def.name] = def
	for entry in cliff_plan:
		var cdef = cliff_defs_by_name.get(entry.def_name)
		if cdef == null:
			continue
		var prof: Dictionary = cliff_top_profiles.get(entry.def_name, {})
		var sj: float = entry.scale_jitter
		var fa: float = entry.face_angle
		keep_rects.append({
			"c": Vector2(entry.px, entry.pz),
			"ax": Vector2(cos(fa), -sin(fa)),
			"az": Vector2(sin(fa), cos(fa)),
			"x0": float(prof.get("x_min", -cdef.real_size * 0.5)) * sj,
			"x1": float(prof.get("x_max", cdef.real_size * 0.5)) * sj,
			"z0": float(prof.get("z_min", -cdef.depth * 0.5)) * sj,
			"z1": float(prof.get("z_max", cdef.depth * 0.5)) * sj,
		})
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	# Boulders/erratics placed earlier this run (see _rock_keep_circles) -- no trunks through rocks.
	keep_circles.append_array(RockScatter.rock_keep_circles)

	# Tree band (see TREE_X_BAND_* / TREE_Z_BAND_*), pulled in by TREE_REACH at the map edges.
	var floor_x := TerrainUtil.clamp_range_for_reach(float(width) * TREE_X_BAND_MIN, float(width) * TREE_X_BAND_MAX, TREE_REACH, float(width - 1))
	var floor_z := TerrainUtil.clamp_range_for_reach(float(length) * TREE_Z_BAND_MIN, float(length) * TREE_Z_BAND_MAX, TREE_REACH, float(length - 1))
	var fx_lo := minf(floor_x.x, floor_x.y)
	var fx_hi := maxf(floor_x.x, floor_x.y)
	var fz_lo := minf(floor_z.x, floor_z.y)
	var fz_hi := maxf(floor_z.x, floor_z.y)

	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for id in active_ids:
		transforms_by_mesh[id] = [] as Array[Transform3D]
		colors_by_mesh[id] = PackedColorArray()

	var area_scale := (float(width) * float(length)) / TREE_DENSITY_BASE_AREA
	var stand_count := maxi(1, int(round(rng.randf_range(TREE_STAND_COUNT_MIN_BASE, TREE_STAND_COUNT_MAX_BASE) * area_scale)))
	var lone_count := maxi(0, int(round(rng.randf_range(TREE_LONE_COUNT_MIN_BASE, TREE_LONE_COUNT_MAX_BASE) * area_scale)))
	var tree_total := 0

	# Stand centres: each is the best of TREE_STAND_SPACING_CANDIDATES candidates -- the one
	# farthest from the stands already placed (evens out coverage, fewer big random voids).
	# Each candidate itself is still the lowest of TREE_STAND_LOWGROUND_SAMPLES points.
	# SPACING_CANDIDATES = 1 reproduces the old pure-random layout exactly (same rng draws).
	var stand_centres: Array[Vector2] = []
	for s in stand_count:
		var pick := Vector2.ZERO
		var pick_gap := -1.0
		for c in maxi(TREE_STAND_SPACING_CANDIDATES, 1):
			var best := Vector2(rng.randf_range(fx_lo, fx_hi), rng.randf_range(fz_lo, fz_hi))
			var best_h := TerrainUtil.sample_height_bilinear(heights, width, length, best.x, best.y)
			for extra in (TREE_STAND_LOWGROUND_SAMPLES - 1):
				var cand := Vector2(rng.randf_range(fx_lo, fx_hi), rng.randf_range(fz_lo, fz_hi))
				var ch := TerrainUtil.sample_height_bilinear(heights, width, length, cand.x, cand.y)
				if ch < best_h:
					best = cand
					best_h = ch
			# distance to the nearest stand placed so far (first stand: any candidate is fine)
			var gap := INF
			for sc in stand_centres:
				gap = minf(gap, best.distance_to(sc))
			if gap > pick_gap:
				pick = best
				pick_gap = gap
		stand_centres.append(pick)

	# DEBUG: keep what the placement checks use, for debug_tree_probe() (PerfDebug key T).
	_tree_debug = {
		"heights": heights, "width": width, "length": length, "import_position": import_position,
		"road_weight": road_weight, "keep_rects": keep_rects, "keep_circles": keep_circles,
		"fx_lo": fx_lo, "fx_hi": fx_hi, "fz_lo": fz_lo, "fz_hi": fz_hi,
		"stand_centres": stand_centres, "lone_count": lone_count,
	}

	for centre in stand_centres:
		var per := rng.randi_range(TREE_PER_STAND_MIN, TREE_PER_STAND_MAX)
		for i in per:
			var target := Vector2(rng.randfn(centre.x, TREE_STAND_SPREAD), rng.randfn(centre.y, TREE_STAND_SPREAD))
			if _place_one_tree(target, heights, width, length, import_position, rng, road_weight, keep_rects, keep_circles, fx_lo, fx_hi, fz_lo, fz_hi, active_ids, transforms_by_mesh, colors_by_mesh, road_path, collider_container):
				tree_total += 1

	for i in lone_count:
		var target := Vector2(rng.randf_range(fx_lo, fx_hi), rng.randf_range(fz_lo, fz_hi))
		if _place_one_tree(target, heights, width, length, import_position, rng, road_weight, keep_rects, keep_circles, fx_lo, fx_hi, fz_lo, fz_hi, active_ids, transforms_by_mesh, colors_by_mesh, road_path, collider_container):
			tree_total += 1

	for id in active_ids:
		if not transforms_by_mesh[id].is_empty():
			instancer.add_transforms(id, transforms_by_mesh[id], colors_by_mesh[id], true)

	print("TERRAIN_GEN: scattered %d tree(s) across %d stand(s) + %d lone (%d with trunk colliders, %d variant id(s) active)" % [tree_total, stand_count, lone_count, collider_container.get_child_count(), active_ids.size()])

## Places one upright tree at (or near) `target` pixel spot: retries a few times
## on steep / on-road / keep-out-blocked ground, and on success appends an
## upright (yaw + tiny lean, never normal-aligned) transform to the per-mesh
## batch and builds a StaticBody trunk cylinder (every tree). Returns true if a
## tree was placed. (Mutates transforms_by_mesh / colors_by_mesh /
## collider_container by reference.) `road_path` is currently unused -- kept
## in the signature from the removed road-range collider gate.
static func _place_one_tree(target: Vector2, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, keep_rects: Array[Dictionary], keep_circles: Array[Vector3], fx_lo: float, fx_hi: float, fz_lo: float, fz_hi: float, active_ids: Array[int], transforms_by_mesh: Dictionary, colors_by_mesh: Dictionary, road_path: PackedVector2Array, collider_container: Node3D) -> bool:
	var scale := rng.randf_range(TREE_SCALE_MIN, TREE_SCALE_MAX)
	var px := 0.0
	var pz := 0.0
	var height := 0.0
	var normal := Vector3.UP
	var found := false
	for attempt in TREE_MAX_PLACEMENT_ATTEMPTS:
		var jx := 0.0 if attempt == 0 else rng.randf_range(-TREE_STAND_SPREAD, TREE_STAND_SPREAD)
		var jz := 0.0 if attempt == 0 else rng.randf_range(-TREE_STAND_SPREAD, TREE_STAND_SPREAD)
		px = clampf(target.x + jx, fx_lo, fx_hi)
		pz = clampf(target.y + jz, fz_lo, fz_hi)
		height = TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
		normal = TerrainUtil.sample_normal(heights, width, length, px, pz)
		var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
		var on_road := road_weight[sample_idx] > 0.0
		if normal.y >= TREE_MAX_SLOPE_NORMAL_Y and not on_road:
			if not RockScatter.boulder_blocked(px, pz, TREE_KEEPOUT_RADIUS * scale, keep_rects, keep_circles):
				found = true
				break
	if not found:
		return false

	var tree_pos := Vector3(import_position.x + px, height - TREE_EMBED_DEPTH, import_position.z + pz)
	# Upright: random yaw + a tiny lean, never normal-aligned.
	var yaw := rng.randf() * TAU
	var basis := Basis(Vector3.UP, yaw)
	var lean := deg_to_rad(rng.randf_range(0.0, TREE_LEAN_MAX_DEG))
	if lean > 0.0001:
		var la := rng.randf() * TAU
		var lean_axis := Vector3(cos(la), 0.0, sin(la))
		basis = Basis(lean_axis, lean) * basis
	var mesh_id: int = active_ids[rng.randi() % active_ids.size()]
	var tree_basis := basis.scaled(Vector3.ONE * scale)
	transforms_by_mesh[mesh_id].append(Transform3D(tree_basis, tree_pos))
	colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))

	# Every tree gets a trunk collider -- a StaticBody + upright cylinder is
	# cheap (Jolt handles a few hundred trivially), and gating by road distance
	# left trees the player walks up to off-road with no collision. Collide all.
	var body := StaticBody3D.new()
	body.name = "Tree%d" % collider_container.get_child_count()
	collider_container.add_child(body)
	body.transform = Transform3D(Basis(), tree_pos) # upright, unscaled
	var cyl := CylinderShape3D.new()
	cyl.radius = TREE_TRUNK_RADIUS * scale
	cyl.height = TREE_TRUNK_HEIGHT * scale
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = cyl
	col.position = Vector3(0.0, cyl.height * 0.5, 0.0)
	body.add_child(col)
	return true

## DEBUG (2026-09-24): re-runs _place_one_tree's checks at a world position and says
## which pass/fail, plus where the nearest stand centres are. Called by PerfDebug key T.
static func debug_tree_probe(world_pos: Vector3) -> String:
	if _tree_debug.is_empty():
		return "[TreeProbe] no tree scatter data (did _scatter_trees run this session?)"
	var d := _tree_debug
	var heights: PackedFloat32Array = d.heights
	var width: int = d.width
	var length: int = d.length
	var imp: Vector3 = d.import_position
	var road_weight: PackedFloat32Array = d.road_weight
	var keep_rects: Array[Dictionary] = d.keep_rects
	var keep_circles: Array[Vector3] = d.keep_circles
	var px := world_pos.x - imp.x
	var pz := world_pos.z - imp.z
	var lines: Array[String] = []
	lines.append("[TreeProbe] world (%.1f, %.1f) -> pixel (%.1f, %.1f)" % [world_pos.x, world_pos.z, px, pz])
	var fails: Array[String] = []

	var in_x: bool = px >= d.fx_lo and px <= d.fx_hi
	var in_z: bool = pz >= d.fz_lo and pz <= d.fz_hi
	lines.append("  zone x (TREE_X_BAND %.0f%%-%.0f%%) %.1f..%.1f: %s" % [TREE_X_BAND_MIN * 100.0, TREE_X_BAND_MAX * 100.0, d.fx_lo, d.fx_hi, "PASS" if in_x else "FAIL -- outside the tree band (x)"])
	lines.append("  zone z (TREE_Z_BAND %.0f%%-%.0f%%) %.1f..%.1f: %s" % [TREE_Z_BAND_MIN * 100.0, TREE_Z_BAND_MAX * 100.0, d.fz_lo, d.fz_hi, "PASS" if in_z else "FAIL -- outside the tree band (z)"])
	if not in_x: fails.append("zone x")
	if not in_z: fails.append("zone z")

	var cpx := clampf(px, 0.0, float(width - 1))
	var cpz := clampf(pz, 0.0, float(length - 1))
	var h := TerrainUtil.sample_height_bilinear(heights, width, length, cpx, cpz)
	var n := TerrainUtil.sample_normal(heights, width, length, cpx, cpz)
	var slope_ok := n.y >= TREE_MAX_SLOPE_NORMAL_Y
	lines.append("  slope: normal.y %.3f (%.1f deg), need >= %.2f (%.1f deg max): %s" % [n.y, rad_to_deg(acos(clampf(n.y, -1.0, 1.0))), TREE_MAX_SLOPE_NORMAL_Y, rad_to_deg(acos(TREE_MAX_SLOPE_NORMAL_Y)), "PASS" if slope_ok else "FAIL -- too steep"])
	if not slope_ok: fails.append("slope")

	var idx := clampi(int(round(cpz)), 0, length - 1) * width + clampi(int(round(cpx)), 0, width - 1)
	var on_road := road_weight[idx] > 0.0
	lines.append("  road: weight %.2f: %s" % [road_weight[idx], "FAIL -- on the road" if on_road else "PASS"])
	if on_road: fails.append("road")

	var blocked := RockScatter.boulder_blocked(cpx, cpz, TREE_KEEPOUT_RADIUS, keep_rects, keep_circles)
	lines.append("  rock keep-outs (cliffs / outcrops / boulders, scale 1.0): %s" % ["FAIL -- inside a keep-out" if blocked else "PASS"])
	if blocked: fails.append("keep-out")

	var centres: Array[Vector2] = d.stand_centres
	var nearest := INF
	var close := 0
	for c in centres:
		var dist := Vector2(px, pz).distance_to(c)
		nearest = minf(nearest, dist)
		if dist <= TREE_STAND_SPREAD * 2.0:
			close += 1
	lines.append("  stands: %d total, nearest centre %.1f m away, %d within %.0f m (2x spread); %d lone trees map-wide; ground height here %.1f" % [centres.size(), nearest, close, TREE_STAND_SPREAD * 2.0, d.lone_count, h])

	if fails.is_empty():
		if close == 0:
			lines.append("  VERDICT: a tree COULD grow here, but no stand was aimed nearby -- empty by chance (only lone trees could land here)")
		else:
			lines.append("  VERDICT: a tree could grow here and a stand is nearby -- nearby trees likely failed their own spot checks")
	else:
		lines.append("  VERDICT: no tree can grow at this exact spot -- failing: %s" % ", ".join(fails))
	return "\n".join(lines)

## Restores this module's static state (caches, debug buffers, counters) to its initial
## values. Called at the start of every WorldGenerator run so each run starts clean, the
## same as when these were per-instance member variables on WorldGenerator.
static func reset_run_state() -> void:
	_tree_debug = {}
