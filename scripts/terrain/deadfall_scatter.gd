## Deadfall scattering -- stumps, fallen logs and branch clumps (2026-09-30).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## DeadfallScatter.scatter_deadfall(...). Must run AFTER RockScatter.scatter_boulders
## (rock_keep_circles) and TreeScatter.scatter_trees (tree_points), and BEFORE
## UnderstoryScatter / GrassScatter, which keep clear of deadfall_keep_circles.
##
## Design (terrain field notes): debris collects in the LEE / UPHILL side of obstacles, so the
## layer ties the rocks and the forest together:
##   rock-banked  -- some of the larger boulders/erratics get a log or a branch clump lying against
##                   their uphill side, along the contour (what rolled/slid down stopped there);
##   in stands    -- candidates on a jittered grid, probability from the same canopy-cover field
##                   the understory uses; logs/branches there are often banked against the uphill
##                   side of a nearby trunk, stumps stand free. A sparse few in the open.
## Every piece is a capsule footprint along its local X (the glbs are exported with the long axis
## on X). Logs follow the ground: both ends are sampled and the log is tilted along that line,
## rejected where the ground bulges through it or drops away under it.
## Rendering: Terrain3D instancer, mesh ids 38-49 (tools/setup_ground_debris_assets.gd).
## Collision: stumps = simplified convex hull, logs = trimesh (not convex -- the large log's root
## plate would turn a hull into a wedge), both built once per mesh id from the glb's LOD2 and
## shared by every instance; branches and sticks none.
class_name DeadfallScatter
extends RefCounted

## Terrain3D mesh asset ids -- keep in sync with DEBRIS in tools/setup_ground_debris_assets.gd.
const STUMP_BROKEN_ID := 38 ## snapped snag on its roots, 0.88 m tall, 0.38 x 0.95 m base (scan was lying on its side -- stood up at import)
const STUMP_OLD_ID := 39 ## 1.33 x 0.87 x 0.52 m, low, wide, roots
const STUMP_ROTTEN_LARGE_ID := 40 ## 2.36 x 1.03 x 1.69 m
const STUMP_ROTTEN_TALL_ID := 41 ## 1.09 x 0.86 x 1.62 m
const LOG_NORDIC_ID := 42 ## 5.69 m long, 0.9 m thick
const LOG_LARGE_ID := 43 ## 7.10 m long, 1.5 m wide, root plate up to 2.4 m
const BRANCH_ID := 44 ## 1.05 m fallen branch, no collision
## Sticks (0.6-0.9 m, small Megascans twigs scaled up at import), no collision -- they fill out the
## branch clumps so a clump isn't copies of one branch (read as a ribcage, 2026-09-30).
const STICK_ARBEM_ID := 45 ## 0.84 m
const STICK_DEBRIS_A_ID := 46 ## 0.88 m
const STICK_DEBRIS_B_ID := 47 ## 0.70 m
const STICK_DEBRIS_C_ID := 48 ## 0.61 m, thin
const STICK_DEBRIS_D_ID := 49 ## 0.60 m
const DEADFALL_MESH_IDS: Array[int] = [STUMP_BROKEN_ID, STUMP_OLD_ID, STUMP_ROTTEN_LARGE_ID, STUMP_ROTTEN_TALL_ID, LOG_NORDIC_ID, LOG_LARGE_ID, BRANCH_ID, STICK_ARBEM_ID, STICK_DEBRIS_A_ID, STICK_DEBRIS_B_ID, STICK_DEBRIS_C_ID, STICK_DEBRIS_D_ID]
const SCENE_DIR := "res://assets/models/ground_debris/"

## Per piece: glb dir, kind, footprint capsule along local X at scale 1 (hl = half-length of the
## axis segment, r = radius), scale range. Footprints are from each LOD0's AABB.
const PIECES := {
	STUMP_BROKEN_ID: {"dir": "stump_broken", "kind": "stump", "hl": 0.0, "r": 0.5, "s": [1.3, 1.7], "embed": 0.15}, # embed: own sink depth (m, x scale) in place of EMBED.stump; x1.5: at scale 1 its 0.38 m trunk is thinner than the live trees' (0.56 m)
	STUMP_OLD_ID: {"dir": "stump_old", "kind": "stump", "hl": 0.25, "r": 0.45, "s": [0.85, 1.2]},
	STUMP_ROTTEN_LARGE_ID: {"dir": "stump_rotten_large", "kind": "stump", "hl": 0.65, "r": 0.55, "s": [0.8, 1.1], "lying": true}, # toppled: 2.4 m long, one splinter up at 45 deg
	STUMP_ROTTEN_TALL_ID: {"dir": "stump_rotten_tall", "kind": "stump", "hl": 0.1, "r": 0.45, "s": [0.8, 1.15]},
	# The nordic log is a stump (x 1.9..2.85, base at y 0) with the fallen trunk still attached and
	# held 0.22-0.46 m clear of the scan's ground plane: laid flat, the whole trunk floats.
	# pivot_x / rest: see the hinged branch in _try_place. rest = trunk underside from LOD0.
	LOG_NORDIC_ID: {"dir": "log_fallen_nordic", "kind": "log", "hl": 2.4, "r": 0.45, "s": [0.75, 1.1], "pivot_x": 2.4,
		"rest": [[-2.6, 0.34], [-2.1, 0.30], [-1.65, 0.26], [-1.2, 0.23], [-0.7, 0.22], [-0.25, 0.36], [0.25, 0.38], [0.7, 0.40], [1.2, 0.44]]},
	LOG_LARGE_ID: {"dir": "log_fallen_large", "kind": "log", "hl": 2.8, "r": 0.75, "s": [0.7, 1.0]},
	BRANCH_ID: {"dir": "branch_fallen", "kind": "branch", "hl": 0.45, "r": 0.12, "s": [0.8, 1.35]},
	STICK_ARBEM_ID: {"dir": "stick_arbem", "kind": "stick", "hl": 0.35, "r": 0.07, "s": [0.8, 1.3]},
	STICK_DEBRIS_A_ID: {"dir": "sticks_debris", "file": "sticks_debris_a", "kind": "stick", "hl": 0.39, "r": 0.05, "s": [0.8, 1.3]},
	STICK_DEBRIS_B_ID: {"dir": "sticks_debris", "file": "sticks_debris_b", "kind": "stick", "hl": 0.3, "r": 0.06, "s": [0.8, 1.3]},
	STICK_DEBRIS_C_ID: {"dir": "sticks_debris", "file": "sticks_debris_c", "kind": "stick", "hl": 0.28, "r": 0.04, "s": [0.8, 1.3]},
	STICK_DEBRIS_D_ID: {"dir": "sticks_debris", "file": "sticks_debris_d", "kind": "stick", "hl": 0.26, "r": 0.05, "s": [0.8, 1.3]},
}
## Weighted picks: [id, weight].
const STUMP_MIX := [[STUMP_BROKEN_ID, 0.3], [STUMP_OLD_ID, 0.3], [STUMP_ROTTEN_LARGE_ID, 0.15], [STUMP_ROTTEN_TALL_ID, 0.25]]
const LOG_MIX := [[LOG_NORDIC_ID, 0.6], [LOG_LARGE_ID, 0.4]]
## Kinds with no collision and no keep-out for the understory/grass; they pack tightly (SMALL_GAP).
const SMALL_KINDS: Array[String] = ["branch", "stick"]
const STICK_MIX :=[[STICK_ARBEM_ID, 0.28], [STICK_DEBRIS_A_ID, 0.2], [STICK_DEBRIS_B_ID, 0.2], [STICK_DEBRIS_C_ID, 0.16], [STICK_DEBRIS_D_ID, 0.16]]

## -- Litter mounds (2026-10-01): low domes of needle litter around trunk bases and against stumps /
## logs. Rim below ground, no collision, no shadows, no keep-out; overlaps allowed. They use the
## PineLitter terrain texture, so they read as the ground swelling up. Placed by _scatter_mounds --
## NOT through _try_place (its linear scan of ctx.placed is too slow for this many pieces).
const MOUND_MESH_IDS: Array[int] = [50, 51, 52] ## LitterMoundA-C, radius 1.1 / 0.95 / 1.25 m at scale 1
const MOUND_TRUNK_P := 0.4 ## chance per tree
const MOUND_DEADFALL_P := 0.6 ## chance per stump / log
const MOUND_TRUNK_OFFSET := 0.35 ## m, max shift from the trunk centre toward uphill
const MOUND_SCALE_MIN := 0.8
const MOUND_SCALE_MAX := 1.25
const MOUND_MIN_NORMAL_Y := 0.9 ## flatter ground only (~25 deg): a rigid dome floats on one side on a slope

## -- Rock-banked debris --
const ROCK_BANK_MIN_RADIUS := 1.0 ## m, only rocks with a keep-out radius at least this big (~scale 1.1+)
const ROCK_BANK_P := 0.35 ## chance such a rock gets debris on its uphill side
const ROCK_BANK_LOG_SHARE := 0.55 ## of those: a log, else a branch clump

## -- Stand debris --
const STAND_STEP := 7.0 ## m, jittered candidate grid (at most one piece or clump per cell)
const STAND_MAX_P := 0.28 ## chance per candidate under full canopy
const STAND_CANOPY_LO := 0.2 ## canopy cover below this -> only OPEN_P
const STAND_CANOPY_HI := 0.75 ## above this -> full STAND_MAX_P
const OPEN_P := 0.006 ## chance per candidate in the open (the odd lone stump or log)
const STAND_STUMP_SHARE := 0.4 ## kind mix in stands: stump, else log, else branch clump
const STAND_LOG_SHARE := 0.3
const TRUNK_BANK_RADIUS := 4.0 ## m: a log/clump with a trunk this close may bank against it
const TRUNK_BANK_P := 0.6 ## chance it does (else it lies where it was rolled, any direction)

## -- Branch clumps: at most ONE big branch + a few mixed sticks (repeated copies of the big branch
## side by side read as a ribcage, 2026-09-30) --
const CLUMP_BIG_BRANCH_P := 0.5 ## chance a clump has the big branch
const CLUMP_STICKS_MIN := 2
const CLUMP_STICKS_MAX := 5
const CLUMP_SPREAD := 1.0 ## m, max offset of a stick from the clump centre
const CLUMP_ANGLE_JITTER_DEG := 70.0 ## sticks loosely along the contour, at mixed angles
const CLUMP_PIECE_ATTEMPTS := 6 ## spots tried per clump piece before it is dropped
const SMALL_GAP := 0.02 ## m between the footprints of two branches/sticks (their meshes must not intersect)

## -- Placement --
const BANK_GAP := 0.05 ## m between an obstacle's footprint and the piece
const BANK_ANGLE_JITTER_DEG := 22.0 ## banked pieces lie along the contour +/- this
const BANK_SLIDE := 0.4 ## banked logs slide along their axis by up to this x half-length (not centred on the rock)
const FLAT_GRADIENT := 0.04 ## slope (rise/run) below which there is no "uphill" -> random side
const MAX_SLOPE_NORMAL_Y := {"stump": 0.88, "log": 0.8, "branch": 0.72, "stick": 0.72} ## stumps ~28 deg: steeper and the downhill side floats
const STUMP_SLOPE_SINK := 0.45 ## stumps sink by this x the drop across their footprint (the rest of the drop floats / buries)
const FIT_SINK_MAX := 0.12 ## m (+ 0.25 x radius): ground may rise into a lying piece by at most this
const FIT_FLOAT_MAX := 0.25 ## m: ground may drop away under a lying piece by at most this
const EMBED := {"stump": 0.05, "log": 0.06, "branch": 0.03, "stick": 0.01} ## m sunk into the ground (x scale)
const STUMP_NORMAL_FOLLOW := 0.25 ## stumps grow up, only tilt this much toward the ground normal
const LOG_ROLL_MAX_DEG := 10.0
const HINGE_MAX_SIN := 0.3 ## hinged pieces: max tilt of the log about its stump (sin; ~17 deg), steeper = rejected
const KEEPOUT_MARGIN := 0.15 ## m around rocks / cliffs / outcrops / trunks / other deadfall
const ROAD_MARGIN := 0.8 ## m kept between any piece and the road corridor
const KNOT_RAMP_CLEAR := 3.5 ## m from a knot fallback ramp's centre line (colliders could block it)
const TRUNK_RADIUS := 0.28 ## m at tree scale 1 -- TreeScatter.TREE_TRUNK_RADIUS
const EDGE_MARGIN := 2.0 ## px kept off the heightmap border
const MAX_ATTEMPTS := 4

const COLLIDER_CONTAINER_NAME := "DeadfallColliders"

## Footprints (px, pz, radius -- pixel space) of the stumps and logs placed this run, as circles
## along each capsule. GrassScatter stamps these; UnderstoryScatter asks keep_blocked() (bucketed --
## ~1.5k circles in a linear scan per fern candidate cost the understory ~3 s). Branches excluded
## (ferns/grass through a thin branch are fine).
static var deadfall_keep_circles: Array[Vector3] = []
static var _keep_grid: Dictionary = {} ## Vector2i(4 m cell) -> Array of circles overlapping it
static var last_counts: Dictionary = {}
const KEEP_GRID_CELL := 4.0

static func scatter_deadfall(parent_node: Node, terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary], knots: Array) -> void:
	var t0 := Time.get_ticks_msec()
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	var assets: Terrain3DAssets = terrain.get_assets()
	var active: Dictionary = {}
	for id in DEADFALL_MESH_IDS:
		instancer.clear_by_mesh(id)
		active[id] = assets != null and assets.get_mesh_asset(id) != null
	for id in MOUND_MESH_IDS:
		instancer.clear_by_mesh(id)
	deadfall_keep_circles.clear()
	_keep_grid.clear()
	if not active.values().has(true):
		print("TERRAIN_GEN: no deadfall mesh assets registered (ids %s) -- run setup_mesh_assets() in tools/setup_ground_debris_assets.gd" % str(DEADFALL_MESH_IDS))
		return

	var old_container := parent_node.get_node_or_null(COLLIDER_CONTAINER_NAME)
	if old_container:
		old_container.queue_free()
	var collider_container := Node3D.new()
	collider_container.name = COLLIDER_CONTAINER_NAME
	parent_node.add_child.call_deferred(collider_container) # parent is still busy in _ready()
	var shapes := _build_collision_shapes()

	var ctx := {
		"heights": heights, "width": width, "length": length, "road_weight": road_weight, "knots": knots,
		"import_position": Vector3(import_position.x, 0.0, import_position.z),
		"active": active, # mesh id -> registered in terrain_assets.tres
		"rects": UnderstoryScatter._build_keep_rects(cliff_plan, cliff_top_profiles),
		"circles": [] as Array[Vector3], # outcrops + rocks (index -> skip when banking on that rock)
		"trunk_grid": _build_trunk_grid(),
		"placed": [] as Array[Dictionary], # {a, b, r, kind} capsules placed so far (pixel space)
		"transforms": {}, "colors": {},
		"counts": {"rock_banked": 0, "trunk_banked": 0, "free": 0, "clumps": 0, "rej_slope": 0, "rej_road": 0, "rej_block": 0, "rej_fit": 0, "rej_edge": 0},
	}
	for oc in outcrop_plan:
		ctx.circles.append(Vector3(oc.px, oc.pz, oc.radius))
	var rock_index_offset: int = ctx.circles.size()
	ctx.circles.append_array(RockScatter.rock_keep_circles)
	for id in DEADFALL_MESH_IDS:
		ctx.transforms[id] = [] as Array[Transform3D]
		ctx.colors[id] = PackedColorArray()
		ctx.counts[id] = 0

	# 1. Debris banked against the uphill side of the larger rocks.
	for i in RockScatter.rock_keep_circles.size():
		var rc: Vector3 = RockScatter.rock_keep_circles[i]
		if rc.z < ROCK_BANK_MIN_RADIUS or rng.randf() >= ROCK_BANK_P:
			continue
		var skip := rock_index_offset + i
		if rng.randf() < ROCK_BANK_LOG_SHARE:
			var id := _pick(LOG_MIX, rng)
			if active[id]:
				for attempt in MAX_ATTEMPTS:
					var scale := _roll_scale(id, rng)
					var spot := _bank_spot(ctx, Vector2(rc.x, rc.y), rc.z, id, scale, rng)
					if _try_place(ctx, id, spot.p, spot.angle, scale, rng, skip):
						ctx.counts.rock_banked += 1
						break
		else:
			var scale := _roll_scale(BRANCH_ID, rng)
			var spot := _bank_spot(ctx, Vector2(rc.x, rc.y), rc.z, BRANCH_ID, scale, rng)
			if _place_clump(ctx, spot.p, spot.angle, rng, skip) > 0:
				ctx.counts.rock_banked += 1

	# 2. Stands: canopy-driven candidates on a jittered grid.
	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var steps_x := int((float(width - 1) - 2.0 * EDGE_MARGIN) / STAND_STEP)
	var steps_z := int((float(length - 1) - 2.0 * EDGE_MARGIN) / STAND_STEP)
	for iz in steps_z:
		for ix in steps_x:
			var p := Vector2(EDGE_MARGIN + (float(ix) + rng.randf()) * STAND_STEP, EDGE_MARGIN + (float(iz) + rng.randf()) * STAND_STEP)
			var c := UnderstoryScatter._grid_sample(canopy, gw, gl, p.x, p.y)
			var prob := OPEN_P + STAND_MAX_P * smoothstep(STAND_CANOPY_LO, STAND_CANOPY_HI, c)
			if rng.randf() >= prob:
				continue
			var roll := rng.randf()
			if roll < STAND_STUMP_SHARE:
				var id := _pick(STUMP_MIX, rng)
				if not active[id]:
					continue
				for attempt in MAX_ATTEMPTS:
					var q := p + Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * attempt
					if _try_place(ctx, id, q, rng.randf() * TAU, _roll_scale(id, rng), rng, -1):
						ctx.counts.free += 1
						break
				continue
			var is_log := roll < STAND_STUMP_SHARE + STAND_LOG_SHARE
			var id := _pick(LOG_MIX, rng) if is_log else BRANCH_ID # clump: BRANCH_ID only sizes the bank spot
			if is_log and not active[id]:
				continue
			var trunk := _nearest_trunk(ctx.trunk_grid, p, TRUNK_BANK_RADIUS)
			var banked := trunk.z > 0.0 and rng.randf() < TRUNK_BANK_P
			for attempt in MAX_ATTEMPTS:
				var scale := _roll_scale(id, rng)
				var spot := {"p": p + Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * attempt, "angle": rng.randf() * TAU}
				if banked:
					spot = _bank_spot(ctx, Vector2(trunk.x, trunk.y), TRUNK_RADIUS * trunk.z, id, scale, rng)
				var ok := false
				if is_log:
					ok = _try_place(ctx, id, spot.p, spot.angle, scale, rng, -1)
				else:
					ok = _place_clump(ctx, spot.p, spot.angle, rng, -1) > 0
				if ok:
					ctx.counts["trunk_banked" if banked else "free"] += 1
					break

	# 3. Litter mounds -- last, so the rolls above are unchanged by them.
	_scatter_mounds(ctx, instancer, assets, rng)

	# Emit: instances, colliders, keep-out circles.
	var collider_count := 0
	for id in DEADFALL_MESH_IDS:
		var xforms: Array[Transform3D] = ctx.transforms[id]
		if xforms.is_empty():
			continue
		instancer.add_transforms(id, xforms, ctx.colors[id], true)
		var shape: Shape3D = shapes.get(id)
		if shape == null:
			continue
		for xf in xforms:
			var body := StaticBody3D.new()
			body.name = "Deadfall%d" % collider_count
			collider_container.add_child(body)
			body.transform = xf
			var col := CollisionShape3D.new()
			col.name = "CollisionShape3D"
			col.shape = shape
			body.add_child(col)
			collider_count += 1
	for cap: Dictionary in ctx.placed:
		if SMALL_KINDS.has(cap.kind):
			continue
		var a: Vector2 = cap.a
		var b: Vector2 = cap.b
		var r: float = cap.r
		var n := maxi(1, int(ceil(a.distance_to(b) / maxf(r, 0.3))))
		for k in n + 1:
			var q := a.lerp(b, float(k) / float(n))
			deadfall_keep_circles.append(Vector3(q.x, q.y, r))
	for kc in deadfall_keep_circles:
		for gz in range(floori((kc.y - kc.z) / KEEP_GRID_CELL), floori((kc.y + kc.z) / KEEP_GRID_CELL) + 1):
			for gx in range(floori((kc.x - kc.z) / KEEP_GRID_CELL), floori((kc.x + kc.z) / KEEP_GRID_CELL) + 1):
				var cell := Vector2i(gx, gz)
				if not _keep_grid.has(cell):
					_keep_grid[cell] = []
				_keep_grid[cell].append(kc)

	var counts: Dictionary = ctx.counts
	_debug_transforms = ctx.transforms
	last_counts = counts
	print("TERRAIN_GEN: deadfall -- %d stump(s) (broken %d, old %d, rotten large %d, rotten tall %d), %d log(s) (nordic %d, large %d), %d big branch(es) + %d stick(s) in %d clump(s); %d rock-banked, %d trunk-banked, %d free; %d with collision; rejected slope %d / road %d / blocked %d / ground fit %d / edge %d; %d ms" % [
		counts[STUMP_BROKEN_ID] + counts[STUMP_OLD_ID] + counts[STUMP_ROTTEN_LARGE_ID] + counts[STUMP_ROTTEN_TALL_ID],
		counts[STUMP_BROKEN_ID], counts[STUMP_OLD_ID], counts[STUMP_ROTTEN_LARGE_ID], counts[STUMP_ROTTEN_TALL_ID],
		counts[LOG_NORDIC_ID] + counts[LOG_LARGE_ID], counts[LOG_NORDIC_ID], counts[LOG_LARGE_ID],
		counts[BRANCH_ID], counts[STICK_ARBEM_ID] + counts[STICK_DEBRIS_A_ID] + counts[STICK_DEBRIS_B_ID] + counts[STICK_DEBRIS_C_ID] + counts[STICK_DEBRIS_D_ID],
		counts.clumps, counts.rock_banked, counts.trunk_banked, counts.free, collider_count,
		counts.rej_slope, counts.rej_road, counts.rej_block, counts.rej_fit, counts.rej_edge, Time.get_ticks_msec() - t0])

## Litter mounds at trunk bases and on the uphill side of stumps / logs. Light checks only (edge,
## slope, road); a mound may overlap anything -- its rim is underground and it has no collision.
static func _scatter_mounds(ctx: Dictionary, instancer: Terrain3DInstancer, assets: Terrain3DAssets, rng: RandomNumberGenerator) -> void:
	var ids: Array[int] = []
	for id in MOUND_MESH_IDS:
		if assets != null and assets.get_mesh_asset(id) != null:
			ids.append(id)
	if ids.is_empty():
		print("TERRAIN_GEN: no litter mound mesh assets registered (ids %s) -- run setup_mesh_assets() in tools/setup_ground_debris_assets.gd" % str(MOUND_MESH_IDS))
		return
	var spots: Array[Vector2] = []
	for tp in TreeScatter.tree_points:
		if rng.randf() < MOUND_TRUNK_P:
			var c := Vector2(tp.x, tp.y)
			spots.append(c + _uphill(ctx, c) * rng.randf() * MOUND_TRUNK_OFFSET)
	var at_trunks := spots.size()
	for cap: Dictionary in ctx.placed:
		if SMALL_KINDS.has(cap.kind) or rng.randf() >= MOUND_DEADFALL_P:
			continue
		var q: Vector2 = (cap.a as Vector2).lerp(cap.b, rng.randf())
		spots.append(q + _uphill(ctx, q) * float(cap.r) * 0.8)
	var width: int = ctx.width
	var length: int = ctx.length
	var road_weight: PackedFloat32Array = ctx.road_weight
	var xforms := {}
	for id in ids:
		xforms[id] = [] as Array[Transform3D]
	var placed := 0
	for p in spots:
		if p.x < EDGE_MARGIN + 2.0 or p.y < EDGE_MARGIN + 2.0 or p.x > width - 3 - EDGE_MARGIN or p.y > length - 3 - EDGE_MARGIN:
			continue
		var normal := TerrainUtil.sample_normal(ctx.heights, width, length, p.x, p.y)
		if normal.y < MOUND_MIN_NORMAL_Y:
			continue
		if road_weight[clampi(int(round(p.y)), 0, length - 1) * width + clampi(int(round(p.x)), 0, width - 1)] > 0.0:
			continue
		var basis := Basis(Quaternion(Vector3.UP, normal)) * Basis(Vector3.UP, rng.randf() * TAU)
		var scale := rng.randf_range(MOUND_SCALE_MIN, MOUND_SCALE_MAX)
		var pos := Vector3(p.x, _h(ctx, p.x, p.y), p.y) + (ctx.import_position as Vector3)
		xforms[ids[rng.randi() % ids.size()]].append(Transform3D(basis.scaled(Vector3.ONE * scale), pos))
		placed += 1
	for id in ids:
		var list: Array[Transform3D] = xforms[id]
		if list.is_empty():
			continue
		var colors := PackedColorArray()
		colors.resize(list.size())
		colors.fill(Color.WHITE)
		instancer.add_transforms(id, list, colors, true)
	print("TERRAIN_GEN: litter mounds -- %d placed of %d spots (%d at trunks, %d at stumps/logs)" % [placed, spots.size(), at_trunks, spots.size() - at_trunks])

## True if a footprint of radius `pad` at (px, pz) overlaps a stump or log placed this run.
static func keep_blocked(px: float, pz: float, pad: float) -> bool:
	var p := Vector2(px, pz)
	for gz in range(floori((pz - pad) / KEEP_GRID_CELL), floori((pz + pad) / KEEP_GRID_CELL) + 1):
		for gx in range(floori((px - pad) / KEEP_GRID_CELL), floori((px + pad) / KEEP_GRID_CELL) + 1):
			for kc: Vector3 in _keep_grid.get(Vector2i(gx, gz), []):
				if p.distance_to(Vector2(kc.x, kc.y)) < kc.z + pad:
					return true
	return false

## Where a piece banked against an obstacle (centre `c`, footprint radius `obstacle_r`) goes: on the
## obstacle's uphill side, touching it, lying along the contour. Flat ground -> any side.
static func _bank_spot(ctx: Dictionary, c: Vector2, obstacle_r: float, id: int, scale: float, rng: RandomNumberGenerator) -> Dictionary:
	var uphill := _uphill(ctx, c)
	if uphill == Vector2.ZERO:
		var a := rng.randf() * TAU
		uphill = Vector2(cos(a), sin(a))
	var piece: Dictionary = PIECES[id]
	var r: float = float(piece.r) * scale
	var angle := uphill.angle() + PI * 0.5 + deg_to_rad(rng.randf_range(-BANK_ANGLE_JITTER_DEG, BANK_ANGLE_JITTER_DEG))
	if rng.randf() < 0.5:
		angle += PI # which end is where (root plate / broken end)
	var along := Vector2(cos(angle), sin(angle))
	var slide := rng.randf_range(-BANK_SLIDE, BANK_SLIDE) * float(piece.hl) * scale
	return {"p": c + uphill * (obstacle_r + r + BANK_GAP + KEEPOUT_MARGIN) + along * slide, "angle": angle}

## Unit vector pointing uphill at `c` (pixel space), or ZERO on flat ground.
static func _uphill(ctx: Dictionary, c: Vector2) -> Vector2:
	var d := 1.5
	var g := Vector2(
		_h(ctx, c.x + d, c.y) - _h(ctx, c.x - d, c.y),
		_h(ctx, c.x, c.y + d) - _h(ctx, c.x, c.y - d)) / (2.0 * d)
	return g.normalized() if g.length() >= FLAT_GRADIENT else Vector2.ZERO

## A clump around `c`: maybe the one big branch (at the centre, along `angle`), plus 2..5 mixed
## sticks scattered around it at loose angles, not touching. Returns how many pieces were placed.
static func _place_clump(ctx: Dictionary, c: Vector2, angle: float, rng: RandomNumberGenerator, skip_circle: int) -> int:
	var active: Dictionary = ctx.active
	var ids: Array[int] = []
	if rng.randf() < CLUMP_BIG_BRANCH_P and active[BRANCH_ID]:
		ids.append(BRANCH_ID)
	for i in rng.randi_range(CLUMP_STICKS_MIN, CLUMP_STICKS_MAX):
		var sid := _pick(STICK_MIX, rng)
		if active[sid]:
			ids.append(sid)
	var placed := 0
	for i in ids.size():
		var id: int = ids[i]
		# Re-roll the spot when it lands on a piece already in the clump (they must not intersect).
		for attempt in CLUMP_PIECE_ATTEMPTS:
			var off := Vector2(rng.randf_range(-CLUMP_SPREAD, CLUMP_SPREAD), rng.randf_range(-CLUMP_SPREAD, CLUMP_SPREAD)) if i > 0 or attempt > 0 else Vector2.ZERO
			var jitter := 0.0 if id == BRANCH_ID else deg_to_rad(rng.randf_range(-CLUMP_ANGLE_JITTER_DEG, CLUMP_ANGLE_JITTER_DEG))
			var a := angle + jitter + (PI if rng.randf() < 0.5 else 0.0)
			if _try_place(ctx, id, c + off, a, _roll_scale(id, rng), rng, skip_circle):
				placed += 1
				break
	if placed > 0:
		ctx.counts.clumps += 1
	return placed

## Checks one piece at `p` (pixel space) with its long axis at `angle`, and records it if it fits.
## skip_circle: index into ctx.circles to ignore (the rock this piece is banked against).
static func _try_place(ctx: Dictionary, id: int, p: Vector2, angle: float, scale: float, rng: RandomNumberGenerator, skip_circle: int) -> bool:
	var piece: Dictionary = PIECES[id]
	var kind: String = piece.kind
	var hl: float = float(piece.hl) * scale
	var r: float = float(piece.r) * scale
	var along := Vector2(cos(angle), sin(angle))
	var a := p - along * hl
	var b := p + along * hl
	var width: int = ctx.width
	var length: int = ctx.length
	var counts: Dictionary = ctx.counts
	var reach := hl + r + ROAD_MARGIN
	if p.x < EDGE_MARGIN + reach or p.y < EDGE_MARGIN + reach or p.x > width - 1 - EDGE_MARGIN - reach or p.y > length - 1 - EDGE_MARGIN - reach:
		counts.rej_edge += 1
		return false

	# Samples along the axis: slope + road (centre line and both sides).
	var n := maxi(1, int(ceil(2.0 * hl / 0.5)))
	var side := Vector2(-along.y, along.x) * (r + ROAD_MARGIN)
	var road_weight: PackedFloat32Array = ctx.road_weight
	for k in n + 1:
		var q := a.lerp(b, float(k) / float(n))
		if TerrainUtil.sample_normal(ctx.heights, width, length, q.x, q.y).y < float(MAX_SLOPE_NORMAL_Y[kind]):
			counts.rej_slope += 1
			return false
		for s in [q, q + side, q - side]:
			var idx := clampi(int(round(s.y)), 0, length - 1) * width + clampi(int(round(s.x)), 0, width - 1)
			if road_weight[idx] > 0.0:
				counts.rej_road += 1
				return false
	if _capsule_blocked(ctx, a, b, r, kind, skip_circle):
		counts.rej_block += 1
		return false

	# Ground fit + transform.
	var pos: Vector3
	var basis: Basis
	var normal := TerrainUtil.sample_normal(ctx.heights, width, length, p.x, p.y)
	if kind == "stump":
		# "lying": a toppled piece rests on the ground like a log -- it follows the ground normal
		# fully, so no side floats and it needs no slope sink (which buried it, 2026-10-01).
		var lying: bool = piece.get("lying", false)
		var up := Vector3.UP.slerp(normal, 1.0 if lying else STUMP_NORMAL_FOLLOW).normalized()
		basis = Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, rng.randf() * TAU)
		# On a slope the downhill side would float: sink by the drop across the footprint.
		var tilt := sqrt(maxf(0.0, 1.0 - normal.y * normal.y)) / maxf(normal.y, 0.2)
		var sink := float(piece.get("embed", EMBED.stump)) * scale +(0.0 if lying else tilt * (hl + r) * STUMP_SLOPE_SINK)
		pos = Vector3(p.x, _h(ctx, p.x, p.y) - sink, p.y)
	elif piece.has("rest"):
		# Hinged piece (stump + attached log): the stump stays planted at "pivot_x" and the log is
		# lowered about it until the first of its "rest" points (local x, underside height) touches
		# the ground -- so the far end never floats and nothing is pushed through the terrain.
		var pivot_x := float(piece.pivot_x) * scale
		var pp := p + along * pivot_x
		var h0 := _h(ctx, pp.x, pp.y)
		var sin_t := INF
		for rp: Array in piece.rest:
			var q := p + along * (float(rp[0]) * scale)
			sin_t = minf(sin_t, (h0 + float(rp[1]) * scale - _h(ctx, q.x, q.y)) / (pivot_x - float(rp[0]) * scale))
		if absf(sin_t) > HINGE_MAX_SIN:
			counts.rej_fit += 1
			return false
		var cos_t := sqrt(1.0 - sin_t * sin_t)
		var x_axis := Vector3(along.x * cos_t, sin_t, along.y * cos_t)
		var y_axis := (normal - x_axis * normal.dot(x_axis)).normalized()
		basis = Basis(x_axis, y_axis, x_axis.cross(y_axis))
		pos = Vector3(pp.x, h0 - float(EMBED[kind]) * scale, pp.y) - x_axis * pivot_x
	else:
		var ha := _h(ctx, a.x, a.y)
		var hb := _h(ctx, b.x, b.y)
		var max_up := -INF
		var max_down := -INF
		for k in n + 1:
			var t := float(k) / float(n)
			var q := a.lerp(b, t)
			var dev := _h(ctx, q.x, q.y) - lerpf(ha, hb, t)
			max_up = maxf(max_up, dev)
			max_down = maxf(max_down, -dev)
		if max_up > FIT_SINK_MAX + 0.25 * r or max_down > FIT_FLOAT_MAX:
			counts.rej_fit += 1
			return false
		var x_axis := (Vector3(b.x, hb, b.y) - Vector3(a.x, ha, a.y)).normalized()
		var y_axis := (normal - x_axis * normal.dot(x_axis)).normalized()
		basis = Basis(x_axis, y_axis, x_axis.cross(y_axis)) * Basis(Vector3.RIGHT, deg_to_rad(rng.randf_range(-LOG_ROLL_MAX_DEG, LOG_ROLL_MAX_DEG)))
		# Sit on the end-to-end line, lifted by part of any bulge so it rests on it.
		pos = Vector3(p.x, lerpf(ha, hb, 0.5) + maxf(0.0, max_up) * 0.5 - float(EMBED[kind]) * scale, p.y)

	var xf := Transform3D(basis.scaled(Vector3.ONE * scale), pos + ctx.import_position) # pixel -> world
	ctx.transforms[id].append(xf)
	ctx.colors[id].append(Color.WHITE)
	ctx.placed.append({"a": a, "b": b, "r": r, "kind": kind})
	counts[id] += 1
	return true

## Capsule (segment a-b, radius r, pixel space) vs cliff rects, outcrop/rock circles, trunks,
## knot ramps and the deadfall placed so far (branches/sticks keep only SMALL_GAP from each other).
static func _capsule_blocked(ctx: Dictionary, a: Vector2, b: Vector2, r: float, kind: String, skip_circle: int) -> bool:
	var n := maxi(1, int(ceil(a.distance_to(b) / maxf(r, 0.25))))
	var pad := r + KEEPOUT_MARGIN
	var circles: Array[Vector3] = ctx.circles
	for k in n + 1:
		var q := a.lerp(b, float(k) / float(n))
		for kr: Dictionary in ctx.rects:
			var d: Vector2 = q - kr.c
			var lx := d.dot(kr.ax)
			var lz := d.dot(kr.az)
			if lx >= float(kr.x0) - pad and lx <= float(kr.x1) + pad and lz >= float(kr.z0) - pad and lz <= float(kr.z1) + pad:
				return true
		for i in circles.size():
			if i != skip_circle and q.distance_to(Vector2(circles[i].x, circles[i].y)) < circles[i].z + pad:
				return true
		var tr := _nearest_trunk(ctx.trunk_grid, q, pad + TRUNK_RADIUS * 1.5)
		if tr.z > 0.0 and q.distance_to(Vector2(tr.x, tr.y)) < TRUNK_RADIUS * tr.z + pad:
			return true
		for knot in ctx.knots:
			if RockScatter._near_knot_ramp(knot, q.x, q.y, KNOT_RAMP_CLEAR + r):
				return true
	for cap: Dictionary in ctx.placed:
		# Branches and sticks lie close together in a clump, but never through each other.
		var gap := SMALL_GAP if SMALL_KINDS.has(kind) and SMALL_KINDS.has(cap.kind) else KEEPOUT_MARGIN
		if _segment_distance(a, b, cap.a, cap.b) < r + float(cap.r) + gap:
			return true
	return false

## Shortest distance between segments p1-p2 and q1-q2.
static func _segment_distance(p1: Vector2, p2: Vector2, q1: Vector2, q2: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(p1, p2, q1, q2) != null:
		return 0.0
	return minf(
		minf(p1.distance_to(Geometry2D.get_closest_point_to_segment(p1, q1, q2)), p2.distance_to(Geometry2D.get_closest_point_to_segment(p2, q1, q2))),
		minf(q1.distance_to(Geometry2D.get_closest_point_to_segment(q1, p1, p2)), q2.distance_to(Geometry2D.get_closest_point_to_segment(q2, p1, p2))))

## Trunks (TreeScatter.tree_points: px, pz, scale) bucketed in 4 m cells.
static func _build_trunk_grid() -> Dictionary:
	var grid := {}
	for tp in TreeScatter.tree_points:
		var c := Vector2i(floori(tp.x / 4.0), floori(tp.y / 4.0))
		if not grid.has(c):
			grid[c] = []
		grid[c].append(tp)
	return grid

## Nearest trunk within `radius` of p as (px, pz, scale); z = 0 if none. radius <= 4 m (3x3 cells).
static func _nearest_trunk(grid: Dictionary, p: Vector2, radius: float) -> Vector3:
	var best := Vector3.ZERO
	var best_d := radius
	var c := Vector2i(floori(p.x / 4.0), floori(p.y / 4.0))
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for tp: Vector3 in grid.get(Vector2i(c.x + dx, c.y + dz), []):
				var d := p.distance_to(Vector2(tp.x, tp.y))
				if d < best_d:
					best_d = d
					best = tp
	return best

## One shared collision shape per mesh id, from the glb's LOD2: stumps a simplified convex hull,
## logs a trimesh (static bodies only). Branches get none.
static func _build_collision_shapes() -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var shapes := {}
	for id in DEADFALL_MESH_IDS:
		var piece: Dictionary = PIECES[id]
		if SMALL_KINDS.has(piece.kind):
			continue
		var scene: PackedScene = load(SCENE_DIR + "%s/%s.glb" % [piece.dir, piece.get("file", piece.dir)])
		if scene == null:
			push_warning("TERRAIN_GEN: deadfall %s glb failed to load -- no collision for it" % piece.dir)
			continue
		var sample := scene.instantiate()
		var lods := sample.find_children("*LOD*", "MeshInstance3D", true, false)
		lods.sort_custom(func(x: Node, y: Node) -> bool: return String(x.name) < String(y.name))
		var src: MeshInstance3D = lods.back() if not lods.is_empty() else null
		if src and src.mesh:
			shapes[id] = src.mesh.create_trimesh_shape() if piece.kind == "log" else src.mesh.create_convex_shape(true, true)
		sample.free()
	print("TERRAIN_GEN_STARTUP:   deadfall glb load + collision shapes (%d): %.2fs" % [shapes.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	return shapes

static func _h(ctx: Dictionary, px: float, pz: float) -> float:
	return TerrainUtil.sample_height_bilinear(ctx.heights, ctx.width, ctx.length, px, pz)

static func _roll_scale(id: int, rng: RandomNumberGenerator) -> float:
	var s: Array = PIECES[id].s
	return rng.randf_range(float(s[0]), float(s[1]))

## Weighted pick from a *_MIX table -> id.
static func _pick(mix: Array, rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for row in mix:
		total += float(row[1])
	var r := rng.randf() * total
	for row in mix:
		r -= float(row[1])
		if r <= 0.0:
			return int(row[0])
	return int(mix[mix.size() - 1][0])

## DEBUG (2026-10-01): this run's placed transforms per mesh id, for debug_probe.
static var _debug_transforms: Dictionary = {}

## Lists every deadfall piece within `radius` m of a world position, nearest first: which model,
## where, its scale and how far its up axis leans from vertical. Call on the running game:
## WorldGenerator.debug_deadfall_probe(pos).
static func debug_probe(world_pos: Vector3, radius: float = 6.0) -> String:
	var rows: Array = []
	for id: int in _debug_transforms:
		var piece: Dictionary = PIECES[id]
		for xf: Transform3D in _debug_transforms[id]:
			var d := Vector2(xf.origin.x - world_pos.x, xf.origin.z - world_pos.z).length()
			if d <= radius:
				rows.append([d, "%s (id %d, %s) at %.1f m: pos (%.1f, %.1f, %.1f) scale %.2f, up axis %.0f deg from vertical" % [
					piece.get("file", piece.dir), id, piece.kind, d, xf.origin.x, xf.origin.y, xf.origin.z,
					xf.basis.get_scale().x, rad_to_deg(xf.basis.y.normalized().angle_to(Vector3.UP))]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out := PackedStringArray()
	for r in rows:
		out.append(r[1])
	return "\n".join(out) if not out.is_empty() else "no deadfall within %.0f m" % radius

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	_debug_transforms = {}
	deadfall_keep_circles = []
	_keep_grid = {}
	last_counts = {}
